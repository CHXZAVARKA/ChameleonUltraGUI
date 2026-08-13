import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

abstract interface class SlotBackupSaveTarget {
  Future<void> write(Uint8List bytes);
}

abstract interface class SlotBackupFileAdapter {
  Future<SlotBackupSaveTarget?> chooseSaveTarget(String suggestedName);

  Future<Uint8List?> open();
}

final class NativeSlotBackupFileAdapter implements SlotBackupFileAdapter {
  const NativeSlotBackupFileAdapter();

  @override
  Future<SlotBackupSaveTarget?> chooseSaveTarget(String suggestedName) async {
    final directory = await FilePicker.getDirectoryPath();
    return directory == null
        ? null
        : _NativeSlotBackupSaveTarget(path.join(directory, suggestedName));
  }

  @override
  Future<Uint8List?> open() async {
    final picked = await FilePicker.pickFile();
    if (picked == null) {
      return null;
    }
    return picked.readAsBytes();
  }
}

final class _NativeSlotBackupSaveTarget implements SlotBackupSaveTarget {
  const _NativeSlotBackupSaveTarget(this.path);

  final String path;

  @override
  Future<void> write(Uint8List bytes) => File(path).writeAsBytes(bytes);
}

enum SlotBackupExportOutcome {
  saved,
  cancelled,
  unavailable,
  connectionChanged,
}

enum SlotBackupOpenOutcome { ready, cancelled, invalid }

enum SlotBackupRestoreOutcome {
  restored,
  invalid,
  incompatibleDevice,
  incomplete,
  connectionChanged,
  failed,
}

class OpenedSlotBackup {
  const OpenedSlotBackup({required this.outcome, this.backup, this.error});

