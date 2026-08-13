import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/connector/serial_native.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/connection_readiness_card.dart';
import 'package:chameleonultragui/gui/page/connect.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/pending_connection.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connection_readiness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';

void main() {
  for (final connectionType in [ConnectionType.ble, ConnectionType.usb]) {
    testWidgets(
      'tapping a ${connectionType.name.toUpperCase()} device preserves its '
      'transport, shows progress immediately, and opens Home after connect',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'auto_connect_first_found': false,
        });
        final connectGate = Completer<void>();
        final logger = Logger(output: MemoryOutput());
        final selectedDevice = Chameleon(
          port: connectionType == ConnectionType.ble
              ? 'ble-device-a'
              : '/dev/usb-device-a',
          device: ChameleonDevice.ultra,
          type: connectionType,
          dfu: false,
        );
        final serial = _DelayedConnectSerial(
          log: logger,
          gate: connectGate,
          selectedDevice: selectedDevice,
        );
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

        expect(serial.connectCalls, 1);
        expect(find.byType(PendingConnectionPage), findsOneWidget);
        expect(find.byType(ConnectionReadinessCard), findsOneWidget);
        expect(serial.receivedSelection, same(selectedDevice));

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
      'failed ${connectionType.name.toUpperCase()} connection returns to '
      'discovery without using the unmounted connection page',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'auto_connect_first_found': false,
        });
        final connectGate = Completer<void>();
        final logger = Logger(output: MemoryOutput());
        final selectedDevice = Chameleon(
          port: connectionType == ConnectionType.ble
              ? 'ble-device-a'
              : '/dev/usb-device-a',
          device: ChameleonDevice.ultra,
          type: connectionType,
          dfu: false,
        );
        final serial = _DelayedConnectSerial(
          log: logger,
          gate: connectGate,
          selectedDevice: selectedDevice,
          connectResult: false,
        );
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

        connectGate.complete();
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(ConnectPage), findsOneWidget);
        expect(serial.connectCalls, 1);
        expect(
          appState.connectionReadiness.snapshot.stage,
          ConnectionReadinessStage.failed,
        );
        expect(find.text('Connection failed'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 500));
        appState.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'readiness stage replaces refresh until discovery finds a device',
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
            home: ConnectPage(autoScanInterval: Duration(milliseconds: 20)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(serial.scanCalls, 1);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byType(ConnectionReadinessCard), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 2);
      expect(find.byType(ConnectionReadinessCard), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 3);
      expect(find.text('device-a'), findsOneWidget);
      expect(find.byType(ConnectionReadinessCard), findsNothing);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 4);
      expect(find.text('device-a'), findsOneWidget);
      expect(find.text('device-b'), findsOneWidget);
      expect(find.byType(ConnectionReadinessCard), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('discovery failures use the redacted readiness surface', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'auto_connect_first_found': false});
    const sensitiveError = 'private-device-path-/dev/cu.secret';
    final serial = _FailingDiscoverySerial(
      log: Logger(output: MemoryOutput()),
      error: StateError(sensitiveError),
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
          home: ConnectPage(autoScanInterval: Duration(seconds: 10)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      appState.connectionReadiness.snapshot.stage,
      ConnectionReadinessStage.failed,
    );
    expect(find.byType(ConnectionReadinessCard), findsOneWidget);
    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.textContaining(sensitiveError), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    appState.dispose();
  });

  testWidgets(
    'a late discovery error cannot disconnect a replacement connector',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'auto_connect_first_found': false,
      });
      final discovery = Completer<List<Chameleon>>();
      final origin = _ControlledDiscoverySerial(
        log: Logger(output: MemoryOutput()),
        discovery: discovery.future,
      );
      final preferences = SharedPreferencesProvider();
      await preferences.load();
      final appState = ChameleonGUIState(preferences)
        ..connector = origin
        ..log = origin.log;

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ConnectPage(autoScanInterval: Duration(seconds: 10)),
          ),
        ),
      );
      await tester.pump();
      expect(origin.scanCalls, 1);

      final replacement = _ReplacementSerial(
        log: Logger(output: MemoryOutput()),
      );
      appState.connector = replacement;
      discovery.completeError(StateError('late origin discovery failure'));
      await tester.pump();
      await tester.pump();

      expect(replacement.disconnectCalls, 0);
      expect(replacement.connected, isTrue);
      expect(appState.connector, same(replacement));

      await tester.pumpWidget(const SizedBox.shrink());
      appState.dispose();
    },
  );

  test(
    'native discovery keeps FFI-bound probing on the caller isolate',
    () async {
      final callerIsolate = Isolate.current;
      final serial = NativeSerial(
        log: Logger(output: MemoryOutput()),
        discoveryCallback: (onlyDFU) {
          expect(Isolate.current, same(callerIsolate));
          return const [];
        },
      );

      expect(await serial.availableChameleons(false), isEmpty);
    },
  );

  test('native USB uses stock firmware serial flow control', () {
    expect(NativeSerial.flowControlForTesting, SerialPortFlowControl.none);
  });
}

class _DelayedConnectSerial extends EmulatorSerial {
  _DelayedConnectSerial({
    required super.log,
    required this.gate,
    required this.selectedDevice,
    this.connectResult = true,
  });

  final Completer<void> gate;
  final Chameleon selectedDevice;
  final bool connectResult;
  final Completer<bool> statusWriteGate = Completer<bool>();
  dynamic receivedSelection;
  int connectCalls = 0;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [
        selectedDevice,
      ];

  @override
  Future<bool> connectSpecificDevice(dynamic selection) async {
    connectCalls++;
    receivedSelection = selection;
    await gate.future;
    if (!connectResult) {
      return false;
    }
    return super.connectSpecificDevice(
      selection is Chameleon ? selection.port : selection,
    );
  }

  @override
  Future<bool> connectDiscoveredDevice(Chameleon selection) async {
    connectCalls++;
    receivedSelection = selection;
    await gate.future;
    if (!connectResult) {
      return false;
    }
    return super.connectSpecificDevice(selection.port);
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

class _FailingDiscoverySerial extends AbstractSerial {
  _FailingDiscoverySerial({required super.log, required this.error});

  final Object error;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async =>
      throw error;

  @override
  Future<bool> performDisconnect() async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => false;
}

class _ControlledDiscoverySerial extends AbstractSerial {
  _ControlledDiscoverySerial({required super.log, required this.discovery});

  final Future<List<Chameleon>> discovery;
  int scanCalls = 0;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) {
    scanCalls++;
    return discovery;
  }

  @override
  Future<bool> performDisconnect() async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => false;
}

class _ReplacementSerial extends AbstractSerial {
  _ReplacementSerial({required super.log}) {
    connected = true;
    device = ChameleonDevice.ultra;
    connectionType = ConnectionType.usb;
    portName = '/dev/replacement';
    activeDevicePort = portName;
  }

  int disconnectCalls = 0;

  @override
  Future<bool> performDisconnect() async {
    disconnectCalls++;
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
