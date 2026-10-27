import Foundation
import IOKit
import Darwin

// MARK: - SMC (AppleSMC) — read/write fan mode + target RPM

private struct SMCVersion {
  var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0
  var reserved: UInt8 = 0
  var release: UInt16 = 0
}

private struct SMCPLimitData {
  var version: UInt16 = 0, length: UInt16 = 0
  var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
  var dataSize: UInt32 = 0
  var dataType: UInt32 = 0
  var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private let kEmptyBytes: SMCBytes = (
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

private struct SMCParamStruct {
  var key: UInt32 = 0
  var vers = SMCVersion()
  var pLimitData = SMCPLimitData()
  var keyInfo = SMCKeyInfoData()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: SMCBytes = kEmptyBytes
}

private let kSMCHandleYPCEvent: UInt32 = 2
private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9

final class SMCClient {
  struct KeyInfo {
    var dataSize: UInt32
    var dataType: UInt32
    var typeString: String {
      let v = dataType
      let chars: [UInt8] = [
        UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
      ]
      return String(bytes: chars, encoding: .ascii) ?? "????"
    }
  }

  private var conn: io_connect_t = 0

  @discardableResult
  func open() -> Bool {
    guard conn == 0 else { return true }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    return IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS
  }

  func close() {
    if conn != 0 { IOServiceClose(conn); conn = 0 }
  }

  deinit { close() }

  static func fourCC(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for char in string.utf8.prefix(4) { result = (result << 8) | UInt32(char) }
    return result
  }

  private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
    guard conn != 0 else { return nil }
    var output = SMCParamStruct()
    let size = MemoryLayout<SMCParamStruct>.stride
    var outSize = size
    let ret = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &input, size, &output, &outSize)
    return ret == KERN_SUCCESS ? output : nil
  }

  func keyInfo(_ key: String) -> KeyInfo? {
    var input = SMCParamStruct()
    input.key = SMCClient.fourCC(key)
    input.data8 = kSMCGetKeyInfo
    guard let out = call(&input), out.result == 0 else { return nil }
    return KeyInfo(dataSize: out.keyInfo.dataSize, dataType: out.keyInfo.dataType)
  }

  func readData(_ key: String) -> (info: KeyInfo, bytes: [UInt8])? {
    guard let info = keyInfo(key) else { return nil }
    var input = SMCParamStruct()
    input.key = SMCClient.fourCC(key)
    input.keyInfo.dataSize = info.dataSize
    input.keyInfo.dataType = info.dataType
    input.data8 = kSMCReadKey
    guard let out = call(&input), out.result == 0 else { return nil }
    let count = min(Int(info.dataSize), 32)
    let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(count)) }
    return (info, bytes)
  }

  @discardableResult
  func writeData(_ key: String, bytes: [UInt8]) -> Bool {
    guard let info = keyInfo(key) else { return false }
    var input = SMCParamStruct()
    input.key = SMCClient.fourCC(key)
    input.keyInfo.dataSize = info.dataSize
    input.keyInfo.dataType = info.dataType
    input.data8 = kSMCWriteKey
    withUnsafeMutableBytes(of: &input.bytes) { dst in
      for (i, b) in bytes.prefix(32).enumerated() { dst[i] = b }
    }
    guard let out = call(&input) else { return false }
    return out.result == 0
  }

  func readDouble(_ key: String) -> Double? {
    guard let (info, bytes) = readData(key) else { return nil }
    let type = info.typeString
    if type == "flt ", bytes.count >= 4 {
      let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
      return Double(Float(bitPattern: raw))
    }
    if type == "ui8 " || type == "flag", let b = bytes.first { return Double(b) }
    if type.hasPrefix("fp"), bytes.count >= 2 {
      let frac = Int(String(type.suffix(1)), radix: 16) ?? 0
      let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
      return Double(raw) / Double(1 << frac)
    }
    return nil
  }

  func readUInt8(_ key: String) -> UInt8? {
    guard let (_, bytes) = readData(key), let first = bytes.first else { return nil }
    return first
  }

  @discardableResult
  func writeDouble(_ key: String, value: Double) -> Bool {
    guard let info = keyInfo(key) else { return false }
    let type = info.typeString
    var bytes = [UInt8](repeating: 0, count: max(Int(info.dataSize), 4))
    if type == "flt " {
      var f = Float(value)
      withUnsafeBytes(of: &f) { src in for i in 0..<4 { bytes[i] = src[i] } }
    } else if type.hasPrefix("fp") {
      let frac = Int(String(type.suffix(1)), radix: 16) ?? 0
      let raw = UInt16(max(0, min(65535, value * Double(1 << frac))))
      bytes[0] = UInt8(raw >> 8); bytes[1] = UInt8(raw & 0xFF)
    } else if type == "ui8 " || type == "flag" {
      bytes[0] = UInt8(max(0, min(255, value)))
    } else {
      return false
    }
    return writeData(key, bytes: Array(bytes.prefix(Int(info.dataSize))))
  }
}

