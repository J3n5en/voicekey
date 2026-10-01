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

final class HUDModel: ObservableObject {
    @Published var text = ""
    @Published var listening = false
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.listening ? "mic.fill" : "waveform")
                .foregroundStyle(model.listening ? .red : .secondary)
                .symbolEffect(.pulse, isActive: model.listening)
            Text(model.text)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: 480, alignment: .leading)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        layout()
        panel.orderFrontRegardless()
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
