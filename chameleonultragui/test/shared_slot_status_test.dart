import 'dart:async';
import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/home_slot_grid.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/edit.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';
import 'support/test_viewport.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesProvider().load();
  });

  test('slot layout defaults globally and survives preferences reload',
      () async {
    final preferences = SharedPreferencesProvider();
    var notifications = 0;
    void listener() => notifications++;
    preferences.addListener(listener);
    addTearDown(() => preferences.removeListener(listener));

    expect(preferences.getSlotLayout(), SlotLayout.eightAcross);

    preferences.setSlotLayout(SlotLayout.twoByFour);
    await Future<void>.delayed(Duration.zero);

    expect(preferences.getSlotLayout(), SlotLayout.twoByFour);
    expect(notifications, 1);

    await preferences.load();
    expect(preferences.getSlotLayout(), SlotLayout.twoByFour);

    final stored = await SharedPreferences.getInstance();
    expect(stored.getKeys(), contains('slot_layout'));
    expect(
      stored.getKeys(),
      isNot(contains(matches(RegExp('model|port|serial|connection')))),
    );
  });

  test('slot layout falls back to eight across for an invalid preference',
      () async {
    SharedPreferences.setMockInitialValues({'slot_layout': 37});
    final preferences = SharedPreferencesProvider();
    await preferences.load();

    expect(preferences.getSlotLayout(), SlotLayout.eightAcross);
  });

  testWidgets('Home uses a named Material segmented slot layout selector',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final preferences = SharedPreferencesProvider();
    final appState = _connectedState(_SlotCommunicator());

    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    final selector = find.byKey(const Key('home-slot-layout-control'));
    expect(selector, findsOneWidget);
    expect(
      find.descendant(
        of: selector,
        matching: find.byWidgetPredicate(
          (widget) => widget is SegmentedButton<SlotLayout>,
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('••••••••'), findsOneWidget);
    expect(find.text('••••\n••••'), findsOneWidget);
    expect(find.byTooltip('Eight slots in one row'), findsOneWidget);
    expect(find.byTooltip('Two rows of four slots'), findsOneWidget);
    expect(tester.getSize(selector).height, greaterThanOrEqualTo(48));
    final selectorLabel = tester.getSemantics(selector).label;
    expect(selectorLabel, contains('Slot layout'));
    expect(selectorLabel, isNot(contains('•')));
    expect(
      find.bySemanticsLabel('Eight slots in one row'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Two rows of four slots'),
      findsOneWidget,
    );
    expect(
        find.byKey(const Key('home-slot-grid-eight-across')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-slot-layout-two-by-four')));
    await tester.pumpAndSettle();

    expect(preferences.getSlotLayout(), SlotLayout.twoByFour);
    expect(find.byKey(const Key('home-slot-grid-two-by-four')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('two-by-four keeps row-major slots tappable at 360px',
      (tester) async {
    setTestViewport(tester, size: const Size(360, 900));
    final semantics = tester.ensureSemantics();
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-slot-layout-two-by-four')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final rects = [
      for (var slot = 1; slot <= 8; slot++)
        tester.getRect(find.byKey(Key('home-slot-$slot'))),
    ];
    for (var index = 0; index < 8; index++) {
      expect(rects[index].width, greaterThanOrEqualTo(48));
      expect(rects[index].height, greaterThanOrEqualTo(48));
      expect(
        tester.getSemantics(find.byKey(Key('home-slot-${index + 1}'))).label,
        startsWith('Slot ${index + 1}.'),
      );
    }
    expect(rects.take(4).map((rect) => rect.center.dy).toSet(), hasLength(1));
    expect(rects.skip(4).map((rect) => rect.center.dy).toSet(), hasLength(1));
    expect(rects[4].center.dy, greaterThan(rects[0].center.dy));
    expect(rects[4].center.dx, closeTo(rects[0].center.dx, 0.1));
    for (final rowStart in [0, 4]) {
      for (var index = rowStart + 1; index < rowStart + 4; index++) {
        expect(rects[index].center.dx, greaterThan(rects[index - 1].center.dx));
      }
    }

    await tester.tap(find.byKey(const Key('home-slot-6')));
    await tester.pumpAndSettle();
    expect(communicator.activations, [5]);
    expect(find.byKey(const Key('home-active-slot-6')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('slot layout survives remount and a different device session',
      (tester) async {
    final preferences = SharedPreferencesProvider();
    final appState = _connectedState(_SlotCommunicator());
    preferences.setSlotLayout(SlotLayout.twoByFour);

    await _pumpPage(tester, appState, const HomePage());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const Key('home-slot-grid-two-by-four')), findsOneWidget);

    await _pumpPage(tester, appState, const SizedBox.shrink());
    appState
      ..connector = (_TestSerial(log: Logger())
        ..connected = true
        ..device = ChameleonDevice.lite
        ..connectionType = ConnectionType.ble
        ..portName = 'different-device'
        ..activeDevicePort = 'different-device')
      ..communicator = _SlotCommunicator()
      ..changesMade();

    await _pumpPage(tester, appState, const HomePage());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(
      appState.connectedDeviceStatus!.snapshot.identity.device,
      ChameleonDevice.lite,
    );
    expect(preferences.getSlotLayout(), SlotLayout.twoByFour);
    expect(find.byKey(const Key('home-slot-grid-two-by-four')), findsOneWidget);
    final selector = tester.widget<SegmentedButton<SlotLayout>>(
      find.byWidgetPredicate(
        (widget) => widget is SegmentedButton<SlotLayout>,
      ),
    );
    expect(selector.selected, {SlotLayout.twoByFour});
  });

  testWidgets('layout switch keeps slot focus after direct arrow activation',
      (tester) async {
    final preferences = SharedPreferencesProvider();
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    final focusFinder = find.byKey(const Key('home-slot-grid-focus'));
    for (var attempt = 0;
        attempt < 12 &&
            !(tester.widget<Focus>(focusFinder).focusNode?.hasFocus ?? false);
        attempt++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(tester.widget<Focus>(focusFinder).focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

    preferences.setSlotLayout(SlotLayout.twoByFour);
    await tester.pumpAndSettle();

    expect(tester.widget<Focus>(focusFinder).focusNode!.hasFocus, isTrue);
    expect(communicator.activations, [1]);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
  });

  testWidgets(
      'eight-across restores scroll and focus after a two-by-four roundtrip',
      (tester) async {
    setTestViewport(tester, size: const Size(360, 900));
    final preferences = SharedPreferencesProvider();
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    final scrollFinder = find.byKey(const Key('home-slot-grid-scroll'));
    final focusFinder = find.byKey(const Key('home-slot-grid-focus'));
    for (var attempt = 0;
        attempt < 12 &&
            !(tester.widget<Focus>(focusFinder).focusNode?.hasFocus ?? false);
        attempt++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(tester.widget<Focus>(focusFinder).focusNode!.hasFocus, isTrue);
    for (var step = 0; step < 7; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pumpAndSettle();
    final before = tester
        .state<ScrollableState>(
          find.descendant(
            of: scrollFinder,
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(before, greaterThan(40));

    preferences.setSlotLayout(SlotLayout.twoByFour);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-slot-grid-two-by-four')), findsOneWidget);

    preferences.setSlotLayout(SlotLayout.eightAcross);
    await tester.pumpAndSettle();

    final after = tester
        .state<ScrollableState>(
          find.descendant(
            of: scrollFinder,
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(after, closeTo(before, 0.1));

    expect(communicator.activations, List.generate(7, (index) => index + 1));

    await tester.tap(find.byKey(const Key('home-slot-7')));
    await tester.pumpAndSettle();
    expect(
      communicator.activations,
      [...List.generate(7, (index) => index + 1), 6],
    );
  });

  for (final layout in SlotLayout.values) {
    testWidgets('${layout.name} blocks duplicate activation while pending',
        (tester) async {
      final gate = Completer<void>();
      final preferences = SharedPreferencesProvider();
      preferences.setSlotLayout(layout);
      final communicator = _SlotCommunicator()..activationGate = gate;
      final appState = _connectedState(communicator);
      await _pumpPage(tester, appState, const HomePage());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('home-slot-6')));
      await tester.pump();
      expect(communicator.activations, [5]);
      expect(find.byKey(const Key('home-slot-6-progress')), findsOneWidget);
      expect(find.byKey(const Key('home-active-slot-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-slot-7')));
      await tester.pump();
      expect(communicator.activations, [5]);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-slot-6-progress')), findsNothing);
      expect(find.byKey(const Key('home-active-slot-6')), findsOneWidget);
    });
  }

  testWidgets('Home shows eight numbered HF and LF slot columns',
      (tester) async {
    setTestViewport(tester, size: const Size(1200, 900));

    final appState = _connectedState(_SlotCommunicator());
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-slot-grid')), findsOneWidget);
    expect(find.text('HF'), findsOneWidget);
    expect(find.text('LF'), findsOneWidget);
    for (var slot = 1; slot <= 8; slot++) {
      expect(find.byKey(Key('home-slot-$slot')), findsOneWidget);
      expect(find.text('$slot'), findsOneWidget);
    }
    expect(find.textContaining('Used Slots:'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.byIcon(Icons.arrow_forward), findsNothing);
  });

  testWidgets('Home polls only active slot once per second while present',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    expect(communicator.activeSlotReads, 1);
    final initialTypeReads = communicator.slotTypeReads;
    final initialModeReads = communicator.modeReads;
    await tester.pump(const Duration(seconds: 1));
    expect(communicator.activeSlotReads, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(communicator.activeSlotReads, 3);
    expect(communicator.slotTypeReads, initialTypeReads);
    expect(communicator.modeReads, initialModeReads);

    await _pumpPage(tester, appState, const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(communicator.activeSlotReads, 3);
  });

  testWidgets(
      'returning to Home uses confirmed cache without a full status reload',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    final initialTypeReads = communicator.slotTypeReads;
    final initialEnabledReads = communicator.enabledSlotReads;
    final initialNameReads = communicator.slotNameReads;
    final initialModeReads = communicator.modeReads;

    await _pumpPage(tester, appState, const SizedBox.shrink());
    await tester.pump();
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    expect(communicator.slotTypeReads, initialTypeReads);
    expect(communicator.enabledSlotReads, initialEnabledReads);
    expect(communicator.slotNameReads, initialNameReads);
    expect(communicator.modeReads, initialModeReads);
    expect(find.byKey(const Key('home-slot-grid')), findsOneWidget);
  });

  testWidgets('physical slot change leaves no old pointer selection highlight',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    final oldSlot = find.byKey(const Key('home-slot-5'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(oldSlot));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.down(tester.getCenter(oldSlot));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-active-slot-5')), findsOneWidget);

    communicator.activeSlot = 5;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-active-slot-5')), findsNothing);
    expect(find.byKey(const Key('home-active-slot-6')), findsOneWidget);
    final oldSlotSurface = tester.widget<AnimatedContainer>(
      find.descendant(
        of: oldSlot,
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect((oldSlotSurface.decoration! as BoxDecoration).color, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(communicator.activations.last, 6);
    expect(find.byKey(const Key('home-active-slot-7')), findsOneWidget);
  });

  testWidgets('Home describes and draws enabled, disabled, and empty marks',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final communicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: false),
      )
      ..slotNames = List.generate(
        8,
        (index) => index == 0
            ? SlotNames(hf: 'Lab pass', lf: 'Garage fob')
            : SlotNames(),
      );
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('home-slot-1-hf-mark-enabled')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('home-slot-1-lf-mark-disabled')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('home-slot-2-hf-mark-empty')),
      findsOneWidget,
    );
    final hfEnabled = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('home-slot-1-hf-mark-enabled')),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
        (hfEnabled.decoration as BoxDecoration).color, Colors.green.shade700);
    final lfDisabled = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('home-slot-1-lf-mark-disabled')),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      ((lfDisabled.decoration as BoxDecoration).border! as Border).top.color,
      Colors.blue.shade700,
    );
    expect(
      tester.getCenter(find.text('HF')).dx,
      lessThan(
        tester
            .getCenter(
              find.byKey(const Key('home-slot-1-hf-mark-enabled')),
            )
            .dx,
      ),
    );
    expect(
      tester.getCenter(find.text('LF')).dx,
      lessThan(
        tester
            .getCenter(
              find.byKey(const Key('home-slot-1-lf-mark-disabled')),
            )
            .dx,
      ),
    );
    expect(
      find.byTooltip(
        'Slot 1\n'
        'HF: Lab pass · Mifare Classic 1K · Enabled\n'
        'LF: Garage fob · EM410X · Disabled\n'
        'Active slot\n'
        'Slot reordering is not supported by this firmware.',
      ),
      findsOneWidget,
    );
    final slotSemantics =
        tester.getSemantics(find.byKey(const Key('home-slot-1')));
    expect(slotSemantics.label, contains('Lab pass'));
    expect(slotSemantics.label, contains('Enabled'));
    expect(slotSemantics.label, contains('Disabled'));
    expect(slotSemantics.label, contains('Active slot'));
    expect(slotSemantics.flagsCollection.isSelected, Tristate.isTrue);

    final activeFrame = find.byKey(const Key('home-active-slot-1'));
    expect(activeFrame, findsOneWidget);
    final frameRect = tester.getRect(activeFrame);
    expect(
      frameRect.top,
      lessThan(
        tester
            .getRect(find.byKey(const Key('home-slot-1-hf-mark-enabled')))
            .top,
      ),
    );
    expect(
      frameRect.bottom,
      greaterThan(tester.getRect(find.text('1')).bottom),
    );
    final frame = tester.widget<AnimatedContainer>(activeFrame);
    final decoration = frame.decoration! as BoxDecoration;
    expect(decoration.border!.top.color, isNot(Colors.red));
    semantics.dispose();
  });

  testWidgets('Home uses lighter HF and LF shades in dark theme',
      (tester) async {
    final communicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: false),
      );
    final appState = _connectedState(communicator);
    await _pumpPage(
      tester,
      appState,
      const HomePage(),
      theme: ThemeData.dark(useMaterial3: true),
    );
    await tester.pumpAndSettle();

    final hfEnabled = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('home-slot-1-hf-mark-enabled')),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
        (hfEnabled.decoration as BoxDecoration).color, Colors.green.shade300);
    final lfDisabled = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('home-slot-1-lf-mark-disabled')),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      ((lfDisabled.decoration as BoxDecoration).border! as Border).top.color,
      Colors.blue.shade300,
    );
  });

  testWidgets('active slot frame stays white in light and dark themes',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(
      tester,
      appState,
      const HomePage(),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.light(primary: Colors.red),
      ),
    );
    await tester.pumpAndSettle();

    var frame = tester.widget<AnimatedContainer>(
      find.byKey(const Key('home-active-slot-1')),
    );
    var frameColor = (frame.decoration! as BoxDecoration).border!.top.color;
    expect(frameColor, Colors.white);

    await _pumpPage(
      tester,
      appState,
      const HomePage(),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.dark(primary: Colors.red),
      ),
    );
    await tester.pumpAndSettle();

    frame = tester.widget<AnimatedContainer>(
      find.byKey(const Key('home-active-slot-1')),
    );
    frameColor = (frame.decoration! as BoxDecoration).border!.top.color;
    expect(frameColor, Colors.white);
  });

  testWidgets('Home explains unknown enabled state and unavailable slot data',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final unknownEnabled = _SlotCommunicator()..failEnabled = true;
    var appState = _connectedState(unknownEnabled);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('home-slot-1-hf-mark-enabledUnknown')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-1'))).label,
      contains('Enabled status unknown, Dashed outline'),
    );

    final unavailable = _SlotCommunicator()..failAll = true;
    appState = _connectedState(unavailable);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('home-slot-1-hf-mark-unavailable')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-1'))).label,
      contains('HF: Unavailable · Unavailable · Unavailable'),
    );
    expect(find.byKey(const Key('home-slot-refresh')), findsNothing);
    semantics.dispose();
  });

  testWidgets('narrow Home slots have distinct 48px pointer targets',
      (tester) async {
    setTestViewport(tester, size: const Size(360, 900));
    final semantics = tester.ensureSemantics();
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshSlots();

    await _pumpPage(
      tester,
      appState,
      Scaffold(body: Center(child: HomeSlotGrid(status: status))),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final slotFinders = [
      for (var slot = 1; slot <= 8; slot++) find.byKey(Key('home-slot-$slot')),
    ];
    final initialRects = [
      for (final finder in slotFinders) tester.getRect(finder),
    ];
    for (var index = 0; index < slotFinders.length; index++) {
      final finder = slotFinders[index];
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(
        tester
            .getSemantics(finder)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(
        find.bySemanticsLabel(RegExp('^Slot ${index + 1}\\.')),
        findsOneWidget,
      );
      for (var other = index + 1; other < initialRects.length; other++) {
        expect(
          initialRects[index].intersect(initialRects[other]).isEmpty,
          isTrue,
          reason: 'Slot ${index + 1} overlaps slot ${other + 1}',
        );
      }
    }

    for (var index = 0; index < slotFinders.length; index++) {
      final finder = slotFinders[index];
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      final rect = tester.getRect(finder);
      final points = [
        rect.center,
        Offset(rect.left + 4, rect.center.dy),
        Offset(rect.right - 4, rect.center.dy),
      ];
      for (final point in points) {
        final activationCount = communicator.activations.length;
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(communicator.activations, hasLength(activationCount + 1));
        expect(
          communicator.activations.last,
          index,
          reason: 'Point $point must activate slot ${index + 1}',
        );
      }
    }
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('home-slot-grid-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, greaterThan(0));

    await tester.ensureVisible(slotFinders.first);
    await tester.pumpAndSettle();
    await tester.tap(slotFinders.first);
    await tester.pumpAndSettle();
    communicator.activations.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    for (var index = 1; index < slotFinders.length; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(communicator.activations, List.generate(8, (index) => index));
    final scrollRect = tester.getRect(
      find.byKey(const Key('home-slot-grid-scroll')),
    );
    final lastSlotRect = tester.getRect(slotFinders.last);
    expect(lastSlotRect.left, greaterThanOrEqualTo(scrollRect.left));
    expect(lastSlotRect.right, lessThanOrEqualTo(scrollRect.right));

    final activationGate = Completer<void>();
    communicator.activationGate = activationGate;
    await tester.ensureVisible(slotFinders[1]);
    await tester.pumpAndSettle();
    await tester.tap(slotFinders[1]);
    await tester.pump();

    for (final finder in slotFinders) {
      final data = tester.getSemantics(finder).getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    }

    activationGate.complete();
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  testWidgets(
      'Home blocks repeated activation and moves frame after command reply',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    communicator.commandEvents.clear();
    final activationGate = Completer<void>();
    communicator.activationGate = activationGate;

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();

    expect(communicator.commandEvents, ['activate:1']);
    expect(find.byKey(const Key('home-slot-2-progress')), findsOneWidget);
    expect(
      find.byKey(const Key('home-slot-2-hf-mark-empty')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('home-slot-2-lf-mark-empty')),
      findsNothing,
    );
    final progressRect =
        tester.getRect(find.byKey(const Key('home-slot-2-progress')));
    final slotRect = tester.getRect(find.byKey(const Key('home-slot-2')));
    expect(progressRect.width, greaterThanOrEqualTo(24));
    expect(progressRect.center.dx, closeTo(slotRect.center.dx, 1));
    expect(find.byKey(const Key('home-active-slot-1')), findsOneWidget);
    expect(find.byKey(const Key('home-active-slot-2')), findsNothing);
    await tester.tap(find.byKey(const Key('home-slot-3')));
    await tester.pump();
    expect(communicator.activations, [1]);

    activationGate.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-slot-2-progress')), findsNothing);
    expect(find.byKey(const Key('home-active-slot-1')), findsNothing);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
  });

  testWidgets(
      'successful slot reply does not wait for a redundant confirmation',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    final initialActiveReads = communicator.activeSlotReads;
    communicator.scriptedActiveSlotReads.add(
      StateError('must not be consumed by activation'),
    );

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(communicator.activations, [1]);
    expect(slots.activeSlot.value, 1);
    expect(slots.pendingActivation, isNull);
    expect(slots.staleFacets, isNot(contains(SlotFacet.activeSlot)));
    expect(communicator.activeSlotReads, initialActiveReads);
    expect(communicator.scriptedActiveSlotReads, hasLength(1));
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
    expect(find.byKey(const Key('home-slot-2-progress')), findsNothing);
    expect(find.byKey(const Key('home-slot-activation-error')), findsNothing);
  });

  testWidgets('slot frame moves on the command reply without a blocking reread',
      (tester) async {
    final activationGate = Completer<void>();
    final communicator = _SlotCommunicator()..activationGate = activationGate;
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    communicator.commandEvents.clear();

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();

    expect(find.byKey(const Key('home-slot-2-progress')), findsOneWidget);
    expect(find.byKey(const Key('home-active-slot-1')), findsOneWidget);

    activationGate.complete();
    await tester.pump();
    await tester.pump();

    expect(communicator.commandEvents, ['activate:1']);
    expect(find.byKey(const Key('home-slot-2-progress')), findsNothing);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
  });

  testWidgets(
      'lost activation reply confirms an applied slot without another tap',
      (tester) async {
    final communicator = _SlotCommunicator()
      ..failActivation = true
      ..applyActivationBeforeFailure = true;
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    communicator.commandEvents.clear();

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();
    await tester.pump();

    expect(communicator.activations, [1]);
    expect(communicator.commandEvents, ['activate:1', 'read-active']);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
    expect(find.byKey(const Key('home-slot-activation-error')), findsNothing);
  });

  testWidgets('arrow and number keys activate slots immediately',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-slot-1')));
    await tester.pumpAndSettle();
    communicator.activations.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(communicator.activations, [1]);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);

    const numberKeys = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
    ];
    communicator.activations.clear();
    for (final key in numberKeys) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    expect(communicator.activations, List.generate(8, (index) => index));
    expect(find.byKey(const Key('home-active-slot-8')), findsOneWidget);
  });

  testWidgets('full refresh cannot clear a queued Home activation',
      (tester) async {
    final refreshGate = Completer<void>();
    final activationGate = Completer<void>();
    final communicator = _SlotCommunicator()
      ..nextTypesGate = refreshGate
      ..activationGate = activationGate;
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const HomePage());
    await tester.pump();

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();
    expect(
      appState.connectedDeviceStatus!.snapshot.slots.pendingActivation,
      1,
    );

    refreshGate.complete();
    await tester.pump();
    await tester.pump();

    expect(communicator.activations, [1]);
    expect(
      appState.connectedDeviceStatus!.snapshot.slots.pendingActivation,
      1,
    );
    expect(find.byKey(const Key('home-slot-2-progress')), findsOneWidget);
    expect(find.byKey(const Key('home-active-slot-1')), findsOneWidget);
    expect(find.byKey(const Key('home-active-slot-2')), findsNothing);

    await tester.tap(find.byKey(const Key('home-slot-3')));
    await tester.tap(find.byKey(const Key('home-slot-4')));
    await tester.pump();
    expect(communicator.activations, [1]);
    expect(
      appState.connectedDeviceStatus!.snapshot.slots.pendingActivation,
      1,
    );

    activationGate.complete();
    await tester.pumpAndSettle();

    expect(communicator.activations, [1]);
    expect(find.byKey(const Key('home-slot-2-progress')), findsNothing);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
  });

  testWidgets('Home activation failure preserves frame and shows one error',
      (tester) async {
    final communicator = _SlotCommunicator()..failActivation = true;
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();

    expect(find.byKey(const Key('home-active-slot-1')), findsOneWidget);
    expect(find.byKey(const Key('home-active-slot-2')), findsNothing);
    expect(find.byKey(const Key('home-slot-activation-error')), findsOneWidget);
    expect(
      find.byKey(const Key('home-slot-activation-error')),
      findsOneWidget,
    );
  });

  testWidgets('firmware rejection does not use ambiguous-result recovery',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    communicator
      ..commandEvents.clear()
      ..activeSlot = 1
      ..activationRejectionStatus = 0x66;

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();

    expect(communicator.commandEvents, ['activate:1']);
    expect(find.byKey(const Key('home-active-slot-1')), findsOneWidget);
    expect(find.byKey(const Key('home-active-slot-2')), findsNothing);
    expect(find.byKey(const Key('home-slot-activation-error')), findsOneWidget);
  });

  testWidgets('old Home activation cannot report into a replacement session',
      (tester) async {
    final oldGate = Completer<void>();
    final oldCommunicator = _SlotCommunicator()..activationGate = oldGate;
    final appState = _connectedState(oldCommunicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();
    expect(oldCommunicator.activations, [1]);

    final newCommunicator = _SlotCommunicator()..name = 'Replacement';
    _replaceConnection(appState, newCommunicator);
    appState.changesMade();
    await tester.pump();
    await tester.pumpAndSettle();

    oldCommunicator.failActivation = true;
    oldGate.complete();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-slot-activation-error')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.byKey(const Key('home-slot-3')));
    await tester.pumpAndSettle();
    expect(newCommunicator.activations, [2]);
    expect(find.byKey(const Key('home-active-slot-3')), findsOneWidget);
  });

  testWidgets('unpumped replacement suppresses an old activation error',
      (tester) async {
    final oldGate = Completer<void>();
    final oldCommunicator = _SlotCommunicator()
      ..activationGate = oldGate
      ..failActivation = true;
    final appState = _connectedState(oldCommunicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();
    expect(oldCommunicator.activations, [1]);

    _replaceConnection(appState, _SlotCommunicator());
    oldGate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('home-slot-activation-error')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('Home skips busy active polling without making slots stale',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    final readsBeforeBusyTick = communicator.activeSlotReads;
    final gate = Completer<void>();
    final started = Completer<void>();
    final foreground = appState.rfOperations.runForeground(() async {
      started.complete();
      await gate.future;
    });
    await started.future;

    await tester.pump(const Duration(seconds: 1));

    expect(communicator.activeSlotReads, readsBeforeBusyTick);
    expect(
      appState.connectedDeviceStatus!.snapshot.slots.staleFacets,
      isEmpty,
    );
    gate.complete();
    await foreground;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(communicator.activeSlotReads, readsBeforeBusyTick + 1);
  });

  testWidgets('passive active poll failure is silent, stale, and retries',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    communicator.failActive = true;

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    var slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.activeSlot.value, 0);
    expect(slots.staleFacets, {SlotFacet.activeSlot});
    expect(find.byKey(const Key('home-active-slot-1')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(const Key('home-slot-refresh')), findsNothing);

    communicator
      ..failActive = false
      ..activeSlot = 1;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.activeSlot.value, 1);
    expect(slots.staleFacets, isEmpty);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
  });

  testWidgets('Home automatically repairs stale slot facts without a button',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    final status = appState.connectedDeviceStatus!;

    communicator
      ..failTypes = true
      ..failEnabled = true
      ..failNames = true;
    await status.refreshSlots();
    await tester.pump();

    expect(status.snapshot.slots.availability, SlotsAvailability.stale);
    expect(
      status.snapshot.slots.staleFacets,
      containsAll({SlotFacet.types, SlotFacet.enabledStates, SlotFacet.names}),
    );
    expect(find.byKey(const Key('home-slot-refresh')), findsNothing);

    communicator
      ..failTypes = false
      ..failEnabled = false
      ..failNames = false;
    final typeReads = communicator.slotTypeReads;
    final enabledReads = communicator.enabledSlotReads;
    final nameReads = communicator.slotNameReads;

    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump();

    expect(status.snapshot.slots.availability, SlotsAvailability.available);
    expect(status.snapshot.slots.staleFacets, isEmpty);
    expect(communicator.slotTypeReads, typeReads + 1);
    expect(communicator.enabledSlotReads, enabledReads + 1);
    expect(communicator.slotNameReads, nameReads + 1);
    expect(find.byKey(const Key('home-slot-refresh')), findsNothing);
  });

  testWidgets('Home pauses polling and refreshes active slot on resume',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();
    final activeReads = communicator.activeSlotReads;
    final batteryReads = communicator.batteryReads;
    final typeReads = communicator.slotTypeReads;
    final modeReads = communicator.modeReads;

    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(communicator.activeSlotReads, activeReads);
    expect(communicator.batteryReads, batteryReads);

    communicator.activeSlot = 1;
    tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pumpAndSettle();

    expect(communicator.activeSlotReads, activeReads + 1);
    expect(communicator.batteryReads, batteryReads + 1);
    expect(communicator.slotTypeReads, typeReads);
    expect(communicator.modeReads, modeReads);
    expect(find.byKey(const Key('home-active-slot-2')), findsOneWidget);
  });

  testWidgets('Tab focuses slots and arrows activate directly in Reader mode',
      (tester) async {
    final communicator = _SlotCommunicator()..readerMode = true;
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pumpAndSettle();

    final focusFinder = find.byKey(const Key('home-slot-grid-focus'));
    for (var attempt = 0;
        attempt < 12 &&
            !(tester.widget<Focus>(focusFinder).focusNode?.hasFocus ?? false);
        attempt++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(tester.widget<Focus>(focusFinder).focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(communicator.activations, [1, 2]);
    expect(find.byKey(const Key('home-active-slot-3')), findsOneWidget);
    expect(
      appState.connectedDeviceStatus!.snapshot.mode.confirmedMode,
      ConnectedDeviceMode.reader,
    );
  });

  testWidgets('loading marks pulse only when reduced motion is off',
      (tester) async {
    final reducedMotionGate = Completer<void>();
    final reducedMotionCommunicator = _SlotCommunicator()
      ..nextTypesGate = reducedMotionGate;
    var appState = _connectedState(reducedMotionCommunicator);
    await _pumpPage(
      tester,
      appState,
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: HomePage(),
      ),
    );
    await tester.pump();

    var fades = find.descendant(
      of: find.byKey(const Key('home-slot-grid')),
      matching: find.byType(FadeTransition),
    );
    expect(fades, findsNWidgets(16));
    var fade = tester.widgetList<FadeTransition>(fades).first;
    final reducedOpacity = fade.opacity.value;
    final reducedRect = tester.getRect(fades.first);
    await tester.pump(const Duration(milliseconds: 350));
    fade = tester.widgetList<FadeTransition>(fades).first;
    expect(fade.opacity.value, reducedOpacity);
    expect(tester.getRect(fades.first), reducedRect);
    reducedMotionGate.complete();
    await tester.pumpAndSettle();

    final motionGate = Completer<void>();
    final motionCommunicator = _SlotCommunicator()..nextTypesGate = motionGate;
    appState = _connectedState(motionCommunicator);
    await _pumpPage(tester, appState, const HomePage());
    await tester.pump();

    fades = find.descendant(
      of: find.byKey(const Key('home-slot-grid')),
      matching: find.byType(FadeTransition),
    );
    expect(fades, findsNWidgets(16));
    fade = tester.widgetList<FadeTransition>(fades).first;
    final animatedOpacity = fade.opacity.value;
    final animatedRect = tester.getRect(fades.first);
    await tester.pump(const Duration(milliseconds: 350));
    fade = tester.widgetList<FadeTransition>(fades).first;
    expect(fade.opacity.value, isNot(animatedOpacity));
    expect(tester.getRect(fades.first), animatedRect);
    motionGate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('Slot Manager refreshes the confirmed Home slot snapshot',
      (tester) async {
    setTestViewport(tester, size: const Size(1200, 1400));

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

    expect(communicator.slotTypeReads, 2);
    expect(communicator.enabledSlotReads, 2);
    expect(communicator.slotNameReads, 2);
    expect(communicator.activeSlotReads, 2);
    final emptyHf = appState.connectedDeviceStatus!.snapshot.slots.slots[1].hf;
    expect(emptyHf.type.isConfirmed, isTrue);
    expect(emptyHf.type.value, TagType.unknown);
    expect(find.byKey(const Key('home-slot-grid')), findsOneWidget);
    expect(find.textContaining('Office'), findsOneWidget);
  });

  testWidgets('name failure keeps confirmed types and enabled state visible',
      (tester) async {
    setTestViewport(tester, size: const Size(1200, 1400));

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
    expect(find.byKey(const Key('home-slot-grid')), findsOneWidget);
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
    expect(find.byKey(const Key('home-slot-grid')), findsOneWidget);

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

    await tester.tap(find.byKey(const Key('home-slot-2')));
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

    communicator.scriptedActiveSlotReads.add(1);
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
    expect(slots.staleFacets, isNot(contains(SlotFacet.activeSlot)));
    expect(slots.availability, SlotsAvailability.available);
    final activationPublication = observedActiveSlots.indexOf(1);
    expect(activationPublication, isNonNegative);
    expect(
      observedActiveSlots.skip(activationPublication),
      everyElement(1),
    );
  });

  testWidgets('invalid fallback read keeps the previous active slot stale',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    final status = appState.connectedDeviceStatus!;
    expect(status.snapshot.slots.activeSlot.value, 0);

    communicator
      ..failActivation = true
      ..scriptedActiveSlotReads.add(8);
    expect(await status.activateSlot(1), isFalse);
    await tester.pump();

    final slots = status.snapshot.slots;
    expect(communicator.activations, [1]);
    expect(slots.activeSlot.value, 0);
    expect(slots.staleFacets, contains(SlotFacet.activeSlot));
    expect(slots.availability, SlotsAvailability.stale);
  });

  testWidgets('failed reply publishes a confirmed unchanged active slot',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    final status = appState.connectedDeviceStatus!;
    expect(status.snapshot.slots.activeSlot.value, 0);

    communicator
      ..failActivation = true
      ..scriptedActiveSlotReads.add(0);
    expect(await status.activateSlot(1), isFalse);
    await tester.pump();

    final slots = status.snapshot.slots;
    expect(communicator.activations, [1]);
    expect(slots.activeSlot.value, 0);
    expect(slots.staleFacets, isNot(contains(SlotFacet.activeSlot)));
    expect(slots.availability, SlotsAvailability.available);
  });

  testWidgets(
      'slot mutation reconciles one shared snapshot across Home and Slot Manager',
      (tester) async {
    setTestViewport(tester, size: const Size(1200, 1400));

    final communicator = _SlotCommunicator();
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
    final status = appState.connectedDeviceStatus!;
    final initialReads = communicator.slotTypeReads;

    await status.mutateSlots((mutation) async {
      await mutation.run(
        (communicator) => communicator.setSlotTagName(
          0,
          'Workshop',
          TagFrequency.hf,
        ),
      );
    });
    await tester.pump();

    expect(communicator.slotTypeReads, initialReads + 1);
    expect(status.snapshot.slots.slots.first.hf.name.value, 'Workshop');
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-1'))).label,
      contains('Workshop'),
    );
    expect(find.textContaining('Workshop'), findsOneWidget);
  });

  testWidgets(
      'queued activation stays pending through slot mutation reconciliation',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshSlots();
    final initialSlotReads = communicator.slotTypeReads;
    final mutationGate = Completer<void>();
    final mutationStarted = Completer<void>();
    final activationGate = Completer<void>();
    communicator.activationGate = activationGate;
    addTearDown(() {
      if (!mutationGate.isCompleted) {
        mutationGate.complete();
      }
      if (!activationGate.isCompleted) {
        activationGate.complete();
      }
    });

    final mutation = status.mutateSlots<void>((_) async {
      mutationStarted.complete();
      await mutationGate.future;
    });
    await mutationStarted.future;

    final activation = status.activateSlot(1);
    expect(status.snapshot.slots.pendingActivation, 1);
    expect(await status.activateSlot(1), isFalse);

    mutationGate.complete();
    await mutation;

    expect(communicator.slotTypeReads, initialSlotReads + 1);
    expect(status.snapshot.slots.activeSlot.value, 0);
    expect(status.snapshot.slots.pendingActivation, 1);
    expect(communicator.activations, [1]);
    expect(await status.activateSlot(1), isFalse);

    activationGate.complete();
    expect(await activation, isTrue);
    expect(status.snapshot.slots.activeSlot.value, 1);
    expect(status.snapshot.slots.pendingActivation, isNull);
    expect(communicator.activations, [1]);
  });

  testWidgets(
      'queued activation keeps the active slot confirmed by reconciliation',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshSlots();
    final mutationGate = Completer<void>();
    final mutationStarted = Completer<void>();
    final activationGate = Completer<void>();
    communicator
      ..activationGate = activationGate
      ..failActivation = true;
    addTearDown(() {
      if (!mutationGate.isCompleted) {
        mutationGate.complete();
      }
      if (!activationGate.isCompleted) {
        activationGate.complete();
      }
    });

    final mutation = status.mutateSlots<void>((_) async {
      mutationStarted.complete();
      await mutationGate.future;
    });
    await mutationStarted.future;

    final activation = status.activateSlot(2);
    communicator.activeSlot = 1;
    mutationGate.complete();
    await mutation;

    expect(status.snapshot.slots.activeSlot.value, 1);
    expect(status.snapshot.slots.pendingActivation, 2);
    expect(await status.activateSlot(2), isFalse);

    activationGate.complete();
    expect(await activation, isFalse);
    expect(status.snapshot.slots.activeSlot.value, 1);
    expect(
      status.snapshot.slots.staleFacets,
      isNot(contains(SlotFacet.activeSlot)),
    );
    expect(status.snapshot.slots.pendingActivation, isNull);
  });

  testWidgets('queued mode switch stays pending through slot reconciliation',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshMode();
    await status.refreshSlots();
    final initialModeReads = communicator.modeReads;
    final mutationGate = Completer<void>();
    final mutationStarted = Completer<void>();
    final modeWriteGate = Completer<void>();
    final modeWriteStarted = Completer<void>();
    communicator
      ..modeWriteGate = modeWriteGate
      ..modeWriteStarted = modeWriteStarted;
    addTearDown(() {
      if (!mutationGate.isCompleted) {
        mutationGate.complete();
      }
      if (!modeWriteGate.isCompleted) {
        modeWriteGate.complete();
      }
    });

    final mutation = status.mutateSlots<void>(
      (_) async {
        mutationStarted.complete();
        await mutationGate.future;
      },
      reconcileMode: true,
    );
    await mutationStarted.future;

    final modeSwitch = status.switchMode(ConnectedDeviceMode.reader);
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.emulator);
    expect(status.snapshot.mode.pendingMode, ConnectedDeviceMode.reader);
    expect(
      await status.switchMode(ConnectedDeviceMode.reader),
      ModeActionOutcome.busy,
    );

    mutationGate.complete();
    await mutation;
    await modeWriteStarted.future;

    expect(communicator.modeReads, initialModeReads + 1);
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.emulator);
    expect(status.snapshot.mode.pendingMode, ConnectedDeviceMode.reader);
    expect(
      await status.switchMode(ConnectedDeviceMode.reader),
      ModeActionOutcome.busy,
    );

    modeWriteGate.complete();
    expect(await modeSwitch, ModeActionOutcome.confirmed);
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.reader);
    expect(status.snapshot.mode.pendingMode, isNull);
    expect(
      communicator.commandEvents.where((event) => event == 'mode:true'),
      hasLength(1),
    );
  });

  testWidgets('queued mode switch keeps the mode confirmed by reconciliation',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshMode();
    await status.refreshSlots();
    final mutationGate = Completer<void>();
    final mutationStarted = Completer<void>();
    final modeWriteGate = Completer<void>();
    final modeWriteStarted = Completer<void>();
    communicator
      ..modeWriteGate = modeWriteGate
      ..modeWriteStarted = modeWriteStarted;
    addTearDown(() {
      if (!mutationGate.isCompleted) {
        mutationGate.complete();
      }
      if (!modeWriteGate.isCompleted) {
        modeWriteGate.complete();
      }
    });

    final mutation = status.mutateSlots<void>(
      (_) async {
        mutationStarted.complete();
        await mutationGate.future;
      },
      reconcileMode: true,
    );
    await mutationStarted.future;

    final modeSwitch = status.switchMode(ConnectedDeviceMode.reader);
    communicator.readerMode = true;
    mutationGate.complete();
    await mutation;
    await modeWriteStarted.future;

    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.reader);
    expect(status.snapshot.mode.pendingMode, ConnectedDeviceMode.reader);
    expect(
      await status.switchMode(ConnectedDeviceMode.reader),
      ModeActionOutcome.busy,
    );

    communicator.failModeRead = true;
    modeWriteGate.complete();
    expect(await modeSwitch, ModeActionOutcome.failed);
    expect(status.snapshot.mode.availability, ModeAvailability.available);
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.reader);
    expect(status.snapshot.mode.pendingMode, isNull);
  });

  for (final disconnect in [false, true]) {
    testWidgets(
        'pending mode write stops before confirmation after connection '
        '${disconnect ? 'disconnect' : 'replacement'}', (tester) async {
      final modeWriteGate = Completer<void>();
      final modeWriteStarted = Completer<void>();
      addTearDown(() {
        if (!modeWriteGate.isCompleted) {
          modeWriteGate.complete();
        }
      });
      final oldCommunicator = _SlotCommunicator()
        ..modeWriteGate = modeWriteGate
        ..modeWriteStarted = modeWriteStarted;
      final appState = _connectedState(oldCommunicator);
      final oldStatus = appState.connectedDeviceStatus!;
      await tester.pumpAndSettle();
      expect(
        oldStatus.snapshot.mode.availability,
        ModeAvailability.available,
      );
      oldCommunicator.commandEvents.clear();
      final initialModeReads = oldCommunicator.modeReads;
      var latePublications = 0;
      oldStatus.addListener(() => latePublications++);

      final modeSwitch = oldStatus.switchMode(ConnectedDeviceMode.reader);
      await modeWriteStarted.future;
      latePublications = 0;

      _SlotCommunicator? newCommunicator;
      ConnectedDeviceStatus? newStatus;
      if (disconnect) {
        await appState.disconnect(manual: true);
      } else {
        newCommunicator = _SlotCommunicator();
        _replaceConnection(appState, newCommunicator);
        newStatus = appState.connectedDeviceStatus!;
      }

      modeWriteGate.complete();

      expect(await modeSwitch, ModeActionOutcome.connectionChanged);
      expect(oldCommunicator.modeReads, initialModeReads);
      expect(oldCommunicator.commandEvents, ['mode:true']);
      expect(latePublications, 0);
      if (disconnect) {
        expect(appState.connectedDeviceStatus, isNull);
      } else {
        expect(newCommunicator!.commandEvents, isEmpty);
        expect(newCommunicator.modeReads, 0);
        expect(newStatus!.snapshot.mode.availability, ModeAvailability.loading);

        await tester.pumpAndSettle();

        expect(newCommunicator.commandEvents, ['read-active']);
        expect(newCommunicator.modeReads, 1);
        expect(
          newStatus.snapshot.mode.confirmedMode,
          ConnectedDeviceMode.emulator,
        );
      }
    });
  }

  testWidgets('partial slot mutation failure still reconciles device state',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshSlots();
    final initialReads = communicator.slotTypeReads;
    final mutationError = StateError('write failed after changing the name');

    Object? thrown;
    try {
      await status.mutateSlots((mutation) async {
        await mutation.run(
          (communicator) => communicator.setSlotTagName(
            0,
            'Partially written',
            TagFrequency.hf,
          ),
        );
        throw mutationError;
      });
    } catch (error) {
      thrown = error;
    }

    expect(thrown, same(mutationError));
    expect(communicator.slotTypeReads, initialReads + 1);
    expect(
      status.snapshot.slots.slots.first.hf.name.value,
      'Partially written',
    );
  });

  testWidgets(
      'slot reconciliation failure keeps primary error and confirmed cache stale',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await tester.pumpAndSettle();
    await status.refreshSlots();
    final confirmed = status.snapshot.slots;
    final mutationError = StateError('primary mutation failure');
    communicator.failAll = true;

    Object? thrown;
    try {
      await status.mutateSlots<void>((_) async {
        throw mutationError;
      });
    } catch (error) {
      thrown = error;
    }

    expect(thrown, same(mutationError));
    final stale = status.snapshot.slots;
    expect(stale.availability, SlotsAvailability.stale);
    expect(stale.staleFacets, SlotFacet.values.toSet());
    expect(stale.slots, confirmed.slots);
    expect(stale.activeSlot, confirmed.activeSlot);
  });

  testWidgets('slot mutation reconciles actual mode when workflow changes it',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await tester.pumpAndSettle();
    await status.refreshMode();
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.emulator);
    final initialModeReads = communicator.modeReads;

    await status.mutateSlots(
      (mutation) => mutation.run(
        (communicator) => communicator.setReaderDeviceMode(true),
      ),
      reconcileMode: true,
    );

    expect(communicator.modeReads, initialModeReads + 1);
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.reader);
  });

  testWidgets(
      'failed mode reconciliation preserves confirmation as unavailable and later repairs',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await tester.pumpAndSettle();
    await status.refreshMode();
    await status.refreshSlots();
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.emulator);

    communicator.failModeRead = true;
    final result = await status.mutateSlots(
      (mutation) async {
        await mutation.run(
          (communicator) => communicator.setReaderDeviceMode(true),
        );
        return 7;
      },
      reconcileMode: true,
    );

    expect(result, 7);
    expect(status.snapshot.slots.availability, SlotsAvailability.available);
    expect(status.snapshot.mode.availability, ModeAvailability.unavailable);
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.emulator);
    expect(status.snapshot.mode.pendingMode, isNull);

    communicator.failModeRead = false;
    await status.refreshMode();
    expect(status.snapshot.mode.availability, ModeAvailability.available);
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.reader);
  });

  testWidgets('queued slot mutation never starts after connection replacement',
      (tester) async {
    final oldCommunicator = _SlotCommunicator();
    final appState = _connectedState(oldCommunicator);
    final status = appState.connectedDeviceStatus!;
    final foregroundGate = Completer<void>();
    final foregroundStarted = Completer<void>();
    final foreground = appState.rfOperations.runForeground(() async {
      foregroundStarted.complete();
      await foregroundGate.future;
    });
    await foregroundStarted.future;
    var mutationStarted = false;
    final result = status.mutateSlots<void>((_) async {
      mutationStarted = true;
    }).then<Object?>((_) => null, onError: (Object error) => error);

    _replaceConnection(appState, _SlotCommunicator());
    foregroundGate.complete();
    await foreground;

    expect(await result, isA<SlotMutationConnectionChanged>());
    expect(mutationStarted, isFalse);
    expect(oldCommunicator.slotTypeReads, 0);
  });

  testWidgets(
      'running slot mutation stops later steps and publication after replacement',
      (tester) async {
    final oldCommunicator = _SlotCommunicator();
    final appState = _connectedState(oldCommunicator);
    final status = appState.connectedDeviceStatus!;
    final firstStepGate = Completer<void>();
    final firstStepStarted = Completer<void>();
    final result = status.mutateSlots<void>((mutation) async {
      await mutation.run((_) async {
        firstStepStarted.complete();
        await firstStepGate.future;
      });
      await mutation.run(
        (communicator) => communicator.setSlotTagName(
          0,
          'Must not run',
          TagFrequency.hf,
        ),
      );
    }).then<Object?>((_) => null, onError: (Object error) => error);
    await firstStepStarted.future;

    _replaceConnection(appState, _SlotCommunicator());
    firstStepGate.complete();

    expect(await result, isA<SlotMutationConnectionChanged>());
    expect(oldCommunicator.commandEvents,
        isNot(contains(contains('Must not run'))));
    expect(oldCommunicator.slotTypeReads, 0);
    expect(oldCommunicator.enabledSlotReads, 0);
    expect(oldCommunicator.slotNameReads, 0);
    expect(oldCommunicator.activeSlotReads, 0);
  });

  testWidgets('Slot Manager upload owns RF and reconciles slots and mode once',
      (tester) async {
    final modeGate = Completer<void>();
    final modeStarted = Completer<void>();
    final communicator = _SlotCommunicator()
      ..modeWriteGate = modeGate
      ..modeWriteStarted = modeStarted;
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    final status = appState.connectedDeviceStatus!;
    final initialTypeReads = communicator.slotTypeReads;
    final initialBatteryReads = communicator.batteryReads;
    final state = tester.state<SlotManagerPageState>(
      find.byType(SlotManagerPage),
    );
    final localizations = AppLocalizations.of(
      tester.element(find.byType(SlotManagerPage)),
    )!;

    final upload = state.onTap(
      CardSave(uid: '01 02 03 04 05', name: 'Badge', tag: TagType.em410X),
      (_, __) {},
      localizations,
    );
    await modeStarted.future;
    await status.refreshBattery();
    expect(communicator.batteryReads, initialBatteryReads);

    modeGate.complete();
    await upload;
    await tester.pump();

    expect(
      communicator.commandEvents,
      containsAllInOrder([
        'mode:false',
        'enable:0:lf:true',
        'activate:0',
        'type:0:em410X',
        'default:0:em410X',
        'em410x',
        'name:0:lf:Badge',
        'save-slots',
      ]),
    );
    expect(communicator.slotTypeReads, initialTypeReads + 1);
    expect(status.snapshot.slots.slots.first.lf.name.value, 'Badge');
    expect(status.snapshot.mode.confirmedMode, ConnectedDeviceMode.emulator);
  });

  testWidgets(
      'Slot Manager repairs invalid seven-byte MIFARE 4K anticollision data',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    await _pumpPage(tester, appState, const SlotManagerPage());
    await tester.pumpAndSettle();
    final state = tester.state<SlotManagerPageState>(
      find.byType(SlotManagerPage),
    );
    final localizations = AppLocalizations.of(
      tester.element(find.byType(SlotManagerPage)),
    )!;
    final dump = List.generate(256, (_) => Uint8List(16));

    await tester.runAsync(
      () => state.onTap(
        CardSave(
          uid: '04 01 02 03 04 05 06',
          name: 'Seven-byte 4K',
          tag: TagType.mifare4K,
          sak: 0x00,
          atqa: Uint8List.fromList([0x98, 0x16]),
          data: dump,
          extraData: CardSaveExtra(mifareClassicDumpComplete: true),
        ),
        (_, __) {},
        localizations,
      ),
    );

    final antiCollision = communicator.lastMf1AntiCollision;
    expect(antiCollision, isNotNull);
    expect(antiCollision!.uid, hasLength(7));
    expect(antiCollision.sak, 0x18);
    expect(antiCollision.atqa, [0x00, 0x42]);
    expect(communicator.mf1BlockBytesWritten, 4096);
  });

  testWidgets('Slot Settings enable and delete paths reconcile shared slots',
      (tester) async {
    SharedPreferences.setMockInitialValues({'confirm_delete': false});
    await SharedPreferencesProvider().load();
    final communicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) =>
            index == 0 ? SlotNames(hf: 'Office', lf: 'Garage') : SlotNames(),
      );
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshSlots();
    await _pumpPage(tester, appState, const SlotSettings(slot: 0));
    await tester.pumpAndSettle();
    communicator.commandEvents.clear();
    final initialTypeReads = communicator.slotTypeReads;

    await tester.tap(find.byKey(const Key('slot-settings-enable-hf')));
    await tester.pumpAndSettle();
    expect(communicator.commandEvents, contains('enable:0:hf:false'));
    expect(status.snapshot.slots.slots.first.hf.enabled.value, isFalse);
    expect(communicator.slotTypeReads, initialTypeReads + 1);

    communicator.commandEvents.clear();
    await tester.tap(find.byKey(const Key('slot-settings-enable-hf')));
    await tester.pumpAndSettle();
    expect(communicator.commandEvents, contains('enable:0:hf:true'));
    expect(status.snapshot.slots.slots.first.hf.enabled.value, isTrue);
    expect(communicator.slotTypeReads, initialTypeReads + 2);

    communicator.commandEvents.clear();
    await tester.tap(find.byKey(const Key('slot-settings-delete-lf')));
    await tester.pumpAndSettle();
    expect(
      communicator.commandEvents,
      containsAllInOrder([
        'delete:0:lf',
        'name:0:lf:Empty',
        'save-slots',
      ]),
    );
    expect(status.snapshot.slots.slots.first.lf.type.value, TagType.unknown);
    expect(status.snapshot.slots.slots.first.lf.name.value, 'Empty');
  });

  testWidgets(
      'Slot Settings keeps unavailable fields inert and retries shared status',
      (tester) async {
    setTestViewport(tester, size: const Size(360, 640));
    final semantics = tester.ensureSemantics();
    final communicator = _SlotCommunicator()..failAll = true;
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotSettings(slot: 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(
      appState.connectedDeviceStatus!.snapshot.slots.availability,
      SlotsAvailability.unavailable,
    );
    expect(find.text('Empty'), findsNothing);
    expect(find.text('Unavailable'), findsNWidgets(6));
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('slot-settings-edit-hf')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('slot-settings-delete-hf')),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.bySemanticsLabel('HF enabled: Unavailable'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('slot-settings-refresh')), findsOneWidget);

    communicator.commandEvents.clear();
    for (final key in const [
      'slot-settings-edit-hf',
      'slot-settings-delete-hf',
      'slot-settings-enable-hf',
    ]) {
      await tester.tap(find.byKey(Key(key)), warnIfMissed: false);
      await tester.pump();
    }
    expect(communicator.commandEvents, isEmpty);
    expect(find.byType(SlotEditMenu), findsNothing);

    communicator.failAll = false;
    await tester.tap(find.byKey(const Key('slot-settings-refresh')));
    await tester.pumpAndSettle();

    expect(find.text('Office'), findsOneWidget);
    expect(find.text('Mifare Classic 1K'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('slot-settings-edit-hf')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<Switch>(
            find.byKey(const Key('slot-settings-enable-hf')),
          )
          .onChanged,
      isNotNull,
    );
    semantics.dispose();
  });

  testWidgets(
      'Slot Settings keeps confirmed fields when enabled state is unavailable',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final communicator = _SlotCommunicator()
      ..failEnabled = true
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..slotNames = List.generate(
        8,
        (index) =>
            index == 0 ? SlotNames(hf: 'Office', lf: 'Garage') : SlotNames(),
      );
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotSettings(slot: 0));
    await tester.pumpAndSettle();

    final slots = appState.connectedDeviceStatus!.snapshot.slots;
    expect(slots.availability, SlotsAvailability.partial);
    expect(slots.unavailableFacets, {SlotFacet.enabledStates});
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('Garage'), findsOneWidget);
    expect(find.text('Mifare Classic 1K'), findsOneWidget);
    expect(find.text('EM410X'), findsOneWidget);
    expect(find.text('Unavailable'), findsNWidgets(2));
    expect(
      find.bySemanticsLabel('HF enabled: Unavailable'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('slot-settings-edit-hf')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('slot-settings-delete-hf')),
          )
          .onPressed,
      isNotNull,
    );

    communicator.commandEvents.clear();
    await tester.tap(
      find.byKey(const Key('slot-settings-edit-hf')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(find.byType(SlotEditMenu), findsNothing);
    expect(communicator.commandEvents, isEmpty);

    communicator.failEnabled = false;
    await tester.tap(find.byKey(const Key('slot-settings-refresh')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slot-settings-edit-hf')));
    await tester.pump();

    final edit = tester.widget<SlotEditMenu>(find.byType(SlotEditMenu));
    expect(edit.name, 'Office');
    expect(edit.isEnabled, isTrue);
    expect(edit.slotType, TagType.mifare1K);
    semantics.dispose();
  });

  testWidgets(
      'open Slot Settings marks cached enabled state stale without inventing off',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final communicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) =>
            index == 0 ? SlotNames(hf: 'Office', lf: 'Garage') : SlotNames(),
      );
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;

    await _pumpPage(tester, appState, const SlotSettings(slot: 0));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
            find.byKey(const Key('slot-settings-enable-hf')),
          )
          .value,
      isTrue,
    );

    communicator.failEnabled = true;
    await status.refreshSlots();
    await tester.pump();

    expect(status.snapshot.slots.availability, SlotsAvailability.stale);
    expect(status.snapshot.slots.staleFacets, {SlotFacet.enabledStates});
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('Garage'), findsOneWidget);
    expect(find.text('Mifare Classic 1K'), findsOneWidget);
    expect(find.text('EM410X'), findsOneWidget);
    expect(find.text('Unavailable'), findsNWidgets(2));
    final hfSwitch = tester.widget<Switch>(
      find.byKey(const Key('slot-settings-enable-hf')),
    );
    expect(hfSwitch.value, isTrue);
    expect(hfSwitch.onChanged, isNull);
    expect(
      tester
          .getSemantics(find.byKey(const Key('slot-settings-enable-hf')))
          .label,
      contains('Enabled (Unavailable)'),
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('slot-settings-edit-hf')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('slot-settings-delete-hf')),
          )
          .onPressed,
      isNotNull,
    );

    communicator.commandEvents.clear();
    await tester.tap(
      find.byKey(const Key('slot-settings-enable-hf')),
      warnIfMissed: false,
    );
    await tester.tap(
      find.byKey(const Key('slot-settings-edit-hf')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(communicator.commandEvents, isEmpty);
    expect(find.byType(SlotEditMenu), findsNothing);
    semantics.dispose();
  });

  testWidgets(
      'Slot Settings passes confirmed empty fields without placeholders',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotSettings(slot: 1));
    await tester.pumpAndSettle();

    expect(find.text('Empty'), findsNWidgets(4));
    await tester.tap(find.byKey(const Key('slot-settings-edit-hf')));
    await tester.pump();

    final edit = tester.widget<SlotEditMenu>(find.byType(SlotEditMenu));
    expect(edit.name, isEmpty);
    expect(edit.isEnabled, isFalse);
    expect(edit.slotType, TagType.unknown);
  });

  testWidgets('Slot Settings keeps raw confirmed names for export',
      (tester) async {
    final communicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) => index == 0 ? SlotNames(hf: '', lf: 'Garage') : SlotNames(),
      );
    final appState = _connectedState(communicator);

    await _pumpPage(tester, appState, const SlotSettings(slot: 0));
    await tester.pumpAndSettle();
    communicator.commandEvents.clear();

    await tester.tap(find.byKey(const Key('slot-settings-export')));
    await tester.pump();

    final export = tester.widget<SlotExportMenu>(find.byType(SlotExportMenu));
    expect(export.names.hf, isEmpty);
    expect(export.names.lf, 'Garage');
    expect(communicator.commandEvents, isEmpty);
  });

  testWidgets(
      'open Slot Settings adopts replacement status and mutates its communicator',
      (tester) async {
    final oldCommunicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) =>
            index == 0 ? SlotNames(hf: 'Old HF', lf: 'Old LF') : SlotNames(),
      );
    final appState = _connectedState(oldCommunicator);
    final oldStatus = appState.connectedDeviceStatus!;
    await oldStatus.refreshSlots();
    await _pumpPage(tester, appState, const SlotSettings(slot: 0));
    await tester.pumpAndSettle();
    expect(find.text('Old HF'), findsOneWidget);

    oldCommunicator.commandEvents.clear();
    final newCommunicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: false, lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) => index == 0
            ? SlotNames(hf: 'Replacement HF', lf: 'Replacement LF')
            : SlotNames(),
      );
    _replaceConnection(appState, newCommunicator);
    final newStatus = appState.connectedDeviceStatus!;
    appState.changesMade();
    await tester.pumpAndSettle();

    expect(find.text('Replacement HF'), findsOneWidget);
    expect(find.text('Old HF'), findsNothing);
    expect(oldCommunicator.commandEvents, isEmpty);
    expect(newCommunicator.activations, [0]);

    newCommunicator.commandEvents.clear();
    await tester.tap(find.byKey(const Key('slot-settings-enable-hf')));
    await tester.pumpAndSettle();
    expect(newCommunicator.commandEvents, contains('enable:0:hf:true'));
    expect(newStatus.snapshot.slots.slots.first.hf.enabled.value, isTrue);
    expect(oldCommunicator.commandEvents, isEmpty);
    expect(find.text('Replacement HF'), findsOneWidget);
  });

  testWidgets('Slot Edit keeps ordinary read failures local to the dialog',
      (tester) async {
    final communicator = _SlotCommunicator()..failActivation = true;
    final appState = _connectedState(communicator);
    final serial = appState.connector! as _TestSerial;

    await _pumpPage(
      tester,
      appState,
      const SlotEditMenu(
        name: 'Garage',
        isEnabled: true,
        slotType: TagType.em410X,
        frequency: TagFrequency.lf,
        slot: 0,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(serial.disconnects, 0);
    expect(serial.connected, isTrue);
  });

  testWidgets(
      'stale Slot Edit failure never disconnects a replacement connector',
      (tester) async {
    final activationGate = Completer<void>();
    final oldCommunicator = _SlotCommunicator()
      ..activationGate = activationGate;
    final appState = _connectedState(oldCommunicator);

    await _pumpPage(
      tester,
      appState,
      const SlotEditMenu(
        name: 'Garage',
        isEnabled: true,
        slotType: TagType.em410X,
        frequency: TagFrequency.lf,
        slot: 0,
      ),
    );
    await tester.pump();
    expect(oldCommunicator.commandEvents, contains('activate:0'));

    final replacementSerial = _TestSerial(log: Logger())
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb
      ..portName = 'replacement-port'
      ..activeDevicePort = 'replacement';
    appState
      ..connector = replacementSerial
      ..communicator = _SlotCommunicator();
    activationGate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(replacementSerial.disconnects, 0);
    expect(replacementSerial.connected, isTrue);
  });

  testWidgets('Slot Edit save reconciles renamed slot through shared status',
      (tester) async {
    final communicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0 ? SlotTypes(lf: TagType.em410X) : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) => index == 0 ? SlotNames(lf: 'Garage') : SlotNames(),
      );
    final appState = _connectedState(communicator);
    final status = appState.connectedDeviceStatus!;
    await status.refreshSlots();
    await _pumpPage(
      tester,
      appState,
      const SlotEditMenu(
        name: 'Garage',
        isEnabled: true,
        slotType: TagType.em410X,
        frequency: TagFrequency.lf,
        slot: 0,
      ),
    );
    await tester.pumpAndSettle();
    communicator.commandEvents.clear();
    final initialTypeReads = communicator.slotTypeReads;

    await tester.enterText(find.byType(TextFormField).first, 'Renamed');
    await tester.tap(find.byKey(const Key('slot-edit-save')));
    await tester.pumpAndSettle();

    expect(
      communicator.commandEvents,
      containsAllInOrder([
        'activate:0',
        'em410x',
        'name:0:lf:Renamed',
        'save-slots',
      ]),
    );
    expect(communicator.slotTypeReads, initialTypeReads + 1);
    expect(status.snapshot.slots.slots.first.lf.name.value, 'Renamed');
  });

  testWidgets(
      'open Slot Edit blocks stale save and quick settings after replacement',
      (tester) async {
    setTestViewport(tester, size: const Size(800, 1200));
    final oldCommunicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) =>
            index == 0 ? SlotNames(hf: 'Old HF', lf: 'Old LF') : SlotNames(),
      );
    final appState = _connectedState(oldCommunicator);
    final oldStatus = appState.connectedDeviceStatus!;
    final oldSerial = appState.connector! as _TestSerial;
    var oldPublications = 0;
    oldStatus.addListener(() => oldPublications++);

    await _pumpPage(tester, appState, const SlotSettings(slot: 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slot-settings-edit-hf')));
    await tester.pumpAndSettle();
    expect(find.byType(SlotEditMenu), findsOneWidget);
    for (final key in _classicQuickSettingKeys) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    await tester.enterText(find.byType(TextFormField).first, 'Stale edit');

    oldCommunicator.commandEvents.clear();
    oldPublications = 0;
    final newCommunicator = _SlotCommunicator()
      ..slotTypes = List.generate(
        8,
        (index) => index == 0
            ? SlotTypes(hf: TagType.mifare1K, lf: TagType.em410X)
            : SlotTypes(),
      )
      ..enabledSlots = List.generate(
        8,
        (index) => EnabledSlotInfo(hf: index == 0, lf: index == 0),
      )
      ..slotNames = List.generate(
        8,
        (index) =>
            index == 0 ? SlotNames(hf: 'New HF', lf: 'New LF') : SlotNames(),
      );
    _replaceConnection(appState, newCommunicator);
    final replacementSerial = appState.connector! as _TestSerial;
    appState.changesMade();
    await tester.pumpAndSettle();

    expect(
      find.text(const SlotMutationConnectionChanged().toString()),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(
            const Key('slot-edit-save'),
            skipOffstage: false,
          ))
          .onPressed,
      isNull,
    );
    newCommunicator.commandEvents.clear();
    await tester.tap(
      find.byKey(
        const Key('slot-edit-save'),
        skipOffstage: false,
      ),
      warnIfMissed: false,
    );
    for (final key in _classicQuickSettingKeys) {
      final setting = find.byKey(Key(key), skipOffstage: false);
      await tester.tap(setting, warnIfMissed: false);
      await tester.pump();
    }

    expect(oldCommunicator.commandEvents, isEmpty);
    expect(newCommunicator.commandEvents, isEmpty);
    expect(oldPublications, 0);
    expect(oldSerial.disconnects, 0);
    expect(replacementSerial.disconnects, 0);

    await tester.tap(
      find.byKey(const Key('slot-edit-connection-changed-close')),
    );
    await tester.pumpAndSettle();
    newCommunicator.commandEvents.clear();
    await tester.tap(find.byKey(const Key('slot-settings-edit-hf')));
    await tester.pumpAndSettle();

    expect(find.byType(SlotEditMenu), findsOneWidget);
    expect(
      find.text(const SlotMutationConnectionChanged().toString()),
      findsNothing,
    );
    final newSetting = find.byKey(const Key('slot-edit-setting-gen1a'));
    await tester.ensureVisible(newSetting);
    final settingRect = tester.getRect(newSetting);
    await tester.tapAt(
      Offset(
          settingRect.left + settingRect.width * 0.75, settingRect.center.dy),
    );
    await tester.pumpAndSettle();

    expect(newCommunicator.commandEvents, contains('setting-gen1a:false'));
    expect(oldCommunicator.commandEvents, isEmpty);
  });
}

