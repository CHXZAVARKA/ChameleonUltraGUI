import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/chameleon_settings.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Home uses the approved bottom-anchored dashboard hierarchy',
      (tester) async {
    await _setViewport(tester, const Size(360, 800));
    final fixture = await _mountDashboard(tester);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Used Slots:'), findsNothing);
    expect(find.text('Slots'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.settings),
      ),
      findsNothing,
    );

    final firmware = find.byKey(const Key('home-firmware-pill'));
    final slots = find.byKey(const Key('home-slot-grid'));
    final controls = find.byKey(const Key('home-controls'));
    final layout = find.byKey(const Key('home-slot-layout-control'));
    final mode = find.byKey(const Key('home-mode-control'));
    final settings = find.byKey(const Key('home-device-settings'));
    expect(firmware, findsOneWidget);
    expect(slots, findsOneWidget);
    expect(controls, findsOneWidget);
    expect(settings, findsOneWidget);
    expect(tester.getCenter(firmware).dy, lessThan(tester.getCenter(slots).dy));
    expect(tester.getCenter(slots).dy, greaterThan(400));
    expect(tester.getCenter(slots).dy, lessThan(tester.getCenter(controls).dy));
    expect(tester.getCenter(layout).dx, lessThan(tester.getCenter(mode).dx));
    expect(tester.getCenter(mode).dx, lessThan(tester.getCenter(settings).dx));
    expect(
      (tester.getCenter(layout).dy - tester.getCenter(mode).dy).abs(),
      lessThan(1),
    );
    expect(
      (tester.getCenter(mode).dy - tester.getCenter(settings).dy).abs(),
      lessThan(1),
    );
    expect(tester.getSize(layout).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(mode).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);

    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.byType(ChameleonSettings), findsOneWidget);
    fixture.dispose();
  });

  testWidgets('short Home has one vertical scroll surface with every action',
      (tester) async {
    await _setViewport(tester, const Size(360, 320));
    final fixture = await _mountDashboard(tester);
    await tester.pumpAndSettle();

    final surface = find.byKey(const Key('home-dashboard-scroll'));
    expect(surface, findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.vertical,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    final settings = find.byKey(const Key('home-device-settings'));
    await tester.ensureVisible(settings);
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(settings).dy, lessThanOrEqualTo(320));
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.byType(ChameleonSettings), findsOneWidget);
    fixture.dispose();
  });

  testWidgets('legacy warning and dashboard fit a narrow viewport',
      (tester) async {
    await _setViewport(tester, const Size(360, 800));
    final fixture = await _mountDashboard(
      tester,
      scenario: _DashboardScenario.legacy,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('firmware-compatibility-warning')),
        findsOneWidget);
    expect(_takeExceptions(tester), isEmpty);
    await tester.tap(find.byKey(const Key('firmware-warning-skip')));
    await tester.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
    expect(_takeExceptions(tester), isEmpty);
    fixture.dispose();
  });

  testWidgets('firmware action honors large system text on narrow Home',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      for (final brightness in Brightness.values) {
        for (final layout in SlotLayout.values) {
          await _setViewport(tester, const Size(360, 800));
          final fixture = await _mountDashboard(
            tester,
            brightness: brightness,
            layout: layout,
            scenario: _DashboardScenario.updateAvailable,
            textScaler: TextScaler.linear(2.5),
          );
          await tester.pumpAndSettle();

          final reason = '${brightness.name} ${layout.name}';
          final label = find.byKey(const Key('firmware-label'));
          final visibleLabelHeight =
              tester.getBottomRight(label).dy - tester.getTopLeft(label).dy;
          expect(visibleLabelHeight, greaterThan(30), reason: reason);
          expect(
            tester.getSize(find.byKey(const Key('home-firmware-pill'))).height,
            greaterThanOrEqualTo(48),
            reason: reason,
          );
          expect(
            find.bySemanticsLabel(
              'Firmware · Update available · Firmware details',
            ),
            findsOneWidget,
            reason: reason,
          );
          expect(_takeExceptions(tester), isEmpty, reason: reason);

          fixture.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('all 96 Home state, width, theme, and layout combinations fit',
      (tester) async {
    const sizes = [Size(360, 800), Size(700, 800), Size(1200, 800)];
    for (final size in sizes) {
      for (final brightness in Brightness.values) {
        for (final layout in SlotLayout.values) {
          for (final scenario in _DashboardScenario.values) {
            await _setViewport(tester, size);
            final fixture = await _mountDashboard(
              tester,
              brightness: brightness,
              layout: layout,
              scenario: scenario,
            );
            await _prepareScenario(tester, fixture, scenario);

            final reason = '${size.width} ${brightness.name} '
                '${layout.name} ${scenario.name}';
            _expectDashboardHierarchy(tester, size, layout, reason);
            _expectScenario(tester, scenario, reason);
            expect(_takeExceptions(tester), isEmpty, reason: reason);

            fixture.dispose();
            await tester.pumpWidget(const SizedBox.shrink());
            await _pumpFrames(tester, 2);
          }
        }
      }
    }
  });

  testWidgets('Demo command seam exposes eight representative ordered slots',
      (tester) async {
    await _setViewport(tester, const Size(360, 800));
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final serial = EmulatorSerial(log: Logger());
    await serial.connectSpecificDevice('Demo');
    final communicator = ChameleonCommunicator(Logger(), port: serial);
    final appState = ChameleonGUIState(
      preferences,
      firmwareCatalog: const _DashboardFirmwareCatalog(),
    )
      ..connector = serial
      ..communicator = communicator
      ..log = Logger();

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(
        find.byKey(const Key('home-slot-1-hf-mark-enabled')), findsOneWidget);
    expect(find.byKey(const Key('home-slot-1-lf-mark-empty')), findsOneWidget);
    expect(find.byKey(const Key('home-slot-2-hf-mark-empty')), findsOneWidget);
    expect(
        find.byKey(const Key('home-slot-2-lf-mark-enabled')), findsOneWidget);
    expect(
        find.byKey(const Key('home-slot-3-hf-mark-enabled')), findsOneWidget);
    expect(
        find.byKey(const Key('home-slot-3-lf-mark-disabled')), findsOneWidget);
    expect(find.byKey(const Key('home-slot-5-hf-mark-empty')), findsOneWidget);
    expect(
      find.byKey(const Key('home-slot-7-hf-mark-enabledUnknown')),
      findsOneWidget,
    );
    final unknownEnabled =
        appState.connectedDeviceStatus!.snapshot.slots.slots[6].hf;
    expect(unknownEnabled.type.value, isNot(TagType.unknown));
    expect(unknownEnabled.enabled.isConfirmed, isFalse);
    final unknownSemantics =
        tester.getSemantics(find.byKey(const Key('home-slot-7'))).label;
    expect(unknownSemantics.toLowerCase(), contains('enabled status unknown'));
    expect(unknownSemantics.toLowerCase(), contains('dashed outline'));
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-1'))).label,
      contains('Office'),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('home-slot-2'))).label,
      contains('Garage'),
    );
    for (var slot = 1; slot <= 8; slot++) {
      expect(find.byKey(Key('home-slot-$slot')), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    appState.dispose();
  });
}

Future<void> _prepareScenario(
  WidgetTester tester,
  _DashboardFixture fixture,
  _DashboardScenario scenario,
) async {
  if (scenario == _DashboardScenario.loading) {
    await tester.pump();
    return;
  }
  await _pumpFrames(tester, 8);
  if (scenario == _DashboardScenario.legacy) {
    await tester.tap(find.byKey(const Key('firmware-warning-skip')));
    await _pumpFrames(tester, 4);
  }
  if (scenario == _DashboardScenario.stale) {
    fixture.communicator.failSlots = true;
    await fixture.appState.connectedDeviceStatus!.refreshSlots();
    await _pumpFrames(tester, 2);
  }
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void _expectDashboardHierarchy(
  WidgetTester tester,
  Size size,
  SlotLayout slotLayout,
  String reason,
) {
  expect(find.byType(Image), findsNothing, reason: reason);
  expect(find.textContaining('Used Slots:'), findsNothing, reason: reason);
  expect(find.text('Slots'), findsNothing, reason: reason);
  expect(
    find.descendant(
      of: find.byType(AppBar),
      matching: find.byIcon(Icons.settings),
    ),
    findsNothing,
    reason: reason,
  );

  final firmware = find.byKey(const Key('home-firmware-pill'));
  final slots = find.byKey(const Key('home-slot-grid'));
  final controls = find.byKey(const Key('home-controls'));
  final layout = find.byKey(const Key('home-slot-layout-control'));
  final mode = find.byKey(const Key('home-mode-control'));
  final modeAction = find.descendant(
    of: mode,
    matching: find.byWidgetPredicate(
      (widget) => widget is SegmentedButton<ConnectedDeviceMode>,
    ),
  );
  final settings = find.byKey(const Key('home-device-settings'));
  final bottomDashboard = find.byKey(const Key('home-bottom-dashboard'));
  expect(find.byKey(const Key('home-dashboard-scroll')), findsOneWidget,
      reason: reason);
  expect(firmware, findsOneWidget, reason: reason);
  expect(slots, findsOneWidget, reason: reason);
  expect(controls, findsOneWidget, reason: reason);
  expect(layout, findsOneWidget, reason: reason);
  expect(mode, findsOneWidget, reason: reason);
  expect(settings, findsOneWidget, reason: reason);
  expect(
    find.byKey(
      Key(
        slotLayout == SlotLayout.eightAcross
            ? 'home-slot-grid-eight-across'
            : 'home-slot-grid-two-by-four',
      ),
    ),
    findsOneWidget,
    reason: reason,
  );

  expect(
    tester.getBottomLeft(firmware).dy,
    lessThan(tester.getTopLeft(slots).dy),
    reason: reason,
  );
  expect(
    tester.getBottomLeft(slots).dy,
    lessThan(tester.getTopLeft(controls).dy),
    reason: reason,
  );
  expect(tester.getCenter(layout).dx, lessThan(tester.getCenter(mode).dx),
      reason: reason);
  expect(tester.getCenter(mode).dx, lessThan(tester.getCenter(settings).dx),
      reason: reason);
  expect(
    tester.getBottomRight(bottomDashboard).dy,
    greaterThan(size.height - 24),
    reason: reason,
  );
  expect(tester.getSize(layout).height, greaterThanOrEqualTo(48),
      reason: reason);
  expect(tester.getSize(mode).height, greaterThanOrEqualTo(48), reason: reason);
  expect(tester.getSize(settings).height, greaterThanOrEqualTo(48),
      reason: reason);
  expect(firmware.hitTestable(), findsOneWidget, reason: reason);
  expect(layout.hitTestable(), findsOneWidget, reason: reason);
  expect(modeAction.hitTestable(), findsOneWidget, reason: reason);
  final modeRetry = find.byKey(const Key('home-mode-retry'));
  if (modeRetry.evaluate().isNotEmpty) {
    expect(modeRetry.hitTestable(), findsOneWidget, reason: reason);
  }
  expect(settings.hitTestable(), findsOneWidget, reason: reason);
}

List<Object> _takeExceptions(WidgetTester tester) {
  final exceptions = <Object>[];
  Object? exception;
  while ((exception = tester.takeException()) != null) {
    exceptions.add(exception!);
  }
  return exceptions;
}

void _expectScenario(
  WidgetTester tester,
  _DashboardScenario scenario,
  String reason,
) {
  switch (scenario) {
    case _DashboardScenario.normal:
      expect(find.text('Up to date'), findsOneWidget, reason: reason);
    case _DashboardScenario.loading:
      expect(find.text('Checking'), findsOneWidget, reason: reason);
    case _DashboardScenario.stale:
      expect(find.byKey(const Key('home-slot-refresh')), findsOneWidget,
          reason: reason);
    case _DashboardScenario.error:
      expect(find.text('--%'), findsOneWidget, reason: reason);
      expect(find.byKey(const Key('home-mode-retry')), findsOneWidget,
          reason: reason);
    case _DashboardScenario.lite:
      final mode = tester.widget<SegmentedButton<ConnectedDeviceMode>>(
        find.byWidgetPredicate(
          (widget) => widget is SegmentedButton<ConnectedDeviceMode>,
        ),
      );
      expect(mode.segments.last.enabled, isFalse, reason: reason);
    case _DashboardScenario.legacy:
      expect(find.text('Update required'), findsOneWidget, reason: reason);
    case _DashboardScenario.demo:
      expect(
        tester.widget<Text>(find.byKey(const Key('firmware-status-text'))).data,
        'Demo',
        reason: reason,
      );
    case _DashboardScenario.updateAvailable:
      expect(find.text('Update available'), findsOneWidget, reason: reason);
  }
}

enum _DashboardScenario {
  normal,
  loading,
  stale,
  lite,
  legacy,
  demo,
  updateAvailable,
  error,
}

class _DashboardFixture {
  const _DashboardFixture(this.appState, this.communicator);

  final ChameleonGUIState appState;
  final _DashboardCommunicator communicator;

  void dispose() {
    communicator.releasePending();
    appState.dispose();
  }
}

Future<_DashboardFixture> _mountDashboard(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  SlotLayout layout = SlotLayout.eightAcross,
  _DashboardScenario scenario = _DashboardScenario.normal,
  TextScaler? textScaler,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = SharedPreferencesProvider();
  await preferences.load();
  preferences.setSlotLayout(layout);
  final communicator = _DashboardCommunicator(scenario);
  final device = scenario == _DashboardScenario.lite
      ? ChameleonDevice.lite
      : ChameleonDevice.ultra;
  final portName = scenario == _DashboardScenario.demo ? 'Demo' : 'test-port';
  final serial = _DashboardSerial(log: Logger())
    ..connected = true
    ..device = device
    ..connectionType = ConnectionType.usb
    ..portName = portName
    ..activeDevicePort = portName;
  final appState = ChameleonGUIState(
    preferences,
    firmwareCatalog: _DashboardFirmwareCatalog(
      updateAvailable: scenario == _DashboardScenario.updateAvailable,
    ),
  )
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
  await _pumpHome(
    tester,
    appState,
    theme: ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: brightness,
      ),
    ),
    textScaler: textScaler,
  );
  return _DashboardFixture(appState, communicator);
}

