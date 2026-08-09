import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/mifare/ultralight.dart';
import 'package:chameleonultragui/helpers/card_info.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferencesProvider preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = SharedPreferencesProvider();
    await preferences.load();
  });

  testWidgets('queued canceled Ultralight dump restores actionable UI',
      (tester) async {
    final communicator = _UltralightCommunicator();
    final appState = _connectedState(preferences, communicator);
    final blockerStarted = Completer<void>();
    final releaseBlocker = Completer<void>();
    final blocker = appState.rfOperations.tryRunBackground(() async {
      blockerStarted.complete();
      await releaseBlocker.future;
    });
    await blockerStarted.future;
    final originalInfo = HFCardInfo(type: TagType.ultralight);
    final replacementInfo = HFCardInfo(type: TagType.ntag216);

    await _pumpHelper(tester, appState, originalInfo);
    final state = tester.state<CardReaderState>(
      find.byType(MifareUltralightHelper),
    );
    final read = state.readCard();
    await tester.pump();
    expect(state.state, MifareUltralightState.read);

    await _pumpHelper(tester, appState, replacementInfo);
    expect(
      tester.state<CardReaderState>(find.byType(MifareUltralightHelper)),
      same(state),
    );
    releaseBlocker.complete();
    await blocker;
    await read;
    await tester.pump();

    expect(communicator.rawCalls, 0);
    expect(state.state, MifareUltralightState.none);
    expect(replacementInfo.type, TagType.ntag216);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-flight canceled Ultralight dump restores actionable UI',
      (tester) async {
    final communicator = _DelayedUltralightCommunicator();
    final appState = _connectedState(preferences, communicator);
    final originalInfo = HFCardInfo(type: TagType.ultralight);
    final replacementInfo = HFCardInfo(type: TagType.ntag216);

    await _pumpHelper(tester, appState, originalInfo);
    final state = tester.state<CardReaderState>(
      find.byType(MifareUltralightHelper),
    );
    final read = state.readCard();
    await communicator.started.future;
    expect(state.state, MifareUltralightState.read);

    await _pumpHelper(tester, appState, replacementInfo);
    communicator.firstResponse.complete(Uint8List(16));
    await read;
    await tester.pump();

    expect(communicator.rawCalls, 1);
    expect(state.state, MifareUltralightState.none);
    expect(replacementInfo.type, TagType.ntag216);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'disposed canceled Ultralight dump restores state without setState',
      (tester) async {
    final communicator = _DelayedUltralightCommunicator();
    final appState = _connectedState(preferences, communicator);

    await _pumpHelper(
      tester,
      appState,
      HFCardInfo(type: TagType.ultralight),
    );
    final state = tester.state<CardReaderState>(
      find.byType(MifareUltralightHelper),
    );
    final read = state.readCard();
    await communicator.started.future;
    expect(state.state, MifareUltralightState.read);

    await tester.pumpWidget(const SizedBox.shrink());
    communicator.firstResponse.complete(Uint8List(16));
    await read;
    await tester.pump();

    expect(communicator.rawCalls, 1);
    expect(state.state, MifareUltralightState.none);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpHelper(
  WidgetTester tester,
  ChameleonGUIState appState,
  HFCardInfo info,
) {
  return tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MifareUltralightHelper(hfInfo: info, allowSave: false),
        ),
      ),
    ),
  );
}

ChameleonGUIState _connectedState(
  SharedPreferencesProvider preferences,
  ChameleonCommunicator communicator,
) {
  return ChameleonGUIState(preferences)
    ..connector = (_TestSerial(log: Logger())..connected = true)
    ..communicator = communicator
    ..log = Logger();
}

class _UltralightCommunicator extends ChameleonCommunicator {
  _UltralightCommunicator() : super(Logger());

  int rawCalls = 0;

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
    rawCalls++;
    if (data.first == 0x60) {
      return Uint8List(8);
    }
    if (data.first == 0x3C) {
      return Uint8List(32);
    }
    return Uint8List(16);
  }
}

class _DelayedUltralightCommunicator extends _UltralightCommunicator {
  final Completer<void> started = Completer<void>();
  final Completer<Uint8List> firstResponse = Completer<Uint8List>();

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
  }) {
    rawCalls++;
    if (!started.isCompleted) {
      started.complete();
      return firstResponse.future;
    }
    return Future.value(Uint8List(16));
  }
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log});

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
