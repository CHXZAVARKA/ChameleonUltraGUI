import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen2.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

class MifareClassicGen3WriteHelper extends MifareClassicGen2WriteHelper {
  MifareClassicGen3WriteHelper(super.communicator,
      {required super.recovery, required super.operationCanContinue});

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
  Future<MifareClassicMagicWriteOutcome> writeSingleBlockOutcome(
      CardSave card, int block, Uint8List data,
      {bool tryBothKeys = false, bool useGenericKey = false}) {
    if (block == 0) {
      return writeGen3BlockOutcome(card, data);
    }
    return super.writeSingleBlockOutcome(
      card,
      block,
      data,
      tryBothKeys: tryBothKeys,
      useGenericKey: useGenericKey,
    );
  }

  Future<bool> writeGen3Block(CardSave dump, Uint8List data) async =>
      (await writeGen3BlockOutcome(dump, data)).succeeded &&
      operationCanContinue;

  Future<MifareClassicMagicWriteOutcome> writeGen3BlockOutcome(
      CardSave dump, Uint8List data) async {
    if (!operationCanContinue) {
      return MifareClassicMagicWriteOutcome.rejected;
    }
    // Try to write whole block
    try {
      await communicator.send14ARaw(
          Uint8List.fromList([0x90, 0xFB, 0xCC, 0xCC, 0x10, ...data]),
          checkResponseCrc: false);
    } catch (_) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }

    // Try to write UID only
    if (!operationCanContinue) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }
    try {
      await communicator.send14ARaw(
          Uint8List.fromList(
              [0x90, 0xFB, 0xCC, 0xCC, 0x07, ...hexToBytes(dump.uid)]),
          checkResponseCrc: false);
    } catch (_) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }

    if (!operationCanContinue) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }

    // Card doesn't respond with anything, just compare UID
    await Future.delayed(
        const Duration(milliseconds: 500)); // Wait for card to reboot
    if (!operationCanContinue) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }
    CardData? card;
    try {
      card = await communicator.scan14443aTag();
    } catch (_) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }
    if (!operationCanContinue) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }
    try {
      final verified = card != null &&
              bytesToHex(card.uid) ==
                  bytesToHex(data.sublist(0, card.uid.length)) ||
          card != null && bytesToHexSpace(card.uid) == dump.uid;
      return verified
          ? MifareClassicMagicWriteOutcome.success
          : MifareClassicMagicWriteOutcome.ambiguous;
    } catch (_) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }
  }
}
