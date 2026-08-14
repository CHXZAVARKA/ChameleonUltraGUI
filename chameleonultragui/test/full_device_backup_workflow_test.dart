import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/full_device_backup.dart';
import 'package:chameleonultragui/helpers/full_device_backup_workflow.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:chameleonultragui/helpers/single_slot_backup_workflow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

import 'support/connected_device_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('full-device backup workflow', () {
    test(
        'captures all positions and safe device facts under one foreground lease',
        () async {
      final communicator = _FullBackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();
      final progress = <FullDeviceBackupProgress>[];

      final capture = await fixture.appState.fullDeviceBackupWorkflow.capture(
        status: fixture.appState.connectedDeviceStatus!,
        clock: () => DateTime.utc(2026, 8, 13, 12),
        onProgress: progress.add,
      );

      expect(capture.outcome, FullDeviceBackupCaptureOutcome.captured);
      final backup = capture.backup!;
      expect(backup.positions, hasLength(8));
      expect(backup.positions.map((item) => item.slot.sourcePosition),
          orderedEquals(List.generate(8, (index) => index)));
      expect(backup.positions.map((item) => item.state),
          everyElement(FullDeviceCaptureState.complete));
      expect(backup.activeSlot, 3);
      expect(backup.mode, FullDeviceOperatingMode.reader);
      expect(backup.firmware.version.value, 0x202);
      expect(backup.firmware.commit.value, 'v2.2.0-19-gcf2b268');
      expect(
          backup.firmware.protocol.value, FullDeviceFirmwareProtocol.current);
      expect(
          backup.preferences.animationMode.value, AnimationSetting.symmetric);
      expect(backup.preferences.buttonAPress.value, ButtonConfig.cycleForward);
      expect(backup.preferences.buttonBPress.value, ButtonConfig.cycleBackward);
      expect(backup.preferences.buttonALongPress.value, ButtonConfig.cloneUID);
      expect(
          backup.preferences.buttonBLongPress.value, ButtonConfig.chargeStatus);
      expect(backup.preferences.sleepTimeoutSeconds.value, 45);
      expect(backup.hasLimitations, isFalse);
      expect(progress.last.processedPositions, 8);
      expect(progress.last.fraction, 1);
      expect(
        communicator.events.where((event) => event == 'types'),
        hasLength(2),
        reason: 'one capture metadata read plus one status reconciliation read',
      );
      expect(
        communicator.events.where((event) => event == 'capabilities'),
        hasLength(1),
      );
      expect(
        communicator.events.where((event) => event.startsWith('activate:')),
        orderedEquals([
          ...List.generate(8, (index) => 'activate:$index'),
          'activate:3',
        ]),
      );

      final background = await fixture.appState.rfOperations
          .tryRunBackground(() async => true);
      expect(background.acquired, isTrue);
    });

    test('marks unsupported preferences and failed positions explicitly',
        () async {
      final communicator = _FullBackupCommunicator(
        failActivationAt: 5,
        supportedCommands: [
          ChameleonCommand.getAnimationMode.value,
          ChameleonCommand.getButtonPressConfig.value,
          ChameleonCommand.getLongButtonPressConfig.value,
        ],
      );
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();

      final result = await fixture.appState.fullDeviceBackupWorkflow.capture(
        status: fixture.appState.connectedDeviceStatus!,
      );

      final backup = result.backup!;
      expect(backup.positions[5].state, FullDeviceCaptureState.failed);
      expect(backup.positions[5].hfState, FullDeviceCaptureState.failed);
      expect(backup.positions[5].lfState, FullDeviceCaptureState.failed);
      expect(backup.positions[5].slot.hf.state,
          SlotBackupCompleteness.unavailable);
      expect(backup.preferences.sleepTimeoutSeconds.state,
          BackupFactState.unsupported);
      expect(communicator.events, isNot(contains('sleep')));
      expect(backup.hasLimitations, isTrue);
    });

    test('marks positions skipped when no metadata exists to capture them',
        () async {
      final communicator = _FullBackupCommunicator(metadataPositionCount: 7);
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();

      final result = await fixture.appState.fullDeviceBackupWorkflow.capture(
        status: fixture.appState.connectedDeviceStatus!,
      );

      final skipped = result.backup!.positions[7];
      expect(skipped.state, FullDeviceCaptureState.skipped);
      expect(skipped.hfState, FullDeviceCaptureState.skipped);
      expect(skipped.lfState, FullDeviceCaptureState.skipped);
      expect(communicator.events, isNot(contains('activate:7')));
      expect(result.backup!.hasLimitations, isTrue);
    });

    test('progress separates processed and confirmed positions', () async {
      final communicator = _FullBackupCommunicator(failActivationAt: 1);
      final fixture = ConnectedDeviceTestHarness(communicator: communicator);
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();
      final progress = <FullDeviceBackupProgress>[];

      await fixture.appState.fullDeviceBackupWorkflow.capture(
        status: fixture.appState.connectedDeviceStatus!,
        onProgress: progress.add,
      );

      final afterFailure = progress.firstWhere(
        (snapshot) => snapshot.processedPositions == 2,
      );
      expect(afterFailure.currentPosition, 2);
      expect(afterFailure.confirmedPositions, 1);
      expect(afterFailure.fraction, 0.25);
      expect(progress.last.currentPosition, isNull);
      expect(progress.last.processedPositions, 8);
      expect(progress.last.confirmedPositions, 7);
      expect(progress.last.fraction, 1);
    });

    test('records Lite emulator mode without an unsupported mode command',
        () async {
      final communicator = _FullBackupCommunicator(failModeRead: true);
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        device: ChameleonDevice.lite,
      );
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();

      final result = await fixture.appState.fullDeviceBackupWorkflow.capture(
        status: fixture.appState.connectedDeviceStatus!,
      );

      expect(result.outcome, FullDeviceBackupCaptureOutcome.captured);
      expect(result.backup!.mode, FullDeviceOperatingMode.emulator);
      expect(communicator.events, isNot(contains('mode')));
    });

    test('picker cancellation performs no device work', () async {
      final files = _MemoryDeviceBackupFiles(cancelSave: true);
      final communicator = _FullBackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();

      final outcome = await fixture.appState.fullDeviceBackupWorkflow.export(
        status: fixture.appState.connectedDeviceStatus!,
        approve: (_) async => true,
      );

      expect(outcome, FullDeviceBackupExportOutcome.cancelled);
      expect(communicator.events, isEmpty);
      expect(files.saved, isNull);
    });

    test('a limited backup is written only after explicit approval', () async {
      final files = _MemoryDeviceBackupFiles();
      final communicator = _FullBackupCommunicator(failActivationAt: 2);
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();
      FullDeviceBackup? report;

      final declined = await fixture.appState.fullDeviceBackupWorkflow.export(
        status: fixture.appState.connectedDeviceStatus!,
        approve: (backup) async {
          report = backup;
          return false;
        },
      );

      expect(declined, FullDeviceBackupExportOutcome.declined);
      expect(report!.hasLimitations, isTrue);
      expect(files.saved, isNull);

      final saved = await fixture.appState.fullDeviceBackupWorkflow.export(
        status: fixture.appState.connectedDeviceStatus!,
        approve: (backup) async => backup.hasLimitations,
      );

      expect(saved, FullDeviceBackupExportOutcome.saved);
      expect(files.saved, isNotNull);
      final decoded = FullDeviceBackupCodec.decode(
        String.fromCharCodes(files.saved!),
      );
      expect(decoded.positions[2].state, FullDeviceCaptureState.failed);
    });

    test('file-write failure is typed and never repeats device capture',
        () async {
      final files = _MemoryDeviceBackupFiles(failWrite: true);
      final communicator = _FullBackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();

      final outcome = await fixture.appState.fullDeviceBackupWorkflow.export(
        status: fixture.appState.connectedDeviceStatus!,
        approve: (_) async => true,
      );

      expect(outcome, FullDeviceBackupExportOutcome.writeFailed);
      expect(files.writeAttempts, 1);
      expect(
        communicator.events.where((event) => event == 'capabilities'),
        hasLength(1),
      );
    });

    test('communicator replacement stops capture and publishes no file',
        () async {
      final gate = Completer<void>();
      final communicator = _FullBackupCommunicator();
      final files = _MemoryDeviceBackupFiles();
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await fixture.settleReadiness();
      communicator.events.clear();
      communicator
        ..metadataGate = gate
        ..metadataStarted = Completer<void>();

      final export = fixture.appState.fullDeviceBackupWorkflow.export(
        status: fixture.appState.connectedDeviceStatus!,
        approve: (_) async => true,
      );
      await communicator.metadataStarted.future;
      final background = await fixture.appState.rfOperations
          .tryRunBackground(() async => true);
      expect(background.acquired, isFalse);

      fixture.appState.communicator = _FullBackupCommunicator();
      gate.complete();

      expect(await export, FullDeviceBackupExportOutcome.connectionChanged);
      expect(files.saved, isNull);
      expect(
        communicator.events.where((event) => event.startsWith('activate:')),
        isEmpty,
      );
    });
  });
}

