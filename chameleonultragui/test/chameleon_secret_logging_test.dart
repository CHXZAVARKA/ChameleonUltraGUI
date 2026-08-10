import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/gui/page/debug.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('bridge payloads are redacted without per-command metadata', () async {
    final harness = await _BridgeLoggingHarness.create();
    final request = Uint8List.fromList([0x13, 0x57, 0x9B, 0xDF]);
    final response = Uint8List.fromList([0x24, 0x68, 0xAC, 0xE0]);
    harness.respondWith(ChameleonCommand.setAnimationMode, data: response);

    await harness.communicator.sendCmd(
      ChameleonCommand.setAnimationMode,
      data: request,
    );

    harness.expectRedacted([request, response]);
    expect(harness.logs,
        contains('command = ${ChameleonCommand.setAnimationMode.value}'));
    expect(harness.logs, contains('status = 0'));
  });

  test('parser failures keep only redacted frame metadata', () async {
    final logging = await _PersistentLogging.create();
    final frame = Uint8List.fromList([0xDE, 0xC0, 0xAD, 0xDE]);
    final serial = _ParserFailureSerial(log: logging.logger);

    serial.report(frame);

    logging.expectRedacted(frame);
    expect(logging.logs, contains('direction = receive'));
    expect(logging.logs, contains('length = ${frame.length}'));
    expect(logging.logs, contains('outcome = parser-error'));
  });

  test('recovery summaries persist counts without recovered key arrays',
      () async {
    final logging = await _PersistentLogging.create();
    final recoveredKeys = [0xA1B2C3D4E5F6, 0x102030405060];

    logging.logger.d(mifareClassicRecoveryLogSummary(
      'Darkside self-test',
      recoveredKeys.length,
    ));

    final logs = logging.logs.toUpperCase();
    for (final key in recoveredKeys) {
      expect(logs, isNot(contains(key.toRadixString(16).toUpperCase())));
    }
    expect(logs, contains('COUNT = 2'));
    expect(logs, contains('OUTCOME = CANDIDATES-RECOVERED'));
  });
}

class _PersistentLogging {
  _PersistentLogging(this.preferences, this.logger);

  final SharedPreferencesProvider preferences;
  final Logger logger;

  static Future<_PersistentLogging> create() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(
      filter: ChameleonLogFilter(),
      printer: PrettyPrinter(noBoxingByDefault: true),
      output: SharedPreferencesLogger(preferences),
    );
    addTearDown(logger.close);
    return _PersistentLogging(preferences, logger);
  }

  String get logs => preferences.getLogLines().join('\n');

  void expectRedacted(Uint8List sentinel) {
    expect(
      logs.toUpperCase(),
      isNot(contains(bytesToHex(sentinel).toUpperCase())),
    );
    expect(logs, contains('<redacted ${sentinel.length} byte(s)>'));
  }
}

class _BridgeLoggingHarness {
  _BridgeLoggingHarness(this.logging, this.serial, this.communicator);

  final _PersistentLogging logging;
  final _RespondingSerial serial;
  final ChameleonCommunicator communicator;

  static Future<_BridgeLoggingHarness> create() async {
    final logging = await _PersistentLogging.create();
    final serial = _RespondingSerial(log: logging.logger);
    final communicator = ChameleonCommunicator(logging.logger, port: serial);
    serial.communicator = communicator;
    return _BridgeLoggingHarness(logging, serial, communicator);
  }

  String get logs => logging.logs;

  void respondWith(
    ChameleonCommand command, {
    int status = 0,
    Uint8List? data,
  }) {
    serial
      ..responseCommand = command
      ..responseStatus = status
      ..responseData = data ?? Uint8List(0);
  }

  void expectRedacted(List<Uint8List> sentinels) {
    for (final sentinel in sentinels) {
      logging.expectRedacted(sentinel);
    }
  }
}

class _RespondingSerial extends AbstractSerial {
  _RespondingSerial({required super.log});

  late ChameleonCommunicator communicator;
  late ChameleonCommand responseCommand;
  int responseStatus = 0;
  Uint8List responseData = Uint8List(0);

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    await messageCallback(communicator.makeDataFrameBytes(
      responseCommand,
      responseStatus,
      responseData,
    ));
    return true;
  }
}

class _ParserFailureSerial extends AbstractSerial {
  _ParserFailureSerial({required super.log});

  void report(Uint8List data) => logUnexpectedSerialData(data);

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => false;
}
