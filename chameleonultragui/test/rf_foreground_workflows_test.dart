import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/tools/hf_sniffing.dart';
import 'package:chameleonultragui/gui/menu/tools/lf_sniffing.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connection_readiness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/connected_device_test_harness.dart';
import 'support/firmware_catalog_stub.dart';

void main() {
  testWidgets('Slot Manager upload waits for and holds foreground RF access',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    await fixture.mount(tester, const SlotManagerPage());
    await tester.pumpAndSettle();
    fixture.communicator.operations.clear();

    final state = tester.state<SlotManagerPageState>(
      find.byType(SlotManagerPage),
    );
    final backgroundGate = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await backgroundGate.future;
    });
    await tester.pump();

    final upload = state.onTap(
      CardSave(uid: '01 02 03 04 05', name: 'LF', tag: TagType.em410X),
      (_, __) {},
      await AppLocalizations.delegate.load(const Locale('en')),
    );
    await tester.pump();
    expect(fixture.communicator.operations, isEmpty);

    backgroundGate.complete();
    await background;
    await tester.pump();
    await fixture.communicator.modeStarted.future.timeout(
      const Duration(seconds: 2),
    );
    expect(fixture.communicator.operations, ['mode:false']);
    expect(
      (await fixture.appState.rfOperations.tryRunBackground(() async {}))
          .acquired,
      isFalse,
    );

    fixture.communicator.allowMode.complete();
    await fixture.communicator.readerModeStarted.future.timeout(
      const Duration(seconds: 2),
    );
    expect(
      (await fixture.appState.rfOperations.tryRunBackground(() async {}))
          .acquired,
      isFalse,
    );
    fixture.communicator.allowReaderMode.complete();
    await upload;
    expect(
      fixture.communicator.operations,
      [
        'mode:false',
        'enable:0:lf:true',
        'activate:0',
        'type:0:em410X',
        'default:0:em410X',
        'em410x:0102030405',
        'name:0:lf:LF',
        'save',
        'slot-types',
        'slot-types',
        'enabled-slots',
        'slot-names',
        'active-slot',
        'reader-mode',
      ],
    );
    expect(
      (await fixture.appState.rfOperations.tryRunBackground(() async {}))
          .acquired,
      isTrue,
    );
  });

  testWidgets('LF capture waits for and holds foreground RF access',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    await fixture.mount(tester, const LfSniffingMenu());
    await tester.pump();
    await tester.pump();

    final backgroundGate = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await backgroundGate.future;
    });
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Capture').first);
    await tester.pump();
    expect(fixture.communicator.operations, ['capabilities']);

    backgroundGate.complete();
    await background;
    await tester.pump();
    await fixture.communicator.readerModeStarted.future.timeout(
      const Duration(seconds: 2),
    );
    expect(fixture.communicator.operations, ['capabilities', 'reader-mode']);
    expect(
      (await fixture.appState.rfOperations.tryRunBackground(() async {}))
          .acquired,
      isFalse,
    );

    fixture.communicator.allowReaderMode.complete();
    await tester.pumpAndSettle();
    expect(
      fixture.communicator.operations,
      ['capabilities', 'reader-mode', 'mode:true', 'lf-sniff:2000'],
    );
    expect(
      (await fixture.appState.rfOperations.tryRunBackground(() async {}))
          .acquired,
      isTrue,
    );
  });

  testWidgets('queued Slot Manager upload rejects a replacement communicator',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    await fixture.mount(tester, const SlotManagerPage());
    await tester.pumpAndSettle();
    fixture.communicator.operations.clear();
    final state = tester.state<SlotManagerPageState>(
      find.byType(SlotManagerPage),
    );
    final backgroundGate = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await backgroundGate.future;
    });
    await tester.pump();

    final upload = state.onTap(
      CardSave(uid: '01 02 03 04 05', name: 'LF', tag: TagType.em410X),
      (_, __) {},
      await AppLocalizations.delegate.load(const Locale('en')),
    );
    await tester.pump();
    final replacement = _WorkflowCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    fixture.appState.communicator = replacement;
    backgroundGate.complete();
    await background;
    await upload;

    expect(fixture.communicator.operations, isEmpty);
    expect(replacement.operations, isEmpty);
  });

  testWidgets('in-flight Slot Manager upload stops after session replacement',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    await fixture.mount(tester, const SlotManagerPage());
    await tester.pumpAndSettle();
    fixture.communicator.operations.clear();
    final state = tester.state<SlotManagerPageState>(
      find.byType(SlotManagerPage),
    );

    final upload = state.onTap(
      CardSave(uid: '01 02 03 04 05', name: 'LF', tag: TagType.em410X),
      (_, __) {},
      await AppLocalizations.delegate.load(const Locale('en')),
    );
    await fixture.communicator.modeStarted.future.timeout(
      const Duration(seconds: 2),
    );
    final replacement = _WorkflowCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    fixture.appState.communicator = replacement;
    fixture.communicator.allowMode.complete();
    await upload;

    expect(fixture.communicator.operations, ['mode:false']);
    expect(replacement.operations, isEmpty);
    expect(state.progress, -1);
  });

  testWidgets('throwing LF capture releases foreground RF access',
      (tester) async {
    final fixture = await _WorkflowFixture.create(throwOnLfSniff: true);
    addTearDown(fixture.dispose);
    fixture.communicator.allowReaderMode.complete();
    await fixture.mount(tester, const LfSniffingMenu());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Capture').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      (await fixture.appState.rfOperations.tryRunBackground(() async {}))
          .acquired,
      isTrue,
    );
  });

  testWidgets('Slot Manager metadata waits for its foreground FIFO turn',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    final blocker = fixture.appState.rfOperations.runForeground(
      () => gate.future,
    );

    await fixture.mount(tester, const SlotManagerPage());
    await tester.pump();
    await tester.pump();
    expect(fixture.communicator.operations, isEmpty);

    final afterMetadata = fixture.appState.rfOperations.runForeground(() async {
      fixture.communicator.operations.add('after-metadata');
    });
    gate.complete();
    await blocker;
    await afterMetadata;
    await tester.pumpAndSettle();

    expect(
      fixture.communicator.operations,
      [
        'after-metadata',
        'slot-types',
        'enabled-slots',
        'slot-names',
        'active-slot',
      ],
    );
  });

  testWidgets('Slot Manager metadata stops after communicator replacement',
      (tester) async {
    final fixture = await _WorkflowFixture.create(holdSlotTypes: true);
    addTearDown(fixture.dispose);

    await fixture.mount(tester, const SlotManagerPage());
    await tester.pump();
    await fixture.communicator.slotTypesStarted.future.timeout(
      const Duration(seconds: 2),
    );
    final replacement = _WorkflowCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    fixture.appState.communicator = replacement;
    fixture.communicator.allowSlotTypes.complete();
    await tester.pumpAndSettle();

    expect(fixture.communicator.operations, ['slot-types']);
    expect(replacement.operations, isEmpty);
  });

  testWidgets('HF capability probe waits and ignores a stale response',
      (tester) async {
    final fixture = await _WorkflowFixture.create(holdCapabilities: true);
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    final blocker = fixture.appState.rfOperations.runForeground(
      () => gate.future,
    );

    await fixture.mount(tester, const HfSniffingMenu());
    await tester.pump();
    await tester.pump();
    expect(fixture.communicator.operations, isEmpty);

    gate.complete();
    await blocker;
    await tester.pump();
    await fixture.communicator.capabilitiesStarted.future.timeout(
      const Duration(seconds: 2),
    );
    final replacement = _WorkflowCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    fixture.appState.communicator = replacement;
    fixture.communicator.allowCapabilities.complete();
    await tester.pumpAndSettle();

    expect(fixture.communicator.operations, ['capabilities']);
    expect(replacement.operations, isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Capture').first,
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('LF capability probe waits and ignores a stale response',
      (tester) async {
    final fixture = await _WorkflowFixture.create(holdCapabilities: true);
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    final blocker = fixture.appState.rfOperations.runForeground(
      () => gate.future,
    );

    await fixture.mount(tester, const LfSniffingMenu());
    await tester.pump();
    await tester.pump();
    expect(fixture.communicator.operations, isEmpty);

    gate.complete();
    await blocker;
    await tester.pump();
    await fixture.communicator.capabilitiesStarted.future.timeout(
      const Duration(seconds: 2),
    );
    final replacement = _WorkflowCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    fixture.appState.communicator = replacement;
    fixture.communicator.allowCapabilities.complete();
    await tester.pumpAndSettle();

    expect(fixture.communicator.operations, ['capabilities']);
    expect(replacement.operations, isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Capture').first,
          )
          .onPressed,
      isNotNull,
    );
  });
}

class _WorkflowFixture {
  _WorkflowFixture._({
    required this.appState,
    required this.communicator,
    required this.connector,
    required this.logger,
  });

  final ChameleonGUIState appState;
  final _WorkflowCommunicator communicator;
  final EmulatorSerial connector;
  final Logger logger;

  static Future<_WorkflowFixture> create({
    bool throwOnLfSniff = false,
    bool holdSlotTypes = false,
    bool holdCapabilities = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    final connector = EmulatorSerial(log: logger);
    await connector.connectSpecificDevice('test-device');
    final communicator = _WorkflowCommunicator(
      logger,
      port: connector,
      throwOnLfSniff: throwOnLfSniff,
      holdSlotTypes: holdSlotTypes,
      holdCapabilities: holdCapabilities,
    );
    final appState = ChameleonGUIState(
      preferences,
      firmwareCatalog: const CurrentFirmwareCatalogStub(),
    )
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    await _settleReadiness(appState);
    communicator.finishInitialReadiness();
    communicator.operations.clear();
    return _WorkflowFixture._(
      appState: appState,
      communicator: communicator,
      connector: connector,
      logger: logger,
    );
  }

  Future<void> mount(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
  }

  void dispose() {
    appState.dispose();
    logger.close();
  }
}

class _WorkflowCommunicator extends ReadinessTestCommunicator {
  _WorkflowCommunicator(
    super.log, {
    required EmulatorSerial port,
    this.throwOnLfSniff = false,
    this.holdSlotTypes = false,
    this.holdCapabilities = false,
  }) {
    open(port);
  }

  final bool throwOnLfSniff;
  final bool holdSlotTypes;
  final bool holdCapabilities;
  final List<String> operations = [];
  final Completer<void> modeStarted = Completer<void>();
  final Completer<void> allowMode = Completer<void>();
  final Completer<void> readerModeStarted = Completer<void>();
  final Completer<void> allowReaderMode = Completer<void>();
  final Completer<void> slotTypesStarted = Completer<void>();
  final Completer<void> allowSlotTypes = Completer<void>();
  final Completer<void> capabilitiesStarted = Completer<void>();
  final Completer<void> allowCapabilities = Completer<void>();
  bool _initialReadiness = true;

  void finishInitialReadiness() => _initialReadiness = false;

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    if (_initialReadiness) {
      return List.generate(8, (_) => SlotTypes());
    }
    operations.add('slot-types');
    if (holdSlotTypes) {
      slotTypesStarted.complete();
      await allowSlotTypes.future;
    }
    return List.generate(8, (_) => SlotTypes());
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    if (_initialReadiness) {
      return List.generate(8, (_) => EnabledSlotInfo());
    }
    operations.add('enabled-slots');
    return List.generate(8, (_) => EnabledSlotInfo());
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    if (_initialReadiness) {
      return List.generate(8, (_) => SlotNames());
    }
    operations.add('slot-names');
    return List.generate(8, (_) => SlotNames());
  }

  @override
  Future<int> getActiveSlot() async {
    if (_initialReadiness) {
      return 0;
    }
    operations.add('active-slot');
    return 0;
  }

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {
    operations.add('mode:$readerMode');
    if (!readerMode) {
      modeStarted.complete();
      await allowMode.future;
    }
  }

  @override
  Future<void> enableSlot(
    int slot,
    TagFrequency frequency,
    bool status,
  ) async {
    operations.add('enable:$slot:${frequency.name}:$status');
  }

  @override
  Future<void> activateSlot(int slot) async {
    operations.add('activate:$slot');
  }

  @override
  Future<void> setSlotType(int slot, TagType type) async {
    operations.add('type:$slot:${type.name}');
  }

  @override
  Future<void> setDefaultDataToSlot(int slot, TagType type) async {
    operations.add('default:$slot:${type.name}');
  }

  @override
  Future<void> setEM410XEmulatorID(Uint8List uid) async {
    operations.add('em410x:${_hex(uid)}');
  }

  @override
  Future<void> setSlotTagName(
    int index,
    String name,
    TagFrequency frequency,
  ) async {
    operations.add('name:$index:${frequency.name}:$name');
  }

  @override
  Future<void> saveSlotData() async {
    operations.add('save');
  }

  @override
  Future<List<int>> getDeviceCapabilities() async {
    if (_initialReadiness) {
      return [ChameleonCommand.lfSniff.value];
    }
    operations.add('capabilities');
    if (holdCapabilities) {
      capabilitiesStarted.complete();
      await allowCapabilities.future;
      return [];
    }
    return [ChameleonCommand.lfSniff.value];
  }

  @override
  Future<bool> isReaderDeviceMode() async {
    if (_initialReadiness) {
      return false;
    }
    operations.add('reader-mode');
    readerModeStarted.complete();
    await allowReaderMode.future;
    return false;
  }

  @override
  Future<Uint8List> lfSniff({int timeoutMs = 2000}) async {
    operations.add('lf-sniff:$timeoutMs');
    if (throwOnLfSniff) {
      throw StateError('capture failed');
    }
    return Uint8List.fromList([0x80, 0x81, 0x82, 0x10]);
  }
}

Future<void> _settleReadiness(ChameleonGUIState appState) async {
  const terminal = {
    ConnectionReadinessStage.ready,
    ConnectionReadinessStage.degraded,
  };
  for (var attempt = 0; attempt < 200; attempt++) {
    if (terminal.contains(appState.connectionReadiness.snapshot.stage)) {
      return;
    }
    await Future<void>.value();
  }
  fail('Workflow fixture readiness did not settle');
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
