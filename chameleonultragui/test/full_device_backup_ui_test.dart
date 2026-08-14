import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/full_device_backup.dart';
import 'package:chameleonultragui/helpers/single_slot_backup_workflow.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'support/connected_device_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('full-device backup user surface', () {
    testWidgets('shows all eight results before writing a complete backup',
        (tester) async {
      final files = _UiBackupFiles();
      final communicator = _UiBackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await _pumpSlotManager(tester, fixture);

      await tester.tap(find.byKey(const Key('slot-manager-backup-all')));
      await tester.pumpAndSettle();

      expect(find.text('Device backup report'), findsOneWidget);
      expect(find.text('Active slot 4; mode: Reader'), findsOneWidget);
      for (var position = 0; position < 8; position++) {
        expect(
          find.byKey(Key('device-backup-report-position-$position')),
          findsOneWidget,
        );
      }
      expect(find.text('Safe device preferences'), findsOneWidget);
      expect(find.text('Animation mode'), findsOneWidget);
      expect(find.text('Sleep timeout'), findsOneWidget);
      expect(find.textContaining('pairing'), findsNothing);
      expect(find.textContaining('BLE key'), findsNothing);
      expect(
          find.byKey(const Key('device-backup-partial-warning')), findsNothing);
      expect(find.text('Save backup'), findsOneWidget);
      expect(files.saved, isNull);

      await tester.tap(find.byKey(const Key('device-backup-confirm-save')));
      await tester.pumpAndSettle();

      expect(files.saved, isNotNull);
      final backup = FullDeviceBackupCodec.decode(
        String.fromCharCodes(files.saved!),
      );
      expect(backup.positions, hasLength(8));
      expect(find.text('Device backup saved.'), findsOneWidget);
    });

    testWidgets('requires an explicit partial-save action for limitations',
        (tester) async {
      final files = _UiBackupFiles();
      final communicator = _UiBackupCommunicator(failActivationAt: 4);
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await _pumpSlotManager(tester, fixture);

      await tester.tap(find.byKey(const Key('slot-manager-backup-all')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('device-backup-partial-warning')),
          findsOneWidget);
      expect(find.text('Slot 5: Failed'), findsOneWidget);
      expect(find.text('HF: Failed; LF: Failed'), findsOneWidget);
      expect(find.text('Save partial backup'), findsOneWidget);
      expect(files.saved, isNull);

      await tester.tap(find.byKey(const Key('device-backup-cancel-save')));
      await tester.pumpAndSettle();

      expect(files.saved, isNull);
    });

    testWidgets('reports positions skipped because capture metadata was absent',
        (tester) async {
      final fixture = ConnectedDeviceTestHarness(
        communicator: _UiBackupCommunicator(metadataPositionCount: 7),
        slotBackupFiles: _UiBackupFiles(),
      );
      addTearDown(fixture.dispose);
      await _pumpSlotManager(tester, fixture);

      await tester.tap(find.byKey(const Key('slot-manager-backup-all')));
      await tester.pumpAndSettle();

      expect(find.text('Slot 8: Skipped'), findsOneWidget);
      expect(find.text('HF: Skipped; LF: Skipped'), findsOneWidget);
      expect(
        find.byKey(const Key('device-backup-partial-warning')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('device-backup-cancel-save')));
      await tester.pumpAndSettle();
    });

    testWidgets(
        'progress keeps the grid and earlier position result visible and semantic',
        (tester) async {
      final release = Completer<void>();
      final communicator = _UiBackupCommunicator(
        holdActivationAt: 1,
        activationGate: release,
      );
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: _UiBackupFiles(),
      );
      addTearDown(fixture.dispose);
      final semantics = tester.ensureSemantics();
      await _pumpSlotManager(tester, fixture);

      await tester.tap(find.byKey(const Key('slot-manager-backup-all')));
      await communicator.heldActivationStarted.future;
      await tester.pump();

      expect(find.byKey(const Key('device-backup-progress')), findsOneWidget);
      expect(
        find.byKey(const Key('device-backup-progress-position-0')),
        findsOneWidget,
      );
      expect(find.text('Slot 1'), findsWidgets);
      expect(
        find.bySemanticsLabel(
          'Backing up slot 2 of 8; 1 processed; 1 confirmed',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('slot-manager-backup-all')),
        findsOneWidget,
      );

      release.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-backup-cancel-save')));
      await tester.pumpAndSettle();
      semantics.dispose();
    });

    testWidgets(
        'slot 8 progress remains reachable on a narrow large-text reduced-motion screen',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete();
        }
      });
      final communicator = _UiBackupCommunicator(
        holdActivationAt: 7,
        activationGate: release,
      );
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: _UiBackupFiles(),
      );
      addTearDown(fixture.dispose);
      final semantics = tester.ensureSemantics();
      await _pumpSlotManager(
        tester,
        fixture,
        textScaler: const TextScaler.linear(2),
        disableAnimations: true,
      );

      await tester.tap(find.byKey(const Key('slot-manager-backup-all')));
      await communicator.heldActivationStarted.future;
      await tester.pump();

      expect(find.byKey(const Key('device-backup-progress')), findsOneWidget);
      expect(
        find.byKey(const Key('device-backup-static-progress')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Backing up slot 8 of 8; 7 processed; 7 confirmed',
        ),
        findsOneWidget,
      );
      for (var position = 0; position < 7; position++) {
        expect(
          find.byKey(Key('device-backup-progress-position-$position')),
          findsOneWidget,
        );
      }
      final resultViewport = tester.getRect(
        find.byKey(const Key('device-backup-progress-results')),
      );
      await tester.ensureVisible(
        find.byKey(const Key('device-backup-progress-position-6')),
      );
      await tester.pump();
      expect(
        resultViewport.overlaps(
          tester.getRect(
            find.byKey(const Key('device-backup-progress-position-6')),
          ),
        ),
        isTrue,
      );
      await tester.ensureVisible(
        find.byKey(const Key('device-backup-progress-position-0')),
      );
      await tester.pump();
      expect(
        resultViewport.overlaps(
          tester.getRect(
            find.byKey(const Key('device-backup-progress-position-0')),
          ),
        ),
        isTrue,
      );
      expect(
        tester.getSize(find.byKey(const Key('device-backup-progress'))).width,
        lessThanOrEqualTo(320),
      );
      expect(tester.takeException(), isNull);

      release.complete();
      await tester.pumpAndSettle();

      expect(
          find.byKey(const Key('device-backup-confirm-save')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('device-backup-confirm-save')),
      );
      await tester.tap(find.byKey(const Key('device-backup-cancel-save')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('picker cancellation returns without any new device command',
        (tester) async {
      final files = _UiBackupFiles(cancelSave: true);
      final communicator = _UiBackupCommunicator();
      final fixture = ConnectedDeviceTestHarness(
        communicator: communicator,
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await _pumpSlotManager(tester, fixture);
      final before = communicator.events.length;

      await tester.tap(find.byKey(const Key('slot-manager-backup-all')));
      await tester.pumpAndSettle();

      expect(communicator.events, hasLength(before));
      expect(find.text('Device backup report'), findsNothing);
      expect(files.saved, isNull);
    });

    testWidgets('file-write failure remains actionable after the report',
        (tester) async {
      final files = _UiBackupFiles(failWrite: true);
      final fixture = ConnectedDeviceTestHarness(
        communicator: _UiBackupCommunicator(),
        slotBackupFiles: files,
      );
      addTearDown(fixture.dispose);
      await _pumpSlotManager(tester, fixture);

      await tester.tap(find.byKey(const Key('slot-manager-backup-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-backup-confirm-save')));
      await tester.pumpAndSettle();

      expect(
        find.text(
            'The backup file could not be written. No device data was changed.'),
        findsOneWidget,
      );
      expect(files.writeAttempts, 1);
    });
  });
}

