import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/pending_connection.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:chameleonultragui/status/connection_readiness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';

void main() {
  for (final transport in [ConnectionType.ble, ConnectionType.usb]) {
    testWidgets(
      'pending ${transport.name.toUpperCase()} connection names its transport '
      'without a blocking spinner',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'auto_connect_first_found': false,
        });
        final gate = Completer<void>();
        final selected = Chameleon(
          port: transport == ConnectionType.ble
              ? 'ble-readiness-device'
              : '/dev/readiness-device',
          device: ChameleonDevice.ultra,
          type: transport,
          dfu: false,
        );
        final serial = _PendingSerial(
          log: Logger(output: MemoryOutput()),
          selected: selected,
          gate: gate,
        );
        final preferences = SharedPreferencesProvider();
        await preferences.load();
        final appState = ChameleonGUIState(preferences)
          ..connector = serial
          ..log = serial.log;

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
        expect(find.byType(ChameleonLoadingIndicator), findsNothing);
        expect(
          find.text(
            transport == ConnectionType.ble
                ? 'Connecting over Bluetooth'
                : 'Connecting over USB',
          ),
          findsOneWidget,
        );

        gate.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpWidget(const SizedBox.shrink());
        appState.dispose();
      },
    );
  }

  testWidgets(
    'Home traces protocol and initial status before becoming ready',
    (tester) async {
      final protocol = Completer<FirmwareVersion>();
      final slots = Completer<void>();
      final communicator = _ReadinessCommunicator(
        protocol: protocol.future,
        slotsGate: slots.future,
      );
      final fixture = await _mountHome(tester, communicator);

      expect(find.text('Waiting for Chameleon'), findsOneWidget);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.waitingForProtocol,
      );

      protocol.complete(_currentFirmware);
      await _pumpFrames(tester, 3);

      expect(find.text('Loading device status'), findsOneWidget);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.loadingStatus,
      );

      slots.complete();
      await _pumpFrames(tester, 12);

      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );
      expect(find.byKey(const Key('connection-readiness')), findsNothing);
      expect(
        fixture.appState.connectedDeviceStatus!.snapshot.slots.availability,
        SlotsAvailability.available,
      );
      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an unavailable optional facet degrades Home without hiding confirmed data',
    (tester) async {
      final communicator = _ReadinessCommunicator(failBattery: true);
      final fixture = await _mountHome(tester, communicator);
      await _pumpFrames(tester, 12);

      final readiness = fixture.appState.connectionReadiness.snapshot;
      final status = fixture.appState.connectedDeviceStatus!.snapshot;
      expect(readiness.stage, ConnectionReadinessStage.degraded);
      expect(
        readiness.errorCategory,
        ConnectionReadinessErrorCategory.status,
      );
      expect(find.text('Connected with limited status'), findsOneWidget);
      expect(find.text('--%'), findsOneWidget);
      expect(status.slots.availability, SlotsAvailability.available);
      expect(status.slots.activeSlot.value, 0);

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a bounded status timeout degrades first and late confirmed data recovers',
    (tester) async {
      final slots = Completer<void>();
      final communicator = _ReadinessCommunicator(slotsGate: slots.future);
      final fixture = await _mountHome(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );

      await tester.pump(const Duration(milliseconds: 25));
      await _pumpFrames(tester, 4);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );
      expect(
        fixture.appState.connectionReadiness.snapshot.errorCategory,
        ConnectionReadinessErrorCategory.timeout,
      );

      slots.complete();
      await _pumpFrames(tester, 8);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a bounded protocol timeout is a redacted failed stage',
      (tester) async {
    final protocol = Completer<FirmwareVersion>();
    final communicator = _ReadinessCommunicator(protocol: protocol.future);
    final fixture = await _mountHome(
      tester,
      communicator,
      timeouts: const ConnectionReadinessTimeouts(
        protocol: Duration(milliseconds: 20),
        statusFacet: Duration(milliseconds: 20),
      ),
    );

    await tester.pump(const Duration(milliseconds: 25));
    await _pumpFrames(tester, 2);
    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('The device did not respond in time.'), findsOneWidget);
    expect(
      fixture.appState.connectionReadiness.snapshot.errorCategory,
      ConnectionReadinessErrorCategory.timeout,
    );

    protocol.complete(_currentFirmware);
    fixture.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'late protocol result cannot replace a newer device readiness session',
    (tester) async {
      final oldProtocol = Completer<FirmwareVersion>();
      final oldCommunicator = _ReadinessCommunicator(
        protocol: oldProtocol.future,
      );
      final fixture = await _mountHome(tester, oldCommunicator);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.waitingForProtocol,
      );

      final replacementSerial = _ReadinessSerial(
        log: Logger(output: MemoryOutput()),
        type: ConnectionType.usb,
        port: '/dev/replacement',
      );
      fixture.appState
        ..connector = replacementSerial
        ..communicator = _ReadinessCommunicator()
        ..changesMade();
      await _pumpFrames(tester, 12);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );
      expect(
        fixture.appState.connectedDeviceStatus!.snapshot.identity.portName,
        '/dev/replacement',
      );

      oldProtocol.complete(_currentFirmware);
      await _pumpFrames(tester, 6);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );
      expect(
        fixture.appState.connectedDeviceStatus!.snapshot.identity.portName,
        '/dev/replacement',
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('readiness history records elapsed stages and redacted categories', () {
    var now = DateTime.utc(2026, 8, 13, 10);
    final tracker = ConnectionReadinessTracker(now: () => now);
    final discovery = tracker.beginDiscovery();
    now = now.add(const Duration(milliseconds: 250));
    final transport = tracker.beginTransport(ConnectionType.ble);
    expect(tracker.isCurrent(discovery), isTrue);
    expect(tracker.isCurrent(transport), isTrue);
    now = now.add(const Duration(milliseconds: 500));
    final session = tracker.attachSession(ConnectionType.ble);
    now = now.add(const Duration(seconds: 2));
    tracker.fail(session, ConnectionReadinessErrorCategory.timeout);

    expect(
      tracker.snapshot.history.map((record) => record.stage),
      [
        ConnectionReadinessStage.discovering,
        ConnectionReadinessStage.connectingTransport,
        ConnectionReadinessStage.waitingForProtocol,
      ],
    );
    expect(
        tracker.snapshot.history[0].elapsed, const Duration(milliseconds: 250));
    expect(
        tracker.snapshot.history[1].elapsed, const Duration(milliseconds: 500));
    expect(tracker.snapshot.terminalElapsed, const Duration(seconds: 2));
    expect(
      tracker.snapshot.errorCategory,
      ConnectionReadinessErrorCategory.timeout,
    );
    tracker.dispose();
  });
}