// MARK: - One-shot privileged CLI (used by daemon + install)

enum FanHelperCLI {
  static func run(_ argv: [String]) -> Int32 {
    guard argv.count >= 2, let fanIndex = Int(argv[0]), (0...9).contains(fanIndex) else {
      fputs("Usage: MacmonDash --smc-fan <index> <rpm|auto>\n", stderr)
      return 1
    }
    let smc = SMCClient()
    guard smc.open() else {
      fputs("MacmonDash: cannot open AppleSMC\n", stderr)
      return 1
    }
    defer { smc.close() }

    let modeKey = ["F\(fanIndex)Md", "F\(fanIndex)md"].first { smc.keyInfo($0) != nil }

    func setMode(_ value: UInt8) -> Bool {
      guard let mk = modeKey else { return true } // Intel uses FS! only
      if smc.readUInt8(mk) == value { return true }
      // Unlock thermalmonitord first when Ftst exists (M3+ / some firmwares).
      if smc.keyInfo("Ftst") != nil {
        _ = smc.writeDouble("Ftst", value: 1)
        usleep(200_000)
      }
      _ = smc.writeDouble(mk, value: Double(value))
      if smc.readUInt8(mk) == value { return true }
      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline {
        if smc.keyInfo("Ftst") != nil { _ = smc.writeDouble("Ftst", value: 1) }
        _ = smc.writeDouble(mk, value: Double(value))
        if smc.readUInt8(mk) == value { return true }
        usleep(100_000)
      }
      // Still proceed — some Macs accept F*Tg while mode readback stays sticky.
      return false
    }

    if argv[1] == "auto" {
      _ = setMode(0)
      let fanCount = Int(smc.readDouble("FNum") ?? 0)
      let allAuto = (0..<fanCount).allSatisfy { i in
        let mk = ["F\(i)Md", "F\(i)md"].first { smc.keyInfo($0) != nil }
        guard let mk else { return true }
        return smc.readUInt8(mk) != 1
      }
      if allAuto, smc.keyInfo("Ftst") != nil {
        _ = smc.writeDouble("Ftst", value: 0)
      }
      if var flags = smc.readUInt8("FS! ") {
        flags &= ~(1 << fanIndex)
        _ = smc.writeData("FS! ", bytes: [flags, 0])
      }
      return 0
    }

    guard let rpm = Double(argv[1]), rpm >= 0, rpm <= 20000 else {
      fputs("MacmonDash: rpm out of range\n", stderr)
      return 1
    }

    let modeOK = setMode(1)
    if !modeOK {
      fputs("MacmonDash: mode sticky — still writing target RPM\n", stderr)
    }
    if var flags = smc.readUInt8("FS! ") {
      flags |= (1 << fanIndex)
      _ = smc.writeData("FS! ", bytes: [flags, 0])
    }

    let key = "F\(fanIndex)Tg"
    let acKey = "F\(fanIndex)Ac"
    let deadline = Date().addingTimeInterval(4)
    var accepted = false
    while Date() < deadline {
      accepted = smc.writeDouble(key, value: rpm)
      if let after = smc.readDouble(key), abs(after - rpm) < 1 { return 0 }
      // Success if actual RPM is moving toward the target.
      if let ac = smc.readDouble(acKey), abs(ac - rpm) < max(rpm * 0.25, 400) {
        return 0
      }
      usleep(150_000)
    }
    return accepted ? 0 : 1
  }
}

