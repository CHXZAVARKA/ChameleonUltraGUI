import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/mifare/standard_write.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/edit.dart';
import 'package:chameleonultragui/gui/page/write_card.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/base.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/gen2.dart';
import 'package:chameleonultragui/helpers/write.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('standard write offers only complete or confirmed legacy dumps',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    preferences.setMifareClassicKeyProfiles([
      MifareClassicKeyProfile(
        id: '4k-profile',
        name: 'Own card keys',
        cardType: 'm4k',
        sectorCount: 40,
        assignments: [
          MifareClassicKeyAssignment(
            sector: 0,
            keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          ),
        ],
      ),
      MifareClassicKeyProfile(
        id: '1k-ev1-profile',
        name: 'EV1 card keys',
        cardType: 'm1k',
        sectorCount: 18,
        assignments: [
          MifareClassicKeyAssignment(
            sector: 0,
            keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          ),
        ],
      ),
    ]);
    preferences.setCards([
      CardSave(
        id: '1k-ev1-card',
        uid: '01020304',
        name: 'Own EV1 dump',
        tag: TagType.mifare1K,
        extraData: CardSaveExtra(mifareClassicDumpComplete: true),
        data: List.generate(
          256,
          (block) => block < 72 ? Uint8List(16) : Uint8List(0),
        ),
      ),
      CardSave(
        id: 'legacy-1k-ev1-card',
        uid: '01020304',
        name: 'Legacy EV1 dump',
        tag: TagType.mifare1K,
        data: List.generate(
          256,
          (block) => block < 72 ? Uint8List(16) : Uint8List(0),
        ),
      ),
      CardSave(
        id: 'incomplete-1k-ev1-card',
        uid: '01020304',
        name: 'Incomplete EV1 dump',
        tag: TagType.mifare1K,
        extraData: CardSaveExtra(mifareClassicDumpComplete: false),
        data: List.generate(
          256,
          (block) => block < 72 ? Uint8List(16) : Uint8List(0),
        ),
      ),
      CardSave(
        id: 'malformed-1k-ev1-card',
        uid: '01020304',
        name: 'Malformed EV1 dump',
        tag: TagType.mifare1K,
        data: List.generate(
          256,
          (block) => block < 72 && block != 12 ? Uint8List(16) : Uint8List(0),
        ),
      ),
      CardSave(
        id: 'oversized-1k-card',
        uid: '01020304',
        name: '4K data marked as 1K',
        tag: TagType.mifare1K,
        extraData: CardSaveExtra(mifareClassicDumpComplete: true),
        data: List.generate(256, (_) => Uint8List(16)),
      ),
    ]);
    final appState = ChameleonGUIState(preferences);

    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    await tester.tap(find.text('Standard MIFARE Classic'));
    await tester.pumpAndSettle();

    expect(find.text("Write the card's own dump to a standard card"),
        findsOneWidget);
    expect(
      find.text(
          'Only data blocks are written. Block 0, keys, and access bits are left unchanged.'),
      findsOneWidget,
    );
    expect(find.byTooltip('Import key profile'), findsNothing);
    await tester.tap(find.text('Select saved card'));
    await tester.pumpAndSettle();
    expect(find.text('Own EV1 dump'), findsOneWidget);
    expect(find.text('Legacy EV1 dump'), findsOneWidget);
    expect(find.text('Incomplete EV1 dump'), findsNothing);
    expect(find.text('Malformed EV1 dump'), findsNothing);
    expect(find.text('4K data marked as 1K'), findsNothing);
    await tester.tap(find.text('Own EV1 dump'));
    await tester.pumpAndSettle();

    expect(find.text('Unverified legacy dump'), findsNothing);
    expect(find.text('✓ Own EV1 dump · 1152 bytes · MIFARE Classic 1K EV1'),
        findsOneWidget);

    await tester.tap(find.text('Select saved card'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Legacy EV1 dump'));
    await tester.pumpAndSettle();

    expect(find.text('Unverified legacy dump'), findsOneWidget);
    expect(
      find.textContaining('predates completeness tracking'),
      findsOneWidget,
    );
    await tester.tap(find.text('Use saved dump'));
    await tester.pumpAndSettle();

    expect(find.text('✓ Legacy EV1 dump · 1152 bytes · MIFARE Classic 1K EV1'),
        findsOneWidget);
    expect(
      preferences
          .getCards()
          .firstWhere((card) => card.id == 'legacy-1k-ev1-card')
          .extraData
          .mifareClassicDumpComplete,
      isTrue,
    );
    expect(
      preferences
          .getCards()
          .firstWhere((card) => card.id == 'incomplete-1k-ev1-card')
          .extraData
          .mifareClassicDumpComplete,
      isFalse,
    );
    await tester.tap(find.text('Select key profile'));
    await tester.pumpAndSettle();
    expect(find.text('EV1 card keys (1)'), findsOneWidget);
    expect(find.text('Own card keys (1)'), findsNothing);
    expect(find.text('Run preflight'), findsOneWidget);
    expect(find.text('Write and verify'), findsNothing);
  });

  testWidgets('editing an incomplete dump keeps it unavailable for writing',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    preferences.setCards([
      CardSave(
        id: 'incomplete-card',
        uid: '01 02 03 04',
        name: 'Incomplete dump',
        tag: TagType.mifare1K,
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        extraData: CardSaveExtra(mifareClassicDumpComplete: false),
        data: List.generate(
          256,
          (block) => block < 64 ? Uint8List(16) : Uint8List(0),
        ),
      ),
    ]);
    final appState = ChameleonGUIState(preferences);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  await showDialog<void>(
                    context: context,
                    builder: (context) => CardEditMenu(
                      tagSave: preferences.getCards().single,
                    ),
                  );
                },
                child: const Text('Open edit'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      preferences.getCards().single.extraData.mifareClassicDumpComplete,
      isFalse,
    );

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
    await tester.pumpAndSettle();
    await tester.tap(find.text('Standard MIFARE Classic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select saved card'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No usable saved MIFARE Classic dumps'),
        findsOneWidget);
    expect(find.text('Incomplete dump'), findsNothing);
  });

  testWidgets(
    'maintenance failure hides diagnostics from the user and logs them',
    (tester) async {
      const diagnostics = 'USB endpoint 0x81 stalled after frame 4f2a';
      SharedPreferences.setMockInitialValues({});
      final preferences = SharedPreferencesProvider();
      await preferences.load();
      preferences.setMifareClassicKeyProfiles([
        MifareClassicKeyProfile(
          id: '1k-profile',
          name: 'Safe keys',
          cardType: 'm1k',
          sectorCount: 16,
          assignments: [
            MifareClassicKeyAssignment(
              sector: 0,
              keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
            ),
          ],
        ),
      ]);
      preferences.setCards([
        CardSave(
          id: 'complete-card',
          uid: '01020304',
          name: 'Complete dump',
          tag: TagType.mifare1K,
          extraData: CardSaveExtra(mifareClassicDumpComplete: true),
          data: List.generate(
            256,
            (block) => block < 64 ? Uint8List(16) : Uint8List(0),
          ),
        ),
      ]);
      final logOutput = MemoryOutput();
      final logger = Logger(
        filter: ProductionFilter(),
        printer: SimplePrinter(colors: false),
        output: logOutput,
      );
      addTearDown(logger.close);
      final appState = ChameleonGUIState(preferences)
        ..log = logger
        ..connector = (_TestSerial(log: logger)..connected = true)
        ..communicator = _FailingPreflightCommunicator(logger, diagnostics);

      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: StandardMifareClassicWritePanel()),
          ),
        ),
      );

      await tester.tap(find.text('Select saved card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complete dump'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select key profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Safe keys (1)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run preflight'));
      await tester.pumpAndSettle();

      expect(find.textContaining(diagnostics), findsNothing);
      expect(find.textContaining('0xe1'), findsNothing);
      expect(
        find.text(
          'Operation stopped: Communication with Chameleon was lost. '
          'Reconnect and try again.',
        ),
        findsOneWidget,
      );
      expect(
        logOutput.buffer.map((event) => event.origin.error),
        contains(
          isA<MifareClassicMaintenanceException>()
              .having(
                (error) => error.failure,
                'failure',
                MifareClassicMaintenanceFailure.communicationLost,
              )
              .having(
                (error) => error.toString(),
                'diagnostics',
                contains(diagnostics),
              ),
        ),
      );
    },
  );

  testWidgets(
    'BIN picker failure hides diagnostics from the user and logs them',
    (tester) async {
      const diagnostics = 'PICKER_DIAGNOSTIC_17_8C4F';
      const filePickerChannel = MethodChannel(
        'miguelruivo.flutter.plugins.filepicker',
        StandardMethodCodec(),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(filePickerChannel, (call) async {
        throw PlatformException(
          code: 'picker_failed',
          message: diagnostics,
        );
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(filePickerChannel, null));

      SharedPreferences.setMockInitialValues({});
      final preferences = SharedPreferencesProvider();
      await preferences.load();
      final logOutput = MemoryOutput();
      final logger = Logger(
        filter: ProductionFilter(),
        printer: SimplePrinter(colors: false),
        output: logOutput,
      );
      addTearDown(logger.close);
      final appState = ChameleonGUIState(preferences)..log = logger;

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: StandardMifareClassicWritePanel()),
          ),
        ),
      );

      await tester.tap(find.text('Select .bin dump'));
      await tester.pumpAndSettle();

      expect(find.textContaining(diagnostics), findsNothing);
      expect(find.text('Operation stopped: Error'), findsOneWidget);
      expect(logOutput.buffer, hasLength(1));
      expect(
        logOutput.buffer.single.origin.error,
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'picker_failed')
            .having((error) => error.message, 'message', diagnostics),
      );
      expect(logOutput.buffer.single.origin.stackTrace, isNotNull);
    },
  );

  testWidgets('Magic write holds foreground RF access for its whole sequence',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _ReaderModeCommunicator(logger);
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = communicator;
    final helper = _ProtectedMagicWriteHelper(communicator);

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
    final state = tester.state<WriteCardPageState>(find.byType(WriteCardPage));
    state
      ..card = CardSave(uid: '01020304', name: 'Test', tag: TagType.mifare1K)
      ..helper = helper;

    final backgroundGate = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await backgroundGate.future;
    });
    await tester.pump();
    final write = state.writeCard();
    await tester.pump();
    expect(helper.writeCalls, 0);

    backgroundGate.complete();
    await background;
    await tester.pump();
    await helper.writeStarted.future.timeout(const Duration(seconds: 2));
    expect(helper.writeCalls, 1);
    expect(
      (await appState.rfOperations.tryRunBackground(() async {})).acquired,
      isFalse,
    );

    helper.allowWrite.complete();
    await write;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued Standard preflight does not cross a reconnect',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    const key = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    preferences.setMifareClassicKeyProfiles([
      MifareClassicKeyProfile(
        id: 'mini-profile',
        name: 'Mini keys',
        cardType: 'mini',
        sectorCount: 5,
        assignments: List.generate(
          5,
          (sector) => MifareClassicKeyAssignment(
            sector: sector,
            keyA: Uint8List.fromList(key),
          ),
        ),
      ),
    ]);
    preferences.setCards([
      CardSave(
        id: 'mini-card',
        uid: '01020304',
        name: 'Mini dump',
        tag: TagType.mifareMini,
        extraData: CardSaveExtra(mifareClassicDumpComplete: true),
        data: List.generate(
            256, (block) => block < 20 ? Uint8List(16) : Uint8List(0)),
      ),
    ]);
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final oldCommunicator = _QueuedPreflightCommunicator(logger);
    final oldConnector = _TestSerial(log: logger)..connected = true;
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = oldConnector
      ..communicator = oldCommunicator;

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: StandardMifareClassicWritePanel()),
        ),
      ),
    );
    await tester.tap(find.text('Select saved card'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mini dump'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select key profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mini keys (5)').last);
    await tester.pumpAndSettle();

    final blocker = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();
    await tester.tap(find.text('Run preflight'));
    await tester.pump();
    expect(oldCommunicator.readerModeCalls, 0);

    oldConnector.connected = false;
    appState
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = _QueuedPreflightCommunicator(logger)
      ..changesMade();
    blocker.complete();
    await background;
    await tester.pumpAndSettle();

    expect(oldCommunicator.readerModeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued Magic write does not cross a reconnect', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _ReaderModeCommunicator(logger);
    final connector = _TestSerial(log: logger)..connected = true;
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    final helper = _ProtectedMagicWriteHelper(communicator);

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
    final state = tester.state<WriteCardPageState>(find.byType(WriteCardPage));
    state
      ..card = CardSave(uid: '01020304', name: 'Test', tag: TagType.mifare1K)
      ..helper = helper;

    final blocker = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();
    final write = state.writeCard();
    await tester.pump();
    expect(helper.writeCalls, 0);

    connector.connected = false;
    appState
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = _ReaderModeCommunicator(logger)
      ..changesMade();
    blocker.complete();
    await background;
    await tester.pump();
    if (helper.writeStarted.isCompleted) {
      helper.allowWrite.complete();
    }
    await write;
    await tester.pump();

    expect(helper.writeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Magic detection stops before the next RF command after DFU',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final connector = _TestSerial(log: logger)..connected = true;
    final communicator = _DelayedMagicDetectCommunicator(logger);
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: await AppLocalizations.delegate.load(const Locale('en')),
    );

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
    final state = tester.state<WriteCardPageState>(find.byType(WriteCardPage));
    state
      ..card = CardSave(uid: '01020304', name: 'Test', tag: TagType.mifare1K)
      ..baseHelper = BaseMifareClassicWriteHelper(
        communicator,
        recovery: recovery,
      );

    final detection = state.detectMagicType();
    await communicator.rawStarted.future.timeout(const Duration(seconds: 2));
    connector.isDFU = true;
    appState.changesMade();
    communicator.allowRaw.complete(Uint8List(0));
    await detection;
    await tester.pump();

    expect(communicator.rawCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued Standard execute stays bound to its preflight session',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    const key = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    final targetBlocks = _miniTargetBlocks();
    preferences.setMifareClassicKeyProfiles([
      MifareClassicKeyProfile(
        id: 'mini-profile',
        name: 'Mini keys',
        cardType: 'mini',
        sectorCount: 5,
        assignments: List.generate(
          5,
          (sector) => MifareClassicKeyAssignment(
            sector: sector,
            keyA: Uint8List.fromList(key),
          ),
        ),
      ),
    ]);
    preferences.setCards([
      CardSave(
        id: 'mini-card',
        uid: '01020304',
        name: 'Mini dump',
        tag: TagType.mifareMini,
        extraData: CardSaveExtra(mifareClassicDumpComplete: true),
        data: targetBlocks,
      ),
    ]);
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final connector = _TestSerial(log: logger)..connected = true;
    final communicator = _MiniMaintenanceCommunicator(
      logger,
      [
        for (var block = 0; block < 20; block++)
          Uint8List.fromList(targetBlocks[block]),
      ]..[1] = Uint8List(16),
    );
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
          home: const Scaffold(body: StandardMifareClassicWritePanel()),
        ),
      ),
    );
    await tester.tap(find.text('Select saved card'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mini dump'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select key profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mini keys (5)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run preflight'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();

    final readerModeBaseline = communicator.readerModeCalls;
    final blocker = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();
    final writeAndVerify = find.text('Write and verify');
    await tester.ensureVisible(writeAndVerify);
    await tester.tap(writeAndVerify);
    await tester.pump();

    connector.connected = false;
    appState
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = _ReaderModeCommunicator(logger)
      ..changesMade();
    blocker.complete();
    await background;
    await tester.pumpAndSettle();

    expect(communicator.readerModeCalls, readerModeBaseline);
    expect(communicator.writeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Magic write stops before the next block after reconnect',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final connector = _TestSerial(log: logger)..connected = true;
    final communicator = _DelayedMagicBlockCommunicator(logger);
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: await AppLocalizations.delegate.load(const Locale('en')),
    );
    final helper = MifareClassicGen2WriteHelper(
      communicator,
      recovery: recovery,
    );

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
    final state = tester.state<WriteCardPageState>(find.byType(WriteCardPage));
    state
      ..card = CardSave(
        uid: '01020304',
        name: 'Test',
        tag: TagType.mifare1K,
        data: [
          Uint8List(0),
          Uint8List.fromList(List.filled(16, 1)),
          Uint8List.fromList(List.filled(16, 2)),
        ],
      )
      ..helper = helper;

    final write = state.writeCard();
    await tester.pump(const Duration(milliseconds: 50));
    await communicator.writeStarted.future.timeout(const Duration(seconds: 2));
    connector.connected = false;
    appState
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = _ReaderModeCommunicator(logger)
      ..changesMade();
    communicator.allowWrite.complete(true);
    await write;
    await tester.pump();

    expect(communicator.writeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued Classic prepare scan does not cross a reconnect',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final connector = _TestSerial(log: logger)..connected = true;
    final oldCommunicator = _QueuedPreflightCommunicator(logger);
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = oldCommunicator;
    final helper = BaseMifareClassicWriteHelper(
      oldCommunicator,
      recovery: MifareClassicRecovery(
        appState: appState,
        update: () {},
        localizations: await AppLocalizations.delegate.load(const Locale('en')),
      ),
    );
    final blocker = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) =>
                  helper.getWriteWidget(context, setState),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(oldCommunicator.readerModeCalls, 0);

    connector.connected = false;
    final replacement = _QueuedPreflightCommunicator(logger);
    appState
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = replacement
      ..changesMade();
    blocker.complete();
    await background;
    await tester.pump();

    expect(oldCommunicator.readerModeCalls, 0);
    expect(replacement.readerModeCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

List<Uint8List> _miniTargetBlocks() {
  const key = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
  const trailer = [...key, 0xFF, 0x07, 0x80, 0x69, ...key];
  final blocks = List.generate(256, (_) => Uint8List(0));
  for (var block = 0; block < 20; block++) {
    blocks[block] = Uint8List(16);
  }
  blocks[0].setRange(0, 4, [1, 2, 3, 4]);
  blocks[1][0] = 1;
  for (var sector = 0; sector < 5; sector++) {
    blocks[mfClassicGetSectorTrailerBlockBySector(sector)] =
        Uint8List.fromList(trailer);
  }
  return blocks;
}

class _FailingPreflightCommunicator extends ChameleonCommunicator {
  final String diagnostics;

  _FailingPreflightCommunicator(super.logger, this.diagnostics);

  @override
  Future<bool> isReaderDeviceMode() async {
    throw MifareClassicMaintenanceException(
      MifareClassicMaintenanceFailure.communicationLost,
      diagnostics,
      status: 0xe1,
    );
  }
}

class _ReaderModeCommunicator extends ChameleonCommunicator {
  _ReaderModeCommunicator(super.logger);

  @override
  Future<bool> isReaderDeviceMode() async => true;
}

class _QueuedPreflightCommunicator extends ChameleonCommunicator {
  _QueuedPreflightCommunicator(super.logger);

  int readerModeCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async {
    readerModeCalls++;
    return true;
  }

  @override
  Future<CardData?> scan14443aTag() async => null;
}

class _DelayedMagicDetectCommunicator extends ChameleonCommunicator {
  _DelayedMagicDetectCommunicator(super.logger);

  final Completer<void> rawStarted = Completer<void>();
  final Completer<Uint8List> allowRaw = Completer<Uint8List>();
  int rawCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

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
    if (!rawStarted.isCompleted) {
      rawStarted.complete();
      return allowRaw.future;
    }
    return Future.value(Uint8List(0));
  }
}

class _MiniMaintenanceCommunicator extends ChameleonCommunicator {
  _MiniMaintenanceCommunicator(super.logger, this.blocks);

  final List<Uint8List> blocks;
  int readerModeCalls = 0;
  int writeCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async {
    readerModeCalls++;
    return true;
  }

  @override
  Future<CardData?> scan14443aTag() async => CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x09,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      );

  @override
  Future<bool> detectMf1Support() async => true;

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
  }) async =>
      Uint8List(0);

  @override
  Future<ChameleonMessage> mf1AuthResult(
    int block,
    int keyType,
    Uint8List key,
  ) async =>
      ChameleonMessage(command: 0, status: 0, data: Uint8List(0));

  @override
  Future<ChameleonMessage> mf1ReadBlockResult(
    int block,
    int keyType,
    Uint8List key,
  ) async =>
      ChameleonMessage(
        command: 0,
        status: 0,
        data: Uint8List.fromList(blocks[block]),
      );

  @override
  Future<ChameleonMessage> mf1WriteBlockResult(
    int block,
    int keyType,
    Uint8List key,
    Uint8List data,
  ) async {
    writeCalls++;
    blocks[block] = Uint8List.fromList(data);
    return ChameleonMessage(command: 0, status: 0, data: Uint8List(0));
  }
}

