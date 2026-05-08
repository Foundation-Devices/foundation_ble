# foundation_ble

`foundation_ble` is a Flutter BLE transport plugin extracted from Envoy.

It gives you:

- BLE setup and device management through `FoundationBle`
- Per-device raw byte read/write streams through `BleConnection`
- Per-connection transport selection with GATT by default and Android L2CAP support
- Native Android, iOS, and macOS BLE integrations without pulling in Envoy's higher-level protocol layer

## Why

- Why: your BLE layer has a clear split between a control plane and a data plane.
- Why: the control plane is things like `prepareDevice`, `reconnect`, `getConnectedDevices`,
  `getCurrentDeviceStatus`, `removeDevice`, and `enableBluetooth`.
- Why: the data plane is per-device raw byte read/write streams and high-frequency
  connection events.
- Why: this package is specifically the BLE plugin layer, so encoding, decoding, framing, and other
  protocol-specific work are intentionally not part of this package.

## What This Package Exposes

### `FoundationBle`

Use `FoundationBle` for the control plane:

- host device name
- enable Bluetooth
- start/stop scan
- get known devices
- prepare or reconnect a device
- remove a remembered device
- cache per-device connections
- listen to scan events

### `BleConnection`

Use `BleConnection` for the data plane:

- `transport` for the active transport mode
- `readStream` for raw inbound bytes
- `write(...)` for raw outbound bytes
- `deviceStatusStream` and `connectionEvents`
- `disconnect()` and `reconnect()`

## Supported Platforms

- Android
- iOS
- macOS

Notes:

- iOS support currently requires iOS `18.0+` because the package uses `AccessorySetupKit`.
- macOS support uses CoreBluetooth central-mode APIs and keeps the same
  `FoundationBle` / `BleConnection` structure as the mobile targets.
- L2CAP transport selection is currently implemented on Android only. Selecting
  `BleTransport.l2cap(...)` on iOS or macOS throws a `BleTransportException`.
- The plugin does not currently expose web, Linux, or Windows BLE support.

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  foundation_ble: ^0.0.1
```

Then import it:

```dart
import 'package:foundation_ble/foundation_ble.dart';
```

## Usage

### Android-style flow

Use the control plane to connect a device, then bind to the data plane connection:

```dart
import 'dart:typed_data';

import 'package:foundation_ble/foundation_ble.dart';

final bluetooth = FoundationBle();

Future<BleConnection> attachToDevice(String deviceId) async {
  final connection = await bluetooth.connect(
    deviceId,
    transport: const BleTransport.gatt(),
  );

  connection.deviceStatusStream.listen((status) {
    // Observe connection, ready state, bonded state, and errors.
  });

  connection.readStream.listen((bytes) {
    // Handle raw BLE bytes from the peripheral.
  });

  return connection;
}

Future<void> sendRawBytes(BleConnection connection) async {
  await connection.write(Uint8List.fromList(<int>[0x01, 0x02, 0x03]));
}
```

### iOS-style flow

On iOS, the accessory setup flow authorizes and discovers a device. Connect to
the returned device ID afterwards:

```dart
final bluetooth = FoundationBle();
final device = await bluetooth.setupDevice(
  iosPickerItems: const <IosAccessoryPickerItem>[
    IosAccessoryPickerItem(
      id: 'passport-prime',
      name: 'Passport Prime',
      imageAsset: 'assets/passport_prime.png',
      descriptor: IosAccessoryDiscoveryDescriptor(
        bluetoothNameSubstring: 'Passport',
        bluetoothServiceUuid: '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
      ),
    ),
  ],
);

final connection = await bluetooth.connect(
  device.peripheralId,
  transport: const BleTransport.gatt(),
);

connection.readStream.listen((bytes) {
  // Raw data from the peripheral.
});
```

### macOS-style flow

On macOS, scan first, then connect to a device using the same control-plane and
data-plane split:

```dart
final bluetooth = FoundationBle();

await bluetooth.startScan();
final connection = await bluetooth.connect(
  deviceId,
  transport: const BleTransport.gatt(),
);

