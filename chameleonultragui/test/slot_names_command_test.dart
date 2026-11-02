import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  test('slot names reject a firmware error even with a full payload', () async {
    for (final payload in [<int>[], List<int>.filled(16, 0)]) {
      final communicator = _ResponseCommunicator(0x67, payload);
      addTearDown(communicator.log.close);
      await expectLater(communicator.getSlotTagNames(), throwsStateError);
    }
  });

  test('slot names reject a missing response', () async {
    final communicator = _ResponseCommunicator(ChameleonStatus.success, [])
      ..noResponse = true;
    addTearDown(communicator.log.close);
    await expectLater(communicator.getSlotTagNames(), throwsStateError);
  });

  for (final payload in [
    <int>[],
    <int>[0],
    List<int>.filled(14, 0),
    <int>[3, 65],
    <int>[...List<int>.filled(16, 0), 0],
    <int>[1, 255, ...List<int>.filled(15, 0)],
  ]) {
    test('slot names reject incomplete or malformed payload $payload',
        () async {
      final communicator =
          _ResponseCommunicator(ChameleonStatus.success, payload);
      addTearDown(communicator.log.close);
      await expectLater(communicator.getSlotTagNames(), throwsFormatException);
    });
  }

  test('a complete response can confirm eight empty names', () async {
    final communicator = _ResponseCommunicator(
      ChameleonStatus.success,
      List<int>.filled(16, 0),
    );
    addTearDown(communicator.log.close);
    final slots = await communicator.getSlotTagNames();
    expect(slots, hasLength(8));
    expect(slots.every((slot) => slot.hf.isEmpty && slot.lf.isEmpty), isTrue);
  });

  test('a complete response preserves UTF8 names and physical slot order',
      () async {
    final payload = <int>[];
    for (var slot = 0; slot < 8; slot++) {
      for (final name in ['HF $slot', 'Карта $slot']) {
        final bytes = utf8.encode(name);
        payload.addAll([bytes.length, ...bytes]);
      }
    }
    final communicator =
        _ResponseCommunicator(ChameleonStatus.success, payload);
    addTearDown(communicator.log.close);
    final slots = await communicator.getSlotTagNames();
    for (var slot = 0; slot < 8; slot++) {
      expect(slots[slot].hf, 'HF $slot');
      expect(slots[slot].lf, 'Карта $slot');
    }
  });
}

class _ResponseCommunicator extends ChameleonCommunicator {
  _ResponseCommunicator(this.status, List<int> bytes)
      : data = Uint8List.fromList(bytes),
        super(Logger(level: Level.off));

  final int status;
  final Uint8List data;
  bool noResponse = false;

  @override
  Future<ChameleonMessage?> sendCmd(ChameleonCommand cmd,
      {Uint8List? data,
      Duration timeout = const Duration(seconds: 5),
      bool skipReceive = false,
      bool firstRun = false}) async {
    expect(cmd, ChameleonCommand.getAllSlotNicks);
    return noResponse
        ? null
        : ChameleonMessage(command: cmd.value, status: status, data: this.data);
  }
}
