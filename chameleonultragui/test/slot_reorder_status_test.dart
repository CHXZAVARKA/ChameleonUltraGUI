import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('bridge sends one 1041 command with source and target bytes', () async {
    final logger = Logger();
    addTearDown(logger.close);
    final serial = _ReplySerial(log: logger);
    final communicator = ChameleonCommunicator(logger, port: serial);
    serial.communicator = communicator;

    await communicator.swapSlots(2, 6);

    expect(serial.commands, [ChameleonCommand.swapSlots]);
    expect(serial.payloads, [
      Uint8List.fromList([2, 6])
    ]);
  });

  test('bridge exposes an unambiguous firmware rejection', () async {
    final logger = Logger();
    addTearDown(logger.close);
    final serial = _ReplySerial(log: logger)..responseStatus = 0x66;
    final communicator = ChameleonCommunicator(logger, port: serial);
    serial.communicator = communicator;

    await expectLater(
      communicator.swapSlots(1, 3),
      throwsA(
        isA<SlotReorderRejected>().having(
          (error) => error.status,
          'status',
          0x66,
        ),
      ),
    );
    expect(serial.commands, [ChameleonCommand.swapSlots]);
  });

  test('capability is read once and cached for the connected session',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);

    expect(
      await fixture.status.refreshSlotReorderCapability(),
      SlotReorderCapability.supported,
    );
    expect(
      await fixture.status.refreshSlotReorderCapability(),
      SlotReorderCapability.supported,
    );
    expect(fixture.communicator.capabilityReads, 1);

    await fixture.status.refreshSlots();
    fixture.communicator.events.clear();
    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.confirmed,
    );
    expect(fixture.communicator.capabilityReads, 1);
    expect(fixture.communicator.events.first, 'swap:0:1');
  });

  test('BLE probes slot reorder support without requesting capabilities',
      () async {
    final fixture = _fixture(connectionType: ConnectionType.ble);
    addTearDown(fixture.dispose);

    expect(
      await fixture.status.refreshSlotReorderCapability(),
      SlotReorderCapability.supported,
    );
    expect(
      await fixture.status.refreshSlotReorderCapability(),
      SlotReorderCapability.supported,
    );
    expect(fixture.communicator.capabilityReads, 0);
    expect(fixture.communicator.swapCalls, 1);
    expect(fixture.communicator.events, ['swap:0:0']);
  });

  test('BLE maps a rejected no-op probe to unsupported firmware', () async {
    final fixture = _fixture(
      supportsSwap: false,
      connectionType: ConnectionType.ble,
    );
    addTearDown(fixture.dispose);

    expect(
      await fixture.status.refreshSlotReorderCapability(),
      SlotReorderCapability.unsupported,
    );
    expect(fixture.communicator.capabilityReads, 0);
    expect(fixture.communicator.swapCalls, 1);
    expect(fixture.communicator.events, ['swap:0:0']);
  });

  test(
      'successful reorder exposes source and target, owns one foreground lease, and reconciles once',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator.events.clear();
    final gate = Completer<void>();
    fixture.communicator.swapGate = gate;

    final reorder = fixture.status.reorderSlots(0, 1);
    await fixture.communicator.swapStarted.future;

    expect(
      fixture.status.snapshot.slots.pendingReorder,
      const PendingSlotReorder(source: 0, target: 1),
    );
    expect(
      await fixture.status.reorderSlots(2, 3),
      SlotReorderOutcome.busy,
    );
    expect(await fixture.status.activateSlot(2), isFalse);
    final background = await fixture.appState.rfOperations
        .tryRunBackground(() async => 'must skip');
    expect(background.acquired, isFalse);

    gate.complete();
    expect(await reorder, SlotReorderOutcome.confirmed);

    expect(fixture.communicator.events, [
      'capabilities',
      'swap:0:1',
      'types',
      'enabled',
      'names',
      'active',
    ]);
    expect(fixture.communicator.swapCalls, 1);
    expect(fixture.status.snapshot.slots.pendingReorder, isNull);
    expect(fixture.status.snapshot.slots.slots[0].hf.name.value, 'Slot 2 HF');
    expect(fixture.status.snapshot.slots.slots[1].hf.name.value, 'Slot 1 HF');
    expect(fixture.status.snapshot.slots.activeSlot.value, 1);
  });

  test('unsupported firmware returns a typed outcome without a swap', () async {
    final fixture = _fixture(supportsSwap: false);
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator.events.clear();

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.unsupported,
    );

    expect(fixture.communicator.events, ['capabilities']);
    expect(fixture.communicator.swapCalls, 0);
    expect(
      fixture.status.snapshot.slots.reorderCapability,
      SlotReorderCapability.unsupported,
    );
    expect(fixture.status.snapshot.slots.pendingReorder, isNull);
  });

  test('failed capability probe is connection-scoped and is not repeated',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator.failCapabilities = true;

    expect(
      await fixture.status.refreshSlotReorderCapability(),
      SlotReorderCapability.unavailable,
    );
    expect(
      await fixture.status.refreshSlotReorderCapability(),
      SlotReorderCapability.unavailable,
    );
    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.failed,
    );
    expect(fixture.communicator.capabilityReads, 1);
    expect(fixture.communicator.swapCalls, 0);
  });

  test('firmware rejection preserves confirmed order without reconciliation',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    final before = fixture.status.snapshot.slots;
    fixture.communicator
      ..events.clear()
      ..rejectSwap = true;

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.failed,
    );

    expect(fixture.communicator.events, ['capabilities', 'swap:0:1']);
    expect(fixture.communicator.swapCalls, 1);
    expect(fixture.status.snapshot.slots.slots, before.slots);
    expect(fixture.status.snapshot.slots.activeSlot, before.activeSlot);
    expect(fixture.status.snapshot.slots.pendingReorder, isNull);
  });

  test('lost reply is never retried and a complete read resolves success',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator
      ..events.clear()
      ..loseSwapReply = true
      ..applySwapBeforeLostReply = true;

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.confirmed,
    );

    expect(fixture.communicator.swapCalls, 1);
    expect(
      fixture.communicator.events.where((event) => event.startsWith('swap:')),
      ['swap:0:1'],
    );
    expect(fixture.status.snapshot.slots.slots[0].hf.name.value, 'Slot 2 HF');
    expect(fixture.status.snapshot.slots.activeSlot.value, 1);
  });

  test('lost reply stays ambiguous when source and target look identical',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator
      ..makeSlotsVisiblyIdentical(0, 1)
      ..activeSlot = 7;
    await fixture.status.refreshSlots();
    fixture.communicator
      ..events.clear()
      ..loseSwapReply = true
      ..applySwapBeforeLostReply = true;

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.ambiguous,
    );

    final slots = fixture.status.snapshot.slots;
    expect(fixture.communicator.swapCalls, 1);
    expect(
      fixture.communicator.events.where((event) => event.startsWith('swap:')),
      ['swap:0:1'],
    );
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, isEmpty);
    expect(slots.staleSlotFacets.keys, {0, 1});
    expect(
      slots.staleSlotFacets[0],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
    expect(
      slots.staleSlotFacets[1],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
  });

  test('acknowledged reorder confirms visibly identical positions', () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator
      ..makeSlotsVisiblyIdentical(0, 1)
      ..activeSlot = 7;
    await fixture.status.refreshSlots();
    fixture.communicator.events.clear();

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.confirmed,
    );

    final slots = fixture.status.snapshot.slots;
    expect(fixture.communicator.swapCalls, 1);
    expect(slots.availability, SlotsAvailability.available);
    expect(slots.staleFacets, isEmpty);
    expect(slots.staleSlotFacets, isEmpty);
  });

  test('complete refresh preserves unresolved identical-slot ambiguity',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator
      ..makeSlotsVisiblyIdentical(0, 1)
      ..activeSlot = 7;
    await fixture.status.refreshSlots();
    fixture.communicator
      ..events.clear()
      ..loseSwapReply = true
      ..applySwapBeforeLostReply = true;

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.ambiguous,
    );
    expect(fixture.status.snapshot.slots.staleSlotFacets.keys, {0, 1});

    fixture.communicator.events.clear();
    await fixture.status.refreshSlots();

    final slots = fixture.status.snapshot.slots;
    expect(fixture.communicator.swapCalls, 1);
    expect(
      fixture.communicator.events,
      ['types', 'enabled', 'names', 'active'],
    );
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, isEmpty);
    expect(slots.staleSlotFacets.keys, {0, 1});
    expect(
      slots.staleSlotFacets[0],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
    expect(
      slots.staleSlotFacets[1],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
    expect(slots.pendingReorder, isNull);
  });

  test(
      'complete refresh preserves identical-slot ambiguity after partial read-back',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator
      ..makeSlotsVisiblyIdentical(0, 1)
      ..activeSlot = 7;
    await fixture.status.refreshSlots();
    fixture.communicator
      ..events.clear()
      ..loseSwapReply = true
      ..applySwapBeforeLostReply = true
      ..failNames = true;

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.ambiguous,
    );
    expect(fixture.communicator.swapCalls, 1);

    fixture.communicator
      ..events.clear()
      ..failNames = false;
    await fixture.status.refreshSlots();

    final slots = fixture.status.snapshot.slots;
    expect(fixture.communicator.swapCalls, 1);
    expect(
      fixture.communicator.events,
      ['types', 'enabled', 'names', 'active'],
    );
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, isEmpty);
    expect(slots.staleSlotFacets.keys, {0, 1});
    expect(
      slots.staleSlotFacets[0],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
    expect(
      slots.staleSlotFacets[1],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
    expect(slots.pendingReorder, isNull);
  });

  test('confirmed reorder moves unresolved bundle identity with its slot',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator
      ..makeSlotsVisiblyIdentical(0, 1)
      ..activeSlot = 7;
    await fixture.status.refreshSlots();
    fixture.communicator
      ..loseSwapReply = true
      ..applySwapBeforeLostReply = true;

    expect(
      await fixture.status.reorderSlots(0, 1),
      SlotReorderOutcome.ambiguous,
    );
    expect(fixture.status.snapshot.slots.staleSlotFacets.keys, {0, 1});

    fixture.communicator
      ..loseSwapReply = false
      ..events.clear();
    expect(
      await fixture.status.reorderSlots(0, 2),
      SlotReorderOutcome.confirmed,
    );

    final slots = fixture.status.snapshot.slots;
    expect(fixture.communicator.swapCalls, 2);
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, isEmpty);
    expect(slots.staleSlotFacets.keys, {1, 2});
    expect(
      slots.staleSlotFacets[1],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
    expect(
      slots.staleSlotFacets[2],
      {SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names},
    );
    expect(slots.pendingReorder, isNull);
  });

  test('slot mutations fail busy during reorder and work after it completes',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
    fixture.communicator.swapGate = gate;

    final reorder = fixture.status.reorderSlots(0, 1);
    await fixture.communicator.swapStarted.future;
    var blockedOperationStarted = false;

    await expectLater(
      fixture.status.mutateSlots<void>((mutation) async {
        blockedOperationStarted = true;
        await mutation.run(
          (communicator) => communicator.setSlotTagName(
            2,
            'Must not run',
            TagFrequency.hf,
          ),
        );
      }).timeout(const Duration(milliseconds: 100)),
      throwsA(isA<SlotMutationBusy>()),
    );
    expect(blockedOperationStarted, isFalse);
    expect(fixture.communicator.slotMutationCalls, 0);

    gate.complete();
    expect(await reorder, SlotReorderOutcome.confirmed);

    await fixture.status.mutateSlots<void>(
      (mutation) => mutation.run(
        (communicator) => communicator.setSlotTagName(
          2,
          'After reorder',
          TagFrequency.hf,
        ),
      ),
    );
    expect(fixture.communicator.slotMutationCalls, 1);
    expect(
      fixture.status.snapshot.slots.slots[2].hf.name.value,
      'After reorder',
    );
  });

  test('successful commit with incomplete read-back is reconciliationFailed',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator
      ..events.clear()
      ..failNames = true;

    expect(
      await fixture.status.reorderSlots(2, 5),
      SlotReorderOutcome.reconciliationFailed,
    );

    expect(fixture.communicator.swapCalls, 1);
    expect(fixture.status.snapshot.slots.staleSlotFacets.keys, {2, 5});
    expect(fixture.status.snapshot.slots.pendingReorder, isNull);
  });

  test('reorder preserves inherited global stale facets on read-back failure',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator.failNames = true;
    await fixture.status.refreshSlots();
    expect(
      fixture.status.snapshot.slots.staleFacets,
      {SlotFacet.names},
    );

    expect(
      await fixture.status.reorderSlots(2, 5),
      SlotReorderOutcome.reconciliationFailed,
    );

    final slots = fixture.status.snapshot.slots;
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, {SlotFacet.names});
    expect(slots.staleSlotFacets, isEmpty);
    for (var index = 0; index < 8; index++) {
      expect(slots.slots[index].hf.name.value, 'Slot ${index + 1} HF');
      expect(slots.slots[index].lf.name.value, 'Slot ${index + 1} LF');
    }
  });

  test('lost reply marks only unresolved source and target facts stale',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator
      ..events.clear()
      ..loseSwapReply = true
      ..applySwapBeforeLostReply = true
      ..failNames = true;

    expect(
      await fixture.status.reorderSlots(1, 4),
      SlotReorderOutcome.ambiguous,
    );

    final slots = fixture.status.snapshot.slots;
    expect(fixture.communicator.swapCalls, 1);
    expect(slots.availability, SlotsAvailability.stale);
    expect(slots.staleFacets, isNot(contains(SlotFacet.names)));
    expect(slots.staleSlotFacets.keys, {1, 4});
    expect(slots.staleSlotFacets[1], {SlotFacet.names});
    expect(slots.staleSlotFacets[4], {SlotFacet.names});
    expect(slots.staleSlotFacets.containsKey(0), isFalse);
    expect(slots.pendingReorder, isNull);
  });

  test('a later complete refresh repairs precise reorder uncertainty',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator
      ..loseSwapReply = true
      ..applySwapBeforeLostReply = true
      ..failNames = true;

    expect(
      await fixture.status.reorderSlots(1, 4),
      SlotReorderOutcome.ambiguous,
    );
    expect(fixture.status.snapshot.slots.staleSlotFacets.keys, {1, 4});

    fixture.communicator.failNames = false;
    await fixture.status.refreshSlots();

    final repaired = fixture.status.snapshot.slots;
    expect(repaired.availability, SlotsAvailability.available);
    expect(repaired.staleSlotFacets, isEmpty);
    expect(repaired.slots[1].hf.name.value, 'Slot 5 HF');
    expect(repaired.slots[4].hf.name.value, 'Slot 2 HF');
  });

  test('queued reorder does not start after communicator replacement',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    final foregroundGate = Completer<void>();
    final foregroundStarted = Completer<void>();
    final foreground = fixture.appState.rfOperations.runForeground(() async {
      foregroundStarted.complete();
      await foregroundGate.future;
    });
    await foregroundStarted.future;

    final reorder = fixture.status.reorderSlots(0, 1);
    fixture.replaceConnection();
    foregroundGate.complete();
    await foreground;

    expect(await reorder, SlotReorderOutcome.connectionChanged);
    expect(fixture.communicator.capabilityReads, 0);
    expect(fixture.communicator.swapCalls, 0);
  });

  test('running old-session reorder sends no reconciliation commands',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator.events.clear();
    final gate = Completer<void>();
    fixture.communicator.swapGate = gate;

    final reorder = fixture.status.reorderSlots(0, 1);
    await fixture.communicator.swapStarted.future;
    fixture.replaceConnection();
    gate.complete();

    expect(await reorder, SlotReorderOutcome.connectionChanged);
    expect(fixture.communicator.events, ['capabilities', 'swap:0:1']);
    expect(fixture.communicator.slotTypeReads, 1);
    expect(fixture.communicator.enabledSlotReads, 1);
    expect(fixture.communicator.slotNameReads, 1);
    expect(fixture.communicator.activeSlotReads, 1);
  });

  test('disconnect during command suppresses late state and reconciliation',
      () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    fixture.communicator.events.clear();
    final gate = Completer<void>();
    fixture.communicator.swapGate = gate;
    final oldStatus = fixture.status;
    var latePublications = 0;
    oldStatus.addListener(() => latePublications++);

    final reorder = oldStatus.reorderSlots(0, 1);
    await fixture.communicator.swapStarted.future;
    latePublications = 0;
    await fixture.appState.disconnect(manual: true);
    gate.complete();

    expect(await reorder, SlotReorderOutcome.connectionChanged);
    expect(fixture.communicator.events, ['capabilities', 'swap:0:1']);
    expect(latePublications, 0);
    expect(fixture.appState.connectedDeviceStatus, isNull);
  });

  test('same and invalid positions perform no device work', () async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);

    expect(
      await fixture.status.reorderSlots(3, 3),
      SlotReorderOutcome.confirmed,
    );
    expect(
      await fixture.status.reorderSlots(-1, 2),
      SlotReorderOutcome.invalid,
    );
    expect(fixture.communicator.events, isEmpty);
  });

  test('Demo advertises and persistently swaps whole bundles', () async {
    final logger = Logger();
    addTearDown(logger.close);
    final serial = EmulatorSerial(log: logger);
    await serial.connectSpecificDevice('Demo');
    final communicator = ChameleonCommunicator(logger, port: serial);

    final capabilities = await communicator.getDeviceCapabilities();
    final namesBefore = await communicator.getSlotTagNames();
    final activeBefore = await communicator.getActiveSlot();
    await communicator.swapSlots(0, 1);
    final namesAfter = await communicator.getSlotTagNames();
    final activeAfter = await communicator.getActiveSlot();

    expect(capabilities, contains(ChameleonCommand.swapSlots.value));
    expect(namesAfter[0].hf, namesBefore[1].hf);
    expect(namesAfter[0].lf, namesBefore[1].lf);
    expect(namesAfter[1].hf, namesBefore[0].hf);
    expect(namesAfter[1].lf, namesBefore[0].lf);
    expect(
      activeAfter,
      activeBefore == 0
          ? 1
          : activeBefore == 1
              ? 0
              : activeBefore,
    );
  });
}

