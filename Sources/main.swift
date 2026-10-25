import AppKit
import CoreImage

// MARK: - 常量

private enum Const {
    /// 窗口比图标大一圈：局部放大会把图案推出原范围，不能裁掉
    static let windowSide: CGFloat = 560
    static let defaultIconSide: CGFloat = 128
    static let sizeChoices: [(name: String, side: CGFloat)] = [("小", 104), ("中", 128), ("大", 160)]
    /// 局部肿起的影响半径，相对图标尺寸
    static let bulgeRadiusRatio: CGFloat = 0.35
    /// 拉动距离的软上限，相对图标尺寸（要和 Jelly.swift 里的值一致）
    static let maxPullRatio: CGFloat = 1.1
    /// 按压中心可以偏离图标边缘多少（方便拖到边上）
    static let pressAreaSlack: CGFloat = 0.12
    /// 整体放大幅度：以按压点为中心，跟着按压弹簧一起弹
    static let bounceScale: CGFloat = 0.2
    /// 局部肿起强度（叠在整体放大上，别太抢）
    static let bumpStrength: CGFloat = 0.3
}

private enum DefaultsKey {
    static let centerX = "pet.centerX"
    static let centerY = "pet.centerY"
    static let iconSide = "pet.iconSide"
    static let style = "pet.style"
}

/// 能切换的三个标志
enum PetStyle: Int, CaseIterable {
    case claude = 0
    case gpt
    case gemini

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .gpt: return "GPT"
        case .gemini: return "Gemini"
        }
    }

    var assetName: String {
        switch self {
        case .claude: return "claude-mark"
        case .gpt: return "gpt-mark"
        case .gemini: return "gemini-mark"
        }
    }
}

// MARK: - 几何

enum PetGeometry {
    /// 软限位：拉得越远越拉不动，渐近到 1.1 倍图标尺寸，方向保持不变。
    /// 用 tanh 而不是直接截断，所以永远到不了硬顶，也没有「一下拉到头」的撞击感。
    static func softenPull(_ vector: CGPoint, iconSide: CGFloat) -> CGPoint {
        let limit = iconSide * Const.maxPullRatio
        let length = sqrt(vector.x * vector.x + vector.y * vector.y)
        guard length > 0.5 else { return .zero }
        let softened = limit * CGFloat(tanh(Double(length / limit)))
        return CGPoint(x: vector.x / length * softened, y: vector.y / length * softened)
    }
}

// MARK: - 绘制

enum PetRenderer {
    static func iconRect(in bounds: CGRect, iconSide: CGFloat) -> CGRect {
        CGRect(x: bounds.midX - iconSide / 2, y: bounds.midY - iconSide / 2,
               width: iconSide, height: iconSide)
    }

    /// 生成一张带透明留白的源图，供局部放大使用。
    /// 返回的矩形是它在视图里应该占的位置（点坐标）。
    static func makeSource(icon: NSImage, iconSide: CGFloat, scale: CGFloat,
                           bounds: CGRect) -> (image: CIImage, rect: CGRect)? {
        let side = iconSide * 2.2          // 留出足够空白，放大时不会被裁
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 8, let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: pixels, height: pixels,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: sRGB,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        bitmap.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        bitmap.interpolationQuality = .high

        let iconPixels = iconSide * scale
        let origin = (CGFloat(pixels) - iconPixels) / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        icon.draw(in: CGRect(x: origin, y: origin, width: iconPixels, height: iconPixels),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmap.makeImage() else { return nil }
        let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                          width: side, height: side)
        return (CIImage(cgImage: cgImage), rect)
    }

