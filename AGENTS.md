# Listen — Notes for Future Agents

A running log of the painful, hard-won facts about this codebase and the macOS
realities around it. Read this BEFORE making changes. Most of these were
learned by breaking the user's working app multiple times in one session.

## Hard rules

1. **Never rebuild "just to clean up" right before a commit/push.** Every
   `swiftc` invocation produces a binary with a new cdhash. macOS TCC
   (Accessibility, Microphone, Input Monitoring) silently revokes its grant
   when cdhash changes, UNLESS the codesign designated requirement is pinned
   to a stable identity (see "Code signing" below). A rebuild that strips
   debug `NSLog`s for cosmetic reasons is not worth re-triggering permission
   prompts for the user.

2. **Never tell the user to re-toggle Accessibility unless you have a real
   reason.** Each prompt erodes trust. If they have already approved the app
   once and it stopped working, the answer is almost never "re-approve" — it
   is usually a code-signing or launch-context issue you introduced.

3. **Don't ship a LaunchAgent for auto-start without first verifying that the
   launchd-spawned process can deliver synthesized Cmd+V.** It usually
   cannot. See "Synth Cmd+V" below.

4. **Don't add new permission prompts** (Automation/AppleEvents, Input
   Monitoring, Full Disk Access) when an existing permission would do the
   job. The user has limited tolerance for the privacy pane.

5. **When the user says "it was working until you broke it", believe them.**
   Retrace your edits and your rebuilds before "diagnosing" anything new.

## Code signing (the cdhash problem)

- `py2app` and `swiftc` produce ad-hoc-signed bundles by default. Every
  rebuild has a new cdhash. macOS TCC keys grants on cdhash by default, so
  every rebuild silently invalidates every prior grant. This single fact is
  responsible for ~80% of "the permissions reset themselves" pain.

- Fix: sign with a stable self-signed cert *and* pin the designated
  requirement to the cert's subject CN instead of the cdhash:

  ```
  designated => identifier "com.listen.app" and
                certificate leaf[subject.CN] = "Listen Local Signing"
  ```

  After the user grants once with this DR, subsequent rebuilds (same cert,
  same DR) keep the grant. `build.sh` already does this — do not regress it.

- The self-signed cert lives in the user's login keychain. It's created on
  first `./build.sh` run via openssl + `security import`. If you ever need to
  recreate it, use `openssl pkcs12 -export -legacy …` — the modern PKCS12
  format is unreadable by macOS `security`.

- Don't sign with `--options runtime` (hardened runtime). Hardened runtime
  without notarization + entitlements silently neuters CGEventTap and other
  privileged APIs. Listen does not use hardened runtime.

## Hotkey: which API to use

- `pynput` / `CGEventTap` (used by the original Python version) requires
  **Input Monitoring** TCC. Don't use it.

- `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` for
  modifier-hold hotkeys requires **Accessibility** TCC (no Input Monitoring).
  This is what Superwhisper and Wispr Flow's Electron framework use. We do
  the same.

- For function keys (F13–F19) we use the same NSEvent global monitor with
  `.keyDown` / `.keyUp`. Same Accessibility-only requirement.

- For chord shortcuts (e.g. Cmd+Shift+Space) the right API is Carbon's
  `RegisterEventHotKey`. We don't use it yet but it's the right choice if
  ever added — needs no TCC permission.

- The user's keyboard is a modern Apple compact (MacBook built-in / Magic
  Keyboard) with **no Right Control key**. Default hotkey is `alt_r`
  (Right Option), which is the rightmost modifier they actually have.
  Do not default to `ctrl_r`.

- Modifier `flagsChanged` events report `event.keyCode` = the virtual
  keycode of the physical key that changed. Mapping:
  - kVK_RightShift   = 60
  - kVK_RightOption  = 61
  - kVK_RightControl = 62
  - kVK_Function     = 63

## Synth Cmd+V (the paste delivery problem)

Symptoms: clipboard write works, transcribed text ends up on pasteboard, but
synthesized Cmd+V does not appear to land in the focused app.

Known triggers:

