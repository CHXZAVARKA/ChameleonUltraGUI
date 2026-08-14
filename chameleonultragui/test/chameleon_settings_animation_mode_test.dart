import 'dart:async';
import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/chameleon_settings.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'support/connected_device_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final device in [ChameleonDevice.ultra, ChameleonDevice.lite]) {
    testWidgets('settings reads and confirms animation mode on ${device.name}',
        (tester) async {
      final fixture = await _pumpSettings(tester, device: device);

      expect(
        fixture.communicator.events,
        containsAllInOrder(['capabilities', 'read:full']),
      );
      expect(_dropdown(tester).value, AnimationSetting.full);

      await _chooseMode(tester, 'Symmetric');
      await tester.pumpAndSettle();

      expect(
        fixture.communicator.events,
        containsAllInOrder([
          'read:full',
          'set:symmetric',
          'save',
          'read:symmetric',
        ]),
      );
      expect(_dropdown(tester).value, AnimationSetting.symmetric);
      expect(fixture.serial.disconnects, 0);
    });
  }

  testWidgets('pending animation change blocks duplicate selection',
      (tester) async {
    final fixture = await _pumpSettings(tester);
    final gate = Completer<void>();
    fixture.communicator.nextSetGate = gate;

    await _chooseMode(tester, 'Minimal');
    await tester.pump();

    expect(fixture.communicator.sets, [AnimationSetting.minimal]);
    expect(find.byKey(const Key('animation-mode-progress')), findsOneWidget);
    expect(_dropdown(tester).onChanged, isNull);

    await tester.tap(find.byKey(const Key('animation-mode-dropdown')));
    await tester.tap(find.byKey(const Key('animation-mode-dropdown')));
    await tester.pump();
    expect(fixture.communicator.sets, [AnimationSetting.minimal]);

    gate.complete();
    await tester.pumpAndSettle();
    expect(fixture.communicator.saves, 1);
    expect(fixture.communicator.animationReads, 2);
  });

  testWidgets('mismatched read-back keeps the device-confirmed animation mode',
      (tester) async {
    final fixture = await _pumpSettings(tester);
    fixture.communicator.ignoreSets = true;

    await _chooseMode(tester, 'None');
    await tester.pumpAndSettle();

    expect(fixture.communicator.sets, [AnimationSetting.none]);
    expect(fixture.communicator.animationReads, 2);
    expect(_dropdown(tester).value, AnimationSetting.full);
    expect(
      find.text('The LED animation mode could not be saved or confirmed.'),
      findsOneWidget,
    );
  });

  testWidgets('unsupported firmware leaves animation setting disabled',
      (tester) async {
    final communicator = _AnimationCommunicator()
      ..capabilities = [ChameleonCommand.getDeviceCapabilities.value];
    final fixture = await _pumpSettings(
      tester,
      communicator: communicator,
      device: ChameleonDevice.lite,
    );

    expect(fixture.communicator.animationReads, 0);
    expect(_dropdown(tester).onChanged, isNull);
    expect(
      find.text(
        'LED animation modes are not supported by this device firmware.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('animation-mode-retry')), findsNothing);
  });

  testWidgets('read failure remains visible and retries without disconnecting',
      (tester) async {
    final communicator = _AnimationCommunicator()
      ..scriptedReads.add(StateError('temporary read failure'));
    final fixture = await _pumpSettings(tester, communicator: communicator);

    expect(find.byType(ChameleonSettings), findsOneWidget);
    expect(find.byKey(const Key('animation-mode-retry')), findsOneWidget);
    expect(fixture.serial.disconnects, 0);

    await tester.tap(find.byKey(const Key('animation-mode-retry')));
    await tester.pumpAndSettle();

    expect(_dropdown(tester).value, AnimationSetting.full);
    expect(fixture.communicator.animationReads, 2);
    expect(fixture.serial.disconnects, 0);
  });

  testWidgets('connection replacement stops follow-up animation commands',
      (tester) async {
    final fixture = await _pumpSettings(tester);
    final gate = Completer<void>();
    fixture.communicator.nextSetGate = gate;

    await _chooseMode(tester, 'Symmetric');
    await tester.pump();
    expect(fixture.communicator.sets, [AnimationSetting.symmetric]);

    final replacement = _AnimationCommunicator();
    fixture.appState.communicator = replacement;
    fixture.appState.changesMade();
    gate.complete();
    await tester.pumpAndSettle();

    expect(fixture.communicator.saves, 0);
    expect(fixture.communicator.animationReads, 1);
    expect(replacement.sets, isEmpty);
    expect(find.byKey(const Key('animation-mode-retry')), findsOneWidget);
    expect(fixture.serial.disconnects, 0);
  });

  testWidgets('idle connection replacement immediately invalidates old mode',
      (tester) async {
    final fixture = await _pumpSettings(tester);
    expect(_dropdown(tester).value, AnimationSetting.full);

    fixture.appState.communicator = _AnimationCommunicator()
      ..currentMode = AnimationSetting.none;
    fixture.appState.changesMade();
    await tester.pump();

    expect(_dropdown(tester).value, isNull);
    expect(_dropdown(tester).onChanged, isNull);
    expect(find.byKey(const Key('animation-mode-retry')), findsOneWidget);
    expect(
      find.text('The LED animation mode could not be read.'),
      findsOneWidget,
    );
  });

  testWidgets('reduced motion uses a static loading indicator', (tester) async {
    final communicator = _AnimationCommunicator();
    communicator.nextCapabilitiesGate = Completer<void>();

    await _pumpSettings(
      tester,
      communicator: communicator,
      disableAnimations: true,
      settle: false,
    );
    await tester.pump();

    expect(find.byKey(const Key('animation-mode-progress')), findsOneWidget);
    expect(
      find.byKey(const Key('animation-mode-static-progress')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    communicator.nextCapabilitiesGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('failed write reconciles through a mandatory device read',
      (tester) async {
    final fixture = await _pumpSettings(tester);
    fixture.communicator.nextSetError = StateError('write rejected');

    await _chooseMode(tester, 'Minimal');
    await tester.pumpAndSettle();

    expect(fixture.communicator.animationReads, 2);
    expect(_dropdown(tester).value, AnimationSetting.full);
    expect(
      find.text('The LED animation mode could not be saved or confirmed.'),
      findsOneWidget,
    );
    expect(fixture.serial.disconnects, 0);
  });
}

DropdownButton<AnimationSetting> _dropdown(WidgetTester tester) {
  return tester.widget<DropdownButton<AnimationSetting>>(
    find.byKey(const Key('animation-mode-dropdown')),
  );
}

Future<void> _chooseMode(WidgetTester tester, String label) async {
  final dropdown = find.byKey(const Key('animation-mode-dropdown'));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pump();
}

Future<
    ({
      ChameleonGUIState appState,
      _AnimationCommunicator communicator,
      TestSerial serial,
    })> _pumpSettings(
  WidgetTester tester, {
  _AnimationCommunicator? communicator,
  ChameleonDevice device = ChameleonDevice.ultra,
  bool disableAnimations = false,
  bool settle = true,
}) async {
  final logger = Logger(output: MemoryOutput());
  addTearDown(logger.close);
  final resolvedCommunicator = communicator ?? _AnimationCommunicator();
  final harness = ConnectedDeviceTestHarness(
    communicator: resolvedCommunicator,
    logger: logger,
    device: device,
    portName: 'animation-mode-test',
    activeDevicePort: 'animation-mode-test',
  );
  final appState = harness.appState;
  final serial = harness.serial;
  addTearDown(appState.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: appState,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: const Scaffold(body: ChameleonSettings()),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }

  return (
    appState: appState,
    communicator: resolvedCommunicator,
    serial: serial,
  );
}

class _AnimationCommunicator extends ChameleonCommunicator {
  _AnimationCommunicator() : super(Logger(output: MemoryOutput()));

  AnimationSetting currentMode = AnimationSetting.full;
  List<int> capabilities = [
    ChameleonCommand.getAnimationMode.value,
    ChameleonCommand.setAnimationMode.value,
    ChameleonCommand.saveSettings.value,
  ];
  final List<String> events = [];
  final List<AnimationSetting> sets = [];
  final List<Object> scriptedReads = [];
  int animationReads = 0;
  int saves = 0;
  Completer<void>? nextSetGate;
  Completer<void>? nextCapabilitiesGate;
  Object? nextSetError;
  bool ignoreSets = false;

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x0100);

  @override
  Future<BatteryCharge> getBatteryCharge() async =>
      BatteryCharge(percent: 60, voltage: 3900);

  @override
  Future<bool> isReaderDeviceMode() async => false;

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
  Future<int> getActiveSlot() async => 0;

  @override
  Future<String> getGitCommitHash() async => 'abcdef0';

  @override
  Future<DeviceSettings> getDeviceSettings() async =>
      DeviceSettings(animation: currentMode);

  @override
  Future<List<int>> getDeviceCapabilities() async {
    events.add('capabilities');
    final gate = nextCapabilitiesGate;
    await gate?.future;
    return capabilities;
  }

  @override
  Future<AnimationSetting> getAnimationMode() async {
    animationReads++;
    if (scriptedReads.isNotEmpty) {
      final result = scriptedReads.removeAt(0);
      if (result is AnimationSetting) {
        currentMode = result;
      } else {
        throw result;
      }
    }
    events.add('read:${currentMode.name}');
    return currentMode;
  }

  @override
  Future<void> setAnimationMode(AnimationSetting animation) async {
    sets.add(animation);
    events.add('set:${animation.name}');
    final gate = nextSetGate;
    nextSetGate = null;
    await gate?.future;
    final error = nextSetError;
    nextSetError = null;
    if (error != null) {
      throw error;
    }
    if (!ignoreSets) {
      currentMode = animation;
    }
  }

  @override
  Future<void> saveSettings() async {
    saves++;
    events.add('save');
  }
}
