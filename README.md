# foundation_ble

`foundation_ble` is a Flutter plugin that provides a lightweight Bluetooth Low Energy (BLE) transport layer for Android, iOS, and macOS.
(WIP: Linux and Windows)

The package is designed around a clear separation between:

- **Control plane APIs** for device discovery, lifecycle management, and platform integration
- **Data plane APIs** for high-throughput raw byte communication with BLE peripherals

Unlike higher-level BLE SDKs, `foundation_ble` intentionally focuses only on transport concerns. Protocol framing, serialization, encryption, and application-specific messaging are left to the consuming application.

---

# Features

`foundation_ble` provides:

- BLE scanning and device discovery
- Device preparation and reconnection workflows
- GATT-based BLE communication
- Per-device raw byte streams
- Connection lifecycle monitoring
- Native Android, iOS, and macOS BLE integrations
- Lightweight transport-only architecture without protocol-layer abstractions

---

# Architecture

The package exposes two primary APIs:

| Layer | Responsibility |
|---|---|
| `FoundationBle` | Control plane operations |
| `BleConnection` | Data plane communication |

This separation allows applications to manage device orchestration independently from streaming BLE traffic.

---

# `FoundationBle`

Use `FoundationBle` for device management:

- Enable Bluetooth
- Scan for peripherals
- Retrieve known devices
- Prepare or reconnect devices
- Remove remembered devices
- Cache active connections
- Observe scan events
- Access host device information

Typical control-plane operations include:

- `prepareDevice(...)`
- `connect(...)`
- `reconnect(...)`
- `disconnect(...)`
- `getKnownDevices()`
- `removeDevice(...)`
- `startScan()`
- `stopScan()`

---

# `BleConnection`

Use `BleConnection` for per-device communication and streaming operations:

- Receive raw inbound BLE bytes
- Send raw outbound BLE bytes
- Observe connection state transitions
- Monitor connection events
- Reconnect or disconnect individual peripherals

Key APIs include:

- `readStream`
- `write(...)`
- `deviceStatusStream`
- `connectionEvents`
- `disconnect()`
- `reconnect()`

---

# Supported Platforms

| Platform | Status |
|---|---|
| Android | Supported |
| iOS | Supported |
| macOS | Supported |
| Linux | Not supported |
| Windows | Not supported |
| Web | Not supported |

## Platform Notes

- iOS support currently requires **iOS 18.0+** because the package uses `AccessorySetupKit`
- macOS support uses CoreBluetooth central-mode APIs
- Only GATT transport is currently supported

---

# Installation

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  foundation_ble: ^0.0.1
```

Import the package:

```dart
import 'package:foundation_ble/foundation_ble.dart';
```

---

# Usage

## Android and macOS

On Android and macOS, applications typically:

1. Start scanning
2. Select a discovered device
3. Establish a connection
4. Bind to the raw byte streams

```dart
import 'dart:typed_data';

import 'package:foundation_ble/foundation_ble.dart';

final bluetooth = FoundationBle();

await bluetooth.startScan();

Future<BleConnection> attachToDevice(String deviceId) async {
  final connection = await bluetooth.connect(deviceId);

  connection.deviceStatusStream.listen((status) {
    // Observe connection state, readiness, bonding, and errors.
  });

  connection.readStream.listen((bytes) {
    // Handle inbound BLE bytes.
  });

  return connection;
}

Future<void> sendRawBytes(BleConnection connection) async {
  await connection.write(
    Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
  );
}
```

---

## iOS

On iOS, device discovery and authorization are handled through `AccessorySetupKit`.

Applications define picker descriptors that are presented through the native accessory setup flow.

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
        bluetoothServiceUuid:
            '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
      ),
    ),
  ],
);

final connection = await bluetooth.connect(device.peripheralId);

connection.readStream.listen((bytes) {
  // Handle inbound BLE bytes.
});
```

---

# API Overview

## `FoundationBle`

Control-plane APIs:

- `getDeviceConnection(deviceId)`
- `getDeviceName()`
- `requestEnableBle()`
- `startScan()`
- `stopScan()`
- `getKnownDevices()`
- `prepareDevice(deviceId)`
- `connect(deviceId)`
- `reconnect(deviceId)`
- `disconnect(deviceId)`
- `setupDevice({iosPickerItems})`
- `removeDevice(deviceId)`
- `scanEvents`

---

## `BleConnection`

Data-plane APIs:

- `readStream`
- `dataStream`
- `write(data)`
- `getCurrentDeviceStatus()`
- `deviceStatusStream`
- `connectionEvents`
- `disconnect()`
- `reconnect()`

---

## Platform-Specific Capabilities

### Android

- `AndroidBleConnectionCapability.bond()`
- `AndroidBlePlatformCapability.pair(deviceId)`
- `AndroidBlePlatformCapability.getApiLevel()`

### iOS

- `IosAccessorySetupCapability.showAccessorySetup({items})`

---

# Platform Configuration

## Android

The plugin declares BLE permissions in its Android manifest, but applications must still request runtime permissions before scanning or connecting.

### Required Runtime Permissions

| Android Version | Permissions |
|---|---|
| Android 12+ | `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` |
| Android 6–11 | `ACCESS_FINE_LOCATION` |

The example application demonstrates a complete permission flow:

- `example/lib/main.dart`
- `example/android/app/src/main/kotlin/xyz/foundation/ble/foundation_ble_example/MainActivity.kt`

---

## iOS

iOS device discovery uses `AccessorySetupKit` (`ASAccessorySession`) rather than traditional BLE scanning.

The system presents a native accessory picker filtered by the descriptors provided at runtime.

All descriptor values used in picker items **must also be declared in `Info.plist`**. The plugin validates these declarations before presenting the picker UI.

Possible validation errors include:

- `ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_NAME`
- `ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_SERVICE`
- `ACCESSORY_SETUP_UNDECLARED_BLUETOOTH_COMPANY_ID`

---

### Step 1 — Declare Bluetooth Support

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

---

### Step 2 — Declare Picker Descriptor Values

Each `IosAccessoryPickerItem` descriptor field maps to a corresponding `Info.plist` key.

| Dart Field | `Info.plist` Key |
|---|---|
| `bluetoothNameSubstring` | `NSAccessorySetupBluetoothNames` |
| `bluetoothServiceUuid` | `NSAccessorySetupBluetoothServices` |
| `bluetoothCompanyIdentifier` | `NSAccessorySetupBluetoothCompanyIdentifiers` |

Example:

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

Name matching is case-insensitive and substring-based. For example, `"Passport"` matches `"Passport Prime"`.

---

### Step 3 — Add Bluetooth Usage Description

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover and connect to BLE accessories.</string>
```

A complete working configuration is available in:

- `example/ios/Runner/Info.plist`

---

## macOS

On macOS, CoreBluetooth access requires both Bluetooth usage descriptions and sandbox entitlements.

Typical setup includes:

- Adding `NSBluetoothAlwaysUsageDescription` to `Info.plist`
- Enabling `com.apple.security.device.bluetooth` in app entitlements

---

# Example Application

The example application demonstrates:

- Android permission handling
- Enabling Bluetooth on Android
- BLE scanning and device discovery
- Managing `BleConnection` instances
- Reading raw byte streams
- Writing UTF-8 and hexadecimal payloads
- Monitoring connection lifecycle events

Start with:

```text
example/lib/main.dart
```