class _Fixture {
  _Fixture({required this.appState, required this.communicator});

  final ChameleonGUIState appState;
  final _ReorderCommunicator communicator;

  ConnectedDeviceStatus get status => appState.connectedDeviceStatus!;

  void replaceConnection() {
    appState
      ..connector = (_TestSerial(log: Logger())
        ..connected = true
        ..device = ChameleonDevice.ultra
        ..connectionType = ConnectionType.usb
        ..portName = 'replacement'
        ..activeDevicePort = 'replacement')
      ..communicator = _ReorderCommunicator();
  }

  void dispose() {
    appState.dispose();
  }
}

_Fixture _fixture({
  bool supportsSwap = true,
  ConnectionType connectionType = ConnectionType.usb,
}) {
  final communicator = _ReorderCommunicator()..supportsSwap = supportsSwap;
  final serial = _TestSerial(log: Logger())
    ..connected = true
    ..device = ChameleonDevice.ultra
    ..connectionType = connectionType
    ..portName = 'test-device'
    ..activeDevicePort = 'test-device';
  final appState = ChameleonGUIState(
    SharedPreferencesProvider(),
    firmwareCatalog: const CurrentFirmwareCatalogStub(),
  )
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
  return _Fixture(appState: appState, communicator: communicator);
}

class _ReorderCommunicator extends ChameleonCommunicator {
  _ReorderCommunicator() : super(Logger()) {
    slotTypes = List.generate(
      8,
      (index) => SlotTypes(
        hf: index.isEven ? TagType.mifare1K : TagType.ntag213,
        lf: index.isEven ? TagType.em410X : TagType.hidProx,
      ),
    );
    enabledSlots = List.generate(
      8,
      (index) => EnabledSlotInfo(hf: index.isEven, lf: index.isOdd),
    );
    slotNames = List.generate(
      8,
      (index) => SlotNames(
        hf: 'Slot ${index + 1} HF',
        lf: 'Slot ${index + 1} LF',
      ),
    );
  }