  final SlotBackupOpenOutcome outcome;
  final SingleSlotBackup? backup;
  final Object? error;
}

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
    required SlotMutationScope mutation,
    required int position,
    required CardSave card,
    required bool enabled,
    required String name,
    SlotEmulatorMetadata? emulator,
    CardData? antiCollision,
    void Function(int progress)? onProgress,
  }) async {
    if (!supports(card.tag)) {
      throw UnsupportedError('Unsupported slot tag type');
    }
    final type = isMifareClassic(card.tag) &&
            chameleonTagSaveCheckForMifareClassicEV1(card)
        ? TagType.mifare2K
        : card.tag;
    final frequency = chameleonTagToFrequency(type);
    await mutation.run(
      (communicator) => communicator.enableSlot(position, frequency, enabled),
    );
    await mutation.run(
      (communicator) => communicator.setSlotType(position, type),
    );
    await mutation.run(
      (communicator) => communicator.setDefaultDataToSlot(position, type),
    );
    if (isMifareClassic(type) || isMifareUltralight(type)) {
      await mutation.run(
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
      onProgress?.call(0);
      final blockCount = mfClassicGetBlockCount(
        chameleonTagTypeGetMfClassicType(type),
      );
      for (var firstBlock = 0; firstBlock < blockCount; firstBlock += 8) {
        final blocks = card.data
            .skip(firstBlock)
            .take(8)
            .where((block) => block.length == 16)
            .expand((block) => block)
            .toList();
        if (blocks.isNotEmpty) {
          await mutation.run(
            (communicator) => communicator.setMf1BlockData(
              firstBlock,
              Uint8List.fromList(blocks),
            ),
          );
        }
        onProgress?.call(
            ((firstBlock + 8).clamp(0, blockCount) / blockCount * 100).round());
      }
      await _restoreClassicSettings(mutation, emulator);
    } else if (isMifareUltralight(type)) {
      onProgress?.call(0);
      final pageCount = mfUltralightGetPagesCount(type);
      for (var page = 0; page < pageCount && page < card.data.length; page++) {
        await mutation.run(
          (communicator) =>
              communicator.mf0EmulatorWritePages(page, card.data[page]),
        );
        onProgress?.call(((page + 1) / pageCount * 100).round());
      }
      if (card.extraData.ultralightVersion.isNotEmpty) {
        await mutation.run(
          (communicator) => communicator.mf0EmulatorSetVersionData(
            card.extraData.ultralightVersion,
          ),
        );
      }
      if (card.extraData.ultralightSignature.isNotEmpty) {
        await mutation.run(
          (communicator) => communicator.mf0EmulatorSetSignatureData(
            card.extraData.ultralightSignature,
          ),
        );
      }
      for (var index = 0;
          index < card.extraData.ultralightCounters.length;
          index++) {
        await mutation.run(
          (communicator) => communicator.mf0EmulatorSetCounterData(
            index,
            card.extraData.ultralightCounters[index],
            true,
          ),
        );
      }
      if (mfUltralightHasCounters(type)) {
        await mutation.run((communicator) => communicator.mf0ResetAuthCount());
      }
      await _restoreUltralightSettings(mutation, emulator);
    } else if (isEM410X(type)) {
      await mutation.run(
        (communicator) => communicator.setEM410XEmulatorID(
          hexToBytes(card.uid),
        ),
      );
    } else if (type == TagType.hidProx) {
      await mutation.run(
        (communicator) => communicator.setHIDProxEmulatorID(
          hexToBytes(HIDCard.fromUID(card.uid).toString()),
        ),
      );
    } else if (type == TagType.viking) {
      await mutation.run(
        (communicator) => communicator.setVikingEmulatorID(
          hexToBytes(card.uid),
        ),
      );
    } else if (type == TagType.pac) {
      await mutation.run(
        (communicator) => communicator.setPacEmulatorID(hexToBytes(card.uid)),
      );
    } else if (type == TagType.ioProx) {
      await mutation.run(
        (communicator) =>
            communicator.setIoProxEmulatorID(hexToBytes(card.uid)),
      );
    } else if (type == TagType.idteck) {
      await mutation.run(
        (communicator) =>
            communicator.setIdteckEmulatorID(hexToBytes(card.uid)),
      );
    }
    await mutation.run(
      (communicator) => communicator.setSlotTagName(position, name, frequency),
    );
    onProgress?.call(100);
  }

  static Future<void> _restoreClassicSettings(
    SlotMutationScope mutation,
    SlotEmulatorMetadata? emulator,
  ) async {
    if (emulator == null) {
      return;
    }
    await mutation.run(
      (communicator) =>
          communicator.setMf1DetectionStatus(emulator.detectionEnabled),
    );
    await mutation.run(
      (communicator) => communicator.setMf1Gen1aMode(emulator.gen1aEnabled),
    );
    await mutation.run(
      (communicator) =>
          communicator.setMf1Gen2Mode(emulator.gen2OrMagicEnabled),
    );
    await mutation.run(
      (communicator) => communicator.setMf1UseFirstBlockColl(
        emulator.useFirstBlockCollision,
      ),
    );
    await mutation.run(
      (communicator) => communicator.setMf1WriteMode(emulator.writeMode),
    );
    if (emulator.prngType != null) {
      await mutation.run(
        (communicator) => communicator.setMf1PrngType(emulator.prngType!),
      );
    }
  }

  static Future<void> _restoreUltralightSettings(
    SlotMutationScope mutation,
    SlotEmulatorMetadata? emulator,
  ) async {
    if (emulator == null) {
      return;
    }
    await mutation.run(
      (communicator) =>
          communicator.mf0SetMagicMode(emulator.gen2OrMagicEnabled),
    );
    await mutation.run(
      (communicator) => communicator.mf0NtagSetDetectionEnable(
        emulator.detectionEnabled,
      ),
    );
    await mutation.run(
      (communicator) => communicator.mf0NtagSetWriteMode(emulator.writeMode),
    );
  }
}

class SingleSlotBackupWorkflow {
  const SingleSlotBackupWorkflow({required this.files});

  final SlotBackupFileAdapter files;

  Future<SlotBackupExportOutcome> export({
    required ConnectedDeviceStatus status,
    required int position,
  }) async {
    if (position < 0 || position >= 8) {
      return SlotBackupExportOutcome.unavailable;
    }
    final target = await files.chooseSaveTarget('slot-${position + 1}.json');
    if (target == null) {
      return SlotBackupExportOutcome.cancelled;
    }
    try {
      final backup = await capture(status: status, position: position);
      if (backup == null) {
        return SlotBackupExportOutcome.connectionChanged;
      }
      await target.write(
        Uint8List.fromList(utf8.encode(SingleSlotBackupCodec.encode(backup))),
      );
      return SlotBackupExportOutcome.saved;
    } on SlotMutationConnectionChanged {
      return SlotBackupExportOutcome.connectionChanged;
    }
  }

  Future<OpenedSlotBackup> open() async {
    final bytes = await files.open();
    if (bytes == null) {
      return const OpenedSlotBackup(outcome: SlotBackupOpenOutcome.cancelled);
    }
    try {
      return OpenedSlotBackup(
        outcome: SlotBackupOpenOutcome.ready,
        backup: SingleSlotBackupCodec.decode(utf8.decode(bytes)),
      );
    } catch (error) {
      return OpenedSlotBackup(
        outcome: SlotBackupOpenOutcome.invalid,
        error: error,
      );
    }
  }

