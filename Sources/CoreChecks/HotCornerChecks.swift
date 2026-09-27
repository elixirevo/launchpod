import Foundation
import CoreGraphics
import LaunchpodCore

func runHotCornerChecks(_ check: (Bool,String) -> Void) {
    let screen = CGRect(x:0,y:0,width:1440,height:900)
    let external = CGRect(x:-1920,y:-180,width:1920,height:1080)
    let screens = [screen,external]
    let all = Set(HotCorner.allCases)
    func point(_ corner: HotCorner, _ screen: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x:screen.minX,y:screen.maxY)
        case .topRight: return CGPoint(x:screen.maxX-1,y:screen.maxY)
        case .bottomLeft: return CGPoint(x:screen.minX,y:screen.minY)
        case .bottomRight: return CGPoint(x:screen.maxX-1,y:screen.minY)
        }
    }
    for mask in 0..<16 {
        let enabled = Set(HotCorner.allCases.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
        for (index,display) in screens.enumerated() {
            for corner in HotCorner.allCases {
                var trigger = HotCornerTrigger()
                let hit = trigger.update(at:point(corner,display),screens:screens,enabled:enabled,canOpen:true)
                check((hit?.corner == corner) == enabled.contains(corner),"only selected hot corners open, for every combination")
                if let hit = hit { check(hit.screenIndex == index,"hot corner chooses the display under the pointer") }
            }
        }
    }
    var trigger = HotCornerTrigger()
    let corner = CGPoint(x:0,y:900), center = CGPoint(x:700,y:450)
    check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true) != nil,"exact AppKit top edge activates")
    for _ in 0..<10 {
        check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true) == nil,"remaining in a corner never repeats")
    }
    check(trigger.update(at:CGPoint(x:8,y:892),screens:[screen],enabled:all,canOpen:true) == nil,"small corner jitter does not rearm")
    check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true) == nil,"return after jitter does not reopen")
    _ = trigger.update(at:center,screens:[screen],enabled:all,canOpen:true)
    check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true) != nil,"leaving and entering rearms")
    _ = trigger.update(at:center,screens:[screen],enabled:all,canOpen:true)
    check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:false) == nil,"drag, modal or visible launcher blocks opening")
    check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true) == nil,"releasing a drag or dismissing in a corner cannot open")
    _ = trigger.update(at:center,screens:[screen],enabled:all,canOpen:true)
    check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true) != nil,"blocked visit rearms only after leaving")
    trigger.reset(at:corner,screens:[screen],enabled:all)
    check(trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true) == nil,"startup, wake or configuration in a corner does not open")
    trigger.reset(at:center,screens:[screen],enabled:all)
    check(trigger.update(at:CGPoint(x:1.5,y:898.5),screens:[screen],enabled:all,canOpen:true) != nil,"fractional Retina coordinates use points")
    trigger.reset(at:center,screens:[screen],enabled:all)
    for position in [CGPoint(x:0,y:450),CGPoint(x:700,y:900),CGPoint(x:-1,y:900),CGPoint(x:3,y:897),CGPoint(x:CGFloat.nan,y:0)] {
        check(trigger.update(at:position,screens:[screen],enabled:all,canOpen:true) == nil,"edges, outside displays and invalid points cannot activate")
    }
    check(trigger.update(at:corner,screens:[],enabled:all,canOpen:true) == nil,"display removal is safe")
    trigger.reset(at:center,screens:[screen],enabled:all)
    _ = trigger.update(at:corner,screens:[screen],enabled:all,canOpen:true)
    check(trigger.update(at:point(.bottomRight,screen),screens:[screen],enabled:all,canOpen:true)?.corner == .bottomRight,"a different selected corner starts a new visit")
    check(trigger.update(at:corner,screens:[screen],enabled:[],canOpen:true) == nil,"disabled corners cannot activate")
    let stacked = [screen,CGRect(x:0,y:900,width:1440,height:900),CGRect(x:0,y:-900,width:1440,height:900)]
    for (position,index,expected) in [(CGPoint(x:1,y:900),0,HotCorner.topLeft),
                                       (CGPoint(x:1,y:901),1,.bottomLeft),
                                       (CGPoint(x:1,y:0),2,.topLeft),
                                       (CGPoint(x:1,y:1),0,.bottomLeft)] {
        trigger.reset(at:center,screens:stacked,enabled:all)
        let hit = trigger.update(at:position,screens:stacked,enabled:all,canOpen:true)
        check(hit?.screenIndex == index && hit?.corner == expected,"stacked displays resolve the shared edge in AppKit coordinates")
    }
    trigger.reset(at:center,screens:screens,enabled:[.topRight])
    check(trigger.update(at:corner,screens:screens,enabled:[.topRight],canOpen:true) == nil,"disabled corner cannot activate a neighbour across the display boundary")
}
