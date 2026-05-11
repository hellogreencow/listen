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
        observeWake()
        prewarmConnections()
    }

    /// On long sleep/wake cycles macOS sometimes quiets global event monitors.
    /// Re-arm the hotkey when the system wakes so it's responsive immediately.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkey.start(keyName: self.settings.hotkey)
        }
    }

    /// Pre-establish TLS connections to the configured provider hosts so the
    /// first hold-to-record doesn't pay handshake latency (~100-200 ms).
    private func prewarmConnections() {
        let hosts: [String] = [
            "https://api.elevenlabs.io",
            "https://api.openai.com",
            "https://api.groq.com",
            "https://openrouter.ai",
        ]
        for host in hosts {
            guard let url = URL(string: host) else { continue }
            Task.detached {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                req.timeoutInterval = 5
                _ = try? await URLSession.shared.data(for: req)
            }
        }
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
        case .listening: button.title = "listening..."
        case .thinking:  button.title = "thinking..."
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
        let grant = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
        grant.target = self
        menu.addItem(grant)
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
        // Microphone only — its prompt happens organically the first time
        // AVAudioRecorder records, and lives in a different pane than
        // Accessibility so it doesn't steal focus from the user's app.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // DO NOT auto-prompt or auto-open System Settings for Accessibility.
        // Every time this launched on a cdhash mismatch it stole focus away
        // from the user's frontmost app, which (a) annoyed them and (b)
        // caused synth Cmd+V to paste into System Settings instead of their
        // actual focused window. If the user needs to (re-)grant, they can
        // use the "Grant Accessibility…" menu item.
        let trusted = AXIsProcessTrusted()
        NSLog("[Listen] startup: AXIsProcessTrusted = \(trusted)")
    }

    @objc private func grantAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
        guard let url, let stt else {
            NSLog("[Listen] process: no url or no stt (url=\(url?.path ?? "nil"))")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? -1
        NSLog("[Listen] process: audio file=\(url.lastPathComponent) bytes=\(size)")
        do {
            let raw = try await stt.transcribe(url)
            NSLog("[Listen] process: stt returned \(raw.count) chars: \(raw.prefix(80))")
            var text = raw
            if let interpreter, !text.isEmpty {
                do {
                    text = try await interpreter.interpret(text, prompt: settings.cleanup_prompt)
                    NSLog("[Listen] process: interpreter returned \(text.count) chars")
                } catch {
                    NSLog("[Listen] interpreter failed: \(error.localizedDescription) — using raw")
                }
            }
            try? FileManager.default.removeItem(at: url)
            if text.isEmpty {
                notify("Empty transcription — check microphone permission")
                NSLog("[Listen] process: empty text, nothing to paste")
                return
            }
            NSLog("[Listen] process: pasting \(text.count) chars")
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
