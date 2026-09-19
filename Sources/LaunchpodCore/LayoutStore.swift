import Foundation

public final class LayoutStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("layout.json") }
    public var backupURL: URL { directory.appendingPathComponent("layout.previous.json") }
    public private(set) var recoveryMessage: String?
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> LayoutState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LayoutState() }
        do { return try decode(fileURL) }
        catch {
            if let backup = try? decode(backupURL) {
                recoveryMessage = L10n.text("Could not read the layout file. The previous backup was restored.", "배치 파일을 읽지 못해 직전 백업을 복구했습니다.")
                return backup
            }
            throw LayoutError.invalid(L10n.text("Could not read the layout file or backup. Original files have been preserved.\n\(error.localizedDescription)", "배치 파일과 백업을 읽지 못했습니다. 원본 파일은 보존됩니다.\n\(error.localizedDescription)"))
        }
    }
    private func decode(_ url: URL) throws -> LayoutState {
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(LayoutState.self, from: data)
        try state.validate(); return state
    }
    public func save(_ state: LayoutState) throws {
        try state.validate()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        // Only a known-valid previous file can replace the backup.
        if (try? decode(fileURL)) != nil {
            try Data(contentsOf: fileURL).write(to: backupURL, options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
    }
    public func export(_ state: LayoutState, to url: URL) throws {
        try state.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
    public func readExport(_ url: URL) throws -> LayoutState { try decode(url) }
}
