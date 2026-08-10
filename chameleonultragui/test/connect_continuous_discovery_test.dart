import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:chameleonultragui/gui/page/connect.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/pending_connection.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';

void main() {
  testWidgets(
    'tapping a BLE device shows progress immediately and opens Home after connect',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'auto_connect_first_found': false,
      });
      final connectGate = Completer<void>();
      final logger = Logger(output: MemoryOutput());
      final serial = _DelayedConnectSerial(log: logger, gate: connectGate);
      final preferences = SharedPreferencesProvider();
      await preferences.load();
      final appState = ChameleonGUIState(
        preferences,
        firmwareCatalog: const CurrentFirmwareCatalogStub(),
      )
        ..connector = serial
        ..log = logger;
      addTearDown(logger.close);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: MainPage(sharedPreferencesProvider: preferences),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Chameleon Ultra'));
      await tester.pump();

      expect(find.byType(PendingConnectionPage), findsOneWidget);
      expect(find.byType(ChameleonLoadingIndicator), findsOneWidget);

      connectGate.complete();
      await tester.pump();
      await tester.pump();

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byKey(const Key('home-bottom-dashboard')), findsOneWidget);
      expect(appState.communicator, isNotNull);

      await tester.pump(const Duration(milliseconds: 500));
      await appState.disconnect();
      appState.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'loader replaces refresh until discovery finds a device',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'auto_connect_first_found': false,
      });
      final serial = _DiscoverySerial(
        log: Logger(output: MemoryOutput()),
        scans: const [
          [],
          [],
          [
            Chameleon(
              port: 'device-a',
              device: ChameleonDevice.ultra,
              type: ConnectionType.ble,
              dfu: false,
            ),
          ],
          [
            Chameleon(
              port: 'device-b',
              device: ChameleonDevice.lite,
              type: ConnectionType.ble,
              dfu: false,
            ),
          ],
        ],
      );
      final preferences = SharedPreferencesProvider();
      await preferences.load();
      final appState = ChameleonGUIState(preferences)
        ..connector = serial
        ..log = serial.log;

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ConnectPage(
              autoScanInterval: Duration(milliseconds: 20),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(serial.scanCalls, 1);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byType(ChameleonLoadingIndicator), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 2);
      expect(find.byType(ChameleonLoadingIndicator), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 3);
      expect(find.text('device-a'), findsOneWidget);
      expect(find.byType(ChameleonLoadingIndicator), findsNothing);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 4);
      expect(find.text('device-a'), findsOneWidget);
      expect(find.text('device-b'), findsOneWidget);
      expect(find.byType(ChameleonLoadingIndicator), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _DelayedConnectSerial extends EmulatorSerial {
  _DelayedConnectSerial({required super.log, required this.gate});

  final Completer<void> gate;
  final Completer<bool> statusWriteGate = Completer<bool>();

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [
        Chameleon(
          port: 'device-a',
          device: ChameleonDevice.ultra,
          type: ConnectionType.ble,
          dfu: false,
        ),
      ];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    await gate.future;
    return super.connectSpecificDevice(devicePort);
  }

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) =>
      statusWriteGate.future;
}

class _DiscoverySerial extends AbstractSerial {
  _DiscoverySerial({required super.log, required this.scans});

  final List<List<Chameleon>> scans;
  int scanCalls = 0;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    final index = scanCalls < scans.length ? scanCalls : scans.length - 1;
    scanCalls++;
    return scans[index];
  }

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => false;
}
