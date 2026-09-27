import Foundation
import LaunchpodCore
import CSQLite

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
runHotCornerChecks { expect($0,$1) }
// Language preferences are isolated from the user's application settings.
let languageDomain = "app.launchpod.LanguageChecks." + UUID().uuidString
let languageDefaults = UserDefaults(suiteName:languageDomain)!
L10n.defaults = languageDefaults
expect(L10n.language == .english, "fresh preferences default to English")
languageDefaults.set("unsupported",forKey:L10n.preferenceKey)
expect(L10n.language == .english, "unknown language falls back to English")
L10n.select(.korean)
expect(L10n.text("Settings", "설정") == "설정", "Korean text is selected")
expect(L10n.language(in:UserDefaults(suiteName:languageDomain)!) == .korean, "saved language survives a new defaults instance")
var localizedLayout = LayoutState()
localizedLayout.reconcile((0..<2).map { AppRecord(id:String($0),title:String($0),bundleID:String($0),path:"/App\($0).app") })
let localizedFolder = try localizedLayout.makeFolder(with:"0",over:"1")
expect(localizedLayout.folder(localizedFolder)?.title == "새 폴더", "new folder uses selected language")
localizedLayout.renameFolder(localizedFolder,title:"My 작업 폴더")
L10n.select(.english)
expect(L10n.text("Settings", "설정") == "Settings", "switching back restores English")
expect(localizedLayout.folder(localizedFolder)?.title == "My 작업 폴더", "language changes preserve user folder names")
defer { languageDefaults.removePersistentDomain(forName:languageDomain) }
func app(_ n: Int, bundle: String? = nil, path: String? = nil) -> AppRecord {
    AppRecord(id: "app-\(n)", title: "앱 \(n)", bundleID: bundle ?? "test.app\(n)", path: path ?? "/Applications/App\(n).app")
}
var state = LayoutState(); state.reconcile((0..<80).map { app($0) })
try state.validate()
expect(state.pages.map(\.count) == [35,35,10], "catalog pagination")
let a = state.apps[0].id, b = state.apps[1].id
let folder = try state.makeFolder(with: a, over: b)
try state.validate()
expect(state.folder(folder)?.pages.flatMap { $0 } == [b,a], "folder creation preserves target before source")
expect(state.pages[0][0] == folder, "folder remains in target position")

