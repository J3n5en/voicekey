import AppKit
import SwiftUI

/// 监听修饰键：按下超过阈值才算长按开始；阈值内按了别的键视为组合键，放弃
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onRelease: () -> Void = {}
    private static let threshold: TimeInterval = 0.3
    private var tap: CFMachPort?
    private var down = false
    private var active = false
    private var timer: Timer?

    /// 无权限时创建会失败，定时重试直到用户授权
    func start() {
        if install() { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.install() ?? true { t.invalidate() }
        }
    }

    private func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if down, !active { cancelPending() }
        case .flagsChanged:
            let key = Hotkey.current
            guard event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode else {
                if down, !active { cancelPending() }
                return
            }
            let pressed = event.flags.contains(key.flag)
            if pressed, !down {
                down = true
                onPress()
                timer = Timer.scheduledTimer(withTimeInterval: Self.threshold, repeats: false) { [weak self] _ in
                    guard let self, self.down else { return }
                    self.active = true
                    self.onLongPress()
                }
            } else if !pressed, down {
                down = false
                timer?.invalidate()
                if active {
                    active = false
                    onRelease()
                }
            }
        default: break
        }
    }

    private func cancelPending() {
        timer?.invalidate()
        timer = nil
    }
}

enum TextInserter {
    /// 借剪贴板 + ⌘V 上屏，随后恢复原剪贴板
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let change = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: isDown)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pb.changeCount == change, !saved.isEmpty else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }
}

/// 边说边上屏：与已打出的文本比对，退格删掉分歧部分再补打新内容（不经剪贴板）
final class StreamTyper {
    private var typed: [Character] = []
    private var done = false
    /// 私有事件源：不混入用户仍按着的修饰键
    private let source = CGEventSource(stateID: .privateState)

    func update(_ text: String) {
        guard !done else { return }
        let next = Array(text)
        var common = 0
        while common < typed.count, common < next.count, typed[common] == next[common] { common += 1 }
        for _ in common..<typed.count { key(51, nil) }
        let tail = String(next[common...])
        if !tail.isEmpty {
            let units = Array(tail.utf16)
            for i in stride(from: 0, to: units.count, by: 20) { key(0, Array(units[i..<min(i + 20, units.count)])) }
        }
        typed = next
    }

    func finish() { done = true }

    private func key(_ code: CGKeyCode, _ unicode: [UniChar]?) {
        for isDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
            e.flags = []
            if let unicode { e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            e.post(tap: .cghidEventTap)
        }
    }
}

final class HUDModel: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var level: CGFloat = 0

    /// 起音快、释放慢，避免波形抖动
    func push(_ raw: Float) {
        let v = CGFloat(raw)
        level = v > level ? level * 0.3 + v * 0.7 : level * 0.85 + v * 0.15
    }
}

/// 多层正弦叠加，振幅随音量变化，两端收敛
private struct VoiceWave: View {
    var level: CGFloat
    private let layers: [(freq: CGFloat, speed: CGFloat, scale: CGFloat, opacity: Double)] = [
        (1.5, 5.0, 1.0, 0.95), (2.2, -3.6, 0.7, 0.55), (1.0, 2.4, 0.5, 0.35),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = CGFloat(context.date.timeIntervalSinceReferenceDate)
            Canvas { ctx, size in
                let mid = size.height / 2
                let amp = (0.06 + level * 0.94) * (mid - 1)
                for layer in layers {
                    ctx.opacity = layer.opacity
                    var path = Path()
                    stride(from: CGFloat(0), through: size.width, by: 1).forEach { x in
                        let p = x / size.width
                        let envelope = pow(sin(.pi * p), 2)
                        let y = mid + sin(p * .pi * 2 * layer.freq + t * layer.speed) * amp * layer.scale * envelope
                        x == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                    ctx.stroke(path, with: .linearGradient(
                        Gradient(colors: [.cyan, .blue, .purple, .pink]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .frame(width: 140, height: 34)
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            if model.listening {
                VoiceWave(level: model.level)
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
            if !model.text.isEmpty {
                Text(model.text)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: 480, alignment: .leading)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}

/// 屏幕底部居中的浮层，不抢焦点
final class HUD {
    private let model = HUDModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ text: String, listening: Bool) {
        hideWork?.cancel()
        model.text = text
        model.listening = listening
        model.level = 0
        layout()
        panel.orderFrontRegardless()
    }

    func level(_ value: Float) {
        guard model.listening else { return }
        model.push(value)
    }

    func update(_ text: String) {
        guard panel.isVisible, !text.isEmpty else { return }
        model.text = text
        layout()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func layout() {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 80, width: size.width, height: size.height), display: true)
    }
}
