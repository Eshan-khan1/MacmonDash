import Foundation
import os.log

private let log = Logger(subsystem: "com.local.macmondash", category: "Metrics")

struct FanReading: Equatable {
  var name: String
  var rpm: Int
  var maxRpm: Int
}

struct LiveMetrics: Equatable {
  var fans: [FanReading] = []
  /// macmon CPU/GPU averages (kept for reference; UI uses package probes).
  var cpuTemp: Double = 0
  var gpuTemp: Double = 0
  /// PMU TP*s / TP*g package probes (°C), filled by TempProbe.
  var packageS: Double = 0
  var packageG: Double = 0
  /// Battery pack temperature (°C) from gas-gauge sensors.
  var batteryTemp: Double = 0
  var cpuPower: Double = 0
  var gpuPower: Double = 0
  var anePower: Double = 0
  var allPower: Double = 0
  var sysPower: Double = 0

  /// Hotter package probe — what the Temp panel and menu bar show.
  var displayTemp: Double {
    let hot = max(packageS, packageG)
    return hot > 1 ? hot : max(cpuTemp, gpuTemp)
  }
}

/// Shared refresh cadence for the TUI and the overlay metrics pipe (ms).
enum MetricsCadence {
  /// Dashboard visible — still light; macmon default is 1000.
  static let foregroundMs = 2000
  /// Menu-bar only — temp/fans need far less often.
  static let backgroundMs = 4000
  /// Live pipe interval (foreground dashboard or background menu-bar).
  static var intervalMs = foregroundMs
  /// Last interval chosen with macmon `-` / `+` while the dashboard is up.
  static var dashboardMs = foregroundMs

  /// Match macmon 0.7.2 `dec_interval` (250 ms steps, floor 250).
  static func decDashboard() {
    let step = 250
    let raw = max(0, dashboardMs - step)
    let aligned = ((raw + step - 1) / step) * step
    dashboardMs = max(aligned, step)
  }

  /// Match macmon 0.7.2 `inc_interval` (250 ms steps, cap 10_000).
  static func incDashboard() {
    let step = 250
    dashboardMs = min(((dashboardMs + step) / step) * step, 10_000)
  }
}

/// Single macmon10 `pipe` reader for fans + power; merges TempProbe on the same tick.
final class MetricsPipe {
  private var process: Process?
  private var stdout: Pipe?
  private var buffer = Data()
  private let lock = NSLock()
  /// Serial enrichment so each UI tick is one complete snapshot (no out-of-order temps).
  private let enrichQueue = DispatchQueue(label: "com.local.macmondash.metrics", qos: .utility)
  private var tick = 0
  private var path: String?
  private var intervalMs = MetricsCadence.foregroundMs
  var onUpdate: ((LiveMetrics) -> Void)?

  func start(macmon10Path: String, intervalMs: Int = MetricsCadence.intervalMs) {
    path = macmon10Path
    self.intervalMs = max(intervalMs, 500)
    MetricsCadence.intervalMs = self.intervalMs
    stopProcessOnly()
    let out = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: macmon10Path)
    proc.arguments = ["pipe", "-i", "\(self.intervalMs)"]
    proc.qualityOfService = .utility
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    proc.environment = env

    out.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      self?.consume(chunk)
    }

    do { try proc.run() } catch {
      log.error("metrics pipe failed \(error.localizedDescription)")
      out.fileHandleForReading.readabilityHandler = nil
      return
    }
    process = proc
    stdout = out
  }

  /// Switch sampling rate without dropping the onUpdate handler (e.g. window closed).
  func setIntervalMs(_ ms: Int) {
    let next = max(ms, 500)
    guard next != intervalMs, let path else { return }
    start(macmon10Path: path, intervalMs: next)
  }

  func stop() {
    path = nil
    stopProcessOnly()
  }

  private func stopProcessOnly() {
    stdout?.fileHandleForReading.readabilityHandler = nil
    if let proc = process, proc.isRunning {
      proc.terminate()
      proc.waitUntilExit()
    }
    process = nil
    stdout = nil
    lock.lock(); buffer.removeAll(); tick = 0; lock.unlock()
  }

  private func consume(_ chunk: Data) {
    lock.lock()
    buffer.append(chunk)
    var lines: [Data] = []
    while let range = buffer.range(of: Data([0x0A])) {
      lines.append(buffer.subdata(in: buffer.startIndex..<range.lowerBound))
      buffer.removeSubrange(buffer.startIndex...range.lowerBound)
    }
    lock.unlock()
    // Keep only the freshest pipe line if several arrived in one chunk.
    guard let line = lines.last, let parsed = Self.parse(line) else { return }
    enrichQueue.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.tick &+= 1
      let myTick = self.tick
      self.lock.unlock()

      var m = parsed
      let pkg = TempProbe.sample()
      m.packageS = pkg.tps
      m.packageG = pkg.tpg
      m.batteryTemp = pkg.battery

      self.lock.lock()
      let stillLatest = self.tick == myTick
      self.lock.unlock()
      guard stillLatest else { return }

      DispatchQueue.main.async { [weak self] in
        self?.onUpdate?(m)
      }
    }
  }

  private static func parse(_ line: Data) -> LiveMetrics? {
    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return nil
    }
    var m = LiveMetrics()
    if let arr = obj["fans"] as? [[String: Any]] {
      m.fans = arr.compactMap { f in
        guard let name = f["name"] as? String else { return nil }
        return FanReading(name: name, rpm: num(f["rpm"]), maxRpm: num(f["max_rpm"]))
      }
    }
    if let temp = obj["temp"] as? [String: Any] {
      m.cpuTemp = dbl(temp["cpu_temp_avg"])
      m.gpuTemp = dbl(temp["gpu_temp_avg"])
    }
    m.cpuPower = dbl(obj["cpu_power"])
    m.gpuPower = dbl(obj["gpu_power"])
    m.anePower = dbl(obj["ane_power"])
    m.allPower = dbl(obj["all_power"])
    m.sysPower = dbl(obj["sys_power"])
    return m
  }

  private static func num(_ any: Any?) -> Int {
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let d = any as? Double { return Int(d) }
    return 0
  }

  private static func dbl(_ any: Any?) -> Double {
    if let d = any as? Double { return d }
    if let n = any as? NSNumber { return n.doubleValue }
    if let i = any as? Int { return Double(i) }
    return 0
  }
}