  bool supportsSwap = true;
  bool failCapabilities = false;
  bool rejectSwap = false;
  bool loseSwapReply = false;
  bool applySwapBeforeLostReply = false;
  bool failNames = false;
  int capabilityReads = 0;
  int swapCalls = 0;
  int slotTypeReads = 0;
  int enabledSlotReads = 0;
  int slotNameReads = 0;
  int activeSlotReads = 0;
  int slotMutationCalls = 0;
  int activeSlot = 0;
  Completer<void>? swapGate;
  Completer<void> swapStarted = Completer<void>();
  final List<String> events = [];
  late List<SlotTypes> slotTypes;
  late List<EnabledSlotInfo> enabledSlots;
  late List<SlotNames> slotNames;

  void makeSlotsVisiblyIdentical(int source, int target) {
    slotTypes[target] = SlotTypes(
      hf: slotTypes[source].hf,
      lf: slotTypes[source].lf,
    );
    enabledSlots[target] = EnabledSlotInfo(
      hf: enabledSlots[source].hf,
      lf: enabledSlots[source].lf,
    );
    slotNames[target] = SlotNames(
      hf: slotNames[source].hf,
      lf: slotNames[source].lf,
    );
  }

  @override
  Future<List<int>> getDeviceCapabilities() async {
    capabilityReads++;
    events.add('capabilities');
    if (failCapabilities) {
      throw StateError('capabilities unavailable');
    }
    return supportsSwap ? [ChameleonCommand.swapSlots.value] : [];
  }

