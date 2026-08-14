import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/mifare/classic.dart';
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
  test('initialization stops shared type detection after reconnect', () async {
    final oldCommunicator = _DelayedTypeCommunicator();
    final appState = _connectedState(oldCommunicator);
    final recovery = await _recovery(appState)
      ..mifareClassicType = MifareClassicType.none;

    final operation = recovery.initialize();
    await oldCommunicator.started.future;

    _reconnect(appState, _RecordingCommunicator());
    oldCommunicator.result.complete(Uint8List(0));

    expect(await operation, isFalse);
    expect(oldCommunicator.typeProbes, 1);
    expect(recovery.mifareClassicType, MifareClassicType.none);
  });

  test('key checking does not continue on a reconnected communicator',
      () async {
    final oldCommunicator = _DelayedKeyCheckCommunicator();
    final newCommunicator = _RecordingCommunicator();
    final appState = _connectedState(oldCommunicator);
    final recovery = await _recovery(
      appState,
      unresolvedSlots: const [0, 1],
    );

    final operation = recovery.checkKeys(skipDefaultDictionary: true);
    await oldCommunicator.started.future;

    _reconnect(appState, newCommunicator);
    oldCommunicator.result.complete(null);
    final completed = await operation;

    expect(completed, isFalse);
    expect(oldCommunicator.keyChecks, 1);
    expect(newCommunicator.keyChecks, 0);
    expect(recovery.getSectorState(1, 0), ChameleonKeyCheckmark.none);
  });

  test('disconnect transport error cancels key checking cleanly', () async {
    final oldCommunicator = _DelayedKeyCheckCommunicator();
    final newCommunicator = _RecordingCommunicator();
    final appState = _connectedState(oldCommunicator);
    final recovery = await _recovery(
      appState,
      unresolvedSlots: const [0, 1],
    );

    final operation = recovery.checkKeys(skipDefaultDictionary: true);
    await oldCommunicator.started.future;

    _reconnect(appState, newCommunicator);
    oldCommunicator.result.completeError(StateError('port closed'));

    expect(await operation, isFalse);
    expect(newCommunicator.keyChecks, 0);
    expect(recovery.getSectorState(1, 0), ChameleonKeyCheckmark.none);
  });

  test('dump does not continue or commit a delayed block after reconnect',
      () async {
    final oldCommunicator = _DelayedDumpCommunicator();
    final newCommunicator = _RecordingCommunicator();
    final appState = _connectedState(oldCommunicator);
    final recovery = await _recovery(appState);
    recovery.setKeyAsFound(0, 0, Uint8List.fromList(List.filled(6, 0xFF)));

    final operation = recovery.dumpData();
    await oldCommunicator.started.future;

    _reconnect(appState, newCommunicator);
    oldCommunicator.result.complete(Uint8List.fromList(List.filled(16, 0xAA)));
    final completed = await operation;

    expect(completed, isFalse);
    expect(oldCommunicator.blockReads, 1);
    expect(newCommunicator.blockReads, 0);
    expect(recovery.cardData[0], isEmpty);
    expect(recovery.dumpProgress, 0);
  });

  testWidgets('completed key check does not update a disposed card helper',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const wakelockChannel = MethodChannel('dev.fluttercommunity.plus/wakelock');
    messenger.setMockMethodCallHandler(wakelockChannel, (call) async => null);
    addTearDown(
        () => messenger.setMockMethodCallHandler(wakelockChannel, null));
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences)
      ..connector = (_TestSerial(log: Logger())..connected = true)
      ..communicator = _RecordingCommunicator()
      ..log = Logger();
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = _DelayedRecovery(
      appState: appState,
      localizations: localizations,
    );
    final info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.checkKeys,
    )..recovery = recovery;

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MifareClassicHelper(
              hfInfo: HFCardInfo(uid: '01 02 03 04'),
              mfcInfo: info,
            ),
          ),
        ),
      ),
    );

    final backgroundGate = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await backgroundGate.future;
    });
    await tester.pump();
    await tester.tap(find.text(localizations.check_keys_dict));
    await tester.pump();
    expect(recovery.started.isCompleted, isFalse);
    backgroundGate.complete();
    await background;
    await tester.pump();
    await recovery.started.future.timeout(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());

    recovery.result.complete(true);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'incomplete profile pass can continue with the ordinary dictionary',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences)
      ..connector = (_TestSerial(log: Logger())..connected = true)
      ..communicator = _RecordingCommunicator()
      ..log = Logger();
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = _DelayedRecovery(
      appState: appState,
      localizations: localizations,
    );
    final info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.recovery,
    )..recovery = recovery;

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MifareClassicHelper(
              hfInfo: HFCardInfo(uid: '01 02 03 04'),
              mfcInfo: info,
            ),
          ),
        ),
      ),
    );

    expect(find.text(localizations.check_keys_dict), findsOneWidget);
    await tester.tap(find.text(localizations.check_keys_dict));
    await tester.pump();

    expect(info.state, MifareClassicState.checkKeys);
    expect(info.recovery, same(recovery));
    expect(find.text(localizations.additional_key_dict), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued key check does not cross a reconnect', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const wakelockChannel = MethodChannel('dev.fluttercommunity.plus/wakelock');
    messenger.setMockMethodCallHandler(wakelockChannel, (call) async => null);
    addTearDown(
        () => messenger.setMockMethodCallHandler(wakelockChannel, null));
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = _connectedState(_RecordingCommunicator());
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = _DelayedRecovery(
      appState: appState,
      localizations: localizations,
    );
    final info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.checkKeys,
    )..recovery = recovery;

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MifareClassicHelper(
              hfInfo: HFCardInfo(uid: '01 02 03 04'),
              mfcInfo: info,
            ),
          ),
        ),
      ),
    );

    final blocker = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();
    await tester.tap(find.text(localizations.check_keys_dict));
    await tester.pump();
    expect(recovery.started.isCompleted, isFalse);

    _reconnect(appState, _RecordingCommunicator());
    blocker.complete();
    await background;
    await tester.pump();

    expect(recovery.started.isCompleted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed key check does not mutate a replacement card session',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const wakelockChannel = MethodChannel('dev.fluttercommunity.plus/wakelock');
    messenger.setMockMethodCallHandler(wakelockChannel, (call) async => null);
    addTearDown(
        () => messenger.setMockMethodCallHandler(wakelockChannel, null));
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences)
      ..connector = (_TestSerial(log: Logger())..connected = true)
      ..communicator = _RecordingCommunicator()
      ..log = Logger();
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final oldRecovery = _DelayedRecovery(
      appState: appState,
      localizations: localizations,
    );
    final oldInfo = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.checkKeys,
    )..recovery = oldRecovery;

    Future<void> pump(MifareClassicInfo info) => tester.pumpWidget(
          ChangeNotifierProvider<ChameleonGUIState>.value(
            value: appState,
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: MifareClassicHelper(
                  hfInfo: HFCardInfo(uid: '01 02 03 04'),
                  mfcInfo: info,
                ),
              ),
            ),
          ),
        );

    await pump(oldInfo);
    await tester.tap(find.text(localizations.check_keys_dict));
    await tester.pump();
    await oldRecovery.started.future;

    final replacementRecovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
    );
    final replacementInfo = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.checkKeys,
    )..recovery = replacementRecovery;
    await pump(replacementInfo);

    oldRecovery.result.complete(true);
    await tester.pump();

    expect(replacementInfo.state, MifareClassicState.checkKeys);
    expect(tester.takeException(), isNull);
  });
}

