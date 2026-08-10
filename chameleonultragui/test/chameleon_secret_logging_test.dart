import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/gui/page/debug.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('T55 old and new keys never enter persistent or exportable logs',
      () async {
    final harness = await _LoggingHarness.create();
    final oldKey = Uint8List.fromList([0xA1, 0xB2, 0xC3, 0xD4]);
    final newKey = Uint8List.fromList([0xE5, 0xF6, 0x07, 0x18]);
    final response = Uint8List.fromList([0x29, 0x3A, 0x4B, 0x5C]);
    harness.respondWith(
      ChameleonCommand.writeEM410XtoT5577,
      data: response,
    );

    await harness.communicator.writeEM410XtoT55XX(
      Uint8List.fromList([1, 2, 3, 4, 5]),
      newKey,
      [oldKey],
    );

    harness.expectRedacted([oldKey, newKey, response]);
    harness.expectDiagnostics(
      ChameleonCommand.writeEM410XtoT5577,
      status: 0,
    );
  });

  test('MF0 detection-log passwords never enter persistent or exportable logs',
      () async {
    final harness = await _LoggingHarness.create();
    final password = Uint8List.fromList([0x61, 0x72, 0x83, 0x94]);
    harness.respondWith(
      ChameleonCommand.mf0NtagGetDetectionLog,
      data: password,
    );

    expect(await harness.communicator.mf0NtagGetDetectionLog(0), isNotEmpty);

    harness.expectRedacted([password]);
    harness.expectDiagnostics(
      ChameleonCommand.mf0NtagGetDetectionLog,
      status: 0,
    );
  });

  test('raw HF14A request and response bytes are always redacted', () async {
    final harness = await _LoggingHarness.create();
    final request = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
    final response = Uint8List.fromList([0xC0, 0xFF, 0xEE, 0x11]);
    harness.respondWith(ChameleonCommand.hf14ARawCommand, data: response);

    expect(await harness.communicator.send14ARaw(request), response);

    harness.expectRedacted([request, response]);
    harness.expectDiagnostics(ChameleonCommand.hf14ARawCommand, status: 0);
  });

  test('emulator page request and response bytes are always redacted',
      () async {
    final harness = await _LoggingHarness.create();
    final writtenPages = Uint8List.fromList([0x12, 0x34, 0x56, 0x78]);
    harness.respondWith(ChameleonCommand.mf0NtagWriteEmuPageData);

    await harness.communicator.mf0EmulatorWritePages(4, writtenPages);

    final readPages = Uint8List.fromList([0x87, 0x65, 0x43, 0x21]);
    harness.respondWith(
      ChameleonCommand.mf0NtagReadEmuPageData,
      data: readPages,
    );
    expect(await harness.communicator.mf0EmulatorReadPages(4, 1), readPages);

    harness.expectRedacted([writtenPages, readPages]);
    harness.expectDiagnostics(
      ChameleonCommand.mf0NtagWriteEmuPageData,
      status: 0,
    );
    harness.expectDiagnostics(
      ChameleonCommand.mf0NtagReadEmuPageData,
      status: 0,
    );
  });

  test('HF and LF sniff response payloads are always redacted', () async {
    final harness = await _LoggingHarness.create();
    final hfPayload = Uint8List.fromList([0x90, 0xA1, 0xB2, 0xC3]);
    harness.respondWith(
      ChameleonCommand.hf14aSniff,
      status: 0x68,
      data: hfPayload,
    );
    expect(await harness.communicator.hf14aSniff(timeoutMs: 1), hfPayload);

    final lfPayload = Uint8List.fromList([0xD4, 0xE5, 0xF6, 0x07]);
    harness.respondWith(
      ChameleonCommand.lfSniff,
      status: 0x40,
      data: lfPayload,
    );
    expect(await harness.communicator.lfSniff(timeoutMs: 1), lfPayload);

    harness.expectRedacted([hfPayload, lfPayload]);
    harness.expectDiagnostics(ChameleonCommand.hf14aSniff, status: 0x68);
    harness.expectDiagnostics(ChameleonCommand.lfSniff, status: 0x40);
  });

  test('payloads are redacted without per-command security metadata', () async {
    final harness = await _LoggingHarness.create();
    final request = Uint8List.fromList([0x13, 0x57, 0x9B, 0xDF]);
    final response = Uint8List.fromList([0x24, 0x68, 0xAC, 0xE0]);
    harness.respondWith(ChameleonCommand.setAnimationMode, data: response);

    await harness.communicator.sendCmd(
      ChameleonCommand.setAnimationMode,
      data: request,
    );

    harness.expectRedacted([request, response]);
    harness.expectDiagnostics(ChameleonCommand.setAnimationMode, status: 0);
  });

  test('unknown emulator commands keep only safe frame metadata', () async {
    final logging = await _PersistentLogging.create();
    final command = Uint8List.fromList([0xCA, 0xFE, 0xBA, 0xBE]);
    final serial = EmulatorSerial(log: logging.logger);

    await serial.write(command);

    logging.expectRedacted(command);
    logging.expectMetadata(
      direction: 'send',
      length: command.length,
      outcome: 'unsupported-emulator-command',
    );
  });

  test('BLE, mobile and native parser failures share redacted receive logging',
      () async {
    final logging = await _PersistentLogging.create();
    final frame = Uint8List.fromList([0xDE, 0xC0, 0xAD, 0xDE]);
    final serial = _ParserFailureSerial(log: logging.logger);

    serial.report(frame);

    logging.expectRedacted(frame);
    logging.expectMetadata(
      direction: 'receive',
      length: frame.length,
      outcome: 'parser-error',
    );
  });

  test('Debug recovery summaries persist counts without recovered key arrays',
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
  _PersistentLogging({required this.preferences, required this.logger});

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
    return _PersistentLogging(preferences: preferences, logger: logger);
  }

  String get logs => preferences.getLogLines().join('\n');

  void expectRedacted(Uint8List sentinel) {
    expect(logs.toUpperCase(),
        isNot(contains(bytesToHex(sentinel).toUpperCase())));
    expect(logs, contains('<redacted ${sentinel.length} byte(s)>'));
  }

  void expectMetadata({
    required String direction,
    required int length,
    required String outcome,
  }) {
    expect(logs, contains('direction = $direction'));
    expect(logs, contains('status = unavailable'));
    expect(logs, contains('length = $length'));
    expect(logs, contains('outcome = $outcome'));
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

class _LoggingHarness {
  _LoggingHarness({
    required this.preferences,
    required this.logger,
    required this.serial,
    required this.communicator,
  });

  final SharedPreferencesProvider preferences;
  final Logger logger;
  final _RespondingSerial serial;
  final ChameleonCommunicator communicator;

  static Future<_LoggingHarness> create() async {
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
    serial.communicator = communicator;
    return _LoggingHarness(
      preferences: preferences,
      logger: logger,
      serial: serial,
      communicator: communicator,
    );
  }

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
    final logs = preferences.getLogLines().join('\n').toUpperCase();
    final exportableLogs = String.fromCharCodes(
      Uint8List.fromList(logs.codeUnits),
    );
    for (final sentinel in sentinels) {
      final value = bytesToHex(sentinel).toUpperCase();
      expect(logs, isNot(contains(value)));
      expect(exportableLogs, isNot(contains(value)));
    }
    expect(logs, contains('REDACTED'));
  }

  void expectDiagnostics(ChameleonCommand command, {required int status}) {
    final logs = preferences.getLogLines().join('\n');
    expect(logs, contains('command = ${command.value}'));
    expect(logs, contains('status = $status'));
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
