import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:foundation_ble/foundation_ble.dart';

class ExampleBleDevice {
  const ExampleBleDevice({
    required this.macId,
    this.deviceName = 'Unknown Device',
  });

  final String macId;
  final String deviceName;

  ExampleBleDevice copyWith({String? deviceName}) {
    return ExampleBleDevice(
      macId: macId,
      deviceName: deviceName ?? this.deviceName,
    );
  }
}

class _BleLogEntry {
  const _BleLogEntry({required this.timestamp, required this.message});

  final DateTime timestamp;
  final String message;

  String get timeLabel {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.device});

  final ExampleBleDevice device;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  late final _BleDemoController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _BleDemoController(device: widget.device);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) {
        final theme = Theme.of(context);
        final logs = _controller.logs.reversed.toList(growable: false);
        return Scaffold(
          appBar: AppBar(
            title: Text(_controller.deviceName),
            actions: [
              SizedBox.square(
                dimension: 22,
                child: Opacity(
                  opacity: _controller.isBusy ? 1 : 0,
                  child: CircularProgressIndicator(
                    strokeWidth: 1,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Connection', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: <Widget>[
                          Chip(
                            label: Text(
                              _controller.isConnected
                                  ? 'Connected'
                                  : 'Disconnected',
                            ),
                          ),
                          Chip(
                            label: Text(
                              _controller.isReady
                                  ? 'Ready for Write'
                                  : 'Not Ready',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        children: [
                          OutlinedButton(
                            onPressed: () => _controller.connect(),
                            child: const Text('Connect'),
                          ),
                          OutlinedButton(
                            onPressed: () => _controller.disconnect(),
                            child: const Text('Disconnect'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _controller.utf8Controller,
                        enabled: _controller.canWrite,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'UTF-8 Payload',
                          hintText: 'ping',
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _controller.hexController,
                        enabled: _controller.canWrite,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Hex Payload',
                          hintText: '68 65 6c 6c 6f',
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: <Widget>[
                          ElevatedButton(
                            onPressed: _controller.canWrite
                                ? () => _controller.writeUtf8()
                                : null,
                            child: const Text('Write UTF-8'),
                          ),
                          ElevatedButton(
                            onPressed: _controller.canWrite
                                ? () => _controller.writeHex()
                                : null,
                            child: const Text('Write Hex'),
                          ),
                          ElevatedButton(
                            onPressed: _controller.canWrite
                                ? () => _controller.writeLargeHexPayload()
                                : null,
                            child: const Text('Write 5 MB Hex Test'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Status', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 8),
                            Text(_controller.statusMessage),
                            if (_controller.transferProgress
                                case final progress?) ...<Widget>[
                              const SizedBox(height: 12),
                              LinearProgressIndicator(value: progress),
                              const SizedBox(height: 8),
                              Text(
                                '${(progress * 100).toStringAsFixed(1)}% complete',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
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
                      Text('Logs', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(
                        'Anything received from the BLE connection appears here.',
                      ),
                      const SizedBox(height: 12),
                      if (logs.isEmpty)
                        Text(
                          'No BLE messages yet. Connect and wait for incoming data.',
                        )
                      else
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: logs.length,
                          itemBuilder: (BuildContext context, int index) {
                            return _BleLogTile(entry: logs[index]);
                          },
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BleLogTile extends StatelessWidget {
  const _BleLogTile({required this.entry});

  final _BleLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            entry.timeLabel,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            entry.message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _BleDemoController extends ChangeNotifier {
  _BleDemoController({required this.device});

  static const int _largeHexTransferBytes = 5 * 1024 * 1024;
  static const int _gattWriteChunkSize = 240;
  static const int _progressUpdateIntervalBytes = 64 * 1024;

  final ExampleBleDevice device;
  final TextEditingController utf8Controller = TextEditingController(
    text: 'ping',
  );
  final TextEditingController hexController = TextEditingController(
    text: '68 65 6C 6C 6F',
  );

  FoundationBle? _bluetooth;
  BleConnection? _connection;
  DeviceStatus? _deviceStatus;
  StreamSubscription<DeviceStatus>? _statusSubscription;
  StreamSubscription<Uint8List>? _readSubscription;
  final List<_BleLogEntry> _logs = <_BleLogEntry>[];

  String _statusMessage = 'Connect to get started.';
  String? _busyAction;
  double? _transferProgress;
  bool _disposed = false;

  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  bool get needsBlePermissions => isAndroid || isMacOS;

  String get statusMessage => _statusMessage;

  String? get busyAction => _busyAction;

  double? get transferProgress => _transferProgress;

  List<_BleLogEntry> get logs => List<_BleLogEntry>.unmodifiable(_logs);

  String get deviceName => _deviceStatus?.peripheralName ?? device.deviceName;

  bool get isConnected => _deviceStatus?.connected ?? false;

  bool get isReady => _deviceStatus?.readyForWrite ?? false;

  bool get canWrite => _hasWritableConnection && !isBusy;

  bool get isBusy => _busyAction != null;

  Future<void> initialize() async {
    await _resetBleSession(clearLogs: true);
    _setStatus('Connect to get started.');
  }

  Future<void> connect() async {
    const label = 'Connect';
    if (isBusy) {
      return;
    }

    _setBusy(label);
    try {
      await _connect();
    } catch (error) {
      _setStatus('$label failed: $error');
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _connect() async {
    _clearTransferProgress(notify: false);
    await _ensureBlePermissions();

    final connection = await _ble.connect(device.macId);

    await _bindConnection(connection);
    _setStatus('Connected to ${connection.deviceId}.');
  }

  Future<void> disconnect() async {
    const label = 'Disconnect';
    if (isBusy) {
      return;
    }

    _setBusy(label);
    try {
      await _disconnect();
    } catch (error) {
      _setStatus('$label failed: $error');
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _disconnect() async {
    _clearTransferProgress(notify: false);
    if (_connection == null && !_ble.hasDeviceConnection(device.macId)) {
      _setStatus('Nothing is connected yet.');
      return;
    }

    await _ble.disconnect(device.macId);
    _setStatus('Disconnect requested.');
  }

  Future<void> writeUtf8() async {
    const label = 'Write UTF-8';
    if (isBusy) {
      return;
    }

    _setBusy(label);
    try {
      await _writeUtf8();
    } catch (error) {
      _setStatus('$label failed: $error');
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _writeUtf8() async {
    _clearTransferProgress(notify: false);
    if (!_hasWritableConnection || _connection == null) {
      _setStatus('Connect first before writing.');
      return;
    }

    final data = Uint8List.fromList(utf8.encode(utf8Controller.text));
    final success = await _connection!.write(data);
    _setStatus(success ? 'UTF-8 payload sent.' : 'UTF-8 payload write failed.');
  }

  Future<void> writeHex() async {
    const label = 'Write Hex';
    if (isBusy) {
      return;
    }

    _setBusy(label);
    try {
      await _writeHex();
    } catch (error) {
      _setStatus('$label failed: $error');
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _writeHex() async {
    _clearTransferProgress(notify: false);
    if (!_hasWritableConnection || _connection == null) {
      _setStatus('Connect first before writing.');
      return;
    }

    final data = _parseHex(hexController.text);
    if (data == null) {
      _setStatus('Hex input must contain complete byte pairs.');
      return;
    }

    final success = await _connection!.write(data);
    _setStatus(success ? 'Hex payload sent.' : 'Hex payload write failed.');
  }

  Future<void> writeLargeHexPayload() async {
    const label = 'Write 5 MB Hex Test';
    if (isBusy) {
      return;
    }

    _setBusy(label);
    try {
      await _writeLargeHexPayload();
    } catch (error) {
      _setStatus('$label failed: $error');
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _writeLargeHexPayload() async {
    if (!_hasWritableConnection || _connection == null) {
      _clearTransferProgress(notify: false);
      _setStatus('Connect first before running the 5 MB hex test.');
      return;
    }

    if (isAndroid && _connection is AndroidBleConnectionCapability) {
      final androidConnection = _connection! as AndroidBleConnectionCapability;
      await androidConnection.requestPhy2();
      await Future.delayed(Duration(milliseconds: 500));
    }

    final seed = _parseHex(hexController.text);
    if (seed == null) {
      _clearTransferProgress(notify: false);
      _setStatus('Hex input must contain complete byte pairs.');
      return;
    }
    if (seed.isEmpty) {
      _clearTransferProgress(notify: false);
      _setStatus('Enter at least one hex byte before starting the 5 MB test.');
      return;
    }

    const chunkSize = _gattWriteChunkSize;
    final payloadTemplate = _buildRepeatedPayload(seed, chunkSize);
    final stopwatch = Stopwatch()..start();
    var bytesWritten = 0;
    var lastReportedBytes = 0;

    _updateTransferProgress(
      bytesWritten: bytesWritten,
      totalBytes: _largeHexTransferBytes,
      chunkSize: chunkSize,
      elapsed: stopwatch.elapsed,
    );

    while (bytesWritten < _largeHexTransferBytes) {
      if (!_hasWritableConnection || _connection == null) {
        stopwatch.stop();
        _updateTransferProgress(
          bytesWritten: bytesWritten,
          totalBytes: _largeHexTransferBytes,
          chunkSize: chunkSize,
          elapsed: stopwatch.elapsed,
        );
        _setStatus(
          '5 MB hex test interrupted after ${_formatMiB(bytesWritten)} MiB.',
        );
        return;
      }

      final remainingBytes = _largeHexTransferBytes - bytesWritten;
      final payload = remainingBytes >= payloadTemplate.length
          ? payloadTemplate
          : Uint8List.sublistView(payloadTemplate, 0, remainingBytes);

      final success = await _connection!.write(payload);
      if (!success) {
        stopwatch.stop();
        _updateTransferProgress(
          bytesWritten: bytesWritten,
          totalBytes: _largeHexTransferBytes,
          chunkSize: chunkSize,
          elapsed: stopwatch.elapsed,
        );
        _setStatus(
          '5 MB hex test failed after ${_formatMiB(bytesWritten)} MiB.',
        );
        return;
      }

      bytesWritten += payload.length;
      final shouldReport =
          bytesWritten == _largeHexTransferBytes ||
          bytesWritten - lastReportedBytes >= _progressUpdateIntervalBytes;
      if (shouldReport) {
        lastReportedBytes = bytesWritten;
        _updateTransferProgress(
          bytesWritten: bytesWritten,
          totalBytes: _largeHexTransferBytes,
          chunkSize: chunkSize,
          elapsed: stopwatch.elapsed,
        );
      }
    }

    stopwatch.stop();
    final throughput = _formatKBPerSecond(
      bytes: _largeHexTransferBytes,
      elapsed: stopwatch.elapsed,
    );
    _updateTransferProgress(
      bytesWritten: _largeHexTransferBytes,
      totalBytes: _largeHexTransferBytes,
      chunkSize: chunkSize,
      elapsed: stopwatch.elapsed,
      finalMessage:
          '5 MB hex test complete in ${_formatSeconds(stopwatch.elapsed)} s at $throughput kB/s.',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_statusSubscription?.cancel());
    unawaited(_readSubscription?.cancel());
    if (_bluetooth != null) {
      unawaited(_bluetooth!.dispose());
    }
    utf8Controller.dispose();
    hexController.dispose();
    super.dispose();
  }

  Future<void> _ensureBlePermissions() async {
    if (!needsBlePermissions || _bluetooth == null) {
      return;
    }

    await _bluetooth!.requestBlePermissions();
  }

  Future<void> _bindConnection(BleConnection connection) async {
    await _statusSubscription?.cancel();
    await _readSubscription?.cancel();

    _connection = connection;
    _deviceStatus = null;
    _statusSubscription = connection.deviceStatusStream.listen(_onDeviceStatus);
    _readSubscription = connection.readStream.listen(_onReadData);

    final initialStatus = await connection.getCurrentDeviceStatus();
    _onDeviceStatus(initialStatus);
  }

  Future<void> _resetBleSession({bool clearLogs = false}) async {
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    await _readSubscription?.cancel();
    _readSubscription = null;

    if (_bluetooth == null) {
      _bluetooth = FoundationBle();
    } else {
      await _bluetooth!.disconnect(device.macId);
      _bluetooth!.removeDeviceConnection(device.macId);
    }
    _connection = null;
    _deviceStatus = null;
    _transferProgress = null;
    if (clearLogs) {
      _logs.clear();
    }
    _safeNotifyListeners();
  }

  void _onDeviceStatus(DeviceStatus status) {
    _deviceStatus = status;
    if (status.type != null) {
      _statusMessage = _statusMessageForEvent(status);
    } else if (status.error case final String error when error.isNotEmpty) {
      _statusMessage = error;
    }
    _safeNotifyListeners();
  }

  void _onReadData(Uint8List data) {
    if (_busyAction != 'Write 5 MB Hex Test') {
      _statusMessage = 'Received ${data.length} byte(s).';
    }
    _appendLog(
      _BleLogEntry(
        timestamp: DateTime.now(),
        message: _formatIncomingMessage(data),
      ),
      notify: false,
    );
    _safeNotifyListeners();
  }

  void _setBusy(String? action) {
    _busyAction = action;
    _safeNotifyListeners();
  }

  void _setStatus(String message) {
    _statusMessage = message;
    _safeNotifyListeners();
  }

  void _clearTransferProgress({bool notify = true}) {
    _transferProgress = null;
    if (notify) {
      _safeNotifyListeners();
    }
  }

  void _updateTransferProgress({
    required int bytesWritten,
    required int totalBytes,
    required int chunkSize,
    required Duration elapsed,
    String? finalMessage,
  }) {
    _transferProgress = totalBytes == 0 ? null : bytesWritten / totalBytes;
    final liveThroughput = elapsed.inMicroseconds == 0
        ? null
        : _formatKBPerSecond(bytes: bytesWritten, elapsed: elapsed);
    _statusMessage =
        finalMessage ??
        'Writing ${_formatMiB(bytesWritten)} / ${_formatMiB(totalBytes)} MiB in '
            '$chunkSize-byte chunks${liveThroughput == null ? '' : ' at $liveThroughput kB/s'}...';
    _safeNotifyListeners();
  }

  void _appendLog(_BleLogEntry entry, {bool notify = true}) {
    _logs.add(entry);
    const maxLogs = 50;
    if (_logs.length > maxLogs) {
      _logs.removeRange(0, _logs.length - maxLogs);
    }
    if (notify) {
      _safeNotifyListeners();
    }
  }

  void _safeNotifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool get _hasWritableConnection => _connection != null && isReady;

  String _statusMessageForEvent(DeviceStatus status) {
    final deviceLabel =
        status.peripheralName ?? status.peripheralId ?? device.deviceName;

    return switch (status.type) {
      BluetoothConnectionEventType.connectionAttempt =>
        'Connecting to $deviceLabel...',
      BluetoothConnectionEventType.deviceConnected =>
        status.readyForWrite
            ? 'Connected to $deviceLabel and ready for write.'
            : 'Connected to $deviceLabel.',
      BluetoothConnectionEventType.deviceDisconnected =>
        status.error == null
            ? 'Disconnected from $deviceLabel.'
            : 'Disconnected from $deviceLabel: ${status.error}',
      BluetoothConnectionEventType.connectionError =>
        status.error == null
            ? 'Connection failed.'
            : 'Connection failed: ${status.error}',
      _ => _statusMessage,
    };
  }

  String _formatIncomingMessage(Uint8List data) {
    final text = _tryDecodeUtf8(data);
    if (text != null && text.isNotEmpty) {
      return text;
    }
    return _formatHex(data);
  }

  Uint8List? _parseHex(String input) {
    final normalized = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (normalized.isEmpty) {
      return Uint8List(0);
    }
    if (normalized.length.isOdd) {
      return null;
    }

    final values = <int>[];
    for (var index = 0; index < normalized.length; index += 2) {
      values.add(int.parse(normalized.substring(index, index + 2), radix: 16));
    }
    return Uint8List.fromList(values);
  }

  Uint8List _buildRepeatedPayload(Uint8List seed, int length) {
    final payload = Uint8List(length);
    for (var index = 0; index < length; index++) {
      payload[index] = seed[index % seed.length];
    }
    return payload;
  }

  String _formatHex(Uint8List data) {
    if (data.isEmpty) {
      return '<empty>';
    }

    return data
        .map((int value) => value.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();
  }

  String _formatMiB(int bytes) {
    return (bytes / (1024 * 1024)).toStringAsFixed(2);
  }

  String _formatKBPerSecond({required int bytes, required Duration elapsed}) {
    if (elapsed.inMicroseconds == 0) {
      return '0';
    }

    final kbPerSecond = (bytes / 1024) / (elapsed.inMicroseconds / 1000000);
    return kbPerSecond.toStringAsFixed(0);
  }

  String _formatSeconds(Duration elapsed) {
    return (elapsed.inMilliseconds / 1000).toStringAsFixed(2);
  }

  String? _tryDecodeUtf8(Uint8List data) {
    try {
      final decoded = utf8.decode(data);
      final hasControlCharacters = decoded.runes.any(
        (int rune) =>
            rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D,
      );
      if (hasControlCharacters) {
        return null;
      }
      return decoded;
    } on FormatException {
      return null;
    }
  }

  FoundationBle get _ble => _bluetooth!;
}
