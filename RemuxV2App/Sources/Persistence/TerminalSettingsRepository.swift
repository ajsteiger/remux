import Foundation

protocol TerminalSettingsRepository: Sendable {
    func loadSettings() async throws -> TerminalSettings
    func saveSettings(_ settings: TerminalSettings) async throws
}

actor FileBackedTerminalSettingsRepository: TerminalSettingsRepository {
    private let store: JSONFileStore<TerminalSettings>

    init(rootURL: URL) {
        self.store = JSONFileStore(fileURL: rootURL.appendingPathComponent("terminal-settings.json"))
    }

    func loadSettings() async throws -> TerminalSettings {
        try await store.load(defaultValue: [.default]).first ?? .default
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        try await store.save([settings])
    }
}