final class _MemoryDeviceBackupFiles implements SlotBackupFileAdapter {
  _MemoryDeviceBackupFiles({this.cancelSave = false, this.failWrite = false});

  final bool cancelSave;
  final bool failWrite;
  Uint8List? saved;
  int writeAttempts = 0;

  @override
  Future<SlotBackupSaveTarget?> chooseSaveTarget(String suggestedName) async =>
      cancelSave ? null : _MemoryDeviceBackupTarget(this);

  @override
  Future<Uint8List?> open() async => null;
}

final class _MemoryDeviceBackupTarget implements SlotBackupSaveTarget {
  const _MemoryDeviceBackupTarget(this.files);

  final _MemoryDeviceBackupFiles files;

  @override
  Future<void> write(Uint8List bytes) async {
    files.writeAttempts++;
    if (files.failWrite) {
      throw StateError('disk full');
    }
    files.saved = Uint8List.fromList(bytes);
  }
}

// This workflow fake exposes command ordering and failure injection. It stays
// separate from the mounted-UI fake, whose synchronization points serve pumps.
final class _FullBackupCommunicator extends ReadinessTestCommunicator {
  _FullBackupCommunicator({
    this.failActivationAt,
    this.failModeRead = false,
    this.metadataPositionCount = 8,
    List<int>? supportedCommands,
  })  : supportedCommands = supportedCommands ??
            [
              ChameleonCommand.getAnimationMode.value,
              ChameleonCommand.getButtonPressConfig.value,
              ChameleonCommand.getLongButtonPressConfig.value,
              ChameleonCommand.getSleepTimeout.value,
            ],
        super(Logger(output: MemoryOutput()));

