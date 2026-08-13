import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:chameleonultragui/helpers/slot_payload.dart';
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

  Future<SlotPayloadReadResult> _readPayload(
    SlotMutationScope mutation,
    TagType type,
  ) =>
      SlotPayloadReader.read(
        runner: mutation,
        type: type,
        includeEmulatorMetadata: true,
      );

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
      runner: mutation,
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
      ultralightTearingStates: payload.ultralightTearingStates,
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
