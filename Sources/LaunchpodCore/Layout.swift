import Foundation

public struct AppRecord: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var bundleID: String
    public var path: String
    public var available: Bool
    public var iconRevision: Date?
    public init(id: String = UUID().uuidString, title: String, bundleID: String, path: String, available: Bool = true) {
        self.id = id; self.title = title; self.bundleID = bundleID; self.path = path; self.available = available
    }
}

public struct AppFolder: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var pages: [[String]]
    public init(id: String = UUID().uuidString, title: String, pages: [[String]]) {
        self.id = id; self.title = title; self.pages = pages
    }
}

public struct ItemLocation: Equatable {
    public var folderID: String?
    public var page: Int
    public var index: Int
    public init(folderID: String? = nil, page: Int, index: Int) {
        self.folderID = folderID; self.page = page; self.index = index
    }
}

public enum LayoutError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

/// Independent layout model. Corresponds to LPItem/LPGroup/LPPage/LPLayout;
/// never writes the system Dock's database.
public struct LayoutState: Codable, Equatable {
    public var schemaVersion = 1
    public var apps: [AppRecord] = []
    public var pages: [[String]] = [[]]
    public var folders: [AppFolder] = []
    public var hidden: [String] = []
    // Optional so layouts exported before this migration still decode.
    public var didGroupSystemApps: Bool?
    public var systemFolderPolicyVersion: Int?
    public var automaticSystemFolderID: String?
    public init() {}