// MARK: - Root fan daemon (LaunchDaemon — password once, forever)

enum FanDaemon {
  /// Bumped whenever the line protocol changes; the app upgrades older helpers.
  static let protocolVersion = 2
  /// Overridable for unprivileged protocol tests (`MACMONDASH_FAN_SOCKET=/tmp/x.sock`).
  static let socketPath =
    ProcessInfo.processInfo.environment["MACMONDASH_FAN_SOCKET"] ?? "/var/run/macmondash-fan.sock"
  static let helperID = "com.local.macmondash.fanhelper"
  static let helperPath = "/usr/local/libexec/macmondash-fanhelper"
  static let plistPath = "/Library/LaunchDaemons/com.local.macmondash.fanhelper.plist"
  static let logPath = "/var/log/macmondash-fanhelper.log"

  /// Safety net: if the app stops talking to us (crash, force-quit) while any
  /// fan is in manual mode, hand the fans back to macOS after this long.
  static let watchdogTimeout: TimeInterval =
    Double(ProcessInfo.processInfo.environment["MACMONDASH_WATCHDOG"] ?? "") ?? 30

  private static let stateLock = NSLock()
  private static var manualFans = Set<Int>()
  private static var lastContact = Date()

  private static func touch() {
    stateLock.lock(); lastContact = Date(); stateLock.unlock()
  }

  private static func startWatchdog() {
    let t = Thread {
      while true {
        Thread.sleep(forTimeInterval: 2)
        stateLock.lock()
        let stale = !manualFans.isEmpty && Date().timeIntervalSince(lastContact) > watchdogTimeout
        let fans = manualFans
        if stale { manualFans.removeAll() }
        stateLock.unlock()
        guard stale else { continue }
        fputs("fan-daemon: no contact for \(Int(watchdogTimeout))s — restoring auto on fans \(fans.sorted())\n", stderr)
        for i in fans.sorted() { _ = FanHelperCLI.run([String(i), "auto"]) }
      }
    }
    t.name = "fan-watchdog"
    t.start()
  }