    /// 局部放大/凹陷。center 是视图坐标里的按压点。
    static func distort(_ image: CIImage, center: CGPoint, radius: CGFloat,
                        amount: Double, pixelScale: CGFloat, context: CIContext) -> CGImage? {
        guard abs(amount) > 0.001,
              let filter = CIFilter(name: "CIBumpDistortion") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: center.x * pixelScale, y: center.y * pixelScale),
                        forKey: kCIInputCenterKey)
        filter.setValue(radius * pixelScale, forKey: kCIInputRadiusKey)
        // 局部肿起只负责「按下去的那块肉」，强度有上限，再大就会折叠出黑洞
        let strength = max(-0.35, min(0.35, amount * Const.bumpStrength))
        filter.setValue(strength, forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: image.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func draw(icon: NSImage, in ctx: CGContext, bounds: CGRect, iconSide: CGFloat,
                     model: Jelly, source: CIImage?, sourceRect: CGRect,
                     pixelScale: CGFloat, ciContext: CIContext) {
        let rect = iconRect(in: bounds, iconSide: iconSide)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10,
                      color: NSColor.black.withAlphaComponent(0.22).cgColor)

        let amount = model.amplitude
        let pull = model.pull
        let pullLength = sqrt(pull.x * pull.x + pull.y * pull.y)

        // 以按压点为中心的整体放大：按下那一下的「弹跳」。
        // 一旦开始拉动就迅速让位给拉伸，免得拉左边时右边也被撑长。
        let pop = model.popLevel.value
        if abs(amount) > 0.003, pop > 0.02 {
            let scale = min(1.4, max(0.8, 1 + Const.bounceScale * amount * pop))
            ctx.translateBy(x: model.center.x, y: model.center.y)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -model.center.x, y: -model.center.y)
        }

        // 拉动：绕拉动方向反侧的边缘拉长，只朝光标那一侧伸出去，远端不动
        if pullLength > 0.5 {
            let angle = model.stretchAngle
            let stretch = model.stretchScale
            let back = CGPoint(x: rect.midX - cos(angle) * iconSide / 2,
                               y: rect.midY - sin(angle) * iconSide / 2)
            ctx.translateBy(x: back.x, y: back.y)
            ctx.rotate(by: angle)
            ctx.scaleBy(x: stretch, y: 1 / sqrt(stretch))
            ctx.rotate(by: -angle)
            ctx.translateBy(x: -back.x, y: -back.y)
        }
        if abs(amount) > 0.003, let source {
            let local = CGPoint(x: model.center.x - sourceRect.minX,
                                y: model.center.y - sourceRect.minY)
            if let distorted = distort(source, center: local,
                                       radius: iconSide * Const.bulgeRadiusRatio,
                                       amount: amount, pixelScale: pixelScale,
                                       context: ciContext) {
                ctx.draw(distorted, in: sourceRect)
                ctx.restoreGState()
                return
            }
        }
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()
    }
}

// MARK: - 视图

final class PetView: NSView {
    let model: Jelly
    var icon: NSImage {
        didSet { rebuildSource() }
    }
    var iconSide: CGFloat = Const.defaultIconSide {
        didSet {
            model.referenceSide = Double(iconSide)
            rebuildSource()
        }
    }

    var onPress: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onRelease: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private let ciContext: CIContext = {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        return CIContext(options: [.cacheIntermediates: false,
                                   .workingColorSpace: space as Any,
                                   .outputColorSpace: space as Any])
    }()
    private var source: CIImage?
    private var sourceRect: CGRect = .zero
    private var pixelScale: CGFloat = 2
    private var pressed = false
    private var pressScreen: CGPoint = .zero

