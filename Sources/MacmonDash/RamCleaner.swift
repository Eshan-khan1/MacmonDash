import AppKit
import Darwin
import os.log

private let log = Logger(subsystem: "com.local.macmondash", category: "RamCleaner")

/// Frees RAM without touching any app the user can see:
///  1. stops hidden background activities — Apple on-demand session services
///     (relaunched by launchd when needed) and faceless non-Apple helpers
///  2. flushes the file cache via the root helper (`purge`)
enum RamCleaner {
  struct Result {
    var freedBytes: Int64
    var stopped: [String]
    var purged: Bool
  }

  /// Apple user-session services that are safe to stop: launchd restarts them
  /// on demand, nothing visible closes. Matched on executable basename.
  static let restartSafeServices: Set<String> = [
    // Siri / intelligence
    "Siri", "siriactionsd", "siriinferenced", "assistantd", "com.apple.siri.embeddedspeech",
    "intelligenceplatformd", "proactived", "suggestd", "knowledge-agent", "parsecd",
    "spotlightknowledged", "duetexpertd",
    // Contacts / Calendar / Photos / Media analysis
    "contactsd", "CalendarAgent", "photoanalysisd", "photolibraryd", "mediaanalysisd",
    "cloudphotod", "AMPDeviceDiscoveryAgent", "AMPLibraryAgent", "studentd", "familycircled",
    // Spotlight / QuickLook helpers
    "corespotlightd", "QuickLookUIService", "com.apple.quicklook.ThumbnailsAgent",
    "quicklookd", "SafariBookmarksSyncAgent",
    // Widgets host (widgets re-render when shown again)
    "chronod",
    // Messages / sharing caches
    "IMDPersistenceAgent", "sharingd",
  ]

  /// Never touched.
  private static let protectedBundleIDs: Set<String> = [
    "com.apple.finder",
    "com.apple.dock",
    "com.apple.systemuiserver",
    "com.apple.loginwindow",
    "com.local.macmondash",
  ]

  struct ProcInfo {
    var pid: pid_t
    var ppid: pid_t
    var uid: uid_t
    var path: String
    var name: String { (path as NSString).lastPathComponent }
  }

  /// All processes via sysctl, with full executable paths.
  static func allProcesses() -> [ProcInfo] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let count = size / MemoryLayout<kinfo_proc>.stride + 16
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    size = count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    let n = size / MemoryLayout<kinfo_proc>.stride
    var out: [ProcInfo] = []
    out.reserveCapacity(n)
    var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    for i in 0..<n {
      let p = procs[i]
      let pid = p.kp_proc.p_pid
      guard pid > 0 else { continue }
      let len = proc_pidpath(pid, &buf, UInt32(buf.count))
      let path = len > 0 ? String(cString: buf) : ""
      out.append(ProcInfo(pid: pid, ppid: p.kp_eproc.e_ppid, uid: p.kp_eproc.e_ucred.cr_uid, path: path))
    }
    return out
  }

  /// Hidden background processes we are allowed to stop.
  static func backgroundTargets() -> [ProcInfo] {
    let me = ProcessInfo.processInfo.processIdentifier
    let uid = getuid()
    let apps = NSWorkspace.shared.runningApplications
    // Visible apps (Dock or menu bar) — their helpers are off-limits.
    let visible = apps.filter { $0.activationPolicy != .prohibited }
    let visiblePaths = visible.compactMap { $0.bundleURL?.path }
    let visibleIDs = visible.compactMap { $0.bundleIdentifier }
    let visiblePIDs = Set(visible.map { $0.processIdentifier })

    // Faceless (prohibited-policy) non-Apple bundles spawned by launchd.
    var facelessPIDs = Set<pid_t>()
    for app in apps where app.activationPolicy == .prohibited {
      guard let bid = app.bundleIdentifier, !bid.hasPrefix("com.apple."),
            !protectedBundleIDs.contains(bid)
      else { continue }
      let path = app.bundleURL?.path ?? ""
      if visiblePaths.contains(where: { path.hasPrefix($0) }) { continue }
      if visibleIDs.contains(where: { bid.hasPrefix($0) }) { continue }
      facelessPIDs.insert(app.processIdentifier)
    }

    return allProcesses().filter { p in
      guard p.uid == uid, p.pid != me, p.ppid == 1, !visiblePIDs.contains(p.pid) else { return false }
      if facelessPIDs.contains(p.pid) { return true }
      return restartSafeServices.contains(p.name)
    }
  }

  /// Same formula macmon uses for `ram_usage`.
  static func usedBytes() -> Int64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let pages = Int64(stats.active_count) + Int64(stats.inactive_count)
      + Int64(stats.wire_count) + Int64(stats.speculative_count)
      + Int64(stats.compressor_page_count)
      - Int64(stats.purgeable_count) - Int64(stats.external_page_count)
    return max(pages, 0) * Int64(pageSize)
  }

  /// Runs off the main thread; completion on main. Never quits apps.
  /// `purge` additionally flushes the file cache through the root helper.
  static func clean(purge: Bool, completion: @escaping (Result) -> Void) {
    let before = usedBytes()
    let targets = backgroundTargets()

    DispatchQueue.global(qos: .userInitiated).async {
      var stopped: [String] = []
      for p in targets {
        log.info("stop background \(p.name, privacy: .public) pid=\(p.pid)")
        if kill(p.pid, SIGTERM) == 0 { stopped.append(p.name) }
      }
      // Faceless services: force anything that ignored SIGTERM.
      Thread.sleep(forTimeInterval: 1.5)
      for p in targets where kill(p.pid, 0) == 0 {
        _ = kill(p.pid, SIGKILL)
      }
      let purged = purge ? FanPrivileged.purge() : false
      Thread.sleep(forTimeInterval: 1.0)
      let after = usedBytes()
      let result = Result(
        freedBytes: max(before - after, 0),
        stopped: stopped,
        purged: purged
      )
      DispatchQueue.main.async { completion(result) }
    }
  }
}

