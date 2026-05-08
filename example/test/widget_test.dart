// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:foundation_ble_example/device_page.dart';
import 'package:foundation_ble_example/main.dart';

void main() {
  testWidgets('renders scan-first BLE shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Foundation BLE Console'), findsOneWidget);
    expect(find.text('Scan Devices'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Start Scan'), findsOneWidget);
  });

  testWidgets('shows unsupported message on non-BLE desktop targets', (
    WidgetTester tester,
  ) async {
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    await tester.pumpWidget(const MyApp());

    expect(find.text('Foundation BLE Console'), findsOneWidget);
    expect(
      find.text('This demo is available on Android, iOS, and macOS only.'),
      findsOneWidget,
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reloads iOS devices after removeDevice completes', (
    WidgetTester tester,
  ) async {
    TestWidgetsFlutterBinding.ensureInitialized();

    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('foundation_ble/bluetooth'),
        null,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    var devices = <Map<String, Object?>>[
      <String, Object?>{
        'peripheralId': 'ios-device',
        'peripheralName': 'Passport Prime',
        'isConnected': false,
        'state': 0,
        'bondState': true,
      },
    ];
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('foundation_ble/bluetooth'),
      (MethodCall call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'getAccessories':
            return devices;
          case 'removeDevice':
            devices = <Map<String, Object?>>[];
            return true;
          default:
            return null;
        }
      },
    );

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Passport Prime'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_forever));
    await tester.pump();
    await tester.pump();

    expect(find.text('Passport Prime'), findsNothing);
    expect(calls, <String>['getAccessories', 'removeDevice', 'getAccessories']);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('renders device logs placeholder on the device page', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DevicePage(device: ExampleBleDevice(macId: '00:11:22:33:44:55')),
      ),
    );
    await tester.pump();

    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Write 5 MB Hex Test'), findsOneWidget);
    expect(find.text('Choose a transport and connect.'), findsOneWidget);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Logs'), findsOneWidget);
    expect(
      find.text('No BLE messages yet. Connect and wait for incoming data.'),
      findsOneWidget,
    );
  });

  testWidgets('allows selecting l2cap on macOS', (WidgetTester tester) async {
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await tester.pumpWidget(
      const MaterialApp(
        home: DevicePage(device: ExampleBleDevice(macId: '00:11:22:33:44:55')),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('L2CAP'));
    await tester.pump();

    expect(find.text('Transport set to L2CAP.'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });
}
