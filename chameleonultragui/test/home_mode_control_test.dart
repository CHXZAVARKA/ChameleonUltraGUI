import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

import 'support/firmware_catalog_stub.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Home shows the confirmed device mode in a segmented control',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget is SegmentedButton<ConnectedDeviceMode>,
      ),
      findsOneWidget,
    );
    expect(find.text('Emulator'), findsOneWidget);
    expect(find.text('Reader'), findsOneWidget);
    expect(communicator.modeReads, 1);
  });

  testWidgets('narrow Home preserves the established mode control presentation',
      (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appState = _connectedState(
      _ModeCommunicator(initialReaderMode: false),
    );

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    var control = _modeControl(tester);
    expect(control.showSelectedIcon, isTrue);
    expect(control.style!.minimumSize!.resolve({}), const Size(48, 48));
    expect(tester.takeException(), isNull);
    expect(
      tester.getCenter(find.text('Emulator')).dy,
      closeTo(tester.getCenter(find.byTooltip('Settings')).dy, 1),
    );
    expect(
      tester.getCenter(find.byKey(const Key('home-slot-layout-control'))).dy,
      closeTo(tester.getCenter(find.text('Emulator')).dy, 1),
    );

    appState.sharedPreferencesProvider.setSlotLayout(SlotLayout.twoByFour);
    await tester.pumpAndSettle();

    control = _modeControl(tester);
    expect(control.showSelectedIcon, isTrue);
    expect(control.style!.minimumSize!.resolve({}), const Size(48, 48));
    expect(tester.takeException(), isNull);
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
    await tester.tap(find.text('Reader'));
    await tester.pump();

    expect(communicator.modeSets, [true]);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(_modeControl(tester).onSelectionChanged, isNull);

    await tester.tap(find.text('Reader'));
    await tester.pump();
    expect(communicator.modeSets, [true]);

    switchGate.complete();
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
    expect(communicator.modeReads, 2);
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
  });

  testWidgets(
      'racing background refresh cannot clear pending mode or queue a duplicate command',
      (tester) async {
    final entryRefreshGate = Completer<void>();
    final switchGate = Completer<void>();
    addTearDown(() {
      if (!entryRefreshGate.isCompleted) {
        entryRefreshGate.complete();
      }
      if (!switchGate.isCompleted) {
        switchGate.complete();
      }
    });
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator
      ..events.clear()
      ..nextModeReadGate = entryRefreshGate
      ..nextModeSetGate = switchGate;

    final backgroundRefresh = appState.connectedDeviceStatus!.refreshMode();
    await tester.pump();
    expect(communicator.events, ['mode:read']);

    await tester.tap(find.text('Reader'));
    await tester.pump();
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(_modeControl(tester).onSelectionChanged, isNull);
    expect(communicator.modeSets, isEmpty);

    entryRefreshGate.complete();
    await tester.pump();
    await tester.pump();
    expect(communicator.modeSets, [true]);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(_modeControl(tester).onSelectionChanged, isNull);

    await tester.tap(
      find.text('Reader'),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(communicator.modeSets, [true]);

    switchGate.complete();
    await backgroundRefresh;
    await tester.pumpAndSettle();
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
    expect(communicator.modeSets, [true]);
  });

  testWidgets(
      'failed confirmation keeps the latest mode confirmed by a racing background refresh',
      (tester) async {
    final entryRefreshGate = Completer<void>();
    addTearDown(() {
      if (!entryRefreshGate.isCompleted) {
        entryRefreshGate.complete();
      }
    });
    final communicator = _ModeCommunicator(initialReaderMode: false);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator
      ..events.clear()
      ..nextModeReadGate = entryRefreshGate
      ..modeReadResults.addAll([
        true,
        StateError('confirmation unavailable'),
      ]);

    final backgroundRefresh = appState.connectedDeviceStatus!.refreshMode();
    await tester.pump();
    await tester.tap(find.text('Reader'));
    await tester.pump();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(_modeControl(tester).onSelectionChanged, isNull);
    expect(communicator.modeSets, isEmpty);

    entryRefreshGate.complete();
    await backgroundRefresh;
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
    expect(appState.connectedDeviceStatus!.snapshot.mode.pendingMode, isNull);
    expect(communicator.events, [
      'mode:read',
      'mode:set:reader',
      'mode:read',
    ]);
    expect(find.text('Error: Unavailable'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('first mode read failure stays aligned and retries automatically',
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
    expect(find.byKey(const Key('home-mode-retry')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('home-mode-control'))).height,
      closeTo(48, 1),
    );

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(communicator.modeReads, 2);
    expect(find.byKey(const Key('home-mode-retry')), findsNothing);
  });

  testWidgets('returning to Home retains confirmed mode without rereading',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: true);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
    expect(find.byKey(const Key('home-mode-retry')), findsNothing);
    expect(communicator.modeReads, 1);
  });

  testWidgets('mode command failure preserves confirmation and reports once',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false)
      ..nextModeSetError = StateError('command failed');
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator.events.clear();

    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
    expect(find.text('Error: Unavailable'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets(
      'confirmed reread publishes the target when the command applies then throws',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false)
      ..mutateModeBeforeSetError = true
      ..nextModeSetError = StateError('transport lost the response');
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator.events.clear();

    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();

    expect(_modeControl(tester).selected, {ConnectedDeviceMode.reader});
    expect(communicator.events, ['mode:set:reader', 'mode:read']);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('mode reread mismatch keeps the prior confirmed selection',
      (tester) async {
    final communicator = _ModeCommunicator(initialReaderMode: false)
      ..ignoreModeSets = true;
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    communicator.events.clear();

    await tester.tap(find.text('Reader'));
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

    await tester.tap(find.text('Reader'));
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
    expect(
      control.segments[1].tooltip,
      'Chameleon Lite does not support reading cards',
    );
    expect(communicator.modeReads, 0);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message == 'Chameleon Lite does not support reading cards',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Reader'), warnIfMissed: false);
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

  testWidgets('Home mounted while paused reads mode once when the app resumes',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final communicator = _ModeCommunicator(initialReaderMode: true);
    final appState = _connectedState(communicator);

    await _pumpHome(tester, appState);
    tester.binding.drawFrame();
    await tester.pump();
    tester.binding.drawFrame();

    expect(communicator.modeReads, 0);
    expect(_modeControl(tester).selected, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

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

    await tester.tap(find.text('Reader'));
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

  testWidgets(
      'replaced Home stops a pending mode write before confirmation and error UI',
      (tester) async {
    final modeWriteGate = Completer<void>();
    addTearDown(() {
      if (!modeWriteGate.isCompleted) {
        modeWriteGate.complete();
      }
    });
    final oldCommunicator = _ModeCommunicator(initialReaderMode: false)
      ..nextModeSetGate = modeWriteGate;
    final appState = _connectedState(oldCommunicator);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    oldCommunicator.events.clear();

    await tester.tap(find.text('Reader'));
    await tester.pump();
    expect(oldCommunicator.modeSets, [true]);

    final newCommunicator = _ModeCommunicator(initialReaderMode: false);
    _replaceConnection(appState, newCommunicator);
    appState.changesMade();
    await tester.pumpAndSettle();

    expect(newCommunicator.modeSets, isEmpty);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});

    modeWriteGate.complete();
    await tester.pumpAndSettle();

    expect(oldCommunicator.events, ['mode:set:reader']);
    expect(newCommunicator.modeSets, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    expect(_modeControl(tester).selected, {ConnectedDeviceMode.emulator});

    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();

    expect(newCommunicator.modeSets, [true]);
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

    await tester.tap(find.text('Reader'));
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

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pumpAndSettle();
    expect(communicator.activations, [1]);
    expect(communicator.modeSets, isEmpty);

    communicator.events.clear();
    await tester.tap(find.text('Reader'));
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
) async {
  SharedPreferences.setMockInitialValues({});
  await appState.sharedPreferencesProvider.load();
  await tester.pumpWidget(
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
  return ChameleonGUIState(
    SharedPreferencesProvider(),
    firmwareCatalog: const CurrentFirmwareCatalogStub(),
  )
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
  bool mutateModeBeforeSetError = false;
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
    if (mutateModeBeforeSetError && error != null) {
      this.readerMode = readerMode;
    }
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
