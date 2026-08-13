import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/full_device_backup.dart';
import 'package:chameleonultragui/helpers/single_slot_backup_workflow.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';

enum FullDeviceBackupExportOutcome {
  saved,
  cancelled,
  declined,
  unavailable,
  connectionChanged,
  captureFailed,
  writeFailed,
}

enum FullDeviceBackupCaptureOutcome {
  captured,
  unavailable,
  connectionChanged,
  failed,
}

class FullDeviceBackupProgress {
  const FullDeviceBackupProgress({
    required this.currentPosition,
    required this.positions,
  });

  final int currentPosition;
  final List<FullDevicePositionBackup> positions;

  int get completedPositions => positions.length;
  double get fraction => completedPositions / 8;
}

class FullDeviceBackupCaptureResult {
  const FullDeviceBackupCaptureResult({
    required this.outcome,
    this.backup,
  });

  final FullDeviceBackupCaptureOutcome outcome;
  final FullDeviceBackup? backup;
}

typedef FullDeviceBackupApproval = Future<bool> Function(
  FullDeviceBackup backup,
);

typedef FullDeviceBackupProgressCallback = void Function(
  FullDeviceBackupProgress progress,
);

class FullDeviceBackupWorkflow {
  FullDeviceBackupWorkflow({
    required this.files,
    SingleSlotBackupWorkflow? singleSlotWorkflow,
  }) : singleSlotWorkflow =
            singleSlotWorkflow ?? SingleSlotBackupWorkflow(files: files);

  final SlotBackupFileAdapter files;
  final SingleSlotBackupWorkflow singleSlotWorkflow;

  Future<FullDeviceBackupExportOutcome> export({
    required ConnectedDeviceStatus status,
    required FullDeviceBackupApproval approve,
    FullDeviceBackupProgressCallback? onProgress,
    DateTime Function() clock = DateTime.now,
  }) async {
    final SlotBackupSaveTarget? target;
    try {
      target = await files.chooseSaveTarget('chameleon-device-backup.json');
    } catch (_) {
      return FullDeviceBackupExportOutcome.writeFailed;
    }
    if (target == null) {
      return FullDeviceBackupExportOutcome.cancelled;
    }
    final captureResult = await capture(
      status: status,
      onProgress: onProgress,
      clock: clock,
    );
    if (captureResult.outcome != FullDeviceBackupCaptureOutcome.captured ||
        captureResult.backup == null) {
      return switch (captureResult.outcome) {
        FullDeviceBackupCaptureOutcome.unavailable =>
          FullDeviceBackupExportOutcome.unavailable,
        FullDeviceBackupCaptureOutcome.connectionChanged =>
          FullDeviceBackupExportOutcome.connectionChanged,
        FullDeviceBackupCaptureOutcome.failed ||
        FullDeviceBackupCaptureOutcome.captured =>
          FullDeviceBackupExportOutcome.captureFailed,
      };
    }
    if (!await approve(captureResult.backup!)) {
      return FullDeviceBackupExportOutcome.declined;
    }
    try {
      await target.write(
        Uint8List.fromList(
          utf8.encode(FullDeviceBackupCodec.encode(captureResult.backup!)),
        ),
      );
      return FullDeviceBackupExportOutcome.saved;
    } catch (_) {
      return FullDeviceBackupExportOutcome.writeFailed;
    }
  }

  Future<FullDeviceBackupCaptureResult> capture({
    required ConnectedDeviceStatus status,
    FullDeviceBackupProgressCallback? onProgress,
    DateTime Function() clock = DateTime.now,
  }) async {
    if (!status.isCurrentSession) {
      return const FullDeviceBackupCaptureResult(
        outcome: FullDeviceBackupCaptureOutcome.unavailable,
      );
    }
    final device = status.snapshot.identity.device;
    if (device == ChameleonDevice.none) {
      return const FullDeviceBackupCaptureResult(
        outcome: FullDeviceBackupCaptureOutcome.unavailable,
      );
    }
    try {
      final backup = await status.mutateSlots((mutation) async {
        final createdAt = clock();
        final activeSlot = await mutation.run(
          (communicator) => communicator.getActiveSlot(),
        );
        if (activeSlot < 0 || activeSlot >= 8) {
          throw const FormatException('Invalid active slot');
        }
        final readerMode = device == ChameleonDevice.lite
            ? false
            : await mutation.run(
                (communicator) => communicator.isReaderDeviceMode(),
              );
        final firmware = await _readFirmware(mutation);
        final preferences = await _readSafePreferences(mutation);
        final captureSession = await singleSlotWorkflow.beginCapture(
          mutation: mutation,
          sourceDevice: device,
        );
        final positions = <FullDevicePositionBackup>[];
        var positionCaptureStarted = false;
        try {
          for (var position = 0; position < 8; position++) {
            onProgress?.call(
              FullDeviceBackupProgress(
                currentPosition: position,
                positions: List.unmodifiable(positions),
              ),
            );
            positionCaptureStarted = true;
            try {
              final slot = await captureSession.capture(
                position: position,
                createdAt: createdAt,
              );
              positions.add(FullDevicePositionBackup.captured(slot));
            } on SlotMutationConnectionChanged {
              rethrow;
            } catch (_) {
              positions.add(
                FullDevicePositionBackup(
                  slot: captureSession.unavailable(
                    position: position,
                    createdAt: createdAt,
                  ),
                  hfState: FullDeviceCaptureState.failed,
                  lfState: FullDeviceCaptureState.failed,
                ),
              );
            }
          }
        } finally {
          if (positionCaptureStarted && mutation.isCurrent) {
            await mutation.run(
              (communicator) => communicator.activateSlot(activeSlot),
            );
          }
        }
        onProgress?.call(
          FullDeviceBackupProgress(
            currentPosition: 7,
            positions: List.unmodifiable(positions),
          ),
        );
        return FullDeviceBackup(
          sourceDevice: device,
          createdAt: createdAt,
          activeSlot: activeSlot,
          mode: readerMode
              ? FullDeviceOperatingMode.reader
              : FullDeviceOperatingMode.emulator,
          firmware: firmware,
          preferences: preferences,
          positions: positions,
        );
      });
      FullDeviceBackupCodec.decode(FullDeviceBackupCodec.encode(backup));
      return FullDeviceBackupCaptureResult(
        outcome: FullDeviceBackupCaptureOutcome.captured,
        backup: backup,
      );
    } on SlotMutationConnectionChanged {
      return const FullDeviceBackupCaptureResult(
        outcome: FullDeviceBackupCaptureOutcome.connectionChanged,
      );
    } catch (_) {
      return FullDeviceBackupCaptureResult(
        outcome: status.isCurrentSession
            ? FullDeviceBackupCaptureOutcome.failed
            : FullDeviceBackupCaptureOutcome.connectionChanged,
      );
    }
  }

