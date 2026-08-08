import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/read_card_session.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mifareUltralightGetVersionCommand = 0x60;
const _mifareUltralightReadSignatureCommand = 0x3C;

void main() {
  testWidgets('Read Card keeps running while another tab is visible', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(tester);
    final initialState = await fixture.openReadCard();
    final recovery = MifareClassicRecovery(
      appState: fixture.appState,
      update: initialState.updateMifareClassicRecovery,
      localizations: await AppLocalizations.delegate.load(const Locale('en')),
      mifareClassicType: MifareClassicType.m1k,
    );
    final hfScanTimer = Timer.periodic(const Duration(minutes: 5), (_) {});
    final lfScanTimer = Timer.periodic(const Duration(minutes: 5), (_) {});
    addTearDown(hfScanTimer.cancel);
    addTearDown(lfScanTimer.cancel);
    initialState
      ..hfInfo = HFCardInfo(
        uid: '01 02 03 04',
        sak: '08',
        atqa: '00 04',
        tech: 'MIFARE Classic 1K',
      )
      ..mfcInfo = (MifareClassicInfo(
        type: MifareClassicType.m1k,
        state: MifareClassicState.recovery,
      )..recovery = recovery)
      ..isContinuousHFScan = true
      ..isContinuousLFScan = true
      ..scanInProgress = true
      ..hfScanTimer = hfScanTimer
      ..lfScanTimer = lfScanTimer
      ..updateMifareClassicInfo();
    await tester.pump();

    expect(find.textContaining('01 02 03 04'), findsOneWidget);

    await fixture.openSavedCards();
    expect(find.byType(ReadCardPage), findsNothing);
    expect(find.byType(ReadCardPage, skipOffstage: false), findsOneWidget);
    expect(initialState.mounted, isTrue);
    expect(hfScanTimer.isActive, isTrue);
    expect(lfScanTimer.isActive, isTrue);

    recovery.update();
    await tester.pump();
    expect(tester.takeException(), isNull);

    final restoredState = await fixture.openReadCard();
    expect(restoredState, same(initialState));
    expect(restoredState.hfInfo.uid, '01 02 03 04');
    expect(restoredState.mfcInfo.recovery, same(recovery));
    expect(recovery.update, restoredState.updateMifareClassicRecovery);
    expect(restoredState.isContinuousHFScan, isTrue);
    expect(restoredState.isContinuousLFScan, isTrue);
    expect(restoredState.scanInProgress, isTrue);
    expect(restoredState.hfScanTimer, same(hfScanTimer));
    expect(restoredState.lfScanTimer, same(lfScanTimer));
    expect(hfScanTimer.isActive, isTrue);
    expect(lfScanTimer.isActive, isTrue);
  });

  testWidgets('pending HF read updates the session while Read Card is hidden', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _PendingHFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _PendingHFCommunicator;
    final initialState = await fixture.openReadCard();

    final originalInfo = HFCardInfo(uid: 'persisted');
    fixture.appState.readCardSession.hfInfo = originalInfo;
    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    expect(communicator.scanStarted.isCompleted, isTrue);

    await fixture.openSavedCards();
    expect(find.byType(ReadCardPage), findsNothing);
    expect(initialState.mounted, isTrue);
    communicator.completeScan(
      CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(communicator.detectCalls, 1);
    expect(
      fixture.appState.readCardSession.hfInfo,
      isNot(same(originalInfo)),
    );
    expect(fixture.appState.readCardSession.hfInfo.uid, '01 02 03 04');

    expect(await fixture.openReadCard(), same(initialState));
    expect(find.textContaining('01 02 03 04'), findsOneWidget);
  });

  testWidgets('pending LF read updates the session while Read Card is hidden', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _PendingLFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _PendingLFCommunicator;
    final initialState = await fixture.openReadCard();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').last);
    await tester.pump();
    expect(communicator.readStarted.isCompleted, isTrue);
    final pendingInfo = fixture.appState.readCardSession.lfInfo;

    await fixture.openSavedCards();
    expect(find.byType(ReadCardPage), findsNothing);
    expect(initialState.mounted, isTrue);
    final card = EM410XCard.fromUID('0102030405');
    communicator.completeRead(card);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(communicator.followUpCalls, 0);
    expect(fixture.appState.readCardSession.lfInfo, same(pendingInfo));
    expect(fixture.appState.readCardSession.lfInfo.card, same(card));
    expect(fixture.appState.readCardSession.lfInfo.cardExist, isTrue);

    expect(await fixture.openReadCard(), same(initialState));
    expect(find.textContaining('01 02 03 04 05'), findsOneWidget);
  });

  testWidgets('disconnect disposes hidden Read Card and cancels its timers', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(tester);
    final readCardState = await fixture.openReadCard();
    final hfScanTimer = Timer.periodic(const Duration(minutes: 5), (_) {});
    final lfScanTimer = Timer.periodic(const Duration(minutes: 5), (_) {});
    addTearDown(hfScanTimer.cancel);
    addTearDown(lfScanTimer.cancel);
    readCardState
      ..isContinuousHFScan = true
      ..isContinuousLFScan = true
      ..hfScanTimer = hfScanTimer
      ..lfScanTimer = lfScanTimer;

    await fixture.openSavedCards();
    expect(readCardState.mounted, isTrue);

    await fixture.appState.disconnect(manual: true);
    await tester.pumpAndSettle();

    expect(find.byType(ReadCardPage, skipOffstage: false), findsNothing);
    expect(readCardState.mounted, isFalse);
    expect(hfScanTimer.isActive, isFalse);
    expect(lfScanTimer.isActive, isFalse);
  });

  testWidgets(
      'delayed HF response after disconnect cannot continue or mutate session',
      (tester) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _PendingHFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _PendingHFCommunicator;
    final readCardState = await fixture.openReadCard();
    final originalInfo = HFCardInfo(uid: 'persisted');
    fixture.appState.readCardSession.hfInfo = originalInfo;

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    expect(communicator.scanStarted.isCompleted, isTrue);

    await fixture.connector.performDisconnect();
    expect(readCardState.mounted, isTrue);
    communicator.completeScan(
      CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      ),
    );
    await tester.idle();

    expect(tester.takeException(), isNull);
    expect(communicator.detectCalls, 0);
    expect(fixture.appState.readCardSession.hfInfo, same(originalInfo));
    expect(fixture.appState.readCardSession.hfInfo.uid, 'persisted');
  });

  testWidgets(
      'delayed LF response after disconnect cannot continue or mutate session',
      (tester) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _PendingLFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _PendingLFCommunicator;
    final readCardState = await fixture.openReadCard();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').last);
    await tester.pump();
    expect(communicator.readStarted.isCompleted, isTrue);
    final pendingInfo = fixture.appState.readCardSession.lfInfo;

    await fixture.connector.performDisconnect();
    expect(readCardState.mounted, isTrue);
    communicator.completeRead(null);
    await tester.idle();

    expect(tester.takeException(), isNull);
    expect(communicator.followUpCalls, 0);
    expect(fixture.appState.readCardSession.lfInfo, same(pendingInfo));
    expect(pendingInfo.card, isNull);
  });

  testWidgets('foreground page State survives connection changes',
      (tester) async {
    final fixture = await _ReadCardFixture.mount(tester);
    await fixture.openSavedCards();
    final initialState = tester.state<SavedCardsPageState>(
      find.byType(SavedCardsPage),
    );

    await fixture.connector.performDisconnect();
    await tester.pumpAndSettle();
    expect(
      tester.state<SavedCardsPageState>(find.byType(SavedCardsPage)),
      same(initialState),
    );

    fixture.reconnect();
    await tester.pumpAndSettle();
    expect(
      tester.state<SavedCardsPageState>(find.byType(SavedCardsPage)),
      same(initialState),
    );
  });

  testWidgets('real continuous HF scan executes again while offstage',
      (tester) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousHFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _ContinuousHFCommunicator;
    final readCardState = await fixture.openReadCard();

    await readCardState.startContinuousHFScan();
    expect(communicator.scanCalls, 1);

    await fixture.openSavedCards();
    await tester.pump(const Duration(seconds: 2));
    await tester.idle();

    expect(communicator.scanCalls, 2);
    expect(readCardState.mounted, isTrue);
    expect(readCardState.hfScanTimer?.isActive, isTrue);
    readCardState.stopContinuousHFScan();
    await tester.pump();
  });

  testWidgets('real continuous LF scan executes again while offstage',
      (tester) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousLFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _ContinuousLFCommunicator;
    final readCardState = await fixture.openReadCard();

    await readCardState.startContinuousLFScan();
    expect(communicator.readCalls, 1);

    await fixture.openSavedCards();
    await tester.pump(const Duration(seconds: 2));
    await tester.idle();

    expect(communicator.readCalls, 2);
    expect(readCardState.mounted, isTrue);
    expect(readCardState.lfScanTimer?.isActive, isTrue);
    readCardState.stopContinuousLFScan();
    await tester.pump();
  });

  testWidgets('DFU mode removes the persistent Read Card page', (tester) async {
    final fixture = await _ReadCardFixture.mount(tester);
    final readCardState = await fixture.openReadCard();
    await fixture.openSavedCards();
    expect(readCardState.mounted, isTrue);

    fixture.connector.isDFU = true;
    fixture.appState.changesMade();
    await tester.pump();

    expect(find.byType(ReadCardPage, skipOffstage: false), findsNothing);
    expect(readCardState.mounted, isFalse);
  });
}