  Future<SingleSlotBackup?> capture({
    required ConnectedDeviceStatus status,
    required int position,
    DateTime Function() clock = DateTime.now,
  }) async {
    if (position < 0 || position >= 8 || !status.isCurrentSession) {
      return null;
    }
    final sourceDevice = status.snapshot.identity.device;
    return status.mutateSlots((mutation) async {
      final metadata = await _readMetadata(mutation, position);
      if (!metadata.hasAnyCurrentValue) {
        return SingleSlotBackup(
          sourceDevice: sourceDevice,
          sourcePosition: position,
          createdAt: clock(),
          hf: const SlotFrequencyBackup.unavailable(
            frequency: TagFrequency.hf,
          ),
          lf: const SlotFrequencyBackup.unavailable(
            frequency: TagFrequency.lf,
          ),
        );
      }
      await mutation.run((communicator) => communicator.activateSlot(position));
      final hf = await _captureFrequency(
        mutation,
        TagFrequency.hf,
        metadata.hf,
      );
      final lf = await _captureFrequency(
        mutation,
        TagFrequency.lf,
        metadata.lf,
      );
      return SingleSlotBackup(
        sourceDevice: sourceDevice,
        sourcePosition: position,
        createdAt: clock(),
        hf: hf,
        lf: lf,
      );
    });
  }

  Future<SlotBackupRestoreOutcome> restore({
    required ConnectedDeviceStatus status,
    required SingleSlotBackup backup,
    required int targetPosition,
  }) async {
    try {
      SingleSlotBackupCodec.decode(SingleSlotBackupCodec.encode(backup));
    } on FormatException {
      return SlotBackupRestoreOutcome.invalid;
    }
    if (targetPosition < 0 || targetPosition >= 8) {
      return SlotBackupRestoreOutcome.invalid;
    }
    if (backup.sourceDevice != status.snapshot.identity.device) {
      return SlotBackupRestoreOutcome.incompatibleDevice;
    }
    if (!backup.isRestorable) {
      return SlotBackupRestoreOutcome.incomplete;
    }
    try {
      await status.mutateSlots((mutation) async {
        await mutation.run(
          (communicator) => communicator.setReaderDeviceMode(false),
        );
        await mutation.run(
          (communicator) => communicator.activateSlot(targetPosition),
        );
        await _restoreFrequency(
          mutation,
          targetPosition,
          backup.hf,
        );
        await _restoreFrequency(
          mutation,
          targetPosition,
          backup.lf,
        );
        await mutation.run((communicator) => communicator.saveSlotData());
      }, reconcileMode: true);
      return SlotBackupRestoreOutcome.restored;
    } on SlotMutationConnectionChanged {
      return SlotBackupRestoreOutcome.connectionChanged;
    } catch (_) {
      return status.isCurrentSession
          ? SlotBackupRestoreOutcome.failed
          : SlotBackupRestoreOutcome.connectionChanged;
    }
  }

