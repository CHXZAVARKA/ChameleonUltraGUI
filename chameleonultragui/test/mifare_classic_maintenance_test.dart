import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaultKey = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
const _defaultTrailer = [
  ..._defaultKey,
  0xFF,
  0x07,
  0x80,
  0x69,
  ..._defaultKey,
];

List<Uint8List> _blankCard() {
  final blocks = List.generate(256, (_) => Uint8List(16));
  blocks[0].setRange(0, 4, [1, 2, 3, 4]);
  for (var sector = 0; sector < 40; sector++) {
    blocks[mfClassicGetSectorTrailerBlockBySector(sector)] =
        Uint8List.fromList(_defaultTrailer);
  }
  return blocks;
}

Uint8List _image(List<Uint8List> blocks) =>
    Uint8List.fromList(blocks.expand((block) => block).toList());

MifareClassicKeyProfile _profile({
  String? uid,
  bool sectorZeroHasKeyA = true,
  bool sectorZeroHasKeyB = true,
}) =>
    MifareClassicKeyProfile(
      id: 'maintenance-profile',
      name: 'Maintenance profile',
      cardType: 'm4k',
      sectorCount: 40,
      uid: uid,
      assignments: List.generate(
        40,
        (sector) => MifareClassicKeyAssignment(
          sector: sector,
          keyA: sector == 0 && !sectorZeroHasKeyA
              ? null
              : Uint8List.fromList(_defaultKey),
          keyB: sector == 0 && !sectorZeroHasKeyB
              ? null
              : Uint8List.fromList(_defaultKey),
        ),
      ),
    );

class _FakePort implements MifareClassicMaintenancePort {
  final List<Uint8List> blocks;
  final List<int> writes = [];
  Uint8List uid = Uint8List.fromList([1, 2, 3, 4]);
  Uint8List? replacementUid;
  Uint8List? replacementUidAfterWrite;
  int replaceUidAfterReadBlock = -1;
  int replaceUidOnScan = -1;
  int noCardOnScan = -1;
  int scans = 0;
  int authentications = 0;
  int reads = 0;
  int writeCommands = 0;
  bool acknowledgeWithoutWriting = false;
  int writeStatus = 0;
  bool throwAfterWriting = false;
  bool throwOnScan = false;
  bool throwOnReadAfterWrite = false;
  int throwOnReadBlock = -1;
  void Function(int block)? onReadAfterWrite;
  void Function(int block)? onSourceRead;
  int availableBlockCount = 256;
  MifareClassicType type = MifareClassicType.m4k;

  _FakePort(this.blocks);

  void resetCommandCounts() {
    scans = 0;
    authentications = 0;
    reads = 0;
    writeCommands = 0;
  }

  @override
  Future<void> ensureReaderMode() async {}

  @override
  Future<CardData?> scan() async {
    if (throwOnScan) {
      throw StateError('simulated Chameleon disconnect');
    }
    scans++;
    if (noCardOnScan >= 0 && scans >= noCardOnScan) {
      return null;
    }
    final scannedUid = replacementUid != null && scans >= replaceUidOnScan
        ? replacementUid!
        : uid;
    return CardData(
      uid: Uint8List.fromList(scannedUid),
      sak: 0x18,
      atqa: Uint8List.fromList([0x00, 0x02]),
      ats: Uint8List(0),
    );
  }

  @override
  Future<MifareClassicType> detectType() async => type;

  @override
  Future<bool> isBlockAvailable(int block) async => block < availableBlockCount;

  @override
  Future<MifareClassicIoResult> authenticate(
      int block, int keyType, Uint8List key) async {
    authentications++;
    return MifareClassicIoResult(status: block < availableBlockCount ? 0 : 6);
  }