  Future<FullDeviceFirmwareFacts> _readFirmware(
    SlotMutationScope mutation,
  ) async {
    BackupFact<int> version = const BackupFact<int>.failed();
    BackupFact<FullDeviceFirmwareProtocol> protocol =
        const BackupFact<FullDeviceFirmwareProtocol>.failed();
    try {
      final result = await mutation.run(
        (communicator) => communicator.getFirmwareVersion(),
      );
      version = BackupFact<int>.confirmed(result.version);
      protocol = BackupFact<FullDeviceFirmwareProtocol>.confirmed(
        result.legacyProtocol
            ? FullDeviceFirmwareProtocol.legacy
            : FullDeviceFirmwareProtocol.current,
      );
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {}

    BackupFact<String> commit = const BackupFact<String>.failed();
    try {
      final value = await mutation.run(
        (communicator) => communicator.getGitCommitHash(),
      );
      if (_isSafeCommit(value)) {
        commit = BackupFact<String>.confirmed(value);
      }
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {}
    return FullDeviceFirmwareFacts(
      version: version,
      commit: commit,
      protocol: protocol,
    );
  }

  Future<FullDeviceSafePreferences> _readSafePreferences(
    SlotMutationScope mutation,
  ) async {
    List<int>? capabilities;
    try {
      capabilities = await mutation.run(
        (communicator) => communicator.getDeviceCapabilities(),
      );
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {}

    return FullDeviceSafePreferences(
      animationMode: await _readPreference(
        mutation,
        capabilities,
        ChameleonCommand.getAnimationMode,
        (communicator) => communicator.getAnimationMode(),
      ),
      buttonAPress: await _readPreference(
        mutation,
        capabilities,
        ChameleonCommand.getButtonPressConfig,
        (communicator) => communicator.getButtonConfig(ButtonType.a),
      ),
      buttonBPress: await _readPreference(
        mutation,
        capabilities,
        ChameleonCommand.getButtonPressConfig,
        (communicator) => communicator.getButtonConfig(ButtonType.b),
      ),
      buttonALongPress: await _readPreference(
        mutation,
        capabilities,
        ChameleonCommand.getLongButtonPressConfig,
        (communicator) => communicator.getLongButtonConfig(ButtonType.a),
      ),
      buttonBLongPress: await _readPreference(
        mutation,
        capabilities,
        ChameleonCommand.getLongButtonPressConfig,
        (communicator) => communicator.getLongButtonConfig(ButtonType.b),
      ),
      sleepTimeoutSeconds: await _readPreference(
        mutation,
        capabilities,
        ChameleonCommand.getSleepTimeout,
        (communicator) => communicator.getSleepTimeout(),
      ),
    );
  }

  Future<BackupFact<T>> _readPreference<T>(
    SlotMutationScope mutation,
    List<int>? capabilities,
    ChameleonCommand command,
    Future<T> Function(ChameleonCommunicator communicator) read,
  ) async {
    if (capabilities != null && !capabilities.contains(command.value)) {
      return BackupFact<T>.unsupported();
    }
    try {
      return BackupFact<T>.confirmed(
        await mutation.run((communicator) => read(communicator)),
      );
    } on SlotMutationConnectionChanged {
      rethrow;
    } catch (_) {
      return BackupFact<T>.failed();
    }
  }

  bool _isSafeCommit(String value) =>
      value.isNotEmpty &&
      value.length <= 96 &&
      RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(value);
}
