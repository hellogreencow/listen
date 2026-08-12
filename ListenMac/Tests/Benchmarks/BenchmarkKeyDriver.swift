import AppKit
import ApplicationServices
import CoreGraphics

enum DriverError: Error { case usage, appMissing, eventCreation, audioFailed }

struct Modifier {
    let keyCode: CGKeyCode
    let flag: CGEventFlags

    static func named(_ name: String) throws -> Modifier {
        switch name {
        case "right-option": return Modifier(keyCode: 61, flag: .maskAlternate)
        case "right-command": return Modifier(keyCode: 54, flag: .maskCommand)
        default: throw DriverError.usage
        }
    }
}

enum Trigger {
    case hold(Modifier)
    case toggle(Modifier)
    case deepLink(String)

    static func named(_ name: String) throws -> Trigger {
        if name == "fn-toggle" {
            return .toggle(Modifier(keyCode: 63, flag: .maskSecondaryFn))
        }
        if name == "superwhisper-deeplink" {
            return .deepLink("superwhisper://record")
        }
        return .hold(try Modifier.named(name))
    }
}

func openInBackground(_ url: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", url]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw DriverError.eventCreation }
}

func post(_ modifier: Modifier, down: Bool) throws {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: modifier.keyCode,
        keyDown: down
    ) else { throw DriverError.eventCreation }
    event.flags = down ? modifier.flag : []
    event.post(tap: .cghidEventTap)
}

guard CommandLine.arguments.count == 4 else { throw DriverError.usage }
let receiverBundleID = CommandLine.arguments[1]
let trigger = try Trigger.named(CommandLine.arguments[2])
let audioURL = URL(fileURLWithPath: CommandLine.arguments[3])

guard let receiver = NSRunningApplication.runningApplications(
    withBundleIdentifier: receiverBundleID
).first else { throw DriverError.appMissing }
let focusDeadline = Date().addingTimeInterval(3)
repeat {
    receiver.activate(options: [.activateAllWindows])
    let receiverElement = AXUIElementCreateApplication(receiver.processIdentifier)
    AXUIElementSetAttributeValue(
        receiverElement,
        kAXFrontmostAttribute as CFString,
        kCFBooleanTrue
    )
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == receiverBundleID { break }
    Thread.sleep(forTimeInterval: 0.05)
} while Date() < focusDeadline
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == receiverBundleID else {
    throw DriverError.appMissing
}
Thread.sleep(forTimeInterval: 0.30)

let pasteboard = NSPasteboard.general
let sentinel = "LISTEN_BENCHMARK_SENTINEL_\(UUID().uuidString)"
pasteboard.clearContents()
pasteboard.setString(sentinel, forType: .string)
let receiverLogURL = URL(fileURLWithPath: "/tmp/listen-benchmark-receiver.jsonl")
try Data().write(to: receiverLogURL, options: .atomic)

switch trigger {
case .hold(let modifier):
    try post(modifier, down: true)
case .toggle(let key):
    try post(key, down: true)
    Thread.sleep(forTimeInterval: 0.08)
    try post(key, down: false)
case .deepLink(let url):
    try openInBackground(url)
}
Thread.sleep(forTimeInterval: 0.35)

let player = Process()
player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
player.arguments = [audioURL.path]
try player.run()
player.waitUntilExit()
guard player.terminationStatus == 0 else { throw DriverError.audioFailed }

Thread.sleep(forTimeInterval: 0.20)
switch trigger {
case .hold(let modifier):
    try post(modifier, down: false)
case .toggle(let key):
    try post(key, down: true)
    Thread.sleep(forTimeInterval: 0.08)
    try post(key, down: false)
case .deepLink(let url):
    try openInBackground(url)
}
let release = ProcessInfo.processInfo.systemUptime
let frontmostAtRelease = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

let deadline = release + 20
var pasteUptime: Double?
var transcript: String?
while ProcessInfo.processInfo.systemUptime < deadline {
    if let value = pasteboard.string(forType: .string),
       !value.isEmpty, value != sentinel {
        pasteUptime = ProcessInfo.processInfo.systemUptime
        transcript = value
        break
    }
    Thread.sleep(forTimeInterval: 0.005)
}

var receiverUptime: Double?
var receiverText: String?
while ProcessInfo.processInfo.systemUptime < deadline {
    if let data = try? Data(contentsOf: receiverLogURL), !data.isEmpty,
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        receiverUptime = object["uptime"] as? Double
        receiverText = object["text"] as? String
        break
    }
    Thread.sleep(forTimeInterval: 0.005)
}

let payload: [String: Any] = [
    "release_uptime": release,
    "paste_uptime": pasteUptime as Any,
    "latency_ms": pasteUptime.map { Int(($0 - release) * 1_000) } as Any,
    "transcript": transcript as Any,
    "end_to_end_ms": receiverUptime.map { Int(($0 - release) * 1_000) } as Any,
    "pasted_text": receiverText as Any,
    "frontmost_at_release": frontmostAtRelease,
    "frontmost_at_paste": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
]
let output = try JSONSerialization.data(withJSONObject: payload)
print(String(decoding: output, as: UTF8.self))
