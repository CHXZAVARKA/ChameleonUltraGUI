import 'dart:async';
import 'dart:io';
import 'dart:math';
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
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('slot certainty stays behind the abstract connector contract', () {
    final physical = _DashboardSerial(log: Logger());
    final demo = EmulatorSerial(log: Logger());

    expect(
      physical.slotEnabledStateCertainty.isConfirmed(
        6,
        highFrequency: true,
      ),
      isTrue,
    );
    expect(
      demo.slotEnabledStateCertainty.isConfirmed(
        6,
        highFrequency: true,
      ),
      isTrue,
    );
    expect(
      demo.slotEnabledStateCertainty.isConfirmed(
        6,
        highFrequency: false,
      ),
      isTrue,
    );

    final statusSource =
        File('lib/status/connected_device_status.dart').readAsStringSync();
    expect(statusSource, isNot(contains('connector/serial_emulator.dart')));
    expect(statusSource, isNot(contains('EmulatorSerial')));
  });

  test('Demo device state is stable per session and randomized between them',
      () async {
    final firstSerial = EmulatorSerial(log: Logger(), random: Random(11));
    await firstSerial.connectSpecificDevice('Demo');
    final firstCommunicator = ChameleonCommunicator(
      Logger(),
      port: firstSerial,
    );
    final first = await _readDemoState(firstCommunicator);
    expect(await _readDemoState(firstCommunicator), first);

    final secondSerial = EmulatorSerial(log: Logger(), random: Random(29));
    await secondSerial.connectSpecificDevice('Demo');
    final secondCommunicator = ChameleonCommunicator(
      Logger(),
      port: secondSerial,
    );
    final second = await _readDemoState(secondCommunicator);

    expect(second, isNot(first));
  });

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

  testWidgets(
      'large text keeps frequency rows aligned and every Home action reachable',
      (tester) async {
    for (final brightness in Brightness.values) {
      for (final layout in SlotLayout.values) {
        await _setViewport(tester, const Size(360, 800));
        final fixture = await _mountDashboard(
          tester,
          brightness: brightness,
          layout: layout,
          textScaler: TextScaler.linear(2.5),
        );
        await tester.pumpAndSettle();

        final reason = '${brightness.name} ${layout.name}';
        final rowStarts = layout == SlotLayout.eightAcross ? [0] : [0, 4];
        for (final rowStart in rowStarts) {
          for (final frequency in ['hf', 'lf']) {
            final labelText = find.descendant(
              of: find.byKey(
                Key('home-frequency-label-$frequency-box-$rowStart'),
              ),
              matching: find.byType(Text),
            );
            final labelBox = find.byKey(
              Key('home-frequency-label-$frequency-box-$rowStart'),
            );
            final mark = find.byKey(
              Key(
                'home-slot-${rowStart + 1}-$frequency-mark-'
                '${frequency == 'hf' ? 'enabled' : 'empty'}',
              ),
            );
            expect(labelText, findsOneWidget, reason: reason);
            final paragraph = tester.renderObject<RenderParagraph>(labelText);
            final textRect = tester.getRect(labelText);
            final boxRect = tester.getRect(labelBox);
            final markRect = tester.getRect(mark);
            expect(paragraph.hasSize, isTrue, reason: reason);
            expect(textRect.left, greaterThanOrEqualTo(boxRect.left),
                reason: reason);
            expect(textRect.top, greaterThanOrEqualTo(boxRect.top),
                reason: reason);
            expect(textRect.right, lessThanOrEqualTo(boxRect.right),
                reason: reason);
            expect(textRect.bottom, lessThanOrEqualTo(boxRect.bottom),
                reason: reason);
            expect(textRect.right, lessThan(markRect.left), reason: reason);
            expect(
              (textRect.center.dy - markRect.center.dy).abs(),
              lessThanOrEqualTo(2),
              reason: reason,
            );
          }
          final hfRect = tester.getRect(
            find.byKey(Key('home-frequency-label-hf-box-$rowStart')),
          );
          final lfRect = tester.getRect(
            find.byKey(Key('home-frequency-label-lf-box-$rowStart')),
          );
          expect(hfRect.bottom, lessThanOrEqualTo(lfRect.top), reason: reason);
        }

        final controlsSurface = find.byKey(const Key('home-controls-scroll'));
        final layoutControl = find.byKey(
          const Key('home-slot-layout-control'),
        );
        expect(controlsSurface, findsOneWidget, reason: reason);
        final controlsScrollable = tester.state<ScrollableState>(
          find.descendant(
            of: controlsSurface,
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          controlsScrollable.position.maxScrollExtent,
          greaterThan(0),
          reason: reason,
        );
        expect(layoutControl.hitTestable(), findsOneWidget, reason: reason);
        expect(
          tester.getSize(layoutControl).height,
          greaterThanOrEqualTo(48),
          reason: reason,
        );
        final alternateLayout = layout == SlotLayout.eightAcross
            ? find.byKey(const Key('home-slot-layout-two-by-four'))
            : find.byKey(const Key('home-slot-layout-eight-across'));
        await tester.tap(alternateLayout);
        await tester.pumpAndSettle();
        expect(
          fixture.appState.sharedPreferencesProvider.getSlotLayout(),
          isNot(layout),
          reason: reason,
        );

        controlsScrollable.position.jumpTo(
          controlsScrollable.position.maxScrollExtent,
        );
        await tester.pumpAndSettle();
        final mode = find.byKey(const Key('home-mode-control'));
        final readerAction = find.text('Reader');
        final settings = find.byKey(const Key('home-device-settings'));
        expect(readerAction.hitTestable(), findsOneWidget, reason: reason);
        expect(settings.hitTestable(), findsOneWidget, reason: reason);
        expect(tester.getSize(mode).height, greaterThanOrEqualTo(48),
            reason: reason);
        expect(tester.getSize(settings).height, greaterThanOrEqualTo(48),
            reason: reason);
        await tester.tap(readerAction);
        await tester.pumpAndSettle();
        expect(fixture.communicator.readerMode, isTrue, reason: reason);
        await tester.tap(settings);
        await tester.pumpAndSettle();
        expect(find.byType(ChameleonSettings), findsOneWidget, reason: reason);
        expect(_takeExceptions(tester), isEmpty, reason: reason);

        fixture.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
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

  testWidgets('Demo Home exposes complete representative states without errors',
      (tester) async {
    await _setViewport(tester, const Size(360, 800));
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final serial = EmulatorSerial(log: Logger(), random: Random(7));
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

    final slots = appState.connectedDeviceStatus!.snapshot.slots.slots;
    var configuredHighFrequency = 0;
    var configuredLowFrequency = 0;
    var enabledConfigured = 0;
    var disabledConfigured = 0;
    var emptyFrequencies = 0;
    for (final slot in slots) {
      for (final frequency in [slot.hf, slot.lf]) {
        expect(frequency.type.isConfirmed, isTrue);
        expect(frequency.name.isConfirmed, isTrue);
        if (frequency.type.value != null &&
            frequency.type.value != TagType.unknown) {
          expect(frequency.enabled.isConfirmed, isTrue);
          expect(frequency.name.value, isNotEmpty);
          if (frequency.enabled.value == true) {
            enabledConfigured++;
          } else {
            disabledConfigured++;
          }
        } else {
          emptyFrequencies++;
        }
      }
      if (slot.hf.type.value != null && slot.hf.type.value != TagType.unknown) {
        configuredHighFrequency++;
      }
      if (slot.lf.type.value != null && slot.lf.type.value != TagType.unknown) {
        configuredLowFrequency++;
      }
    }
    expect(configuredHighFrequency, greaterThan(0));
    expect(configuredLowFrequency, greaterThan(0));
    expect(enabledConfigured, greaterThan(0));
    expect(disabledConfigured, greaterThan(0));
    expect(emptyFrequencies, greaterThan(0));
    expect(find.byKey(const Key('home-slot-refresh')), findsNothing);
    for (var slot = 1; slot <= 8; slot++) {
      expect(find.byKey(Key('home-slot-$slot')), findsOneWidget);
      final label =
          tester.getSemantics(find.byKey(Key('home-slot-$slot'))).label;
      expect(label.toLowerCase(), isNot(contains('unknown')));
      expect(label.toLowerCase(), isNot(contains('unavailable')));
    }

    final initialActive =
        appState.connectedDeviceStatus!.snapshot.slots.activeSlot.value!;
    final targetSlot = (initialActive + 1) % 8;
    await tester.tap(find.byKey(Key('home-slot-${targetSlot + 1}')));
    await tester.pumpAndSettle();
    expect(
      appState.connectedDeviceStatus!.snapshot.slots.activeSlot.value,
      targetSlot,
    );
    expect(find.byKey(const Key('home-slot-activation-error')), findsNothing);

    final initialMode =
        appState.connectedDeviceStatus!.snapshot.mode.confirmedMode!;
    final targetMode = initialMode == ConnectedDeviceMode.emulator
        ? ConnectedDeviceMode.reader
        : ConnectedDeviceMode.emulator;
    await tester.tap(find.text(
      targetMode == ConnectedDeviceMode.reader ? 'Reader' : 'Emulator',
    ));
    await tester.pumpAndSettle();
    expect(
      appState.connectedDeviceStatus!.snapshot.mode.confirmedMode,
      targetMode,
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    appState.dispose();
  });
}

Future<String> _readDemoState(ChameleonCommunicator communicator) async {
  final types = await communicator.getSlotTagTypes();
  final enabled = await communicator.getEnabledSlots();
  final names = await communicator.getSlotTagNames();
  final active = await communicator.getActiveSlot();
  final reader = await communicator.isReaderDeviceMode();
  final battery = await communicator.getBatteryCharge();
  return [
    types.map((slot) => '${slot.hf.name}:${slot.lf.name}').join(','),
    enabled.map((slot) => '${slot.hf}:${slot.lf}').join(','),
    names.map((slot) => '${slot.hf}:${slot.lf}').join(','),
    '$active',
    '$reader',
    '${battery.voltage}:${battery.percent}',
  ].join('|');
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
  expect(find.byKey(const Key('home-mode-retry')), findsNothing,
      reason: reason);
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
      expect(find.byKey(const Key('home-slot-refresh')), findsNothing,
          reason: reason);
    case _DashboardScenario.error:
      expect(find.text('--%'), findsOneWidget, reason: reason);
      expect(find.byKey(const Key('home-mode-retry')), findsNothing,
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
  bool readerMode = false;

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
    return readerMode;
  }

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {
    this.readerMode = readerMode;
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