    public func app(_ id: String) -> AppRecord? { apps.first { $0.id == id } }
    public func folder(_ id: String) -> AppFolder? { folders.first { $0.id == id } }
    public func title(_ id: String) -> String { folder(id)?.title ?? app(id)?.title ?? "" }
    public func pageList(in folderID: String?) -> [[String]] {
        folderID.flatMap { folder($0)?.pages } ?? pages
    }
    public func location(of id: String) -> ItemLocation? {
        for (p, items) in pages.enumerated() {
            if let i = items.firstIndex(of: id) { return ItemLocation(page: p, index: i) }
        }
        for f in folders {
            for (p, items) in f.pages.enumerated() {
                if let i = items.firstIndex(of: id) { return ItemLocation(folderID: f.id, page: p, index: i) }
            }
        }
        return nil
    }
    public var orderedAppIDs: [String] {
        pages.flatMap { $0 }.flatMap { id in folder(id)?.pages.flatMap { $0 } ?? [id] }
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw LayoutError.invalid(L10n.text("Unsupported layout file version.", "지원하지 않는 배치 파일 버전입니다.")) }
        let appIDs = apps.map(\.id), folderIDs = folders.map(\.id)
        guard Set(appIDs + folderIDs).count == appIDs.count + folderIDs.count else {
            throw LayoutError.invalid(L10n.text("The layout contains duplicate item IDs.", "배치에 중복된 항목 ID가 있습니다."))
        }
        guard !pages.isEmpty, Set(hidden).count == hidden.count, Set(hidden).isSubset(of: Set(appIDs)) else {
            throw LayoutError.invalid(L10n.text("Invalid page or hidden app information in the layout.", "배치의 페이지 또는 숨긴 앱 정보가 올바르지 않습니다."))
        }
        let root = pages.flatMap { $0 }
        guard Set(root).isSubset(of: Set(appIDs + folderIDs)) else { throw LayoutError.invalid(L10n.text("The layout references missing items.", "배치에 없는 항목을 참조합니다.")) }
        let children = folders.flatMap { $0.pages.flatMap { $0 } }
        guard folders.allSatisfy({ !$0.pages.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(children).isSubset(of: Set(appIDs)) else {
            throw LayoutError.invalid(L10n.text("Folders can contain only apps and must have a name.", "폴더는 앱만 포함할 수 있으며 이름이 필요합니다."))
        }
        let allPlaced = root + children + hidden
        guard Set(allPlaced).count == allPlaced.count,
              Set(allPlaced) == Set(appIDs + folderIDs) else {
            throw LayoutError.invalid(L10n.text("The layout contains duplicate or unlinked items.", "배치에 중복되거나 연결되지 않은 항목이 있습니다."))
        }
    }

    private mutating func setPages(_ list: [[String]], in folderID: String?) {
        if let id = folderID, let i = folders.firstIndex(where: { $0.id == id }) { folders[i].pages = list }
        else if folderID == nil { pages = list }
    }
    private mutating func detach(_ id: String) {
        pages = pages.map { $0.filter { $0 != id } }
        for i in folders.indices { folders[i].pages = folders[i].pages.map { $0.filter { $0 != id } } }
        hidden.removeAll { $0 == id }
    }
    public mutating func normalize(capacity: Int = 35, folderCapacity: Int = 35) {
        func rebalance(_ input: [[String]], _ maxCount: Int) -> [[String]] {
            var result = input.isEmpty ? [[]] : input
            var i = 0
            while i < result.count {
                if result[i].count > maxCount {
                    let overflow = Array(result[i].dropFirst(maxCount))
                    result[i] = Array(result[i].prefix(maxCount))
                    if i+1 == result.count { result.append([]) }
                    result[i+1].insert(contentsOf: overflow, at: 0)
                }
                i += 1
            }
            result.removeAll { $0.isEmpty }
            return result.isEmpty ? [[]] : result
        }
        let empty = folders.filter { $0.pages.allSatisfy(\.isEmpty) }.map(\.id)
        for id in empty { detach(id) }
        folders.removeAll { empty.contains($0.id) }
        for i in folders.indices { folders[i].pages = rebalance(folders[i].pages, max(1, folderCapacity)) }
        pages = rebalance(pages, max(1, capacity))
    }

    /// Destination index is defined after removing the dragged item.
    /// This avoids off-by-one errors during same-page moves and cancelled drags.
    /// Append after the last occupied page, preserving deliberate page gaps.
    /// move() handles overflow and clamps the index after detaching the source.
    public func endOfFolder(_ id: String) -> ItemLocation? {
        guard let group = folder(id) else { return nil }
        let page = group.pages.lastIndex(where: { !$0.isEmpty }) ?? 0
        return ItemLocation(folderID:id,page:page,index:group.pages.indices.contains(page) ? group.pages[page].count : 0)
    }

    public mutating func move(_ id: String, to destination: ItemLocation, capacity: Int = 35, folderCapacity: Int = 35) throws {
        guard location(of: id) != nil else { throw LayoutError.invalid(L10n.text("Could not find the item to move.", "이동할 항목을 찾을 수 없습니다.")) }
        if let target = destination.folderID {
            guard folder(target) != nil, app(id) != nil else { throw LayoutError.invalid(L10n.text("Only apps can be placed in folders.", "폴더 안에는 앱만 넣을 수 있습니다.")) }
        }
        var next = self
        next.detach(id)
        var list = next.pageList(in: destination.folderID)
        let page = min(max(destination.page, 0), list.count)
        if page == list.count { list.append([]) }
        list[page].insert(id, at: min(max(destination.index, 0), list[page].count))
        next.setPages(list, in: destination.folderID)
        next.normalize(capacity: capacity, folderCapacity: folderCapacity)
        try next.validate()
        self = next
    }

    @discardableResult public mutating func makeFolder(with source: String, over target: String, title: String = L10n.text("New Folder", "새 폴더"), capacity: Int = 35, folderCapacity: Int = 35) throws -> String {
        guard source != target, app(source) != nil, app(target) != nil,
              let targetLocation = location(of: target), targetLocation.folderID == nil else {
            throw LayoutError.invalid(L10n.text("Could not create a folder from these two apps.", "두 앱으로 폴더를 만들 수 없습니다."))
        }
        var next = self
        // Replace the target before detaching source so its original position is preserved.
        let folder = AppFolder(title: title, pages: [[target, source]])
        next.pages[targetLocation.page][targetLocation.index] = folder.id
        next.detach(source)
        next.folders.append(folder)
        next.normalize(capacity: capacity, folderCapacity: folderCapacity)
        try next.validate()
        self = next
        return folder.id
    }
    public mutating func renameFolder(_ id: String, title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].title = String(text.prefix(100))
    }
    public mutating func hide(_ id: String) {
        guard app(id) != nil else { return }
        detach(id); hidden.append(id); normalize(capacity: Int.max, folderCapacity: Int.max)
    }
    public mutating func showAllHidden(capacity: Int = 35, folderCapacity: Int = 35) {
        let ids = hidden; hidden = []
        for id in ids { append(id, capacity: capacity) }
        normalize(capacity: capacity, folderCapacity: folderCapacity)
    }
    public mutating func removeApp(_ id: String) {
        detach(id); apps.removeAll { $0.id == id }; normalize(capacity: Int.max, folderCapacity: Int.max)
    }
    private mutating func append(_ id: String, capacity: Int = 35) {
        if pages.isEmpty { pages = [[]] }
        if let page = pages.indices.first(where: { pages[$0].count < capacity }) { pages[page].append(id) }
        else { pages.append([id]) }
    }

