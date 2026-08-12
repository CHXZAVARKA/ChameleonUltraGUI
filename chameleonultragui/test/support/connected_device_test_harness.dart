import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
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