class _DelayedMagicBlockCommunicator extends ChameleonCommunicator {
  _DelayedMagicBlockCommunicator(super.logger);

  final Completer<void> writeStarted = Completer<void>();
  final Completer<bool> allowWrite = Completer<bool>();
  int writeCalls = 0;

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
  ) {
    writeCalls++;
    if (!writeStarted.isCompleted) {
      writeStarted.complete();
      return allowWrite.future;
    }
    return Future.value(true);
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

class _ProtectedMagicWriteHelper extends AbstractWriteHelper {
  _ProtectedMagicWriteHelper(super.communicator);

  final Completer<void> writeStarted = Completer<void>();
  final Completer<void> allowWrite = Completer<void>();
  int writeCalls = 0;

  @override
  Future<bool> isMagic(dynamic data) async => true;

  @override
  bool isReady() => true;

  @override
  Future<bool> isCompatible(CardSave card) async => true;

  @override
  List<AbstractWriteHelper> getAvailableMethods() => [this];

  @override
  List<AbstractWriteHelper> getAvailableMethodsByPriority() => [this];

  @override
  Future<bool> writeData(
    CardSave card,
    Function(int writeProgress) update,
  ) async {
    writeCalls++;
    writeStarted.complete();
    await allowWrite.future;
    return true;
  }

  @override
  Widget getWriteWidget(BuildContext context, dynamic setState) =>
      const SizedBox.shrink();
}