  Future<_SlotMetadata> _readMetadata(
    SlotMutationScope mutation,
    int position,
  ) async {
    List<SlotTypes>? types;
    List<EnabledSlotInfo>? enabled;
    List<SlotNames>? names;
    try {
      types =
          await mutation.run((communicator) => communicator.getSlotTagTypes());
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {}
    try {
      enabled =
          await mutation.run((communicator) => communicator.getEnabledSlots());
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {}
    try {
      names =
          await mutation.run((communicator) => communicator.getSlotTagNames());
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {}
    return _SlotMetadata(
      hf: _FrequencyMetadata(
        type: types?[position].hf,
        enabled: enabled?[position].hf,
        name: names?[position].hf,
      ),
      lf: _FrequencyMetadata(
        type: types?[position].lf,
        enabled: enabled?[position].lf,
        name: names?[position].lf,
      ),
    );
  }

  Future<SlotFrequencyBackup> _captureFrequency(
    SlotMutationScope mutation,
    TagFrequency frequency,
    _FrequencyMetadata metadata,
  ) async {
    final type = metadata.type;
    final enabled = metadata.enabled;
    final name = metadata.name;
    if (type == null && enabled == null && name == null) {
      return SlotFrequencyBackup.unavailable(frequency: frequency);
    }
    if (type == null || enabled == null || name == null) {
      return SlotFrequencyBackup.partial(
        frequency: frequency,
        type: type,
        enabled: enabled,
        name: name,
      );
    }
    if (type == TagType.unknown) {
      return SlotFrequencyBackup.empty(
        frequency: frequency,
        enabled: enabled,
        name: name,
      );
    }
    if (!_isSupported(type)) {
      return SlotFrequencyBackup.unsupported(
        frequency: frequency,
        type: type,
        enabled: enabled,
        name: name,
      );
    }
    try {
      final read = await _readPayload(mutation, type);
      final payload = read.payload;
      final complete =
          read.structurallyComplete && _payloadIsComplete(type, payload);
      return complete
          ? SlotFrequencyBackup.complete(
              frequency: frequency,
              type: type,
              enabled: enabled,
              name: name,
              payload: payload,
            )
          : SlotFrequencyBackup.partial(
              frequency: frequency,
              type: type,
              enabled: enabled,
              name: name,
              payload: payload,
            );
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {
      return SlotFrequencyBackup.partial(
        frequency: frequency,
        type: type,
        enabled: enabled,
        name: name,
      );
    }
  }

  Future<_PayloadReadResult> _readPayload(
    SlotMutationScope mutation,
    TagType type,
  ) async {
    if (isMifareClassic(type)) {
      final anticollision = await mutation.run(
        (communicator) => communicator.mf1GetAntiCollData(),
      );
      final settings = await mutation.run(
        (communicator) => communicator.getMf1EmulatorSettings(),
      );
      Mf1PrngType? prngType;
      try {
        prngType = await mutation.run(
          (communicator) => communicator.getMf1PrngType(),
        );
      } on SlotMutationConnectionChanged {
        rethrow;
      } catch (_) {}
      final dump = await readMifareClassicSlotDump(
        blockCount: mfClassicGetBlockCount(
          chameleonTagTypeGetMfClassicType(type),
        ),
        readBlocks: (firstBlock, blockCount) => mutation.run(
          (communicator) => communicator.mf1GetEmulatorBlock(
            firstBlock,
            blockCount,
          ),
        ),
      );
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: anticollision.uid,
          sak: anticollision.sak,
          atqa: anticollision.atqa,
          ats: anticollision.ats,
          data: dump.blocks,
          emulator: SlotEmulatorMetadata(
            detectionEnabled: settings.isDetectionEnabled,
            gen1aEnabled: settings.isGen1a,
            gen2OrMagicEnabled: settings.isGen2,
            useFirstBlockCollision: settings.isAntiColl,
            writeMode: settings.writeMode,
            prngType: prngType,
          ),
        ),
        structurallyComplete: dump.complete,
      );
    }
    if (isMifareUltralight(type)) {
      final anticollision = await mutation.run(
        (communicator) => communicator.mf1GetAntiCollData(),
      );
      final settings = await mutation.run(
        (communicator) => communicator.mf0NtagGetEmulatorConfig(),
      );
      final pages = <Uint8List>[];
      for (var page = 0; page < mfUltralightGetPagesCount(type); page++) {
        pages.add(
          await mutation.run(
            (communicator) => communicator.mf0EmulatorReadPages(page, 1),
          ),
        );
      }
      final counters = <int>[];
      if (mfUltralightHasCounters(type)) {
        for (var index = 0;
            index < mfUltralightGetCounterCount(type);
            index++) {
          counters.add(
            (await mutation.run(
              (communicator) => communicator.mf0EmulatorGetCounterData(index),
            ))
                .$1,
          );
        }
      }
      final version = await mutation.run(
        (communicator) => communicator.mf0EmulatorGetVersionData(),
      );
      final signature = await mutation.run(
        (communicator) => communicator.mf0EmulatorGetSignatureData(),
      );
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: anticollision.uid,
          sak: anticollision.sak,
          atqa: anticollision.atqa,
          ats: anticollision.ats,
          data: pages,
          ultralightVersion: version,
          ultralightSignature: signature,
          ultralightCounters: counters,
          emulator: SlotEmulatorMetadata(
            detectionEnabled: settings.isDetectionEnabled,
            gen1aEnabled: false,
            gen2OrMagicEnabled: settings.isGen2,
            useFirstBlockCollision: false,
            writeMode: settings.writeMode,
          ),
        ),
      );
    }
    if (isEM410X(type)) {
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: await mutation.run(
            (communicator) => communicator.getEM410XEmulatorID(),
          ),
        ),
      );
    }
    if (type == TagType.hidProx) {
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: hexToBytes(
            (await mutation.run(
              (communicator) => communicator.getHIDProxEmulatorID(),
            ))
                .toString(),
          ),
        ),
      );
    }
    if (type == TagType.viking) {
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: (await mutation.run(
            (communicator) => communicator.getVikingEmulatorID(),
          ))
              .uid,
        ),
      );
    }
    if (type == TagType.pac) {
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: (await mutation.run(
            (communicator) => communicator.getPacEmulatorID(),
          ))
              .uid,
        ),
      );
    }
    if (type == TagType.ioProx) {
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: (await mutation.run(
            (communicator) => communicator.getIoProxEmulatorID(),
          ))
              .uid,
        ),
      );
    }
    if (type == TagType.idteck) {
      return _PayloadReadResult(
        payload: SlotCardPayload(
          uid: (await mutation.run(
            (communicator) => communicator.getIdteckEmulatorID(),
          ))
              .uid,
        ),
      );
    }
    throw UnsupportedError('Unsupported slot tag type');
  }

  Future<void> _restoreFrequency(
    SlotMutationScope mutation,
    int position,
    SlotFrequencyBackup frequency,
  ) async {
    if (frequency.state == SlotBackupCompleteness.empty) {
      await mutation.run(
        (communicator) =>
            communicator.deleteSlotInfo(position, frequency.frequency),
      );
      await mutation.run(
        (communicator) => communicator.setSlotTagName(
          position,
          frequency.name!,
          frequency.frequency,
        ),
      );
      await mutation.run(
        (communicator) => communicator.enableSlot(
          position,
          frequency.frequency,
          frequency.enabled!,
        ),
      );
      return;
    }
    final payload = frequency.payload!;
    await SlotPayloadWriter.writeCard(
      mutation: mutation,
      position: position,
      card: CardSave(
        uid: bytesToHexSpace(payload.uid),
        name: frequency.name!,
        tag: frequency.type!,
        sak: payload.sak,
        atqa: payload.atqa,
        ats: payload.ats,
        data: payload.data,
        extraData: CardSaveExtra(
          ultralightVersion: payload.ultralightVersion,
          ultralightSignature: payload.ultralightSignature,
          ultralightCounters: payload.ultralightCounters,
          mifareClassicDumpComplete:
              isMifareClassic(frequency.type!) ? true : null,
        ),
      ),
      enabled: frequency.enabled!,
      name: frequency.name!,
      emulator: payload.emulator,
      antiCollision: chameleonTagToFrequency(frequency.type!) == TagFrequency.hf
          ? CardData(
              uid: payload.uid,
              sak: payload.sak,
              atqa: payload.atqa,
              ats: payload.ats,
            )
          : null,
    );
  }

  bool _payloadIsComplete(TagType type, SlotCardPayload payload) {
    try {
      final frequency = chameleonTagToFrequency(type);
      SingleSlotBackupCodec.encode(
        SingleSlotBackup(
          sourceDevice: ChameleonDevice.ultra,
          sourcePosition: 0,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          hf: frequency == TagFrequency.hf
              ? SlotFrequencyBackup.complete(
                  frequency: frequency,
                  type: type,
                  enabled: true,
                  name: '',
                  payload: payload,
                )
              : SlotFrequencyBackup.empty(
                  frequency: TagFrequency.hf,
                  enabled: false,
                  name: '',
                ),
          lf: frequency == TagFrequency.lf
              ? SlotFrequencyBackup.complete(
                  frequency: frequency,
                  type: type,
                  enabled: true,
                  name: '',
                  payload: payload,
                )
              : SlotFrequencyBackup.empty(
                  frequency: TagFrequency.lf,
                  enabled: false,
                  name: '',
                ),
        ),
      );
      return true;
    } on FormatException {
      return false;
    }
  }

  bool _isSupported(TagType type) => SlotPayloadWriter.supports(type);
}

class _SlotMetadata {
  const _SlotMetadata({required this.hf, required this.lf});

  final _FrequencyMetadata hf;
  final _FrequencyMetadata lf;

  bool get hasAnyCurrentValue => hf.hasAnyValue || lf.hasAnyValue;
}

class _FrequencyMetadata {
  const _FrequencyMetadata({this.type, this.enabled, this.name});

  final TagType? type;
  final bool? enabled;
  final String? name;

  bool get hasAnyValue => type != null || enabled != null || name != null;
}

class _PayloadReadResult {
  const _PayloadReadResult({
    required this.payload,
    this.structurallyComplete = true,
  });

  final SlotCardPayload payload;
  final bool structurallyComplete;
}
