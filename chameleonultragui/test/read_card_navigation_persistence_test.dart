import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
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

void main() {
  testWidgets('Read Card state survives switching tabs', (tester) async {
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
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = ChameleonCommunicator(logger, port: connector);

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

    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();

    final initialState = tester.state<ReadCardPageState>(
      find.byType(ReadCardPage),
    );
    final recovery = MifareClassicRecovery(
      appState: appState,
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

    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pumpAndSettle();
    expect(find.byType(ReadCardPage), findsNothing);
    expect(initialState.mounted, isFalse);
    expect(hfScanTimer.isActive, isFalse);
    expect(lfScanTimer.isActive, isFalse);

    recovery.update();
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();

    final restoredState = tester.state<ReadCardPageState>(
      find.byType(ReadCardPage),
    );
    expect(restoredState.hfInfo.uid, '01 02 03 04');
    expect(restoredState.mfcInfo.recovery, same(recovery));
    expect(recovery.update, restoredState.updateMifareClassicRecovery);
    expect(restoredState.isContinuousHFScan, isFalse);
    expect(restoredState.isContinuousLFScan, isFalse);
    expect(restoredState.scanInProgress, isFalse);
    expect(restoredState.hfScanTimer, isNull);
    expect(restoredState.lfScanTimer, isNull);
  });

  testWidgets('pending HF read cannot update the session after navigation',
      (tester) async {
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
    final communicator = _PendingHFCommunicator(logger, port: connector);
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
    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();

    final originalInfo = HFCardInfo(uid: 'persisted');
    appState.readCardSession.hfInfo = originalInfo;
    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    expect(communicator.scanStarted.isCompleted, isTrue);

    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pumpAndSettle();
    communicator.completeScan(CardData(
      uid: Uint8List.fromList([1, 2, 3, 4]),
      sak: 0x08,
      atqa: Uint8List.fromList([0x00, 0x04]),
      ats: Uint8List(0),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(communicator.detectCalls, 0);
    expect(appState.readCardSession.hfInfo, same(originalInfo));
    expect(appState.readCardSession.hfInfo.uid, 'persisted');
  });

  testWidgets('pending LF read cannot update the session after navigation',
      (tester) async {
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
    final communicator = _PendingLFCommunicator(logger, port: connector);
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
    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').last);
    await tester.pump();
    expect(communicator.readStarted.isCompleted, isTrue);
    final pendingInfo = appState.readCardSession.lfInfo;

    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pumpAndSettle();
    communicator.completeRead(null);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(communicator.followUpCalls, 0);
    expect(appState.readCardSession.lfInfo, same(pendingInfo));
    expect(appState.readCardSession.lfInfo.card, isNull);
    expect(appState.readCardSession.lfInfo.cardExist, isTrue);
  });
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
    return true;
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
