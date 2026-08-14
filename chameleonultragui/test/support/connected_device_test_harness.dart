import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/helpers/single_slot_backup_workflow.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connection_readiness.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firmware_catalog_stub.dart';

/// A connected serial adapter with only the behavior shared by GUI tests.
final class TestSerial extends AbstractSerial {
  TestSerial({
    required super.log,
    ChameleonDevice device = ChameleonDevice.ultra,
    ConnectionType connectionType = ConnectionType.usb,
    String portName = 'test-device',
    String activeDevicePort = 'test-port',
  }) {
    connected = true;
    this.device = device;
    this.connectionType = connectionType;
    this.portName = portName;
    this.activeDevicePort = activeDevicePort;
  }

  int disconnects = 0;
  Completer<void>? disconnectGate;

  @override
  Future<bool> performDisconnect() async {
    disconnects++;
    await disconnectGate?.future;
    resetConnectionState();
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}

/// Immediate protocol facts for test communicators that are not exercising
/// staged connection readiness themselves.
abstract class ReadinessTestCommunicator extends ChameleonCommunicator {
  ReadinessTestCommunicator(super.log);

  @override
  Future<FirmwareVersion> getFirmwareVersion() async =>
      FirmwareVersion(legacyProtocol: false, version: 0x0202);

  @override
  Future<String> getGitCommitHash() async => 'test-ready';

  @override
  Future<List<int>> getDeviceCapabilities() async => const [];

  @override
  Future<BatteryCharge> getBatteryCharge() async =>
      BatteryCharge(percent: 60, voltage: 3900);

  @override
  Future<bool> isReaderDeviceMode() async => false;
}

final class ConnectedDeviceTestHarness<T extends ChameleonCommunicator> {
  ConnectedDeviceTestHarness({
    required this.communicator,
    FirmwareCatalog firmwareCatalog = const CurrentFirmwareCatalogStub(),
    Logger? logger,
    ChameleonDevice device = ChameleonDevice.ultra,
    ConnectionType connectionType = ConnectionType.usb,
    String portName = 'test-device',
    String activeDevicePort = 'test-port',
    Future<void> Function(ChameleonGUIState appState, FirmwareChannel channel)?
        installFirmware,
    SlotBackupFileAdapter slotBackupFiles = const NativeSlotBackupFileAdapter(),
  }) : logger = logger ?? Logger(output: MemoryOutput()) {
    serial = TestSerial(
      log: this.logger,
      device: device,
      connectionType: connectionType,
      portName: portName,
      activeDevicePort: activeDevicePort,
    );
    communicator.open(serial);
    late ChameleonGUIState state;
    state = ChameleonGUIState(
      SharedPreferencesProvider(),
      firmwareCatalog: firmwareCatalog,
      firmwareInstaller: installFirmware == null
          ? null
          : (channel) => installFirmware(state, channel),
      slotBackupFiles: slotBackupFiles,
    )
      ..log = this.logger
      ..connector = serial
      ..communicator = communicator;
    appState = state;
  }

  final T communicator;
  final Logger logger;
  late final TestSerial serial;
  late final ChameleonGUIState appState;
  bool _disposed = false;

  Future<void> settleReadiness({WidgetTester? tester}) async {
    const terminalStages = {
      ConnectionReadinessStage.ready,
      ConnectionReadinessStage.degraded,
    };
    for (var attempt = 0; attempt < 200; attempt++) {
      if (terminalStages
          .contains(appState.connectionReadiness.snapshot.stage)) {
        return;
      }
      if (const {
        ConnectionReadinessStage.failed,
        ConnectionReadinessStage.disconnected,
      }.contains(appState.connectionReadiness.snapshot.stage)) {
        fail(
          'Connected-device readiness ended in '
          '${appState.connectionReadiness.snapshot.stage.name}',
        );
      }
      if (tester == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      } else {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }
    fail('Connected-device readiness did not settle');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    appState.dispose();
  }
}

ConnectedDeviceTestHarness<ChameleonCommunicator> connectedDeviceSessionHarness(
    {FirmwareCatalog firmwareCatalog = const CurrentFirmwareCatalogStub()}) {
  final logger = Logger(output: MemoryOutput());
  final communicator = ChameleonCommunicator(logger);
  return ConnectedDeviceTestHarness(
    communicator: communicator,
    firmwareCatalog: firmwareCatalog,
    logger: logger,
  );
}

Future<void> pumpHome(
  WidgetTester tester,
  ChameleonGUIState appState, {
  ThemeData? theme,
  Locale locale = const Locale('en'),
  TextScaler? textScaler,
}) async {
  SharedPreferences.setMockInitialValues({});
  await appState.sharedPreferencesProvider.load();
  await tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        theme: theme,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: child!,
                ),
        home: const HomePage(),
      ),
    ),
  );
}
