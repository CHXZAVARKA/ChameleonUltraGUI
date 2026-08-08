import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

void main() {
  testWidgets('Home shell renders while battery is still loading',
      (tester) async {
    final communicator = _BatteryCommunicator.pending();
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pump();

    expect(find.text('Chameleon Ultra'), findsOneWidget);
    expect(find.text('USB device with a very long port name'), findsOneWidget);
    expect(find.byIcon(Icons.usb), findsOneWidget);
    expect(find.text('--%'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  testWidgets('Home polls only battery and formats live battery details',
      (tester) async {
    final communicator = _BatteryCommunicator.withValues([
      BatteryCharge(percent: 61, voltage: 3910),
      BatteryCharge(percent: 61, voltage: 3910),
    ]);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pump();

    expect(find.text('61%'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == '61% · 3.91 V',
      ),
      findsOneWidget,
    );
    expect(communicator.batteryReads, 1);
    expect(communicator.slotTypeReads, 1);

    final snapshot = appState.connectedDeviceStatus!.snapshot;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();

    expect(communicator.batteryReads, 2);
    expect(communicator.slotTypeReads, 1);
    expect(
        identical(appState.connectedDeviceStatus!.snapshot, snapshot), isTrue);
  });

  testWidgets('device identity and disconnect action live only in the AppBar',
      (tester) async {
    final communicator = _BatteryCommunicator.complete(
      BatteryCharge(percent: 61, voltage: 3910),
    );
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pump();
    await tester.pump();

    expect(find.text('Chameleon Ultra'), findsOneWidget);
    expect(find.text('USB device with a very long port name'), findsOneWidget);
    expect(find.byIcon(Icons.usb), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  testWidgets('battery failure stays non-fatal and renders unknown state',
      (tester) async {
    final communicator = _BatteryCommunicator.failing();
    final appState = _connectedState(communicator);
    final serial = appState.connector! as _TestSerial;

    await _pumpHome(tester, appState);
    await tester.pump();

    expect(find.text('--%'), findsOneWidget);
    expect(find.byIcon(Icons.battery_unknown), findsOneWidget);
    expect(serial.connected, isTrue);
    expect(serial.disconnects, 0);
    expect(appState.communicator, same(communicator));
  });

  testWidgets('battery polling pauses with lifecycle and stops without Home',
      (tester) async {
    final communicator = _BatteryCommunicator.withValues([
      BatteryCharge(percent: 61, voltage: 3910),
      BatteryCharge(percent: 60, voltage: 3900),
      BatteryCharge(percent: 59, voltage: 3890),
    ]);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pump();
    expect(communicator.batteryReads, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(communicator.batteryReads, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(communicator.batteryReads, 2);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(communicator.batteryReads, 3);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(communicator.batteryReads, 3);
  });

  testWidgets('late battery result from a replaced connection is discarded',
      (tester) async {
    final oldCommunicator = _BatteryCommunicator.pending();
    final appState = _connectedState(oldCommunicator);

    await _pumpHome(tester, appState);
    await tester.pump();

    final newCommunicator = _BatteryCommunicator.withValues([
      BatteryCharge(percent: 77, voltage: 4010),
    ]);
    _replaceConnection(appState, newCommunicator);
    appState.changesMade();
    await tester.pump();
    await tester.pump();
    expect(find.text('77%'), findsOneWidget);

    oldCommunicator.completePending(
      BatteryCharge(percent: 4, voltage: 3500),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('77%'), findsOneWidget);
    expect(find.text('4%'), findsNothing);
    expect(appState.connectedDeviceStatus!.snapshot.battery.percent, 77);
  });

  testWidgets('battery colors follow normal warning and error thresholds',
      (tester) async {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
    );
    final cases = <(int, Color)>[
      (21, theme.colorScheme.onSurface),
      (20, Colors.amber.shade700),
      (10, theme.colorScheme.error),
    ];

    for (final (percent, expectedColor) in cases) {
      final appState = _connectedState(
        _BatteryCommunicator.withValues([
          BatteryCharge(percent: percent, voltage: 3800),
        ]),
      );
      await _pumpHome(tester, appState, theme: theme);
      await tester.pump();

      final label = tester.widget<Text>(find.text('$percent%'));
      expect(label.style?.color, expectedColor, reason: '$percent%');
    }
  });
}

Future<void> _pumpHome(
  WidgetTester tester,
  ChameleonGUIState appState, {
  ThemeData? theme,
}) {
  return tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const HomePage(),
      ),
    ),
  );
}

void _replaceConnection(
  ChameleonGUIState appState,
  ChameleonCommunicator communicator,
) {
  appState
    ..connector = (_TestSerial(log: Logger())
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb
      ..portName = 'replacement-port'
      ..activeDevicePort = 'replacement')
    ..communicator = communicator;
}

ChameleonGUIState _connectedState(ChameleonCommunicator communicator) {
  final serial = _TestSerial(log: Logger())
    ..connected = true
    ..device = ChameleonDevice.ultra
    ..connectionType = ConnectionType.usb
    ..portName = 'USB device with a very long port name'
    ..activeDevicePort = 'test-port';
  return ChameleonGUIState(SharedPreferencesProvider())
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
}

class _BatteryCommunicator extends ChameleonCommunicator {
  _BatteryCommunicator.pending()
      : _pendingBattery = Completer<BatteryCharge>(),
        _batteryValues = const [],
        _completeLegacyStatus = false,
        _batteryError = null,
        super(Logger());

  _BatteryCommunicator.withValues(this._batteryValues)
      : _pendingBattery = null,
        _completeLegacyStatus = false,
        _batteryError = null,
        super(Logger());

  _BatteryCommunicator.complete(BatteryCharge battery)
      : _pendingBattery = null,
        _batteryValues = [battery],
        _completeLegacyStatus = true,
        _batteryError = null,
        super(Logger());

  _BatteryCommunicator.failing()
      : _pendingBattery = null,
        _batteryValues = const [],
        _completeLegacyStatus = false,
        _batteryError = StateError('battery unavailable'),
        super(Logger());

  final Completer<BatteryCharge>? _pendingBattery;
  final List<BatteryCharge> _batteryValues;
  final Completer<FirmwareVersion> _firmware = Completer<FirmwareVersion>();
  final bool _completeLegacyStatus;
  final Object? _batteryError;
  int batteryReads = 0;
  int slotTypeReads = 0;

  @override
  Future<BatteryCharge> getBatteryCharge() async {
    final index = batteryReads++;
    final batteryError = _batteryError;
    if (batteryError != null) {
      throw batteryError;
    }
    final pendingBattery = _pendingBattery;
    if (pendingBattery != null) {
      return pendingBattery.future;
    }
    return _batteryValues[index.clamp(0, _batteryValues.length - 1)];
  }

  void completePending(BatteryCharge battery) {
    _pendingBattery!.complete(battery);
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    slotTypeReads++;
    return List.generate(8, (_) => SlotTypes());
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() => _completeLegacyStatus
      ? Future.value(FirmwareVersion(legacyProtocol: false, version: 0x0100))
      : _firmware.future;

  @override
  Future<String> getGitCommitHash() async => 'abcdef0';

  @override
  Future<bool> isReaderDeviceMode() async => false;

  @override
  Future<List<int>> getDeviceCapabilities() async =>
      [ChameleonCommand.setIdteckEmulatorID.value];

  @override
  Future<int> getActiveSlot() async => 0;
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log});

  int disconnects = 0;

  @override
  Future<bool> performDisconnect() async {
    disconnects++;
    resetConnectionState();
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
