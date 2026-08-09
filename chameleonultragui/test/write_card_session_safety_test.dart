import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/write_card.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/base.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen2.dart';
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

  testWidgets(
      'production T55 write skips read-back after communicator replacement',
      (tester) async {
    late ChameleonGUIState appState;
    final fixture = await _pumpWriter(
      tester,
      (logger) => _T55WriteCommunicator(
        logger,
        afterWrite: () => appState.communicator = ChameleonCommunicator(logger),
      ),
    );
    appState = fixture.appState;
    final communicator = fixture.communicator as _T55WriteCommunicator;
    fixture.state
      ..card = _em410xCard()
      ..helper = BaseT55XXCardHelper(
        communicator,
        operationCanContinue: () => true,
      );

    final write = fixture.state.writeCard();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 501));
    await write;

    expect(communicator.writes, 1);
    expect(communicator.reads, 0);
  });

  testWidgets('production Magic write stops after a DFU transition',
      (tester) async {
    late _TestSerial connector;
    final fixture = await _pumpWriter(
      tester,
      (logger) => _ClassicWriteCommunicator(
        logger,
        afterWrite: () => connector.isDFU = true,
      ),
    );
    connector = fixture.connector;
    final communicator = fixture.communicator as _ClassicWriteCommunicator;
    final helper = MifareClassicGen2WriteHelper(
      communicator,
      recovery: await _recoveryFor(fixture.appState),
      operationCanContinue: () => true,
    )
      ..type = MifareClassicType.m1k
      ..isEV1 = false;
    fixture.state
      ..card = _classicCard()
      ..helper = helper;

    final write = fixture.state.writeCard();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await write;

    expect(communicator.writes, 1);
  });

  testWidgets('production write rejects a helper from a previous connection',
      (tester) async {
    final fixture = await _pumpWriter(tester, _T55WriteCommunicator.new);
    final staleCommunicator = fixture.communicator as _T55WriteCommunicator;
    final newConnector = _TestSerial(log: fixture.logger)..connected = true;
    fixture.appState
      ..connector = newConnector
      ..communicator = ChameleonCommunicator(fixture.logger);
    fixture.state
      ..card = _em410xCard()
      ..helper = BaseT55XXCardHelper(
        staleCommunicator,
        operationCanContinue: () => true,
      );

    final write = fixture.state.writeCard();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 501));
    await write;

    expect(staleCommunicator.writes, 0);
  });

  testWidgets('disposed production writer skips T55 read-back', (tester) async {
    final writeIssued = Completer<void>();
    final releaseWrite = Completer<void>();
    final fixture = await _pumpWriter(
      tester,
      (logger) => _T55WriteCommunicator(
        logger,
        writeIssued: writeIssued,
        releaseWrite: releaseWrite,
      ),
    );
    final communicator = fixture.communicator as _T55WriteCommunicator;
    fixture.state
      ..card = _em410xCard()
      ..helper = BaseT55XXCardHelper(
        communicator,
        operationCanContinue: () => true,
      );

    final write = fixture.state.writeCard();
    await writeIssued.future;
    await tester.pumpWidget(const SizedBox());
    releaseWrite.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 501));
    await write;

    expect(communicator.writes, 1);
    expect(communicator.reads, 0);
    expect(tester.takeException(), isNull);
  });

  test('Classic helper factory propagates its continuation predicate',
      () async {
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _ClassicWriteCommunicator(logger);
    final preferences = await _preferences();
    final appState = ChameleonGUIState(preferences)
      ..communicator = communicator;
    final baseHelper = BaseMifareClassicWriteHelper(
      communicator,
      recovery: await _recoveryFor(appState),
      operationCanContinue: () => false,
    );

    final helper = baseHelper.getAvailableMethods().first;
    final detected = await helper.isMagic(_classicCard());

    expect(detected, isFalse);
    expect(communicator.rawCommands, 0);
  });
}

Future<_WriterFixture> _pumpWriter(
  WidgetTester tester,
  ChameleonCommunicator Function(Logger logger) createCommunicator,
) async {
  final preferences = await _preferences();
  final logger = Logger(output: MemoryOutput());
  addTearDown(logger.close);
  final connector = _TestSerial(log: logger)
    ..connected = true
    ..device = ChameleonDevice.ultra;
  final communicator = createCommunicator(logger);
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
        home: const WriteCardPage(),
      ),
    ),
  );

  return _WriterFixture(
    appState: appState,
    connector: connector,
    communicator: communicator,
    logger: logger,
    state: tester.state<WriteCardPageState>(find.byType(WriteCardPage)),
  );
}

Future<SharedPreferencesProvider> _preferences() async {
  SharedPreferences.setMockInitialValues({});
  final preferences = SharedPreferencesProvider();
  await preferences.load();
  return preferences;
}

Future<MifareClassicRecovery> _recoveryFor(
  ChameleonGUIState appState,
) async {
  return MifareClassicRecovery(
    appState: appState,
    update: () {},
    localizations: await AppLocalizations.delegate.load(const Locale('en')),
    validKeys: List.generate(
      80,
      (_) => Uint8List.fromList(const [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
    ),
  );
}

CardSave _classicCard() => CardSave(
      uid: '01020304',
      name: 'Classic',
      tag: TagType.mifare1K,
      data: [Uint8List(16), Uint8List(16)],
    );

CardSave _em410xCard() => CardSave(
      uid: '0102030405',
      name: 'EM410X',
      tag: TagType.em410X,
    );

class _WriterFixture {
  const _WriterFixture({
    required this.appState,
    required this.connector,
    required this.communicator,
    required this.logger,
    required this.state,
  });

  final ChameleonGUIState appState;
  final _TestSerial connector;
  final ChameleonCommunicator communicator;
  final Logger logger;
  final WriteCardPageState state;
}

class _T55WriteCommunicator extends ChameleonCommunicator {
  _T55WriteCommunicator(
    super.log, {
    this.afterWrite,
    this.writeIssued,
    this.releaseWrite,
  });

  final void Function()? afterWrite;
  final Completer<void>? writeIssued;
  final Completer<void>? releaseWrite;
  int writes = 0;
  int reads = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<void> writeEM410XtoT55XX(
    Uint8List uid,
    Uint8List newKey,
    List<Uint8List> oldKeys,
  ) async {
    writes++;
    afterWrite?.call();
    writeIssued?.complete();
    await releaseWrite?.future;
  }

  @override
  Future<EM410XCard?> readEM410X() async {
    reads++;
    return null;
  }
}

class _ClassicWriteCommunicator extends ChameleonCommunicator {
  _ClassicWriteCommunicator(super.log, {this.afterWrite});

  final void Function()? afterWrite;
  int writes = 0;
  int rawCommands = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() async => CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      );

  @override
  Future<bool> mf1WriteBlock(
    int block,
    int keyType,
    Uint8List key,
    Uint8List data,
  ) async {
    writes++;
    afterWrite?.call();
    return true;
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
    rawCommands++;
    return Uint8List.fromList([0x0A]);
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
