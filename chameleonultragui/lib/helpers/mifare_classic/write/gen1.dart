import 'dart:typed_data';

import 'package:chameleonultragui/helpers/mifare_classic/write/base.dart';

class MifareClassicGen1WriteHelper extends BaseMifareClassicWriteHelper {
  MifareClassicGen1WriteHelper(super.communicator, {required super.recovery});

  @override
  String get name => "gen1";

  static String get staticName => "gen1";

  @override
  Future<bool> isMagic(dynamic data) async {
    try {
      if (!operationCanContinue) return false;
      await communicator.send14ARaw(Uint8List(1)); // reset
      if (!operationCanContinue) return false;

      Uint8List data = await communicator.send14ARaw(Uint8List.fromList([0x40]),
          bitLen: 7,
          appendCrc: false,
          autoSelect: false,
          checkResponseCrc: false,
          keepRfField: true);
      if (!operationCanContinue) return false;

      if (data.isNotEmpty && data[0] == 0x0a) {
        data = await communicator.send14ARaw(Uint8List.fromList([0x43]),
            appendCrc: false, autoSelect: false, checkResponseCrc: false);
        return operationCanContinue && data.isNotEmpty && data[0] == 0x0a;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  bool isReady() {
    return true;
  }

  @override
  Future<bool> writeBlock(int block, Uint8List data) async {
    for (int retry = 0; retry < 5; retry++) {
      if (!operationCanContinue) return false;
      var writeIssued = false;
      try {
        await communicator.send14ARaw(Uint8List(1)); // reset
        if (!operationCanContinue) return false;

        await communicator.send14ARaw(Uint8List.fromList([0x40]),
            bitLen: 7,
            appendCrc: false,
            autoSelect: false,
            checkResponseCrc: false,
            keepRfField: true);
        if (!operationCanContinue) return false;

        await communicator.send14ARaw(Uint8List.fromList([0x43]),
            appendCrc: false,
            autoSelect: false,
            checkResponseCrc: false,
            keepRfField: true);
        if (!operationCanContinue) return false;

        await communicator.send14ARaw(Uint8List.fromList([0xA0, block]),
            autoSelect: false, keepRfField: true, checkResponseCrc: false);
        if (!operationCanContinue) return false;

        writeIssued = true;
        Uint8List output = await communicator.send14ARaw(data,
            autoSelect: false, keepRfField: true, checkResponseCrc: false);
        writeIssued = false;

        if (!operationCanContinue) return false;
        if (output.isEmpty) return false;
        if (output[0] == 0x0a) {
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        if (!operationCanContinue) return false;
      } catch (_) {
        if (writeIssued) return false;
      }
    }

    return false;
  }
}
