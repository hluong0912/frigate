import SwiftUI

/// First-run connection form; also reused from Settings to change servers.
struct ServerSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false

    @State private var address = "http://192.168.40.249:8971"
    @State private var username = ""
    @State private var password = ""
    @State private var allowSelfSigned = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.40.249:8971", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Frigate address")
            } footer: {
                Text("Use port 8971 (sign-in required) or 5000 (no sign-in, trusted networks only). Live video and recordings need plain http or a certificate the iPhone trusts; see the README.")
            }

            Section("Account") {
                TextField("Username (leave empty for port 5000)", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            Section {
                Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
            } footer: {
                Text("Only affects the camera list, thumbnails and snapshots. iOS video playback still rejects untrusted certificates.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy || address.isEmpty || (!username.isEmpty && password.isEmpty))
            }
        }
        .navigationTitle("Connect to Frigate")
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onAppear {
            if let s = model.settings {
                address = s.baseURL.absoluteString
                username = s.username
                allowSelfSigned = s.allowSelfSigned
            }
        }
    }

    private func connect() async {
        guard let url = ServerSettings.normalisedURL(from: address) else {
            error = "That doesn't look like an address."
            return
        }
        busy = true
        defer { busy = false }
        let settings = ServerSettings(baseURL: url,
                                      username: username.trimmingCharacters(in: .whitespaces),
                                      allowSelfSigned: allowSelfSigned)
        do {
            try await model.connect(settings: settings, password: password)
            error = nil
            if isSheet { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            Form {
                if let s = model.settings {
                    Section("Server") {
                        LabeledContent("Address", value: s.baseURL.absoluteString)
                        LabeledContent("User", value: s.usesAuth ? s.username : "No sign-in")
                        if let v = model.serverVersion { LabeledContent("Frigate", value: v) }
                        LabeledContent("Cameras", value: "\(model.cameras.count)")
                    }
                }
                if let err = model.lastError {
                    Section("Last error") { Text(err).font(.callout).foregroundStyle(.red) }
                }
                Section {
                    Button("Change server or account") { showingSetup = true }
                    Button("Reload cameras") { Task { await model.refresh() } }
                    Button("Sign out", role: .destructive) { model.signOut() }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingSetup) {
                NavigationStack { ServerSetupView(isSheet: true) }
            }
        }
    }
}
