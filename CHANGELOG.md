## 0.0.1

* Initial release of the Foundation BLE transport plugin, extracted from Envoy.
* Provides a control plane (`FoundationBle`) and a data plane (`BleConnection`) for raw BLE byte streams.
* Android: GATT transport mode, BLE scanning, runtime permission helpers.
* iOS: AccessorySetupKit-based device discovery (iOS 18.0+) via a native system picker.
* macOS: CoreBluetooth central-mode scanning and GATT connections.
