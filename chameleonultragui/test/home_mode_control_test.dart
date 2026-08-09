import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Home shows the confirmed device mode in a segmented control',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((widget) => widget is SegmentedButton),
      findsOneWidget,
    );
    expect(find.text('Go to emulator mode'), findsOneWidget);
    expect(find.text('Go to reader mode'), findsOneWidget);
    expect(communicator.modeReads, 1);
  });

  testWidgets(
      'mode switch keeps confirmed selection and blocks repeated input until reread',
      (tester) async {
    final switchGate = Completer<void>();
    addTearDown(() {
      if (!switchGate.isCompleted) {
        switchGate.complete();
      }
    });
    final communicator = _ModeCommunicator(initialReaderMode: false)
      ..nextModeSetGate = switchGate;
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator.events.clear();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    await tester.tap(find.text('Go to reader mode'));
    await tester.pump();

    expect(communicator.modeSets, [true]);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(_modeControl(tester).onSelectionChanged, isNull);

    await tester.tap(find.text('Go to reader mode'));
    await tester.pump();
    expect(communicator.modeSets, [true]);

    switchGate.complete();
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
    expect(communicator.modeReads, 2);
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
  });

  testWidgets('first mode read failure disables selection and offers retry',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false)
      ..modeReadResults.addAll([
        StateError('mode unavailable'),
        false,
      ]);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, isEmpty);
    expect(_modeControl(tester).onSelectionChanged, isNull);
    expect(find.byKey(const Key('home-mode-retry')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-mode-retry')));
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(communicator.modeReads, 2);
    expect(find.byKey(const Key('home-mode-retry')), findsNothing);
  });

  testWidgets('later Home entry failure retains the confirmed mode',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: true);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    communicator.modeReadResults.add(StateError('later mode read failed'));

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
    expect(find.byKey(const Key('home-mode-retry')), findsNothing);
    expect(communicator.modeReads, 2);
  });

  testWidgets('mode command failure preserves confirmation and reports once',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false)
      ..nextModeSetError = StateError('command failed');
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator.events.clear();

    await tester.tap(find.text('Go to reader mode'));
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
    expect(find.text('Error: Unavailable'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('mode reread mismatch keeps the prior confirmed selection',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false)
      ..ignoreModeSets = true;
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator.events.clear();

    await tester.tap(find.text('Go to reader mode'));
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
    expect(find.text('Error: Unavailable'), findsOneWidget);
  });

  testWidgets('mode reread failure keeps the prior confirmed selection',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator
      ..events.clear()
      ..modeReadResults.add(StateError('confirmation unavailable'));

    await tester.tap(find.text('Go to reader mode'));
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
    expect(find.text('Error: Unavailable'), findsOneWidget);
  });

  testWidgets('Lite fixes Emulator mode and never sends a Reader command',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(
      communicator,
      device: ChameleonDevice.lite,
    );

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    final control = _modeControl(tester);
    expect(control.selected, {ConnectedDeviceMode.emulator});
    expect(control.segments[1].enabled, isFalse);
    expect(communicator.modeReads, 0);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message == 'Chameleon Lite does not support reading cards',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Go to reader mode'), warnIfMissed: false);
    await tester.pump();
    expect(communicator.modeSets, isEmpty);
  });

  testWidgets('mode does not poll while Home remains visible', (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: true);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(communicator.modeReads, 1);

    await tester.pump(const Duration(minutes: 1));
    await tester.pump();

    expect(communicator.modeReads, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(communicator.modeReads, 1);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
  });

  testWidgets('mode switch waits for foreground RF ownership', (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    final foregroundGate = Completer<void>();
    final foregroundStarted = Completer<void>();
    final foreground = appState.rfOperations.runForeground(() async {
      foregroundStarted.complete();
      await foregroundGate.future;
    });
    await foregroundStarted.future;

    await tester.tap(find.text('Go to reader mode'));
    await tester.pump();
    expect(communicator.modeSets, isEmpty);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});

    foregroundGate.complete();
    await foreground;
    await tester.pumpAndSettle();
    expect(communicator.modeSets, [true]);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
  });

  testWidgets('Home entry waits to read mode when foreground RF is busy',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: true);
    final appState = _connectedState(communicator);
    final foregroundGate = Completer<void>();
    final foregroundStarted = Completer<void>();
    final foreground = appState.rfOperations.runForeground(() async {
      foregroundStarted.complete();
      await foregroundGate.future;
    });
    await foregroundStarted.future;

    await _pumpHome(tester, appState);
    await tester.pump();
    expect(communicator.modeReads, 0);
    expect(_modeControl(tester).selected, isEmpty);

    foregroundGate.complete();
    await foreground;
    await tester.pumpAndSettle();

    expect(communicator.modeReads, 1);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
  });

  testWidgets('late mode result from the old connection is discarded',
      (tester) async {
    final oldCommunicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(oldCommunicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    final oldReadGate = Completer<void>();
    oldCommunicator.nextModeReadGate = oldReadGate;

    await tester.tap(find.text('Go to reader mode'));
    await tester.pump();
    expect(oldCommunicator.modeSets, [true]);

    final newCommunicator = _ModeCommunicator(initialReaderMode: false);
    _replaceConnection(appState, newCommunicator);
    appState.changesMade();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});

    oldReadGate.complete();
    await tester.pump();
    await tester.pump();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(appState.connectedDeviceStatus!.snapshot.mode.confirmedMode,
        ConnectedDeviceMode.emulator);
  });

  testWidgets('mode switching and slot activation remain independent',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator.events.clear();

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();
    expect(communicator.activations, [1]);
    expect(communicator.modeSets, isEmpty);

    communicator.events.clear();
    await tester.tap(find.text('Go to reader mode'));
    await tester.pumpAndSettle();
    expect(communicator.modeSets, [true]);
    expect(communicator.activations, [1]);
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
  });
}