Future<void> _pumpHome(
  WidgetTester tester,
  ChameleonGUIState appState, {
  ThemeData? theme,
  TextScaler? textScaler,
}) =>
    tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          theme: theme,
          builder: textScaler == null
              ? null
              : (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: textScaler,
                    ),
                    child: child!,
                  ),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomePage(),
        ),
      ),
    );

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _DashboardFirmwareCatalog implements FirmwareCatalog {
  const _DashboardFirmwareCatalog({this.updateAvailable = false});

  final bool updateAvailable;

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
  }) async =>
      FirmwareCatalogRelease(
        latestCommit: updateAvailable ? 'new5678' : installedCommit ?? 'none',
        updateAvailable: updateAvailable,
      );
}

class _DashboardCommunicator extends ChameleonCommunicator {
  _DashboardCommunicator(this.scenario) : super(Logger());

  final _DashboardScenario scenario;
  final Completer<void> _pending = Completer<void>();
  bool failSlots = false;

  Future<void> _waitIfLoading() async {
    if (scenario == _DashboardScenario.loading) {
      await _pending.future;
    }
  }

  void releasePending() {
    if (!_pending.isCompleted) {
      _pending.complete();
    }
  }

  void _throwIfError([bool slotRead = false]) {
    if (scenario == _DashboardScenario.error || (slotRead && failSlots)) {
      throw StateError('dashboard status unavailable');
    }
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async {
    await _waitIfLoading();
    _throwIfError();
    return BatteryCharge(percent: 72, voltage: 3910);
  }

  @override
  Future<bool> isReaderDeviceMode() async {
    await _waitIfLoading();
    _throwIfError();
    return false;
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    await _waitIfLoading();
    _throwIfError(true);
    return List.generate(
      8,
      (index) => SlotTypes(
        hf: index.isEven ? TagType.mifare1K : TagType.unknown,
        lf: index == 2 ? TagType.em410X : TagType.unknown,
      ),
    );
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    _throwIfError(true);
    return List.generate(
      8,
      (index) => EnabledSlotInfo(hf: index.isEven, lf: index == 2),
    );
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    _throwIfError(true);
    return List.generate(
      8,
      (index) => SlotNames(hf: index.isEven ? 'Slot ${index + 1}' : ''),
    );
  }

  @override
  Future<int> getActiveSlot() async {
    await _waitIfLoading();
    _throwIfError(true);
    return 0;
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() async {
    await _waitIfLoading();
    _throwIfError();
    return FirmwareVersion(
      legacyProtocol: scenario == _DashboardScenario.legacy,
      version: 0x0100,
    );
  }

  @override
  Future<String> getGitCommitHash() async {
    _throwIfError();
    return 'current1';
  }

  @override
  Future<List<int>> getDeviceCapabilities() async {
    _throwIfError();
    return scenario == _DashboardScenario.legacy
        ? const []
        : [ChameleonCommand.setIdteckEmulatorID.value];
  }

  @override
  Future<DeviceSettings> getDeviceSettings() async => DeviceSettings();
}

class _DashboardSerial extends AbstractSerial {
  _DashboardSerial({required super.log});

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