Future<MifareClassicRecovery> _recovery(
  ChameleonGUIState appState, {
  List<int> unresolvedSlots = const [],
}) async {
  final checkMarks =
      List.filled(80, ChameleonKeyCheckmark.disabled, growable: false);
  for (final slot in unresolvedSlots) {
    checkMarks[slot] = ChameleonKeyCheckmark.none;
  }
  return MifareClassicRecovery(
    appState: appState,
    update: () {},
    localizations: await AppLocalizations.delegate.load(const Locale('en')),
    mifareClassicType: MifareClassicType.m1k,
    checkMarks: checkMarks,
    selectedDictionary: Dictionary(
      id: 'test',
      name: 'Test keys',
      keys: [Uint8List.fromList(List.filled(6, 0xFF))],
      keyLength: 12,
    ),
  );
}

ChameleonGUIState _connectedState(ChameleonCommunicator communicator) {
  final serial = _TestSerial(log: Logger())..connected = true;
  return ChameleonGUIState(SharedPreferencesProvider())
    ..connector = serial
    ..communicator = communicator
    ..log = Logger();
}

void _reconnect(
    ChameleonGUIState appState, ChameleonCommunicator communicator) {
  appState.connector!.connected = false;
  appState
    ..connector = (_TestSerial(log: Logger())..connected = true)
    ..communicator = communicator;
}

class _RecordingCommunicator extends ChameleonCommunicator {
  int keyChecks = 0;
  int blockReads = 0;

  _RecordingCommunicator() : super(Logger());

  @override
  Future<Uint8List?> mf1AuthMultipleKeys(
      int block, int keyType, List<Uint8List> keys) async {
    keyChecks++;
    return null;
  }

  @override
  Future<Uint8List> mf1ReadBlock(int block, int keyType, Uint8List key) async {
    blockReads++;
    return Uint8List(0);
  }
}

class _DelayedTypeCommunicator extends _RecordingCommunicator {
  final Completer<void> started = Completer<void>();
  final Completer<Uint8List> result = Completer<Uint8List>();
  int typeProbes = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<bool> detectMf1Support() async => true;

  @override
  Future<Uint8List> send14ARaw(Uint8List data,
      {int respTimeoutMs = 100,
      int? bitLen,
      bool activateRfField = true,
      bool waitResponse = true,
      bool appendCrc = true,
      bool autoSelect = true,
      bool keepRfField = false,
      bool checkResponseCrc = true}) {
    typeProbes++;
    if (!started.isCompleted) {
      started.complete();
    }
    return result.future;
  }
}

class _DelayedKeyCheckCommunicator extends _RecordingCommunicator {
  final Completer<void> started = Completer<void>();
  final Completer<Uint8List?> result = Completer<Uint8List?>();

  @override
  Future<Uint8List?> mf1AuthMultipleKeys(
      int block, int keyType, List<Uint8List> keys) {
    keyChecks++;
    started.complete();
    return result.future;
  }
}

class _DelayedDumpCommunicator extends _RecordingCommunicator {
  final Completer<void> started = Completer<void>();
  final Completer<Uint8List> result = Completer<Uint8List>();

  @override
  Future<Uint8List> mf1ReadBlock(int block, int keyType, Uint8List key) {
    blockReads++;
    started.complete();
    return result.future;
  }
}

class _DelayedRecovery extends MifareClassicRecovery {
  final Completer<void> started = Completer<void>();
  final Completer<bool> result = Completer<bool>();

  _DelayedRecovery({
    required super.appState,
    required super.localizations,
  }) : super(
          update: () {},
          mifareClassicType: MifareClassicType.m1k,
        );

  @override
  Future<bool> checkKeys({bool skipDefaultDictionary = false}) {
    started.complete();
    return result.future;
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
