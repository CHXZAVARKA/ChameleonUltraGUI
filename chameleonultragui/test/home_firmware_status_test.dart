import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Home shows firmware Checking independently of other facets',
      (tester) async {
    final communicator = _FirmwareCommunicator.pendingFirmware();
    final catalog = _FakeFirmwareCatalog.current();
    final appState = _connectedState(communicator, catalog: catalog);

    await _pumpHome(tester, appState);
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
      await _pumpHome(tester, appState, theme: theme);
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
      'firmware pill keeps a compact visual inside one accessible 48px action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final appState = _connectedState(
        _FirmwareCommunicator.current(),
        catalog: _FakeFirmwareCatalog.current(),
      );

      await _pumpHome(tester, appState);
      await tester.pumpAndSettle();

      final pill = find.byKey(const Key('home-firmware-pill'));
      expect(tester.getSize(pill).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.byKey(const Key('firmware-visual-pill'))).height,
        lessThan(48),
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

    await _pumpHome(tester, appState);
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

  testWidgets('automatic firmware lookup runs once for a connected session',
      (tester) async {
    final catalog = _FakeFirmwareCatalog.current();
    final communicator = _FirmwareCommunicator.current();
    final appState = _connectedState(communicator, catalog: catalog);

    await _pumpHome(tester, appState);
    await tester.pumpAndSettle();
    expect(catalog.lookups, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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
      await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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
    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
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

    await _pumpHome(tester, appState);
    await tester.pump();
    await tester.pump();
    expect(oldCommunicator.firmwareReads, 1);

    _replaceConnection(appState, newCommunicator);
    appState.changesMade();
    await tester.pumpAndSettle();
    expect(appState.connectedDeviceStatus!.snapshot.firmware.state,
        FirmwareState.upToDate);

    oldCommunicator.completePendingFirmware();
    await tester.pump();
    await tester.pump();

    expect(oldCommunicator.commitReads, 0);
    expect(oldCommunicator.capabilityReads, 0);
    expect(newCommunicator.firmwareReads, 1);
    expect(newCommunicator.commitReads, 1);
    expect(newCommunicator.capabilityReads, 1);
    expect(catalog.lookups, 1);
  });
}

Future<void> _pumpHome(WidgetTester tester, ChameleonGUIState appState,
    {ThemeData? theme}) async {
  SharedPreferences.setMockInitialValues({});
  await appState.sharedPreferencesProvider.load();
  await tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const HomePage(),
      ),
    ),
  );
}

ChameleonGUIState _connectedState(
  ChameleonCommunicator communicator, {
  required FirmwareCatalog catalog,
  String portName = 'firmware-test-device',
  Future<void> Function(ChameleonGUIState appState)? installer,
}) {
  final serial = _TestSerial(log: Logger())
    ..connected = true
    ..device = ChameleonDevice.ultra
    ..connectionType = ConnectionType.usb
    ..portName = portName
    ..activeDevicePort = 'firmware-test-port';
  late ChameleonGUIState appState;
  appState = ChameleonGUIState(
    SharedPreferencesProvider(),
    firmwareCatalog: catalog,
    firmwareInstaller: installer == null ? null : () => installer(appState),
  )
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
  return appState;
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

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
  }) async {
    lookups++;
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
    ..connector = (_TestSerial(log: Logger())
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb
      ..portName = 'replacement-firmware-device'
      ..activeDevicePort = 'replacement-firmware-port')
    ..communicator = communicator;
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log});

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
