import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/slot_command_runner.dart';
import 'package:chameleonultragui/helpers/slot_write_verification.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'support/connected_device_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('post-write comparison', () {
    test('verifies every supported Classic source and storage geometry',
        () async {
      const cases = [
        (TagType.mifareMini, 20, TagType.mifareMini, 20),
        (TagType.mifare1K, 64, TagType.mifare1K, 64),
        (TagType.mifare1K, 72, TagType.mifare2K, 128),
        (TagType.mifare2K, 128, TagType.mifare2K, 128),
        (TagType.mifare4K, 256, TagType.mifare4K, 256),
      ];

      for (final geometryCase in cases) {
        final card = _classicCardFor(
          tag: geometryCase.$1,
          blockCount: geometryCase.$2,
        );
        final communicator = _VerificationCommunicator.fromClassic(
          card,
          targetType: geometryCase.$3,
        );

        final result = await SlotWriteVerifier.verify(
          runner: _Runner(communicator),
          position: 0,
          card: card,
          targetType: geometryCase.$3,
        );

        expect(
          result.outcome,
          SlotWriteVerificationOutcome.verified,
          reason: '${geometryCase.$1.name}:${geometryCase.$2}',
        );
        expect(communicator.classicBlocks, hasLength(geometryCase.$4));
      }
    });

    test('verifies exact Classic metadata, geometry, and payload digest',
        () async {
      final card = _classicCard();
      final communicator = _VerificationCommunicator.fromClassic(card);

      final result = await SlotWriteVerifier.verify(
        runner: _Runner(communicator),
        position: 2,
        card: card,
        targetType: TagType.mifareMini,
      );

      expect(result.outcome, SlotWriteVerificationOutcome.verified);
      expect(communicator.classicReads, 2);
    });

    test('a confirmed Classic metadata or payload difference is a mismatch',
        () async {
      final card = _classicCard();
      final metadataMismatch = _VerificationCommunicator.fromClassic(card)
        ..antiCollision = CardData(
          uid: Uint8List.fromList([9, 8, 7, 6]),
          sak: 0x09,
          atqa: Uint8List.fromList([0, 4]),
          ats: Uint8List(0),
        );
      final metadata = await SlotWriteVerifier.verify(
        runner: _Runner(metadataMismatch),
        position: 0,
        card: card,
        targetType: TagType.mifareMini,
      );
      expect(metadata.outcome, SlotWriteVerificationOutcome.mismatch);
      expect(
        metadata.detail,
        SlotWriteVerificationDetail.anticollisionMismatch,
      );

      final payloadMismatch = _VerificationCommunicator.fromClassic(card);
      payloadMismatch.classicBlocks[10][0] ^= 0xff;
      final payload = await SlotWriteVerifier.verify(
        runner: _Runner(payloadMismatch),
        position: 0,
        card: card,
        targetType: TagType.mifareMini,
      );
      expect(payload.outcome, SlotWriteVerificationOutcome.mismatch);
      expect(payload.detail, SlotWriteVerificationDetail.payloadMismatch);

      final typeMismatch = _VerificationCommunicator.fromClassic(card)
        ..hfType = TagType.mifare1K;
      final type = await SlotWriteVerifier.verify(
        runner: _Runner(typeMismatch),
        position: 0,
        card: card,
        targetType: TagType.mifareMini,
      );
      expect(type.outcome, SlotWriteVerificationOutcome.mismatch);
      expect(type.detail, SlotWriteVerificationDetail.typeMismatch);
    });

    test('checks each Classic anticollision field independently', () async {
      final card = _classicCardFor(
        tag: TagType.mifare1K,
        blockCount: 64,
      );
      for (final field in ['uid', 'sak', 'atqa']) {
        final communicator = _VerificationCommunicator.fromClassic(card);
        final expected = communicator.antiCollision;
        communicator.antiCollision = CardData(
          uid: Uint8List.fromList(expected.uid),
          sak: expected.sak,
          atqa: Uint8List.fromList(expected.atqa),
          ats: Uint8List.fromList(expected.ats),
        );
        switch (field) {
          case 'uid':
            communicator.antiCollision.uid[0] ^= 0xff;
          case 'sak':
            communicator.antiCollision.sak ^= 0xff;
          case 'atqa':
            communicator.antiCollision.atqa[0] ^= 0xff;
        }

        final result = await SlotWriteVerifier.verify(
          runner: _Runner(communicator),
          position: 0,
          card: card,
          targetType: TagType.mifare1K,
        );

        expect(
          result.outcome,
          SlotWriteVerificationOutcome.mismatch,
          reason: field,
        );
        expect(
          result.detail,
          SlotWriteVerificationDetail.anticollisionMismatch,
          reason: field,
        );
      }
    });

    test('EV1 target padding participates in the payload digest', () async {
      final card = _classicCardFor(
        tag: TagType.mifare1K,
        blockCount: 72,
      );
      final communicator = _VerificationCommunicator.fromClassic(
        card,
        targetType: TagType.mifare2K,
      );
      communicator.classicBlocks[90][0] ^= 0xff;

      final result = await SlotWriteVerifier.verify(
        runner: _Runner(communicator),
        position: 0,
        card: card,
        targetType: TagType.mifare2K,
      );

      expect(result.outcome, SlotWriteVerificationOutcome.mismatch);
      expect(result.detail, SlotWriteVerificationDetail.payloadMismatch);
    });

    test('complete target storage cannot mask invalid source geometry',
        () async {
      final card = _classicCardFor(
        tag: TagType.mifare1K,
        blockCount: 71,
      );
      final communicator = _VerificationCommunicator.fromClassic(
        card,
        targetType: TagType.mifare2K,
      );

      final result = await SlotWriteVerifier.verify(
        runner: _Runner(communicator),
        position: 0,
        card: card,
        targetType: TagType.mifare2K,
      );

      expect(result.outcome, SlotWriteVerificationOutcome.incomplete);
      expect(
        result.detail,
        SlotWriteVerificationDetail.expectedGeometryIncomplete,
      );
    });

    test('short and oversized Classic chunks are incomplete, not mismatches',
        () async {
      final card = _classicCard();
      for (final responseDelta in [-1, 1]) {
        final communicator = _VerificationCommunicator.fromClassic(card)
          ..classicResponseDelta = responseDelta;
        final result = await SlotWriteVerifier.verify(
          runner: _Runner(communicator),
          position: 0,
          card: card,
          targetType: TagType.mifareMini,
        );
        expect(
          result.outcome,
          SlotWriteVerificationOutcome.incomplete,
          reason: 'response delta $responseDelta',
        );
        expect(
          result.detail,
          SlotWriteVerificationDetail.deviceGeometryIncomplete,
        );
      }
    });

    test('verifies Ultralight payload and supported metadata', () async {
      final card = _ultralightCard();
      final communicator = _VerificationCommunicator.fromUltralight(card);

      final verified = await SlotWriteVerifier.verify(
        runner: _Runner(communicator),
        position: 0,
        card: card,
        targetType: TagType.ntag210,
      );
      expect(verified.outcome, SlotWriteVerificationOutcome.verified);

      communicator.ultralightSignature = Uint8List.fromList([0xff]);
      final mismatch = await SlotWriteVerifier.verify(
        runner: _Runner(communicator),
        position: 0,
        card: card,
        targetType: TagType.ntag210,
      );
      expect(mismatch.outcome, SlotWriteVerificationOutcome.mismatch);
      expect(mismatch.detail, SlotWriteVerificationDetail.metadataMismatch);
    });

    test('partial Ultralight page geometry is incomplete', () async {
      final card = _ultralightCard();
      final communicator = _VerificationCommunicator.fromUltralight(card)
        ..ultralightResponseDelta = 1;

      final result = await SlotWriteVerifier.verify(
        runner: _Runner(communicator),
        position: 0,
        card: card,
        targetType: TagType.ntag210,
      );

      expect(result.outcome, SlotWriteVerificationOutcome.incomplete);
      expect(
        result.detail,
        SlotWriteVerificationDetail.deviceGeometryIncomplete,
      );
    });

    test('normalizes LF identities using each family wire representation',
        () async {
      final cases = <(TagType, String, Uint8List)>[
        (TagType.em410X, '01 02 03 04 05', Uint8List.fromList([1, 2, 3, 4, 5])),
        (TagType.viking, '01 02 03 04', Uint8List.fromList([1, 2, 3, 4])),
        (
          TagType.pac,
          '01 02 03 04 05 06 07 08',
          Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        ),
        (
          TagType.ioProx,
          '01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10',
          Uint8List.fromList([
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            12,
            13,
            14,
            15,
            16,
          ]),
        ),
        (
          TagType.idteck,
          '01 02 03 04 05 06 07 08',
          Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        ),
        (
          TagType.hidProx,
          '01 00 00 00 02 03 04 05 06 07 08 00 09',
          Uint8List.fromList([1, 0, 0, 0, 2, 3, 4, 5, 6, 7, 8, 0, 9]),
        ),
      ];
      for (final testCase in cases) {
        final communicator = _VerificationCommunicator.fromLf(
          testCase.$1,
          testCase.$3,
        );
        final result = await SlotWriteVerifier.verify(
          runner: _Runner(communicator),
          position: 0,
          card: CardSave(uid: testCase.$2, name: 'LF', tag: testCase.$1),
          targetType: testCase.$1,
        );
        expect(
          result.outcome,
          SlotWriteVerificationOutcome.verified,
          reason: testCase.$1.name,
        );
      }
    });

    test('unavailable reads are unknown and session replacement propagates',
        () async {
      final card = _classicCard();
      final unavailable = _VerificationCommunicator.fromClassic(card)
        ..readFailure = StateError('lost response');
      final unknown = await SlotWriteVerifier.verify(
        runner: _Runner(unavailable),
        position: 0,
        card: card,
        targetType: TagType.mifareMini,
      );
      expect(unknown.outcome, SlotWriteVerificationOutcome.unknown);

      final changed = _Runner(
        _VerificationCommunicator.fromClassic(card),
        changedAfterCommands: 1,
      );
      await expectLater(
        SlotWriteVerifier.verify(
          runner: changed,
          position: 0,
          card: card,
          targetType: TagType.mifareMini,
        ),
        throwsA(isA<_RunnerChanged>()),
      );
    });
  });

  group('Slot Manager upload workflow', () {
    test('verifies a 72-block EV1 source in 128-block target storage',
        () async {
      final card = _classicCardFor(
        tag: TagType.mifare1K,
        blockCount: 72,
      );
      final communicator = _UploadCommunicator();
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);

      final result = await const SlotWriteWorkflow().upload(
        status: fixture.appState.connectedDeviceStatus!,
        position: 2,
        card: card,
        name: card.name,
      );

      expect(result.outcome, SlotWriteVerificationOutcome.verified);
      expect(communicator.types[2].hf, TagType.mifare2K);
      expect(communicator.classicBlocks, hasLength(128));
      expect(
        communicator.classicBlocks
            .take(72)
            .map((block) => block.toList())
            .toList(),
        equals(card.data.map((block) => block.toList()).toList()),
      );
      expect(
        communicator.classicBlocks
            .skip(72)
            .map((block) => block.toList())
            .toList(),
        equals(
          List.generate(
            56,
            (offset) => _defaultClassicBlock(offset + 72).toList(),
          ),
        ),
      );
    });

    testWidgets('shows the localized verification result', (tester) async {
      final communicator = _UploadCommunicator();
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: fixture.appState,
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SlotManagerPage(),
          ),
        ),
      );
      await tester.pump();
      final state = tester.state<SlotManagerPageState>(
        find.byType(SlotManagerPage),
      );

      await state.onTap(
        CardSave(
          uid: '01 02 03 04 05',
          name: 'Door',
          tag: TagType.em410X,
        ),
        (_, __) {},
        AppLocalizations.of(state.context)!,
      );
      await tester.pump();

      expect(find.text('Slot write verified against the device.'), findsOne);
    });

    test('writes, persists, verifies, and reconciles in one foreground lease',
        () async {
      final communicator = _UploadCommunicator();
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.appState.dispose);
      final status = fixture.appState.connectedDeviceStatus!;

      final result = await const SlotWriteWorkflow().upload(
        status: status,
        position: 3,
        card: CardSave(
          uid: '01 02 03 04 05',
          name: 'Door',
          tag: TagType.em410X,
        ),
        name: 'Door',
      );

      expect(result.outcome, SlotWriteVerificationOutcome.verified);
      expect(
        communicator.events,
        containsAllInOrder([
          'mode:false',
          'enable:3:lf:true',
          'activate:3',
          'type:3:em410X',
          'default:3:em410X',
          'write-lf:0102030405',
          'name:3:lf:Door',
          'save',
          'read-types',
          'read-lf',
          'read-types',
          'read-enabled',
          'read-names',
          'read-active',
          'read-mode',
        ]),
      );
      expect(status.snapshot.slots.slots[3].lf.name.value, 'Door');
      expect(status.snapshot.slots.slots[3].lf.type.value, TagType.em410X);
    });

    test('lost and rejected writes are issued once and never auto-rewritten',
        () async {
      for (final failure in [_UploadFailure.write, _UploadFailure.save]) {
        final communicator = _UploadCommunicator(failure: failure);
        final fixture = ConnectedDeviceTestHarness(communicator: communicator);
        addTearDown(fixture.appState.dispose);

        final result = await const SlotWriteWorkflow().upload(
          status: fixture.appState.connectedDeviceStatus!,
          position: 0,
          card: CardSave(
            uid: '01 02 03 04 05',
            name: 'Door',
            tag: TagType.em410X,
          ),
          name: 'Door',
        );

        expect(result.outcome, SlotWriteVerificationOutcome.unknown);
        expect(
          communicator.events.where((event) => event == 'write-lf:0102030405'),
          hasLength(1),
        );
        expect(
          communicator.events.where((event) => event == 'save'),
          failure == _UploadFailure.write ? isEmpty : hasLength(1),
        );
      }
    });

    test('disconnect, DFU, and communicator replacement stop late commands',
        () async {
      for (final transition in _SessionTransition.values) {
        final gate = Completer<void>();
        final communicator = _UploadCommunicator(readGate: gate);
        final fixture = ConnectedDeviceTestHarness(communicator: communicator);
        addTearDown(fixture.appState.dispose);
        final upload = const SlotWriteWorkflow().upload(
          status: fixture.appState.connectedDeviceStatus!,
          position: 0,
          card: CardSave(
            uid: '01 02 03 04 05',
            name: 'Door',
            tag: TagType.em410X,
          ),
          name: 'Door',
        );
        await communicator.readStarted.future;

        switch (transition) {
          case _SessionTransition.disconnect:
            fixture.serial.connected = false;
          case _SessionTransition.dfu:
            fixture.serial.isDFU = true;
          case _SessionTransition.replacement:
            fixture.appState.communicator = _UploadCommunicator();
        }
        gate.complete();

        final result = await upload;
        expect(
          result.outcome,
          SlotWriteVerificationOutcome.connectionChanged,
          reason: transition.name,
        );
        expect(communicator.events, isNot(contains('read-lf')));
      }
    });
  });
}