SegmentedButton<ConnectedDeviceMode> _modeControl(WidgetTester tester) =>
    tester.widget<SegmentedButton<ConnectedDeviceMode>>(
      find.byWidgetPredicate(
        (widget) => widget is SegmentedButton<ConnectedDeviceMode>,
      ),
    );

Future<void> _pumpHome(
  WidgetTester tester,
  ChameleonGUIState appState,
) {
  return tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const HomePage(),
      ),
    ),
  );
}

ChameleonGUIState _connectedState(
  _ModeCommunicator communicator, {
  ChameleonDevice device = ChameleonDevice.ultra,
}) {
  final serial = _TestSerial(log: Logger())
    ..connected = true
    ..device = device
    ..connectionType = ConnectionType.usb
    ..portName = 'mode-test-device'
    ..activeDevicePort = 'mode-test-port';
  return ChameleonGUIState(SharedPreferencesProvider())
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
}

void _replaceConnection(
  ChameleonGUIState appState,
  _ModeCommunicator communicator,
) {
  appState
    ..connector = (_TestSerial(log: Logger())
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb
      ..portName = 'replacement-mode-device'
      ..activeDevicePort = 'replacement-mode-port')
    ..communicator = communicator;
}

class _ModeCommunicator extends ChameleonCommunicator {
  _ModeCommunicator({required bool initialReaderMode})
      : readerMode = initialReaderMode,
        super(Logger());

  bool readerMode;
  int modeReads = 0;
  final List<Object> modeReadResults = [];
  final List<bool> modeSets = [];
  final List<String> events = [];
  final List<int> activations = [];
  Completer<void>? nextModeSetGate;
  Completer<void>? nextModeReadGate;
  Object? nextModeSetError;
  bool ignoreModeSets = false;
  int activeSlot = 0;

  @override
  Future<bool> isReaderDeviceMode() async {
    modeReads++;
    events.add('mode:read');
    final gate = nextModeReadGate;
    nextModeReadGate = null;
    await gate?.future;
    if (modeReadResults.isNotEmpty) {
      final result = modeReadResults.removeAt(0);
      if (result is bool) {
        readerMode = result;
        return result;
      }
      throw result;
    }
    return readerMode;
  }

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {
    modeSets.add(readerMode);
    events.add('mode:set:${readerMode ? 'reader' : 'emulator'}');
    final gate = nextModeSetGate;
    nextModeSetGate = null;
    await gate?.future;
    final error = nextModeSetError;
    nextModeSetError = null;
    if (error != null) {
      throw error;
    }
    if (!ignoreModeSets) {
      this.readerMode = readerMode;
    }
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async =>
      BatteryCharge(percent: 61, voltage: 3910);

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async =>
      List.generate(8, (_) => SlotTypes());

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async =>
      List.generate(8, (_) => EnabledSlotInfo());

  @override
  Future<List<SlotNames>> getSlotTagNames() async =>
      List.generate(8, (_) => SlotNames());

  @override
  Future<int> getActiveSlot() async => activeSlot;

  @override
  Future<void> activateSlot(int slot) async {
    activations.add(slot);
    events.add('slot:activate:$slot');
    activeSlot = slot;
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x0100);

  @override
  Future<String> getGitCommitHash() async => 'abcdef0';

  @override
  Future<List<int>> getDeviceCapabilities() async =>
      [ChameleonCommand.setIdteckEmulatorID.value];
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log});

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
