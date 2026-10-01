import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let hud = HUD()
    private let pick = PickHUD()
    private let doubao = DoubaoEngine()
    private let wetype = WeTypeEngine()
    private let offline = OfflineEngine()
    private let qwen = QwenEngine()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var session: Task<Void, Never>?
    private var recording = false
    /// 点按开启的会话：静音超时自动结束
    private var autoStop = false
    private var heardVoice = false
    private var lastVoice = Date()
    private var recognizeTimeout: DispatchWorkItem?
    private var aborting = false
    private var sessionGen = 0
    private var picking = false
    private var caretAnchor: NSRect?
    private var previousApp: NSRunningApplication?
    private var pickLatest: [String: (text: String, status: String)] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        recorder.onLevel = { [weak self] v in
            DispatchQueue.main.async {
                self?.hud.level(v)
                self?.checkSilence(v)
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        hotkey.onPress = { [weak self] in
            guard let self else { return }
            if self.session != nil, !self.recording { self.abort(nil); return }
            guard self.session == nil else { return }
            if Channel.current == .all {
                self.wetype.prewarm()
                self.qwen.prewarm()
                if OfflineAssets.installed { OfflineWorker.shared.prewarm() }
                return
            }
            switch Channel.current {
            case .wetype: self.wetype.prewarm()
            case .qwen: self.qwen.prewarm()
            case .offline where OfflineAssets.installed: OfflineWorker.shared.prewarm()
            default: break
            }
        }
        hotkey.onLongPress = { [weak self] in self?.begin() }
        hotkey.onRelease = { [weak self] in
            if self?.autoStop == false { self?.end() }
        }
        hotkey.onTap = { [weak self] in
            guard let self else { return }
            if self.recording { self.end() }
            else if self.session != nil { self.abort(nil) }
            else { self.begin(autoStop: true) }
        }
        hotkey.onEscape = { [weak self] in
            guard let self, self.session != nil else { return }
            self.abort(nil)
        }
        hotkey.onPickKey = { [weak self] key in
            guard let self, self.picking || self.pick.isVisible else { return false }
            switch key {
            case .up: self.pick.move(-1)
            case .down: self.pick.move(1)
            case .enter: self.pick.confirm()
            case .escape: self.abort(nil)
            }
            return true
        }
        hotkey.start()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleSettingsShortcut(event) == true ? nil : event
        }
    }

    /// 菜单栏图标可能被刘海/菜单栏管理器藏起来，再次打开 App 即弹出设置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func begin(autoStop: Bool = false) {
        guard session == nil else { return }
        if Channel.current == .all {
            beginPick(autoStop: autoStop)
            return
        }
        let engine: ASREngine = switch Channel.current {
        case .doubao: doubao
        case .wetype: wetype
        case .qwen: qwen
        case .offline: offline
        case .all: doubao
        }
        let audio: AsyncStream<[Int16]>
        do {
            audio = try recorder.start()
        } catch {
            fail("麦克风启动失败：\(error.localizedDescription)")
            return
        }
        recording = true
        self.autoStop = autoStop
        heardVoice = false
        lastVoice = Date()
        setIcon(recording: true)
        hud.show("", listening: true)
        let typer: StreamTyper? = (UserDefaults.standard.object(forKey: "streaming") as? Bool ?? true) ? StreamTyper() : nil
        aborting = false
        sessionGen += 1
        let gen = sessionGen
        session = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await engine.run(audio: audio) { partial in
                    DispatchQueue.main.async {
                        if let typer { typer.update(partial) } else { self.hud.update(partial) }
                    }
                }
                guard self.sessionGen == gen else { return }
                self.stopRecording()
                self.recognizeTimeout?.cancel()
                if let typer {
                    // 定稿可能与流式结果不同（数字/标点整理），按差异修正；之后到达的迟到片段丢弃
                    if !text.isEmpty { typer.update(text) }
                    typer.finish()
                    self.hud.hide()
                } else if text.isEmpty {
                    self.hud.show("没有识别到内容", listening: false)
                    self.hud.hide(after: 1)
                } else {
                    self.hud.hide()
                    TextInserter.insert(text)
                }
            } catch is CancellationError {
                typer?.finish()
                self.stopRecording()
                self.recognizeTimeout?.cancel()
                if !self.aborting { self.hud.hide() }
            } catch {
                typer?.finish()
                self.stopRecording()
                self.recognizeTimeout?.cancel()
                self.fail("识别失败：\(error.localizedDescription)")
            }
            if self.sessionGen == gen {
                self.aborting = false
                self.session = nil
            }
        }
    }

    private func beginPick(autoStop: Bool) {
        let audio: AsyncStream<[Int16]>
        do {
            audio = try recorder.start()
        } catch {
            fail("麦克风启动失败：\(error.localizedDescription)")
            return
        }
        recording = true
        self.autoStop = autoStop
        heardVoice = false
        lastVoice = Date()
        setIcon(recording: true)
        hud.show("", listening: true)
        caretAnchor = Caret.bounds()
        previousApp = NSWorkspace.shared.frontmostApplication
        aborting = false
        sessionGen += 1
        let gen = sessionGen
        pickLatest = [:]
        let items: [PickItem] = Channel.engines.map { ch in
            if ch == .offline, !OfflineAssets.installed {
                return PickItem(channel: ch, status: "跳过（未下载）")
            }
            return PickItem(channel: ch, status: "识别中")
        }
        let active = items.filter { $0.status == "识别中" }.map(\.channel)
        let streams = ChannelCompare.fanout(audio, n: active.count)
        pick.onChoose = { [weak self] text in self?.finishPick(text) }
        pick.onCancel = { [weak self] in self?.abort(nil) }
        session = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { g in
                for (i, ch) in active.enumerated() {
                    let stream = streams[i]
                    g.addTask { @MainActor in await self.recognizePick(ch, stream, gen) }
                }
            }
        }
    }

    private func recognizePick(_ ch: Channel, _ stream: AsyncStream<[Int16]>, _ gen: Int) async {
        let engine: ASREngine = switch ch {
        case .doubao: doubao
        case .wetype: wetype
        case .qwen: qwen
        case .offline: offline
        case .all: doubao
        }
        do {
            let text = try await engine.run(audio: stream) { [weak self] partial in
                DispatchQueue.main.async {
                    guard let self, self.sessionGen == gen else { return }
                    self.notePick(ch, text: partial, status: "识别中")
                }
            }
            guard sessionGen == gen else { return }
            notePick(ch, text: text, status: "完成")
        } catch is CancellationError {
            if sessionGen == gen { notePick(ch, status: "已取消") }
        } catch {
            if sessionGen == gen { notePick(ch, status: error.localizedDescription) }
        }
    }

    private func notePick(_ ch: Channel, text: String? = nil, status: String? = nil) {
        var cur = pickLatest[ch.rawValue] ?? (text: "", status: "")
        if let text { cur.text = text }
        if let status { cur.status = status }
        pickLatest[ch.rawValue] = cur
        if picking { pick.update(ch, text: text, status: status) }
    }

    private func finishPick(_ text: String) {
        aborting = true
        sessionGen += 1
        recognizeTimeout?.cancel()
        session?.cancel()
        session = nil
        picking = false
        pick.hide()
        hud.hide()
        stopRecording()
        let app = previousApp
        previousApp = nil
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            TextInserter.insert(text)
        }
    }

    /// 说过话后静音超过设定时长即结束；一直没开口则 8 秒后放弃
    private func checkSilence(_ level: Float) {
        guard recording, autoStop else { return }
        if level > 0.3 {
            heardVoice = true
            lastVoice = Date()
        } else if Date().timeIntervalSince(lastVoice) > (heardVoice ? Hotkey.silence : 8) {
            end()
        }
    }

    private func end() {
        guard recording else { return }
        stopRecording()
        if Channel.current == .all {
            hud.hide()
            picking = true
            pick.show(Channel.engines.map { ch in
                if let latest = pickLatest[ch.rawValue] {
                    return PickItem(channel: ch, text: latest.text, status: latest.status)
                }
                if ch == .offline, !OfflineAssets.installed {
                    return PickItem(channel: ch, status: "跳过（未下载）")
                }
                return PickItem(channel: ch, status: "识别中")
            }, anchor: caretAnchor)
            return
        }
        hud.show("识别中…", listening: false)
        let work = DispatchWorkItem { [weak self] in self?.abort("识别超时") }
        recognizeTimeout?.cancel()
        recognizeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// 打断「识别中」：点按/再按快捷键/Esc，或 15 秒超时。message 为 nil 表示用户取消。
    private func abort(_ message: String?) {
        guard session != nil else { return }
        aborting = true
        sessionGen += 1
        recognizeTimeout?.cancel()
        session?.cancel()
        session = nil
        stopRecording()
        picking = false
        pick.hide()
        if let message {
            fail(message)
        } else {
            hud.hide()
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        autoStop = false
        recorder.stop()
        setIcon(recording: false)
    }

    private func fail(_ message: String) {
        hud.show(message, listening: false)
        hud.hide(after: 2.5)
    }

    private func setIcon(recording: Bool) {
        statusItem.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "VoiceKey")
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "长按 \(Hotkey.current.title) 说话", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for c in Channel.available {
            let item = NSMenuItem(title: c.title, action: #selector(selectChannel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = c == Channel.current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "⚠️ 需要辅助功能权限…", action: #selector(openSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectChannel(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "channel")
        if Channel.current == .offline { MainActor.assumeIsolated { OfflineAssets.shared.download() } }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "VoiceKey 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 菜单栏 App 没有「文件 → 关闭」，⌘W 不会自动关窗口
    private func handleSettingsShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return false }
        guard event.keyCode == 13 else { return false } // W
        guard let win = settingsWindow, win.isVisible, win.isKeyWindow else { return false }
        win.performClose(nil)
        return true
    }
}
