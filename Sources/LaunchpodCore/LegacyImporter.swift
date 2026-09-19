import Foundation
import Darwin
import CSQLite

public struct ImportPreview {
    public var state: LayoutState
    public var matched: Int
    public var missing: Int
    public var warnings: [String]
    public var summary: String {
        L10n.text("Matched apps: \(matched) · Missing apps: \(missing)\nFolders: \(state.folders.count) · Pages: \(state.pages.count)", "앱 \(matched)개 연결 · 찾지 못한 앱 \(missing)개\n폴더 \(state.folders.count)개 · 페이지 \(state.pages.count)개")
    }
}

/// Reads the observed LPStorage v13 topology: root(1) -> page(3) ->
/// app(4) or group(2) -> page(3) -> app(4). Only follows the active root.
public enum LegacyImporter {
    public static var currentDatabaseURL: URL? {
        let size = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        confstr(_CS_DARWIN_USER_DIR, &buffer, size)
        let url = URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("com.apple.dock.launchpad/db/db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func read(_ url: URL, matching catalog: [AppRecord]) throws -> ImportPreview {
        var source: OpaquePointer?, snapshot: OpaquePointer?
        guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if source != nil { sqlite3_close(source) }
            throw LayoutError.invalid(L10n.text("Cannot read the Launchpad database. Choose the database file manually.", "Launchpad DB를 읽을 수 없습니다. DB 파일을 직접 선택해 주세요."))
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 2000)
        guard sqlite3_open(":memory:", &snapshot) == SQLITE_OK else {
            if snapshot != nil { sqlite3_close(snapshot) }
            throw LayoutError.invalid(L10n.text("Could not create a database snapshot.", "DB 스냅샷을 만들지 못했습니다."))
        }
        defer { sqlite3_close(snapshot) }
        guard let backup = sqlite3_backup_init(snapshot, "main", source, "main") else {
            throw LayoutError.invalid(L10n.text("Could not start the database snapshot.", "DB 스냅샷을 시작하지 못했습니다."))
        }
        let result = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else { throw LayoutError.invalid(L10n.text("The database is busy. Try again shortly.", "DB가 사용 중입니다. 잠시 후 다시 시도해 주세요.")) }
        func rows(_ sql: String) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(snapshot, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LayoutError.invalid(L10n.text("Unsupported Launchpad database structure.", "지원하지 않는 Launchpad DB 구조입니다."))
            }
            defer { sqlite3_finalize(statement) }
            var output: [[String]] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                output.append((0..<sqlite3_column_count(statement)).map { i in
                    sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
                })
                guard output.count < 100_000 else { throw LayoutError.invalid(L10n.text("The database contains too many entries.", "DB 항목 수가 너무 많습니다.")) }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw LayoutError.invalid(L10n.text("An error occurred while reading the database.", "DB를 읽는 중 오류가 발생했습니다.")) }
            return output
        }
        let info = try rows("SELECT key,value FROM dbinfo WHERE key IN ('version','launchpad_root')")
        let version = info.first { $0[0] == "version" }?[1]
        guard version == "13", let rootText = info.first(where: { $0[0] == "launchpad_root" })?[1], let root = Int(rootText) else {
            throw LayoutError.invalid(L10n.text("Only Launchpad database version 13 is supported. This file is version \(version ?? "unknown").", "현재 가져오기는 Launchpad DB 버전 13을 지원합니다. 이 파일은 \(version ?? "알 수 없는 버전")입니다."))
        }
        struct Item { let id: Int; let type: Int; let parent: Int; let order: Int }
        let items = try rows("SELECT rowid,type,parent_id,ordering FROM items ORDER BY ordering,rowid").map {
            Item(id: Int($0[0]) ?? -1, type: Int($0[1]) ?? -1, parent: Int($0[2]) ?? -1, order: Int($0[3]) ?? 0)
        }
        guard items.contains(where: { $0.id == root && $0.type == 1 }) else { throw LayoutError.invalid(L10n.text("Could not find the Launchpad root.", "Launchpad 루트를 찾지 못했습니다.")) }
        let appRows = try rows("SELECT item_id,title,bundleid FROM apps")
        let groupRows = try rows("SELECT item_id,title FROM groups")
        var appByID: [Int: [String]] = [:], groupByID: [Int: String] = [:]
        for row in appRows {
            guard let id = Int(row[0]), appByID[id] == nil else { throw LayoutError.invalid(L10n.text("Duplicate or invalid app IDs.", "앱 ID가 중복되거나 잘못되었습니다.")) }
            appByID[id] = row
        }
        for row in groupRows {
            guard let id = Int(row[0]), groupByID[id] == nil else { throw LayoutError.invalid(L10n.text("Duplicate or invalid group IDs.", "그룹 ID가 중복되거나 잘못되었습니다.")) }
            groupByID[id] = row[1]
        }
        var state = LayoutState(); state.apps = catalog; state.pages = []
        var used = Set<String>(), visited = Set<Int>()
        var matched = 0, missing = 0, warnings: [String] = []
        func appID(_ item: Item) throws -> String? {
            guard let row = appByID[item.id] else { warnings.append(L10n.text("Skipped item \(item.id) with missing app information.", "앱 정보가 없는 항목 \(item.id)을 건너뛰었습니다.")); return nil }
            let candidates = catalog.filter { !$0.bundleID.isEmpty && $0.bundleID == row[2] && !used.contains($0.id) }
            let chosen: AppRecord
            if candidates.count == 1 { chosen = candidates[0]; matched += 1 }
            else {
                chosen = AppRecord(title: row[1], bundleID: row[2], path: "", available: false)
                state.apps.append(chosen); missing += 1
                if candidates.count > 1 { warnings.append(L10n.text("\(row[1]): Multiple installations found; none was automatically selected.", "\(row[1]): 여러 설치본 중 하나를 자동으로 선택하지 않았습니다.")) }
            }
            guard used.insert(chosen.id).inserted else { return nil }
            return chosen.id
        }
        func readPages(parent: Int, allowsFolders: Bool) throws -> [[String]] {
            guard visited.insert(parent).inserted else { throw LayoutError.invalid(L10n.text("The database has cyclic or duplicate group relationships.", "DB에 순환 또는 중복된 그룹 관계가 있습니다.")) }
            let children = items.filter { $0.parent == parent }
            guard children.allSatisfy({ $0.type == 3 }) else { throw LayoutError.invalid(L10n.text("Unexpected page structure.", "예상과 다른 페이지 구조입니다.")) }
            var pages: [[String]] = []
            for page in children {
                guard visited.insert(page.id).inserted else { throw LayoutError.invalid(L10n.text("Duplicate database page relationships.", "DB 페이지 관계가 중복되었습니다.")) }
                var ids: [String] = []
                for item in items.filter({ $0.parent == page.id }) {
                    if item.type == 4 {
                        if let id = try appID(item) { ids.append(id) }
                    } else if item.type == 2 && allowsFolders {
                        let title = groupByID[item.id].flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Folder", "폴더")
                        let folder = AppFolder(title: title, pages: try readPages(parent: item.id, allowsFolders: false))
                        state.folders.append(folder); ids.append(folder.id)
                    } else if item.type == 5 {
                        warnings.append(L10n.text("Item \(item.id) will be added automatically once installation finishes.", "설치 중인 항목 \(item.id)은 설치 완료 후 자동으로 추가됩니다."))
                    } else { throw LayoutError.invalid(L10n.text("Unsupported item structure (type \(item.type)).", "지원하지 않는 항목 구조(type \(item.type))입니다.")) }
                }
                pages.append(ids)
            }
            return pages.isEmpty ? [[]] : pages
        }
        state.pages = try readPages(parent: root, allowsFolders: true)
        for app in catalog where !used.contains(app.id) {
            if state.pages.last?.count ?? 35 >= 35 { state.pages.append([]) }
            state.pages[state.pages.count-1].append(app.id)
        }
        state.normalize(); try state.validate()
        return ImportPreview(state: state, matched: matched, missing: missing, warnings: warnings)
    }
}