typedef _CommunicatorFactory = ChameleonCommunicator Function(
  Logger logger,
  EmulatorSerial connector,
);

class _ReadCardFixture {
  _ReadCardFixture({
    required this.tester,
    required this.logger,
    required this.connector,
    required this.appState,
    required this.communicator,
  });

  final WidgetTester tester;
  final Logger logger;
  final EmulatorSerial connector;
  final ChameleonGUIState appState;
  final ChameleonCommunicator communicator;

  static Future<_ReadCardFixture> mount(
    WidgetTester tester, {
    _CommunicatorFactory? communicatorFactory,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/wakelock'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    final connector = EmulatorSerial(log: logger)
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb;
    final communicator = communicatorFactory?.call(logger, connector) ??
        ChameleonCommunicator(logger, port: connector);
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;

    tester.view.physicalSize = const Size(3000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MainPage(sharedPreferencesProvider: preferences),
      ),
    );
    await tester.pump();

    return _ReadCardFixture(
      tester: tester,
      logger: logger,
      connector: connector,
      appState: appState,
      communicator: communicator,
    );
  }

  Future<ReadCardPageState> openReadCard() async {
    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();
    return tester.state<ReadCardPageState>(find.byType(ReadCardPage));
  }

  Future<void> openSavedCards() async {
    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pumpAndSettle();
  }