  @override
  Future<MifareClassicIoResult> readBlock(
      int block, int keyType, Uint8List key) async {
    reads++;
    if (block >= availableBlockCount) {
      return MifareClassicIoResult(status: 6);
    }
    if (block == throwOnReadBlock) {
      throw StateError('simulated Chameleon disconnect while reading');
    }
    if (throwOnReadAfterWrite && writes.contains(block)) {
      throw StateError('simulated lost read-back connection');
    }
    if (writes.contains(block)) {
      onReadAfterWrite?.call(block);
    } else {
      onSourceRead?.call(block);
      if (block == replaceUidAfterReadBlock) {
        replacementUid = Uint8List.fromList([9, 9, 9, 9]);
        replaceUidOnScan = scans + 1;
      }
    }
    return MifareClassicIoResult(status: 0, data: blocks[block]);
  }

  @override
  Future<MifareClassicIoResult> writeBlock(
      int block, int keyType, Uint8List key, Uint8List data) async {
    writeCommands++;
    writes.add(block);
    if (!acknowledgeWithoutWriting) {
      blocks[block] = Uint8List.fromList(data);
    }
    if (replacementUidAfterWrite != null) {
      replacementUid = replacementUidAfterWrite;
      replaceUidOnScan = scans + 1;
    }
    if (throwAfterWriting) {
      throw StateError('simulated lost write response');
    }
    return MifareClassicIoResult(status: writeStatus);
  }
}

Future<MifareClassicMaintenanceException> _expectMaintenanceFailure(
    Future<void> Function() action) async {
  try {
    await action();
    fail('Expected MifareClassicMaintenanceException');
  } on MifareClassicMaintenanceException catch (error) {
    return error;
  }
}

