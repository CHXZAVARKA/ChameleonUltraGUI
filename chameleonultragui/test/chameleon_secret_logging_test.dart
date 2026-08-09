import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('raw HF14A credentials never enter persistent or exportable logs',
      () async {
    const sentinel = 'DEADBEEF0123';
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(
      filter: ChameleonLogFilter(),
      printer: PrettyPrinter(noBoxingByDefault: true),
      output: SharedPreferencesLogger(preferences),
    );
    addTearDown(logger.close);
    final serial = _RespondingSerial(log: logger);
    final communicator = ChameleonCommunicator(logger, port: serial);
    serial.onWrite = () async {
      await serial.messageCallback(communicator.makeDataFrameBytes(
        ChameleonCommand.hf14ARawCommand,
        0,
        Uint8List(0),
      ));
    };

    await communicator.send14ARaw(
      Uint8List.fromList([
        0xDE,
        0xAD,
        0xBE,
        0xEF,
        0x01,
        0x23,
      ]),
    );

    final storedLogs = preferences.getLogLines().join('\n');
    final exportableLogs = String.fromCharCodes(
      Uint8List.fromList(storedLogs.codeUnits),
    );
    expect(storedLogs.toUpperCase(), isNot(contains(sentinel)));
    expect(exportableLogs.toUpperCase(), isNot(contains(sentinel)));
    expect(storedLogs, contains('redacted'));
  });
}

class _RespondingSerial extends AbstractSerial {
  _RespondingSerial({required super.log});

  late Future<void> Function() onWrite;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    await onWrite();
    return true;
  }
}