  void reconnect() {
    connector
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb;
    appState
      ..communicator = ChameleonCommunicator(logger, port: connector)
      ..changesMade();
  }
}

class _PendingHFCommunicator extends ChameleonCommunicator {
  _PendingHFCommunicator(super.logger, {super.port});

  final Completer<void> scanStarted = Completer<void>();
  final Completer<CardData?> _scanResult = Completer<CardData?>();
  int detectCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() {
    scanStarted.complete();
    return _scanResult.future;
  }

  @override
  Future<bool> detectMf1Support() async {
    detectCalls++;
    return false;
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
    if (data.first == _mifareUltralightGetVersionCommand) {
      return Uint8List.fromList([0, 0, 4, 2, 1, 0, 0x0F, 3]);
    }
    if (data.first == _mifareUltralightReadSignatureCommand) {
      return Uint8List(32);
    }
    return Uint8List(0);
  }

  void completeScan(CardData? card) => _scanResult.complete(card);
}

class _PendingLFCommunicator extends ChameleonCommunicator {
  _PendingLFCommunicator(super.logger, {super.port});

  final Completer<void> readStarted = Completer<void>();
  final Completer<EM410XCard?> _readResult = Completer<EM410XCard?>();
  int followUpCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<EM410XCard?> readEM410X() {
    readStarted.complete();
    return _readResult.future;
  }

  @override
  Future<HIDCard?> readHIDProx() async {
    followUpCalls++;
    return null;
  }

  @override
  Future<VikingCard?> readViking() async {
    followUpCalls++;
    return null;
  }

  @override
  Future<PacCard?> readPac() async {
    followUpCalls++;
    return null;
  }

  @override
  Future<IoProxCard?> readIoProx() async {
    followUpCalls++;
    return null;
  }

  void completeRead(EM410XCard? card) => _readResult.complete(card);
}

class _ContinuousHFCommunicator extends ChameleonCommunicator {
  _ContinuousHFCommunicator(super.logger, {super.port});

  int scanCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() async {
    scanCalls++;
    return null;
  }
}

class _ContinuousLFCommunicator extends ChameleonCommunicator {
  _ContinuousLFCommunicator(super.logger, {super.port});

  int readCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<EM410XCard?> readEM410X() async {
    readCalls++;
    return null;
  }

  @override
  Future<HIDCard?> readHIDProx() async => null;

  @override
  Future<VikingCard?> readViking() async => null;

  @override
  Future<PacCard?> readPac() async => null;

  @override
  Future<IoProxCard?> readIoProx() async => null;
}
