import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:chameleonultragui/helpers/slot_command_runner.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

class MifareClassicSlotDump {
  const MifareClassicSlotDump({
    required this.blocks,
    required this.complete,
  });

  final List<Uint8List> blocks;
  final bool complete;
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
  for (var firstBlock = 0;
      firstBlock < blockCount;
      firstBlock += maxBlocksPerRead) {
    final requestedBlocks =
        (blockCount - firstBlock).clamp(0, maxBlocksPerRead);
    final result = await readBlocks(firstBlock, requestedBlocks);
    final expectedLength = requestedBlocks * 16;
    if (result.length != expectedLength) {
      complete = false;
    }
    final copyLength = result.length.clamp(0, expectedLength);
    binData.setRange(
      firstBlock * 16,
      firstBlock * 16 + copyLength,
      result,
    );
  }
  return MifareClassicSlotDump(
    blocks: List.generate(
      blockCount,
      (block) => Uint8List.fromList(
        binData.sublist(block * 16, (block + 1) * 16),
      ),
    ),
    complete: complete,
  );
}

class SlotPayloadReadResult {
  const SlotPayloadReadResult({
    required this.payload,
    this.structurallyComplete = true,
  });

  final SlotCardPayload payload;
  final bool structurallyComplete;

  CardSave toCardSave({required TagType type, required String name}) {
    return CardSave(
      uid: bytesToHexSpace(payload.uid),
      name: name,
      tag: type,
      sak: payload.sak,
      atqa: payload.atqa,
      ats: payload.ats,
      data: payload.data,
      extraData: CardSaveExtra(
        ultralightVersion: payload.ultralightVersion,
        ultralightSignature: payload.ultralightSignature,
        ultralightCounters: payload.ultralightCounters,
        mifareClassicDumpComplete:
            isMifareClassic(type) ? structurallyComplete : null,
      ),
    );
  }
}

abstract final class SlotPayloadReader {
  static bool supports(TagType type) => SlotPayloadWriter.supports(type);

  static Future<SlotPayloadReadResult> read({
    required SlotCommandRunner runner,
    required TagType type,
    bool includeEmulatorMetadata = false,
  }) async {
    if (isMifareClassic(type)) {
      final anticollision = await runner.run(
        (communicator) => communicator.mf1GetAntiCollData(),
      );
      SlotEmulatorMetadata? emulator;
      var metadataComplete = true;
      if (includeEmulatorMetadata) {
        final settings = await runner.run(
          (communicator) => communicator.getMf1EmulatorSettings(),
        );
        Mf1PrngType? prngType;
        try {
          prngType = await runner.run(
            (communicator) => communicator.getMf1PrngType(),
          );
        } on SlotCommandRunnerChanged {
          rethrow;
        } catch (_) {
          metadataComplete = false;
        }
        emulator = SlotEmulatorMetadata(
          detectionEnabled: settings.isDetectionEnabled,
          gen1aEnabled: settings.isGen1a,
          gen2OrMagicEnabled: settings.isGen2,
          useFirstBlockCollision: settings.isAntiColl,
          writeMode: settings.writeMode,
          prngType: prngType,
        );
      }
      final dump = await readMifareClassicSlotDump(
        blockCount: mfClassicGetBlockCount(
          chameleonTagTypeGetMfClassicType(type),
        ),
        readBlocks: (firstBlock, blockCount) => runner.run(
          (communicator) => communicator.mf1GetEmulatorBlock(
            firstBlock,
            blockCount,
          ),
        ),
      );
      return SlotPayloadReadResult(
        payload: SlotCardPayload(
          uid: anticollision.uid,
          sak: anticollision.sak,
          atqa: anticollision.atqa,
          ats: anticollision.ats,
          data: dump.blocks,
          emulator: emulator,
        ),
        structurallyComplete: dump.complete && metadataComplete,
      );
    }
    if (isMifareUltralight(type)) {
      final anticollision = await runner.run(
        (communicator) => communicator.mf1GetAntiCollData(),
      );
      SlotEmulatorMetadata? emulator;
      if (includeEmulatorMetadata) {
        final settings = await runner.run(
          (communicator) => communicator.mf0NtagGetEmulatorConfig(),
        );
        emulator = SlotEmulatorMetadata(
          detectionEnabled: settings.isDetectionEnabled,
          gen1aEnabled: false,
          gen2OrMagicEnabled: settings.isGen2,
          useFirstBlockCollision: false,
          writeMode: settings.writeMode,
        );
      }
      final pages = <Uint8List>[];
      var complete = true;
      for (var page = 0; page < mfUltralightGetPagesCount(type); page++) {
        final data = await runner.run(
          (communicator) => communicator.mf0EmulatorReadPages(page, 1),
        );
        pages.add(data);
        complete = complete && data.length == 4;
      }
      final counters = <int>[];
      final tearingStates = <bool>[];
      if (mfUltralightHasCounters(type)) {
        for (var index = 0;
            index < mfUltralightGetCounterCount(type);
            index++) {
          final counter = await runner.run(
            (communicator) => communicator.mf0EmulatorGetCounterData(index),
          );
          counters.add(counter.$1);
          tearingStates.add(counter.$2);
          complete = complete && counter.$2;
        }
      }
      final version = await runner.run(
        (communicator) => communicator.mf0EmulatorGetVersionData(),
      );
      final signature = await runner.run(
        (communicator) => communicator.mf0EmulatorGetSignatureData(),
      );
      return SlotPayloadReadResult(
        payload: SlotCardPayload(
          uid: anticollision.uid,
          sak: anticollision.sak,
          atqa: anticollision.atqa,
          ats: anticollision.ats,
          data: pages,
          ultralightVersion: version,
          ultralightSignature: signature,
          ultralightCounters: counters,
          ultralightTearingStates: tearingStates,
          emulator: emulator,
        ),
        structurallyComplete: complete,
      );
    }
    return SlotPayloadReadResult(
      payload: SlotCardPayload(uid: await _readLfIdentity(runner, type)),
    );
  }

