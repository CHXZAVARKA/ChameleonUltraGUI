import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/pending_connection.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:chameleonultragui/status/connection_readiness.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';

void main() {
  for (final transport in [ConnectionType.ble, ConnectionType.usb]) {
    testWidgets(
      'pending ${transport.name.toUpperCase()} connection names its transport '
      'without a blocking spinner',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'auto_connect_first_found': false,
        });
        final gate = Completer<void>();
        final selected = Chameleon(
          port: transport == ConnectionType.ble
              ? 'ble-readiness-device'
              : '/dev/readiness-device',
          device: ChameleonDevice.ultra,
          type: transport,
          dfu: false,
        );
        final serial = _PendingSerial(
          log: Logger(output: MemoryOutput()),
          selected: selected,
          gate: gate,
        );
        final preferences = SharedPreferencesProvider();
        await preferences.load();
        final appState = ChameleonGUIState(preferences)
          ..connector = serial
          ..log = serial.log;

        await tester.pumpWidget(
          ChangeNotifierProvider<ChameleonGUIState>.value(
            value: appState,
            child: MainPage(sharedPreferencesProvider: preferences),
          ),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Chameleon Ultra'));
        await tester.pump();

        expect(find.byType(PendingConnectionPage), findsOneWidget);
        expect(find.byType(ChameleonLoadingIndicator), findsNothing);
        expect(
          find.text(
            transport == ConnectionType.ble
                ? 'Connecting over Bluetooth'
                : 'Connecting over USB',
          ),
          findsOneWidget,
        );

        gate.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpWidget(const SizedBox.shrink());
        appState.dispose();
      },
    );
  }

  testWidgets('Home traces protocol and initial status before becoming ready', (
    tester,
  ) async {
    final protocol = Completer<FirmwareVersion>();
    final slots = Completer<void>();
    final communicator = _ReadinessCommunicator(
      protocol: protocol.future,
      slotsGate: slots.future,
    );
    final fixture = await _mountHome(tester, communicator);

    expect(find.text('Waiting for Chameleon'), findsOneWidget);
    expect(
      fixture.appState.connectionReadiness.snapshot.stage,
      ConnectionReadinessStage.waitingForProtocol,
    );

    protocol.complete(_currentFirmware);
    await _pumpFrames(tester, 3);

    expect(find.text('Loading device status'), findsOneWidget);
    expect(
      fixture.appState.connectionReadiness.snapshot.stage,
      ConnectionReadinessStage.loadingStatus,
    );

    slots.complete();
    await _pumpFrames(tester, 12);

    expect(
      fixture.appState.connectionReadiness.snapshot.stage,
      ConnectionReadinessStage.ready,
    );
    expect(find.byKey(const Key('connection-readiness')), findsNothing);
    expect(
      fixture.appState.connectedDeviceStatus!.snapshot.slots.availability,
      SlotsAvailability.available,
    );
    fixture.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'initial status probes wait for the protocol handshake to finish',
    (tester) async {
      final protocol = Completer<FirmwareVersion>();
      final communicator = _ReadinessCommunicator(protocol: protocol.future);
      final fixture = await _mountHome(tester, communicator);

      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.waitingForProtocol,
      );
      final explicitModeRefresh =
          fixture.appState.connectedDeviceStatus!.refreshMode();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(communicator.statusProbeCalls, 0);

      protocol.complete(_currentFirmware);
      await explicitModeRefresh;
      await _pumpFrames(tester, 3);

      expect(communicator.statusProbeCalls, greaterThan(0));
      expect(
        fixture.appState.connectionReadiness.snapshot.history.map(
          (record) => record.stage,
        ),
        contains(ConnectionReadinessStage.waitingForProtocol),
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a serialized timeout holds the queue until the blocker settles',
    (tester) async {
      final batteryGate = Completer<void>();
      final communicator = _SerializedReadinessCommunicator(batteryGate);
      final fixture = await _mountHome(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );

      await tester.pump(const Duration(milliseconds: 25));

      final waitingSnapshot = fixture.appState.connectedDeviceStatus!.snapshot;
      expect(
        waitingSnapshot.battery.availability,
        BatteryAvailability.unavailable,
      );
      expect(waitingSnapshot.mode.availability, ModeAvailability.available);
      expect(waitingSnapshot.slots.availability, SlotsAvailability.available);
      expect(
        waitingSnapshot.firmware.checkResult,
        FirmwareCheckResult.unavailable,
      );
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );
      expect(communicator.gitCommitCalls, 0);

      batteryGate.completeError(StateError('battery unavailable'));
      await _pumpFrames(tester, 16);

      final settledSnapshot = fixture.appState.connectedDeviceStatus!.snapshot;
      expect(settledSnapshot.mode.availability, ModeAvailability.available);
      expect(settledSnapshot.slots.availability, SlotsAvailability.available);
      expect(communicator.gitCommitCalls, 1);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a permanently hung serialized facet cannot cascade readiness timeouts',
    (tester) async {
      final batteryGate = Completer<void>();
      final communicator = _SerializedReadinessCommunicator(batteryGate);
      final fixture = await _mountHome(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );

      await tester.pump(const Duration(milliseconds: 25));
      await _pumpFrames(tester, 4);

      final status = fixture.appState.connectedDeviceStatus!.snapshot;
      expect(status.mode.availability, ModeAvailability.available);
      expect(status.slots.availability, SlotsAvailability.available);
      expect(status.battery.availability, BatteryAvailability.unavailable);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );
      expect(
        fixture.appState.connectionReadiness.snapshot.errorCategory,
        ConnectionReadinessErrorCategory.timeout,
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'post-timeout surfaces and timers do not enqueue behind a hung command',
    (tester) async {
      final batteryGate = Completer<void>();
      final communicator = _SerializedReadinessCommunicator(batteryGate);
      final fixture = await _mountHome(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );

      await tester.pump(const Duration(milliseconds: 25));
      await _pumpFrames(tester, 4);

      final status = fixture.appState.connectedDeviceStatus!;
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );
      expect(
        status.snapshot.battery.availability,
        BatteryAvailability.unavailable,
      );
      expect(status.snapshot.mode.availability, ModeAvailability.available);
      expect(status.snapshot.slots.availability, SlotsAvailability.available);
      expect(
        status.snapshot.firmware.checkResult,
        FirmwareCheckResult.unavailable,
      );
      final requestsAfterTimeout = communicator.serializedRequests;

      await tester.pump(const Duration(seconds: 2));
      expect(communicator.serializedRequests, requestsAfterTimeout);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(communicator.serializedRequests, requestsAfterTimeout);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: fixture.appState,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SlotManagerPage(),
          ),
        ),
      );
      await tester.pump();

      expect(communicator.serializedRequests, requestsAfterTimeout);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );
      expect(
        status.snapshot.firmware.checkResult,
        FirmwareCheckResult.unavailable,
      );

      unawaited(status.retryFirmwareCheck());
      await tester.pump(const Duration(milliseconds: 25));
      expect(communicator.serializedRequests, requestsAfterTimeout);
      expect(
        status.snapshot.firmware.checkResult,
        FirmwareCheckResult.unavailable,
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real Home keeps initial status ownership across consecutive hung facets',
    (tester) async {
      final modeGate = Completer<void>();
      final slotsGate = Completer<void>();
      final capabilityGate = Completer<void>();
      final communicator = _InitialQueueOwnershipCommunicator(
        modeGate: modeGate,
        slotsBlocker: slotsGate,
        capabilityGate: capabilityGate,
      );
      addTearDown(() {
        if (!modeGate.isCompleted) modeGate.complete();
        if (!slotsGate.isCompleted) slotsGate.complete();
        if (!capabilityGate.isCompleted) capabilityGate.complete();
      });
      final fixture = await _mountHome(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );
      addTearDown(fixture.dispose);

      await tester.pump(const Duration(milliseconds: 25));

      expect(communicator.serializedRequests, 1);
      expect(communicator.modeCalls, 1);
      expect(communicator.deviceCapabilitiesCalls, 0);

      modeGate.complete();
      await tester.pump(const Duration(milliseconds: 5));
      expect(communicator.serializedRequests, 2);
      expect(communicator.slotTypeCalls, 1);
      expect(communicator.deviceCapabilitiesCalls, 0);

      final status = fixture.appState.connectedDeviceStatus!;
      unawaited(status.refreshSlotReorderCapability());
      unawaited(status.refreshBattery());
      await tester.pump(const Duration(milliseconds: 5));
      expect(communicator.serializedRequests, 2);

      await tester.pump(const Duration(milliseconds: 20));
      await _pumpFrames(tester, 3);
      expect(communicator.serializedRequests, 2);
      expect(communicator.deviceCapabilitiesCalls, 0);
      expect(communicator.batteryCalls, 0);
      expect(communicator.gitCommitCalls, 0);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'foreground status actions do not queue behind a hung background lease',
    (tester) async {
      final modeGate = Completer<void>();
      final communicator = _ForegroundActionCommunicator(modeGate);
      var installs = 0;
      final fixture = await _mountHome(
        tester,
        communicator,
        firmwareCatalog: const _UpdateAvailableFirmwareCatalog(),
        firmwareInstaller: (_) async => installs++,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );
      addTearDown(() {
        if (!modeGate.isCompleted) modeGate.complete();
        fixture.dispose();
      });
      await tester.pump(const Duration(milliseconds: 25));
      final status = fixture.appState.connectedDeviceStatus!;
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );

      ModeActionOutcome? modeOutcome;
      SlotReorderOutcome? reorderOutcome;
      bool? activationOutcome;
      FirmwareInstallOutcome? installOutcome;
      Object? mutationError;
      unawaited(
        status
            .switchMode(ConnectedDeviceMode.reader)
            .then((value) => modeOutcome = value),
      );
      unawaited(
        status.reorderSlots(0, 1).then((value) => reorderOutcome = value),
      );
      unawaited(
        status.activateSlot(1).then((value) => activationOutcome = value),
      );
      unawaited(
        status.installFirmware().then((value) => installOutcome = value),
      );
      unawaited(
        status.mutateSlots<void>((_) async {}).catchError((Object error) {
          mutationError = error;
        }),
      );

      await tester.pump(const Duration(milliseconds: 10));

      expect(modeOutcome, ModeActionOutcome.busy);
      expect(reorderOutcome, SlotReorderOutcome.busy);
      expect(activationOutcome, isFalse);
      expect(installOutcome, FirmwareInstallOutcome.busy);
      expect(mutationError, isA<SlotMutationBusy>());
      expect(status.snapshot.mode.pendingMode, isNull);
      expect(status.snapshot.slots.pendingReorder, isNull);
      expect(status.snapshot.slots.pendingActivation, isNull);
      expect(status.snapshot.firmware.installing, isFalse);
      expect(communicator.foregroundRequests, 0);
      expect(installs, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'foreground status actions are bounded while initial readiness owns queue',
    (tester) async {
      final modeGate = Completer<void>();
      final communicator = _ForegroundActionCommunicator(modeGate);
      var installs = 0;
      final fixture = await _mountHome(
        tester,
        communicator,
        firmwareCatalog: const _UpdateAvailableFirmwareCatalog(),
        firmwareInstaller: (_) async => installs++,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );
      addTearDown(() {
        if (!modeGate.isCompleted) modeGate.complete();
        fixture.dispose();
      });
      await tester.pump();
      expect(communicator.modeCalls, 1);

      final status = fixture.appState.connectedDeviceStatus!;
      ModeActionOutcome? modeOutcome;
      SlotReorderOutcome? reorderOutcome;
      bool? activationOutcome;
      FirmwareInstallOutcome? installOutcome;
      Object? mutationError;
      unawaited(
        status
            .switchMode(ConnectedDeviceMode.reader)
            .then((value) => modeOutcome = value),
      );
      unawaited(
        status.reorderSlots(0, 1).then((value) => reorderOutcome = value),
      );
      unawaited(
        status.activateSlot(1).then((value) => activationOutcome = value),
      );
      unawaited(
        status.installFirmware().then((value) => installOutcome = value),
      );
      unawaited(
        status.mutateSlots<void>((_) async {}).catchError((Object error) {
          mutationError = error;
        }),
      );

      await tester.pump(const Duration(milliseconds: 5));

      expect(modeOutcome, ModeActionOutcome.busy);
      expect(reorderOutcome, SlotReorderOutcome.busy);
      expect(activationOutcome, isFalse);
      expect(installOutcome, FirmwareInstallOutcome.busy);
      expect(mutationError, isA<SlotMutationBusy>());
      expect(status.snapshot.mode.pendingMode, isNull);
      expect(status.snapshot.slots.pendingReorder, isNull);
      expect(status.snapshot.slots.pendingActivation, isNull);
      expect(status.snapshot.firmware.installing, isFalse);
      expect(communicator.foregroundRequests, 0);
      expect(installs, 0);

      modeGate.complete();
      await tester.pump(const Duration(milliseconds: 40));
      await _pumpFrames(tester, 12);

      expect(communicator.foregroundRequests, 0);
      expect(installs, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'foreground RF beyond the initial budget degrades without loading forever',
    (tester) async {
      final protocol = Completer<FirmwareVersion>();
      final communicator = _ReadinessCommunicator(protocol: protocol.future);
      final fixture = await _mountConnectedShell(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );
      final foregroundGate = Completer<void>();
      final foregroundStarted = Completer<void>();
      final foreground = fixture.appState.rfOperations.runForeground(() async {
        foregroundStarted.complete();
        await foregroundGate.future;
      });
      await foregroundStarted.future;

      protocol.complete(_currentFirmware);
      await tester.pump(const Duration(milliseconds: 25));
      await _pumpFrames(tester, 3);

      var status = fixture.appState.connectedDeviceStatus!.snapshot;
      expect(status.battery.availability, BatteryAvailability.unavailable);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );
      expect(
        fixture.appState.connectionReadiness.snapshot.errorCategory,
        ConnectionReadinessErrorCategory.timeout,
      );

      foregroundGate.complete();
      await foreground;
      await _pumpFrames(tester, 12);

      status = fixture.appState.connectedDeviceStatus!.snapshot;
      expect(status.battery.availability, BatteryAvailability.available);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('firmware channel change waits for the protocol handshake', (
    tester,
  ) async {
    final protocol = Completer<FirmwareVersion>();
    final communicator = _ReadinessCommunicator(protocol: protocol.future);
    final fixture = await _mountConnectedShell(tester, communicator);
    final status = fixture.appState.connectedDeviceStatus!;

    final channelChange = status.setFirmwareChannel(FirmwareChannel.custom);
    await tester.pump(const Duration(milliseconds: 100));

    expect(status.snapshot.firmware.channel, FirmwareChannel.official);
    expect(communicator.gitCommitCalls, 0);

    protocol.complete(_currentFirmware);
    await channelChange;
    await _pumpFrames(tester, 12);

    expect(status.snapshot.firmware.channel, FirmwareChannel.custom);
    expect(communicator.gitCommitCalls, 1);

    fixture.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'firmware channel requested before handshake is rejected by quarantine',
    (tester) async {
      final protocol = Completer<FirmwareVersion>();
      final modeGate = Completer<void>();
      final communicator = _InitialQueueOwnershipCommunicator(
        protocol: protocol.future,
        modeGate: modeGate,
        slotsBlocker: Completer<void>(),
        capabilityGate: Completer<void>(),
      );
      addTearDown(() {
        if (!modeGate.isCompleted) modeGate.complete();
      });
      final fixture = await _mountConnectedShell(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );
      addTearDown(fixture.dispose);
      final status = fixture.appState.connectedDeviceStatus!;

      var channelChangeCompleted = false;
      unawaited(
        status
            .setFirmwareChannel(FirmwareChannel.custom)
            .then((_) => channelChangeCompleted = true),
      );
      protocol.complete(_currentFirmware);
      await tester.pump(const Duration(milliseconds: 25));

      expect(status.snapshot.firmware.channel, FirmwareChannel.official);
      expect(channelChangeCompleted, isTrue);
      expect(communicator.gitCommitCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Home persists a firmware channel only after status accepts it', (
    tester,
  ) async {
    final modeGate = Completer<void>();
    final communicator = _InitialQueueOwnershipCommunicator(
      modeGate: modeGate,
      slotsBlocker: Completer<void>(),
      capabilityGate: Completer<void>(),
    );
    addTearDown(() {
      if (!modeGate.isCompleted) modeGate.complete();
    });
    final fixture = await _mountHome(
      tester,
      communicator,
      timeouts: const ConnectionReadinessTimeouts(
        protocol: Duration(milliseconds: 20),
        statusFacet: Duration(milliseconds: 20),
      ),
    );
    addTearDown(fixture.dispose);
    await tester.pump(const Duration(milliseconds: 25));
    await _pumpFrames(tester, 3);

    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('firmware-channel-custom')));
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      fixture.appState.sharedPreferencesProvider.getFirmwareChannel(),
      FirmwareChannel.official,
    );
    expect(
      fixture.appState.connectedDeviceStatus!.snapshot.firmware.channel,
      FirmwareChannel.official,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'firmware channel replacement after final refresh cannot be accepted',
    (tester) async {
      final modeGate = Completer<void>();
      final communicator = _InitialQueueOwnershipCommunicator(
        modeGate: modeGate,
        slotsBlocker: Completer<void>()..complete(),
        capabilityGate: Completer<void>()..complete(),
      );
      final catalog = _ReplacingFirmwareCatalog();
      final fixture = await _mountConnectedShell(
        tester,
        communicator,
        firmwareCatalog: catalog,
      );
      addTearDown(() {
        if (!modeGate.isCompleted) modeGate.complete();
        fixture.dispose();
      });
      await tester.pump();
      expect(communicator.modeCalls, 1);

      final originalStatus = fixture.appState.connectedDeviceStatus!;
      final change = originalStatus.setFirmwareChannel(FirmwareChannel.custom);
      modeGate.complete();
      await catalog.secondRequestStarted.future;
      fixture.appState.communicator = _ReadinessCommunicator();
      catalog.releaseSecondResult.complete();
      final outcome = await change.timeout(const Duration(seconds: 1));
      if (outcome == FirmwareChannelChangeOutcome.accepted) {
        fixture.appState.sharedPreferencesProvider.setFirmwareChannel(
          FirmwareChannel.custom,
        );
      }
      await _pumpFrames(tester, 4);

      expect(catalog.calls, greaterThanOrEqualTo(2));
      expect(outcome, FirmwareChannelChangeOutcome.connectionChanged);
      expect(originalStatus.isCurrentSession, isFalse);
      expect(
        fixture.appState.connectedDeviceStatus,
        isNot(same(originalStatus)),
      );
      expect(
        fixture.appState.sharedPreferencesProvider.getFirmwareChannel(),
        FirmwareChannel.official,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'latest concurrent firmware channel survives readiness quarantine',
    (tester) async {
      final modeGate = Completer<void>();
      final communicator = _InitialQueueOwnershipCommunicator(
        modeGate: modeGate,
        slotsBlocker: Completer<void>(),
        capabilityGate: Completer<void>(),
      );
      final fixture = await _mountConnectedShell(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );
      addTearDown(() {
        if (!modeGate.isCompleted) modeGate.complete();
        fixture.dispose();
      });
      await tester.pump();
      expect(communicator.modeCalls, 1);

      final status = fixture.appState.connectedDeviceStatus!;
      final customChange = status.setFirmwareChannel(FirmwareChannel.custom);
      await tester.pump();
      expect(status.snapshot.firmware.channel, FirmwareChannel.custom);
      final officialChange = status.setFirmwareChannel(
        FirmwareChannel.official,
      );
      await tester.pump();
      expect(status.snapshot.firmware.channel, FirmwareChannel.official);

      await tester.pump(const Duration(milliseconds: 25));
      final outcomes = await Future.wait([customChange, officialChange]);
      await _pumpFrames(tester, 3);

      expect(outcomes, everyElement(FirmwareChannelChangeOutcome.rejected));
      expect(status.snapshot.firmware.channel, FirmwareChannel.official);
      expect(
        fixture.appState.sharedPreferencesProvider.getFirmwareChannel(),
        FirmwareChannel.official,
      );
      expect(communicator.gitCommitCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an unavailable optional facet degrades Home without hiding confirmed data',
    (tester) async {
      final communicator = _ReadinessCommunicator(failBattery: true);
      final fixture = await _mountHome(tester, communicator);
      await _pumpFrames(tester, 12);

      final readiness = fixture.appState.connectionReadiness.snapshot;
      final status = fixture.appState.connectedDeviceStatus!.snapshot;
      expect(readiness.stage, ConnectionReadinessStage.degraded);
      expect(readiness.errorCategory, ConnectionReadinessErrorCategory.status);
      expect(find.text('Connected with limited status'), findsOneWidget);
      expect(find.text('--%'), findsOneWidget);
      expect(status.slots.availability, SlotsAvailability.available);
      expect(status.slots.activeSlot.value, 0);

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a bounded status timeout degrades first and late confirmed data recovers',
    (tester) async {
      final slots = Completer<void>();
      final communicator = _ReadinessCommunicator(slotsGate: slots.future);
      final fixture = await _mountHome(
        tester,
        communicator,
        timeouts: const ConnectionReadinessTimeouts(
          protocol: Duration(milliseconds: 20),
          statusFacet: Duration(milliseconds: 20),
        ),
      );

      await tester.pump(const Duration(milliseconds: 25));
      await _pumpFrames(tester, 4);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.degraded,
      );
      expect(
        fixture.appState.connectionReadiness.snapshot.errorCategory,
        ConnectionReadinessErrorCategory.timeout,
      );

      slots.complete();
      await _pumpFrames(tester, 8);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a bounded protocol timeout is a redacted failed stage', (
    tester,
  ) async {
    final protocol = Completer<FirmwareVersion>();
    final communicator = _ReadinessCommunicator(protocol: protocol.future);
    final fixture = await _mountHome(
      tester,
      communicator,
      timeouts: const ConnectionReadinessTimeouts(
        protocol: Duration(milliseconds: 20),
        statusFacet: Duration(milliseconds: 20),
      ),
    );

    await tester.pump(const Duration(milliseconds: 25));
    await _pumpFrames(tester, 2);
    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('The device did not respond in time.'), findsOneWidget);
    expect(
      fixture.appState.connectionReadiness.snapshot.errorCategory,
      ConnectionReadinessErrorCategory.timeout,
    );

    protocol.complete(_currentFirmware);
    fixture.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('protocol handshake remains bounded without Home being mounted', (
    tester,
  ) async {
    final protocol = Completer<FirmwareVersion>();
    final communicator = _ReadinessCommunicator(protocol: protocol.future);
    final fixture = await _mountConnectedShell(
      tester,
      communicator,
      timeouts: const ConnectionReadinessTimeouts(
        protocol: Duration(milliseconds: 20),
        statusFacet: Duration(milliseconds: 20),
      ),
    );

    expect(
      fixture.appState.connectionReadiness.snapshot.stage,
      ConnectionReadinessStage.waitingForProtocol,
    );

    await tester.pump(const Duration(milliseconds: 25));
    await _pumpFrames(tester, 2);

    expect(
      fixture.appState.connectionReadiness.snapshot.stage,
      ConnectionReadinessStage.failed,
    );
    expect(
      fixture.appState.connectionReadiness.snapshot.errorCategory,
      ConnectionReadinessErrorCategory.timeout,
    );

    protocol.complete(_currentFirmware);
    fixture.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'late protocol result cannot replace a newer device readiness session',
    (tester) async {
      final oldProtocol = Completer<FirmwareVersion>();
      final oldCommunicator = _ReadinessCommunicator(
        protocol: oldProtocol.future,
      );
      final fixture = await _mountHome(tester, oldCommunicator);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.waitingForProtocol,
      );

      final replacementSerial = _ReadinessSerial(
        log: Logger(output: MemoryOutput()),
        type: ConnectionType.usb,
        port: '/dev/replacement',
      );
      fixture.appState
        ..connector = replacementSerial
        ..communicator = _ReadinessCommunicator()
        ..changesMade();
      await _pumpFrames(tester, 12);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );
      expect(
        fixture.appState.connectedDeviceStatus!.snapshot.identity.portName,
        '/dev/replacement',
      );

      oldProtocol.complete(_currentFirmware);
      await _pumpFrames(tester, 6);
      expect(
        fixture.appState.connectionReadiness.snapshot.stage,
        ConnectionReadinessStage.ready,
      );
      expect(
        fixture.appState.connectedDeviceStatus!.snapshot.identity.portName,
        '/dev/replacement',
      );

      fixture.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('readiness history records elapsed stages and redacted categories', () {
    var now = DateTime.utc(2026, 8, 13, 10);
    final tracker = ConnectionReadinessTracker(now: () => now);
    final discovery = tracker.beginDiscovery();
    now = now.add(const Duration(milliseconds: 250));
    final transport = tracker.beginTransport(ConnectionType.ble);
    expect(tracker.isCurrent(discovery), isTrue);
    expect(tracker.isCurrent(transport), isTrue);
    now = now.add(const Duration(milliseconds: 500));
    final session = tracker.attachSession(ConnectionType.ble);
    now = now.add(const Duration(seconds: 2));
    tracker.fail(session, ConnectionReadinessErrorCategory.timeout);

    expect(tracker.snapshot.history.map((record) => record.stage), [
      ConnectionReadinessStage.discovering,
      ConnectionReadinessStage.connectingTransport,
      ConnectionReadinessStage.waitingForProtocol,
    ]);
    expect(
      tracker.snapshot.history[0].elapsed,
      const Duration(milliseconds: 250),
    );
    expect(
      tracker.snapshot.history[1].elapsed,
      const Duration(milliseconds: 500),
    );
    expect(tracker.snapshot.terminalElapsed, const Duration(seconds: 2));
    expect(
      tracker.snapshot.errorCategory,
      ConnectionReadinessErrorCategory.timeout,
    );
    tracker.dispose();
  });
}

final _currentFirmware = FirmwareVersion(
  legacyProtocol: false,
  version: 0x0202,
);

class _ReadinessFixture {
  const _ReadinessFixture(this.appState);

  final ChameleonGUIState appState;

  void dispose() => appState.dispose();
}

Future<_ReadinessFixture> _mountHome(
  WidgetTester tester,
  _ReadinessCommunicator communicator, {
  ConnectionReadinessTimeouts timeouts = const ConnectionReadinessTimeouts(),
  FirmwareCatalog firmwareCatalog = const CurrentFirmwareCatalogStub(),
  FirmwareInstaller? firmwareInstaller,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = SharedPreferencesProvider();
  await preferences.load();
  final serial = _ReadinessSerial(
    log: Logger(output: MemoryOutput()),
    type: ConnectionType.usb,
    port: '/dev/readiness',
  );
  final appState = ChameleonGUIState(
    preferences,
    firmwareCatalog: firmwareCatalog,
    firmwareInstaller: firmwareInstaller,
    connectionReadinessTimeouts: timeouts,
  )
    ..connector = serial
    ..log = serial.log
    ..communicator = communicator;

  await tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomePage(),
      ),
    ),
  );
  await tester.pump();
  return _ReadinessFixture(appState);
}

Future<_ReadinessFixture> _mountConnectedShell(
  WidgetTester tester,
  _ReadinessCommunicator communicator, {
  ConnectionReadinessTimeouts timeouts = const ConnectionReadinessTimeouts(),
  FirmwareCatalog firmwareCatalog = const CurrentFirmwareCatalogStub(),
  FirmwareInstaller? firmwareInstaller,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = SharedPreferencesProvider();
  await preferences.load();
  final serial = _ReadinessSerial(
    log: Logger(output: MemoryOutput()),
    type: ConnectionType.usb,
    port: '/dev/readiness',
  );
  final appState = ChameleonGUIState(
    preferences,
    firmwareCatalog: firmwareCatalog,
    firmwareInstaller: firmwareInstaller,
    connectionReadinessTimeouts: timeouts,
  )
    ..connector = serial
    ..log = serial.log
    ..communicator = communicator;

  await tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: const MaterialApp(home: SizedBox.shrink()),
    ),
  );
  await tester.pump();
  return _ReadinessFixture(appState);
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _PendingSerial extends EmulatorSerial {
  _PendingSerial({
    required super.log,
    required this.selected,
    required this.gate,
  });

  final Chameleon selected;
  final Completer<void> gate;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [selected];

  @override
  Future<bool> connectDiscoveredDevice(Chameleon chameleon) async {
    await gate.future;
    return false;
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}

class _ReadinessSerial extends AbstractSerial {
  _ReadinessSerial({
    required super.log,
    required ConnectionType type,
    required String port,
  }) {
    connected = true;
    device = ChameleonDevice.ultra;
    connectionType = type;
    portName = port;
    activeDevicePort = port;
  }

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}

class _ReadinessCommunicator extends ChameleonCommunicator {
  _ReadinessCommunicator({
    Future<FirmwareVersion>? protocol,
    this.slotsGate,
    this.failBattery = false,
  })  : protocol = protocol ?? Future.value(_currentFirmware),
        super(Logger(output: MemoryOutput()));

  final Future<FirmwareVersion> protocol;
  final Future<void>? slotsGate;
  final bool failBattery;
  int batteryCalls = 0;
  int modeCalls = 0;
  int slotTypeCalls = 0;
  int gitCommitCalls = 0;
  int deviceCapabilitiesCalls = 0;
  int activeSlotCalls = 0;

  int get statusProbeCalls =>
      batteryCalls +
      modeCalls +
      slotTypeCalls +
      gitCommitCalls +
      deviceCapabilitiesCalls +
      activeSlotCalls;

  @override
  Future<FirmwareVersion> getFirmwareVersion() => protocol;

  @override
  Future<String> getGitCommitHash() async {
    gitCommitCalls++;
    return 'readiness123';
  }

  @override
  Future<List<int>> getDeviceCapabilities() async {
    deviceCapabilitiesCalls++;
    return [ChameleonCommand.setIdteckEmulatorID.value];
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async {
    batteryCalls++;
    if (failBattery) {
      throw StateError('sensitive transport detail must stay redacted');
    }
    return BatteryCharge(percent: 78, voltage: 3970);
  }

  @override
  Future<bool> isReaderDeviceMode() async {
    modeCalls++;
    return false;
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    slotTypeCalls++;
    await slotsGate;
    return List.generate(
      8,
      (index) => SlotTypes(
        hf: index == 0 ? TagType.mifare1K : TagType.unknown,
        lf: TagType.unknown,
      ),
    );
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async =>
      List.generate(8, (index) => EnabledSlotInfo(hf: index == 0, lf: false));

  @override
  Future<List<SlotNames>> getSlotTagNames() async => List.generate(
        8,
        (index) => SlotNames(hf: index == 0 ? 'Confirmed card' : ''),
      );

  @override
  Future<int> getActiveSlot() async {
    activeSlotCalls++;
    return 0;
  }
}

class _SerializedReadinessCommunicator extends _ReadinessCommunicator {
  _SerializedReadinessCommunicator(this.batteryGate);

  final Completer<void> batteryGate;
  Future<void> _tail = Future.value();
  int serializedRequests = 0;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    serializedRequests++;
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  @override
  Future<BatteryCharge> getBatteryCharge() => _serialize(() async {
        batteryCalls++;
        await batteryGate.future;
        return BatteryCharge(percent: 78, voltage: 3970);
      });

  @override
  Future<bool> isReaderDeviceMode() => _serialize(() async {
        modeCalls++;
        return false;
      });

  @override
  Future<List<SlotTypes>> getSlotTagTypes() => _serialize(() async {
        slotTypeCalls++;
        return super.getSlotTagTypes();
      });

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() =>
      _serialize(super.getEnabledSlots);

  @override
  Future<List<SlotNames>> getSlotTagNames() =>
      _serialize(super.getSlotTagNames);

  @override
  Future<int> getActiveSlot() => _serialize(super.getActiveSlot);

  @override
  Future<String> getGitCommitHash() => _serialize(() async {
        gitCommitCalls++;
        return 'readiness123';
      });

  @override
  Future<List<int>> getDeviceCapabilities() => _serialize(() async {
        deviceCapabilitiesCalls++;
        return [ChameleonCommand.setIdteckEmulatorID.value];
      });
}

class _InitialQueueOwnershipCommunicator extends _ReadinessCommunicator {
  _InitialQueueOwnershipCommunicator({
    super.protocol,
    required this.modeGate,
    required this.slotsBlocker,
    required this.capabilityGate,
  });

  final Completer<void> modeGate;
  final Completer<void> slotsBlocker;
  final Completer<void> capabilityGate;
  Future<void> _tail = Future.value();
  int serializedRequests = 0;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    serializedRequests++;
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  @override
  Future<bool> isReaderDeviceMode() => _serialize(() async {
        modeCalls++;
        await modeGate.future;
        return false;
      });

  @override
  Future<List<SlotTypes>> getSlotTagTypes() => _serialize(() async {
        slotTypeCalls++;
        await slotsBlocker.future;
        return super.getSlotTagTypes();
      });

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() =>
      _serialize(super.getEnabledSlots);

  @override
  Future<List<SlotNames>> getSlotTagNames() =>
      _serialize(super.getSlotTagNames);

  @override
  Future<int> getActiveSlot() => _serialize(super.getActiveSlot);

  @override
  Future<List<int>> getDeviceCapabilities() => _serialize(() async {
        deviceCapabilitiesCalls++;
        await capabilityGate.future;
        return [
          ChameleonCommand.setIdteckEmulatorID.value,
          ChameleonCommand.swapSlots.value,
        ];
      });

  @override
  Future<BatteryCharge> getBatteryCharge() => _serialize(() async {
        batteryCalls++;
        return BatteryCharge(percent: 78, voltage: 3970);
      });

  @override
  Future<String> getGitCommitHash() => _serialize(() async {
        gitCommitCalls++;
        return 'readiness123';
      });
}

class _ForegroundActionCommunicator extends _ReadinessCommunicator {
  _ForegroundActionCommunicator(this.modeGate);

  final Completer<void> modeGate;
  int foregroundRequests = 0;

  @override
  Future<bool> isReaderDeviceMode() async {
    modeCalls++;
    await modeGate.future;
    return false;
  }

  @override
  Future<void> setReaderDeviceMode(bool reader) async {
    foregroundRequests++;
  }

  @override
  Future<void> activateSlot(int slot) async {
    foregroundRequests++;
  }

  @override
  Future<void> swapSlots(int source, int target) async {
    foregroundRequests++;
  }
}

class _UpdateAvailableFirmwareCatalog implements FirmwareCatalog {
  const _UpdateAvailableFirmwareCatalog();

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
    FirmwareChannel channel = FirmwareChannel.official,
  }) async =>
      const FirmwareCatalogRelease(
        latestCommit: 'newer123',
        updateAvailable: true,
      );
}

class _ReplacingFirmwareCatalog implements FirmwareCatalog {
  int calls = 0;
  final Completer<void> secondRequestStarted = Completer<void>();
  final Completer<void> releaseSecondResult = Completer<void>();

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
    FirmwareChannel channel = FirmwareChannel.official,
  }) async {
    calls++;
    if (calls == 1) {
      return const FirmwareCatalogRelease(
        latestCommit: 'unknown123',
        updateAvailable: null,
      );
    }
    secondRequestStarted.complete();
    await releaseSecondResult.future;
    return const FirmwareCatalogRelease(
      latestCommit: 'current123',
      updateAvailable: false,
    );
  }
}
