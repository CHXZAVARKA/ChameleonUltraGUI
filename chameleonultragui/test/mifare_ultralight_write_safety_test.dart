import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/write/base.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  for (final response in <List<int>>[
    const [],
    const [0x00],
    const [0x0A, 0x00],
  ]) {
    test(
        'Ultralight stops after one destructive command when ACK is '
        '${response.isEmpty ? 'missing' : 'invalid'}', () async {
      final logger = Logger(output: MemoryOutput());
      addTearDown(logger.close);
      final communicator = _UltralightWriteCommunicator(
        logger,
        response: response,
      );
      final helper = BaseMifareUltralightWriteHelper(communicator)..key = '';

      final result = await helper.writeData(_ultralightCard(), (_) {});

      expect(result, isFalse);
      expect(communicator.rawCommands, [
        [0xA2, 0x00, 0x00, 0x00, 0x00, 0x00],
      ]);
    });
  }

  test('Ultralight preserves an exact write acknowledgement', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _UltralightWriteCommunicator(
      logger,
      response: const [0x0A],
    );
    final helper = BaseMifareUltralightWriteHelper(communicator)..key = '';

    final result = await helper.writeData(_ultralightCard(), (_) {});

    expect(result, isTrue);
    expect(communicator.rawCommands, [
      [0xA2, 0x00, 0x00, 0x00, 0x00, 0x00],
    ]);
  });
}

CardSave _ultralightCard() => CardSave(
      uid: '01020304',
      name: 'Ultralight',
      tag: TagType.ultralight,
      data: [Uint8List(4)],
    );

class _UltralightWriteCommunicator extends ChameleonCommunicator {
  _UltralightWriteCommunicator(super.log, {required this.response});

  final List<int> response;
  final List<List<int>> rawCommands = [];

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() async => CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0,
        atqa: Uint8List(2),
        ats: Uint8List(0),
      );

  @override
  Future<Uint8List> send14ARaw(
    Uint8List data, {
    int respTimeoutMs = 100,
    int? bitLen,
    bool activateRfField = true,
    bool waitResponse = true,
    bool appendCrc = true,
    bool autoSelect = true,
    bool keepRfField = false,
    bool checkResponseCrc = true,
  }) async {
    rawCommands.add(data.toList());
    return Uint8List.fromList(response);
  }
}
