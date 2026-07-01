// Driver for the SwiftUI vMLX app via the macOS Accessibility API.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - AX helpers

func axApp(pid: pid_t) -> AXUIElement {
    AXUIElementCreateApplication(pid)
}

func ensureTrust() {
    let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
    if !AXIsProcessTrustedWithOptions(opts) {
        FileHandle.standardError.write(Data("axdriver: not yet trusted — grant Accessibility to Terminal in System Settings, then re-run.\n".utf8))
    }
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func childrenOf(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func roleOf(_ el: AXUIElement) -> String { (attr(el, kAXRoleAttribute) as? String) ?? "?" }
func titleOf(_ el: AXUIElement) -> String { (attr(el, kAXTitleAttribute) as? String) ?? "" }
func valueOf(_ el: AXUIElement) -> String {
    let v = attr(el, kAXValueAttribute)
    if let s = v as? String { return s }
    return ""
}
func identOf(_ el: AXUIElement) -> String {
    (attr(el, kAXIdentifierAttribute) as? String) ?? ""
}
func descOf(_ el: AXUIElement) -> String {
    (attr(el, kAXDescriptionAttribute) as? String) ?? ""
}

func matches(_ el: AXUIElement, _ needle: String) -> Bool {
    identOf(el) == needle || titleOf(el) == needle || descOf(el) == needle || valueOf(el) == needle
}

func isMenuElement(_ el: AXUIElement) -> Bool {
    switch roleOf(el) {
    case "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem":
        return true
    default:
        return false
    }
}

func walk(_ el: AXUIElement, depth: Int = 0, visit: (AXUIElement, Int) -> Bool) {
    if !visit(el, depth) { return }
    for c in childrenOf(el) {
        walk(c, depth: depth + 1, visit: visit)
    }
}

// MARK: - Commands

func cmdDump(pid: pid_t) {
    let app = axApp(pid: pid)
    walk(app) { el, depth in
        let r = roleOf(el)
        let t = titleOf(el)
        let v = valueOf(el)
        let i = identOf(el)
        let d = descOf(el)
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)\(r)"
        if !t.isEmpty { line += " title=\"\(t.prefix(60))\"" }
        if !i.isEmpty { line += " id=\"\(i.prefix(40))\"" }
        if !d.isEmpty { line += " desc=\"\(d.prefix(40))\"" }
        if !v.isEmpty && r != "AXGroup" { line += " value=\"\(v.prefix(40))\"" }
        print(line)
        return true
    }
}

func find(pid: pid_t, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    let app = axApp(pid: pid)
    var hit: AXUIElement?
    walk(app) { el, _ in
        if predicate(el) { hit = el; return false }
        return true
    }
    return hit
}

func findAll(pid: pid_t, predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    let app = axApp(pid: pid)
    var hits: [AXUIElement] = []
    walk(app) { el, _ in
        if predicate(el) {
            hits.append(el)
        }
        return true
    }
    return hits
}

func cmdClick(pid: pid_t, ident: String) -> Int32 {
    let hits = findAll(pid: pid, predicate: { !isMenuElement($0) && matches($0, ident) })
    guard !hits.isEmpty else {
        FileHandle.standardError.write(Data("axdriver: no element matched \"\(ident)\"\n".utf8))
        return 2
    }

    var firstFailure: AXError?
    for el in hits {
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r == .success {
            return 0
        }
        if firstFailure == nil {
            firstFailure = r
        }
    }

    FileHandle.standardError.write(Data("axdriver: AXPressAction failed for all matches: \(firstFailure?.rawValue ?? -1)\n".utf8))
    return 3
}

func keyCode(for key: String) -> CGKeyCode? {
    switch key.lowercased() {
    case "a": return 0
    case "s": return 1
    case "d": return 2
    case "f": return 3
    case "h": return 4
    case "g": return 5
    case "z": return 6
    case "x": return 7
    case "c": return 8
    case "v": return 9
    case "b": return 11
    case "q": return 12
    case "w": return 13
    case "e": return 14
    case "r": return 15
    case "y": return 16
    case "t": return 17
    case "1": return 18
    case "2": return 19
    case "3": return 20
    case "4": return 21
    case "6": return 22
    case "5": return 23
    case "=": return 24
    case "9": return 25
    case "7": return 26
    case "-": return 27
    case "8": return 28
    case "0": return 29
    case "]": return 30
    case "o": return 31
    case "u": return 32
    case "[": return 33
    case "i": return 34
    case "p": return 35
    case "l": return 37
    case "j": return 38
    case "'": return 39
    case "k": return 40
    case ";": return 41
    case "\\": return 42
    case ",": return 43
    case "/": return 44
    case "n": return 45
    case "m": return 46
    case ".": return 47
    default: return nil
    }
}

func flags(from raw: String) -> CGEventFlags {
    var flags = CGEventFlags()
    for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
        switch token {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}

func cmdKey(pid: pid_t, key: String, modifiers: String) -> Int32 {
    guard let code = keyCode(for: key) else {
        FileHandle.standardError.write(Data("axdriver: unsupported key \"\(key)\"\n".utf8))
        return 2
    }
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    usleep(80_000)
    let source = CGEventSource(stateID: .hidSystemState)
    let flags = flags(from: modifiers)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else { return 3 }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    usleep(50_000)
    up.postToPid(pid)
    return 0
}

func cmdType(pid: pid_t, ident: String, text: String) -> Int32 {
    guard let el = find(pid: pid, predicate: { !isMenuElement($0) && matches($0, ident) }) else {
        FileHandle.standardError.write(Data("axdriver: no element matched \"\(ident)\"\n".utf8))
        return 2
    }
    // Focus first
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef)
    let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
    return r == .success ? 0 : 4
}

func cmdShot(pid: pid_t, outPath: String) -> Int32 {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
    func area(_ window: [String: Any]) -> Double {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = number(bounds["Width"]),
              let height = number(bounds["Height"])
        else { return 0 }
        return width * height
    }
    func layer(_ window: [String: Any]) -> Int {
        Int(number(window[kCGWindowLayer as String]) ?? 0)
    }
    func alpha(_ window: [String: Any]) -> Double {
        number(window[kCGWindowAlpha as String]) ?? 1
    }
    let appWindows = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    let sizableWindows = appWindows.filter { area($0) >= 10_000 && alpha($0) > 0 }
    let layerZeroWindows = sizableWindows.filter { layer($0) == 0 }
    let candidates = (layerZeroWindows.isEmpty ? sizableWindows : layerZeroWindows)
        .sorted { area($0) > area($1) }
    guard let first = candidates.first, let wid = first[kCGWindowNumber as String] as? CGWindowID else {
        FileHandle.standardError.write(Data("axdriver: no on-screen window for pid=\(pid)\n".utf8))
        return 2
    }
    guard let cg = CGWindowListCreateImage(.null, [.optionIncludingWindow], wid, [.bestResolution, .boundsIgnoreFraming]) else {
        FileHandle.standardError.write(Data("axdriver: CGWindowListCreateImage failed (Screen Recording perm may be required on macOS 14+)\n".utf8))
        return 3
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 4 }
    do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { return 5 }
    print("wrote \(outPath) (\(cg.width)x\(cg.height))")
    return 0
}

func mainWindowInfo(pid: pid_t) -> [String: Any]? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
    func area(_ window: [String: Any]) -> Double {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = number(bounds["Width"]),
              let height = number(bounds["Height"])
        else { return 0 }
        return width * height
    }
    func layer(_ window: [String: Any]) -> Int {
        Int(number(window[kCGWindowLayer as String]) ?? 0)
    }
    func alpha(_ window: [String: Any]) -> Double {
        number(window[kCGWindowAlpha as String]) ?? 1
    }
    let appWindows = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    let sizableWindows = appWindows.filter { area($0) >= 10_000 && alpha($0) > 0 }
    let layerZeroWindows = sizableWindows.filter { layer($0) == 0 }
    return (layerZeroWindows.isEmpty ? sizableWindows : layerZeroWindows)
        .sorted { area($0) > area($1) }
        .first
}

