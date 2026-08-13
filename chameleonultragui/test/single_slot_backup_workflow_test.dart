import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:chameleonultragui/helpers/single_slot_backup_workflow.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'support/connected_device_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('single-slot backup workflow', () {
    testWidgets(
        'Slot Settings exports through the production state and file seam',
        (tester) async {
      final files = _MemoryBackupFiles();
      final communicator = _BackupCommunicator(
        hfType: TagType.mifareMini,
        lfType: TagType.em410X,
      );
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.appState.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: fixture.appState,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: SlotSettings(slot: 0)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('slot-settings-backup')), findsOneWidget);
      await tester.tap(find.byKey(const Key('slot-settings-backup')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(files.saved, isNotNull);
      final backup = SingleSlotBackupCodec.decode(
        String.fromCharCodes(files.saved!),
      );
      expect(backup.hf.state, SlotBackupCompleteness.complete);
      expect(backup.lf.state, SlotBackupCompleteness.complete);
      expect(find.text('Slot backup saved.'), findsOneWidget);
    });

    testWidgets('Slot Settings previews and confirms restore into its slot',
        (tester) async {
      final files = _MemoryBackupFiles()
        ..opened = Uint8List.fromList(
          SingleSlotBackupCodec.encode(
            _lfBackup(device: ChameleonDevice.ultra),
          ).codeUnits,
        );
      final communicator = _BackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.appState.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: fixture.appState,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: SlotSettings(slot: 3)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      communicator.events.clear();

      await tester.tap(find.byKey(const Key('slot-settings-restore')));
      await tester.pump();

      expect(find.text('Restore slot backup'), findsOneWidget);
      expect(
        find.textContaining('Restore source slot 1 into slot 4?'),
        findsOneWidget,
      );
      expect(
        find.textContaining('HF: Empty, Empty, Disabled'),
        findsOneWidget,
      );
      expect(
        find.textContaining('LF: Complete, EM410X, Enabled'),
        findsOneWidget,
      );
      expect(find.textContaining('HF: empty'), findsNothing);
      expect(find.textContaining('LF: complete'), findsNothing);
      expect(communicator.events, isEmpty);

      await tester.tap(find.byKey(const Key('slot-backup-confirm-restore')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(communicator.events, contains('activate:3'));
      expect(communicator.events, contains('lf:em410X:0102030405'));
      expect(find.text('Slot restored.'), findsOneWidget);
    });

    test('round-trips a complete Classic HF and LF bundle to another slot',
        () async {
      final communicator = _BackupCommunicator(
        hfType: TagType.mifareMini,
        lfType: TagType.em410X,
        antiCollisionRead: CardData(
          uid: Uint8List.fromList([7, 8, 9, 10]),
          sak: 0x42,
          atqa: Uint8List.fromList([0x44, 0x55]),
          ats: Uint8List.fromList([0x75]),
        ),
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final status = fixture.appState.connectedDeviceStatus!;
      final files = _MemoryBackupFiles();
      final workflow = SingleSlotBackupWorkflow(files: files);

      expect(
        await workflow.export(status: status, position: 1),
        SlotBackupExportOutcome.saved,
      );
      final encoded = files.saved!;
      files.opened = encoded;
      final opened = await workflow.open();

      expect(opened.outcome, SlotBackupOpenOutcome.ready);
      expect(opened.backup!.hf.state, SlotBackupCompleteness.complete);
      expect(opened.backup!.lf.state, SlotBackupCompleteness.complete);
      expect(opened.backup!.hf.payload!.data, hasLength(20));
      expect(opened.backup!.lf.payload!.uid, [1, 2, 3, 4, 5]);

      communicator.events.clear();
      expect(
        await workflow.restore(
          status: status,
          backup: opened.backup!,
          targetPosition: 5,
        ),
        SlotBackupRestoreOutcome.restored,
      );
      expect(
          communicator.events,
          containsAllInOrder([
            'mode:emulator',
            'activate:5',
            'enable:5:hf:true',
            'type:5:mifareMini',
            'default:5:mifareMini',
            'anticollision:0708090a',
            'classic:0:128',
            'classic:8:128',
            'classic:16:64',
            'classic-detection:true',
            'classic-gen1a:false',
            'classic-gen2:true',
            'classic-block0-collision:true',
            'classic-write-mode:shadow',
            'classic-prng:weak',
            'name:5:hf:Office',
            'enable:5:lf:false',
            'type:5:em410X',
            'default:5:em410X',
            'lf:em410X:0102030405',
            'name:5:lf:Door',
            'save',
          ]));
      expect(communicator.antiCollisionWritten!.uid, [7, 8, 9, 10]);
      expect(communicator.antiCollisionWritten!.sak, 0x42);
      expect(communicator.antiCollisionWritten!.atqa, [0x44, 0x55]);
      expect(communicator.antiCollisionWritten!.ats, [0x75]);
    });

    test('round-trips Ultralight payload and supported metadata', () async {
      final communicator = _BackupCommunicator(
        hfType: TagType.ntag210,
        lfType: TagType.unknown,
        antiCollisionRead: CardData(
          uid: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
          sak: 0,
          atqa: Uint8List.fromList([0x00, 0x44]),
          ats: Uint8List(0),
        ),
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final workflow = SingleSlotBackupWorkflow(files: _MemoryBackupFiles());

      final backup = await workflow.capture(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );

      expect(backup!.hf.state, SlotBackupCompleteness.complete);
      expect(backup.hf.payload!.data, hasLength(20));
      expect(backup.hf.payload!.ultralightVersion, [1, 2, 3]);
      expect(backup.hf.payload!.ultralightSignature, [4, 5, 6]);

      communicator.events.clear();
      expect(
        await workflow.restore(
          status: fixture.appState.connectedDeviceStatus!,
          backup: backup,
          targetPosition: 4,
        ),
        SlotBackupRestoreOutcome.restored,
      );
      expect(communicator.ultralightPagesWritten, 20);
      expect(communicator.events, contains('ultralight-version:010203'));
      expect(communicator.events, contains('ultralight-signature:040506'));
      expect(
        communicator.events,
        containsAllInOrder([
          'ultralight-magic:true',
          'ultralight-detection:true',
          'ultralight-write-mode:deceive',
        ]),
      );
    });

    test('short Classic payload is never labeled complete', () async {
      final communicator = _BackupCommunicator(
        hfType: TagType.mifareMini,
        shortClassicRead: true,
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);

      final backup = await SingleSlotBackupWorkflow(
        files: _MemoryBackupFiles(),
      ).capture(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );

      expect(backup!.hf.state, SlotBackupCompleteness.partial);
      expect(backup.isRestorable, isFalse);
    });

    test('failed Classic PRNG metadata read cannot produce a complete backup',
        () async {
      final communicator = _BackupCommunicator(
        hfType: TagType.mifareMini,
        failPrngRead: true,
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);

      final backup = await SingleSlotBackupWorkflow(
        files: _MemoryBackupFiles(),
      ).capture(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );

      expect(backup!.hf.state, SlotBackupCompleteness.partial);
      expect(backup.isRestorable, isFalse);
    });

    test('non-restorable Ultralight tearing state is marked partial', () async {
      final communicator = _BackupCommunicator(
        hfType: TagType.ultralight11,
        ultralightTearingStates: const [true, false, true],
        antiCollisionRead: CardData(
          uid: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
          sak: 0,
          atqa: Uint8List.fromList([0, 4]),
          ats: Uint8List(0),
        ),
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);

      final backup = await SingleSlotBackupWorkflow(
        files: _MemoryBackupFiles(),
      ).capture(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );

      expect(backup!.hf.state, SlotBackupCompleteness.partial);
      expect(backup.hf.payload!.ultralightTearingStates, [true, false, true]);
      expect(backup.isRestorable, isFalse);
    });

    test('Ultralight tearing state round-trips through restore exactly',
        () async {
      final communicator = _BackupCommunicator(
        hfType: TagType.ultralight11,
        ultralightTearingStates: const [true, true, true],
        antiCollisionRead: CardData(
          uid: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
          sak: 0,
          atqa: Uint8List.fromList([0, 4]),
          ats: Uint8List(0),
        ),
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final workflow = SingleSlotBackupWorkflow(files: _MemoryBackupFiles());

      final captured = await workflow.capture(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );
      final decoded = SingleSlotBackupCodec.decode(
        SingleSlotBackupCodec.encode(captured!),
      );

      expect(decoded.hf.payload!.ultralightTearingStates, [true, true, true]);
      communicator.events.clear();
      expect(
        await workflow.restore(
          status: fixture.appState.connectedDeviceStatus!,
          backup: decoded,
          targetPosition: 2,
        ),
        SlotBackupRestoreOutcome.restored,
      );
      expect(
        communicator.events
            .where((event) => event.startsWith('ultralight-counter:')),
        containsAllInOrder([
          'ultralight-counter:0:1:true',
          'ultralight-counter:1:2:true',
          'ultralight-counter:2:3:true',
        ]),
      );
      expect(
        communicator.events,
        containsAllInOrder([
          'ultralight-magic:true',
          'ultralight-detection:true',
          'ultralight-write-mode:deceive',
        ]),
      );
    });

    test('picker cancellation performs no device work', () async {
      final communicator = _BackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final workflow = SingleSlotBackupWorkflow(
        files: _MemoryBackupFiles(cancelSave: true),
      );

      expect(
        await workflow.export(
          status: fixture.appState.connectedDeviceStatus!,
          position: 0,
        ),
        SlotBackupExportOutcome.cancelled,
      );
      expect(communicator.events, isEmpty);

      final openFiles = _MemoryBackupFiles();
      final openWorkflow = SingleSlotBackupWorkflow(files: openFiles);
      expect(
          (await openWorkflow.open()).outcome, SlotBackupOpenOutcome.cancelled);
      expect(communicator.events, isEmpty);
    });

    test('invalid digest and incompatible model perform no mutations',
        () async {
      final communicator = _BackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final files = _MemoryBackupFiles();
      final workflow = SingleSlotBackupWorkflow(files: files);
      final valid = _lfBackup(device: ChameleonDevice.ultra);
      files.opened = Uint8List.fromList(
        SingleSlotBackupCodec.encode(valid)
            .replaceFirst('AQIDBAU=', 'AQIDBAY=')
            .codeUnits,
      );

      expect((await workflow.open()).outcome, SlotBackupOpenOutcome.invalid);
      expect(communicator.events, isEmpty);

      expect(
        await workflow.restore(
          status: fixture.appState.connectedDeviceStatus!,
          backup: _lfBackup(device: ChameleonDevice.lite),
          targetPosition: 2,
        ),
        SlotBackupRestoreOutcome.incompatibleDevice,
      );
      expect(communicator.events, isEmpty);
    });

    test('ambiguous response is issued once and stops later commands',
        () async {
      final communicator = _BackupCommunicator(failAfterLfWrite: true);
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final workflow = SingleSlotBackupWorkflow(files: _MemoryBackupFiles());

      expect(
        await workflow.restore(
          status: fixture.appState.connectedDeviceStatus!,
          backup: _lfBackup(device: ChameleonDevice.ultra),
          targetPosition: 2,
        ),
        SlotBackupRestoreOutcome.failed,
      );
      expect(
        communicator.events.where((event) => event.startsWith('lf:')),
        hasLength(1),
      );
      expect(communicator.events, isNot(contains('name:2:lf:Door')));
      expect(communicator.events, isNot(contains('save')));
    });

    test('communicator replacement stops capture and publishes no file',
        () async {
      final gate = Completer<void>();
      final communicator = _BackupCommunicator(readGate: gate);
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final files = _MemoryBackupFiles();
      final workflow = SingleSlotBackupWorkflow(files: files);
      final export = workflow.export(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );
      await communicator.readStarted.future;

      fixture.appState.communicator = _BackupCommunicator();
      gate.complete();

      expect(await export, SlotBackupExportOutcome.connectionChanged);
      expect(files.saved, isNull);
    });

    test('communicator replacement stops between payload reads', () async {
      final gate = Completer<void>();
      final communicator = _BackupCommunicator(
        hfType: TagType.mifareMini,
        payloadReadGate: gate,
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final files = _MemoryBackupFiles();
      final export = SingleSlotBackupWorkflow(files: files).export(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );
      await communicator.payloadReadStarted.future;

      fixture.appState.communicator = _BackupCommunicator();
      gate.complete();

      expect(await export, SlotBackupExportOutcome.connectionChanged);
      expect(communicator.classicReadCount, 1);
      expect(files.saved, isNull);
    });

    test('DFU transition stops capture and publishes no file', () async {
      final gate = Completer<void>();
      final communicator = _BackupCommunicator(readGate: gate);
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final files = _MemoryBackupFiles();
      final export = SingleSlotBackupWorkflow(files: files).export(
        status: fixture.appState.connectedDeviceStatus!,
        position: 0,
      );
      await communicator.readStarted.future;

      fixture.serial.isDFU = true;
      fixture.appState.onConnectorStateChanged();
      gate.complete();

      expect(await export, SlotBackupExportOutcome.connectionChanged);
      expect(files.saved, isNull);
    });
  });
}

SingleSlotBackup _lfBackup({required ChameleonDevice device}) {
  return SingleSlotBackup(
    sourceDevice: device,
    sourcePosition: 0,
    createdAt: DateTime.utc(2026),
    hf: SlotFrequencyBackup.empty(
      frequency: TagFrequency.hf,
      enabled: false,
      name: '',
    ),
    lf: SlotFrequencyBackup.complete(
      frequency: TagFrequency.lf,
      type: TagType.em410X,
      enabled: true,
      name: 'Door',
      payload: SlotCardPayload(
        uid: Uint8List.fromList([1, 2, 3, 4, 5]),
      ),
    ),
  );
}

final class _MemoryBackupFiles implements SlotBackupFileAdapter {
  _MemoryBackupFiles({this.cancelSave = false});

  final bool cancelSave;
  Uint8List? saved;
  Uint8List? opened;

  @override
  Future<SlotBackupSaveTarget?> chooseSaveTarget(String suggestedName) async {
    return cancelSave ? null : _MemorySaveTarget(this);
  }

  @override
  Future<Uint8List?> open() async => opened;
}

final class _MemorySaveTarget implements SlotBackupSaveTarget {
  const _MemorySaveTarget(this.files);

  final _MemoryBackupFiles files;

  @override
  Future<void> write(Uint8List bytes) async {
    files.saved = Uint8List.fromList(bytes);
  }
}

final class _BackupCommunicator extends ChameleonCommunicator {
  _BackupCommunicator({
    this.hfType = TagType.unknown,
    this.lfType = TagType.unknown,
    this.failAfterLfWrite = false,
    this.readGate,
    this.payloadReadGate,
    this.antiCollisionRead,
    this.shortClassicRead = false,
    this.failPrngRead = false,
    this.ultralightTearingStates = const [true, true, true],
  }) : super(Logger(output: MemoryOutput()));

  final TagType hfType;
  final TagType lfType;
  final bool failAfterLfWrite;
  final Completer<void>? readGate;
  final Completer<void>? payloadReadGate;
  final CardData? antiCollisionRead;
  final bool shortClassicRead;
  final bool failPrngRead;
  final List<bool> ultralightTearingStates;
  final Completer<void> readStarted = Completer<void>();
  final Completer<void> payloadReadStarted = Completer<void>();
  final List<String> events = [];
  int ultralightPagesWritten = 0;
  int classicReadCount = 0;
  CardData? antiCollisionWritten;

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    if (!readStarted.isCompleted) {
      readStarted.complete();
    }
    await readGate?.future;
    events.add('read:types');
    return List.generate(8, (_) => SlotTypes(hf: hfType, lf: lfType));
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    events.add('read:enabled');
    return List.generate(8, (_) => EnabledSlotInfo(hf: true, lf: false));
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    events.add('read:names');
    return List.generate(8, (_) => SlotNames(hf: 'Office', lf: 'Door'));
  }

  @override
  Future<int> getActiveSlot() async => 0;

  @override
  Future<void> activateSlot(int slot) async {
    events.add('activate:$slot');
  }

  @override
  Future<CardData> mf1GetAntiCollData() async =>
      antiCollisionRead ??
      CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 9,
        atqa: Uint8List.fromList([0, 4]),
        ats: Uint8List(0),
      );

  @override
  Future<EmulatorSettings> getMf1EmulatorSettings() async => EmulatorSettings(
        isDetectionEnabled: true,
        isGen1a: false,
        isGen2: true,
        isAntiColl: true,
        writeMode: MifareWriteMode.shadow,
      );

  @override
  Future<Mf1PrngType> getMf1PrngType() async {
    if (failPrngRead) {
      throw StateError('PRNG metadata unavailable');
    }
    return Mf1PrngType.weak;
  }

  @override
  Future<EmulatorSettings> mf0NtagGetEmulatorConfig() async => EmulatorSettings(
        isDetectionEnabled: true,
        isGen1a: false,
        isGen2: true,
        isAntiColl: false,
        writeMode: MifareWriteMode.deceive,
      );

  @override
  Future<Uint8List> mf1GetEmulatorBlock(int startBlock, int blockCount) async {
    classicReadCount++;
    if (!payloadReadStarted.isCompleted) {
      payloadReadStarted.complete();
      await payloadReadGate?.future;
    }
    final length = blockCount * 16 - (shortClassicRead ? 1 : 0);
    return Uint8List.fromList(
      List.generate(length, (index) => startBlock + index),
    );
  }

  @override
  Future<Uint8List> mf0EmulatorReadPages(int from, int count) async {
    return Uint8List.fromList([from, from + 1, from + 2, from + 3]);
  }

  @override
  Future<Uint8List> mf0EmulatorGetVersionData() async =>
      Uint8List.fromList([1, 2, 3]);

  @override
  Future<Uint8List> mf0EmulatorGetSignatureData() async =>
      Uint8List.fromList([4, 5, 6]);

  @override
  Future<(int, bool)> mf0EmulatorGetCounterData(int index) async =>
      (index + 1, ultralightTearingStates[index]);

  @override
  Future<Uint8List> getEM410XEmulatorID() async =>
      Uint8List.fromList([1, 2, 3, 4, 5]);

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {
    events.add('mode:${readerMode ? 'reader' : 'emulator'}');
  }

  @override
  Future<void> setSlotType(int slot, TagType type) async {
    events.add('type:$slot:${type.name}');
  }

  @override
  Future<void> setDefaultDataToSlot(int slot, TagType type) async {
    events.add('default:$slot:${type.name}');
  }

  @override
  Future<void> setMf1AntiCollision(CardData card) async {
    antiCollisionWritten = card;
    events.add('anticollision:${_hex(card.uid)}');
  }

  @override
  Future<void> setMf1BlockData(int startBlock, Uint8List blocks) async {
    events.add('classic:$startBlock:${blocks.length}');
  }

  @override
  Future<void> setMf1DetectionStatus(bool status) async {
    events.add('classic-detection:$status');
  }

  @override
  Future<void> setMf1Gen1aMode(bool enabled) async {
    events.add('classic-gen1a:$enabled');
  }

  @override
  Future<void> setMf1Gen2Mode(bool enabled) async {
    events.add('classic-gen2:$enabled');
  }

  @override
  Future<void> setMf1UseFirstBlockColl(bool enabled) async {
    events.add('classic-block0-collision:$enabled');
  }

  @override
  Future<void> setMf1WriteMode(MifareWriteMode mode) async {
    events.add('classic-write-mode:${mode.name}');
  }

  @override
  Future<void> setMf1PrngType(Mf1PrngType type) async {
    events.add('classic-prng:${type.name}');
  }

  @override
  Future<void> mf0EmulatorWritePages(int from, Uint8List data) async {
    ultralightPagesWritten++;
  }

  @override
  Future<void> mf0EmulatorSetVersionData(Uint8List data) async {
    events.add('ultralight-version:${_hex(data)}');
  }

  @override
  Future<void> mf0EmulatorSetSignatureData(Uint8List data) async {
    events.add('ultralight-signature:${_hex(data)}');
  }

  @override
  Future<void> mf0EmulatorSetCounterData(
    int index,
    int value,
    bool resetTearing,
  ) async {
    events.add('ultralight-counter:$index:$value:$resetTearing');
  }

  @override
  Future<int> mf0ResetAuthCount() async => 0;

  @override
  Future<void> mf0SetMagicMode(bool enabled) async {
    events.add('ultralight-magic:$enabled');
  }

  @override
  Future<void> mf0NtagSetDetectionEnable(bool enabled) async {
    events.add('ultralight-detection:$enabled');
  }

  @override
  Future<void> mf0NtagSetWriteMode(MifareWriteMode mode) async {
    events.add('ultralight-write-mode:${mode.name}');
  }

  @override
  Future<void> setEM410XEmulatorID(Uint8List uid) async {
    events.add('lf:em410X:${_hex(uid)}');
    if (failAfterLfWrite) {
      throw StateError('write response lost');
    }
  }

  @override
  Future<void> setSlotTagName(
    int slot,
    String name,
    TagFrequency frequency,
  ) async {
    events.add('name:$slot:${frequency.name}:$name');
  }

  @override
  Future<void> enableSlot(
    int slot,
    TagFrequency frequency,
    bool status,
  ) async {
    events.add('enable:$slot:${frequency.name}:$status');
  }

  @override
  Future<void> deleteSlotInfo(int index, TagFrequency frequency) async {
    events.add('delete:$index:${frequency.name}');
  }

  @override
  Future<void> saveSlotData() async {
    events.add('save');
  }

  @override
  Future<bool> isReaderDeviceMode() async => false;
}

String _hex(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
