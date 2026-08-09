import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Home and Slot Manager share one confirmed slot snapshot',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Column(
            children: [
              Expanded(child: HomePage()),
              Expanded(child: SlotManagerPage()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(communicator.slotTypeReads, 1);
    expect(communicator.enabledSlotReads, 1);
    expect(communicator.slotNameReads, 1);
    expect(communicator.activeSlotReads, 1);
    final emptyHf = appState.connectedDeviceStatus!.snapshot.slots.slots[1].hf;
    expect(emptyHf.type.isConfirmed, isTrue);
    expect(emptyHf.type.value, TagType.unknown);
    expect(find.text('Used Slots: 1/8'), findsOneWidget);
    expect(find.textContaining('Office'), findsOneWidget);
  });

  testWidgets('name failure keeps confirmed types and enabled state visible',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final communicator = _SlotCommunicator()..failNames = true;
    final appState = _connectedState(communicator);

    await _pumpPage(
      tester,
      appState,
      const Column(
        children: [
          Expanded(child: HomePage()),
          Expanded(child: SlotManagerPage()),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.availability, SlotsAvailability.partial);
    expect(slots.slots, hasLength(8));
    expect(slots.unavailableFacets, {SlotFacet.names});
    expect(slots.slots.first.hf.type.value, TagType.mifare1K);
    expect(slots.slots.first.hf.enabled.value, isTrue);
    expect(slots.slots.first.hf.name.isConfirmed, isFalse);
    expect(find.text('Used Slots: 1/8'), findsOneWidget);
    expect(find.text('Unavailable (Mifare Classic 1K)'), findsOneWidget);
  });

  testWidgets('first slot read failure stays connected and offers refresh',
      (tester) async {
    final communicator = _SlotCommunicator()..failAll = true;
    final appState = _connectedState(communicator);
    final serial = appState.connector! as _TestSerial;

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();

    final slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.availability, SlotsAvailability.unavailable);
    expect(slots.slots, hasLength(8));
    expect(slots.activeSlot.isConfirmed, isFalse);
    expect(find.text('Unavailable (Unavailable)'), findsWidgets);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(serial.connected, isTrue);
    expect(serial.disconnects, 0);
  });

  testWidgets('later failure preserves confirmed cache and marks it stale',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    final confirmed = appState.connectedDeviceStatus!.snapshot.slots;
    expect(find.textContaining('Office'), findsOneWidget);

    communicator.failAll = true;
    await appState.connectedDeviceStatus!.refreshSlots();
    await tester.pump();

    final stale = appState.connectedDeviceStatus!.snapshot.slots;
    expect(stale.availability, SlotsAvailability.stale);
    expect(stale.staleFacets, SlotFacet.values.toSet());
    expect(stale.slots, confirmed.slots);
    expect(stale.activeSlot, confirmed.activeSlot);
    expect(find.textContaining('Office'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('slot facets keep independent unavailable and stale certainty',
      (tester) async {
    final communicator = _SlotCommunicator()..failNames = true;
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    expect(
      appState.connectedDeviceStatus!.snapshot.slots.unavailableFacets,
      {SlotFacet.names},
    );

    communicator.failTypes = true;
    await appState.connectedDeviceStatus!.refreshSlots();
    await tester.pump();

    final slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, {SlotFacet.types});
    expect(slots.unavailableFacets, {SlotFacet.names});
    expect(slots.slots.first.hf.type.value, TagType.mifare1K);
    expect(slots.slots.first.hf.name.isConfirmed, isFalse);
  });

  testWidgets('active slot alone is confirmed then becomes independently stale',
      (tester) async {
    final communicator = _SlotCommunicator()
      ..failTypes = true
      ..failEnabled = true
      ..failNames = true;
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    var slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.availability, SlotsAvailability.partial);
    expect(slots.activeSlot.value, 0);
    expect(slots.unavailableFacets, {
      SlotFacet.types,
      SlotFacet.enabledStates,
      SlotFacet.names,
    });

    communicator.failActive = true;
    await appState.connectedDeviceStatus!.refreshSlots();
    await tester.pump();

    slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.activeSlot.value, 0);
    expect(slots.staleFacets, {SlotFacet.activeSlot});
    expect(slots.unavailableFacets, {
      SlotFacet.types,
      SlotFacet.enabledStates,
      SlotFacet.names,
    });
  });

  testWidgets('Slot Manager shows cache immediately while entry refreshes',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    expect(find.text('Used Slots: 1/8'), findsOneWidget);

    final refreshGate = Completer<void>();
    communicator
      ..name = 'Lab'
      ..nextTypesGate = refreshGate;
    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pump();

    expect(communicator.slotTypeReads, 2);
    expect(find.textContaining('Office'), findsOneWidget);

    refreshGate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Lab'), findsOneWidget);
  });

  testWidgets('Slot Manager entry refresh waits for busy foreground RF work',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final foregroundGate = Completer<void>();
    final foregroundStarted = Completer<void>();
    final foreground = appState.rfOperations.runForeground(() async {
      foregroundStarted.complete();
      await foregroundGate.future;
    });
    await foregroundStarted.future;

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pump();
    expect(communicator.slotTypeReads, 0);

    foregroundGate.complete();
    await foreground;
    await tester.pumpAndSettle();

    expect(communicator.slotTypeReads, 1);
    expect(communicator.enabledSlotReads, 1);
    expect(communicator.slotNameReads, 1);
    expect(communicator.activeSlotReads, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(communicator.slotTypeReads, 1);
  });

  testWidgets('Slot Manager entry refresh waits for busy background RF work',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final backgroundGate = Completer<void>();
    final backgroundStarted = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      backgroundStarted.complete();
      await backgroundGate.future;
    });
    await backgroundStarted.future;

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pump();
    expect(communicator.slotTypeReads, 0);

    backgroundGate.complete();
    await background;
    await tester.pumpAndSettle();

    expect(communicator.slotTypeReads, 1);
    expect(communicator.enabledSlotReads, 1);
    expect(communicator.slotNameReads, 1);
    expect(communicator.activeSlotReads, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(communicator.slotTypeReads, 1);
  });

  testWidgets('late slot result from a replaced communicator is discarded',
      (tester) async {
    final gate = Completer<void>();
    final oldCommunicator = _SlotCommunicator()..nextTypesGate = gate;
    final appState = _connectedState(oldCommunicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pump();

    final newCommunicator = _SlotCommunicator()..name = 'Replacement';
    _replaceConnection(appState, newCommunicator);
    appState.changesMade();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('Replacement'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(oldCommunicator.enabledSlotReads, 0);
    expect(oldCommunicator.slotNameReads, 0);
    expect(oldCommunicator.activeSlotReads, 0);
    expect(find.textContaining('Office'), findsNothing);
    expect(
      appState.connectedDeviceStatus!.snapshot.slots.slots.first.hf.name.value,
      'Replacement',
    );
  });

  testWidgets('disconnect discards a pending slot refresh', (tester) async {
    final gate = Completer<void>();
    final communicator = _SlotCommunicator()..nextTypesGate = gate;
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pump();
    final disposedStatus = appState.connectedDeviceStatus!;

    await appState.disconnect(manual: true);
    gate.complete();
    await tester.pumpAndSettle();

    expect(appState.connectedDeviceStatus, isNull);
    expect(communicator.enabledSlotReads, 0);
    expect(communicator.slotNameReads, 0);
    expect(communicator.activeSlotReads, 0);
    expect(
        disposedStatus.snapshot.slots.availability, SlotsAvailability.loading);
  });

  testWidgets('Home activation publishes only the re-read active slot',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    expect(appState.connectedDeviceStatus!.snapshot.slots.activeSlot.value, 0);

    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(communicator.activations, [1]);
    expect(appState.connectedDeviceStatus!.snapshot.slots.activeSlot.value, 1);
  });

  testWidgets('confirmed activation repairs the only stale slot facet',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    communicator.failActive = true;
    await appState.connectedDeviceStatus!.refreshSlots();
    var slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, {SlotFacet.activeSlot});

    communicator.failActive = false;
    expect(await appState.connectedDeviceStatus!.activateSlot(1), isTrue);

    slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.activeSlot.value, 1);
    expect(slots.staleFacets, isEmpty);
    expect(slots.unavailableFacets, isEmpty);
    expect(slots.availability, SlotsAvailability.available);
  });

  testWidgets(
      'waiting entry refresh preserves a newer confirmed activation when its active read fails',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    final status = appState.connectedDeviceStatus!;
    expect(status.snapshot.slots.activeSlot.value, 0);

    await _pumpPage(tester, appState, const SizedBox.shrink());
    await tester.pumpAndSettle();

    final foregroundGate = Completer<void>();
    final foregroundStarted = Completer<void>();
    final foreground = appState.rfOperations.runForeground(() async {
      foregroundStarted.complete();
      await foregroundGate.future;
    });
    await foregroundStarted.future;

    communicator.scriptedActiveSlotReads.addAll([
      1,
      StateError('active slot unavailable after activation'),
    ]);
    final observedActiveSlots = <int?>[];
    status.addListener(
      () => observedActiveSlots.add(status.snapshot.slots.activeSlot.value),
    );

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pump();
    final entryRefresh = status.refreshSlots();
    final activation = status.activateSlot(1);

    foregroundGate.complete();
    await foreground;
    expect(await activation, isTrue);
    await entryRefresh;
    await tester.pump();

    final slots = status.snapshot.slots;
    expect(slots.activeSlot.value, 1);
    expect(slots.activeSlot.isConfirmed, isTrue);
    expect(slots.staleFacets, contains(SlotFacet.activeSlot));
    expect(slots.availability, SlotsAvailability.stale);
    final activationPublication = observedActiveSlots.indexOf(1);
    expect(activationPublication, isNonNegative);
    expect(
      observedActiveSlots.skip(activationPublication),
      everyElement(1),
    );
  });

  testWidgets('invalid activation reread marks the confirmed active slot stale',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    final status = appState.connectedDeviceStatus!;
    expect(status.snapshot.slots.activeSlot.value, 0);

    communicator.scriptedActiveSlotReads.add(8);
    expect(await status.activateSlot(1), isFalse);
    await tester.pump();

    final slots = status.snapshot.slots;
    expect(communicator.activations, [1]);
    expect(slots.activeSlot.value, 0);
    expect(slots.staleFacets, contains(SlotFacet.activeSlot));
    expect(slots.availability, SlotsAvailability.stale);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  ChameleonGUIState appState,
  Widget page,
) =>
    tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: page,
        ),
      ),
    );

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
    ..portName = 'test-port'
    ..activeDevicePort = 'test-port';
  return ChameleonGUIState(SharedPreferencesProvider())
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
}

