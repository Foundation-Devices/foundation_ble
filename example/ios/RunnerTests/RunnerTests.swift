import Flutter
import UIKit
import XCTest

@testable import foundation_ble

class RunnerTests: XCTestCase {

  func testPluginIsRegisterable() {
    let pluginClass: AnyClass = FoundationBlePlugin.self
    XCTAssertTrue(
      pluginClass.responds(to: NSSelectorFromString("registerWithRegistrar:")),
      "FoundationBlePlugin must implement register(with:) to be a valid FlutterPlugin"
    )
  }

}
