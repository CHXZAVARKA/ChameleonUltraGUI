import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

class MifareClassicSlotDump {
  final List<Uint8List> blocks;
  final bool complete;

  const MifareClassicSlotDump({required this.blocks, required this.complete});
}

Future<MifareClassicSlotDump> readMifareClassicSlotDump({
  required int blockCount,
  required Future<Uint8List> Function(int firstBlock, int blockCount)
  readBlocks,
  int maxBlocksPerRead = 16,
}) async {
  if (blockCount <= 0 || maxBlocksPerRead <= 0) {
    throw ArgumentError('Block counts must be positive');
  }

  final binData = Uint8List(blockCount * 16);
  var complete = true;

  for (
    var firstBlock = 0;
    firstBlock < blockCount;
    firstBlock += maxBlocksPerRead
  ) {
    final remainingBlocks = blockCount - firstBlock;
    final requestedBlocks = remainingBlocks < maxBlocksPerRead
        ? remainingBlocks
        : maxBlocksPerRead;
    final result = await readBlocks(firstBlock, requestedBlocks);
    final expectedLength = requestedBlocks * 16;

    if (result.length != expectedLength) {
      complete = false;
    }

    final copyLength = result.length < expectedLength
        ? result.length
        : expectedLength;
    final destinationOffset = firstBlock * 16;
    binData.setRange(destinationOffset, destinationOffset + copyLength, result);
  }

  final blocks = <Uint8List>[];
  for (var offset = 0; offset < binData.length; offset += 16) {
    blocks.add(Uint8List.fromList(binData.sublist(offset, offset + 16)));
  }

  return MifareClassicSlotDump(blocks: blocks, complete: complete);
}

/// Reads the HF (MIFARE Classic / MIFARE Ultralight) dump from the currently
/// active slot's emulator memory and returns it as a [CardSave].
Future<CardSave> readHfDumpFromSlot(
  ChameleonCommunicator communicator,
  String name,
  TagType tagType, {
  bool Function()? canContinue,
}) async {
  void ensureCurrent() {
    if (canContinue?.call() == false) throw StateError('Slot read cancelled');
  }

  Future<T> read<T>(Future<T> Function() action) async {
    ensureCurrent();
    final value = await action();
    ensureCurrent();
    return value;
  }

  CardData data = await read(communicator.mf1GetAntiCollData);

  if (isMifareUltralight(tagType)) {
    int pageCount = mfUltralightGetPagesCount(tagType);
    List<Uint8List> pages = [];

    for (int page = 0; page < pageCount; page++) {
      final data = await read(() => communicator.mf0EmulatorReadPages(page, 1));
      if (data.length != 4) throw const FormatException('Incomplete slot page');
      pages.add(data);
    }

    CardSaveExtra extraData = CardSaveExtra();

    Uint8List version = await read(communicator.mf0EmulatorGetVersionData);
    if (version.isNotEmpty) {
      extraData.ultralightVersion = version;
    }

    Uint8List signature = await read(communicator.mf0EmulatorGetSignatureData);
    if (signature.isNotEmpty) {
      extraData.ultralightSignature = signature;
    }

    if (mfUltralightHasCounters(tagType)) {
      List<int> counters = [];
      int counterCount = mfUltralightGetCounterCount(tagType);

      for (int i = 0; i < counterCount; i++) {
        var counterData = await read(
          () => communicator.mf0EmulatorGetCounterData(i),
        );
        counters.add(counterData.$1);
      }

      if (counters.isNotEmpty) {
        extraData.ultralightCounters = counters;
      }
    }

    return CardSave(
      uid: bytesToHexSpace(data.uid),
      name: name,
      sak: data.sak,
      atqa: data.atqa,
      ats: data.ats,
      tag: tagType,
      data: pages,
      extraData: extraData,
    );
  } else {
    int blockCount = mfClassicGetBlockCount(
      chameleonTagTypeGetMfClassicType(tagType),
    );

    final dump = await readMifareClassicSlotDump(
      blockCount: blockCount,
      readBlocks: (first, count) =>
          read(() => communicator.mf1GetEmulatorBlock(first, count)),
    );
    if (!dump.complete) {
      throw const FormatException(
        'Incomplete slot dump cannot be edited safely',
      );
    }
    return CardSave(
      uid: bytesToHexSpace(data.uid),
      name: name,
      sak: data.sak,
      atqa: data.atqa,
      ats: data.ats,
      tag: tagType,
      data: dump.blocks,
      extraData: CardSaveExtra(mifareClassicDumpComplete: dump.complete),
    );
  }
}

/// Writes an edited HF (MIFARE Classic / MIFARE Ultralight) dump back into the
/// emulator memory of [slot] and persists it. [onProgress] is called with a
/// value from 0 to 100 while the dump is being uploaded.
Future<void> writeHfDumpToSlot(
  ChameleonCommunicator communicator,
  int slot,
  TagType tagType,
  List<Uint8List> dumpData, {
  void Function(int progress)? onProgress,
  bool Function()? canContinue,
}) async {
  void ensureCurrent() {
    if (canContinue?.call() == false) throw StateError('Slot write cancelled');
  }

  Future<T> write<T>(Future<T> Function() action) async {
    ensureCurrent();
    final value = await action();
    ensureCurrent();
    return value;
  }

  final pageSize = isMifareUltralight(tagType) ? 4 : 16;
  final count = isMifareUltralight(tagType)
      ? mfUltralightGetPagesCount(tagType)
      : mfClassicGetBlockCount(chameleonTagTypeGetMfClassicType(tagType));
  if (dumpData.length != count ||
      dumpData.any((block) => block.length != pageSize)) {
    throw const FormatException(
      'A complete slot dump is required before writing',
    );
  }
  await write(() => communicator.activateSlot(slot));

  if (isMifareUltralight(tagType)) {
    int pageCount = mfUltralightGetPagesCount(tagType);

    for (var page = 0; page < pageCount && dumpData.length > page; page++) {
      await write(
        () => communicator.mf0EmulatorWritePages(page, dumpData[page]),
      );
      onProgress?.call((page / pageCount * 100).round());
      await asyncSleep(1);
    }
  } else {
    int blockCount = mfClassicGetBlockCount(
      chameleonTagTypeGetMfClassicType(tagType),
    );

    List<int> blockChunk = [];
    int lastSend = 0;

    for (var blockOffset = 0; blockOffset < blockCount; blockOffset++) {
      if ((dumpData.length > blockOffset && dumpData[blockOffset].isEmpty) ||
          blockChunk.length >= 128) {
        if (blockChunk.isNotEmpty) {
          await write(
            () => communicator.setMf1BlockData(
              lastSend,
              Uint8List.fromList(blockChunk),
            ),
          );
          blockChunk = [];
          lastSend = blockOffset;
        }
      }

      if (dumpData.length > blockOffset && dumpData[blockOffset].length == 16) {
        blockChunk.addAll(dumpData[blockOffset]);
      }

      onProgress?.call((blockOffset / blockCount * 100).round());
      await asyncSleep(1);
    }

    if (blockChunk.isNotEmpty) {
      await write(
        () => communicator.setMf1BlockData(
          lastSend,
          Uint8List.fromList(blockChunk),
        ),
      );
    }
  }

  onProgress?.call(100);
  await write(communicator.saveSlotData);
}