  static Future<Uint8List> _readLfIdentity(
    SlotCommandRunner runner,
    TagType type,
  ) async {
    if (isEM410X(type)) {
      return runner.run((communicator) => communicator.getEM410XEmulatorID());
    }
    if (type == TagType.hidProx) {
      return hexToBytes(
        (await runner.run(
          (communicator) => communicator.getHIDProxEmulatorID(),
        ))
            .toString(),
      );
    }
    if (type == TagType.viking) {
      return (await runner.run(
        (communicator) => communicator.getVikingEmulatorID(),
      ))
          .uid;
    }
    if (type == TagType.pac) {
      return (await runner.run(
        (communicator) => communicator.getPacEmulatorID(),
      ))
          .uid;
    }
    if (type == TagType.ioProx) {
      return (await runner.run(
        (communicator) => communicator.getIoProxEmulatorID(),
      ))
          .uid;
    }
    if (type == TagType.idteck) {
      return (await runner.run(
        (communicator) => communicator.getIdteckEmulatorID(),
      ))
          .uid;
    }
    throw UnsupportedError('Unsupported slot tag type');
  }
}

abstract final class SlotPayloadWriter {
  static bool supports(TagType type) =>
      isMifareClassic(type) ||
      isMifareUltralight(type) ||
      isEM410X(type) ||
      type == TagType.hidProx ||
      type == TagType.viking ||
      type == TagType.pac ||
      type == TagType.ioProx ||
      type == TagType.idteck;

  static Future<void> writeCard({
    required SlotCommandRunner runner,
    required int position,
    required CardSave card,
    required bool enabled,
    required String name,
    SlotEmulatorMetadata? emulator,
    CardData? antiCollision,
    List<bool>? ultralightTearingStates,
    TagType? targetType,
    bool activateAfterEnable = false,
    void Function(int progress)? onProgress,
  }) async {
    if (!supports(card.tag)) {
      throw UnsupportedError('Unsupported slot tag type');
    }
    final type = targetType ??
        (isMifareClassic(card.tag) &&
                chameleonTagSaveCheckForMifareClassicEV1(card)
            ? TagType.mifare2K
            : card.tag);
    final frequency = chameleonTagToFrequency(type);
    await runner.run(
      (communicator) => communicator.enableSlot(position, frequency, enabled),
    );
    if (activateAfterEnable) {
      await runner.run((communicator) => communicator.activateSlot(position));
    }
    await runner.run(
      (communicator) => communicator.setSlotType(position, type),
    );
    await runner.run(
      (communicator) => communicator.setDefaultDataToSlot(position, type),
    );
    if (isMifareClassic(type) || isMifareUltralight(type)) {
      await runner.run(
        (communicator) => communicator.setMf1AntiCollision(
          antiCollision ??
              (isMifareClassic(type)
                  ? mifareClassicAntiCollisionForCard(card)
                  : CardData(
                      uid: hexToBytes(card.uid),
                      sak: card.sak,
                      atqa: card.atqa,
                      ats: card.ats,
                    )),
        ),
      );
    }
    if (isMifareClassic(type)) {
      await _writeClassic(runner, type, card, onProgress);
      await _restoreClassicSettings(runner, emulator);
    } else if (isMifareUltralight(type)) {
      await _writeUltralight(
        runner,
        type,
        card,
        ultralightTearingStates,
        onProgress,
      );
      await _restoreUltralightSettings(runner, emulator);
    } else {
      await _writeLfIdentity(runner, type, card.uid);
    }
    await runner.run(
      (communicator) => communicator.setSlotTagName(position, name, frequency),
    );
    onProgress?.call(100);
  }

