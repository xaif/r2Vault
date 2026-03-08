import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var viewModel

    @State private var selectedCredentialID: UUID? = nil
    @State private var editingCredentialID: UUID? = nil
    @State private var accountId = ""
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var bucketName = ""
    @State private var customDomain = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var saved = false

    private var canSave: Bool {
        !accountId.isEmpty
            && !accessKeyId.isEmpty
            && !secretAccessKey.isEmpty
            && !bucketName.isEmpty
            && customDomainValidationMessage == nil
    }

    private var trimmedCustomDomain: String {
        customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customDomainValidationMessage: String? {
        guard !trimmedCustomDomain.isEmpty,
              R2Credentials.normalizedCustomDomain(trimmedCustomDomain) == nil else {
            return nil
        }

        return "Use a full https URL without query parameters or fragments."
    }

    private var selectedCredentials: R2Credentials? {
        guard let selectedCredentialID else { return nil }
        return viewModel.credentialsList.first(where: { $0.id == selectedCredentialID })
    }

    private var hasUnsavedChanges: Bool {
        guard let selectedCredentials else {
            return !accountId.isEmpty || !accessKeyId.isEmpty || !secretAccessKey.isEmpty || !bucketName.isEmpty || !customDomain.isEmpty
        }

        return accountId != selectedCredentials.accountId
            || accessKeyId != selectedCredentials.accessKeyId
            || secretAccessKey != selectedCredentials.secretAccessKey
            || bucketName != selectedCredentials.bucketName
            || customDomain != (selectedCredentials.customDomain ?? "")
    }

    var body: some View {
        Group {
#if os(iOS)
            iosContent
#else
            settingsForm
#endif
        }
#if os(macOS)
        .frame(width: 520)
        .padding(.vertical)
#endif
        .onAppear {
            if let selectedId = viewModel.selectedCredentialID,
               let creds = viewModel.credentialsList.first(where: { $0.id == selectedId }) {
                selectedCredentialID = selectedId
                editingCredentialID = selectedId
                populateFromExisting(creds)
            } else if let first = viewModel.credentialsList.first {
                selectedCredentialID = first.id
                editingCredentialID = first.id
                populateFromExisting(first)
            } else {
                selectedCredentialID = nil
                editingCredentialID = nil
                clearForm()
            }
        }
    }

    private var settingsForm: some View {
        Form {
            connectionsFormSection
            credentialsFormSection
            optionalFormSection
            actionsFormSection

#if os(iOS)
            aboutFormSection
#endif
        }
        .formStyle(.grouped)
    }

#if os(iOS)
    private var iosContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                connectionsCard
                credentialsCard
                optionalCard
                actionsCard
                aboutCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedCredentials?.bucketName ?? "Cloudflare R2")
                        .font(.title3.weight(.semibold))

                    Text(viewModel.credentialsList.isEmpty ? "Add a connection to start browsing and uploading files." : "Keep your active bucket ready for uploads, public links, and quick connection tests.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                statusPill(title: viewModel.credentialsList.isEmpty ? "No Connection" : "\(viewModel.credentialsList.count) Bucket\(viewModel.credentialsList.count == 1 ? "" : "s")", systemImage: "externaldrive.fill")
                statusPill(title: hasUnsavedChanges ? "Unsaved Changes" : "Ready", systemImage: hasUnsavedChanges ? "square.and.arrow.down" : "checkmark.circle")
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
        )
    }

    private var connectionsCard: some View {
        settingsCard(title: "Connections", subtitle: "Switch between buckets or create a fresh configuration.") {
            VStack(spacing: 12) {
                if viewModel.credentialsList.isEmpty {
                    ContentUnavailableView {
                        Label("No connections yet", systemImage: "externaldrive.badge.questionmark")
                    } description: {
                        Text("Create your first R2 connection to start syncing files.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                } else {
                    ForEach(viewModel.credentialsList) { creds in
                        connectionRow(creds)
                    }
                }

                Button {
                    selectedCredentialID = nil
                    clearForm()
                    editingCredentialID = nil
                    testResult = nil
                } label: {
                    Label("Add New Connection", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var credentialsCard: some View {
        settingsCard(title: "Cloudflare R2 Credentials", subtitle: "Use the same values you would for any S3-compatible client.") {
            VStack(spacing: 0) {
                inputRow(title: "Account ID", symbol: "person.text.rectangle", prompt: "Enter account identifier") {
                    configuredTextField("Account ID", text: $accountId)
                        .textContentType(.username)
                }

                inputDivider

                inputRow(title: "Access Key ID", symbol: "key.horizontal", prompt: "Enter access key") {
                    configuredTextField("Access Key ID", text: $accessKeyId)
                        .textContentType(.username)
                }

                inputDivider

                inputRow(title: "Secret Access Key", symbol: "lock.fill", prompt: "Enter secret key") {
                    SecureField("Secret Access Key", text: $secretAccessKey)
                        .textContentType(.password)
                        .multilineTextAlignment(.trailing)
                }

                inputDivider

                inputRow(title: "Bucket Name", symbol: "shippingbox.fill", prompt: "Enter bucket name") {
                    configuredTextField("Bucket Name", text: $bucketName)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            )
        }
    }

    private var optionalCard: some View {
        settingsCard(title: "Optional", subtitle: customDomainValidationMessage ?? "Add a custom HTTPS domain if you want friendly public URLs.") {
            VStack(alignment: .leading, spacing: 10) {
                inputRow(title: "Custom Domain", symbol: "globe", prompt: "https://cdn.example.com") {
                    configuredTextField("Custom Domain", text: $customDomain)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                )

                if let customDomainValidationMessage {
                    Label(customDomainValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var actionsCard: some View {
        settingsCard(title: "Actions", subtitle: "Save the active configuration, then confirm R2 can be reached.") {
            VStack(spacing: 12) {
                Button {
                    guard save() else { return }
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                } label: {
                    HStack {
                        Text(saved ? "Saved" : "Save Changes")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSave)

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text(isTesting ? "Testing Connection" : "Test Connection")
                            .fontWeight(.medium)
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "network")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isTesting || !canSave)

                if let testResult {
                    Label(testResult, systemImage: testResult.contains("✓") ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(testResult.contains("✓") ? .green : .red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var aboutCard: some View {
        settingsCard(title: "About", subtitle: "A compact overview of the current app build.") {
            VStack(spacing: 0) {
                aboutRow(title: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.10")
                inputDivider
                aboutRow(title: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "10")
                inputDivider
                Link(destination: URL(string: "https://github.com/xaif/r2Vault")!) {
                    HStack(spacing: 12) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
            )
        }
    }

    private func statusPill(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemGroupedBackground)))
    }

    private func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.14), lineWidth: 1)
        )
    }

    private func connectionRow(_ creds: R2Credentials) -> some View {
        let isSelected = selectedCredentialID == creds.id

        return Button {
            selectedCredentialID = creds.id
            populateFromExisting(creds)
            editingCredentialID = creds.id
            testResult = nil
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .tertiarySystemGroupedBackground))

                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(creds.bucketName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(creds.customDomain ?? creds.endpoint.host() ?? "Cloudflare R2")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(uiColor: .tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.24) : Color(uiColor: .separator).opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                deleteCredentials(id: creds.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteCredentials(id: creds.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func inputRow<Content: View>(title: String, symbol: String, prompt: String, @ViewBuilder field: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .labelStyle(.titleAndIcon)

            Spacer(minLength: 12)

            field()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .submitLabel(.done)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(prompt)
    }

    private var inputDivider: some View {
        Divider()
            .padding(.leading, 30)
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func configuredTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
#endif

    private var connectionsFormSection: some View {
        Section {
            if viewModel.credentialsList.isEmpty {
                Label("No connections yet", systemImage: "externaldrive.badge.questionmark")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(viewModel.credentialsList) { creds in
                    Button {
                        selectedCredentialID = creds.id
                        populateFromExisting(creds)
                        editingCredentialID = creds.id
                    } label: {
                        HStack {
                            Label(creds.bucketName, systemImage: "externaldrive.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedCredentialID == creds.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.callout.weight(.semibold))
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let creds = viewModel.credentialsList[index]
                        viewModel.deleteCredentials(id: creds.id)
                    }
                    syncSelectionAfterDelete()
                }
            }
        } header: {
            HStack {
                Text("Connections")
                Spacer()
                Button("Add New") {
                    selectedCredentialID = nil
                    clearForm()
                    editingCredentialID = nil
                }
                .font(.callout)
            }
        }
    }

    private var credentialsFormSection: some View {
        Section("Cloudflare R2 Credentials") {
            TextField("Account ID", text: $accountId)
                .textContentType(.username)
#if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
#endif
            TextField("Access Key ID", text: $accessKeyId)
                .textContentType(.username)
#if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
#endif
            SecureField("Secret Access Key", text: $secretAccessKey)
            TextField("Bucket Name", text: $bucketName)
#if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
#endif
        }
    }

    private var optionalFormSection: some View {
        Section {
            TextField("Custom Domain (https://cdn.example.com)", text: $customDomain)
                .textContentType(.URL)
#if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
        } header: {
            Text("Optional")
        } footer: {
            Text(customDomainValidationMessage ?? "Used to generate public URLs. Include the scheme (https://).")
                .foregroundStyle(customDomainValidationMessage == nil ? Color.secondary : Color.red)
        }
    }

    private var actionsFormSection: some View {
        Section {
            Button {
                guard save() else { return }
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
            } label: {
                HStack {
                    Text("Save")
                        .fontWeight(.semibold)
                    Spacer()
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }
            }
            .disabled(!canSave)

            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else if let testResult {
                        Text(testResult)
                            .foregroundStyle(testResult.contains("✓") ? .green : .red)
                            .font(.callout)
                    }
                }
            }
            .disabled(isTesting || !canSave)
        }
    }

#if os(iOS)
    private var aboutFormSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.10")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "10")
                    .foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://github.com/xaif/r2Vault")!) {
                HStack {
                    Text("Source Code")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
#endif

    private func populateFromExisting(_ creds: R2Credentials) {
        accountId = creds.accountId
        accessKeyId = creds.accessKeyId
        secretAccessKey = creds.secretAccessKey
        bucketName = creds.bucketName
        customDomain = creds.customDomain ?? ""
    }

    private func clearForm() {
        accountId = ""
        accessKeyId = ""
        secretAccessKey = ""
        bucketName = ""
        customDomain = ""
    }

    private func deleteCredentials(id: UUID) {
        viewModel.deleteCredentials(id: id)
        syncSelectionAfterDelete()
    }

    private func syncSelectionAfterDelete() {
        if let first = viewModel.credentialsList.first {
            selectedCredentialID = first.id
            editingCredentialID = first.id
            populateFromExisting(first)
        } else {
            selectedCredentialID = nil
            editingCredentialID = nil
            clearForm()
        }
    }

    @discardableResult
    private func save() -> Bool {
        let normalizedCustomDomain: String?
        if trimmedCustomDomain.isEmpty {
            normalizedCustomDomain = nil
        } else if let normalized = R2Credentials.normalizedCustomDomain(trimmedCustomDomain) {
            normalizedCustomDomain = normalized
        } else {
            viewModel.alertMessage = "Custom Domain must be a valid https URL without query parameters or fragments."
            viewModel.showAlert = true
            return false
        }

        let creds = R2Credentials(
            id: editingCredentialID ?? UUID(),
            accountId: accountId.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeyId: accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketName: bucketName.trimmingCharacters(in: .whitespacesAndNewlines),
            customDomain: normalizedCustomDomain
        )
        customDomain = normalizedCustomDomain ?? ""
        editingCredentialID = creds.id
        selectedCredentialID = creds.id
        viewModel.saveCredentials(creds)
        viewModel.selectCredentials(id: creds.id)
        return true
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        guard save() else {
            isTesting = false
            return
        }
        let success = await viewModel.testConnection()
        isTesting = false
        testResult = success ? "✓ Connected to R2" : "✗ Connection failed"
    }
}

#Preview {
    SettingsView()
        .environment(AppViewModel())
}
