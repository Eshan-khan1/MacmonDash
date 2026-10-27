import AppKit

/// What macmon 0.7.2 prints, and what it should print.
///
/// On macOS 27 `system_profiler` reports `proc total:S:P:E` (an M1 Pro reads
/// `proc 10:0:8:2`). macmon 0.7.2 still parses the macOS 26 order
/// `proc total:P:E:M`, so this Mac is drawn as `2P+0S` with boxes "P-CPU" and
/// "S-CPU". The left box is the efficiency cluster and the right box is the
/// performance cluster. macmon 0.10 fixed the parser; the bundled TUI is 0.7.2,
/// so the titles are patched on top of the terminal grid.
struct ClusterCorrection: Equatable {
  /// Replacement for the left box title ("E-CPU"), or nil when 0.7.2 is already right.
  var leftTitle: String?
  var rightTitle: String?
  /// Column of the `2P+0S` token inside the top title.
  var headerCol: Int = 0
  /// Text drawn over that token (and the rest of the title when the length changes).
  var headerText: String?
  var headerWidth: Int = 0

  static let none = ClusterCorrection()

  /// `X-CPU` is always 5 cells, drawn one cell past the box corner (leading space).
  static let boxTitleWidth = 5
}

enum ClusterLabels {
  /// Reads system_profiler once. Completion is on the main queue.
  static func load(_ completion: @escaping (ClusterCorrection) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      let fix = correction(from: profilerJSON())
      DispatchQueue.main.async { completion(fix) }
    }
  }

  /// Visible for the layout math. `json` is `system_profiler -json` output.
  static func correction(from json: [String: Any]?) -> ClusterCorrection {
    guard
      let hw = (json?["SPHardwareDataType"] as? [[String: Any]])?.first,
      let chip = hw["chip_type"] as? String, !chip.isEmpty,
      let proc = hw["number_processors"] as? String
    else { return .none }

    let old = parseV072(proc)
    let new = parseV010(proc)
    guard old.e + old.p + new.e + new.p > 0 else { return .none }

    let oldNames = names(hasM: old.m)
    let newNames = names(hasM: new.m)
    var fix = ClusterCorrection.none

    if oldNames.e != newNames.e { fix.leftTitle = "\(newNames.e)-CPU" }
    if oldNames.p != newNames.p { fix.rightTitle = "\(newNames.p)-CPU" }

    let oldToken = "\(old.e)\(oldNames.e)+\(old.p)\(oldNames.p)"
    let newToken = "\(new.e)\(newNames.e)+\(new.p)\(newNames.p)"
    if oldToken != newToken {
      // Title text is " {chip} ({token}+{gpu}GPU {mem}GB) " starting at column 1.
      fix.headerCol = 1 + 1 + chip.count + 2
      if oldToken.count == newToken.count {
        fix.headerText = newToken
        fix.headerWidth = newToken.count
      } else {
        // Keep "+16GPU 32GB)" intact when the token grows or shrinks.
        let gpu = gpuCores(json)
        let mem = memoryGB(hw)
        let tail = "+\(gpu)GPU \(mem)GB)"
        let oldSuffix = oldToken + tail
        let newSuffix = newToken + tail
        fix.headerText = newSuffix
        fix.headerWidth = max(oldSuffix.count, newSuffix.count)
      }
    }
    return fix
  }

  // MARK: Parsers (ported from macmon sources.rs)

  /// macmon 0.7.2: "proc T:P:E" or "proc T:P:E:M".
  static func parseV072(_ s: String) -> (e: Int, p: Int, m: Bool) {
    let parts = fields(s)
    switch parts.count {
    case 4:
      let (e, m) = (parts[2], parts[3])
      return m > 0 ? (m, parts[1], true) : (e, parts[1], false)
    case 3:
      return (parts[2], parts[1], false)
    default:
      return (0, 0, false)
    }
  }

  /// macmon 0.10: macOS 27 reordered the 4-field form to "proc T:S:P:E".
  static func parseV010(_ s: String) -> (e: Int, p: Int, m: Bool) {
    let parts = fields(s)
    if parts.count == 4, parts[1] == 0 { return (parts[3], parts[2], false) }
    if parts.count == 4, parts[3] > 0 { return (parts[3], parts[1], true) }
    if parts.count == 4 || parts.count == 3 { return (parts[2], parts[1], false) }
    return (0, 0, false)
  }

  private static func names(hasM: Bool) -> (e: String, p: String) {
    hasM ? ("P", "S") : ("E", "P")
  }

  private static func fields(_ s: String) -> [Int] {
    let body = s.hasPrefix("proc ") ? String(s.dropFirst(5)) : s
    return body.split(separator: ":").map { Int($0) ?? 0 }
  }

  private static func gpuCores(_ json: [String: Any]?) -> Int {
    let gpu = (json?["SPDisplaysDataType"] as? [[String: Any]])?.first
    return Int(gpu?["sppci_cores"] as? String ?? "") ?? 0
  }

  private static func memoryGB(_ hw: [String: Any]) -> Int {
    let raw = hw["physical_memory"] as? String ?? ""
    return Int(raw.replacingOccurrences(of: " GB", with: "")) ?? 0
  }

  private static func profilerJSON() -> [String: Any]? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPHardwareDataType", "SPDisplaysDataType", "-json"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}

/// Black cell strip with terminal-font text, used to replace a few TUI glyphs.
final class GridTextPatch: NSView {
  var text = "" { didSet { needsDisplay = true } }
  var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
  var baselineOffset: CGFloat = 3

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = false
    autoresizingMask = []
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
    NSColor.black.setFill()
    bounds.fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tuiGreen]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: bounds.minX, y: baselineOffset)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}
