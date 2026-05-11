import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = Hotkey()
    private let recorder = Recorder()
    private var settings = SettingsStore.load()
    private var stt: STTProvider?
    private var interpreter: Interpreter?
    private var settingsWindow: NSWindow?
    private var state: State = .idle { didSet { renderStatus() } }

    enum State { case idle, listening, thinking }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        reloadProviders()
        startHotkey()
        ensurePermissionsOnFirstRun()
    }

    // MARK: - Status bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderStatus()
        statusItem.menu = buildMenu()
    }

    private func renderStatus() {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:      button.title = "Listen"
        case .listening: button.title = "● listening…"
        case .thinking:  button.title = "thinking…"
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(showPrefs), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        let test = NSMenuItem(title: "Test Recording (3s)", action: #selector(testRecord), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        let reveal = NSMenuItem(title: "Reveal Config File", action: #selector(revealConfig), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Listen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    // MARK: - Providers / hotkey

    private func reloadProviders() {
        do {
            stt = try ProviderFactory.stt(settings)
        } catch {
            stt = nil
            NSLog("[Listen] stt init failed: \(error.localizedDescription)")
        }
        do {
            interpreter = try ProviderFactory.interpreter(settings)
        } catch {
            interpreter = nil
            NSLog("[Listen] interpreter init failed: \(error.localizedDescription)")
        }
    }

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.onPress() }
        hotkey.onRelease = { [weak self] in self?.onRelease() }
        hotkey.start(keyName: settings.hotkey)
    }

    private func ensurePermissionsOnFirstRun() {
        // Microphone: prompts automatically when AVAudioRecorder starts.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Accessibility: required for NSEvent.addGlobalMonitorForEvents to
        // actually deliver keyboard events on macOS 10.15+. This is the
        // same permission Superwhisper uses (and labels "Needed to paste").
        // Passing prompt=true shows the system dialog the first time only.
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [prompt: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSLog("[Listen] Accessibility not granted; hotkey events will be silently dropped until granted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    // MARK: - Actions

    @objc private func showPrefs() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsModel(settings) { [weak self] new in
            guard let self else { return }
            self.settings = new
            SettingsStore.save(new)
            self.reloadProviders()
            self.hotkey.start(keyName: new.hotkey)
        }
        let host = NSHostingController(rootView: SettingsView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "Listen — Preferences"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.setContentSize(NSSize(width: 720, height: 520))
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = WindowCloser.shared
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.url])
    }

    @objc private func testRecord() {
        onPress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.onRelease() }
    }

    // MARK: - Recording flow

    private func onPress() {
        guard state == .idle else { return }
        guard let stt else {
            notify("No STT provider configured — open Preferences.")
            return
        }
        _ = stt
        do {
            try recorder.start()
            state = .listening
        } catch {
            notify("Mic error: \(error.localizedDescription)")
        }
    }

    private func onRelease() {
        guard state == .listening else { return }
        let url = recorder.stop()
        state = .thinking
        Task { await self.process(url) }
    }

    private func process(_ url: URL?) async {
        defer { Task { @MainActor in self.state = .idle } }
        guard let url, let stt else { return }
        do {
            let raw = try await stt.transcribe(url)
            var text = raw
            if let interpreter, !text.isEmpty {
                text = (try? await interpreter.interpret(text, prompt: settings.cleanup_prompt)) ?? text
            }
            try? FileManager.default.removeItem(at: url)
            if text.isEmpty { return }
            await MainActor.run {
                Paster.paste(text, restoreClipboard: true)
            }
        } catch {
            notify("Transcription failed: \(error.localizedDescription)")
            NSLog("[Listen] process error: \(error)")
        }
    }

    // MARK: - User notifications via menubar title

    private func notify(_ msg: String) {
        guard let button = statusItem.button else { return }
        let prior = button.title
        button.title = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            button.title = prior
        }
    }
}

/// Single delegate that nils out our settings window reference on close so
/// reopening rebuilds it fresh.
@MainActor
final class WindowCloser: NSObject, NSWindowDelegate {
    static let shared = WindowCloser()
    func windowWillClose(_ notification: Notification) {
        if let app = NSApp.delegate as? AppDelegate {
            // No-op: window keeps reference via isReleasedWhenClosed=false.
            _ = app
        }
    }
}
