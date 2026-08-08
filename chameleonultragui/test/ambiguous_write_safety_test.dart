import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/tools/t55xx_password_cleaner.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen1.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen2.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen3.dart';
import 'package:chameleonultragui/helpers/t55xx/write/base.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
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

  test('Gen1 does not retry a block after an issued write loses its response',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(logger);
    final helper = MifareClassicGen1WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeBlock(1, Uint8List(16));

    expect(result, isFalse);
    expect(communicator.classicRawWrites, 1);
  });

  test('Gen1 does not retry a block after an empty write response', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(
      logger,
      emptyClassicWriteResponse: true,
    );
    final helper = MifareClassicGen1WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeBlock(1, Uint8List(16));

    expect(result, isFalse);
    expect(communicator.classicRawWrites, 1);
  });

  test('Gen1 may retry an explicit write rejection', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(
      logger,
      rejectFirstClassicWrite: true,
    );
    final helper = MifareClassicGen1WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeBlock(1, Uint8List(16));

    expect(result, isTrue);
    expect(communicator.classicRawWrites, 2);
  });

  test('Gen2 does not try another key after an issued write loses its response',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(logger);
    final helper = MifareClassicGen2WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeBlockModifier(
      _classicCard(),
      1,
      Uint8List(16),
      tryBothKeys: true,
    );

    expect(result, isFalse);
    expect(communicator.authenticatedWrites, 1);
  });

  test('Gen2 full write stops after an ambiguous trailer write', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(
      logger,
      returnScannedCard: true,
    );
    final helper = MifareClassicGen2WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeData(
      _classicCardWithData([
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

  test('Gen2 full write may try another key after an explicit rejection',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(
      logger,
      returnScannedCard: true,
      rejectFirstAuthenticatedWrite: true,
    );
    final helper = MifareClassicGen2WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeData(
      _classicCardWithData([Uint8List(16)]),
      (_) {},
    );

    expect(result, isTrue);
    expect(communicator.authenticatedWrites, 2);
  });

  test('Gen3 does not retry block 0 after an issued write loses its response',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(logger);
    final helper = MifareClassicGen3WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeBlockModifier(
      _classicCard(),
      0,
      Uint8List(16),
    );

    expect(result, isFalse);
    expect(communicator.gen3Writes, 1);
  });

  test('Gen3 full write stops after an ambiguous block-zero write', () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(
      logger,
      returnScannedCard: true,
    );
    final helper = MifareClassicGen3WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    );

    final result = await helper.writeData(
      _classicCardWithData([
        Uint8List(16),
        Uint8List.fromList(List.filled(16, 0x01)),
      ]),
      (_) {},
    );

    expect(result, isFalse);
    expect(communicator.gen3Writes, 1);
    expect(communicator.authenticatedWrites, 0);
  });

  test('Gen3 does not retain an ambiguous outcome across full writes',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _AmbiguousWriteCommunicator(
      logger,
      completeGen3Write: true,
      returnScannedCard: true,
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
      _classicCardWithData([
        verifiedBlockZero,
        Uint8List(16),
      ]),
      (_) {},
    );
    final verifiedResult = await helper.writeData(
      _classicCardWithData([verifiedBlockZero]),
      (_) {},
    );

    expect(ambiguousResult, isFalse);
    expect(verifiedResult, isTrue);
    expect(communicator.authenticatedWrites, 1);
    expect(communicator.gen3Writes, 4);
  });

  test('Gen3 skips read-back after its captured session becomes stale',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    var sessionCurrent = true;
    final communicator = _AmbiguousWriteCommunicator(
      logger,
      completeGen3Write: true,
      afterGen3Write: () => sessionCurrent = false,
    );
    final helper = MifareClassicGen3WriteHelper(
      communicator,
      recovery: await recoveryFor(communicator),
    )..setOperationContinuation(() => sessionCurrent);

    final result = await helper.writeBlockModifier(
      _classicCard(),
      0,
      Uint8List(16),
    );

    expect(result, isFalse);
    expect(communicator.gen3Writes, 1);
    expect(communicator.scans, 0);
  });

  test('T55 helper skips stale-session read-back after an issued write',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _CompletedT55WriteCommunicator(logger);
    final helper = BaseT55XXCardHelper(communicator);
    var sessionCurrent = true;
    helper.setOperationContinuation(() => sessionCurrent);
    communicator.afterWrite = () => sessionCurrent = false;

    final result = await helper.writeData(_em410xCard(), (_) {});

    expect(result, isFalse);
    expect(communicator.writes, 1);
    expect(communicator.reads, 0);
  });

  testWidgets(
      'T55 password cleaner stops after an issued write loses its response',
      (tester) async {
    final communicator = await _runPasswordCleaner(
      tester,
      (logger) => _AmbiguousT55WriteCommunicator(logger),
    );

    expect(communicator.writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'T55 password cleaner stops when read-back fails after an issued write',
      (tester) async {
    final communicator = await _runPasswordCleaner(
      tester,
      (logger) => _AmbiguousT55ReadCommunicator(logger),
    );

    expect(communicator.writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'T55 password cleaner stops when read-back is null after an issued write',
      (tester) async {
    final communicator = await _runPasswordCleaner(
      tester,
      (logger) => _CompletedT55WriteCommunicator(logger),
    );

    expect(communicator.writes, 1);
    expect(communicator.reads, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<T> _runPasswordCleaner<T extends ChameleonCommunicator>(
  WidgetTester tester,
  T Function(Logger logger) createCommunicator,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = SharedPreferencesProvider();
  await preferences.load();
  preferences.setDictionaries([
    Dictionary(
      id: 'test-passwords',
      name: 'Test passwords',
      keyLength: 8,
      keys: [
        Uint8List.fromList([1, 2, 3, 4]),
        Uint8List.fromList([5, 6, 7, 8]),
      ],
    ),
  ]);
  final logger = Logger(output: MemoryOutput());
  addTearDown(logger.close);
  final communicator = createCommunicator(logger);
  final connector = _TestSerial(log: logger)..connected = true;
  final appState = ChameleonGUIState(preferences)
    ..log = logger
    ..connector = connector
    ..communicator = communicator;

  await tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: T55XXPasswordCleanerMenu()),
      ),
    ),
  );
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Test passwords').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Start password reset'));
  await tester.pumpAndSettle();

  return communicator;
}

CardSave _classicCard() => CardSave(
      uid: '01020304',
      name: 'Classic',
      tag: TagType.mifare1K,
    );

CardSave _classicCardWithData(List<Uint8List> data) => CardSave(
      uid: '01020304',
      name: 'Classic',
      tag: TagType.mifare1K,
      data: data,
    );

CardSave _em410xCard() => CardSave(
      uid: '0102030405',
      name: 'EM410X',
      tag: TagType.em410X,
    );

class _AmbiguousWriteCommunicator extends ChameleonCommunicator {
  _AmbiguousWriteCommunicator(
    super.log, {
    this.emptyClassicWriteResponse = false,
    this.rejectFirstClassicWrite = false,
    this.completeGen3Write = false,
    this.afterGen3Write,
    this.returnScannedCard = false,
    this.rejectFirstAuthenticatedWrite = false,
  });

  final bool emptyClassicWriteResponse;
  final bool rejectFirstClassicWrite;
  final bool completeGen3Write;
  final void Function()? afterGen3Write;
  final bool returnScannedCard;
  final bool rejectFirstAuthenticatedWrite;
  int classicRawWrites = 0;
  int authenticatedWrites = 0;
  int gen3Writes = 0;
  int scans = 0;

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
    if (data.length == 16) {
      classicRawWrites++;
      if (emptyClassicWriteResponse) {
        return Uint8List(0);
      }
      if (rejectFirstClassicWrite && classicRawWrites == 1) {
        return Uint8List.fromList([0x00]);
      }
      if (rejectFirstClassicWrite) {
        return Uint8List.fromList([0x0A]);
      }
      throw StateError('write response lost');
    }
    if (data.length > 2 && data[0] == 0x90) {
      gen3Writes++;
      if (completeGen3Write) {
        afterGen3Write?.call();
        return Uint8List(0);
      }
      throw StateError('write response lost');
    }
    return Uint8List.fromList([0x0A]);
  }

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
  Future<CardData?> scan14443aTag() async {
    scans++;
    if (returnScannedCard) {
      return CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      );
    }
    return null;
  }
}