const _classicQuickSettingKeys = [
  'slot-edit-setting-gen1a',
  'slot-edit-setting-gen2',
  'slot-edit-setting-prng',
  'slot-edit-setting-anticollision',
  'slot-edit-setting-detection',
  'slot-edit-setting-write-mode',
];

Future<void> _pumpPage(
        WidgetTester tester, ChameleonGUIState appState, Widget page,
        {ThemeData? theme}) =>
    tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          theme: theme,
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
  return ChameleonGUIState(
    SharedPreferencesProvider(),
    firmwareCatalog: const CurrentFirmwareCatalogStub(),
  )
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
  int modeReads = 0;
  int batteryReads = 0;
  String name = 'Office';
  bool failTypes = false;
  bool failEnabled = false;
  bool failNames = false;
  bool failActive = false;
  Completer<void>? nextTypesGate;
  Completer<void>? nextActiveGate;
  Completer<void>? activationGate;
  bool failActivation = false;
  bool applyActivationBeforeFailure = false;
  int? activationRejectionStatus;
  bool failModeRead = false;
  bool readerMode = false;
  Completer<void>? modeWriteGate;
  Completer<void>? modeWriteStarted;
  int activeSlot = 0;
  final List<int> activations = [];
  final List<Object> scriptedActiveSlotReads = [];
  final List<String> commandEvents = [];
  CardData? lastMf1AntiCollision;
  int mf1BlockBytesWritten = 0;
  List<SlotTypes>? slotTypes;
  List<EnabledSlotInfo>? enabledSlots;
  List<SlotNames>? slotNames;

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
    return slotTypes ??
        List.generate(
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
    return enabledSlots ??
        List.generate(8, (index) => EnabledSlotInfo(hf: index == 0));
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    slotNameReads++;
    if (failNames) {
      throw StateError('slot names unavailable');
    }
    return slotNames ??
        List.generate(
          8,
          (index) => SlotNames(hf: index == 0 ? name : ''),
        );
  }

  @override
  Future<int> getActiveSlot() async {
    activeSlotReads++;
    commandEvents.add('read-active');
    final gate = nextActiveGate;
    nextActiveGate = null;
    await gate?.future;
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
    commandEvents.add('activate:$slot');
    activations.add(slot);
    await activationGate?.future;
    if (applyActivationBeforeFailure) {
      activeSlot = slot;
    }
    final rejectionStatus = activationRejectionStatus;
    if (rejectionStatus != null) {
      throw SlotActivationRejected(rejectionStatus);
    }
    if (failActivation) {
      throw StateError('slot activation unavailable');
    }
    activeSlot = slot;
  }

  @override
  Future<void> setSlotTagName(
    int slot,
    String name,
    TagFrequency frequency,
  ) async {
    commandEvents.add('name:$slot:${frequency.name}:$name');
    slotNames ??= List.generate(
      8,
      (index) => SlotNames(hf: index == 0 ? this.name : ''),
    );
    if (frequency == TagFrequency.hf) {
      slotNames![slot].hf = name;
    } else {
      slotNames![slot].lf = name;
    }
  }

  @override
  Future<void> enableSlot(
    int slot,
    TagFrequency frequency,
    bool enabled,
  ) async {
    commandEvents.add('enable:$slot:${frequency.name}:$enabled');
    enabledSlots ??= List.generate(8, (_) => EnabledSlotInfo());
    if (frequency == TagFrequency.hf) {
      enabledSlots![slot].hf = enabled;
    } else {
      enabledSlots![slot].lf = enabled;
    }
  }

  @override
  Future<void> setSlotType(int slot, TagType type) async {
    commandEvents.add('type:$slot:${type.name}');
    slotTypes ??= List.generate(8, (_) => SlotTypes());
    if (chameleonTagToFrequency(type) == TagFrequency.hf) {
      slotTypes![slot].hf = type;
    } else {
      slotTypes![slot].lf = type;
    }
  }

  @override
  Future<void> setDefaultDataToSlot(int slot, TagType type) async {
    commandEvents.add('default:$slot:${type.name}');
  }

  @override
  Future<void> setMf1AntiCollision(CardData card) async {
    lastMf1AntiCollision = card;
    commandEvents.add('mf1-anti-collision');
  }

  @override
  Future<void> setMf1BlockData(int startBlock, Uint8List blocks) async {
    mf1BlockBytesWritten += blocks.length;
    commandEvents.add('mf1-blocks:$startBlock:${blocks.length}');
  }

  @override
  Future<void> setEM410XEmulatorID(Uint8List uid) async {
    commandEvents.add('em410x');
  }

  @override
  Future<Uint8List> getEM410XEmulatorID() async =>
      Uint8List.fromList([1, 2, 3, 4, 5]);

  @override
  Future<CardData> mf1GetAntiCollData() async => CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      );

  @override
  Future<EmulatorSettings> getMf1EmulatorSettings() async => EmulatorSettings(
        isDetectionEnabled: false,
        isGen1a: true,
        isGen2: true,
        isAntiColl: true,
        writeMode: MifareWriteMode.normal,
      );

  @override
  Future<Mf1PrngType> getMf1PrngType() async => Mf1PrngType.weak;

  @override
  Future<void> setMf1Gen1aMode(bool enabled) async {
    commandEvents.add('setting-gen1a:$enabled');
  }

  @override
  Future<void> setMf1Gen2Mode(bool enabled) async {
    commandEvents.add('setting-gen2:$enabled');
  }

  @override
  Future<void> setMf1PrngType(Mf1PrngType type) async {
    commandEvents.add('setting-prng:${type.name}');
  }

  @override
  Future<void> setMf1UseFirstBlockColl(bool enabled) async {
    commandEvents.add('setting-anticollision:$enabled');
  }

  @override
  Future<void> setMf1DetectionStatus(bool enabled) async {
    commandEvents.add('setting-detection:$enabled');
  }

  @override
  Future<void> setMf1WriteMode(MifareWriteMode mode) async {
    commandEvents.add('setting-write-mode:${mode.name}');
  }

  @override
  Future<void> deleteSlotInfo(int slot, TagFrequency frequency) async {
    commandEvents.add('delete:$slot:${frequency.name}');
    slotTypes ??= List.generate(8, (_) => SlotTypes());
    if (frequency == TagFrequency.hf) {
      slotTypes![slot].hf = TagType.unknown;
    } else {
      slotTypes![slot].lf = TagType.unknown;
    }
  }

  @override
  Future<void> saveSlotData() async {
    commandEvents.add('save-slots');
  }

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {
    commandEvents.add('mode:$readerMode');
    modeWriteStarted?.complete();
    await modeWriteGate?.future;
    this.readerMode = readerMode;
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async {
    batteryReads++;
    return BatteryCharge(percent: 61, voltage: 3910);
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x0100);

  @override
  Future<String> getGitCommitHash() async => 'abcdef0';

  @override
  Future<bool> isReaderDeviceMode() async {
    modeReads++;
    if (failModeRead) {
      throw StateError('mode unavailable');
    }
    return readerMode;
  }

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