class _SlotCommunicator extends ChameleonCommunicator {
  _SlotCommunicator() : super(Logger());

  int slotTypeReads = 0;
  int enabledSlotReads = 0;
  int slotNameReads = 0;
  int activeSlotReads = 0;
  String name = 'Office';
  bool failTypes = false;
  bool failEnabled = false;
  bool failNames = false;
  bool failActive = false;
  Completer<void>? nextTypesGate;
  int activeSlot = 0;
  final List<int> activations = [];
  final List<Object> scriptedActiveSlotReads = [];

  bool get failAll => failTypes && failEnabled && failNames && failActive;

  set failAll(bool value) {
    failTypes = value;
    failEnabled = value;
    failNames = value;
    failActive = value;
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    slotTypeReads++;
    final gate = nextTypesGate;
    nextTypesGate = null;
    await gate?.future;
    if (failTypes) {
      throw StateError('slot types unavailable');
    }
    return List.generate(
      8,
      (index) => SlotTypes(
        hf: index == 0 ? TagType.mifare1K : TagType.unknown,
      ),
    );
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    enabledSlotReads++;
    if (failEnabled) {
      throw StateError('enabled slots unavailable');
    }
    return List.generate(8, (index) => EnabledSlotInfo(hf: index == 0));
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    slotNameReads++;
    if (failNames) {
      throw StateError('slot names unavailable');
    }
    return List.generate(8, (index) => SlotNames(hf: index == 0 ? name : ''));
  }

  @override
  Future<int> getActiveSlot() async {
    activeSlotReads++;
    if (scriptedActiveSlotReads.isNotEmpty) {
      final result = scriptedActiveSlotReads.removeAt(0);
      if (result is int) {
        return result;
      }
      throw result;
    }
    if (failActive) {
      throw StateError('active slot unavailable');
    }
    return activeSlot;
  }

  @override
  Future<void> activateSlot(int slot) async {
    activations.add(slot);
    activeSlot = slot;
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async =>
      BatteryCharge(percent: 61, voltage: 3910);

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x0100);

  @override
  Future<String> getGitCommitHash() async => 'abcdef0';

  @override
  Future<bool> isReaderDeviceMode() async => false;

  @override
  Future<List<int>> getDeviceCapabilities() async =>
      [ChameleonCommand.setIdteckEmulatorID.value];
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