var systemLayout = LayoutState()
let utilityBundles = Array(AppRecord.initialUtilityBundleIDs).sorted()
let builtins = (0..<6).map { AppRecord(id:"system-\($0)",title:"System \($0)",bundleID:utilityBundles[$0],path:"/System/Applications/Utilities/System\($0).app") }
let safari = AppRecord(id:"safari",title:"Safari",bundleID:"com.apple.Safari",path:"/Applications/Safari.app")
let xcode = AppRecord(id:"xcode",title:"Xcode",bundleID:"com.apple.dt.Xcode",path:"/Applications/Xcode.app")
let thirdParty = AppRecord(id:"third",title:"Third Party",bundleID:"vendor.app",path:"/Applications/Third.app")
systemLayout.reconcile(builtins+[safari,xcode,thirdParty],capacity:4,folderCapacity:3)
let custom = try systemLayout.makeFolder(with:"system-0",over:"third",capacity:4,folderCapacity:3)
systemLayout.hide("system-1")
systemLayout.groupSystemAppsIfNeeded(capacity:4,folderCapacity:3)
try systemLayout.validate()
let apple = systemLayout.folders.first { $0.title == L10n.text("Tools", "도구") }!
expect(apple.pages.map(\.count) == [3,1],"only reference utilities group across folder pages")
expect(systemLayout.location(of:"system-0")?.folderID == custom,"automatic grouping preserves user folders")
expect(systemLayout.hidden == ["system-1"],"automatic grouping preserves hidden apps")
expect(systemLayout.location(of:xcode.id)?.folderID == nil,"separately installed Apple apps stay outside the built-in folder")
try systemLayout.move("system-2",to:ItemLocation(page:0,index:0),capacity:4,folderCapacity:3)
let customizedSystemLayout = systemLayout
systemLayout.groupSystemAppsIfNeeded(capacity:4,folderCapacity:3)
expect(systemLayout == customizedSystemLayout,"automatic grouping never overrides later manual moves")
let systemRoundTrip = try JSONDecoder().decode(LayoutState.self,from:JSONEncoder().encode(systemLayout))
expect(systemRoundTrip.didGroupSystemApps == true,"grouping migration is persisted in exports")
var legacyJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(customizedSystemLayout)) as! [String:Any]
legacyJSON.removeValue(forKey:"didGroupSystemApps")
let legacyLayout = try JSONDecoder().decode(LayoutState.self,from:JSONSerialization.data(withJSONObject:legacyJSON))
expect(legacyLayout.didGroupSystemApps == nil,"old layout files decode without the migration field")
expect(!AppRecord(title:"Fake",bundleID:"com.apple.fake",path:"/System/ApplicationsFake/Fake.app").isBuiltInAppleApp,"system directory matching respects path boundaries")
expect(!AppRecord(title:"Fake",bundleID:"vendor.fake",path:"/System/Applications/Fake.app").isBuiltInAppleApp,"system grouping requires an Apple bundle identity")
expect(systemLayout.location(of:safari.id)?.folderID == nil,"Safari remains outside the Tools folder")
expect(AppRecord.initialUtilityBundleIDs.count == 19,"reference Tools membership contains exactly 19 bundle IDs")
expect(!AppRecord(title:"Notes",bundleID:"com.apple.Notes",path:"/System/Applications/Notes.app").isInitialUtility,"general Apple apps are never initial utilities")
expect(!AppRecord(title:"Terminal",bundleID:"com.apple.Terminal",path:"/Applications/Terminal.app").isInitialUtility,"a separately installed copy is not grouped as a system utility")
var priorGrouping = LayoutState()
priorGrouping.reconcile(builtins+[safari,xcode])
let broadFolder = try priorGrouping.makeFolder(with:builtins[0].id,over:safari.id,title:"Apple")
for utility in builtins.dropFirst() { try priorGrouping.move(utility.id,to:priorGrouping.endOfFolder(broadFolder)!) }
priorGrouping.didGroupSystemApps = true
priorGrouping.groupSystemAppsIfNeeded()
try priorGrouping.validate()
expect(priorGrouping.folder(broadFolder)?.title == L10n.text("Tools", "도구"),"0.1.18 automatic Apple folder becomes Tools")
expect(priorGrouping.folder(broadFolder)?.pages.flatMap { $0 }.count == 6,"migration keeps only reference utility members")
expect(priorGrouping.location(of:safari.id)?.folderID == nil,"migration releases general Apple apps into root pages")
let corrected = priorGrouping
priorGrouping.groupSystemAppsIfNeeded()
expect(priorGrouping == corrected,"corrected initial policy runs only once")
var customGrouping = corrected
customGrouping.systemFolderPolicyVersion = nil
customGrouping.renameFolder(broadFolder,title:"My tools")
customGrouping.groupSystemAppsIfNeeded()
expect(customGrouping.folder(broadFolder)?.title == "My tools","migration preserves a user's renamed folder")
for index in 1..<5 {
    expect(PageGesture.destination(initialPage:index,inheritedTarget:index,translation:-10,velocity:0,inputAge:0.01,stride:1440,pageCount:6,cancelled:false) == index,"remaining positive displacement cannot reverse a short forward continuation")
    expect(PageGesture.destination(initialPage:index-1,inheritedTarget:index,translation:-300,velocity:-900,inputAge:0.01,stride:1440,pageCount:6,cancelled:false) == index+1,"forward continuation advances from the committed destination")
    expect(PageGesture.destination(initialPage:index,inheritedTarget:index,translation:300,velocity:900,inputAge:0.01,stride:1440,pageCount:6,cancelled:false) == index-1,"explicit reverse gesture moves backward")
    expect(PageGesture.destination(initialPage:index-1,inheritedTarget:index,translation:300,velocity:900,inputAge:0.01,stride:1440,pageCount:6,cancelled:true) == index,"cancelling a new gesture retains the earlier committed destination")
}
expect(PageGesture.destination(initialPage:0,inheritedTarget:nil,translation:400,velocity:0,inputAge:1,stride:1440,pageCount:3,cancelled:false) == 0,"paging clamps at the leading edge")
expect(PageGesture.destination(initialPage:2,inheritedTarget:2,translation:-400,velocity:-800,inputAge:0,stride:1440,pageCount:3,cancelled:false) == 2,"continued paging clamps at the last page")
try state.move(a, to: ItemLocation(page: 2, index: 0))
expect(state.folder(folder)?.pages.flatMap { $0 } == [b], "moving from folder retains one-item folder")
try state.move(b, to: ItemLocation(page: 2, index: 1))
expect(state.folder(folder) == nil, "empty folder removed")
try state.validate()
let moved = state.pages[0][0]
try state.move(moved, to: ItemLocation(page: 0,index: 10))
expect(state.pages[0][10] == moved, "same-page index is after removal")
let old = state
do { try state.move(moved, to: ItemLocation(folderID: "missing",page: 0,index: 0)); expect(false,"invalid folder must fail") } catch {}
expect(state == old, "failed move is atomic")
state.hide(a); try state.validate()
expect(state.location(of: a) == nil && state.hidden.contains(a),"hidden apps leave layout")
state.showAllHidden(); try state.validate()
expect(state.location(of: a) != nil,"hidden apps restore")
var movedCatalog = state.apps
let originalID = movedCatalog[0].id
movedCatalog[0].path = "/Applications/Moved.app"; movedCatalog[0].id = "new-id"
state.reconcile(movedCatalog)
expect(state.apps.first { $0.path == "/Applications/Moved.app" }?.id == originalID,"move preserves unique bundle identity")
var duplicateState = LayoutState()
duplicateState.reconcile([app(1,bundle:"same"),app(2,bundle:"same")]); try duplicateState.validate()
expect(duplicateState.apps.count == 2,"two installed versions are distinct")
var searchState = LayoutState()
searchState.reconcile([AppRecord(id:"ko",title:"음성 메모",bundleID:"voice",path:"/VoiceMemos.app"),AppRecord(id:"en",title:"Café Studio",bundleID:"cafe",path:"/Cafe.app")])
expect(AppSearch.results(for:"메모",in:searchState).map(\.id) == ["ko"],"Korean substring")
expect(AppSearch.results(for:"음성",in:searchState).map(\.id) == ["ko"],"Korean Unicode normalization")
expect(AppSearch.results(for:"CAFE",in:searchState).map(\.id) == ["en"],"case and diacritic folding")
expect(AppSearch.results(for:"cafe studio",in:searchState).count == 1,"multiple search terms")
var interaction = InteractionState(); interaction.dragging = true; interaction.editing = true; interaction.folderID = "f"; interaction.query = "a"
expect(interaction.cancel() == .cancelDrag,"Escape cancels drag first")
expect(interaction.cancel() == .stopEditing,"Escape exits edit before folder")
expect(interaction.cancel() == .closeFolder,"Escape closes folder before query")
expect(interaction.cancel() == .clearSearch,"Escape clears query before dismiss")
expect(interaction.cancel() == .dismiss,"Escape dismisses last")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("launchpod-checks-"+UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temp) }
let store = LayoutStore(directory: temp)
try store.save(state); let first = state
state.hide(a); try store.save(state)
let loaded = try store.load()
expect(loaded == state,"save/load round trip")
try Data("broken".utf8).write(to: store.fileURL)
let recovered = try store.load()
expect(recovered == first,"corrupt primary recovers valid backup")
var malformed = first; malformed.pages[0].append(malformed.pages[0][0])
do { try store.save(malformed); expect(false,"duplicate layout must fail") } catch {}
let preserved = try store.load()
expect(preserved == first,"invalid save preserves recovery copy")
var wide = LayoutState(); wide.reconcile((0..<80).map { app($0) }, capacity: 63, folderCapacity: 27)
expect(wide.pages.map(\.count) == [63,17], "custom grid capacity")
wide.hide(wide.pages[0][0]); wide.reconcile(wide.apps, capacity: 63, folderCapacity: 27)
expect(wide.pages.map(\.count) == [62,17], "rescan preserves custom page boundaries")
var fiveRow = LayoutState(); fiveRow.reconcile((0..<60).map { app($0) })
let fiveRowFolder = try fiveRow.makeFolder(with:"app-0",over:"app-1")
for i in 2..<36 { try fiveRow.move("app-\(i)",to:ItemLocation(folderID:fiveRowFolder,page:0,index:i),folderCapacity:35) }
expect(fiveRow.folder(fiveRowFolder)?.pages.map(\.count) == [35,1],"five-row folder overflows only after 35 apps")
let overflowOrder = fiveRow.folder(fiveRowFolder)!.pages
fiveRow.normalize(folderCapacity:45)
expect(fiveRow.folder(fiveRowFolder)?.pages == overflowOrder,"increasing folder capacity preserves existing page boundaries")
for i in 36..<45 { try fiveRow.move("app-\(i)",to:ItemLocation(folderID:fiveRowFolder,page:0,index:i),folderCapacity:45) }
let expandedPages = fiveRow.folder(fiveRowFolder)!.pages
try fiveRow.makeFolder(with:"app-46",over:"app-47",folderCapacity:45)
expect(fiveRow.folder(fiveRowFolder)?.pages == expandedPages,"creating another folder preserves a custom five-row folder")
try store.save(fiveRow)
let fiveRowReloaded = try store.load()
expect(fiveRowReloaded == fiveRow,"five-row folder pages survive persistence")
var appended = LayoutState(); appended.reconcile((0..<50).map { app($0) })
let appendFolder = try appended.makeFolder(with:"app-0",over:"app-1")
for i in 2..<37 { try appended.move("app-\(i)",to:appended.endOfFolder(appendFolder)!,folderCapacity:35) }
expect(appended.folder(appendFolder)?.pages.map(\.count) == [35,2],"appending to a full folder continues on its last page")
expect(appended.folder(appendFolder)?.pages.flatMap { $0 } == ["app-1","app-0"]+(2..<37).map { "app-\($0)" },"successive folder drops preserve insertion order")
try appended.move("app-2",to:ItemLocation(page:0,index:0))
let sparsePages = appended.folder(appendFolder)!.pages
try appended.move("app-37",to:appended.endOfFolder(appendFolder)!)
expect(appended.folder(appendFolder)?.pages == [sparsePages[0],sparsePages[1]+["app-37"]],"append does not fill an earlier page's vacancy")
try appended.move("app-35",to:appended.endOfFolder(appendFolder)!)
expect(appended.folder(appendFolder)?.pages.last == ["app-36","app-37","app-35"],"moving within the same folder appends once after detaching")
expect(appended.endOfFolder("missing") == nil,"missing folder has no append destination")
try store.save(appended)
let appendedReloaded = try store.load()
expect(appendedReloaded == appended,"appended folder order survives saving and reloading")
var varied = LayoutState(); varied.reconcile((0..<90).map { app($0) })
var seed: UInt64 = 12345
func random(_ upper: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(max(1,upper))) }
for i in 0..<250 {
    let ids = varied.orderedAppIDs
    let id = ids[random(ids.count)]
    if i % 7 == 0, let target = varied.pages.flatMap({ $0 }).first(where: { $0 != id && varied.app($0) != nil }) {
        try varied.makeFolder(with: id, over: target)
    } else {
        let destination = i % 3 == 0 && !varied.folders.isEmpty ? varied.folders[random(varied.folders.count)].id : nil
        let pages = varied.pageList(in: destination)
        try varied.move(id, to: ItemLocation(folderID: destination, page: random(pages.count+1), index: random(36)), folderCapacity: 21)
    }
    try varied.validate()
    expect(Set(varied.orderedAppIDs) == Set((0..<90).map { "app-\($0)" }), "mixed folder and page moves retain every app (\(i))")
}
let fixtureURL = temp.appendingPathComponent("legacy.db")
var fixture: OpaquePointer?
expect(sqlite3_open(fixtureURL.path, &fixture) == SQLITE_OK, "open importer fixture")
defer { sqlite3_close(fixture) }
func sql(_ text: String) { expect(sqlite3_exec(fixture, text, nil, nil, nil) == SQLITE_OK, "prepare importer fixture") }
sql("""
PRAGMA journal_mode=WAL;
CREATE TABLE dbinfo(key TEXT,value TEXT);
INSERT INTO dbinfo VALUES('version','13'),('launchpad_root','1');
CREATE TABLE items(type INTEGER,parent_id INTEGER,ordering INTEGER);
INSERT INTO items(rowid,type,parent_id,ordering) VALUES(1,1,0,0),(2,3,1,0),(3,4,2,0),(4,2,2,1),(5,3,4,0),(6,4,5,0),(7,1,0,1),(8,3,7,0),(9,4,8,0);
CREATE TABLE apps(item_id INTEGER,title TEXT,bundleid TEXT);
INSERT INTO apps VALUES(3,'One','test.app1'),(6,'Two','test.app2'),(9,'Orphan','orphan');
CREATE TABLE groups(item_id INTEGER,title TEXT);
INSERT INTO groups VALUES(4,'도구');
""")
let imported = try LegacyImporter.read(fixtureURL, matching: [app(1),app(2),app(10)])
expect(imported.matched == 2 && imported.missing == 0, "WAL snapshot matches installed apps")
expect(imported.state.apps.count == 3 && imported.state.folders.count == 1, "active root ignores old orphan root")
expect(imported.state.pages[0].first == "app-1" && imported.state.folders[0].pages == [["app-2"]], "import preserves root and folder order")
let ambiguous = try LegacyImporter.read(fixtureURL, matching: [app(1),app(11,bundle:"test.app1"),app(2)])
expect(ambiguous.missing == 1 && !ambiguous.warnings.isEmpty, "ambiguous bundle IDs remain unresolved")
sql("INSERT INTO apps VALUES(3,'Duplicate','duplicate');")
do { _ = try LegacyImporter.read(fixtureURL, matching: []); expect(false,"duplicate DB IDs must fail") } catch {}
sql("DELETE FROM apps WHERE bundleid='duplicate'; UPDATE dbinfo SET value='99' WHERE key='version';")
do { _ = try LegacyImporter.read(fixtureURL, matching: []); expect(false,"unknown DB version must fail") } catch {}
if CommandLine.arguments.contains("--legacy"), let url = LegacyImporter.currentDatabaseURL {
    let preview = try LegacyImporter.read(url, matching: [])
    try preview.state.validate()
    expect(preview.missing > 0,"real DB imports missing-app placeholders")
    print("Legacy DB: \(preview.state.apps.count) apps, \(preview.state.folders.count) folders, \(preview.state.pages.count) pages")
}
print("PASS: \(checks) core checks")
