import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let hud = HUD()
    private let doubao = DoubaoEngine()
    private let wetype = WeTypeEngine()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var session: Task<Void, Never>?
    private var recording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        hotkey.onPress = { [weak self] in
            if Channel.current == .wetype, self?.session == nil { self?.wetype.prewarm() }
        }
        hotkey.onLongPress = { [weak self] in self?.begin() }
        hotkey.onRelease = { [weak self] in self?.end() }
        hotkey.start()
    }

    private func begin() {
        guard session == nil else { return }
        let engine: ASREngine = Channel.current == .wetype ? wetype : doubao
        let audio: AsyncStream<[Int16]>
        do {
            audio = try recorder.start()
        } catch {
            fail("麦克风启动失败：\(error.localizedDescription)")
            return
        }
        recording = true
        setIcon(recording: true)
        hud.show("正在聆听…", listening: true)
        let typer: StreamTyper? = (UserDefaults.standard.object(forKey: "streaming") as? Bool ?? true) ? StreamTyper() : nil
        session = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await engine.run(audio: audio) { partial in
                    DispatchQueue.main.async {
                        if let typer { typer.update(partial) } else { self.hud.update(partial) }
                    }
                }
                self.stopRecording()
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
            } catch {
                typer?.finish()
                self.stopRecording()
                self.fail("识别失败：\(error.localizedDescription)")
            }
            self.session = nil
        }
    }

    private func end() {
        guard recording else { return }
        stopRecording()
        hud.show("识别中…", listening: false)
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
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
        for c in Channel.allCases {
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
}
