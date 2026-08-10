import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/slot_changer.dart';
import 'package:chameleonultragui/gui/menu/tools/lf_sniffing.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Slot Manager upload holds one foreground FIFO lease',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    await fixture.mount(tester, const SlotManagerPage());
    await tester.pumpAndSettle();
    fixture.communicator.operations.clear();

    final gate = Completer<void>();
    final blocker = fixture.appState.rfOperations.runForeground(
      () => gate.future,
    );
    final state = tester.state<SlotManagerPageState>(
      find.byType(SlotManagerPage),
    );
    final upload = state.onTap(
      CardSave(uid: '01 02 03 04 05', name: 'LF', tag: TagType.em410X),
      (_, __) {},
      await AppLocalizations.delegate.load(const Locale('en')),
    );
    await tester.pump();
    expect(fixture.communicator.operations, isEmpty);

    gate.complete();
    await blocker;
    await fixture.communicator.modeStarted.future;
    expect(fixture.communicator.operations, ['mode:false']);
    expect(
      (await fixture.appState.rfOperations.tryRunBackground(() async {}))
          .acquired,
      isFalse,
    );

    fixture.communicator.allowMode.complete();
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
      ],
    );
  });

  testWidgets('Slot Manager upload stops after communicator replacement',
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
    await fixture.communicator.modeStarted.future;
    final replacement = fixture.replaceCommunicator();
    fixture.communicator.allowMode.complete();
    await upload;

    expect(fixture.communicator.operations, ['mode:false']);
    expect(replacement.operations, isEmpty);
  });

  testWidgets('Slot Changer metadata waits for its foreground FIFO turn',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    final gate = Completer<void>();
    final blocker = fixture.appState.rfOperations.runForeground(
      () => gate.future,
    );

    await fixture.mount(tester, const SlotChanger());
    await tester.pump();
    expect(fixture.communicator.operations, isEmpty);
    gate.complete();
    await blocker;
    await tester.pumpAndSettle();

    expect(fixture.communicator.operations, ['slot-types', 'active-slot']);
  });

  testWidgets('LF capture holds one lease and stops stale follow-up commands',
      (tester) async {
    final fixture = await _WorkflowFixture.create();
    addTearDown(fixture.dispose);
    await fixture.mount(tester, const LfSniffingMenu());
    await tester.pump();
    await tester.pump();
    fixture.communicator.operations.clear();

    await tester.tap(find.widgetWithText(FilledButton, 'Capture').first);
    await fixture.communicator.readerModeStarted.future;
    final replacement = fixture.replaceCommunicator();
    fixture.communicator.allowReaderMode.complete();
    await tester.pumpAndSettle();

    expect(fixture.communicator.operations, ['reader-mode']);
    expect(replacement.operations, isEmpty);
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

  static Future<_WorkflowFixture> create() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    final connector = EmulatorSerial(log: logger);
    await connector.connectSpecificDevice('test-device');
    final communicator = _WorkflowCommunicator(logger, port: connector);
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    return _WorkflowFixture._(
      appState: appState,
      communicator: communicator,
      connector: connector,
      logger: logger,
    );
  }

  _WorkflowCommunicator replaceCommunicator() {
    final replacement = _WorkflowCommunicator(logger, port: connector);
    appState.communicator = replacement;
    return replacement;
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
    logger.close();
  }
}

class _WorkflowCommunicator extends ChameleonCommunicator {
  _WorkflowCommunicator(super.logger, {required super.port});

  final List<String> operations = [];
  final Completer<void> modeStarted = Completer<void>();
  final Completer<void> allowMode = Completer<void>();
  final Completer<void> readerModeStarted = Completer<void>();
  final Completer<void> allowReaderMode = Completer<void>();

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    operations.add('slot-types');
    return List.generate(8, (_) => SlotTypes());
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    operations.add('enabled-slots');
    return List.generate(8, (_) => EnabledSlotInfo());
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    operations.add('slot-names');
    return List.generate(8, (_) => SlotNames());
  }

  @override
  Future<int> getActiveSlot() async {
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
  Future<List<int>> getDeviceCapabilities() async => [
        ChameleonCommand.lfSniff.value,
      ];

  @override
  Future<bool> isReaderDeviceMode() async {
    operations.add('reader-mode');
    readerModeStarted.complete();
    await allowReaderMode.future;
    return false;
  }

  @override
  Future<Uint8List> lfSniff({int timeoutMs = 2000}) async {
    operations.add('lf-sniff:$timeoutMs');
    return Uint8List.fromList([0x80, 0x81, 0x82, 0x10]);
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