    init(model: Jelly, icon: NSImage) {
        self.model = model
        self.icon = icon
        super.init(frame: CGRect(x: 0, y: 0, width: Const.windowSide, height: Const.windowSide))
        rebuildSource()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    var iconRect: CGRect { PetRenderer.iconRect(in: bounds, iconSide: iconSide) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildSource()
    }

    private func rebuildSource() {
        guard bounds.width > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        pixelScale = scale
        if let made = PetRenderer.makeSource(icon: icon, iconSide: iconSide,
                                             scale: scale, bounds: bounds) {
            source = made.image
            sourceRect = made.rect
        } else {
            source = nil
        }
        needsDisplay = true
    }

    /// 只有图标附近才接收点击，窗口四周的透明区域让给桌面
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let p = convert(point, from: superview)
        let dx = p.x - bounds.midX
        let dy = p.y - bounds.midY
        let radius = iconSide * 0.47
        return dx * dx + dy * dy <= radius * radius ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(iconRect.insetBy(dx: -4, dy: -4), cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        PetRenderer.draw(icon: icon, in: ctx, bounds: bounds, iconSide: iconSide,
                         model: model, source: source, sourceRect: sourceRect,
                         pixelScale: pixelScale, ciContext: ciContext)
    }

    // MARK: 鼠标

    /// 按压中心限制在图标附近，拖到图标外面也不会完全失去按压感
    private func clampToIcon(_ point: CGPoint) -> CGPoint {
        let slack = iconSide * Const.pressAreaSlack
        let area = iconRect.insetBy(dx: -slack, dy: -slack)
        return CGPoint(x: min(max(point.x, area.minX), area.maxX),
                       y: min(max(point.y, area.minY), area.maxY))
    }

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        clampToIcon(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressScreen = NSEvent.mouseLocation
        model.press(at: viewPoint(event))
        onPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        // 放大中心跟着按住的鼠标走；同时按拖开的距离把形状拉长
        let screen = NSEvent.mouseLocation
        let delta = CGPoint(x: screen.x - pressScreen.x, y: screen.y - pressScreen.y)
        model.drag(center: viewPoint(event),
                   pull: PetGeometry.softenPull(delta, iconSide: iconSide))
        onDragStarted?()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        model.release()   // 松开后才开始 Q 弹归位
        onRelease?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

// MARK: - 窗口

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 控制器

final class PetController: NSObject {
    let model = Jelly()
    let panel: PetPanel
    let view: PetView
    private(set) var style: PetStyle
    /// 图标中心的屏幕坐标；窗口原点由它算出来
    private(set) var center: CGPoint
    var iconSide: CGFloat {
        didSet {
            view.iconSide = iconSide
            view.window?.invalidateCursorRects(for: view)
        }
    }

    private var ticker: Timer?
    private var lastTick: CFTimeInterval = 0

    init(fallbackIcon: NSImage) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.iconSide) != nil {
            iconSide = CGFloat(defaults.double(forKey: DefaultsKey.iconSide))
        } else {
            iconSide = Const.defaultIconSide
        }
        if let saved = defaults.object(forKey: DefaultsKey.style) as? Int,
           let savedStyle = PetStyle(rawValue: saved) {
            style = savedStyle
        } else {
            style = .claude
        }

        view = PetView(model: model, icon: PetAssets.icon(style) ?? fallbackIcon)
        panel = PetPanel(contentRect: CGRect(x: 0, y: 0, width: Const.windowSide, height: Const.windowSide),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        center = PetController.restoreCenter()

        super.init()

        view.iconSide = iconSide
        model.referenceSide = Double(iconSide)
        panel.contentView = view
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        applyCenter()

        view.onPress = { [weak self] in self?.startTicker() }
        view.onDragStarted = { [weak self] in self?.startTicker() }
        view.onRelease = { [weak self] in self?.startTicker() }
        view.onMenu = { [weak self] event in self?.showMenu(event) }

        // 系统休眠后计时器可能被暂停，醒来重新对齐一下
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    deinit {
        stopTicker()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: 生命周期

    func start() {
        panel.orderFrontRegardless()
        view.needsDisplay = true
    }

    func shutdown() {
        persist()
        stopTicker()
    }

    @objc private func didWake() {
        applyCenter()
        model.settleAll()
        view.needsDisplay = true
    }

    // MARK: 菜单

    @objc private func goHome() {
        center = PetController.defaultCenter()
        persist()
        model.settleAll()
        applyCenter()
        view.needsDisplay = true
    }

    @objc private func changeStyle(_ sender: NSMenuItem) {
        guard let choice = PetStyle(rawValue: sender.tag),
              let image = PetAssets.icon(choice) else { return }
        style = choice
        view.icon = image
        UserDefaults.standard.set(choice.rawValue, forKey: DefaultsKey.style)
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        iconSide = CGFloat(sender.tag)
        UserDefaults.standard.set(Double(iconSide), forKey: DefaultsKey.iconSide)
    }

    @objc private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let back = NSMenuItem(title: "回到原位", action: #selector(goHome), keyEquivalent: "")
        back.target = self
        menu.addItem(back)

        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (name, side) in Const.sizeChoices {
            let item = NSMenuItem(title: name, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(side)
            item.state = abs(side - iconSide) < 0.5 ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let iconItem = NSMenuItem(title: "图标", action: nil, keyEquivalent: "")
        let iconMenu = NSMenu()
        for choice in PetStyle.allCases {
            let item = NSMenuItem(title: choice.name, action: #selector(changeStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = choice.rawValue
            item.state = choice == style ? .on : .off
            iconMenu.addItem(item)
        }
        iconItem.submenu = iconMenu
        menu.addItem(iconItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: 动画

    private func startTicker() {
        guard ticker == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0, now - lastTick))
        lastTick = now
        model.update(dt)
        view.needsDisplay = true

        if model.isSettled {
            model.settleAll()
            view.needsDisplay = true
            stopTicker()
        }
    }

    // MARK: 位置

    private func applyCenter() {
        let origin = CGPoint(x: (center.x - Const.windowSide / 2).rounded(),
                             y: (center.y - Const.windowSide / 2).rounded())
        panel.setFrameOrigin(origin)
    }

    private func persist() {
        UserDefaults.standard.set(Double(center.x), forKey: DefaultsKey.centerX)
        UserDefaults.standard.set(Double(center.y), forKey: DefaultsKey.centerY)
    }

    private static func defaultCenter() -> CGPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return CGPoint(x: 300, y: 300) }
        return CGPoint(x: visible.maxX - 120, y: visible.minY + 130)
    }

    private static func restoreCenter() -> CGPoint {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.centerX) != nil,
              defaults.object(forKey: DefaultsKey.centerY) != nil else {
            return defaultCenter()
        }
        let point = CGPoint(x: defaults.double(forKey: DefaultsKey.centerX),
                            y: defaults.double(forKey: DefaultsKey.centerY))
        // 换了屏幕要保证还能看见
        let visible = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: 20, dy: 20).contains(point) }
        return visible ? point : defaultCenter()
    }
}

// MARK: - 素材

enum PetAssets {
    static func icon(_ style: PetStyle) -> NSImage? {
        let name = style.assetName
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // 直接从仓库目录跑（比如 --self-test）时的兜底
        let exec = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/\(name).png")]
        var dir = exec
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent("Assets/\(name).png"))
            dir = dir.deletingLastPathComponent()
        }
        for url in candidates {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}

// MARK: - 自检

private func inkCount(_ rep: NSBitmapImageRep) -> Int {
    var count = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.06 { count += 1 }
        }
    }
    return count
}