- **LaunchAgent-spawned processes have their own "responsible process"
  attribution.** Synth events posted via `CGEvent.post(.cghidEventTap)` from
  a launchd-managed process can be silently dropped by macOS even when the
  bundle's own Accessibility grant is intact. Shell-spawned (inherits parent
  responsibility) works; `open`-launched (LaunchServices) is unreliable;
  LaunchAgent is the worst of the three.

- **Clipboard-restore races the paste.** Original code restored the user's
  prior clipboard 300 ms after writing the transcript. The synth Cmd+V was
  queued in the OS event stream and didn't fire in the focused app until
  after the restore, so paste would paste the *prior* content (or nothing).
  Fix: do NOT restore. Leave the transcript on the clipboard. If synth Cmd+V
  delivers, great; if not, the user can manually Cmd+V to get the text.
  See `Paster.swift`.

Posting mechanism that's currently in use:

```swift
let src = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
let up   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
down?.flags = .maskCommand
up?.flags = .maskCommand
down?.post(tap: .cghidEventTap)
up?.post(tap: .cghidEventTap)
```

Things that may help when synth Cmd+V isn't delivering (not yet
confirmed in this codebase):

- Try `CGEventSource(stateID: .combinedSessionState)` or `nil` source.
- Try posting to `.cgSessionEventTap` instead of `.cghidEventTap`.
- Insert a short `usleep` between keyDown and keyUp.
- Last-resort: AppleScript via `NSAppleScript` — needs a one-time
  "Listen wants to control System Events" prompt under Automation, then
  bulletproof. NSAppleEventsUsageDescription is already declared in
  `Info.plist` for this.

## Auto-start at login

- `LaunchAgent` plist at `~/Library/LaunchAgents/com.listen.app.plist` is
  the obvious choice but breaks synth Cmd+V (see above). Removed.

- Correct path for auto-start without breaking paste: `SMAppService` from
  the ServiceManagement framework. Listen registers itself as a Login Item
  through that API; user manages it via System Settings → General → Login
  Items. The process is launched by LaunchServices, not launchd, so synth
  events behave the same as a Dock-clicked launch. Not implemented yet.

## Settings & UX

- Config schema is preserved at `~/.listen/config.json` exactly as the
  original Python app used it, so users don't lose API keys when migrating.

- Settings UI is SwiftUI with a sidebar (`SettingsView.swift`). The Python
  version's JSON-textarea hack was unacceptable to the user and Kimi was
  wrong to remove all custom UI — `rumps.Window` would have been the right
  pivot then. We don't use rumps anymore.

- Don't conflate "this works for me" with "the user can use it". The user
  said the JSON-textarea UI was "shit" and they were right. Settings UX
  matters as much as core functionality for a competitor to Wispr Flow.

## Provider stale-model gotchas

- OpenRouter model IDs change. `google/gemini-flash-1.5` was the default in
  the old Python config and now 404s. Default to `openai/gpt-4o-mini` or
  re-check the current Gemini Flash ID before suggesting one.

- ElevenLabs Scribe (`scribe_v1`) is the default STT and works well, but
  is ~3× slower than Groq Whisper-large-v3 for short clips. For latency-
  critical users, recommend Groq.

## Diagnostic discipline

- Always have the running app log its key state transitions to a file
  (`/tmp/listen.err.log` via stderr) when iterating. Trying to debug
  behavior without runtime logs wastes the user's time.

- Before changing code in response to a user complaint, look at the log
  first. Multiple times in this session, the log proved the app was doing
  exactly the right thing and the bug was elsewhere (e.g. clipboard race,
  wrong physical key, stale OpenRouter model).

## Behavioral lessons about working with this user

- The user is technical and impatient. Give them one diagnostic test or
  one fix per turn, not a wall of theory.

- They do not want plans, options, or trade-off tables when they're angry.
  They want the broken thing fixed with the smallest possible change.

- Permission re-grants are a hard "no" once you've already used the budget.
  Find another way.

- If they say something is "shit" or "embarrassing", they mean it. Don't
  defend the existing implementation — improve it.

- The "ship" command from the user means commit + push. It does not mean
  "polish first, then commit". Polish AFTER ship.