final _currentFirmware = FirmwareVersion(
  legacyProtocol: false,
  version: 0x0202,
);

class _ReadinessFixture {
  const _ReadinessFixture(this.appState);

  final ChameleonGUIState appState;

  void dispose() => appState.dispose();
}

Future<_ReadinessFixture> _mountHome(
  WidgetTester tester,
  _ReadinessCommunicator communicator, {
  ConnectionReadinessTimeouts timeouts = const ConnectionReadinessTimeouts(),
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = SharedPreferencesProvider();
  await preferences.load();
  final serial = _ReadinessSerial(
    log: Logger(output: MemoryOutput()),
    type: ConnectionType.usb,
    port: '/dev/readiness',
  );
  final appState = ChameleonGUIState(
    preferences,
    firmwareCatalog: const CurrentFirmwareCatalogStub(),
    connectionReadinessTimeouts: timeouts,
  )
    ..connector = serial
    ..log = serial.log
    ..communicator = communicator;

  await tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomePage(),
      ),
    ),
  );
  await tester.pump();
  return _ReadinessFixture(appState);
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _PendingSerial extends EmulatorSerial {
  _PendingSerial({
    required super.log,
    required this.selected,
    required this.gate,
  });

  final Chameleon selected;
  final Completer<void> gate;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [selected];

  @override
  Future<bool> connectDiscoveredDevice(Chameleon chameleon) async {
    await gate.future;
    return false;
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}

class _ReadinessSerial extends AbstractSerial {
  _ReadinessSerial({
    required super.log,
    required ConnectionType type,
    required String port,
  }) {
    connected = true;
    device = ChameleonDevice.ultra;
    connectionType = type;
    portName = port;
    activeDevicePort = port;
  }

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}

class _ReadinessCommunicator extends ChameleonCommunicator {
  _ReadinessCommunicator({
    Future<FirmwareVersion>? protocol,
    this.slotsGate,
    this.failBattery = false,
  })  : protocol = protocol ?? Future.value(_currentFirmware),
        super(Logger(output: MemoryOutput()));

  final Future<FirmwareVersion> protocol;
  final Future<void>? slotsGate;
  final bool failBattery;

  @override
  Future<FirmwareVersion> getFirmwareVersion() => protocol;

  @override
  Future<String> getGitCommitHash() async => 'readiness123';

  @override
  Future<List<int>> getDeviceCapabilities() async => [
        ChameleonCommand.setIdteckEmulatorID.value,
      ];

  @override
  Future<BatteryCharge> getBatteryCharge() async {
    if (failBattery) {
      throw StateError('sensitive transport detail must stay redacted');
    }
    return BatteryCharge(percent: 78, voltage: 3970);
  }

  @override
  Future<bool> isReaderDeviceMode() async => false;

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    await slotsGate;
    return List.generate(
      8,
      (index) => SlotTypes(
        hf: index == 0 ? TagType.mifare1K : TagType.unknown,
        lf: TagType.unknown,
      ),
    );
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async => List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: false),
      );

  @override
  Future<List<SlotNames>> getSlotTagNames() async => List.generate(
        8,
        (index) => SlotNames(hf: index == 0 ? 'Confirmed card' : ''),
      );

  @override
  Future<int> getActiveSlot() async => 0;
}
