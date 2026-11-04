import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/slot_dump.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

class _SlotMemory extends ChameleonCommunicator {
  _SlotMemory() : super(Logger(level: Level.off));
  int chunkLength = 256;
  int pageLength = 4;
  int activated = 0;
  int reads = 0;
  int writes = 0;
  int saved = 0;
  void Function()? afterIdentity;
  void Function()? afterWrite;

  @override
  Future<CardData> mf1GetAntiCollData() async {
    afterIdentity?.call();
    return CardData(
      uid: Uint8List(4),
      sak: 8,
      atqa: Uint8List(2),
      ats: Uint8List(0),
    );
  }

  @override
  Future<Uint8List> mf1GetEmulatorBlock(int startBlock, int blockCount) async {
    reads++;
    return Uint8List(chunkLength);
  }

  @override
  Future<Uint8List> mf0EmulatorReadPages(int from, int count) async {
    reads++;
    return Uint8List(pageLength);
  }

  @override
  Future<void> activateSlot(int slot) async {
    activated++;
  }

  @override
  Future<void> setMf1BlockData(int startBlock, Uint8List blocks) async {
    writes++;
    afterWrite?.call();
  }

  @override
  Future<void> saveSlotData() async {
    saved++;
  }
}

void main() {
  test(
    'short Classic reads cannot become an editable zero-filled dump',
    () async {
      final memory = _SlotMemory()..chunkLength = 255;
      await expectLater(
        readHfDumpFromSlot(memory, 'Card', TagType.mifare1K),
        throwsFormatException,
      );
      expect(memory.writes, 0);
    },
  );

  test('short Ultralight pages cannot become editable memory', () async {
    final memory = _SlotMemory()..pageLength = 3;
    await expectLater(
      readHfDumpFromSlot(memory, 'Card', TagType.ultralight),
      throwsFormatException,
    );
    expect(memory.reads, 1);
  });

  test('incomplete edits fail before selecting or changing any slot', () async {
    final memory = _SlotMemory();
    await expectLater(
      writeHfDumpToSlot(
        memory,
        0,
        TagType.mifare1K,
        List.generate(63, (_) => Uint8List(16)),
      ),
      throwsFormatException,
    );
    expect(memory.activated, 0);
    expect(memory.writes, 0);
    expect(memory.saved, 0);
  });

  test(
    'reconnect after identity read prevents follow-up memory reads',
    () async {
      var current = true;
      final memory = _SlotMemory()..afterIdentity = () => current = false;
      await expectLater(
        readHfDumpFromSlot(
          memory,
          'Card',
          TagType.mifare1K,
          canContinue: () => current,
        ),
        throwsStateError,
      );
      expect(memory.reads, 0);
    },
  );

  test(
    'reconnect during upload stops further writes and persistence',
    () async {
      var current = true;
      final memory = _SlotMemory()..afterWrite = () => current = false;
      await expectLater(
        writeHfDumpToSlot(
          memory,
          0,
          TagType.mifare1K,
          List.generate(64, (_) => Uint8List(16)),
          canContinue: () => current,
        ),
        throwsStateError,
      );
      expect(memory.writes, 1);
      expect(memory.saved, 0);
    },
  );

  test('complete Classic memory is written and persisted once', () async {
    final memory = _SlotMemory();
    await writeHfDumpToSlot(
      memory,
      0,
      TagType.mifare1K,
      List.generate(64, (_) => Uint8List(16)),
    );
    expect(memory.activated, 1);
    expect(memory.writes, 8);
    expect(memory.saved, 1);
  });
}
