import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen2.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

class MifareClassicGen3WriteHelper extends MifareClassicGen2WriteHelper {
  bool _gen3WriteWasAmbiguous = false;

  @override
  bool get lastWriteWasAmbiguous =>
      _gen3WriteWasAmbiguous || super.lastWriteWasAmbiguous;

  MifareClassicGen3WriteHelper(super.communicator, {required super.recovery});

  @override
  String get name => "gen3";

  static String get staticName => "gen3";

  @override
  Future<bool> isMagic(dynamic data) async {
    try {
      if (!operationCanContinue) return false;
      if (!await communicator.detectMf1Support()) {
        return false; // not even Mifare Classic
      }
      if (!operationCanContinue) return false;

      Uint8List response = await communicator.send14ARaw(
          Uint8List.fromList([0x30, 0x00]),
          checkResponseCrc: false);

      return operationCanContinue && response.length == 18; // 16 + 2 byte CRC
    } catch (_) {
      return false;
    }
  }

  @override
  bool isReady() {
    for (var sector = 0;
        sector < mfClassicGetSectorCount(type, isEV1: isEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (recovery.checkMarks[sector + (keyType * 40)] !=
            ChameleonKeyCheckmark.found) {
          return false;
        }
      }
    }

    return true;
  }

  @override
  Future<bool> writeBlockModifier(CardSave card, int block, Uint8List data,
      {bool tryBothKeys = false, bool useGenericKey = false}) async {
    _gen3WriteWasAmbiguous = false;
    for (int retry = 0; retry < 10; retry++) {
      if (!operationCanContinue) return false;
      try {
        await Future.delayed(
            const Duration(milliseconds: 50)); // Stability delay
        if (!operationCanContinue) return false;
        if (block == 0) {
          if (await writeGen3Block(card, data) && operationCanContinue) {
            return true;
          }
          if (_gen3WriteWasAmbiguous) return false;
        } else {
          if (await writeBlock(block, data,
              tryBothKeys: tryBothKeys, useGenericKey: useGenericKey)) {
            return true;
          }
          if (lastWriteWasAmbiguous) return false;
        }
        if (!operationCanContinue) return false;
        await Future.delayed(const Duration(milliseconds: 150));
        if (!operationCanContinue) return false;
      } catch (_) {
        if (_gen3WriteWasAmbiguous || lastWriteWasAmbiguous) return false;
      }
    }

    return false;
  }

  Future<bool> writeGen3Block(CardSave dump, Uint8List data) async {
    if (!operationCanContinue) return false;
    // Try to write whole block
    _gen3WriteWasAmbiguous = true;
    await communicator.send14ARaw(
        Uint8List.fromList([0x90, 0xFB, 0xCC, 0xCC, 0x10, ...data]),
        checkResponseCrc: false);

    // Try to write UID only
    if (operationCanContinue) {
      await communicator.send14ARaw(
          Uint8List.fromList(
              [0x90, 0xFB, 0xCC, 0xCC, 0x07, ...hexToBytes(dump.uid)]),
          checkResponseCrc: false);
    }

    if (!operationCanContinue) return false;

    // Card doesn't respond with anything, just compare UID
    await Future.delayed(
        const Duration(milliseconds: 500)); // Wait for card to reboot
    if (!operationCanContinue) return false;
    CardData? card = await communicator.scan14443aTag();
    if (!operationCanContinue) return false;
    final verified = card != null &&
            bytesToHex(card.uid) ==
                bytesToHex(data.sublist(0, card.uid.length)) ||
        card != null && bytesToHexSpace(card.uid) == dump.uid;
    if (verified) {
      _gen3WriteWasAmbiguous = false;
    }
    return verified;
  }
}