Future<void> _pumpSlotManager(
  WidgetTester tester,
  ConnectedDeviceTestHarness<_UiBackupCommunicator> fixture, {
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
}) async {
  await fixture.settleReadiness(tester: tester);
  fixture.communicator.events.clear();
  await tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: fixture.appState,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: textScaler,
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: const SlotManagerPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _UiBackupFiles implements SlotBackupFileAdapter {
  _UiBackupFiles({this.cancelSave = false, this.failWrite = false});

  final bool cancelSave;
  final bool failWrite;
  Uint8List? saved;
  int writeAttempts = 0;

  @override
  Future<SlotBackupSaveTarget?> chooseSaveTarget(String suggestedName) async =>
      cancelSave ? null : _UiBackupTarget(this);

  @override
  Future<Uint8List?> open() async => null;
}

final class _UiBackupTarget implements SlotBackupSaveTarget {
  const _UiBackupTarget(this.files);

  final _UiBackupFiles files;

  @override
  Future<void> write(Uint8List bytes) async {
    files.writeAttempts++;
    if (files.failWrite) {
      throw StateError('write failed');
    }
    files.saved = Uint8List.fromList(bytes);
  }
}

// This UI fake exposes pump-safe activation gates. The workflow fake instead
// records the wider command contract and would couple unrelated scenarios.
final class _UiBackupCommunicator extends ReadinessTestCommunicator {
  _UiBackupCommunicator({
    this.failActivationAt,
    this.holdActivationAt,
    this.activationGate,
    this.metadataPositionCount = 8,
  }) : super(Logger(output: MemoryOutput()));

  final int? failActivationAt;
  final int? holdActivationAt;
  final Completer<void>? activationGate;
  final int metadataPositionCount;
  final Completer<void> heldActivationStarted = Completer<void>();
  final List<String> events = [];

  @override
  Future<int> getActiveSlot() async {
    events.add('active');
    return 3;
  }

  @override
  Future<bool> isReaderDeviceMode() async {
    events.add('mode');
    return true;
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x202);

  @override
  Future<String> getGitCommitHash() async => 'v2.2.0-19-gcf2b268';

  @override
  Future<List<int>> getDeviceCapabilities() async => [
        ChameleonCommand.getAnimationMode.value,
        ChameleonCommand.getButtonPressConfig.value,
        ChameleonCommand.getLongButtonPressConfig.value,
        ChameleonCommand.getSleepTimeout.value,
      ];

  @override
  Future<AnimationSetting> getAnimationMode() async => AnimationSetting.full;

  @override
  Future<ButtonConfig> getButtonConfig(ButtonType type) async =>
      ButtonConfig.cycleForward;

  @override
  Future<ButtonConfig> getLongButtonConfig(ButtonType type) async =>
      ButtonConfig.chargeStatus;

  @override
  Future<int> getSleepTimeout() async => 30;

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
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
    if (slot == holdActivationAt) {
      if (!heldActivationStarted.isCompleted) {
        heldActivationStarted.complete();
      }
      await activationGate?.future;
    }
    if (slot == failActivationAt) {
      throw StateError('activation failed');
    }
  }
}
