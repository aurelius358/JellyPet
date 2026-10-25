// 真人操作替代品：用合成鼠标事件确认「点击、拖动时窗口都一动不动」。
// 会移动你的鼠标，跑完会放回原处；执行进程需要有「辅助功能」权限。
//
//   swiftc -O Tools/ui-check.swift -o /tmp/ui-check && /tmp/ui-check
//
// 前提：果冻桌宠正在运行，且还停在默认位置（右下角）。

import AppKit
import ApplicationServices

private let ownerName = "果冻桌宠"
private let windowSide: CGFloat = 260
private let iconSide: CGFloat = 128

private func petOrigin() -> CGPoint? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    for window in info where (window[kCGWindowOwnerName as String] as? String) == ownerName {
        if let bounds = window[kCGWindowBounds as String] as? [String: Any],
           let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat {
            return CGPoint(x: x, y: y)
        }
    }
    return nil
}

private func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

private func wait(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }
private func text(_ point: CGPoint?) -> String {
    point.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } ?? "nil"
}
private func distance(_ a: CGPoint?, _ b: CGPoint) -> CGFloat {
    guard let a else { return .infinity }
    return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
}

guard AXIsProcessTrusted() else {
    print("需要辅助功能权限：系统设置 › 隐私与安全性 › 辅助功能，把运行它的终端/编辑器勾上。")
    exit(2)
}
guard let home = petOrigin() else {
    print("没找到 \(ownerName) 的窗口，先启动桌宠。")
    exit(1)
}
print("窗口原位：\(text(home))")
usleep(400_000)   // 刚启动时窗口服务器偶尔还没就绪

let screenTop = NSScreen.screens[0].frame.height
let mouseBefore = NSEvent.mouseLocation
let mouseBeforeTop = CGPoint(x: mouseBefore.x, y: screenTop - mouseBefore.y)
defer { post(.mouseMoved, mouseBeforeTop) }

let center = CGPoint(x: home.x + windowSide / 2, y: home.y + windowSide / 2)
var failures = 0

// 1. 点击：只变形，窗口不该动
post(.mouseMoved, center)
wait(0.15)
post(.leftMouseDown, center)
wait(0.05)
post(.leftMouseUp, center)

var worstMove: CGFloat = 0
for _ in 0..<50 {
    wait(0.03)
    worstDragMove = max(worstDragMove, distance(petOrigin(), home))
}
wait(0.6)
let afterClick = petOrigin()
print(String(format: "点击：窗口最大位移 %.0f pt，仍在 %@", worstMove, text(afterClick)))
if worstMove > 1 { print("FAIL 点击产生了位移（应该只变形）"); failures += 1 }
if distance(afterClick, home) > 1 { print("FAIL 点击后没回到原位"); failures += 1 }

// 2. 拖动：窗口必须完全不动（只变形）
let grab = CGPoint(x: center.x + 25, y: center.y - 15)
post(.mouseMoved, grab)
wait(0.15)
post(.leftMouseDown, grab)
wait(0.12)
if distance(petOrigin(), home) > 1 {
    print("FAIL 按下瞬间窗口动了"); failures += 1
}

let target = CGPoint(x: grab.x - 380, y: grab.y + 220)
var worstDragMove: CGFloat = 0
for step in 1...20 {
    let progress = CGFloat(step) / 20
    let point = CGPoint(x: grab.x + (target.x - grab.x) * progress,
                        y: grab.y + (target.y - grab.y) * progress)
    post(.leftMouseDragged, point)
    wait(0.02)
    worstDragMove = max(worstDragMove, distance(petOrigin(), home))
}
wait(0.3)
worstDragMove = max(worstDragMove, distance(petOrigin(), home))
print(String(format: "拖动全程：窗口最大位移 %.1f pt", worstDragMove))
if worstDragMove > 1 { print("FAIL 拖动时窗口动了（应该只变形）"); failures += 1 }

post(.leftMouseUp, target)
wait(0.9)
let afterDrag = petOrigin()
print("松手后：\(text(afterDrag))，原位：\(text(home))")
if distance(afterDrag, home) > 1 { print("FAIL 松手后窗口动了"); failures += 1 }

if failures == 0 {
    print("PASS")
    exit(0)
}
print("\(failures) 项失败")
exit(1)
