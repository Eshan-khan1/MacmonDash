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

private struct NamedService {
  let service: HIDService
  let kind: Kind
  enum Kind { case tps, tpg, battery }
}

enum TempProbe {
  private static let lock = NSLock()
  private static var client: HIDClient?
  /// Keep the CFArray alive so the service pointers inside stay valid.
  private static var servicesArray: CFArray?
  private static var cached: [NamedService] = []
  private static var cacheAt: Date = .distantPast
  private static let cacheTTL: TimeInterval = 30

  /// Blocking sample. Prefer calling off the main thread.
  static func sample() -> PackageTemps {
    lock.lock()
    defer { lock.unlock() }

    if client == nil {
      client = HIDClientCreate(kCFAllocatorDefault)
    }
    guard let system = client else { return PackageTemps() }

    if cached.isEmpty || Date().timeIntervalSince(cacheAt) > cacheTTL {
      refreshCache(system)
    }

    var sVals: [Double] = []
    var gVals: [Double] = []
    var batVals: [Double] = []
    for item in cached {
      guard let event = HIDServiceCopyEvent(item.service, kIOHIDEventTypeTemperature, 0, 0) else {
        continue
      }
      let celsius = HIDEventGetFloatValue(event, kIOHIDEventTypeTemperature << 16)
      Unmanaged<CFTypeRef>.fromOpaque(event).release()
      guard celsius > 0, celsius <= 150 else { continue }
      switch item.kind {
      case .tps: sVals.append(celsius)
      case .tpg: gVals.append(celsius)
      case .battery: batVals.append(celsius)
      }
    }

    func avg(_ xs: [Double]) -> Double {
      xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
    return PackageTemps(tps: avg(sVals), tpg: avg(gVals), battery: avg(batVals))
  }

  private static func refreshCache(_ system: HIDClient) {
    let matching: [String: Any] = [
      "PrimaryUsagePage": kHIDPage_AppleVendor,
      "PrimaryUsage": kHIDUsage_AppleVendor_TemperatureSensor,
    ]
    _ = HIDClientSetMatching(system, matching as CFDictionary)
    guard let services = HIDClientCopyServices(system)?.takeRetainedValue() else {
      servicesArray = nil
      cached = []
      cacheAt = Date()
      return
    }
    servicesArray = services
    var next: [NamedService] = []
    let count = CFArrayGetCount(services)
    next.reserveCapacity(min(count, 32))
    for i in 0..<count {
      guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
      let service = HIDService(mutating: raw)
      guard
        let name = HIDServiceCopyProperty(service, "Product" as CFString)?
          .takeRetainedValue() as? String
      else { continue }
      if name.hasPrefix("PMU TP") {
        if name.hasSuffix("s") { next.append(NamedService(service: service, kind: .tps)) }
        else if name.hasSuffix("g") { next.append(NamedService(service: service, kind: .tpg)) }
      } else if name.localizedCaseInsensitiveContains("gas gauge battery")
                  || name.localizedCaseInsensitiveContains("battery") {
        next.append(NamedService(service: service, kind: .battery))
      }
    }
    cached = next
    cacheAt = Date()
  }
}
