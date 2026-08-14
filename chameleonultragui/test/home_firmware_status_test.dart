import 'dart:async';
import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/connected_device_test_harness.dart';
import 'support/test_viewport.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesProvider().load();
  });

  testWidgets('Home shows firmware Checking independently of other facets',
      (tester) async {
    final communicator = _FirmwareCommunicator.pendingFirmware();
    final catalog = _FakeFirmwareCatalog.current();
    final appState = _connectedState(communicator, catalog: catalog);

    await pumpHome(tester, appState);
    await tester.pump();

    expect(find.byKey(const Key('home-firmware-pill')), findsOneWidget);
    expect(find.text('Firmware'), findsOneWidget);
    expect(find.text('Checking'), findsOneWidget);
    expect(find.text('Chameleon Ultra'), findsOneWidget);
    expect(catalog.lookups, 0);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('firmware-status-text')))
          .style
          ?.color,
      Theme.of(tester.element(find.byKey(const Key('home-firmware-pill'))))
          .colorScheme
          .onSurfaceVariant,
    );

    appState.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('BLE Home avoids the multi-packet capabilities response',
      (tester) async {
    final communicator = _FirmwareCommunicator.current();
    final appState = _connectedState(
      communicator,
      catalog: _FakeFirmwareCatalog.current(),
      connectionType: ConnectionType.ble,
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(communicator.capabilityReads, 0);
    expect(communicator.noOpSwapProbes, 1);
    expect(
      appState.connectedDeviceStatus!.snapshot.firmware.state,
      FirmwareState.upToDate,
    );
    expect(
      appState.connectedDeviceStatus!.snapshot.firmware.compatibility,
      FirmwareCompatibility.unknown,
    );
  });

  testWidgets('firmware states use their specified semantic colors',
      (tester) async {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
    );
    final cases =
        <(String, _FirmwareCommunicator, _FakeFirmwareCatalog, Color)>[
      (
        'Up to date',
        _FirmwareCommunicator.current(),
        _FakeFirmwareCatalog.current(),
        Colors.green.shade700,
      ),
      (
        'Update available',
        _FirmwareCommunicator.current(),
        _FakeFirmwareCatalog.updateAvailable(),
        Colors.amber.shade800,
      ),
      (
        'Check unavailable',
        _FirmwareCommunicator.current(),
        _FakeFirmwareCatalog.unavailable(),
        Colors.grey.shade600,
      ),
    ];

    for (final (label, communicator, catalog, color) in cases) {
      final appState = _connectedState(communicator, catalog: catalog);
      await pumpHome(tester, appState, theme: theme);
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(
        find.byKey(const Key('firmware-status-text')),
      );
      expect(text.data, label);
      expect(text.style?.color, color, reason: label);
      appState.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
      'firmware pill visual and pressed action share the same 48px stadium',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final appState = _connectedState(
        _FirmwareCommunicator.current(),
        catalog: _FakeFirmwareCatalog.current(),
      );

      await pumpHome(tester, appState);
      await tester.pumpAndSettle();

      final pill = find.byKey(const Key('home-firmware-pill'));
      final actionSize = tester.getSize(pill);
      expect(actionSize.height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.byKey(const Key('firmware-visual-pill'))).height,
        actionSize.height,
      );
      expect(
        find.bySemanticsLabel('Firmware · Up to date · Firmware details'),
        findsOneWidget,
      );

      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('firmware-details-dialog')), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('firmware pill content has optically even padding',
      (tester) async {
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: _FakeFirmwareCatalog.current(),
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();

    final pillRect = tester.getRect(
      find.byKey(const Key('firmware-visual-pill')),
    );
    final labelRect = tester.getRect(find.text('Firmware'));
    final statusRect = tester.getRect(
      find.byKey(const Key('firmware-status-text')),
    );
    final contentRect = Rect.fromLTRB(
      labelRect.left,
      labelRect.top < statusRect.top ? labelRect.top : statusRect.top,
      statusRect.right,
      labelRect.bottom > statusRect.bottom
          ? labelRect.bottom
          : statusRect.bottom,
    );

    expect(
      (contentRect.center.dx - pillRect.center.dx).abs(),
      lessThanOrEqualTo(0.5),
    );
    expect(
      (contentRect.center.dy - pillRect.center.dy).abs(),
      lessThanOrEqualTo(0.5),
    );
  });

  testWidgets('firmware details contain facts and exclude unsupported content',
      (tester) async {
    final communicator = _FirmwareCommunicator.current(
      version: 0x0102,
      commit: 'abc1234',
    );
    final catalog = _FakeFirmwareCatalog([
      const FirmwareCatalogRelease(
        latestVersion: '2.0',
        latestCommit: 'def5678',
        updateAvailable: true,
      ),
    ]);
    final appState = _connectedState(communicator, catalog: catalog);

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('firmware-details-dialog')), findsOneWidget);
    expect(find.text('Firmware details'), findsOneWidget);
    expect(find.textContaining('Model: Ultra', findRichText: true),
        findsOneWidget);
    expect(
      find.textContaining('Installed version: 1.2', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Installed commit: abc1234', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Protocol: Current', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Latest version or commit: 2.0 (def5678)',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Last check result: Update available',
          findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Capabilities'), findsNothing);
    expect(find.textContaining('Changelog'), findsNothing);
    expect(find.byKey(const Key('firmware-update')), findsOneWidget);
  });

  testWidgets(
      'firmware details persists the selected channel and rechecks that source',
      (tester) async {
    final catalog = _FakeFirmwareCatalog([
      const FirmwareCatalogRelease(
        latestCommit: 'abc1234',
        updateAvailable: false,
      ),
      const FirmwareCatalogRelease(
        latestCommit: 'custom5678',
        updateAvailable: true,
      ),
      const FirmwareCatalogRelease(
        latestCommit: 'custom5678',
        updateAvailable: true,
      ),
    ]);
    FirmwareChannel? installedChannel;
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: catalog,
      channelInstaller: (_, channel) async {
        installedChannel = channel;
      },
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(catalog.channels, [FirmwareChannel.official]);

    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('firmware-channel-control')), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<FirmwareChannel>>(
            find.byKey(const Key('firmware-channel-control')),
          )
          .selected,
      {FirmwareChannel.official},
    );

    await tester.tap(find.byKey(const Key('firmware-channel-custom')));
    await tester.pumpAndSettle();

    expect(
      appState.sharedPreferencesProvider.getFirmwareChannel(),
      FirmwareChannel.custom,
    );
    expect(
        catalog.channels, [FirmwareChannel.official, FirmwareChannel.custom]);
    expect(
      appState.connectedDeviceStatus!.snapshot.firmware.latestCommit,
      'custom5678',
    );

    await tester.tap(find.byKey(const Key('firmware-update')));
    await tester.pumpAndSettle();
    expect(installedChannel, FirmwareChannel.custom);

    _replaceConnection(appState, _FirmwareCommunicator.current());
    appState.changesMade();
    await tester.pumpAndSettle();
    expect(appState.connectedDeviceStatus!.snapshot.firmware.channel,
        FirmwareChannel.custom);
    expect(catalog.channels, [
      FirmwareChannel.official,
      FirmwareChannel.custom,
      FirmwareChannel.custom,
    ]);
  });

  testWidgets('a late result from the previous channel cannot replace Custom',
      (tester) async {
    final officialLookup = Completer<FirmwareCatalogRelease>();
    final catalog = _FakeFirmwareCatalog([
      officialLookup.future,
      const FirmwareCatalogRelease(
        latestCommit: 'custom5678',
        updateAvailable: true,
      ),
    ]);
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: catalog,
    );

    await pumpHome(tester, appState);
    await tester.pump();
    await tester.pump();
    expect(catalog.channels, [FirmwareChannel.official]);

    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('firmware-channel-custom')));
    await tester.pump();
    expect(appState.connectedDeviceStatus!.snapshot.firmware.channel,
        FirmwareChannel.custom);

    officialLookup.complete(
      const FirmwareCatalogRelease(
        latestCommit: 'official9999',
        updateAvailable: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(
        catalog.channels, [FirmwareChannel.official, FirmwareChannel.custom]);
    expect(
      appState.connectedDeviceStatus!.snapshot.firmware.latestCommit,
      'custom5678',
    );
  });

  testWidgets(
      'switching channel during the first fact read reuses those device facts',
      (tester) async {
    final communicator = _FirmwareCommunicator.pendingFirmware();
    final catalog = _FakeFirmwareCatalog([
      const FirmwareCatalogRelease(
        latestCommit: 'custom5678',
        updateAvailable: true,
      ),
    ]);
    final appState = _connectedState(communicator, catalog: catalog);

    await pumpHome(tester, appState);
    await tester.pump();
    await tester.pump();
    expect(communicator.firmwareReads, 1);

    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('firmware-channel-custom')));
    await tester.pump();

    communicator.completePendingFirmware();
    await tester.pumpAndSettle();

    expect(communicator.firmwareReads, 1);
    expect(communicator.commitReads, 1);
    expect(communicator.capabilityReads, 1);
    expect(catalog.channels, [FirmwareChannel.custom]);
  });

  testWidgets('firmware channel remains reachable at 360px and 2.5x text',
      (tester) async {
    setTestViewport(tester, size: const Size(360, 800));
    final catalog = _FakeFirmwareCatalog([
      const FirmwareCatalogRelease(
        latestCommit: 'abc1234',
        updateAvailable: false,
      ),
      const FirmwareCatalogRelease(
        latestCommit: 'custom5678',
        updateAvailable: true,
      ),
    ]);
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: catalog,
    );

    await pumpHome(
      tester,
      appState,
      textScaler: const TextScaler.linear(2.5),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('firmware-channel-control')), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const Key('firmware-channel-custom')));
    await tester.tap(find.byKey(const Key('firmware-channel-custom')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('firmware-channel-custom-description')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic firmware lookup runs once for a connected session',
      (tester) async {
    final catalog = _FakeFirmwareCatalog.current();
    final communicator = _FirmwareCommunicator.current();
    final appState = _connectedState(communicator, catalog: catalog);

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(catalog.lookups, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(catalog.lookups, 1);
    expect(communicator.firmwareReads, 1);
  });

  testWidgets('Retry after unavailable performs exactly one new lookup',
      (tester) async {
    final catalog = _FakeFirmwareCatalog([
      StateError('offline'),
      const FirmwareCatalogRelease(
        latestCommit: 'abc1234',
        updateAvailable: false,
      ),
    ]);
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: catalog,
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(find.text('Check unavailable'), findsOneWidget);
    expect(catalog.lookups, 1);

    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('firmware-check-retry')));
    await tester.pumpAndSettle();

    expect(catalog.lookups, 2);
    expect(find.text('Up to date'), findsWidgets);
    expect(find.byKey(const Key('firmware-check-retry')), findsNothing);
  });

  testWidgets('Demo performs no lookup and never exposes Update',
      (tester) async {
    final catalog = _FakeFirmwareCatalog.updateAvailable();
    final communicator = _FirmwareCommunicator.current();
    final appState = _connectedState(
      communicator,
      catalog: catalog,
      portName: 'Demo',
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('firmware-status-text'))).data,
      'Demo',
    );
    expect(catalog.lookups, 0);
    expect(communicator.firmwareReads, 0);

    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('firmware-update')), findsNothing);
    expect(find.byKey(const Key('firmware-check-retry')), findsNothing);
    expect(
      tester
          .widget<SegmentedButton<FirmwareChannel>>(
            find.byKey(const Key('firmware-channel-control')),
          )
          .onSelectionChanged,
      isNull,
    );
  });

  testWidgets('current and unavailable firmware do not expose Update',
      (tester) async {
    for (final catalog in [
      _FakeFirmwareCatalog.current(),
      _FakeFirmwareCatalog.unavailable(),
    ]) {
      final appState = _connectedState(
        _FirmwareCommunicator.current(),
        catalog: catalog,
      );
      await pumpHome(tester, appState);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-firmware-pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('firmware-update')), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      appState.dispose();
    }
  });

  testWidgets(
      'legacy warning appears once per connection and Skip keeps Home usable',
      (tester) async {
    final catalog = _FakeFirmwareCatalog.updateAvailable();
    final appState = _connectedState(
      _FirmwareCommunicator.legacy(),
      catalog: catalog,
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('firmware-compatibility-warning')),
        findsOneWidget);
    expect(find.text('Update required'), findsOneWidget);
    final requiredText = tester.widget<Text>(
      find.byKey(const Key('firmware-status-text')),
    );
    expect(
      requiredText.style?.color,
      Theme.of(tester.element(find.byKey(const Key('home-firmware-pill'))))
          .colorScheme
          .error,
    );

    await tester.tap(find.byKey(const Key('firmware-warning-skip')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.settings), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('firmware-update')), findsOneWidget);
    expect(
      find.textContaining('Protocol: Legacy', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('firmware-compatibility-warning')), findsNothing);
  });

  testWidgets('legacy warning can appear again for a new connection',
      (tester) async {
    final catalog = _FakeFirmwareCatalog([
      const FirmwareCatalogRelease(
        latestCommit: 'def5678',
        updateAvailable: true,
      ),
      const FirmwareCatalogRelease(
        latestCommit: 'def5678',
        updateAvailable: true,
      ),
    ]);
    final appState = _connectedState(
      _FirmwareCommunicator.legacy(),
      catalog: catalog,
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('firmware-warning-skip')));
    await tester.pumpAndSettle();

    _replaceConnection(appState, _FirmwareCommunicator.legacy());
    appState.changesMade();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('firmware-compatibility-warning')),
        findsOneWidget);
    expect(catalog.lookups, 2);
  });

  testWidgets('Update starts flashing directly without a second confirmation',
      (tester) async {
    var installs = 0;
    final installGate = Completer<void>();
    addTearDown(() {
      if (!installGate.isCompleted) installGate.complete();
    });
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: _FakeFirmwareCatalog.updateAvailable(),
      installer: (_) async {
        installs++;
        await installGate.future;
      },
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('firmware-update')));
    await tester.pump();

    expect(installs, 1);
    expect(find.byKey(const Key('firmware-details-dialog')), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets(
      'queued update from a replaced connection never reaches the installer',
      (tester) async {
    var installs = 0;
    final catalog = _FakeFirmwareCatalog([
      const FirmwareCatalogRelease(
        latestCommit: 'def5678',
        updateAvailable: true,
      ),
      const FirmwareCatalogRelease(
        latestCommit: 'new5678',
        updateAvailable: true,
      ),
    ]);
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: catalog,
      installer: (_) async => installs++,
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    final oldStatus = appState.connectedDeviceStatus!;

    final releaseForeground = Completer<void>();
    final foregroundStarted = Completer<void>();
    final foreground = appState.rfOperations.runForeground(() async {
      foregroundStarted.complete();
      await releaseForeground.future;
    });
    await foregroundStarted.future;

    final oldPublications = <DeviceStatusSnapshot>[];
    oldStatus.addListener(() => oldPublications.add(oldStatus.snapshot));
    final oldInstall = oldStatus.installFirmware();
    await tester.pump();

    expect(oldStatus.snapshot.firmware.installing, isTrue);
    expect(installs, 0);

    _replaceConnection(
        appState,
        _FirmwareCommunicator.current(
          commit: 'new1234',
        ));
    appState.changesMade();
    await tester.pumpAndSettle();
    final newStatus = appState.connectedDeviceStatus!;
    final publicationsAtReplacement = oldPublications.length;

    releaseForeground.complete();
    await foreground;

    expect(await oldInstall, FirmwareInstallOutcome.connectionChanged);
    expect(installs, 0);
    expect(oldPublications, hasLength(publicationsAtReplacement));
    expect(newStatus.snapshot.firmware.state, FirmwareState.updateAvailable);

    expect(await newStatus.installFirmware(), FirmwareInstallOutcome.started);
    expect(installs, 1);
  });

  testWidgets(
      'update failure remains inline and Retry starts the flasher again',
      (tester) async {
    var installs = 0;
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: _FakeFirmwareCatalog.updateAvailable(),
      installer: (_) async {
        installs++;
        if (installs == 1) throw StateError('flash failed');
      },
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('firmware-update')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('firmware-update-error')), findsOneWidget);
    expect(find.byKey(const Key('firmware-install-retry')), findsOneWidget);
    expect(installs, 1);

    await tester.tap(find.byKey(const Key('firmware-install-retry')));
    await tester.pumpAndSettle();
    expect(installs, 2);
    expect(find.byKey(const Key('firmware-update-error')), findsNothing);
  });

  testWidgets(
      'successful flashing resets firmware with the replacement session',
      (tester) async {
    late ChameleonGUIState appState;
    appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: _FakeFirmwareCatalog([
        const FirmwareCatalogRelease(
          latestCommit: 'def5678',
          updateAvailable: true,
        ),
        const FirmwareCatalogRelease(
          latestCommit: 'def5678',
          updateAvailable: false,
        ),
      ]),
      installer: (state) async {
        _replaceConnection(state, _FirmwareCommunicator.current());
        state.changesMade();
      },
    );

    await pumpHome(tester, appState);
    await tester.pumpAndSettle();
    final oldStatus = appState.connectedDeviceStatus!;
    await tester.tap(find.byKey(const Key('home-firmware-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('firmware-update')));
    await tester.pumpAndSettle();

    expect(appState.connectedDeviceStatus, isNot(same(oldStatus)));
    expect(
      appState.connectedDeviceStatus!.snapshot.firmware.state,
      FirmwareState.upToDate,
    );
  });

  testWidgets('late catalog result from an old connection is discarded',
      (tester) async {
    final oldLookup = Completer<FirmwareCatalogRelease>();
    final catalog = _FakeFirmwareCatalog([
      oldLookup.future,
      const FirmwareCatalogRelease(
        latestCommit: 'new1234',
        updateAvailable: false,
      ),
    ]);
    final appState = _connectedState(
      _FirmwareCommunicator.current(),
      catalog: catalog,
    );

    await pumpHome(tester, appState);
    await tester.pump();
    await tester.pump();
    final oldStatus = appState.connectedDeviceStatus!;
    expect(catalog.lookups, 1);

    _replaceConnection(appState, _FirmwareCommunicator.current());
    appState.changesMade();
    await tester.pumpAndSettle();
    final newStatus = appState.connectedDeviceStatus!;
    expect(newStatus, isNot(same(oldStatus)));
    expect(newStatus.snapshot.firmware.state, FirmwareState.upToDate);

    oldLookup.complete(
      const FirmwareCatalogRelease(
        latestCommit: 'late9999',
        updateAvailable: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(appState.connectedDeviceStatus, same(newStatus));
    expect(newStatus.snapshot.firmware.state, FirmwareState.upToDate);
  });

  testWidgets(
      'replacement during firmware version read stops all old session work',
      (tester) async {
    final oldCommunicator = _FirmwareCommunicator.pendingFirmware();
    final newCommunicator = _FirmwareCommunicator.current(commit: 'new1234');
    final catalog = _FakeFirmwareCatalog([
      const FirmwareCatalogRelease(
        latestCommit: 'new1234',
        updateAvailable: false,
      ),
    ]);
    final appState = _connectedState(oldCommunicator, catalog: catalog);

    await pumpHome(tester, appState);
    await tester.pump();
    await tester.pump();
    expect(oldCommunicator.firmwareReads, 1);
    final oldCapabilityReadsBeforeReplacement = oldCommunicator.capabilityReads;
    expect(oldCapabilityReadsBeforeReplacement, 0);

    _replaceConnection(appState, newCommunicator);
    appState.changesMade();
    await tester.pumpAndSettle();
    expect(appState.connectedDeviceStatus!.snapshot.firmware.state,
        FirmwareState.upToDate);

    oldCommunicator.completePendingFirmware();
    await tester.pump();
    await tester.pump();

    expect(oldCommunicator.commitReads, 0);
    expect(
      oldCommunicator.capabilityReads,
      oldCapabilityReadsBeforeReplacement,
    );
    expect(newCommunicator.firmwareReads, 1);
    expect(newCommunicator.commitReads, 1);
    expect(newCommunicator.capabilityReads, 1);
    expect(catalog.lookups, 1);
  });
}

ChameleonGUIState _connectedState(
  ChameleonCommunicator communicator, {
  required FirmwareCatalog catalog,
  String portName = 'firmware-test-device',
  ConnectionType connectionType = ConnectionType.usb,
  Future<void> Function(ChameleonGUIState appState)? installer,
  Future<void> Function(
    ChameleonGUIState appState,
    FirmwareChannel channel,
  )? channelInstaller,
}) {
  return ConnectedDeviceTestHarness(
    communicator: communicator,
    firmwareCatalog: catalog,
    connectionType: connectionType,
    portName: portName,
    activeDevicePort: 'firmware-test-port',
    installFirmware: channelInstaller ??
        (installer == null ? null : (appState, _) => installer(appState)),
  ).appState;
}

class _FirmwareCommunicator extends ChameleonCommunicator {
  _FirmwareCommunicator.pendingFirmware()
      : _pendingFirmware = Completer<FirmwareVersion>(),
        _version = null,
        commit = 'abc1234',
        capabilities = [ChameleonCommand.setIdteckEmulatorID.value],
        super(Logger());

  _FirmwareCommunicator.current({
    int version = 0x0100,
    this.commit = 'abc1234',
  })  : _pendingFirmware = null,
        _version = FirmwareVersion(
          legacyProtocol: false,
          version: version,
        ),
        capabilities = [ChameleonCommand.setIdteckEmulatorID.value],
        super(Logger());

  _FirmwareCommunicator.legacy()
      : _pendingFirmware = null,
        _version = FirmwareVersion(legacyProtocol: true, version: 0x0100),
        commit = 'legacy123',
        capabilities = const [],
        super(Logger());

  final Completer<FirmwareVersion>? _pendingFirmware;
  final FirmwareVersion? _version;
  final String commit;
  final List<int> capabilities;
  int firmwareReads = 0;
  int commitReads = 0;
  int capabilityReads = 0;
  int noOpSwapProbes = 0;

  void completePendingFirmware() {
    _pendingFirmware?.complete(
      FirmwareVersion(legacyProtocol: false, version: 0x0100),
    );
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() {
    firmwareReads++;
    return _pendingFirmware?.future ?? Future.value(_version!);
  }

  @override
  Future<String> getGitCommitHash() async {
    commitReads++;
    return commit;
  }

  @override
  Future<List<int>> getDeviceCapabilities() async {
    capabilityReads++;
    return capabilities;
  }

  @override
  Future<void> swapSlots(int source, int target) async {
    if (source == target) {
      noOpSwapProbes++;
      return;
    }
    throw StateError('unexpected slot swap in firmware status test');
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async =>
      BatteryCharge(percent: 61, voltage: 3910);

  @override
  Future<bool> isReaderDeviceMode() async => false;

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async =>
      List.generate(8, (_) => SlotTypes());

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async =>
      List.generate(8, (_) => EnabledSlotInfo());

  @override
  Future<List<SlotNames>> getSlotTagNames() async =>
      List.generate(8, (_) => SlotNames());

  @override
  Future<int> getActiveSlot() async => 0;
}

class _FakeFirmwareCatalog implements FirmwareCatalog {
  _FakeFirmwareCatalog(this.results);

  _FakeFirmwareCatalog.current()
      : results = [
          const FirmwareCatalogRelease(
            latestCommit: 'abc1234',
            updateAvailable: false,
          ),
        ];

  _FakeFirmwareCatalog.updateAvailable()
      : results = [
          const FirmwareCatalogRelease(
            latestCommit: 'def5678',
            updateAvailable: true,
          ),
        ];

  _FakeFirmwareCatalog.unavailable() : results = [StateError('offline')];

  final List<Object> results;
  int lookups = 0;
  final List<FirmwareChannel> channels = [];

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
    FirmwareChannel channel = FirmwareChannel.official,
  }) async {
    lookups++;
    channels.add(channel);
    final result = results.removeAt(0);
    if (result is FirmwareCatalogRelease) return result;
    if (result is Future<FirmwareCatalogRelease>) return result;
    throw result;
  }
}

void _replaceConnection(
  ChameleonGUIState appState,
  ChameleonCommunicator communicator,
) {
  appState
    ..connector = TestSerial(
      log: Logger(),
      portName: 'replacement-firmware-device',
      activeDevicePort: 'replacement-firmware-port',
    )
    ..communicator = communicator;
}