  final int? failActivationAt;
  Completer<void>? metadataGate;
  final bool failModeRead;
  final int metadataPositionCount;
  final List<int> supportedCommands;
  Completer<void> metadataStarted = Completer<void>();
  final List<String> events = [];

  @override
  Future<int> getActiveSlot() async {
    events.add('active');
    return 3;
  }

  @override
  Future<bool> isReaderDeviceMode() async {
    events.add('mode');
    if (failModeRead) {
      throw UnsupportedError('mode command is not supported');
    }
    return true;
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() async {
    events.add('firmware-version');
    return FirmwareVersion(legacyProtocol: false, version: 0x202);
  }

  @override
  Future<String> getGitCommitHash() async {
    events.add('firmware-commit');
    return 'v2.2.0-19-gcf2b268';
  }

  @override
  Future<List<int>> getDeviceCapabilities() async {
    events.add('capabilities');
    return supportedCommands;
  }

  @override
  Future<AnimationSetting> getAnimationMode() async {
    events.add('animation');
    return AnimationSetting.symmetric;
  }

  @override
  Future<ButtonConfig> getButtonConfig(ButtonType type) async {
    events.add('button-${type.name}');
    return type == ButtonType.a
        ? ButtonConfig.cycleForward
        : ButtonConfig.cycleBackward;
  }

  @override
  Future<ButtonConfig> getLongButtonConfig(ButtonType type) async {
    events.add('button-long-${type.name}');
    return type == ButtonType.a
        ? ButtonConfig.cloneUID
        : ButtonConfig.chargeStatus;
  }

  @override
  Future<int> getSleepTimeout() async {
    events.add('sleep');
    return 45;
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    if (!metadataStarted.isCompleted) {
      metadataStarted.complete();
      await metadataGate?.future;
    }
    events.add('types');
    return List.generate(metadataPositionCount, (_) => SlotTypes());
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    events.add('enabled');
    return List.generate(metadataPositionCount, (_) => EnabledSlotInfo());
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    events.add('names');
    return List.generate(metadataPositionCount,
        (index) => SlotNames(hf: 'HF $index', lf: 'LF $index'));
  }

  @override
  Future<void> activateSlot(int slot) async {
    events.add('activate:$slot');
    if (slot == failActivationAt) {
      throw StateError('activation failed');
    }
  }
}
