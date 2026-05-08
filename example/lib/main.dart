import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:foundation_ble/foundation_ble.dart';

import 'device_page.dart';
import 'example_accessory_setup.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.white),
        useMaterial3: true,
      ),
      darkTheme: ThemeData.dark(),
      home: const _ScanPage(),
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  FoundationBle? _bluetooth;
  StreamSubscription<BleScanEvent>? _scanSubscription;

  final Map<String, ExampleBleDevice> _devices = <String, ExampleBleDevice>{};

  String _statusMessage = 'Preparing BLE demo...';
  String? _busyAction;
  bool _isScanning = false;
  bool? _hasBlePermissions;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  bool get _supportsBleDemo => _isAndroid || _isIOS || _isMacOS;

  bool get _needsBlePermissionFlow => _isAndroid || _isMacOS;

  String get _requestBleAccessLabel =>
      _isMacOS ? 'Request Access' : 'Request Permissions';

  String get _initialStatusMessage => _isIOS
      ? 'Use Accessory Setup to pick a device, then open it on the next screen.'
      : _isAndroid
      ? 'Request BLE permissions, enable Bluetooth, scan, and select a device.'
      : 'Grant Bluetooth access on macOS, then scan and select a device.';

  List<ExampleBleDevice> get _sortedDevices {
    final devices = _devices.values.toList(growable: false);
    devices.sort((left, right) {
      final nameComparison = left.deviceName.toLowerCase().compareTo(
        right.deviceName.toLowerCase(),
      );
      if (nameComparison != 0) {
        return nameComparison;
      }
      return left.macId.toLowerCase().compareTo(right.macId.toLowerCase());
    });
    return devices;
  }

  @override
  void initState() {
    super.initState();

    if (_supportsBleDemo) {
      _bluetooth = FoundationBle();
      _scanSubscription = _bluetooth!.scanEvents.listen(_onScanEvent);
      unawaited(_initialize());
    } else {
      _statusMessage =
          'This demo is available on Android, iOS, and macOS only.';
    }
  }

  @override
  void dispose() {
    unawaited(_scanSubscription?.cancel());
    if (_bluetooth != null) {
      unawaited(_bluetooth!.dispose());
    }
    super.dispose();
  }

  Future<void> _initialize() async {
    var canLoadKnownDevices = true;
    if (_needsBlePermissionFlow) {
      canLoadKnownDevices = await _ensureBlePermissions(silent: true);
    }
    if (_isIOS && canLoadKnownDevices) {
      await _loadKnownDevices(silent: true);
    }
    _setStatus(_initialStatusMessage);
  }

  void _setStatus(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = message;
    });
  }

  void _setBusy(String? action) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busyAction = action;
    });
  }

  Future<void> _requestBleAccess() async {
    if (_busyAction != null) {
      return;
    }

    _setBusy(_requestBleAccessLabel);
    try {
      final granted = await _ensureBlePermissions();
      if (_isIOS && granted) {
        await _loadKnownDevices(silent: true);
      }
    } catch (error) {
      _setStatus(error.toString());
    } finally {
      _setBusy(null);
    }
  }

  Future<bool> _ensureBlePermissions({bool silent = false}) async {
    if (!_needsBlePermissionFlow || _bluetooth == null) {
      return true;
    }

    try {
      final granted = await _bluetooth!.requestBlePermissions();
      if (!mounted) {
        return granted;
      }

      setState(() {
        _hasBlePermissions = granted;
      });

      if (!silent) {
        _setStatus(
          granted
              ? _isMacOS
                    ? 'Bluetooth access granted.'
                    : 'Android BLE permissions granted.'
              : _isMacOS
              ? 'Bluetooth access was denied.'
              : 'Android BLE permissions were denied.',
        );
      }
      return granted;
    } catch (error) {
      if (!silent) {
        _setStatus(error.toString());
      }
      return false;
    }
  }

  Future<void> _enableBluetooth() async {
    if (_busyAction != null) {
      return;
    }

    _setBusy('Enable Bluetooth');
    try {
      if (_bluetooth == null || !await _ensureBlePermissions()) {
        return;
      }

      final enabled = await _bluetooth!.requestEnableBle();
      _setStatus(
        enabled == true
            ? 'Bluetooth enable request accepted.'
            : 'Bluetooth enable request was cancelled or denied.',
      );
    } catch (error) {
      _setStatus(error.toString());
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _startScan() async {
    if (_busyAction != null) {
      return;
    }

    _setBusy('Start Scan');
    try {
      if (_bluetooth == null || !await _ensureBlePermissions()) {
        return;
      }

      final started = await _bluetooth!.startScan();
      if (!mounted) {
        return;
      }

      setState(() {
        _isScanning = started;
        if (started) {
          _devices.clear();
        }
      });

      _setStatus(
        started
            ? 'Scanning for nearby BLE devices.'
            : 'Scan could not be started.',
      );
    } catch (error) {
      _setStatus(error.toString());
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _stopScan() async {
    if (_busyAction != null) {
      return;
    }

    _setBusy('Stop Scan');
    try {
      if (_bluetooth == null) {
        return;
      }

      final stopped = await _bluetooth!.stopScan();
      if (!mounted) {
        return;
      }

      setState(() {
        _isScanning = !stopped;
      });
      _setStatus(stopped ? 'Scan stopped.' : 'Scan stop request failed.');
    } catch (error) {
      _setStatus(error.toString());
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _showAccessorySetup() async {
    if (_busyAction != null) {
      return;
    }

    _setBusy('Accessory Setup');
    try {
      if (_bluetooth == null) {
        return;
      }

      final setupDevice = await _bluetooth!.setupDevice(
        iosPickerItems: exampleIosPickerItems,
      );
      await _loadKnownDevices(silent: true);

      final device = ExampleBleDevice(
        macId: setupDevice.peripheralId,
        deviceName: setupDevice.peripheralName.isNotEmpty
            ? setupDevice.peripheralName
            : primeAccessoryDisplayName,
      );

      if (!mounted) {
        return;
      }

      _setStatus('Selected ${device.macId}. Open it to connect.');
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => DevicePage(device: device),
        ),
      );
    } catch (error) {
      _setStatus(error.toString());
    } finally {
      _setBusy(null);
    }
  }

  Future<List<BleDeviceInfo>> _loadKnownDevices({
    bool silent = false,
    bool replace = false,
  }) async {
    if (_bluetooth == null) {
      return const <BleDeviceInfo>[];
    }

    try {
      final knownDevices = await _bluetooth!.getKnownDevices();
      if (!mounted) {
        return knownDevices;
      }

      final loadedDevices = <String, ExampleBleDevice>{};
      for (final knownDevice in knownDevices) {
        if (knownDevice.peripheralId.isEmpty) {
          continue;
        }

        final current = _devices[knownDevice.peripheralId];
        final resolvedName = knownDevice.peripheralName.isNotEmpty
            ? knownDevice.peripheralName
            : current?.deviceName ?? 'Unknown Device';
        loadedDevices[knownDevice.peripheralId] = ExampleBleDevice(
          macId: knownDevice.peripheralId,
          deviceName: resolvedName,
        );
      }

      setState(() {
        if (replace) {
          _devices
            ..clear()
            ..addAll(loadedDevices);
          return;
        }

        for (final knownDevice in knownDevices) {
          if (knownDevice.peripheralId.isEmpty) {
            continue;
          }

          _devices[knownDevice.peripheralId] =
              loadedDevices[knownDevice.peripheralId]!;
        }
      });

      return knownDevices;
    } catch (error) {
      if (!silent) {
        _setStatus(error.toString());
      }
      return const <BleDeviceInfo>[];
    }
  }

  Future<void> _removeDevice(ExampleBleDevice device) async {
    if (_busyAction != null) {
      return;
    }

    _setBusy('Remove Device');
    try {
      await _bluetooth?.disconnect(device.macId);
      final removed = await _bluetooth?.removeDevice(device.macId) ?? false;
      if (!mounted) {
        return;
      }

      await _loadKnownDevices(silent: true, replace: true);

      _setStatus(
        removed
            ? 'Removed ${device.deviceName}.'
            : 'Could not remove ${device.deviceName}.',
      );
    } catch (error) {
      _setStatus(error.toString());
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _openDevice(ExampleBleDevice device) async {
    if (_isScanning) {
      await _stopScan();
    }
    if (!mounted) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DevicePage(device: device),
      ),
    );
  }

  void _onScanEvent(BleScanEvent event) {
    if (!mounted) {
      return;
    }

    setState(() {
      switch (event.type) {
        case BluetoothConnectionEventType.scanStarted:
          _isScanning = true;
        case BluetoothConnectionEventType.scanStopped ||
            BluetoothConnectionEventType.scanError:
          _isScanning = false;
        case BluetoothConnectionEventType.deviceFound:
          final macId = event.deviceId;
          if (macId != null) {
            final current = _devices[macId];
            _devices[macId] = (current ?? ExampleBleDevice(macId: macId))
                .copyWith(
                  deviceName:
                      event.deviceName ??
                      current?.deviceName ??
                      'Unknown Device',
                );
          }
        default:
          break;
      }
    });

    switch (event.type) {
      case BluetoothConnectionEventType.scanStarted:
        _setStatus('Scanning for nearby BLE devices.');
      case BluetoothConnectionEventType.scanStopped:
        _setStatus('Scan stopped.');
      case BluetoothConnectionEventType.scanError:
        _setStatus('Scan failed.');
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Foundation BLE Console')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Scan Devices', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Text(_statusMessage),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      if (_needsBlePermissionFlow)
                        Chip(
                          label: Text(
                            _hasBlePermissions == null
                                ? 'BLE Access: Unknown'
                                : _hasBlePermissions!
                                ? 'BLE Access: Granted'
                                : 'BLE Access: Denied',
                          ),
                        ),
                      if (_busyAction != null) Chip(label: Text(_busyAction!)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Actions', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      if (_needsBlePermissionFlow)
                        ElevatedButton(
                          onPressed: () => _requestBleAccess(),
                          child: Text(_requestBleAccessLabel),
                        ),
                      if (_isAndroid)
                        ElevatedButton(
                          onPressed: () => _enableBluetooth(),
                          child: const Text('Enable Bluetooth'),
                        ),
                      if (_isAndroid || _isMacOS)
                        ElevatedButton(
                          onPressed: () => _startScan(),
                          child: Text(_isScanning ? 'Scanning…' : 'Start Scan'),
                        ),
                      if (_isAndroid || _isMacOS)
                        ElevatedButton(
                          onPressed: () => _stopScan(),
                          child: const Text('Stop Scan'),
                        ),
                      if (_isIOS)
                        ElevatedButton(
                          onPressed: () => _showAccessorySetup(),
                          child: const Text('Show Accessory Setup'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Devices', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    _isIOS
                        ? 'Use Accessory Setup to choose a device, then open it.'
                        : 'Scan first, then tap a device to open the connect and write screen.',
                  ),
                  const SizedBox(height: 12),
                  if (!_supportsBleDemo)
                    const SizedBox.shrink()
                  else if (_sortedDevices.isEmpty)
                    Text(
                      _isScanning
                          ? 'Scanning now. Devices will appear here.'
                          : _isIOS
                          ? 'No device selected yet.'
                          : 'No devices yet. Start a scan to discover one.',
                    )
                  else
                    ..._sortedDevices.map((device) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => _openDevice(device),
                          title: Text(device.deviceName),
                          subtitle: Text(device.macId),
                          isThreeLine: true,
                          trailing: IconButton(
                            onPressed: () => _removeDevice(device),
                            icon: const Icon(Icons.delete_forever),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
