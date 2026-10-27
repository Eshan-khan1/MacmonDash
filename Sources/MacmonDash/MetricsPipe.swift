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
  var cpuTemp: Double = 0
  var gpuTemp: Double = 0
  var cpuPower: Double = 0
  var gpuPower: Double = 0
  var anePower: Double = 0
  var allPower: Double = 0
  var sysPower: Double = 0
}

/// Single macmon10 `pipe` reader for fans + temps + power.
final class MetricsPipe {
  private var process: Process?
  private var stdout: Pipe?
  private var buffer = Data()
  private let lock = NSLock()
  var onUpdate: ((LiveMetrics) -> Void)?

  func start(macmon10Path: String) {
    stop()
    let out = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: macmon10Path)
    proc.arguments = ["pipe", "-i", "500"]
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

  func stop() {
    stdout?.fileHandleForReading.readabilityHandler = nil
    if let proc = process, proc.isRunning {
      proc.terminate()
      proc.waitUntilExit()
    }
    process = nil
    stdout = nil
    lock.lock(); buffer.removeAll(); lock.unlock()
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
    for line in lines {
      if let m = Self.parse(line) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(m) }
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