  static Future<void> _writeClassic(
    SlotCommandRunner runner,
    TagType type,
    CardSave card,
    void Function(int progress)? onProgress,
  ) async {
    onProgress?.call(0);
    final blockCount = mfClassicGetBlockCount(
      chameleonTagTypeGetMfClassicType(type),
    );
    var blockChunk = <int>[];
    var lastSend = 0;
    for (var blockOffset = 0; blockOffset < blockCount; blockOffset++) {
      if ((card.data.length > blockOffset && card.data[blockOffset].isEmpty) ||
          blockChunk.length >= 128) {
        if (blockChunk.isNotEmpty) {
          await runner.run(
            (communicator) => communicator.setMf1BlockData(
              lastSend,
              Uint8List.fromList(blockChunk),
            ),
          );
          blockChunk = [];
          lastSend = blockOffset;
        }
      }
      if (card.data.length > blockOffset &&
          card.data[blockOffset].length == 16) {
        blockChunk.addAll(card.data[blockOffset]);
      }
      onProgress?.call((blockOffset / blockCount * 100).round());
    }
    if (blockChunk.isNotEmpty) {
      await runner.run(
        (communicator) => communicator.setMf1BlockData(
          lastSend,
          Uint8List.fromList(blockChunk),
        ),
      );
    }
  }

  static Future<void> _writeUltralight(
    SlotCommandRunner runner,
    TagType type,
    CardSave card,
    List<bool>? tearingStates,
    void Function(int progress)? onProgress,
  ) async {
    onProgress?.call(0);
    final pageCount = mfUltralightGetPagesCount(type);
    for (var page = 0; page < pageCount && page < card.data.length; page++) {
      await runner.run(
        (communicator) => communicator.mf0EmulatorWritePages(
          page,
          card.data[page],
        ),
      );
      onProgress?.call((page / pageCount * 100).round());
    }
    if (card.extraData.ultralightVersion.isNotEmpty) {
      await runner.run(
        (communicator) => communicator.mf0EmulatorSetVersionData(
          card.extraData.ultralightVersion,
        ),
      );
    }
    if (card.extraData.ultralightSignature.isNotEmpty) {
      await runner.run(
        (communicator) => communicator.mf0EmulatorSetSignatureData(
          card.extraData.ultralightSignature,
        ),
      );
    }
    for (var index = 0;
        index < card.extraData.ultralightCounters.length;
        index++) {
      await runner.run(
        (communicator) => communicator.mf0EmulatorSetCounterData(
          index,
          card.extraData.ultralightCounters[index],
          tearingStates?[index] ?? true,
        ),
      );
    }
    if (mfUltralightHasCounters(type)) {
      await runner.run((communicator) => communicator.mf0ResetAuthCount());
    }
  }

  static Future<void> _writeLfIdentity(
    SlotCommandRunner runner,
    TagType type,
    String uid,
  ) async {
    if (isEM410X(type)) {
      await runner.run(
        (communicator) => communicator.setEM410XEmulatorID(hexToBytes(uid)),
      );
    } else if (type == TagType.hidProx) {
      await runner.run(
        (communicator) => communicator.setHIDProxEmulatorID(
          hexToBytes(HIDCard.fromUID(uid).toString()),
        ),
      );
    } else if (type == TagType.viking) {
      await runner.run(
        (communicator) => communicator.setVikingEmulatorID(hexToBytes(uid)),
      );
    } else if (type == TagType.pac) {
      await runner.run(
        (communicator) => communicator.setPacEmulatorID(hexToBytes(uid)),
      );
    } else if (type == TagType.ioProx) {
      await runner.run(
        (communicator) => communicator.setIoProxEmulatorID(hexToBytes(uid)),
      );
    } else if (type == TagType.idteck) {
      await runner.run(
        (communicator) => communicator.setIdteckEmulatorID(hexToBytes(uid)),
      );
    }
  }

  static Future<void> _restoreClassicSettings(
    SlotCommandRunner runner,
    SlotEmulatorMetadata? emulator,
  ) async {
    if (emulator == null) return;
    await runner.run((c) => c.setMf1DetectionStatus(emulator.detectionEnabled));
    await runner.run((c) => c.setMf1Gen1aMode(emulator.gen1aEnabled));
    await runner.run((c) => c.setMf1Gen2Mode(emulator.gen2OrMagicEnabled));
    await runner.run(
      (c) => c.setMf1UseFirstBlockColl(emulator.useFirstBlockCollision),
    );
    await runner.run((c) => c.setMf1WriteMode(emulator.writeMode));
    await runner.run((c) => c.setMf1PrngType(emulator.prngType!));
  }

  static Future<void> _restoreUltralightSettings(
    SlotCommandRunner runner,
    SlotEmulatorMetadata? emulator,
  ) async {
    if (emulator == null) return;
    await runner.run((c) => c.mf0SetMagicMode(emulator.gen2OrMagicEnabled));
    await runner.run(
      (c) => c.mf0NtagSetDetectionEnable(emulator.detectionEnabled),
    );
    await runner.run((c) => c.mf0NtagSetWriteMode(emulator.writeMode));
  }
}