class _CompletedT55WriteCommunicator extends ChameleonCommunicator {
  _CompletedT55WriteCommunicator(super.log);

  int writes = 0;
  int reads = 0;
  void Function()? afterWrite;

  @override
  Future<void> writeEM410XtoT55XX(
    Uint8List uid,
    Uint8List newKey,
    List<Uint8List> oldKeys,
  ) async {
    writes++;
    afterWrite?.call();
  }

  @override
  Future<EM410XCard?> readEM410X() async {
    reads++;
    return null;
  }
}

class _AmbiguousT55WriteCommunicator extends ChameleonCommunicator {
  _AmbiguousT55WriteCommunicator(super.log);

  int writes = 0;

  @override
  Future<void> writeEM410XtoT55XX(
    Uint8List uid,
    Uint8List newKey,
    List<Uint8List> oldKeys,
  ) async {
    writes++;
    throw StateError('write response lost');
  }
}

class _AmbiguousT55ReadCommunicator extends ChameleonCommunicator {
  _AmbiguousT55ReadCommunicator(super.log);

  int writes = 0;

  @override
  Future<void> writeEM410XtoT55XX(
    Uint8List uid,
    Uint8List newKey,
    List<Uint8List> oldKeys,
  ) async {
    writes++;
  }

  @override
  Future<EM410XCard?> readEM410X() async {
    throw StateError('read-back response lost');
  }
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log}) {
    connectionType = ConnectionType.usb;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
