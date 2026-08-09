import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/firmware_catalog_stub.dart';

void main() {
  testWidgets(
      'Home serializes initial protocol commands so real slot facts stay available',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final logger = Logger(output: MemoryOutput());
    final serial = _SingleFlightSerial(log: logger)
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.ble
      ..portName = 'Chameleon Ultra'
      ..activeDevicePort = 'test-device';
    final communicator = ChameleonCommunicator(logger, port: serial);
    serial.responseFrame = (command, data) => communicator.makeDataFrameBytes(
          command,
          0,
          data,
        );
    final appState = ChameleonGUIState(
      SharedPreferencesProvider(),
      firmwareCatalog: const CurrentFirmwareCatalogStub(),
    )
      ..connector = serial
      ..communicator = communicator
      ..log = logger;
    await appState.sharedPreferencesProvider.load();

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
    await tester.pumpAndSettle();

    expect(serial.maxConcurrentWrites, 1);
    expect(
      find.byKey(const Key('home-slot-1-hf-mark-empty')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('home-slot-1-hf-mark-unavailable')),
      findsNothing,
    );
  });
}

class _SingleFlightSerial extends AbstractSerial {
  _SingleFlightSerial({required super.log});

  late Uint8List Function(ChameleonCommand command, Uint8List data)
      responseFrame;
  int _activeWrites = 0;
  bool _protocolCorrupted = false;
  int maxConcurrentWrites = 0;

  @override
  Future<void> open() async {
    isOpen = true;
  }

  @override
  Future<bool> write(Uint8List request, {bool firmware = false}) async {
    _activeWrites++;
    maxConcurrentWrites = maxConcurrentWrites < _activeWrites
        ? _activeWrites
        : maxConcurrentWrites;
    if (_activeWrites > 1) {
      _protocolCorrupted = true;
    }
    try {
      await Future<void>.delayed(const Duration(milliseconds: 4));
      final value = request[2] << 8 | request[3];
      final command = ChameleonCommand.values.firstWhere(
        (candidate) => candidate.value == value,
      );
      final data = _protocolCorrupted ? Uint8List(0) : _responseData(command);
      await messageCallback(responseFrame(command, data));
      return true;
    } finally {
      _activeWrites--;
    }
  }

  Uint8List _responseData(ChameleonCommand command) => switch (command) {
        ChameleonCommand.getAppVersion => Uint8List.fromList([1, 0]),
        ChameleonCommand.getDeviceMode => Uint8List.fromList([0]),
        ChameleonCommand.getGitVersion =>
          Uint8List.fromList(ascii.encode('abcdef0')),
        ChameleonCommand.getBatteryCharge =>
          Uint8List.fromList([0x0f, 0x46, 61]),
        ChameleonCommand.getActiveSlot => Uint8List.fromList([0]),
        ChameleonCommand.getSlotInfo => Uint8List(32),
        ChameleonCommand.getEnabledSlots => Uint8List(16),
        ChameleonCommand.getAllSlotNicks => Uint8List(16),
        ChameleonCommand.getDeviceCapabilities => Uint8List(0),
        _ => Uint8List(0),
      };

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;
}
