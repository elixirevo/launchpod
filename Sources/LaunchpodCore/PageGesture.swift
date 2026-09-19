import Foundation

public enum PageGesture {
    /// A resumed gesture inherits a destination, not a direction. Its remaining
    /// on-screen offset must never count as movement from the new fingers.
    public static func destination(initialPage: Int, inheritedTarget: Int?, translation: Double,
                                   velocity: Double, inputAge: Double, stride: Double,
                                   pageCount: Int, cancelled: Bool) -> Int {
        let base = inheritedTarget ?? initialPage
        let flick = inputAge < 0.12 && abs(velocity) > 600 && abs(translation) > 12 && velocity*translation > 0
        let turn = !cancelled && (abs(translation) > max(60,stride*0.18) || flick)
        let requested = base + (turn ? (translation < 0 ? 1 : -1) : 0)
        return max(0,min(max(0,pageCount-1),requested))
    }
}
