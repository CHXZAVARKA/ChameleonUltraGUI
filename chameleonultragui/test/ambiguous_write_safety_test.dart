import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen2.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen3.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MifareClassicRecovery> recoveryFor(
    ChameleonCommunicator communicator,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    return MifareClassicRecovery(
      appState: ChameleonGUIState(preferences)..communicator = communicator,
      update: () {},
      localizations: await AppLocalizations.delegate.load(const Locale('en')),
      validKeys: List.generate(
        80,
        (_) => Uint8List.fromList(const [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
      ),
    );
  }

  test('Gen2 full write stops after an ambiguous trailer write', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _WriteCommunicator(logger, returnScannedCard: true);
    final helper = MifareClassicGen2WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeData(
      _classicCard([
        Uint8List(16),
        Uint8List(16),
        Uint8List(16),
        Uint8List.fromList(List.filled(16, 0xFF)),
      ]),
      (_) {},
    );

    expect(result, isFalse);
    expect(communicator.authenticatedWrites, 1);
  });

  test('Gen2 may try another key after an explicit rejection', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _WriteCommunicator(
      logger,
      returnScannedCard: true,
      rejectFirstAuthenticatedWrite: true,
    );
    final helper = MifareClassicGen2WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    expect(
      await helper.writeData(_classicCard([Uint8List(16)]), (_) {}),
      isTrue,
    );
    expect(communicator.authenticatedWrites, 2);
  });

  test('Gen3 full write stops after an ambiguous block-zero write', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _WriteCommunicator(logger, returnScannedCard: true);
    final helper = MifareClassicGen3WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeData(
      _classicCard([
        Uint8List(16),
        Uint8List.fromList(List.filled(16, 0x01)),
      ]),
      (_) {},
    );

    expect(result, isFalse);
    expect(communicator.gen3Writes, 1);
    expect(communicator.authenticatedWrites, 0);
  });

  test('Gen3 stops before the next block and resets for a later write',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _WriteCommunicator(
      logger,
      returnScannedCard: true,
      completeGen3Write: true,
    );
    final helper = MifareClassicGen3WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );
    final verifiedBlockZero = Uint8List.fromList([
      0x01,
      0x02,
      0x03,
      0x04,
      ...List.filled(12, 0),
    ]);

    final ambiguousResult = await helper.writeData(
      _classicCard([
        verifiedBlockZero,
        Uint8List(16),
        Uint8List.fromList(List.filled(16, 0x02)),
      ]),
      (_) {},
    );

    expect(ambiguousResult, isFalse);
    expect(communicator.authenticatedWrites, 1);

    final laterResult = await helper.writeData(
      _classicCard([verifiedBlockZero]),
      (_) {},
    );

    expect(laterResult, isTrue);
    expect(communicator.authenticatedWrites, 1);
    expect(communicator.gen3Writes, 4);
  });
}

CardSave _classicCard(List<Uint8List> data) => CardSave(
      uid: '01020304',
      name: 'Classic',
      tag: TagType.mifare1K,
      data: data,
    );

class _WriteCommunicator extends ChameleonCommunicator {
  _WriteCommunicator(
    super.log, {
    required this.returnScannedCard,
    this.rejectFirstAuthenticatedWrite = false,
    this.completeGen3Write = false,
  });

  final bool returnScannedCard;
  final bool rejectFirstAuthenticatedWrite;
  final bool completeGen3Write;
  int authenticatedWrites = 0;
  int gen3Writes = 0;

  @override
  Future<bool> mf1WriteBlock(
    int block,
    int keyType,
    Uint8List key,
    Uint8List data,
  ) async {
    authenticatedWrites++;
    if (rejectFirstAuthenticatedWrite) {
      return authenticatedWrites > 1;
    }
    throw StateError('write response lost');
  }

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
    if (data.length > 2 && data[0] == 0x90) {
      gen3Writes++;
      if (completeGen3Write) {
        return Uint8List(0);
      }
      throw StateError('write response lost');
    }
    return Uint8List.fromList([0x0A]);
  }

  @override
  Future<CardData?> scan14443aTag() async {
    if (!returnScannedCard) return null;
    return CardData(
      uid: Uint8List.fromList([1, 2, 3, 4]),
      sak: 0x08,
      atqa: Uint8List.fromList([0x00, 0x04]),
      ats: Uint8List(0),
    );
  }
}