    /// Group only loose, installed system apps once. Existing folders, hidden
    /// apps and subsequent manual moves remain the user's choices.
    public mutating func groupSystemAppsIfNeeded(capacity: Int = 35, folderCapacity: Int = 35) {
        guard (systemFolderPolicyVersion ?? 0) < 2 else { return }
        defer { didGroupSystemApps = true; systemFolderPolicyVersion = 2 }
        // Correct the identifiable folder created by 0.1.18. Renamed/custom
        // folders and manually extracted apps are not swept back into it.
        if didGroupSystemApps == true {
            let candidates = folders.filter { folder in
                let children = folder.pages.flatMap { $0 }
                return folder.title == "Apple" && !children.isEmpty
                    && children.allSatisfy { app($0)?.isBuiltInAppleApp == true }
            }
            guard candidates.count == 1, let previous = candidates.first,
                  let location = location(of:previous.id),
                  let index = folders.firstIndex(where: { $0.id == previous.id }) else { return }
            let children = previous.pages.flatMap { $0 }
            let tools = children.filter { app($0)?.isInitialUtility == true }
            let loose = children.filter { app($0)?.isInitialUtility != true }
            folders[index].title = L10n.text("Tools", "도구"); folders[index].pages = [tools]
            pages[location.page].insert(contentsOf:loose,at:location.index+1)
            automaticSystemFolderID = tools.isEmpty ? nil : previous.id
            normalize(capacity:capacity,folderCapacity:folderCapacity)
            return
        }
        didGroupSystemApps = true
        let eligible = Set(apps.filter { $0.isInitialUtility && $0.available }.map(\.id))
        let ids = pages.flatMap { $0 }.filter { eligible.contains($0) }
        guard ids.count > 1, let first = ids.first, let position = location(of: first) else { return }
        let folder = AppFolder(title: L10n.text("Tools", "도구"), pages: [ids])
        pages[position.page][position.index] = folder.id
        let grouped = Set(ids)
        pages = pages.map { $0.filter { !grouped.contains($0) } }
        folders.append(folder)
        automaticSystemFolderID = folder.id
        normalize(capacity: capacity, folderCapacity: folderCapacity)
    }

    /// A moved app keeps its identity only when the bundle ID has exactly one
    /// unmatched old and new candidate. Two installed versions never collapse.
    public mutating func reconcile(_ discovered: [AppRecord], removedPaths: Set<String> = [], capacity: Int = 35, folderCapacity: Int = 35) {
        let old = apps
        var claimed = Set<String>()
        var updated: [AppRecord] = []
        let incomingPaths = Set(discovered.map(\.path))
        for var found in discovered {
            if let exact = old.first(where: { $0.path == found.path && !claimed.contains($0.id) }) {
                found.id = exact.id
            } else if !found.bundleID.isEmpty {
                let candidates = old.filter { $0.bundleID == found.bundleID && !incomingPaths.contains($0.path) && !claimed.contains($0.id) }
                let incoming = discovered.filter { candidate in
                    candidate.bundleID == found.bundleID && !old.contains(where: { $0.path == candidate.path })
                }
                if candidates.count == 1 && incoming.count == 1 { found.id = candidates[0].id }
            }
            claimed.insert(found.id); found.available = true; updated.append(found)
        }
        // Match moved apps first. Only confirmed deletions lose their placement;
        // disconnected sources and unresolved imports retain their identity.
        for var missing in old where !claimed.contains(missing.id) {
            if removedPaths.contains(missing.path) { detach(missing.id) }
            else { missing.available = false; updated.append(missing) }
        }
        apps = updated
        for app in updated where location(of: app.id) == nil && !hidden.contains(app.id) { append(app.id, capacity: capacity) }
        normalize(capacity: capacity, folderCapacity: folderCapacity)
    }
}

extension AppRecord {
    /// Exact membership read from the supplied LaunchOS Tools folder. General
    /// Apple apps (including Safari, Notes and Photos) are deliberately absent.
    public static let initialUtilityBundleIDs: Set<String> = [
        "com.apple.airport.airportutility", "com.apple.BluetoothFileExchange", "com.apple.bootcampassistant",
        "com.apple.ColorSyncUtility", "com.apple.grapher", "com.apple.VoiceOverUtility",
        "com.apple.DiskUtility", "com.apple.DigitalColorMeter", "com.apple.MigrateAssistant",
        "com.apple.screenshot.launcher", "com.apple.ScriptEditor2", "com.apple.SystemProfiler",
        "com.apple.audio.AudioMIDISetup", "com.apple.Console", "com.apple.Terminal",
        "com.apple.printcenter", "com.apple.ScreenSharing", "com.apple.Magnifier", "com.apple.ActivityMonitor"
    ]
    public var isInitialUtility: Bool {
        Self.initialUtilityBundleIDs.contains(bundleID)
            && URL(fileURLWithPath:path).standardizedFileURL.path.hasPrefix("/System/Applications/Utilities/")
    }
    public var isBuiltInAppleApp: Bool {
        guard bundleID.hasPrefix("com.apple.") else { return false }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        return canonical.hasPrefix("/System/Applications/")
            || (bundleID == "com.apple.Safari" &&
                (canonical == "/Applications/Safari.app" || canonical.hasPrefix("/System/Volumes/Preboot/Cryptexes/App/System/Applications/")))
    }
}
