import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
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
}
