import 'dart:async';
import 'dart:ui' show PointerDeviceKind, SemanticsAction;

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/home_slot_grid.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'long press drags one whole slot without activating and swaps once',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    await fixture.status.refreshSlotReorderCapability();
    await _pumpGrid(tester, fixture.status);
    expect(fixture.status.snapshot.slots.reorderCapability,
        SlotReorderCapability.supported);
    await _dragSlot(
      tester,
      source: 0,
      target: 1,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(fixture.communicator.activations, isEmpty);
    expect(fixture.communicator.swaps, [(0, 1)]);
    expect(fixture.status.snapshot.slots.slots[0].hf.name.value, 'Slot 2 HF');
    expect(fixture.status.snapshot.slots.slots[1].hf.name.value, 'Slot 1 HF');
  });

  testWidgets('normal tap stays immediate and same or outside drops cancel',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture);

    await tester.tap(find.byKey(const Key('home-slot-3')));
    await tester.pumpAndSettle();
    expect(fixture.communicator.activations, [2]);

    var gesture = await _startSlotDrag(tester, 0);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('home-slot-1'))),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, isEmpty);

    gesture = await _startSlotDrag(tester, 0);
    await gesture.moveTo(const Offset(4, 4));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, isEmpty);
    expect(fixture.communicator.activations, [2]);
  });

  testWidgets('two-by-four drag swaps the whole row-major bundle',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture, layout: SlotLayout.twoByFour);

    await _dragSlot(tester, source: 0, target: 4);
    await tester.pumpAndSettle();

    expect(fixture.communicator.activations, isEmpty);
    expect(fixture.communicator.swaps, [(0, 4)]);
    expect(fixture.status.snapshot.slots.slots[0].hf.name.value, 'Slot 5 HF');
    expect(fixture.status.snapshot.slots.slots[4].lf.name.value, 'Slot 1 LF');
  });

  testWidgets('unsupported firmware disables drag but keeps tap and explains',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture = _fixture(supportsSwap: false);
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture);

    expect(
      fixture.status.snapshot.slots.reorderCapability,
      SlotReorderCapability.unsupported,
    );
    expect(find.byType(LongPressDraggable<int>), findsNothing);
    final slotSemantics =
        tester.getSemantics(find.byKey(const Key('home-slot-1')));
    expect(
      slotSemantics.label,
      contains('Slot reordering is not supported by this firmware.'),
    );
    expect(
      slotSemantics.hint,
      'Slot reordering is not supported by this firmware.',
    );

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pumpAndSettle();
    expect(fixture.communicator.activations, [1]);
    expect(fixture.communicator.swaps, isEmpty);
    semantics.dispose();
  });

  testWidgets(
      'pending reorder keeps both confirmed columns visible and blocks repeats',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    fixture.communicator.swapGate = gate;
    await _prepareGrid(tester, fixture);

    await _dragSlot(tester, source: 0, target: 1);
    await tester.pump();

    expect(
      fixture.status.snapshot.slots.pendingReorder,
      const PendingSlotReorder(source: 0, target: 1),
    );
    expect(
      find.byKey(const Key('home-slot-1-reorder-progress')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('home-slot-2-reorder-progress')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-1'))).label,
      contains('Reorder pending: source, destination slot 2'),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-2'))).label,
      contains('Reorder pending: destination, source slot 1'),
    );
    expect(
      find.byKey(const Key('home-slot-1-hf-mark-enabled')),
      findsOneWidget,
    );
    expect(find.byType(LongPressDraggable<int>), findsNothing);

    await tester.tap(
      find.byKey(const Key('home-slot-3')),
      warnIfMissed: false,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(fixture.communicator.swaps, [(0, 1)]);
    expect(fixture.communicator.activations, isEmpty);

    gate.complete();
    await tester.pumpAndSettle();
    expect(fixture.status.snapshot.slots.pendingReorder, isNull);
    expect(find.byType(LongPressDraggable<int>), findsNWidgets(8));
  });

  testWidgets(
      'failed reorder preserves the grid and shows one actionable error',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator.rejectSwap = true;
    await _prepareGrid(tester, fixture);

    await _dragSlot(tester, source: 0, target: 1);
    await tester.pumpAndSettle();

    expect(fixture.communicator.swaps, [(0, 1)]);
    expect(fixture.status.snapshot.slots.slots[0].hf.name.value, 'Slot 1 HF');
    expect(fixture.status.snapshot.slots.slots[1].hf.name.value, 'Slot 2 HF');
    expect(
      find.byKey(const Key('home-slot-reorder-error')),
      findsOneWidget,
    );
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).action?.label,
      'Retry',
    );
  });

  testWidgets(
      'lost response is ambiguous, runs one command, and offers manual retry',
      (tester) async {
    final fixture = _fixture(activeSlot: 2);
    addTearDown(fixture.dispose);
    fixture.communicator
      ..makeSlotsVisiblyIdentical(0, 1)
      ..throwAfterSwap = true;
    await _prepareGrid(tester, fixture);

    await _dragSlot(tester, source: 0, target: 1);
    await tester.pumpAndSettle();

    expect(fixture.communicator.swaps, [(0, 1)]);
    expect(
      find.textContaining(
        'The slot swap could not be confirmed. Check the slot contents before retrying.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).action?.label,
      'Retry',
    );
    await tester.pump(const Duration(seconds: 2));
    expect(fixture.communicator.swaps, [(0, 1)]);
  });

  testWidgets('incomplete reconciliation has distinct actionable feedback',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator.failNamesReadAfterSwap = true;
    await _prepareGrid(tester, fixture);

    await _dragSlot(tester, source: 0, target: 1);
    await tester.pumpAndSettle();

    expect(fixture.communicator.swaps, [(0, 1)]);
    expect(
      find.textContaining(
        'The slot swap completed, but the refreshed slot state is incomplete.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).action?.label,
      'Retry',
    );
  });

  testWidgets('Retry from old feedback never reorders a replacement device',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    fixture.communicator.rejectSwap = true;
    await _prepareGrid(tester, fixture);

    await _dragSlot(tester, source: 0, target: 1);
    await tester.pumpAndSettle();
    final staleRetry =
        tester.widget<SnackBar>(find.byType(SnackBar)).action!.onPressed;

    final replacement = fixture.replaceConnection();
    await replacement.status.refreshSlots();
    await replacement.status.refreshSlotReorderCapability();
    await _pumpGrid(tester, replacement.status);
    staleRetry();
    await tester.pumpAndSettle();

    expect(replacement.communicator.swaps, isEmpty);
    expect(find.byKey(const Key('home-slot-reorder-error')), findsNothing);
  });

  testWidgets('late result from a replaced session has no old-page feedback',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    fixture.communicator.swapGate = gate;
    await _prepareGrid(tester, fixture);

    await _dragSlot(tester, source: 0, target: 1);
    await tester.pump();
    final replacement = fixture.replaceConnection();
    await replacement.status.refreshSlots();
    await replacement.status.refreshSlotReorderCapability();
    await _pumpGrid(tester, replacement.status);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-slot-reorder-error')), findsNothing);
    expect(replacement.status.snapshot.slots.pendingReorder, isNull);
  });

  testWidgets('disconnect during reorder clears UI without stale feedback',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    fixture.communicator.swapGate = gate;
    await _prepareGrid(tester, fixture);

    await _dragSlot(tester, source: 0, target: 1);
    await tester.pump();
    final disconnectedStatus = fixture.status;
    fixture.disconnect();
    expect(disconnectedStatus.isCurrentSession, isFalse);

    gate.complete();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('home-slot-reorder-error')), findsNothing);
  });

  testWidgets('Shift arrows reorder while plain arrows still activate',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, [(0, 1)]);
    expect(fixture.communicator.activations, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(fixture.communicator.activations, [2]);
  });

  testWidgets('two-by-four Shift arrows use row and column adjacency',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture, layout: SlotLayout.twoByFour);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, [(0, 4)]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(fixture.communicator.activations, [3]);
  });

  testWidgets('two-by-four Shift arrows stop at physical row edges',
      (tester) async {
    final ltr = _fixture(activeSlot: 3);
    addTearDown(ltr.dispose);
    await _prepareGrid(tester, ltr, layout: SlotLayout.twoByFour);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(ltr.communicator.swaps, isEmpty);

    final rtl = _fixture(activeSlot: 3);
    addTearDown(rtl.dispose);
    await _prepareGrid(
      tester,
      rtl,
      layout: SlotLayout.twoByFour,
      textDirection: TextDirection.rtl,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(rtl.communicator.swaps, isEmpty);
  });

  testWidgets('Shift arrows follow RTL visual geometry in both layouts',
      (tester) async {
    final eightAcross = _fixture();
    addTearDown(eightAcross.dispose);
    await _prepareGrid(
      tester,
      eightAcross,
      textDirection: TextDirection.rtl,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(eightAcross.communicator.swaps, [(0, 1)]);

    final twoByFour = _fixture(activeSlot: 3);
    addTearDown(twoByFour.dispose);
    await _prepareGrid(
      tester,
      twoByFour,
      layout: SlotLayout.twoByFour,
      textDirection: TextDirection.rtl,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(twoByFour.communicator.swaps, [(3, 2)]);
  });

  testWidgets('Demo session uses the same deterministic whole-slot gesture',
      (tester) async {
    final fixture = _fixture(demo: true);
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    await _pumpGrid(tester, fixture.status);
    await tester.pump();

    expect(
      fixture.status.snapshot.slots.reorderCapability,
      SlotReorderCapability.supported,
    );
    await _dragSlot(tester, source: 2, target: 6);
    await tester.pumpAndSettle();

    expect(fixture.communicator.swaps, [(2, 6)]);
    expect(fixture.status.snapshot.slots.slots[2].hf.name.value, 'Slot 7 HF');
    expect(fixture.status.snapshot.slots.slots[6].lf.name.value, 'Slot 3 LF');
  });

  testWidgets('screen reader exposes and invokes move-before and move-after',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture);

    final node = tester.getSemantics(find.byKey(const Key('home-slot-2')));
    final data = node.getSemanticsData();
    expect(data.customSemanticsActionIds, hasLength(2));
    final actions = [
      for (final id in data.customSemanticsActionIds!)
        CustomSemanticsAction.getAction(id)!.label,
    ];
    expect(
      actions,
      containsAll(['Move before slot 1', 'Move after slot 3']),
    );

    final moveAfter = data.customSemanticsActionIds!.firstWhere(
      (id) => CustomSemanticsAction.getAction(id)!.label == 'Move after slot 3',
    );
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      moveAfter,
    );
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, [(1, 2)]);
    semantics.dispose();
  });

  testWidgets(
      'screen reader actions share RTL two-by-four neighbors without row crossover',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(
      tester,
      fixture,
      layout: SlotLayout.twoByFour,
      textDirection: TextDirection.rtl,
    );

    final node = tester.getSemantics(find.byKey(const Key('home-slot-4')));
    final data = node.getSemanticsData();
    final actions = [
      for (final id in data.customSemanticsActionIds!)
        CustomSemanticsAction.getAction(id)!.label,
    ];
    expect(actions, ['Move before slot 3']);
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      data.customSemanticsActionIds!.single,
    );
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, [(3, 2)]);
    semantics.dispose();
  });

  testWidgets('drag semantics identify source and destination without color',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture);

    final gesture = await _startSlotDrag(tester, 0);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('home-slot-2'))),
    );
    await tester.pump();

    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-1'))).label,
      contains('Reorder source, destination slot 2'),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-2'))).label,
      contains('Reorder destination, source slot 1'),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets('narrow auto-scroll reveals a destination and drops exact swap',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await _prepareGrid(tester, fixture);

    final scroll = find.byKey(const Key('home-slot-grid-scroll'));
    final gesture = await _startSlotDrag(tester, 0);
    final rect = tester.getRect(scroll);
    await gesture.moveTo(Offset(rect.right - 2, rect.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scroll, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.pixels, greaterThan(0));

    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('home-slot-8'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fixture.communicator.swaps, [(0, 7)]);
    expect(fixture.status.snapshot.slots.slots[0].hf.name.value, 'Slot 8 HF');
    expect(fixture.status.snapshot.slots.slots[7].lf.name.value, 'Slot 1 LF');
  });

  testWidgets('reduced motion keeps drag and pending progress without lift',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    fixture.communicator.swapGate = gate;
    await fixture.status.refreshSlots();
    await fixture.status.refreshSlotReorderCapability();
    await _pumpGrid(
      tester,
      fixture.status,
      mediaQuery: const MediaQueryData(disableAnimations: true),
    );

    final gesture = await _startSlotDrag(tester, 0);
    final preview = find.byKey(const Key('home-slot-1-drag-preview'));
    final transform = tester.widget<Transform>(
      find.ancestor(of: preview, matching: find.byType(Transform)).first,
    );
    expect(transform.transform.storage[0], 1);
    final opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.byKey(const Key('home-slot-1')),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 1);

    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('home-slot-2'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(
      find.byKey(const Key('home-slot-1-reorder-progress')),
      findsOneWidget,
    );
    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('responsive reorder targets survive theme and text matrix',
      (tester) async {
    final fixture = _fixture();
    addTearDown(fixture.dispose);
    await fixture.status.refreshSlots();
    await fixture.status.refreshSlotReorderCapability();

    for (final width in [360.0, 700.0, 1200.0]) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await _pumpGrid(
          tester,
          fixture.status,
          mediaQuery: const MediaQueryData(
            textScaler: TextScaler.linear(1.8),
          ),
          theme: ThemeData(brightness: brightness),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        for (var slot = 1; slot <= 8; slot++) {
          final size = tester.getSize(
            find.byKey(Key('home-slot-$slot-reorder-target')),
          );
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _prepareGrid(
  WidgetTester tester,
  _Fixture fixture, {
  SlotLayout layout = SlotLayout.eightAcross,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  await fixture.status.refreshSlots();
  await fixture.status.refreshSlotReorderCapability();
  await _pumpGrid(
    tester,
    fixture.status,
    layout: layout,
    textDirection: textDirection,
  );
  await tester.pump();
}

Future<TestGesture> _startSlotDrag(
  WidgetTester tester,
  int source, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final slot = source + 1;
  expect(find.byKey(Key('home-slot-$slot-draggable')), findsOneWidget);
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(Key('home-slot-$slot'))),
    pointer: 20 + source,
    kind: kind,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 300));
  expect(
    find.byKey(Key('home-slot-$slot-drag-preview')),
    findsOneWidget,
  );
  return gesture;
}

Future<void> _dragSlot(
  WidgetTester tester, {
  required int source,
  required int target,
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final gesture = await _startSlotDrag(tester, source, kind: kind);
  await gesture.moveTo(
    tester.getCenter(find.byKey(Key('home-slot-${target + 1}'))),
  );
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

Future<void> _pumpGrid(
  WidgetTester tester,
  ConnectedDeviceStatus status, {
  SlotLayout layout = SlotLayout.eightAcross,
  MediaQueryData mediaQuery = const MediaQueryData(),
  ThemeData? theme,
  TextDirection textDirection = TextDirection.ltr,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MediaQuery(
            data: mediaQuery,
            child: Directionality(
              textDirection: textDirection,
              child: Center(
                child: HomeSlotGrid(status: status, layout: layout),
              ),
            ),
          ),
        ),
      ),
    );

class _Fixture {
  const _Fixture({
    required this.appState,
    required this.communicator,
    required this.serial,
  });

  final ChameleonGUIState appState;
  final _ReorderCommunicator communicator;
  final _TestSerial serial;

  ConnectedDeviceStatus get status => appState.connectedDeviceStatus!;

  _Fixture replaceConnection() {
    final replacementCommunicator = _ReorderCommunicator();
    final replacementSerial = _TestSerial(log: Logger())
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb
      ..portName = 'replacement-home-reorder-test'
      ..activeDevicePort = 'replacement-home-reorder-test';
    appState
      ..connector = replacementSerial
      ..communicator = replacementCommunicator;
    return _Fixture(
      appState: appState,
      communicator: replacementCommunicator,
      serial: replacementSerial,
    );
  }

  void disconnect() {
    serial.connected = false;
    appState.onConnectorStateChanged();
  }

  void dispose() => appState.dispose();
}

_Fixture _fixture({
  bool supportsSwap = true,
  bool demo = false,
  int activeSlot = 0,
}) {
  final communicator = _ReorderCommunicator()..supportsSwap = supportsSwap;
  communicator.activeSlot = activeSlot;
  final serial = _TestSerial(log: Logger())
    ..connected = true
    ..device = ChameleonDevice.ultra
    ..connectionType = ConnectionType.usb
    ..portName = demo ? 'Demo' : 'home-reorder-test'
    ..activeDevicePort = 'home-reorder-test';
  final appState = ChameleonGUIState(
    SharedPreferencesProvider(),
    firmwareCatalog: const CurrentFirmwareCatalogStub(),
  )
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
  return _Fixture(
    appState: appState,
    communicator: communicator,
    serial: serial,
  );
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
  bool rejectSwap = false;
  bool throwAfterSwap = false;
  bool failNamesReadAfterSwap = false;
  int activeSlot = 0;
  Completer<void>? swapGate;
  final List<int> activations = [];
  final List<(int, int)> swaps = [];
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
  Future<List<int>> getDeviceCapabilities() async =>
      supportsSwap ? [ChameleonCommand.swapSlots.value] : [];

  @override
  Future<void> activateSlot(int slot) async {
    activations.add(slot);
    activeSlot = slot;
  }

  @override
  Future<void> swapSlots(int source, int target) async {
    swaps.add((source, target));
    await swapGate?.future;
    if (rejectSwap) {
      throw const SlotReorderRejected(0x66);
    }
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
    if (throwAfterSwap) {
      throw StateError('Lost whole-slot reorder reply');
    }
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async => [
        for (final slot in slotTypes) SlotTypes(hf: slot.hf, lf: slot.lf),
      ];

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async => [
        for (final slot in enabledSlots)
          EnabledSlotInfo(hf: slot.hf, lf: slot.lf),
      ];

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    if (failNamesReadAfterSwap && swaps.isNotEmpty) {
      throw StateError('Slot names unavailable during reconciliation');
    }
    return [
      for (final slot in slotNames) SlotNames(hf: slot.hf, lf: slot.lf),
    ];
  }

  @override
  Future<int> getActiveSlot() async => activeSlot;

  @override
  Future<BatteryCharge> getBatteryCharge() async =>
      BatteryCharge(percent: 60, voltage: 3900);

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x0100);

  @override
  Future<String> getGitCommitHash() async => 'abcdef0';

  @override
  Future<bool> isReaderDeviceMode() async => false;
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