void main() {
  test('preflight rejects a non-4096-byte image before card access', () async {
    final port = _FakePort(_blankCard());
    final maintenance = MifareClassicMaintenance(port);

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.preflight(image: Uint8List(4095), profile: _profile());
    });

    expect(error.failure, MifareClassicMaintenanceFailure.invalidImage);
    expect(port.scans, 0);
    expect(port.writes, isEmpty);
  });

  test('Mini preflight plans its 14 writable data blocks only', () async {
    final current = List.generate(20, (_) => Uint8List(16));
    current[0].setRange(0, 4, [1, 2, 3, 4]);
    for (var sector = 0; sector < 5; sector++) {
      current[mfClassicGetSectorTrailerBlockBySector(sector)] =
          Uint8List.fromList(_defaultTrailer);
    }
    final target = current.map(Uint8List.fromList).toList();
    for (var block = 1; block < 20; block++) {
      final sector = mfClassicGetSectorByBlock(block);
      if (block != mfClassicGetSectorTrailerBlockBySector(sector)) {
        target[block] = Uint8List.fromList(List.filled(16, block));
      }
    }
    final profile = MifareClassicKeyProfile(
      id: 'mini-maintenance-profile',
      name: 'Mini maintenance profile',
      cardType: 'mini',
      sectorCount: 5,
      assignments: List.generate(
        5,
        (sector) => MifareClassicKeyAssignment(
          sector: sector,
          keyA: Uint8List.fromList(_defaultKey),
          keyB: Uint8List.fromList(_defaultKey),
        ),
      ),
    );
    final port = _FakePort(current)..type = MifareClassicType.mini;

    final plan = await MifareClassicMaintenance(port)
        .preflight(image: _image(target), profile: profile);

    expect(plan.dataBlockCount, 14);
    expect(plan.changedBlocks, 14);
    expect(plan.plannedBlocks, isNot(contains(0)));
    expect(plan.plannedBlocks, isNot(contains(3)));
    expect(plan.plannedBlocks, isNot(contains(19)));
  });

  test('1K preflight plans its 47 writable data blocks only', () async {
    final current = List.generate(64, (_) => Uint8List(16));
    current[0].setRange(0, 4, [1, 2, 3, 4]);
    for (var sector = 0; sector < 16; sector++) {
      current[mfClassicGetSectorTrailerBlockBySector(sector)] =
          Uint8List.fromList(_defaultTrailer);
    }
    final target = current.map(Uint8List.fromList).toList();
    for (var block = 1; block < 64; block++) {
      final sector = mfClassicGetSectorByBlock(block);
      if (block != mfClassicGetSectorTrailerBlockBySector(sector)) {
        target[block] = Uint8List.fromList(List.filled(16, block));
      }
    }
    final profile = MifareClassicKeyProfile(
      id: '1k-maintenance-profile',
      name: '1K maintenance profile',
      cardType: 'm1k',
      sectorCount: 16,
      assignments: List.generate(
        16,
        (sector) => MifareClassicKeyAssignment(
          sector: sector,
          keyA: Uint8List.fromList(_defaultKey),
          keyB: Uint8List.fromList(_defaultKey),
        ),
      ),
    );
    final port = _FakePort(current)
      ..type = MifareClassicType.m1k
      ..availableBlockCount = 64;

    final plan = await MifareClassicMaintenance(port)
        .preflight(image: _image(target), profile: profile);

    expect(plan.dataBlockCount, 47);
    expect(plan.changedBlocks, 47);
    expect(plan.plannedBlocks, isNot(contains(0)));
    expect(plan.plannedBlocks, isNot(contains(3)));
    expect(plan.plannedBlocks, isNot(contains(63)));
  });

  test('ordinary 1K preflight rejects a 1K EV1 card', () async {
    final ev1Card = List.generate(72, (_) => Uint8List(16));
    ev1Card[0].setRange(0, 4, [1, 2, 3, 4]);
    for (var sector = 0; sector < 18; sector++) {
      ev1Card[mfClassicGetSectorTrailerBlockBySector(sector)] =
          Uint8List.fromList(_defaultTrailer);
    }
    final oneKilobyteImage = _image(ev1Card.sublist(0, 64));
    final port = _FakePort(ev1Card)
      ..type = MifareClassicType.m1k
      ..availableBlockCount = 72;
    final profile = MifareClassicKeyProfile(
      id: 'ordinary-1k-on-ev1-profile',
      name: 'Ordinary 1K profile',
      cardType: 'm1k',
      sectorCount: 16,
      assignments: List.generate(
        16,
        (sector) => MifareClassicKeyAssignment(
          sector: sector,
          keyA: Uint8List.fromList(_defaultKey),
          keyB: Uint8List.fromList(_defaultKey),
        ),
      ),
    );

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port)
          .preflight(image: oneKilobyteImage, profile: profile);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.wrongCardType);
    expect(port.writes, isEmpty);
  });

  test('1K EV1 preflight requires 18 sectors and plans 53 data blocks',
      () async {
    final current = List.generate(72, (_) => Uint8List(16));
    current[0].setRange(0, 4, [1, 2, 3, 4]);
    for (var sector = 0; sector < 18; sector++) {
      current[mfClassicGetSectorTrailerBlockBySector(sector)] =
          Uint8List.fromList(_defaultTrailer);
    }
    final target = current.map(Uint8List.fromList).toList();
    for (var block = 1; block < 72; block++) {
      final sector = mfClassicGetSectorByBlock(block);
      if (block != mfClassicGetSectorTrailerBlockBySector(sector)) {
        target[block] = Uint8List.fromList(List.filled(16, block));
      }
    }
    final profile = MifareClassicKeyProfile(
      id: '1k-ev1-maintenance-profile',
      name: '1K EV1 maintenance profile',
      cardType: 'm1k',
      sectorCount: 18,
      assignments: List.generate(
        18,
        (sector) => MifareClassicKeyAssignment(
          sector: sector,
          keyA: Uint8List.fromList(_defaultKey),
          keyB: Uint8List.fromList(_defaultKey),
        ),
      ),
    );
    final port = _FakePort(current)..type = MifareClassicType.m1k;

    final plan = await MifareClassicMaintenance(port)
        .preflight(image: _image(target), profile: profile);

    expect(plan.dataBlockCount, 53);
    expect(plan.changedBlocks, 53);
    expect(plan.plannedBlocks, isNot(contains(0)));
    expect(plan.plannedBlocks, isNot(contains(67)));
    expect(plan.plannedBlocks, isNot(contains(71)));
  });

  test('2K preflight plans its 95 writable data blocks only', () async {
    final current = List.generate(128, (_) => Uint8List(16));
    current[0].setRange(0, 4, [1, 2, 3, 4]);
    for (var sector = 0; sector < 32; sector++) {
      current[mfClassicGetSectorTrailerBlockBySector(sector)] =
          Uint8List.fromList(_defaultTrailer);
    }
    final target = current.map(Uint8List.fromList).toList();
    for (var block = 1; block < 128; block++) {
      final sector = mfClassicGetSectorByBlock(block);
      if (block != mfClassicGetSectorTrailerBlockBySector(sector)) {
        target[block] = Uint8List.fromList(List.filled(16, block));
      }
    }
    final profile = MifareClassicKeyProfile(
      id: '2k-maintenance-profile',
      name: '2K maintenance profile',
      cardType: 'm2k',
      sectorCount: 32,
      assignments: List.generate(
        32,
        (sector) => MifareClassicKeyAssignment(
          sector: sector,
          keyA: Uint8List.fromList(_defaultKey),
          keyB: Uint8List.fromList(_defaultKey),
        ),
      ),
    );
    final port = _FakePort(current)..type = MifareClassicType.m2k;

    final plan = await MifareClassicMaintenance(port)
        .preflight(image: _image(target), profile: profile);

    expect(plan.dataBlockCount, 95);
    expect(plan.changedBlocks, 95);
    expect(plan.plannedBlocks, isNot(contains(0)));
    expect(plan.plannedBlocks, isNot(contains(3)));
    expect(plan.plannedBlocks, isNot(contains(127)));
  });

  test('preflight plans and verifies all 215 data blocks only', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    for (var block = 1; block < 256; block++) {
      final sector = mfClassicGetSectorByBlock(block);
      if (block != mfClassicGetSectorTrailerBlockBySector(sector)) {
        target[block] = Uint8List.fromList(List.filled(16, block));
      }
    }
    // Trailer contents in the target are intentionally ignored.
    target[255] = Uint8List.fromList(List.filled(16, 0x12));

    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    expect(plan.changedBlocks, 215);
    final plannedBlocks = plan.plannedBlocks;
    expect(plannedBlocks, containsAll([1, 126, 128, 142, 144, 254]));
    expect(plannedBlocks, isNot(contains(0)));
    expect(plannedBlocks, isNot(contains(127)));
    expect(plannedBlocks, isNot(contains(143)));
    expect(plannedBlocks, isNot(contains(255)));

    final report = await maintenance.execute(plan);

    expect(report.writtenBlocks, 215);
    expect(report.verifiedBlocks, 215);
    expect(port.writes, orderedEquals(plannedBlocks));
  });

  test('execute keeps a fully changed 4K card within its RF command budget',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    for (var block = 1; block < 256; block++) {
      final sector = mfClassicGetSectorByBlock(block);
      if (block != mfClassicGetSectorTrailerBlockBySector(sector)) {
        target[block] = Uint8List.fromList(List.filled(16, block));
      }
    }
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.resetCommandCounts();

    final report = await maintenance.execute(plan);

    expect(report.writtenBlocks, 215);
    expect(report.verifiedBlocks, 215);
    expect(port.reads, 431);
    expect(port.authentications, 1);
    expect(port.writeCommands, 215);
    expect(port.scans, 472);
  });

  test('block 0 must exactly match even when the UID prefix matches', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[0][4] = 0x99;
    final port = _FakePort(current);

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port)
          .preflight(image: _image(target), profile: _profile());
    });

    expect(error.failure, MifareClassicMaintenanceFailure.identityMismatch);
    expect(error.block, 0);
    expect(port.writes, isEmpty);
  });

  test('invalid current access bits abort before the first write', () async {
    final current = _blankCard();
    current[3].setRange(6, 9, [0, 0, 0]);
    final port = _FakePort(current);

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port)
          .preflight(image: _image(current), profile: _profile());
    });

    expect(error.failure, MifareClassicMaintenanceFailure.invalidAccessBits);
    expect(port.writes, isEmpty);
  });

  test(
      'preflight accepts an unchanged Key A-readable block without write access',
      () async {
    final current = _blankCard();
    // Valid access bytes for block 1 C1/C2/C3 = 010: read A/B, write never.
    current[3].setRange(6, 9, [0xDF, 0x0F, 0x02]);
    final port = _FakePort(current);

    final plan = await MifareClassicMaintenance(port).preflight(
      image: _image(current),
      profile: _profile(sectorZeroHasKeyB: false),
    );

    expect(plan.changedBlocks, 0);
    expect(plan.unchangedBlocks, 215);
    expect(port.writes, isEmpty);
  });

  test('preflight rejects a changed Key A-readable block without write access',
      () async {
    final current = _blankCard();
    // Valid access bytes for block 1 C1/C2/C3 = 010: read A/B, write never.
    current[3].setRange(6, 9, [0xDF, 0x0F, 0x02]);
    final target = current.map(Uint8List.fromList).toList();
    target[1][0] = 0xA1;
    final port = _FakePort(current);

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port).preflight(
        image: _image(target),
        profile: _profile(sectorZeroHasKeyB: false),
      );
    });

    expect(error.failure, MifareClassicMaintenanceFailure.writeNotAllowed);
    expect(error.sector, 0);
    expect(error.block, 1);
    expect(port.writes, isEmpty);
  });

  test(
      'preflight accepts an unchanged Key B-readable block without write access',
      () async {
    final current = _blankCard();
    // Valid access bytes: block 1 is C1/C2/C3 = 101 (read B, write never),
    // and the trailer is 001 so its access bits are readable with Key B.
    current[3].setRange(6, 9, [0xF5, 0xAD, 0x20]);
    final port = _FakePort(current);

    final plan = await MifareClassicMaintenance(port).preflight(
      image: _image(current),
      profile: _profile(sectorZeroHasKeyA: false),
    );

    expect(plan.changedBlocks, 0);
    expect(plan.unchangedBlocks, 215);
    expect(port.writes, isEmpty);
  });

  test('preflight rejects a changed Key B-readable block without write access',
      () async {
    final current = _blankCard();
    // Valid access bytes: block 1 is C1/C2/C3 = 101 (read B, write never),
    // and the trailer is 001 so its access bits are readable with Key B.
    current[3].setRange(6, 9, [0xF5, 0xAD, 0x20]);
    final target = current.map(Uint8List.fromList).toList();
    target[1][0] = 0xB1;
    final port = _FakePort(current);

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port).preflight(
        image: _image(target),
        profile: _profile(sectorZeroHasKeyA: false),
      );
    });

    expect(error.failure, MifareClassicMaintenanceFailure.writeNotAllowed);
    expect(error.sector, 0);
    expect(error.block, 1);
    expect(port.writes, isEmpty);
  });

  test('a UID change during preflight aborts before writing', () async {
    final current = _blankCard();
    final port = _FakePort(current)
      ..replacementUid = Uint8List.fromList([9, 9, 9, 9])
      ..replaceUidOnScan = 2;

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port)
          .preflight(image: _image(current), profile: _profile());
    });

    expect(error.failure, MifareClassicMaintenanceFailure.identityMismatch);
    expect(port.writes, isEmpty);
  });

  test('a card swap during the last preflight sector cannot produce a plan',
      () async {
    final current = _blankCard();
    final port = _FakePort(current)..replaceUidAfterReadBlock = 254;

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port)
          .preflight(image: _image(current), profile: _profile());
    });

    expect(error.failure, MifareClassicMaintenanceFailure.identityMismatch);
    expect(port.writes, isEmpty);
  });

  test('a Chameleon disconnect during preflight is reported without writing',
      () async {
    final port = _FakePort(_blankCard())..throwOnScan = true;

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port)
          .preflight(image: _image(_blankCard()), profile: _profile());
    });

    expect(error.failure, MifareClassicMaintenanceFailure.communicationLost);
    expect(port.writes, isEmpty);
  });

  test('a profile UID mismatch aborts before sector authentication', () async {
    final current = _blankCard();
    final port = _FakePort(current);

    final error = await _expectMaintenanceFailure(() async {
      await MifareClassicMaintenance(port).preflight(
        image: _image(current),
        profile: _profile(uid: '09090909'),
      );
    });

    expect(error.failure, MifareClassicMaintenanceFailure.incompatibleProfile);
    expect(port.writes, isEmpty);
  });

  test('execute rechecks 4K card type before the first write', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x33));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.type = MifareClassicType.m1k;

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.wrongCardType);
    expect(port.writes, isEmpty);
  });

  test('execute distinguishes 1K EV1 from an ordinary 1K before writing',
      () async {
    final current = List.generate(72, (_) => Uint8List(16));
    current[0].setRange(0, 4, [1, 2, 3, 4]);
    for (var sector = 0; sector < 18; sector++) {
      current[mfClassicGetSectorTrailerBlockBySector(sector)] =
          Uint8List.fromList(_defaultTrailer);
    }
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x35));
    final profile = MifareClassicKeyProfile(
      id: '1k-ev1-execute-profile',
      name: '1K EV1 execute profile',
      cardType: 'm1k',
      sectorCount: 18,
      assignments: List.generate(
        18,
        (sector) => MifareClassicKeyAssignment(
          sector: sector,
          keyA: Uint8List.fromList(_defaultKey),
          keyB: Uint8List.fromList(_defaultKey),
        ),
      ),
    );
    final port = _FakePort(current)..type = MifareClassicType.m1k;
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: profile);
    port.availableBlockCount = 64;

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.wrongCardType);
    expect(port.writes, isEmpty);
  });

  test('execute rechecks the full manufacturer block after preflight',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x34));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.blocks[0][4] = 0x99;

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.identityMismatch);
    expect(error.block, 0);
    expect(port.writes, isEmpty);
  });

  test('a maintenance plan can be executed only once', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x3A));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    await maintenance.execute(plan);

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.stalePlan);
    expect(port.writes, [1]);
  });

  test('a maintenance plan cannot be moved to another device port', () async {
    final firstCard = _blankCard();
    final target = firstCard.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x3D));
    final firstMaintenance = MifareClassicMaintenance(_FakePort(firstCard));
    final plan = await firstMaintenance.preflight(
        image: _image(target), profile: _profile());
    final secondPort = _FakePort(_blankCard());
    final secondMaintenance = MifareClassicMaintenance(secondPort);

    final error = await _expectMaintenanceFailure(() async {
      await secondMaintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.stalePlan);
    expect(secondPort.writes, isEmpty);
  });

  test('execute rejects a plan when a source block changed after preflight',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x3B));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.blocks[1] = Uint8List.fromList(List.filled(16, 0x3C));

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.stalePlan);
    expect(error.block, 1);
    expect(port.blocks[1], orderedEquals(List.filled(16, 0x3C)));
    expect(port.writes, isEmpty);
  });

  test('execute revalidates the last source block before the first write',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x3C));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.blocks[254] = Uint8List.fromList(List.filled(16, 0x3D));

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.stalePlan);
    expect(error.block, 254);
    expect(port.writes, isEmpty);
  });

  test('execute revalidates blocks that already matched during preflight',
      () async {
    final current = _blankCard();
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan = await maintenance.preflight(
        image: _image(current), profile: _profile());
    port.blocks[1] = Uint8List.fromList(List.filled(16, 0x3E));

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.stalePlan);
    expect(error.block, 1);
    expect(error.verifiedBlocks, 0);
    expect(port.writes, isEmpty);
  });

  test('disconnect during revalidation is typed before any write', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[2] = Uint8List.fromList(List.filled(16, 0x3F));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.throwOnReadBlock = 1;

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.communicationLost);
    expect(error.block, 1);
    expect(error.verifiedBlocks, 0);
    expect(error.writeOutcome, MifareClassicWriteOutcome.notAttempted);
    expect(port.writes, isEmpty);
  });

  test('cancellation stops execute before the next destructive block',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x44));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan, shouldCancel: () => true);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.cancelled);
    expect(port.writes, isEmpty);
  });

  test('card loss between blocks reports the last verified state', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x51));
    target[2] = Uint8List.fromList(List.filled(16, 0x52));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.onReadAfterWrite = (block) {
      if (block == 1) {
        port.noCardOnScan = port.scans + 1;
      }
    };

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.noCard);
    expect(error.block, 2);
    expect(error.verifiedBlocks, 1);
    expect(error.toString(), contains('1 block verified'));
    expect(port.blocks[1], orderedEquals(target[1]));
    expect(port.blocks[2], isNot(orderedEquals(target[2])));
  });

  test('cancellation after one verified block stops before the next write',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x53));
    target[2] = Uint8List.fromList(List.filled(16, 0x54));
    var cancelled = false;
    final port = _FakePort(current)
      ..onReadAfterWrite = (block) {
        if (block == 1) {
          cancelled = true;
        }
      };
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan, shouldCancel: () => cancelled);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.cancelled);
    expect(error.block, 2);
    expect(error.verifiedBlocks, 1);
    expect(port.blocks[1], orderedEquals(target[1]));
    expect(port.blocks[2], isNot(orderedEquals(target[2])));
  });

  test('cancellation during common revalidation stops before any write',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x55));
    var cancelled = false;
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());
    port.onSourceRead = (block) {
      if (block == 1) {
        cancelled = true;
      }
    };

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan, shouldCancel: () => cancelled);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.cancelled);
    expect(error.block, 1);
    expect(error.verifiedBlocks, 0);
    expect(port.blocks[1], isNot(orderedEquals(target[1])));
    expect(port.writes, isEmpty);
  });

  test('read-back resolves a lost or negative write response', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x45));
    final port = _FakePort(current)..writeStatus = 0x06;
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    final report = await maintenance.execute(plan);

    expect(report.writtenBlocks, 1);
    expect(report.verifiedBlocks, 1);
    expect(port.blocks[1], orderedEquals(target[1]));
  });

  test('a progress callback cannot interrupt read-back after a write',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x46));
    final port = _FakePort(current);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    final report = await maintenance.execute(
      plan,
      onProgress: (progress) {
        if (progress.phase == MifareClassicMaintenancePhase.verifying) {
          throw StateError('simulated disposed UI callback');
        }
      },
    );

    expect(report.writtenBlocks, 1);
    expect(report.verifiedBlocks, 1);
    expect(port.blocks[1], orderedEquals(target[1]));
  });

  test('lost write response and read-back reports an unknown write outcome',
      () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x47));
    final port = _FakePort(current)
      ..throwAfterWriting = true
      ..throwOnReadAfterWrite = true;
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.communicationLost);
    expect(error.writeOutcome, MifareClassicWriteOutcome.unknown);
    expect(error.block, 1);
    expect(error.verifiedBlocks, 0);
    expect(error.toString(), contains('0 blocks verified'));
    expect(error.toString(), contains('write outcome unknown'));
    expect(port.writes, [1]);
  });

  test('a card swap after write cannot be accepted by read-back', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x48));
    final port = _FakePort(current)
      ..replacementUidAfterWrite = Uint8List.fromList([9, 9, 9, 9]);
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.identityMismatch);
    expect(error.writeOutcome, MifareClassicWriteOutcome.unknown);
    expect(error.block, 1);
    expect(error.verifiedBlocks, 0);
    expect(port.writes, [1]);
  });

  test('a write ACK with stale read-back aborts verification', () async {
    final current = _blankCard();
    final target = current.map(Uint8List.fromList).toList();
    target[1] = Uint8List.fromList(List.filled(16, 0x5A));
    final port = _FakePort(current)..acknowledgeWithoutWriting = true;
    final maintenance = MifareClassicMaintenance(port);
    final plan =
        await maintenance.preflight(image: _image(target), profile: _profile());

    final error = await _expectMaintenanceFailure(() async {
      await maintenance.execute(plan);
    });

    expect(error.failure, MifareClassicMaintenanceFailure.verificationFailed);
    expect(error.block, 1);
    expect(port.writes, [1]);
  });
}