connection.readStream.listen((bytes) {
  // Raw data from the peripheral.
});
```

### Android L2CAP flow

On Android, you can opt into L2CAP while keeping the same `BleConnection`
read/write and connection APIs:

```dart
final bluetooth = FoundationBle();
final connection = await bluetooth.connect(
  deviceId,
  transport: const BleTransport.l2cap(psm: 0x0085),
);
```

## API Overview

Control plane APIs on `FoundationBle`:

- `getDeviceConnection(deviceId, {transport, reset})`
- `getDeviceName()`
- `requestEnableBle()`
- `startScan()`
- `stopScan()`
- `getKnownDevices()`
- `prepareDevice(deviceId, {transport})`
- `connect(deviceId, {transport, reset})`
- `reconnect(deviceId, {transport})`
- `disconnect(deviceId)`
- `setupDevice({iosPickerItems})`
- `removeDevice(deviceId)`
- `scanEvents`

Data plane APIs on `BleConnection`:

- `transport`
- `readStream`
- `dataStream`
- `write(data)`
- `getCurrentDeviceStatus()`
- `deviceStatusStream`
- `connectionEvents`
- `disconnect()`
- `reconnect()`

Android-only connection capability:

- `AndroidBleConnectionCapability.bond()`

Platform-only capabilities:

- `IosAccessorySetupCapability.showAccessorySetup({items})`
- `AndroidBlePlatformCapability.pair(deviceId)`
- `AndroidBlePlatformCapability.getApiLevel()`

## Platform Setup Notes

### Android

The plugin declares BLE permissions in its Android manifest, but your app still needs to request
runtime permissions before scanning or connecting.

Typical runtime permissions:

- Android 12 and newer: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
- Android 6 through 11: `ACCESS_FINE_LOCATION`

The example app shows one working permission flow in
[`example/lib/main.dart`](example/lib/main.dart) and
[`example/android/app/src/main/kotlin/xyz/foundation/ble/foundation_ble_example/MainActivity.kt`](example/android/app/src/main/kotlin/xyz/foundation/ble/foundation_ble_example/MainActivity.kt).

### iOS

iOS device discovery uses `AccessorySetupKit` (`ASAccessorySession`) instead of a traditional BLE
scan. The system shows a native picker filtered by the descriptors you pass at runtime, but **every
descriptor value must also be declared in `Info.plist`** — the plugin validates this before the
picker appears and throws `ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_NAME`,
`ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_SERVICE`, or
`ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_COMPANY_ID` if there is a mismatch.

**Step 1 — declare Bluetooth support**

Add both keys so the plugin initialises correctly on all iOS 18 runtimes:

```xml
<key>NSAccessorySetupSupports</key>
<array>
    <string>Bluetooth</string>
</array>
<key>NSAccessorySetupKitSupports</key>
<array>
    <string>Bluetooth</string>
</array>
```

**Step 2 — declare every filter value your picker items use**

Each `IosAccessoryPickerItem` descriptor field has a matching `Info.plist` array. Every value you
pass at runtime must appear in the corresponding array:

| Dart field | Info.plist key |
|---|---|
| `bluetoothNameSubstring` | `NSAccessorySetupBluetoothNames` |
| `bluetoothServiceUuid` | `NSAccessorySetupBluetoothServices` |
| `bluetoothCompanyIdentifier` | `NSAccessorySetupBluetoothCompanyIdentifiers` |

Example — if your picker item uses `bluetoothNameSubstring: 'Passport Prime'` and
`bluetoothServiceUuid: '6E400001-B5A3-F393-E0A9-E50E24DCCA9E'`:

```xml
<key>NSAccessorySetupBluetoothNames</key>
<array>
    <string>Passport Prime</string>
</array>
<key>NSAccessorySetupBluetoothServices</key>
<array>
    <string>6E400001-B5A3-F393-E0A9-E50E24DCCA9E</string>
</array>
```

Name matching is case-insensitive and substring-based, so `"Passport"` would also satisfy a
declared entry of `"Passport Prime"`.

**Step 3 — add the Bluetooth usage description**

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover and connect to BLE accessories.</string>
```

The example app includes a complete working configuration in
[`example/ios/Runner/Info.plist`](example/ios/Runner/Info.plist).

### macOS

On macOS, CoreBluetooth access also needs app sandbox configuration in addition to the Bluetooth
usage description.

Typical macOS setup:

- add `NSBluetoothAlwaysUsageDescription` to `Info.plist`
- enable `com.apple.security.device.bluetooth` in your app entitlements

The example app includes a working setup in
[`example/macos/Runner/Info.plist`](example/macos/Runner/Info.plist),
[`example/macos/Runner/DebugProfile.entitlements`](example/macos/Runner/DebugProfile.entitlements),
and [`example/macos/Runner/Release.entitlements`](example/macos/Runner/Release.entitlements).

## What This Package Does Not Do

- It does not encode or decode application payloads.
- It does not implement Quantum Link protocol semantics.
- It does not transform raw bytes into domain models.
- It does not replace your app-layer protocol handling.

## Example App

See the example app for a complete BLE console that:

- checks Android permissions
- enables Bluetooth on Android
- scans and lists known devices on Android and macOS
- attaches to a `BleConnection`
- reads raw bytes
- writes UTF-8 or hex payloads
- monitors connection events

Start with [`example/lib/main.dart`](example/lib/main.dart).