private func inkBounds(_ rep: NSBitmapImageRep) -> CGRect {
    var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.06 else { continue }
            minX = min(minX, CGFloat(x)); maxX = max(maxX, CGFloat(x))
            minY = min(minY, CGFloat(y)); maxY = max(maxY, CGFloat(y))
        }
    }
    guard maxX >= minX else { return .zero }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

private func dotImage(size: Int, at point: CGPoint, radius: CGFloat) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2))
    return ctx.makeImage()
}

private func bitmapRep(_ cg: CGImage) -> NSBitmapImageRep {
    NSBitmapImageRep(cgImage: cg)
}

func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print((ok ? "ok   " : "FAIL ") + name + (detail.isEmpty ? "" : "  (\(detail))"))
        if !ok { failures += 1 }
    }

    for style in PetStyle.allCases {
        let image = PetAssets.icon(style)
        check((image?.size.width ?? 0) > 64, "素材 \(style.name) 可读",
              image.map { "\(Int($0.size.width))pt" } ?? "缺失")
    }
    guard let icon = PetAssets.icon(.claude) else {
        print("FAIL Claude 素材缺失，后续检查无法进行")
        return 1
    }

    // 按压弹簧：按下会过头，松开回到 0
    let jelly = Jelly()
    jelly.press(at: CGPoint(x: 100, y: 100))
    var peak = 0.0
    for _ in 0..<360 {
        jelly.update(1.0 / 120.0)
        peak = max(peak, jelly.bulge.value)
    }
    check(abs(jelly.bulge.value - 1) < 0.01, "按住时稳定在 1 倍放大",
          String(format: "%.3f", jelly.bulge.value))
    check(peak > 1.15, "按下时冲过头，有弹跳感", String(format: "峰值 %.2f", peak))

    jelly.drag(center: CGPoint(x: 140, y: 80), pull: CGPoint(x: 120, y: -40))
    for _ in 0..<180 { jelly.update(1.0 / 120.0) }   // 拉动量由弹簧跟随
    check(jelly.center == CGPoint(x: 140, y: 80), "放大中心跟着鼠标走")
    check(abs(jelly.pullLength - 126.5) < 1, "拉动量按位移记录",
          String(format: "%.1f", jelly.pullLength))
    check(jelly.stretchScale > 1.4, "拖动时形状被拉长",
          String(format: "x%.2f", jelly.stretchScale))

    jelly.release()
    var lowest = 0.0
    var settledAt = -1.0
    var bounces = 0
    var lastSign = 0
    for i in 0..<600 {
        jelly.update(1.0 / 120.0)
        lowest = min(lowest, jelly.bulge.value)
        let sign = jelly.bulge.value > 0.02 ? 1 : (jelly.bulge.value < -0.02 ? -1 : 0)
        if sign != 0 {
            if lastSign != 0 && sign != lastSign { bounces += 1 }
            lastSign = sign
        }
        if jelly.isSettled, settledAt < 0 { settledAt = Double(i) / 120.0 }
    }
    check(jelly.isSettled, "松开 5 秒内 Q 弹归位")
    check(abs(jelly.bulge.value) < 0.001, "归位后完全没有变形",
          String(format: "%.4f", jelly.bulge.value))
    check(jelly.pullLength < 0.5 && jelly.stretchScale < 1.001, "松手后拉动量也归零",
          String(format: "%.4f", jelly.pullLength))
    check(lowest < -0.2, "归位时会反向过冲成小凹坑", String(format: "%.2f", lowest))
    check(bounces >= 3, "松开后来回弹好几下", "\(bounces) 次过零")
    check(settledAt > 0 && settledAt < 3, "归位用时合理",
          String(format: "%.2f 秒", settledAt))

    // 拉动曲线：拉得越远越明显；靠近按下点不抖
    let curve = Jelly()
    curve.referenceSide = 128
    curve.pullX.value = 50
    let nearStretch = curve.stretchScale
    curve.pullX.value = 160
    let farStretch = curve.stretchScale
    check(farStretch > nearStretch + 0.3, "拉得越远变形越明显",
          String(format: "x%.2f → x%.2f", nearStretch, farStretch))

    // 软限位：越拉越拉不动，永远到不了硬顶
    let softNear = PetGeometry.softenPull(CGPoint(x: 60, y: 0), iconSide: 128)
    let softFar = PetGeometry.softenPull(CGPoint(x: 900, y: 0), iconSide: 128)
    check(abs(softNear.x - 60) < 5, "小幅拉动基本不打折",
          String(format: "%.0f", softNear.x))
    check(softFar.x < 128 * 1.1 && softFar.x > 128 * 1.0, "拉到头时是软限位",
          String(format: "%.1f / 上限 %.1f", softFar.x, 128 * 1.1))
    let early = PetGeometry.softenPull(CGPoint(x: 100, y: 0), iconSide: 128).x
        - PetGeometry.softenPull(CGPoint(x: 50, y: 0), iconSide: 128).x
    let late = PetGeometry.softenPull(CGPoint(x: 400, y: 0), iconSide: 128).x
        - PetGeometry.softenPull(CGPoint(x: 250, y: 0), iconSide: 128).x
    check(early > late * 3, "越靠近上限，同样一段鼠标距离变得越不明显",
          String(format: "%.1f → %.1f", early, late))

    // 越接近上限，阻尼越大
    let strain = Jelly()
    strain.press(at: .zero)
    strain.aimPull(PetGeometry.softenPull(CGPoint(x: 900, y: 0), iconSide: 128))
    for _ in 0..<180 { strain.update(1.0 / 120.0) }
    check(strain.pullX.damping > 90, "接近上限时阻尼变大",
          String(format: "%.0f", strain.pullX.damping))
    check(strain.pullLength < 128 * 1.1, "拉动量不会越过软上限",
          String(format: "%.1f", strain.pullLength))

    let steady = Jelly()
    steady.press(at: .zero)
    steady.aimPull(CGPoint(x: 40, y: 0))      // 拉出去过
    for _ in 0..<40 { steady.update(1.0 / 120.0) }
    steady.aimPull(CGPoint(x: 4, y: 2))       // 又绕回中心
    steady.pullX.value = 40
    for _ in 0..<120 { steady.update(1.0 / 120.0) }
    check(steady.pullLength < 0.5, "光标在按下点附近时不抖",
          String(format: "%.3f", steady.pullLength))
    check(steady.popLevel.value < 0.2, "整体放大淡出后不会绕回中心又长出来",
          String(format: "%.2f", steady.popLevel.value))

    // 局部放大：点在哪儿放大哪儿，别处不动
    let ciContext: CIContext = {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        return CIContext(options: [.cacheIntermediates: false,
                                   .workingColorSpace: space as Any,
                                   .outputColorSpace: space as Any])
    }()
    if let input = dotImage(size: 200, at: CGPoint(x: 60, y: 140), radius: 8) {
        let source = CIImage(cgImage: input)
        let inputBox = inkBounds(bitmapRep(input))

        if let grown = PetRenderer.distort(source, center: CGPoint(x: 60, y: 140), radius: 45,
                                           amount: 0.8, pixelScale: 1, context: ciContext) {
            let box = inkBounds(bitmapRep(grown))
            check(box.width > inputBox.width * 1.15, "按压点附近被放大",
                  String(format: "点径 %.0f → %.0f", inputBox.width, box.width))
            check(abs(box.midX - inputBox.midX) < 4 && abs(box.midY - inputBox.midY) < 4,
                  "放大的中心就是按压点",
                  String(format: "中心偏移 (%.1f, %.1f)", box.midX - inputBox.midX,
                         box.midY - inputBox.midY))
        } else {
            check(false, "bump 变形不可用")
        }

        if let far = PetRenderer.distort(source, center: CGPoint(x: 170, y: 30), radius: 30,
                                         amount: 0.8, pixelScale: 1, context: ciContext) {
            let box = inkBounds(bitmapRep(far))
            check(abs(box.width - inputBox.width) <= 1 && abs(box.height - inputBox.height) <= 1,
                  "按压点之外保持原大小",
                  String(format: "%.0f → %.0f", inputBox.width, box.width))
        }
    } else {
        check(false, "合成测试图失败")
    }

    // 真实素材：按压后确实重绘，且整体位置没跑
    let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jelly-pet-selftest", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let bounds = CGRect(x: 0, y: 0, width: Const.windowSide, height: Const.windowSide)
    if let made = PetRenderer.makeSource(icon: icon, iconSide: Const.defaultIconSide,
                                         scale: 2, bounds: bounds) {
        let idle = Jelly()
        let pressed = Jelly()
        pressed.press(at: CGPoint(x: Const.windowSide / 2, y: Const.windowSide / 2))
        pressed.bulge.value = 1
        pressed.bulge.velocity = 0

        func render(_ model: Jelly, name: String) -> NSBitmapImageRep? {
            let pixels = Int(Const.windowSide)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                             pixelsHigh: pixels, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .calibratedRGB, bytesPerRow: 0,
                                             bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            PetRenderer.draw(icon: icon, in: context.cgContext, bounds: bounds,
                             iconSide: Const.defaultIconSide, model: model,
                             source: made.image, sourceRect: made.rect,
                             pixelScale: 2, ciContext: ciContext)
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: outputDir.appendingPathComponent(name))
            }
            return rep
        }

        let pulled = Jelly()
        pulled.press(at: CGPoint(x: Const.windowSide / 2, y: Const.windowSide / 2))
        pulled.bulge.value = 1
        pulled.bulge.velocity = 0
        pulled.aimPull(CGPoint(x: -130, y: 0))
        pulled.popLevel.value = 0                 // 已经拉远，整体放大淡出
        pulled.pullX.value = -130
        pulled.pullY.value = 0

        let idleRep = render(idle, name: "idle.png")
        let pressedRep = render(pressed, name: "bulge.png")
        let pulledRep = render(pulled, name: "pull.png")
        if let idleRep, let pressedRep {
            let a = inkBounds(idleRep), b = inkBounds(pressedRep)
            check(a.width > 40 && a.height > 40, "闲置状态正常出图",
                  String(format: "%.0fx%.0f", a.width, a.height))
            let idleInk = inkCount(idleRep), pressedInk = inkCount(pressedRep)
            check(pressedInk > Int(Double(idleInk) * 1.02), "按压点附近肿起来（实心面积变大）",
                  String(format: "%d → %d", idleInk, pressedInk))
            check(abs(a.midX - b.midX) < 3 && abs(a.midY - b.midY) < 3, "按压不挪位置",
                  String(format: "中心偏移 (%.1f, %.1f)", b.midX - a.midX, b.midY - a.midY))
        } else {
            check(false, "离屏渲染失败")
        }

        if let idleRep, let pulledRep {
            let a = inkBounds(idleRep), c = inkBounds(pulledRep)
            check(c.minX < a.minX - 40, "往左拉时形状朝左边伸出去",
                  String(format: "左边界 %.0f → %.0f", a.minX, c.minX))
            check(c.maxX < a.maxX + 4, "往左拉时右边界不动",
                  String(format: "右边界 %.0f → %.0f", a.maxX, c.maxX))
        } else {
            check(false, "拉动渲染失败")
        }
    } else {
        check(false, "生成源图失败")
    }

    if failures == 0 {
        print("渲染检查图：\(outputDir.path)")
        print("PASS")
        return 0
    }
    print("\(failures) 项失败")
    return 1
}

// MARK: - 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let fallbackIcon = PetAssets.icon(.claude) else {
            let alert = NSAlert()
            alert.messageText = "找不到图标素材"
            alert.informativeText = "Assets 里缺少 claude-mark.png。请重新完整下载项目（或运行 Tools/make-icon.py 重新生成素材）。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let controller = PetController(fallbackIcon: fallbackIcon)
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let arguments = CommandLine.arguments

if arguments.contains("--self-test") {
    exit(runSelfTest())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