func cmdScroll(pid: pid_t, lines: Int32) -> Int32 {
    func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        return nil
    }
    guard let window = mainWindowInfo(pid: pid),
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let x = number(bounds["X"]),
          let y = number(bounds["Y"]),
          let width = number(bounds["Width"]),
          let height = number(bounds["Height"])
    else {
        FileHandle.standardError.write(Data("axdriver: no on-screen window for pid=\(pid)\n".utf8))
        return 2
    }
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    let source = CGEventSource(stateID: .hidSystemState)
    let point = CGPoint(x: x + width * 0.55, y: y + height * 0.56)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
    guard let scroll = CGEvent(
        scrollWheelEvent2Source: source,
        units: .line,
        wheelCount: 1,
        wheel1: lines,
        wheel2: 0,
        wheel3: 0
    ) else {
        return 3
    }
    scroll.post(tap: .cghidEventTap)
    usleep(120_000)
    return 0
}

func cmdWait(pid: pid_t, ident: String, timeoutSec: Double = 10) -> Int32 {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        if find(pid: pid, predicate: { !isMenuElement($0) && matches($0, ident) }) != nil {
            return 0
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    FileHandle.standardError.write(Data("axdriver: timed out waiting for \"\(ident)\"\n".utf8))
    return 6
}

func cmdGrep(pid: pid_t, needle: String) {
    let app = axApp(pid: pid)
    walk(app) { el, _ in
        guard !isMenuElement(el) else { return true }
        let blob = "\(roleOf(el)) \(titleOf(el)) \(identOf(el)) \(descOf(el)) \(valueOf(el))"
        if blob.localizedCaseInsensitiveContains(needle) {
            print("\(roleOf(el)) title=\"\(titleOf(el))\" id=\"\(identOf(el))\" desc=\"\(descOf(el))\" value=\"\(valueOf(el).prefix(80))\"")
        }
        return true
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    usage:
      vmlx-axdriver dump <pid>
      vmlx-axdriver grep <pid> <needle>
      vmlx-axdriver click <pid> <id-or-title>
      vmlx-axdriver key   <pid> <key> [command,shift,option,control]
      vmlx-axdriver type  <pid> <id-or-title> "text"
      vmlx-axdriver scroll <pid> <lines>
      vmlx-axdriver shot  <pid> <out.png>
      vmlx-axdriver wait  <pid> <id-or-title> [timeout=10]
    """)
    exit(1)
}

ensureTrust()
let cmd = args[1]
guard let pid = pid_t(args[2]) else { print("bad pid"); exit(1) }
let rest = Array(args.dropFirst(3))

switch cmd {
case "dump":  cmdDump(pid: pid)
case "grep":  guard rest.count >= 1 else { exit(1) }; cmdGrep(pid: pid, needle: rest[0])
case "click": guard rest.count >= 1 else { exit(1) }; exit(cmdClick(pid: pid, ident: rest[0]))
case "key":   guard rest.count >= 1 else { exit(1) }; exit(cmdKey(pid: pid, key: rest[0], modifiers: rest.count >= 2 ? rest[1] : ""))
case "type":  guard rest.count >= 2 else { exit(1) }; exit(cmdType(pid: pid, ident: rest[0], text: rest[1]))
case "scroll":
    guard rest.count >= 1, let lines = Int32(rest[0]) else { exit(1) }
    exit(cmdScroll(pid: pid, lines: lines))
case "shot":  guard rest.count >= 1 else { exit(1) }; exit(cmdShot(pid: pid, outPath: rest[0]))
case "wait":
    guard rest.count >= 1 else { exit(1) }
    let to = rest.count >= 2 ? (Double(rest[1]) ?? 10) : 10
    exit(cmdWait(pid: pid, ident: rest[0], timeoutSec: to))
default:
    print("unknown command: \(cmd)"); exit(1)
}
