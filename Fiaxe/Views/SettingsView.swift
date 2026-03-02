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
            Section("Connections") {
                Picker("Bucket", selection: $selectedCredentialID) {
                    Text("New Connection").tag(Optional<UUID>.none)
                    ForEach(viewModel.credentialsList) { creds in
                        Text(creds.bucketName).tag(Optional(creds.id))
                    }
                }
                .onChange(of: selectedCredentialID) { _, newValue in
                    if let id = newValue,
                       let creds = viewModel.credentialsList.first(where: { $0.id == id }) {
                        populateFromExisting(creds)
                        editingCredentialID = id
                    } else {
                        clearForm()
                        editingCredentialID = nil
                    }
                }

                HStack(spacing: 10) {
                    Button("Add New") {
                        selectedCredentialID = nil
                        clearForm()
                        editingCredentialID = nil
                    }

                    Button("Delete") {
                        if let id = editingCredentialID {
                            viewModel.deleteCredentials(id: id)
                            selectedCredentialID = viewModel.credentialsList.first?.id
                            if let first = viewModel.credentialsList.first {
                                populateFromExisting(first)
                                editingCredentialID = first.id
                            } else {
                                clearForm()
                                editingCredentialID = nil
                            }
                        }
                    }
                    .disabled(editingCredentialID == nil)
                }
            }

            Section("Cloudflare R2 Credentials") {
                TextField("Account ID", text: $accountId)
                    .textContentType(.username)
                TextField("Access Key ID", text: $accessKeyId)
                    .textContentType(.username)
                SecureField("Secret Access Key", text: $secretAccessKey)
                TextField("Bucket Name", text: $bucketName)
            }

            Section {
                TextField("Custom Domain (https://cdn.example.com)", text: $customDomain)
                    .textContentType(.URL)
            } header: {
                Text("Optional")
            } footer: {
                Text("Used to generate public URLs. Include the scheme (https://).")
            }

            Section {
                HStack(spacing: 12) {
                    Button("Save") {
                        save()
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                    }
                    .disabled(!canSave)
                    .buttonStyle(.borderedProminent)

                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting || !canSave)

                    if isTesting {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    if let testResult {
                        Text(testResult)
                            .foregroundStyle(testResult.contains("✓") ? .green : .red)
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical)
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