  static func makeAddr(_ path: String) -> (sockaddr_un, socklen_t) {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { src in
      withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
          _ = strncpy(buf, src, 103)
        }
      }
    }
    // sun_len + sun_family + path + NUL
    let len = socklen_t(2 + path.utf8.count + 1)
    addr.sun_len = UInt8(min(Int(len), 255))
    return (addr, len)
  }

  /// Runs forever as root; line protocol: `SET <i> <rpm>` / `AUTO <i>` → `OK` / `ERR …`
  static func run() -> Never {
    unlink(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      fputs("fan-daemon: socket failed\n", stderr)
      exit(1)
    }
    var pair = makeAddr(socketPath)
    let bindOK = withUnsafePointer(to: &pair.0) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, pair.1) }
    }
    guard bindOK == 0 else {
      fputs("fan-daemon: bind failed errno=\(errno)\n", stderr)
      exit(1)
    }
    chmod(socketPath, 0o666)
    listen(fd, 8)
    fputs("fan-daemon: v\(protocolVersion) listening on \(socketPath)\n", stderr)
    startWatchdog()

    while true {
      let client = accept(fd, nil, nil)
      guard client >= 0 else { continue }
      var buffer = [UInt8](repeating: 0, count: 256)
      let n = read(client, &buffer, buffer.count - 1)
      guard n > 0 else { close(client); continue }
      let line = String(bytes: buffer.prefix(n), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let reply = handle(line)
      _ = reply.withCString { write(client, $0, strlen($0)) }
      close(client)
    }
  }

  /// Line protocol:
  ///   VERSION        → OK <n>
  ///   PING           → OK            (keeps the watchdog happy while manual)
  ///   SET <i> <rpm>  → OK | ERR set  (fan i manual at rpm)
  ///   AUTO <i>       → OK | ERR auto (fan i back to macOS control)
  ///   PURGE          → OK | ERR purge (flush file cache, root only)
  static func handle(_ line: String) -> String {
    touch()
    let parts = line.split(separator: " ").map(String.init)
    switch parts.first {
    case "VERSION":
      return "OK \(protocolVersion)\n"
    case "PING":
      return "OK\n"
    case "AUTO" where parts.count >= 2:
      guard let idx = Int(parts[1]), (0...9).contains(idx) else { return "ERR bad\n" }
      let ok = FanHelperCLI.run([String(idx), "auto"]) == 0
      stateLock.lock(); manualFans.remove(idx); stateLock.unlock()
      return ok ? "OK\n" : "ERR auto\n"
    case "SET" where parts.count >= 3:
      guard let idx = Int(parts[1]), (0...9).contains(idx) else { return "ERR bad\n" }
      let ok = FanHelperCLI.run([String(idx), parts[2]]) == 0
      stateLock.lock(); manualFans.insert(idx); stateLock.unlock()
      return ok ? "OK\n" : "ERR set\n"
    case "PURGE":
      return shell("/usr/sbin/purge", []) == 0 ? "OK\n" : "ERR purge\n"
    default:
      return "ERR bad\n"
    }
  }

  /// Root uninstaller: fans back to auto, stop + remove daemon, helper, socket.
  static func uninstall() -> Int32 {
    let smc = SMCClient()
    if smc.open() {
      let fanCount = Int(smc.readDouble("FNum") ?? 0)
      smc.close()
      for i in 0..<min(fanCount, 10) { _ = FanHelperCLI.run([String(i), "auto"]) }
    }
    _ = shell("/bin/launchctl", ["bootout", "system/\(helperID)"])
    let fm = FileManager.default
    var failed = false
    for path in [plistPath, helperPath, socketPath] where fm.fileExists(atPath: path) {
      do { try fm.removeItem(atPath: path) } catch {
        fputs("uninstall: cannot remove \(path): \(error)\n", stderr)
        failed = true
      }
    }
    return failed ? 1 : 0
  }

  /// Root installer: copy helper + LaunchDaemon, start it. Password asked once here.
  static func install(fromExecutable src: String) -> Int32 {
    let fm = FileManager.default
    do {
      try fm.createDirectory(
        atPath: "/usr/local/libexec",
        withIntermediateDirectories: true
      )
      if fm.fileExists(atPath: helperPath) { try fm.removeItem(atPath: helperPath) }
      try fm.copyItem(atPath: src, toPath: helperPath)
      try fm.setAttributes(
        [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
        ofItemAtPath: helperPath
      )
    } catch {
      fputs("install: copy failed \(error)\n", stderr)
      return 1
    }

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(helperID)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(helperPath)</string>
        <string>--fan-daemon</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>StandardErrorPath</key>
      <string>\(logPath)</string>
    </dict>
    </plist>
    """
    do {
      try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
      try fm.setAttributes(
        [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
        ofItemAtPath: plistPath
      )
    } catch {
      fputs("install: plist failed \(error)\n", stderr)
      return 1
    }

    _ = shell("/bin/launchctl", ["bootout", "system/\(helperID)"])
    _ = shell("/bin/launchctl", ["bootstrap", "system", plistPath])
    _ = shell("/bin/launchctl", ["enable", "system/\(helperID)"])
    _ = shell("/bin/launchctl", ["kickstart", "-k", "system/\(helperID)"])

    // Wait until the *new* daemon answers (a stale socket file may linger).
    for _ in 0..<80 {
      if probeVersion() == protocolVersion { return 0 }
      usleep(100_000)
    }
    fputs("install: daemon did not come up\n", stderr)
    return 1
  }

  /// Protocol version of the running daemon, or nil if none is listening.
  static func probeVersion() -> Int? {
    guard let reply = sendLine("VERSION") else { return nil }
    // Pre-v2 daemons answer "ERR bad" to VERSION.
    guard reply.hasPrefix("OK") else { return 1 }
    return Int(reply.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// One request/reply round-trip on the unix socket; nil if not reachable.
  static func sendLine(_ line: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: 20, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var pair = makeAddr(socketPath)
    let ok = withUnsafePointer(to: &pair.0) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, pair.1)
      }
    }
    guard ok == 0 else { return nil }
    let payload = line + "\n"
    payload.withCString { _ = write(fd, $0, strlen($0)) }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, buf.count - 1)
    guard n > 0 else { return nil }
    return String(bytes: buf.prefix(n), encoding: .utf8)
  }

  @discardableResult
  static func shell(_ path: String, _ args: [String]) -> Int32 {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: path)
    t.arguments = args
    t.standardOutput = FileHandle.nullDevice
    t.standardError = FileHandle.nullDevice
    do { try t.run() } catch { return 1 }
    t.waitUntilExit()
    return t.terminationStatus
  }
}

// MARK: - App → daemon client

/// Where the privileged helper stands on this Mac.
enum HelperState: Equatable {
  /// Daemon answers with the current protocol — everything works.
  case ready
  /// LaunchDaemon files exist but the daemon is older / not answering.
  case needsUpdate
  /// Never installed (or removed).
  case notInstalled
}

/// Talks to the root helper. Never prompts for a password by itself — the UI
/// decides when to call `installOrUpdate()` (see `HelperSetup`).
enum FanPrivileged {
  private static let queue = DispatchQueue(label: "com.local.macmondash.fan")

  static var executablePath: String {
    Bundle.main.executablePath ?? CommandLine.arguments[0]
  }

  /// Cheap file check, safe on the main thread (used for menu titles).
  static var filesInstalled: Bool {
    FileManager.default.fileExists(atPath: FanDaemon.plistPath)
  }

  /// Full check with a socket round-trip — call off the main thread.
  static func state() -> HelperState {
    queue.sync {
      if FanDaemon.probeVersion() == FanDaemon.protocolVersion { return .ready }
      return filesInstalled ? .needsUpdate : .notInstalled
    }
  }

  static func setSpeed(fanIndex: Int, rpm: Double) -> Bool {
    queue.sync { ok(FanDaemon.sendLine("SET \(fanIndex) \(Int(rpm.rounded()))")) }
  }

  static func setAuto(fanIndex: Int) -> Bool {
    queue.sync { ok(FanDaemon.sendLine("AUTO \(fanIndex)")) }
  }

  /// Fire-and-forget variant for app termination (no queue hop).
  static func setAutoSilently(fanIndex: Int) {
    _ = FanDaemon.sendLine("AUTO \(fanIndex)")
  }

  /// Keeps the daemon's watchdog from resetting fans while we hold them manual.
  static func ping() {
    queue.async { _ = FanDaemon.sendLine("PING") }
  }

  /// Flush the file cache via the root helper (`purge`).
  static func purge() -> Bool {
    queue.sync { ok(FanDaemon.sendLine("PURGE")) }
  }

  /// Runs the root installer (one macOS admin prompt). Blocks; call off main.
  static func installOrUpdate() -> Bool {
    queue.sync { runPrivileged(flag: "--install-fan-helper") && FanDaemon.probeVersion() == FanDaemon.protocolVersion }
  }

  /// Runs the root uninstaller (one macOS admin prompt). Blocks; call off main.
  static func uninstall() -> Bool {
    queue.sync { runPrivileged(flag: "--uninstall-fan-helper") && !filesInstalled }
  }

  private static func ok(_ reply: String?) -> Bool { reply?.hasPrefix("OK") == true }

  private static func runPrivileged(flag: String) -> Bool {
    let cmd = "'\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))' \(flag)"
    let quoted = cmd
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "do shell script \"\(quoted)\" with administrator privileges"
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    t.arguments = ["-e", script]
    t.standardOutput = FileHandle.nullDevice
    t.standardError = FileHandle.nullDevice
    do { try t.run() } catch { return false }
    t.waitUntilExit()
    return t.terminationStatus == 0
  }
}
