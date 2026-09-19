import Foundation

public enum AppSearch {
    public static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
    /// Searches through folders without changing the saved layout.
    public static func results(for query: String, in state: LayoutState) -> [AppRecord] {
        let terms = folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let apps = Dictionary(uniqueKeysWithValues: state.apps.map { ($0.id, $0) })
        return state.orderedAppIDs.compactMap { apps[$0] }.filter { app in
            let title = folded(app.title)
            let file = folded(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
            return terms.allSatisfy { title.contains($0) || file.contains($0) }
        }
    }
}

public struct InteractionState: Equatable {
    public var query = ""
    public var folderID: String?
    public var editing = false
    public var dragging = false
    public var renaming = false
    public init() {}
    public enum CancelAction { case cancelDrag, finishRename, stopEditing, closeFolder, clearSearch, dismiss }
    /// Order derived from -[Springboard performCancel], 0x1000e7a2c.
    public mutating func cancel() -> CancelAction {
        if dragging { dragging = false; return .cancelDrag }
        if renaming { renaming = false; return .finishRename }
        if editing { editing = false; return .stopEditing }
        if folderID != nil { folderID = nil; return .closeFolder }
        if !query.isEmpty { query = ""; return .clearSearch }
        return .dismiss
    }
}
