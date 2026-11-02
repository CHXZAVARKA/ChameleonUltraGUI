import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/flash.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/protobuf/dfu-cc.pb.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/firmware_channel.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logger/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final replacement in ['communicator', 'connector', 'reconnect']) {
    test('download for A cannot enter DFU on replacement $replacement',
        () async {
      final logger = Logger(level: Level.off);
      addTearDown(logger.close);
      final serial = _TestSerial(log: logger)..connected = true;
      final first = _DfuCommunicator(logger);
      final second = _DfuCommunicator(logger);
      final app = ChameleonGUIState(SharedPreferencesProvider())
        ..connector = serial
        ..communicator = first;
      addTearDown(app.dispose);
      final started = Completer<void>();
      final archive = Completer<Uint8List>();
      final updating = _download(app, started, archive);
      await started.future;

      if (replacement == 'connector') {
        app.connector = _TestSerial(log: logger)
          ..connected = true
          ..device = ChameleonDevice.lite;
      } else if (replacement == 'reconnect') {
        serial.connected = false;
        app.onConnectorStateChanged();
        serial.connected = true;
      }
      app.communicator = second;
      final rejected = expectLater(updating, throwsStateError);
      archive.complete(_firmwareArchive());
      await rejected;

      expect(first.enterDfuCalls, 0);
      expect(second.enterDfuCalls, 0);
      expect(serial.disconnects, 0);
    });
  }

  test('an unchanged target reaches the original DFU command', () async {
    final logger = Logger(level: Level.off);
    addTearDown(logger.close);
    final communicator = _DfuCommunicator(logger);
    final app = ChameleonGUIState(SharedPreferencesProvider())
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = communicator;
    addTearDown(app.dispose);
    final started = Completer<void>();
    final archive = Completer<Uint8List>();
    final updating = _download(app, started, archive);
    await started.future;
    final stoppedAtDfu = expectLater(updating, throwsStateError);
    archive.complete(_firmwareArchive());
    await stoppedAtDfu;
    expect(communicator.enterDfuCalls, 1);
  });

  test('recovery can discover DFU while the connector is disconnected',
      () async {
    final logger = Logger(level: Level.off);
    addTearDown(logger.close);
    final serial = _TestSerial(log: logger);
    final app = ChameleonGUIState(SharedPreferencesProvider())
      ..connector = serial;
    addTearDown(app.dispose);
    final started = Completer<void>();
    final archive = Completer<Uint8List>();
    final updating = _download(app, started, archive, enterDFU: false);
    await started.future;
    final rejectedConnection = expectLater(updating, throwsStateError);
    archive.complete(_firmwareArchive());
    await rejectedConnection;
    expect(serial.discoveries, 1);
    expect(serial.connects, 1);
    expect(serial.disconnects, 0);
  });
}

Future<void> _download(ChameleonGUIState app, Completer<void> started,
    Completer<Uint8List> archive,
    {bool enterDFU = true}) {
  return http.runWithClient(
    () =>
        flashFirmware(app, channel: FirmwareChannel.custom, enterDFU: enterDFU),
    () => MockClient((request) async {
      if (request.url.path.endsWith('/releases')) {
        return http.Response(
            jsonEncode([
              {
                'prerelease': true,
                'author': {'login': 'github-actions[bot]'},
                'target_commitish': 'test-commit',
                'assets': [
                  {
                    'name': 'ultra-dfu-app.zip',
                    'browser_download_url':
                        'https://fixture.invalid/firmware.zip',
                  }
                ],
              }
            ]),
            200);
      }
      expect(request.url.host, 'fixture.invalid');
      started.complete();
      return http.Response.bytes(await archive.future, 200);
    }),
  );
}

Uint8List _firmwareArchive() {
  final binary = Uint8List.fromList([1, 2, 3]);
  final metadata = Packet(
    signedCommand: SignedCommand(
      command: Command(
        init: InitCommand(
          hash: Hash(
            hashType: HashType.SHA256,
            hash: sha256.convert(binary).bytes.reversed.toList(),
          ),
        ),
      ),
    ),
  ).writeToBuffer();
  return Uint8List.fromList(ZipEncoder().encode(Archive()
    ..addFile(ArchiveFile('application.dat', metadata.length, metadata))
    ..addFile(ArchiveFile('application.bin', binary.length, binary))));
}

class _DfuCommunicator extends ChameleonCommunicator {
  _DfuCommunicator(super.log);
  int enterDfuCalls = 0;

  @override
  Future<void> enterDFUMode() async {
    enterDfuCalls++;
    throw StateError('Stopped at DFU boundary without touching hardware');
  }
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log}) {
    device = ChameleonDevice.ultra;
  }

  int disconnects = 0;
  int discoveries = 0;
  int connects = 0;

  @override
  Future<bool> performDisconnect() async {
    disconnects++;
    throw StateError('Unexpected disconnect');
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    discoveries++;
    return const [
      Chameleon(
          port: 'test-dfu',
          device: ChameleonDevice.ultra,
          type: ConnectionType.usb,
          dfu: true)
    ];
  }

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    connects++;
    return false;
  }

  @override
  bool isManualConnectionSupported() => false;
  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