CardSave _classicCard() => _classicCardFor(
      tag: TagType.mifareMini,
      blockCount: 20,
    );

CardSave _classicCardFor({
  required TagType tag,
  required int blockCount,
}) {
  final card = CardSave(
    uid: '01 02 03 04',
    name: 'Classic',
    tag: tag,
    data: List.generate(
      blockCount,
      (block) => Uint8List.fromList(
        List.generate(16, (offset) => (block * 16 + offset) & 0xff),
      ),
    ),
  );
  final antiCollision = mifareClassicAntiCollisionForCard(card);
  card
    ..sak = antiCollision.sak
    ..atqa = antiCollision.atqa;
  return card;
}

CardSave _ultralightCard() => CardSave(
      uid: '01 02 03 04 05 06 07',
      name: 'NTAG',
      tag: TagType.ntag210,
      sak: 0,
      atqa: Uint8List.fromList([0, 4]),
      data: List.generate(
        20,
        (page) => Uint8List.fromList([page, page, page, page]),
      ),
      extraData: CardSaveExtra(
        ultralightVersion: Uint8List.fromList([1, 2, 3]),
        ultralightSignature: Uint8List.fromList([4, 5, 6]),
        ultralightCounters: const [7],
      ),
    );

final class _RunnerChanged implements SlotCommandRunnerChanged {}

