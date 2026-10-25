import CoreGraphics
import Foundation

private enum Const {
    /// 拖动时拉动量的跟随阻尼：偏大，跟手且不抖
    static let trackDamping: Double = 28
    /// 松手后的回弹阻尼：偏小，多荡几下
    static let reboundDamping: Double = 11
    /// 拉到上限附近额外加的阻尼，让人感觉是在跟弹簧较劲，而不是撞墙
    static let limitDamping: Double = 70
    /// 拉动距离的软上限，相对图标尺寸
    static let maxPullRatio: Double = 1.1
}

/// 一个最普通的阻尼弹簧。Q 弹感全部来自「欠阻尼」：会过头、会来回晃，然后停。
struct Spring {
    var value: Double
    var target: Double
    var velocity: Double = 0
    let stiffness: Double
    var damping: Double

    init(_ value: Double = 0, stiffness: Double, damping: Double) {
        self.value = value
        self.target = 0
        self.stiffness = stiffness
        self.damping = damping
    }

    mutating func step(_ dt: Double) {
        let acceleration = -stiffness * (value - target) - damping * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    mutating func settle() {
        value = target
        velocity = 0
    }

    var isSettled: Bool {
        abs(value - target) < 0.0005 && abs(velocity) < 0.004
    }
}

/// 按压 + 拉动的全部形变状态。窗口始终不动。
///
/// - `bulge`：以按压点为中心的整体放大（弹跳）和局部肿起，0 = 原样
/// - `pull`：按住后把鼠标拖开，形状朝光标方向被拉长（松手弹回）
final class Jelly {
    /// 按压弹簧：整体放大 + 局部肿起的幅度。
    /// 阻尼故意压得很低，松开后要来回晃好几下。
    var bulge = Spring(stiffness: 340, damping: 8.5)
    /// 拉动位移（点）。拉动量走弹簧跟随鼠标，压掉绕圈时的抖动
    var pullX = Spring(stiffness: 420, damping: 28)
    var pullY = Spring(stiffness: 420, damping: 28)
    /// 图标尺寸，用来把「拉了多少点」换算成拉伸倍数
    var referenceSide: Double = 128

    private(set) var isPressing = false
    /// 整体放大的淡出程度（1 = 完整放大，0 = 只剩拉动形变）。
    /// 一旦拉开过就保持淡出，光标绕回中心也不会反复抽动。
    var popLevel = Spring(1, stiffness: 160, damping: 22)
    /// 按压 / 放大中心（视图坐标），按住时跟着鼠标走
    private(set) var center: CGPoint = .zero

    /// 按压幅度，限幅避免变形到认不出来
    var amplitude: Double { min(1.25, max(-0.45, bulge.value)) }

    var pull: CGPoint { CGPoint(x: pullX.value, y: pullY.value) }
    var pullLength: Double { (pullX.value * pullX.value + pullY.value * pullY.value).squareRoot() }
    var stretchAngle: Double { atan2(pullY.value, pullX.value) }

    /// 沿拉动方向的拉伸倍数：拉得越远越明显，上限 1.6 倍
    var stretchScale: Double {
        min(1.6, 1 + 0.55 * (pullLength / max(1, referenceSide)))
    }

    /// 软限位之后的拉动上限（点）
    var pullLimit: Double { referenceSide * Const.maxPullRatio }

    func press(at point: CGPoint) {
        center = point
        bulge.velocity = 0
        bulge.target = 1
        pullX.settle()
        pullY.settle()
        // 跟手时阻尼大一点（不抖），松手后才换成低阻尼，让回弹更活泼
        pullX.damping = Const.trackDamping
        pullY.damping = Const.trackDamping
        popLevel.value = 1
        popLevel.target = 1
        popLevel.velocity = 0
        isPressing = true
    }

    /// 按住时同时更新：放大中心跟着鼠标，拉动量 = 光标相对按下点
    func drag(center point: CGPoint, pull vector: CGPoint) {
        center = point
        aimPull(vector)
    }

    /// 只设目标值，让弹簧自己追。6pt 以内算没拉开，
    /// 免得光标在按下点附近划来划去时方向乱翻。
    func aimPull(_ vector: CGPoint) {
        let length = (vector.x * vector.x + vector.y * vector.y).squareRoot()
        if length > 10 { popLevel.target = 0 }
        if length < 6 {
            pullX.target = 0
            pullY.target = 0
        } else {
            pullX.target = vector.x
            pullY.target = vector.y
        }
    }

    /// 松开：整体放大和拉动一起弹回，开始 Q 弹归位
    func release() {
        isPressing = false
        bulge.target = 0
        pullX.target = 0
        pullY.target = 0
        pullX.damping = Const.reboundDamping
        pullY.damping = Const.reboundDamping
    }

    func update(_ dt: Double) {
        guard dt > 0 else { return }
        // 越接近上限，拉动越「重」：阻尼随拉距平方增长
        if isPressing {
            let ratio = min(1, pullLength / max(1, pullLimit))
            // 只在最后一段（60% 以后）明显变重
            let over = max(0, (ratio - 0.6) / 0.4)
            let extra = Const.limitDamping * over * over
            pullX.damping = Const.trackDamping + extra
            pullY.damping = Const.trackDamping + extra
        }
        let steps = max(1, Int((dt / (1.0 / 600.0)).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            bulge.step(h)
            pullX.step(h)
            pullY.step(h)
            popLevel.step(h)
        }
    }

    /// 弹簧停了就停计时器；按住不动时也不空转
    var isSettled: Bool {
        bulge.isSettled && pullX.isSettled && pullY.isSettled && popLevel.isSettled
    }

    func settleAll() {
        bulge.settle()
        pullX.settle()
        pullY.settle()
        popLevel.settle()
        isPressing = false
    }
}