  @override
  Future<void> swapSlots(int source, int target) async {
    swapCalls++;
    events.add('swap:$source:$target');
    if (!swapStarted.isCompleted) {
      swapStarted.complete();
    }
    await swapGate?.future;
    if (!supportsSwap) {
      throw const SlotReorderRejected(0x67);
    }
    if (rejectSwap) {
      throw const SlotReorderRejected(0x66);
    }
    if (!loseSwapReply || applySwapBeforeLostReply) {
      _applySwap(source, target);
    }
    if (loseSwapReply) {
      throw TimeoutException('reply lost');
    }
  }

  void _applySwap(int source, int target) {
    final sourceTypes = slotTypes[source];
    slotTypes[source] = slotTypes[target];
    slotTypes[target] = sourceTypes;
    final sourceEnabled = enabledSlots[source];
    enabledSlots[source] = enabledSlots[target];
    enabledSlots[target] = sourceEnabled;
    final sourceNames = slotNames[source];
    slotNames[source] = slotNames[target];
    slotNames[target] = sourceNames;
    if (activeSlot == source) {
      activeSlot = target;
    } else if (activeSlot == target) {
      activeSlot = source;
    }
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    slotTypeReads++;
    events.add('types');
    return [
      for (final value in slotTypes) SlotTypes(hf: value.hf, lf: value.lf)
    ];
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    enabledSlotReads++;
    events.add('enabled');
    return [
      for (final value in enabledSlots)
        EnabledSlotInfo(hf: value.hf, lf: value.lf),
    ];
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    slotNameReads++;
    events.add('names');
    if (failNames) {
      throw StateError('names unavailable');
    }
    return [
      for (final value in slotNames) SlotNames(hf: value.hf, lf: value.lf),
    ];
  }