final class _Runner implements SlotCommandRunner {
  _Runner(this.communicator, {this.changedAfterCommands});

  final ChameleonCommunicator communicator;
  final int? changedAfterCommands;
  int commands = 0;

  @override
  Future<T> run<T>(
    Future<T> Function(ChameleonCommunicator communicator) operation,
  ) async {
    if (changedAfterCommands != null && commands >= changedAfterCommands!) {
      throw _RunnerChanged();
    }
    commands++;
    final result = await operation(communicator);
    if (changedAfterCommands != null && commands >= changedAfterCommands!) {
      throw _RunnerChanged();
    }
    return result;
  }
}

class _VerificationCommunicator extends ChameleonCommunicator {
  _VerificationCommunicator() : super(Logger(output: MemoryOutput()));

  factory _VerificationCommunicator.fromClassic(
    CardSave card, {
    TagType? targetType,
  }) {
    final storageType = targetType ?? card.tag;
    final storageBlockCount = mfClassicGetBlockCount(
      chameleonTagTypeGetMfClassicType(storageType),
    );
    final communicator = _VerificationCommunicator()
      ..hfType = storageType
      ..classicBlocks = List.generate(
        storageBlockCount,
        (block) => block < card.data.length
            ? Uint8List.fromList(card.data[block])
            : _defaultClassicBlock(block),
      )
      ..antiCollision = mifareClassicAntiCollisionForCard(card);
    return communicator;
  }

