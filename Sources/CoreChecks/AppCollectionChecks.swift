import Foundation
import LaunchpodCore

func runAppCollectionChecks(_ expect: (Bool,String) -> Void) throws {
    var original = LayoutState()
    original.apps = (0..<9).map { AppRecord(id:String($0),title:String($0),bundleID:String($0),path:"/Applications/\($0).app") }
    original.pages = [["0","1","2"],["3","4"],["folder","8"]]
    original.folders = [AppFolder(id:"folder",title:"Tools",pages:[["5","6"],["7"]])]
    try original.validate()
    var state = original
    try state.moveApps(["2","0"],to:ItemLocation(page:0,index:1),capacity:3)
    expect(state.pages[0] == ["1","2","0"],"collection keeps pickup order in same-page move")
    state = original
    try state.moveApps(["0","1","2","5","6","7"],to:ItemLocation(page:2,index:1),capacity:3)
    expect(state.pages == [["3","4"],["0","1","2"],["5","6","7"],["8"]],"batch move preserves destination while removing empty source pages and folders")
    expect(state.folders.isEmpty,"empty source folder removed after entire batch")
    state = original
    try state.moveApps(["6","5"],to:ItemLocation(folderID:"folder",page:1,index:1),folderCapacity:2)
    expect(state.folder("folder")?.pages == [["7","6"],["5"]],"same-folder collection keeps destination page before normalization")
    state = original
    try state.moveApps(["2","0","4"],to:ItemLocation(folderID:"folder",page:1,index:1),folderCapacity:2)
    expect(state.folder("folder")?.pages == [["5","6"],["7","2"],["0","4"]],"folder drop overflows in pickup order")
    state = original
    let group = try state.makeFolder(withApps:["6","0","2"],over:"3",folderCapacity:2)
    expect(state.folder(group)?.pages == [["3","6"],["0","2"]],"grouping places target first then collected apps")
    try state.validate()
    state = original
    try state.moveApps(["0","3"],to:ItemLocation(page:3,index:0))
    expect(state.pages.last == ["0","3"],"collection can create a final page")
    for ids in [["0","0"],["missing"],["folder"],[]] {
        state = original
        do { try state.moveApps(ids,to:ItemLocation(page:0,index:0)); expect(false,"invalid collection must fail") }
        catch { expect(state == original,"invalid collection leaves layout unchanged") }
    }
    state = original
    do { try state.moveApps(["0"],to:ItemLocation(folderID:"missing",page:0,index:0)); expect(false,"invalid folder must fail") }
    catch { expect(state == original,"invalid destination is atomic") }
    do { try state.makeFolder(withApps:["0","1"],over:"1"); expect(false,"cannot group onto collected app") }
    catch { expect(state == original,"invalid grouping is atomic") }
}
