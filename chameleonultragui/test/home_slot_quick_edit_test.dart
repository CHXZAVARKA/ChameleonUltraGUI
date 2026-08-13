import 'dart:async';
import 'dart:ui' show PointerDeviceKind, SemanticsAction;

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/home_slot_grid.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/gestures.dart'
    show kLongPressTimeout, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/connected_device_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'inactive tap activates immediately and repeat active tap opens Slot Settings',
    (tester) async {
      final fixture = _fixture();
      addTearDown(fixture.appState.dispose);
      await fixture.appState.sharedPreferencesProvider.load();
      await fixture.status.refreshSlots();
      await _pumpGrid(tester, fixture);

      final gate = Completer<void>();
      fixture.communicator.activationGate = gate;
      await tester.tap(find.byKey(const Key('home-slot-2')));
      await tester.pump();

      expect(fixture.communicator.activations, [1]);
      expect(find.byType(SlotSettings), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      fixture.communicator.activationGate = null;
      fixture.communicator.activations.clear();

      await tester.tap(find.byKey(const Key('home-slot-2')));
      await tester.pump();

      expect(find.byType(SlotSettings), findsOneWidget);
    },
  );

  testWidgets(
    'E and F2 edit the focused slot without changing arrow contracts',
    (tester) async {
      final fixture = _fixture();
      addTearDown(fixture.appState.dispose);
      await fixture.appState.sharedPreferencesProvider.load();
      await fixture.status.refreshSlots();
      await _pumpGrid(tester, fixture);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pump();
      expect(tester.widget<SlotSettings>(find.byType(SlotSettings)).slot, 0);

      Navigator.of(tester.element(find.byType(SlotSettings))).pop();
      await tester.pumpAndSettle();
      fixture.communicator.activations.clear();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(fixture.communicator.activations, [1]);

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(tester.widget<SlotSettings>(find.byType(SlotSettings)).slot, 1);
    },
  );

  testWidgets('screen reader exposes one explicit Edit slot action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fixture = _fixture();
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    await _pumpGrid(tester, fixture);

    final node = tester.getSemantics(find.byKey(const Key('home-slot-3')));
    final data = node.getSemanticsData();
    final editAction = data.customSemanticsActionIds!.singleWhere(
      (id) => CustomSemanticsAction.getAction(id)!.label == 'Edit slot',
    );
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      editAction,
    );
    await tester.pump();

    expect(tester.widget<SlotSettings>(find.byType(SlotSettings)).slot, 2);
    semantics.dispose();
  });

  testWidgets(
    'stale screen reader action explains why editing is unavailable',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final fixture = _fixture();
      addTearDown(fixture.appState.dispose);
      await fixture.appState.sharedPreferencesProvider.load();
      await fixture.status.refreshSlots();
      fixture.communicator.failNames = true;
      await fixture.status.refreshSlots();
      await _pumpGrid(tester, fixture);

      final node = tester.getSemantics(find.byKey(const Key('home-slot-1')));
      final editActions = node
          .getSemanticsData()
          .customSemanticsActionIds!
          .where(
            (id) => CustomSemanticsAction.getAction(id)!.label == 'Edit slot',
          )
          .toList();
      expect(editActions, hasLength(1));

      node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        editActions.single,
      );
      await tester.pump();

      expect(find.byType(SlotSettings), findsNothing);
      expect(
        find.text('Slot details are unavailable. Refresh the slot status.'),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets('secondary click exposes Edit, Move, Clear, and Export', (
    tester,
  ) async {
    final fixture = _fixture();
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    await _pumpGrid(tester, fixture);

    await tester.tap(
      find.byKey(const Key('home-slot-3')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('Edit slot'), findsOneWidget);
    expect(find.text('Move slot'), findsOneWidget);
    expect(find.text('Clear slot'), findsOneWidget);
    expect(find.text('Export Slot Data'), findsOneWidget);
  });

  testWidgets('context actions reuse settings, export, and atomic move flows', (
    tester,
  ) async {
    final fixture = _fixture(supportsSwap: true);
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    await fixture.status.refreshSlotReorderCapability();
    await _pumpGrid(tester, fixture);

    await _openContextMenu(tester, 2);
    await tester.tap(find.text('Edit slot'));
    await tester.pump();
    expect(tester.widget<SlotSettings>(find.byType(SlotSettings)).slot, 2);
    Navigator.of(tester.element(find.byType(SlotSettings))).pop();
    await tester.pumpAndSettle();

    await _openContextMenu(tester, 2);
    await tester.tap(find.text('Clear slot'));
    await tester.pump();
    expect(tester.widget<SlotSettings>(find.byType(SlotSettings)).slot, 2);
    Navigator.of(tester.element(find.byType(SlotSettings))).pop();
    await tester.pumpAndSettle();

    await _openContextMenu(tester, 2);
    await tester.tap(find.text('Export Slot Data'));
    await tester.pump();
    expect(tester.widget<SlotExportMenu>(find.byType(SlotExportMenu)).slot, 2);
    Navigator.of(tester.element(find.byType(SlotExportMenu))).pop();
    await tester.pumpAndSettle();

    await _openContextMenu(tester, 2);
    await tester.tap(find.text('Move slot'));
    await tester.pumpAndSettle();
    expect(find.text('Swap with slot 4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-slot-move-target-4')));
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, [(2, 3)]);
  });

  testWidgets('stale slot facts block quick edit with an explanation', (
    tester,
  ) async {
    final fixture = _fixture();
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    fixture.communicator.failNames = true;
    await fixture.status.refreshSlots();
    await _pumpGrid(tester, fixture);

    await tester.tap(find.byKey(const Key('home-slot-1')));
    await tester.pump();

    expect(find.byType(SlotSettings), findsNothing);
    expect(
      find.text('Slot details are unavailable. Refresh the slot status.'),
      findsOneWidget,
    );
  });

  testWidgets('pending activation blocks keyboard edit with an explanation', (
    tester,
  ) async {
    final fixture = _fixture();
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    await _pumpGrid(tester, fixture);

    final gate = Completer<void>();
    fixture.communicator.activationGate = gate;
    await tester.tap(find.byKey(const Key('home-slot-2')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();

    expect(fixture.communicator.activations, [1]);
    expect(find.byType(SlotSettings), findsNothing);
    expect(
      find.text('Slot details are unavailable. Refresh the slot status.'),
      findsOneWidget,
    );
    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('stale active-slot fact cannot open the old active editor', (
    tester,
  ) async {
    final fixture = _fixture();
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    fixture.communicator.failActiveSlot = true;
    await fixture.status.refreshSlots();
    await _pumpGrid(tester, fixture);

    await tester.tap(find.byKey(const Key('home-slot-1')));
    await tester.pump();

    expect(find.byType(SlotSettings), findsNothing);
    expect(
      find.text('Slot details are unavailable. Refresh the slot status.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'replacement session disables Home slot dialog without commands',
    (tester) async {
      final fixture = _fixture();
      addTearDown(fixture.appState.dispose);
      await fixture.appState.sharedPreferencesProvider.load();
      await fixture.status.refreshSlots();
      await _pumpGrid(tester, fixture);

      await tester.tap(find.byKey(const Key('home-slot-1')));
      await tester.pumpAndSettle();
      expect(find.byType(SlotSettings), findsOneWidget);

      final replacement = fixture.replaceConnection();
      fixture.appState.changesMade();
      await tester.pump();
      expect(
        tester.widget<HomeSlotGrid>(find.byType(HomeSlotGrid)).status,
        same(fixture.status),
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(SlotSettings), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.byKey(const Key('slot-settings-edit-hf')), findsNothing);
      expect(replacement.activations, isEmpty);
    },
  );

  testWidgets('nested export stays pinned to the quick-opened device session', (
    tester,
  ) async {
    final fixture = _fixture();
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    await _pumpGrid(tester, fixture);

    await tester.tap(find.byKey(const Key('home-slot-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slot-settings-export')));
    await tester.pumpAndSettle();
    expect(find.byType(SlotExportMenu), findsOneWidget);

    final replacement = fixture.replaceConnection();
    fixture.appState.changesMade();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(SlotExportMenu),
        matching: find.text('Unavailable'),
      ),
      findsOneWidget,
    );
    expect(find.text('Save to file'), findsNothing);
    expect(replacement.activations, isEmpty);
  });

  testWidgets(
    'nested editor disables immediately when its session disconnects',
    (tester) async {
      final fixture = _fixture();
      addTearDown(fixture.appState.dispose);
      await fixture.appState.sharedPreferencesProvider.load();
      fixture.communicator.slotTypes[0] =
          SlotTypes(hf: TagType.unknown, lf: TagType.em410X);
      await fixture.status.refreshSlots();
      await _pumpGrid(tester, fixture);

      await tester.tap(find.byKey(const Key('home-slot-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('slot-settings-edit-hf')));
      await tester.pump();
      expect(find.byKey(const Key('slot-edit-save')), findsOneWidget);

      fixture.appState.connector!.connected = false;
      fixture.appState.changesMade();
      await tester.pump();

      expect(
        find.byKey(const Key('slot-edit-connection-changed-close')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('slot-edit-save')), findsNothing);
    },
  );

  testWidgets('touch long press remains drag-only and never quick-edits', (
    tester,
  ) async {
    final fixture = _fixture(supportsSwap: true);
    addTearDown(fixture.appState.dispose);
    await fixture.appState.sharedPreferencesProvider.load();
    await fixture.status.refreshSlots();
    await fixture.status.refreshSlotReorderCapability();
    await _pumpGrid(tester, fixture);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('home-slot-1'))),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('home-slot-2'))),
    );
    await tester.pump();

    expect(find.byType(SlotSettings), findsNothing);
    expect(fixture.communicator.activations, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(fixture.communicator.swaps, [(0, 1)]);
    expect(fixture.communicator.activations, isEmpty);
  });

  testWidgets(
    'real Home quick edit covers layouts, RTL, target sizes, text, and motion',
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      const cases = [
        _HomeCase(
          size: Size(360, 900),
          layout: SlotLayout.eightAcross,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.linear(1.8),
        ),
        _HomeCase(
          size: Size(700, 900),
          layout: SlotLayout.twoByFour,
          textDirection: TextDirection.rtl,
          disableAnimations: true,
        ),
        _HomeCase(
          size: Size(1200, 900),
          layout: SlotLayout.eightAcross,
          textDirection: TextDirection.ltr,
        ),
      ];

      for (final testCase in cases) {
        SharedPreferences.setMockInitialValues({});
        final fixture = _fixture();
        await fixture.appState.sharedPreferencesProvider.load();
        fixture.appState.sharedPreferencesProvider.setSlotLayout(
          testCase.layout,
        );
        await fixture.status.refreshSlots();
        await fixture.status.refreshSlotReorderCapability();
        tester.view.physicalSize = testCase.size;
        tester.view.devicePixelRatio = 1;
        await _pumpHome(tester, fixture, testCase);
        await tester.pump();

        expect(find.byType(HomePage), findsOneWidget);
        expect(
          tester.widget<HomeSlotGrid>(find.byType(HomeSlotGrid)).layout,
          testCase.layout,
        );
        expect(
          Directionality.of(
            tester.element(find.byKey(const Key('home-slot-1'))),
          ),
          testCase.textDirection,
        );
        for (var slot = 1; slot <= 8; slot++) {
          final size = tester.getSize(find.byKey(Key('home-slot-$slot')));
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        if (testCase.disableAnimations) {
          expect(
            tester
                .widget<AnimatedContainer>(
                  find.byKey(const Key('home-active-slot-1')),
                )
                .duration,
            Duration.zero,
          );
        }
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('home-slot-1')));
        await tester.pump();
        expect(find.byType(SlotSettings), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        fixture.appState.dispose();
      }
    },
  );
}

Future<void> _openContextMenu(WidgetTester tester, int zeroBasedSlot) async {
  await tester.tap(
    find.byKey(Key('home-slot-${zeroBasedSlot + 1}')),
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpGrid(WidgetTester tester, _Fixture fixture) =>
    tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: fixture.appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer<ChameleonGUIState>(
              builder: (context, state, _) => Center(
                child: HomeSlotGrid(status: state.connectedDeviceStatus!),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _pumpHome(
  WidgetTester tester,
  _Fixture fixture,
  _HomeCase testCase,
) =>
    tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: fixture.appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: testCase.textScaler,
              disableAnimations: testCase.disableAnimations,
            ),
            child: Directionality(
              textDirection: testCase.textDirection,
              child: child!,
            ),
          ),
          home: const HomePage(),
        ),
      ),
    );

class _HomeCase {
  const _HomeCase({
    required this.size,
    required this.layout,
    required this.textDirection,
    this.textScaler = TextScaler.noScaling,
    this.disableAnimations = false,
  });

  final Size size;
  final SlotLayout layout;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final bool disableAnimations;
}

class _Fixture {
  _Fixture(this.harness);

  final ConnectedDeviceTestHarness<_QuickEditCommunicator> harness;

  ChameleonGUIState get appState => harness.appState;
  _QuickEditCommunicator get communicator => harness.communicator;
  ConnectedDeviceStatus get status => harness.appState.connectedDeviceStatus!;

  _QuickEditCommunicator replaceConnection() {
    final replacement = _QuickEditCommunicator();
    appState
      ..connector = TestSerial(
        log: Logger(output: MemoryOutput()),
        portName: 'replacement-device',
        activeDevicePort: 'replacement-port',
      )
      ..communicator = replacement;
    return replacement;
  }
}

_Fixture _fixture({bool supportsSwap = false}) {
  final communicator = _QuickEditCommunicator()..supportsSwap = supportsSwap;
  return _Fixture(ConnectedDeviceTestHarness(communicator: communicator));
}

class _QuickEditCommunicator extends ChameleonCommunicator {
  _QuickEditCommunicator() : super(Logger(output: MemoryOutput())) {
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
      (index) =>
          SlotNames(hf: 'Slot ${index + 1} HF', lf: 'Slot ${index + 1} LF'),
    );
  }

  int activeSlot = 0;
  bool supportsSwap = false;
  bool failNames = false;
  bool failActiveSlot = false;
  Completer<void>? activationGate;
  final List<int> activations = [];
  final List<(int, int)> swaps = [];
  late List<SlotTypes> slotTypes;
  late List<EnabledSlotInfo> enabledSlots;
  late List<SlotNames> slotNames;

  @override
  Future<void> activateSlot(int slot) async {
    activations.add(slot);
    await activationGate?.future;
    activeSlot = slot;
  }

  @override
  Future<int> getActiveSlot() async {
    if (failActiveSlot) {
      throw StateError('active slot unavailable');
    }
    return activeSlot;
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async => slotTypes;

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async => enabledSlots;

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    if (failNames) {
      throw StateError('slot names unavailable');
    }
    return slotNames;
  }

  @override
  Future<List<int>> getDeviceCapabilities() async =>
      supportsSwap ? [ChameleonCommand.swapSlots.value] : const [];

  @override
  Future<void> swapSlots(int source, int target) async {
    swaps.add((source, target));
    final sourceTypes = slotTypes[source];
    slotTypes[source] = slotTypes[target];
    slotTypes[target] = sourceTypes;
    final sourceEnabled = enabledSlots[source];
    enabledSlots[source] = enabledSlots[target];
    enabledSlots[target] = sourceEnabled;
    final sourceNames = slotNames[source];
    slotNames[source] = slotNames[target];
    slotNames[target] = sourceNames;
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async =>
      BatteryCharge(percent: 72, voltage: 3910);

  @override
  Future<bool> isReaderDeviceMode() async => false;

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x0202);

  @override
  Future<String> getGitCommitHash() async => 'current1';

  @override
  Future<DeviceSettings> getDeviceSettings() async => DeviceSettings();
}