/// Accent for the clean button so it reads as a button, not TUI text.
let buttonAmber = NSColor(srgbRed: 225 / 255, green: 190 / 255, blue: 30 / 255, alpha: 1)

/// Text button ("CLEAN") in a small rounded box on the RAM title row.
final class RamCleanButton: NSView {
  var onClick: (() -> Void)?
  var busy = false { didSet { needsDisplay = true } }
  var label = "CLEAN"
  var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
  var baselineOffset: CGFloat = 3
  var cellW: CGFloat = 7
  private var hovered = false { didSet { needsDisplay = true } }
  private var tracking: NSTrackingArea?

  /// Width in terminal cells: 1 pad + text + 1 pad.
  var widthInCells: Int { label.count + 2 }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = false
    autoresizingMask = []
    toolTip = "Free RAM: stop hidden background services (apps are never closed) + purge file cache"
  }

  required init?(coder: NSCoder) { fatalError() }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {
    guard !busy, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick?()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    tuiBackground.setFill()
    bounds.fill()

    let accent = buttonAmber.withAlphaComponent(busy ? 0.5 : 1)
    let box = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
    path.lineWidth = 1
    if hovered && !busy {
      accent.setFill()
      path.fill()
    } else {
      accent.setStroke()
      path.stroke()
    }

    let textColor: NSColor = (hovered && !busy) ? .black : accent
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: bounds.minX + cellW, y: bounds.minY + baselineOffset)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}

/// Transient "freed 1.2 GB · 3 apps" label drawn in the terminal font.
final class RamStatusLabel: NSView {
  var text = "" { didSet { needsDisplay = true; isHidden = text.isEmpty } }
  var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
  var baselineOffset: CGFloat = 3
  private var hideWork: DispatchWorkItem?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = false
    autoresizingMask = []
    isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ s: String, for seconds: TimeInterval = 5) {
    hideWork?.cancel()
    text = s
    let w = DispatchWorkItem { [weak self] in self?.text = "" }
    hideWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
    tuiBackground.setFill()
    bounds.fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tuiGreen]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.saveGState()
    ctx.textMatrix = .identity
    // Right-aligned so it hugs the button.
    ctx.textPosition = CGPoint(x: max(bounds.maxX - width, 0), y: baselineOffset)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}
