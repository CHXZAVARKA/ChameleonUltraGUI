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
  for (final operation in _ClassicOperation.values) {
    testWidgets(
      'queued canceled ${operation.name} restores only its original model',
      (tester) async {
        final fixture = await _ClassicFixture.create(tester, operation);
        final blocker = Completer<void>();
        final background = fixture.appState.rfOperations.tryRunBackground(
          () async {
            await blocker.future;
          },
        );
        await tester.pump();

        await tester.tap(find.text(fixture.buttonLabel));
        await tester.pump();
        expect(fixture.info.state, operation.ongoingState);
        fixture.recovery.checkMarks[0] = ChameleonKeyCheckmark.checking;

        final replacement = fixture.createReplacement();
        fixture.reconnect();
        await fixture.pump(replacement);
        blocker.complete();
        await background;
        await tester.pump();

        expect(fixture.recovery.started.isCompleted, isFalse);
        expect(fixture.info.state, operation.actionableState);
        expect(fixture.recovery.checkMarks[0], ChameleonKeyCheckmark.none);
        expect(replacement.state, operation.actionableState);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'in-flight canceled ${operation.name} restores only its original model',
      (tester) async {
        final fixture = await _ClassicFixture.create(tester, operation);

        await tester.tap(find.text(fixture.buttonLabel));
        await tester.pump();
        await fixture.recovery.started.future;
        expect(fixture.info.state, operation.ongoingState);

        final replacement = fixture.createReplacement();
        fixture.reconnect();
        await fixture.pump(replacement);
        fixture.recovery.result.complete(false);
        await tester.pump();

        expect(fixture.info.state, operation.actionableState);
        expect(fixture.recovery.checkMarks[0], ChameleonKeyCheckmark.none);
        expect(replacement.state, operation.actionableState);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('canceled key check restores state after helper disposal',
      (tester) async {
    final fixture =
        await _ClassicFixture.create(tester, _ClassicOperation.check);

    await tester.tap(find.text(fixture.buttonLabel));
    await tester.pump();
    await fixture.recovery.started.future;
    await tester.pumpWidget(const SizedBox());
    fixture.reconnect();
    fixture.recovery.result.complete(false);
    await tester.pump();

    expect(fixture.info.state, MifareClassicState.checkKeys);
    expect(
      fixture.recovery.checkMarks[0],
      ChameleonKeyCheckmark.none,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('recover error restores the current model and reports safely',
      (tester) async {
    final fixture =
        await _ClassicFixture.create(tester, _ClassicOperation.recover);

    await tester.tap(find.text(fixture.buttonLabel));
    await tester.pump();
    await fixture.recovery.started.future;
    fixture.recovery.result.completeError(StateError('RF transport failed'));
    await tester.pump();

    expect(fixture.info.state, MifareClassicState.recovery);
    expect(
      fixture.recovery.checkMarks[0],
      ChameleonKeyCheckmark.none,
    );
    expect(fixture.recovery.error, fixture.localizations.error);
    expect(find.text(fixture.localizations.error), findsOneWidget);
    expect(
      fixture.logOutput.buffer.map((event) => event.origin.error),
      contains(isA<StateError>()),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('recover error restores only the replaced original model',
      (tester) async {
    final fixture =
        await _ClassicFixture.create(tester, _ClassicOperation.recover);

    await tester.tap(find.text(fixture.buttonLabel));
    await tester.pump();
    await fixture.recovery.started.future;

    final replacement = fixture.createReplacement();
    await fixture.pump(replacement);
    fixture.recovery.result.completeError(StateError('RF transport failed'));
    await tester.pump();

    expect(fixture.info.state, MifareClassicState.recovery);
    expect(
      fixture.recovery.checkMarks[0],
      ChameleonKeyCheckmark.none,
    );
    expect(fixture.recovery.error, isEmpty);
    expect(replacement.state, MifareClassicState.recovery);
    expect(replacement.recovery?.error, isEmpty);
    expect(
      fixture.logOutput.buffer.map((event) => event.origin.error),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('recover error after reconnect restores without reporting',
      (tester) async {
    final fixture =
        await _ClassicFixture.create(tester, _ClassicOperation.recover);

    await tester.tap(find.text(fixture.buttonLabel));
    await tester.pump();
    await fixture.recovery.started.future;
    fixture.reconnect();
    fixture.recovery.result.completeError(StateError('port closed'));
    await tester.pump();

    expect(fixture.info.state, MifareClassicState.recovery);
    expect(
      fixture.recovery.checkMarks[0],
      ChameleonKeyCheckmark.none,
    );
    expect(fixture.recovery.error, isEmpty);
    expect(
      fixture.logOutput.buffer.map((event) => event.origin.error),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('recover error restores state after helper disposal',
      (tester) async {
    final fixture =
        await _ClassicFixture.create(tester, _ClassicOperation.recover);

    await tester.tap(find.text(fixture.buttonLabel));
    await tester.pump();
    await fixture.recovery.started.future;
    await tester.pumpWidget(const SizedBox());
    fixture.recovery.result.completeError(StateError('RF transport failed'));
    await tester.pump();

    expect(fixture.info.state, MifareClassicState.recovery);
    expect(
      fixture.recovery.checkMarks[0],
      ChameleonKeyCheckmark.none,
    );
    expect(fixture.recovery.error, isEmpty);
    expect(
      fixture.logOutput.buffer.map((event) => event.origin.error),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}

enum _ClassicOperation { check, recover, dump }

extension on _ClassicOperation {
  MifareClassicState get actionableState => switch (this) {
    _ClassicOperation.check => MifareClassicState.checkKeys,
    _ClassicOperation.recover => MifareClassicState.recovery,
    _ClassicOperation.dump => MifareClassicState.dump,
  };

  MifareClassicState get ongoingState => switch (this) {
    _ClassicOperation.check => MifareClassicState.checkKeysOngoing,
    _ClassicOperation.recover => MifareClassicState.recoveryOngoing,
    _ClassicOperation.dump => MifareClassicState.dumpOngoing,
  };
}

class _ClassicFixture {
  _ClassicFixture._({
    required this.tester,
    required this.appState,
    required this.localizations,
    required this.operation,
    required this.info,
    required this.recovery,
    required this.logOutput,
  });

  final WidgetTester tester;
  final ChameleonGUIState appState;
  final AppLocalizations localizations;
  final _ClassicOperation operation;
  final MifareClassicInfo info;
  final _CancellableRecovery recovery;
  final MemoryOutput logOutput;

  String get buttonLabel => switch (operation) {
    _ClassicOperation.check => localizations.check_keys_dict,
    _ClassicOperation.recover => localizations.recover_keys,
    _ClassicOperation.dump => localizations.dump_card,
  };

  static Future<_ClassicFixture> create(
    WidgetTester tester,
    _ClassicOperation operation,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const wakelockChannel = MethodChannel('dev.fluttercommunity.plus/wakelock');
    messenger.setMockMethodCallHandler(wakelockChannel, (call) async => null);
    addTearDown(
      () => messenger.setMockMethodCallHandler(wakelockChannel, null),
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final localizations = await AppLocalizations.delegate.load(
      const Locale('en'),
    );
    final logOutput = MemoryOutput();
    final logger = Logger(
      filter: ProductionFilter(),
      printer: SimplePrinter(colors: false),
      output: logOutput,
    );
    addTearDown(logger.close);
    final appState = ChameleonGUIState(preferences)
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = ChameleonCommunicator(logger)
      ..log = logger;
    final recovery = _CancellableRecovery(
      appState: appState,
      localizations: localizations,
      operation: operation,
    );
    final info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: operation.actionableState,
    )..recovery = recovery;
    final fixture = _ClassicFixture._(
      tester: tester,
      appState: appState,
      localizations: localizations,
      operation: operation,
      info: info,
      recovery: recovery,
      logOutput: logOutput,
    );
    await fixture.pump(info);
    return fixture;
  }

  Future<void> pump(MifareClassicInfo model) => tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MifareClassicHelper(
            hfInfo: HFCardInfo(uid: '01 02 03 04'),
            mfcInfo: model,
          ),
        ),
      ),
    ),
  );

  MifareClassicInfo createReplacement() =>
      MifareClassicInfo(
          type: MifareClassicType.m1k,
          state: operation.actionableState,
        )
        ..recovery = MifareClassicRecovery(
          appState: appState,
          update: () {},
          localizations: localizations,
          mifareClassicType: MifareClassicType.m1k,
        );

  void reconnect() {
    appState.connector!.connected = false;
    appState
      ..connector = (_TestSerial(log: Logger())..connected = true)
      ..communicator = ChameleonCommunicator(Logger());
  }
}

class _CancellableRecovery extends MifareClassicRecovery {
  _CancellableRecovery({
    required super.appState,
    required super.localizations,
    required this.operation,
  }) : super(update: () {}, mifareClassicType: MifareClassicType.m1k);

  final _ClassicOperation operation;
  final Completer<void> started = Completer<void>();
  final Completer<bool> result = Completer<bool>();

  Future<bool> _run(_ClassicOperation requested) {
    if (operation != requested) {
      throw StateError('Unexpected operation: $requested');
    }
    checkMarks[0] = ChameleonKeyCheckmark.checking;
    started.complete();
    return result.future;
  }

  @override
  Future<bool> checkKeys({bool skipDefaultDictionary = false}) =>
      _run(_ClassicOperation.check);

  @override
  Future<bool> recoverKeys() => _run(_ClassicOperation.recover);

  @override
  Future<bool> dumpData() => _run(_ClassicOperation.dump);
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
