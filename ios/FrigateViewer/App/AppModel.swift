import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var settings: ServerSettings?
    private(set) var client: FrigateClient?
    var cameras: [Camera] = []
    var isLoading = false
    var lastError: String?
    var serverVersion: String?

    /// Tab selection and cross-tab navigation (e.g. "rewind" from Live).
    var selectedTab: Tab = .live
    var recordingsCamera: String?
    var recordingsDate: Date = .now

    enum Tab: Hashable { case live, review, recordings, settings }

    init() {
        if let saved = ServerSettings.load() {
            settings = saved
            client = FrigateClient(settings: saved, password: Keychain.get("password"))
        }
    }

    var isConfigured: Bool { client != nil }

    func camera(named name: String) -> Camera? { cameras.first { $0.name == name } }

    /// Validates the connection, signs in when a username is given, then saves.
    func connect(settings newSettings: ServerSettings, password: String) async throws {
        Keychain.delete("token")
        let candidate = FrigateClient(settings: newSettings, password: password.isEmpty ? nil : password)
        if newSettings.usesAuth {
            try await candidate.login(username: newSettings.username, password: password)
        }
        let cams = try await candidate.cameras()
        newSettings.save()
        if !newSettings.usesAuth { Keychain.delete("password") }
        settings = newSettings
        client = candidate
        cameras = cams
        lastError = nil
        serverVersion = try? await candidate.version()
    }

    func signOut() {
        ServerSettings.clear()
        settings = nil
        client = nil
        cameras = []
        serverVersion = nil
    }

    func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.ensureSession()
            cameras = try await client.cameras()
            lastError = nil
            if serverVersion == nil { serverVersion = try? await client.version() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showRecordings(camera: String, at date: Date = .now) {
        recordingsCamera = camera
        recordingsDate = date
        selectedTab = .recordings
    }
}