  factory _VerificationCommunicator.fromUltralight(CardSave card) =>
      _VerificationCommunicator()
        ..hfType = card.tag
        ..ultralightPages = card.data.map(Uint8List.fromList).toList()
        ..antiCollision = CardData(
          uid: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
          sak: card.sak,
          atqa: card.atqa,
          ats: card.ats,
        )
        ..ultralightVersion = card.extraData.ultralightVersion
        ..ultralightSignature = card.extraData.ultralightSignature
        ..ultralightCounters = card.extraData.ultralightCounters;

  factory _VerificationCommunicator.fromLf(TagType type, Uint8List identity) =>
      _VerificationCommunicator()
        ..lfType = type
        ..lfIdentity = identity;

  TagType hfType = TagType.unknown;
  TagType lfType = TagType.unknown;
  late CardData antiCollision;
  List<Uint8List> classicBlocks = [];
  List<Uint8List> ultralightPages = [];
  Uint8List ultralightVersion = Uint8List(0);
  Uint8List ultralightSignature = Uint8List(0);
  List<int> ultralightCounters = [];
  Uint8List lfIdentity = Uint8List(0);
  int classicResponseDelta = 0;
  int ultralightResponseDelta = 0;
  Object? readFailure;
  int classicReads = 0;

  void _maybeFail() {
    final failure = readFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    _maybeFail();
    return List.generate(8, (_) => SlotTypes(hf: hfType, lf: lfType));
  }

