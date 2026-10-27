import Foundation
import IOKit

// Private IOHIDEventSystemClient APIs — same route macmon uses for Apple Silicon temps.

private typealias HIDClient = UnsafeMutableRawPointer
private typealias HIDService = UnsafeMutableRawPointer
private typealias HIDEvent = UnsafeMutableRawPointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func HIDClientCreate(_ allocator: CFAllocator?) -> HIDClient?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func HIDClientSetMatching(_ client: HIDClient?, _ matching: CFDictionary?) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func HIDClientCopyServices(_ client: HIDClient?) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func HIDServiceCopyProperty(_ service: HIDService?, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func HIDServiceCopyEvent(
  _ service: HIDService?, _ type: Int64, _ options: Int32, _ unused: Int64
) -> HIDEvent?

@_silgen_name("IOHIDEventGetFloatValue")
private func HIDEventGetFloatValue(_ event: HIDEvent?, _ field: Int64) -> Double

private let kHIDPage_AppleVendor = 0xff00
private let kHIDUsage_AppleVendor_TemperatureSensor = 0x0005
private let kIOHIDEventTypeTemperature: Int64 = 15

/// Package + battery temperatures from Apple Silicon IOHID sensors.
struct PackageTemps: Equatable {
  /// Average of `PMU TP*s` (°C) — CPU / system side of the package.
  var tps: Double = 0
  /// Average of `PMU TP*g` (°C) — GPU side of the package.
  var tpg: Double = 0
  /// Average of `gas gauge battery` (°C).
  var battery: Double = 0
  var hottest: Double { max(tps, tpg) }
  var isValid: Bool { tps > 1 || tpg > 1 }
}

enum TempProbe {
  private static let lock = NSLock()
  private static var client: HIDClient?

  /// Blocking sample. Prefer calling off the main thread.
  static func sample() -> PackageTemps {
    lock.lock()
    defer { lock.unlock() }

    if client == nil {
      client = HIDClientCreate(kCFAllocatorDefault)
    }
    guard let system = client else { return PackageTemps() }

    let matching: [String: Any] = [
      "PrimaryUsagePage": kHIDPage_AppleVendor,
      "PrimaryUsage": kHIDUsage_AppleVendor_TemperatureSensor,
    ]
    _ = HIDClientSetMatching(system, matching as CFDictionary)
    guard let services = HIDClientCopyServices(system)?.takeRetainedValue() else {
      return PackageTemps()
    }

    var sVals: [Double] = []
    var gVals: [Double] = []
    var batVals: [Double] = []
    let count = CFArrayGetCount(services)
    for i in 0..<count {
      guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
      let service = HIDService(mutating: raw)
      guard
        let name = HIDServiceCopyProperty(service, "Product" as CFString)?
          .takeRetainedValue() as? String
      else { continue }
      guard let event = HIDServiceCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else {
        continue
      }
      let celsius = HIDEventGetFloatValue(event, kIOHIDEventTypeTemperature << 16)
      Unmanaged<CFTypeRef>.fromOpaque(event).release()
      guard celsius > 0, celsius <= 150 else { continue }
      if name.hasPrefix("PMU TP") {
        if name.hasSuffix("s") { sVals.append(celsius) }
        else if name.hasSuffix("g") { gVals.append(celsius) }
      } else if name.localizedCaseInsensitiveContains("gas gauge battery")
                  || name.localizedCaseInsensitiveContains("battery") {
        batVals.append(celsius)
      }
    }

    func avg(_ xs: [Double]) -> Double {
      xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
    return PackageTemps(tps: avg(sVals), tpg: avg(gVals), battery: avg(batVals))
  }
}
