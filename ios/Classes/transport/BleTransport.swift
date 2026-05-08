import CoreBluetooth
import Foundation

enum BleTransportMode: String {
  case gatt
  case l2cap
}

struct BleTransportConfig: Equatable {
  let mode: BleTransportMode
  let psm: CBL2CAPPSM?

  static func gatt() -> BleTransportConfig {
    BleTransportConfig(mode: .gatt, psm: nil)
  }

  func validate() throws {
    guard mode == .l2cap else {
      return
    }

    guard let psm, psm > 0 else {
      throw Self.transportError("L2CAP transport requires a PSM")
    }
  }

  static func fromArguments(
    _ arguments: [String: Any]?,
    defaultConfig: BleTransportConfig? = nil
  ) throws -> BleTransportConfig {
    guard let rawTransport = arguments?["transport"] as? [String: Any] else {
      guard let defaultConfig else {
        throw transportError("Missing BLE transport configuration")
      }
      return defaultConfig
    }

    guard let rawMode = rawTransport["mode"] as? String,
          let mode = BleTransportMode(rawValue: rawMode.lowercased())
    else {
      throw transportError(
        "Unsupported BLE transport mode: \((rawTransport["mode"] as? String) ?? "nil")"
      )
    }

    let psmValue = (rawTransport["psm"] as? NSNumber)?.uint16Value
    let config = BleTransportConfig(mode: mode, psm: psmValue)
    try config.validate()
    return config
  }

  private static func transportError(_ message: String) -> NSError {
    NSError(
      domain: "INVALID_TRANSPORT",
      code: 0,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
