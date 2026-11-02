import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final replacement in [
    'communicator',
    'connector',
    'disconnect',
    'DFU',
    'dispose'
  ]) {
    test('old queued command stops after $replacement', () async {
      final logger = Logger(level: Level.off);
      addTearDown(logger.close);
      final serial = _GatedSerial(log: logger)
        ..connected = true
        ..isOpen = true;
      final app = ChameleonGUIState(SharedPreferencesProvider())
        ..connector = serial;
      final old = ChameleonCommunicator(logger, port: serial);
      app.communicator = old;
      await serial.registerCallback(old.onSerialMessage);

      final reading = old.getActiveSlot();
      await serial.started.future;
      final queued = old.activateSlot(7);
      final readRejected = expectLater(reading, throwsStateError);
      final writeRejected = expectLater(queued, throwsStateError);

      switch (replacement) {
        case 'communicator':
          app.communicator = ChameleonCommunicator(logger, port: serial);
        case 'connector':
          app.connector = _GatedSerial(log: logger)..connected = true;
        case 'disconnect':
          await app.disconnect();
          serial.connected = true;
          serial.isOpen = true;
          app.communicator = ChameleonCommunicator(logger, port: serial);
        case 'DFU':
          serial.isDFU = true;
          app.changesMade();
        case 'dispose':
          app.dispose();
      }
      serial.gate.complete();
      await Future.wait([readRejected, writeRejected]);

      expect(serial.commands, [ChameleonCommand.getActiveSlot.value]);
      if (replacement != 'dispose') app.dispose();
    });
  }

  test('current connection still serializes successful commands', () async {
    final logger = Logger(level: Level.off);
    addTearDown(logger.close);
    final serial = _GatedSerial(log: logger)..isOpen = true;
    final communicator = ChameleonCommunicator(logger, port: serial);
    await serial.registerCallback(communicator.onSerialMessage);

    final first = communicator.getActiveSlot();
    await serial.started.future;
    final second = communicator.activateSlot(7);
    await Future<void>.delayed(Duration.zero);
    expect(serial.commands, [ChameleonCommand.getActiveSlot.value]);

    serial.gate.complete();
    expect(await first, 0);
    await second;
    expect(serial.commands, [1018, 1003]);
  });
}

class _GatedSerial extends AbstractSerial {
  _GatedSerial({required super.log});

  final started = Completer<void>();
  final gate = Completer<void>();
  final commands = <int>[];

  @override
  Future<bool> performDisconnect() async {
    resetConnectionState();
    return true;
  }

  @override
  Future<bool> write(Uint8List frame, {bool firmware = false}) async {
    final command = (frame[2] << 8) | frame[3];
    final callback = messageCallback;
    commands.add(command);
    if (commands.length == 1) {
      started.complete();
      await gate.future;
    }
    final encoder = ChameleonCommunicator(log);
    final response = encoder.makeDataFrameBytes(
      command == 1018
          ? ChameleonCommand.getActiveSlot
          : ChameleonCommand.setActiveSlot,
      ChameleonStatus.success,
      command == 1018 ? Uint8List.fromList([0]) : Uint8List(0),
    );
    await callback(response);
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;
}
