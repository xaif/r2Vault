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
        !accountId.isEmpty && !accessKeyId.isEmpty && !secretAccessKey.isEmpty && !bucketName.isEmpty
    }

    var body: some View {
        Form {
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
                        // Reset selection after delete
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
                Text("Used to generate public URLs. Include the scheme (https://).")
            }

            Section {
                Button {
                    save()
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


#if os(iOS)
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.9")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "9")
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
#endif
        }
        .formStyle(.grouped)
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

    private func save() {
        let creds = R2Credentials(
            id: editingCredentialID ?? UUID(),
            accountId: accountId.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeyId: accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketName: bucketName.trimmingCharacters(in: .whitespacesAndNewlines),
            customDomain: customDomain.isEmpty ? nil : customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        editingCredentialID = creds.id
        selectedCredentialID = creds.id
        viewModel.saveCredentials(creds)
        viewModel.selectCredentials(id: creds.id)
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        save()  // ensure latest values are used
        let success = await viewModel.testConnection()
        isTesting = false
        testResult = success ? "✓ Connected to R2" : "✗ Connection failed"
    }
}

#Preview {
    SettingsView()
        .environment(AppViewModel())
}
