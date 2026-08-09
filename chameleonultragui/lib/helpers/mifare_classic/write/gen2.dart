import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/base.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/foundation.dart' show protected;

enum MifareClassicMagicWriteOutcome {
  success,
  rejected,
  ambiguous;

  bool get succeeded => this == MifareClassicMagicWriteOutcome.success;
}

class MifareClassicGen2WriteHelper extends BaseMifareClassicWriteHelper {
  List<int> failedBlocks = [];

  MifareClassicGen2WriteHelper(super.communicator, {required super.recovery});

  @override
  String get name => "gen2";

  static String get staticName => "gen2";

  @override
  Future<bool> isMagic(dynamic data) async {
    if (!operationCanContinue) return false;
    CardSave cardSave = data;
    CardData? card = await communicator.scan14443aTag();
    if (card == null || !operationCanContinue) {
      return false;
    }

    if (cardSave.uid == bytesToHexSpace(card.uid)) {
      return true; // if UID matches we can assume it is same card
    }

    return false; // we can't check
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

  Future<bool> writeBlockModifier(CardSave card, int block, Uint8List data,
          {bool tryBothKeys = false, bool useGenericKey = false}) async =>
      (await writeBlockModifierOutcome(
        card,
        block,
        data,
        tryBothKeys: tryBothKeys,
        useGenericKey: useGenericKey,
      ))
          .succeeded;

  @protected
  Future<MifareClassicMagicWriteOutcome> writeBlockModifierOutcome(
      CardSave card, int block, Uint8List data,
      {bool tryBothKeys = false, bool useGenericKey = false}) async {
    for (int retry = 0; retry < 10; retry++) {
      if (!operationCanContinue) {
        return MifareClassicMagicWriteOutcome.rejected;
      }
      try {
        await Future.delayed(
            const Duration(milliseconds: 50)); // Stability delay
        if (!operationCanContinue) {
          return MifareClassicMagicWriteOutcome.rejected;
        }
        final outcome = await writeSingleBlockOutcome(
          card,
          block,
          data,
          tryBothKeys: tryBothKeys,
          useGenericKey: useGenericKey,
        );
        switch (outcome) {
          case MifareClassicMagicWriteOutcome.success:
            return operationCanContinue
                ? outcome
                : MifareClassicMagicWriteOutcome.rejected;
          case MifareClassicMagicWriteOutcome.ambiguous:
            return outcome;
          case MifareClassicMagicWriteOutcome.rejected:
            break;
        }
        if (!operationCanContinue) {
          return MifareClassicMagicWriteOutcome.rejected;
        }
        await Future.delayed(const Duration(milliseconds: 150));
        if (!operationCanContinue) {
          return MifareClassicMagicWriteOutcome.rejected;
        }
      } catch (_) {
        // Only failures before the typed write boundary remain retryable.
      }
    }

    return MifareClassicMagicWriteOutcome.rejected;
  }

  @protected
  Future<MifareClassicMagicWriteOutcome> writeSingleBlockOutcome(
      CardSave card, int block, Uint8List data,
      {bool tryBothKeys = false, bool useGenericKey = false}) {
    return writeBlockOutcome(
      block,
      data,
      tryBothKeys: tryBothKeys,
      useGenericKey: useGenericKey,
    );
  }

  @override
  Future<bool> writeBlock(int block, Uint8List data,
          {bool tryBothKeys = false, bool useGenericKey = false}) async =>
      (await writeBlockOutcome(
        block,
        data,
        tryBothKeys: tryBothKeys,
        useGenericKey: useGenericKey,
      ))
          .succeeded &&
      operationCanContinue;

  @protected
  Future<MifareClassicMagicWriteOutcome> writeBlockOutcome(
      int block, Uint8List data,
      {bool tryBothKeys = false, bool useGenericKey = false}) async {
    if (!operationCanContinue) {
      return MifareClassicMagicWriteOutcome.rejected;
    }
    final sector = mfClassicGetSectorByBlock(block);
    final keys = <(int, Uint8List)>[
      (
        0x60,
        useGenericKey ? gMifareClassicKeys[0] : recovery.validKeys[sector],
      ),
    ];
    if (useGenericKey) {
      keys.add((0x60, recovery.validKeys[sector]));
    }
    if (tryBothKeys) {
      keys.add((
        0x61,
        useGenericKey ? gMifareClassicKeys[0] : recovery.validKeys[40 + sector],
      ));
      if (useGenericKey) {
        keys.add((0x61, recovery.validKeys[40 + sector]));
      }
    }

    for (final (keyType, key) in keys) {
      if (!operationCanContinue) {
        return MifareClassicMagicWriteOutcome.rejected;
      }
      final outcome = await writeAuthenticatedBlock(
        block,
        keyType,
        key,
        data,
      );
      switch (outcome) {
        case MifareClassicMagicWriteOutcome.success:
        case MifareClassicMagicWriteOutcome.ambiguous:
          return outcome;
        case MifareClassicMagicWriteOutcome.rejected:
          break;
      }
      if (!operationCanContinue) {
        return MifareClassicMagicWriteOutcome.rejected;
      }
    }

    return MifareClassicMagicWriteOutcome.rejected;
  }

  @protected
  Future<MifareClassicMagicWriteOutcome> writeAuthenticatedBlock(
    int block,
    int keyType,
    Uint8List key,
    Uint8List data,
  ) async {
    try {
      final result = await communicator.mf1WriteBlock(
        block,
        keyType,
        key,
        data,
      );
      if (!operationCanContinue) {
        return MifareClassicMagicWriteOutcome.rejected;
      }
      return result
          ? MifareClassicMagicWriteOutcome.success
          : MifareClassicMagicWriteOutcome.rejected;
    } catch (_) {
      return MifareClassicMagicWriteOutcome.ambiguous;
    }
  }

  @override
  Future<bool> writeData(
      CardSave card, Function(int writeProgress) update) async {
    if (!operationCanContinue) return false;
    List<Uint8List> data = card.data;
    List<bool> cleanSectors = List.generate(40, (index) => false);
    failedBlocks = [];

    try {
      await communicator.scan14443aTag();
    } catch (e) {
      return false;
    }
    if (!operationCanContinue) return false;

    if (data.isEmpty || data[0].isEmpty) {
      if (data.isEmpty) {
        data = [Uint8List(0)];
      }
      data[0] = createBlock0FromSave(card);
    }

    for (var sector = 0; sector < mfClassicGetSectorCount(type); sector++) {
      if (!operationCanContinue) return false;
      var block = mfClassicGetSectorTrailerBlockBySector(sector);
      if (data.length > block && data[block].isNotEmpty) {
        final outcome = await writeBlockModifierOutcome(
            card, block, data[block],
            tryBothKeys: true);
        switch (outcome) {
          case MifareClassicMagicWriteOutcome.success:
            cleanSectors[sector] = true;
          case MifareClassicMagicWriteOutcome.rejected:
            cleanSectors[sector] = false;
          case MifareClassicMagicWriteOutcome.ambiguous:
            return false;
        }
        if (!operationCanContinue) return false;
        if (cleanSectors[sector]) {
          // Update keys to match the newly written trailer,
          // so subsequent data block writes use the correct keys.
          recovery.validKeys[sector] = data[block].sublist(0, 6);
          recovery.validKeys[40 + sector] = data[block].sublist(10, 16);
        }
      }
    }

    for (var sector = 0;
        sector < mfClassicGetSectorCount(type, isEV1: isEV1);
        sector++) {
      for (var block = 0;
          block < mfClassicGetBlockCountBySector(sector);
          block++) {
        int blockToWrite = block + mfClassicGetFirstBlockCountBySector(sector);
        if (mfClassicGetSectorTrailerBlockBySector(sector) == blockToWrite) {
          continue; // skip sector blocks for now
        }

        if (data.length > blockToWrite && data[blockToWrite].isNotEmpty) {
          if (!operationCanContinue) return false;
          final outcome = await writeBlockModifierOutcome(
              card, blockToWrite, data[blockToWrite],
              useGenericKey: cleanSectors[sector], tryBothKeys: true);
          late final bool writeSucceeded;
          switch (outcome) {
            case MifareClassicMagicWriteOutcome.success:
              writeSucceeded = true;
            case MifareClassicMagicWriteOutcome.rejected:
              writeSucceeded = false;
            case MifareClassicMagicWriteOutcome.ambiguous:
              return false;
          }
          if (!(writeSucceeded && cleanSectors[sector]) && blockToWrite != 0) {
            failedBlocks.add(blockToWrite);
          }

          if (!operationCanContinue) return false;

          update((blockToWrite / mfClassicGetBlockCount(type) * 100).round());
        }
      }
    }

    for (var sector = 0; sector < mfClassicGetSectorCount(type); sector++) {
      if (!operationCanContinue) return false;
      var block = mfClassicGetSectorTrailerBlockBySector(sector);
      if (cleanSectors[sector] &&
          data.length > block &&
          data[block].isNotEmpty) {
        final outcome = await writeBlockModifierOutcome(
          card,
          block,
          data[block],
          tryBothKeys: true,
          useGenericKey: true,
        );
        switch (outcome) {
          case MifareClassicMagicWriteOutcome.success:
            break;
          case MifareClassicMagicWriteOutcome.rejected:
            // how we went here? We set to default sector trailer and now we can't write to it. Probably card is lost
            return false;
          case MifareClassicMagicWriteOutcome.ambiguous:
            return false;
        }
        if (!operationCanContinue) return false;
      }
    }

    return failedBlocks.isEmpty;
  }

  @override
  List<int> getFailedBlocks() {
    return failedBlocks;
  }

  @override
  bool writeWidgetSupported() {
    return true;
  }
}