  @override
  Future<CardData> mf1GetAntiCollData() async {
    _maybeFail();
    return antiCollision;
  }

  @override
  Future<Uint8List> mf1GetEmulatorBlock(int startBlock, int blockCount) async {
    _maybeFail();
    classicReads++;
    final bytes = classicBlocks
        .skip(startBlock)
        .take(blockCount)
        .expand((block) => block)
        .toList();
    if (classicResponseDelta < 0) bytes.removeLast();
    if (classicResponseDelta > 0) bytes.add(0xee);
    return Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> mf0EmulatorReadPages(int from, int count) async {
    _maybeFail();
    final bytes = ultralightPages[from].toList();
    if (ultralightResponseDelta < 0) bytes.removeLast();
    if (ultralightResponseDelta > 0) bytes.add(0xee);
    return Uint8List.fromList(bytes);
  }

  @override
  Future<(int, bool)> mf0EmulatorGetCounterData(int index) async =>
      (ultralightCounters[index], true);

  @override
  Future<Uint8List> mf0EmulatorGetVersionData() async => ultralightVersion;

  @override
  Future<Uint8List> mf0EmulatorGetSignatureData() async => ultralightSignature;

  @override
  Future<Uint8List> getEM410XEmulatorID() async => lfIdentity;

  @override
  Future<HIDCard> getHIDProxEmulatorID() async => HIDCard.fromBytes(lfIdentity);

  @override
  Future<VikingCard> getVikingEmulatorID() async =>
      VikingCard.fromBytes(lfIdentity);

  @override
  Future<PacCard> getPacEmulatorID() async => PacCard.fromBytes(lfIdentity);

  @override
  Future<IoProxCard> getIoProxEmulatorID() async =>
      IoProxCard.fromBytes(lfIdentity);

  @override
  Future<IdteckCard> getIdteckEmulatorID() async =>
      IdteckCard.fromBytes(lfIdentity);
}

enum _UploadFailure { none, write, save }

enum _SessionTransition { disconnect, dfu, replacement }

class _UploadCommunicator extends ChameleonCommunicator {
  _UploadCommunicator({
    this.failure = _UploadFailure.none,
    this.readGate,
  }) : super(Logger(output: MemoryOutput()));

