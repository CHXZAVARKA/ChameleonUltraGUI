import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/dfu.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  for (final operation in ['command', 'firmware chunks']) {
    test('DFU $operation stop after the captured connection changes', () async {
      final logger = Logger(level: Level.off);
      addTearDown(logger.close);
      final serial = _GatedSerial(log: logger)..isOpen = true;
      var current = true;
      final dfu = DFUCommunicator(logger,
          port: serial, viaBLE: true, isConnectionCurrent: () => current);
      final sending = operation == 'command'
          ? dfu.setPRN()
          : dfu.delayedSend(Uint8List(300));
      await serial.started.future;
      final rejected = expectLater(sending, throwsStateError);
      current = false;
      serial.gate.complete();
      await rejected;
      expect(serial.writes, 1);
    });
  }

  test('DFU refuses a stale connection before its first write', () async {
    final logger = Logger(level: Level.off);
    addTearDown(logger.close);
    final serial = _GatedSerial(log: logger)..isOpen = true;
    final dfu = DFUCommunicator(logger,
        port: serial, viaBLE: true, isConnectionCurrent: () => false);
    await expectLater(dfu.setPRN(), throwsStateError);
    await expectLater(dfu.delayedSend(Uint8List(20)), throwsStateError);
    expect(serial.writes, 0);
  });
}

class _GatedSerial extends AbstractSerial {
  _GatedSerial({required super.log});
  final started = Completer<void>();
  final gate = Completer<void>();
  int writes = 0;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    writes++;
    if (writes == 1) {
      started.complete();
      await gate.future;
    }
    if (!firmware) {
      messageCallback(Uint8List.fromList([0x60, command.first, 0x01]));
    }
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];
  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;
  @override
  bool isManualConnectionSupported() => false;
}