  @override
  Future<int> getActiveSlot() async {
    activeSlotReads++;
    events.add('active');
    return activeSlot;
  }

  @override
  Future<void> setSlotTagName(
    int index,
    String name,
    TagFrequency frequency,
  ) async {
    slotMutationCalls++;
    final current = slotNames[index];
    slotNames[index] = SlotNames(
      hf: frequency == TagFrequency.hf ? name : current.hf,
      lf: frequency == TagFrequency.lf ? name : current.lf,
    );
  }
}

class _ReplySerial extends AbstractSerial {
  _ReplySerial({required super.log});

  late ChameleonCommunicator communicator;
  int responseStatus = ChameleonStatus.success;
  final List<ChameleonCommand> commands = [];
  final List<Uint8List> payloads = [];

  @override
  Future<bool> write(Uint8List request, {bool firmware = false}) async {
    final commandValue = request[2] << 8 | request[3];
    final command = ChameleonCommand.values.firstWhere(
      (candidate) => candidate.value == commandValue,
    );
    final length = request[6] << 8 | request[7];
    commands.add(command);
    payloads.add(Uint8List.fromList(request.sublist(9, 9 + length)));
    await messageCallback(
      communicator.makeDataFrameBytes(
        command,
        responseStatus,
        Uint8List(0),
      ),
    );
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;
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