  final _UploadFailure failure;
  final Completer<void>? readGate;
  final Completer<void> readStarted = Completer<void>();
  final List<String> events = [];
  final List<SlotTypes> types = List.generate(8, (_) => SlotTypes());
  final List<EnabledSlotInfo> enabled =
      List.generate(8, (_) => EnabledSlotInfo());
  final List<SlotNames> names = List.generate(8, (_) => SlotNames());
  Uint8List lfIdentity = Uint8List(0);
  CardData antiCollision = CardData(
    uid: Uint8List(0),
    sak: 0,
    atqa: Uint8List(0),
    ats: Uint8List(0),
  );
  List<Uint8List> classicBlocks = [];
  int active = 0;
  bool readerMode = false;

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {
    events.add('mode:$readerMode');
    this.readerMode = readerMode;
  }

  @override
  Future<void> enableSlot(
    int slot,
    TagFrequency frequency,
    bool status,
  ) async {
    events.add('enable:$slot:${frequency.name}:$status');
    if (frequency == TagFrequency.hf) {
      enabled[slot].hf = status;
    } else {
      enabled[slot].lf = status;
    }
  }

  @override
  Future<void> activateSlot(int slot) async {
    events.add('activate:$slot');
    active = slot;
  }

  @override
  Future<void> setSlotType(int slot, TagType type) async {
    events.add('type:$slot:${type.name}');
    if (chameleonTagToFrequency(type) == TagFrequency.hf) {
      types[slot].hf = type;
    } else {
      types[slot].lf = type;
    }
  }

  @override
  Future<void> setDefaultDataToSlot(int slot, TagType type) async {
    events.add('default:$slot:${type.name}');
    if (isMifareClassic(type)) {
      classicBlocks = List.generate(
        mfClassicGetBlockCount(chameleonTagTypeGetMfClassicType(type)),
        _defaultClassicBlock,
      );
    }
  }

  @override
  Future<void> setMf1AntiCollision(CardData card) async {
    antiCollision = card;
  }

  @override
  Future<void> setMf1BlockData(int startBlock, Uint8List blocks) async {
    for (var offset = 0; offset < blocks.length; offset += 16) {
      classicBlocks[startBlock + offset ~/ 16] = Uint8List.fromList(
        blocks.sublist(offset, offset + 16),
      );
    }
  }

  @override
  Future<void> setEM410XEmulatorID(Uint8List uid) async {
    events.add('write-lf:${_hex(uid)}');
    lfIdentity = uid;
    if (failure == _UploadFailure.write) {
      throw StateError('explicit rejection');
    }
  }

  @override
  Future<void> setSlotTagName(
    int index,
    String name,
    TagFrequency frequency,
  ) async {
    events.add('name:$index:${frequency.name}:$name');
    if (frequency == TagFrequency.hf) {
      names[index].hf = name;
    } else {
      names[index].lf = name;
    }
  }

  @override
  Future<void> saveSlotData() async {
    events.add('save');
    if (failure == _UploadFailure.save) {
      throw StateError('lost save response');
    }
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    events.add('read-types');
    if (readGate != null && !readStarted.isCompleted) {
      readStarted.complete();
      await readGate!.future;
    }
    return types;
  }

  @override
  Future<Uint8List> getEM410XEmulatorID() async {
    events.add('read-lf');
    return lfIdentity;
  }

  @override
  Future<CardData> mf1GetAntiCollData() async => antiCollision;

  @override
  Future<Uint8List> mf1GetEmulatorBlock(int startBlock, int blockCount) async =>
      Uint8List.fromList(
        classicBlocks
            .skip(startBlock)
            .take(blockCount)
            .expand((block) => block)
            .toList(),
      );

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    events.add('read-enabled');
    return enabled;
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    events.add('read-names');
    return names;
  }

  @override
  Future<int> getActiveSlot() async {
    events.add('read-active');
    return active;
  }

  @override
  Future<bool> isReaderDeviceMode() async {
    events.add('read-mode');
    return readerMode;
  }
}

Uint8List _defaultClassicBlock(int block) => Uint8List.fromList(
      (block < 128 && block % 4 == 3) || block % 16 == 15
          ? const [
              0xff,
              0xff,
              0xff,
              0xff,
              0xff,
              0xff,
              0xff,
              0x07,
              0x80,
              0x69,
              0xff,
              0xff,
              0xff,
              0xff,
              0xff,
              0xff,
            ]
          : List.filled(16, 0),
    );

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
