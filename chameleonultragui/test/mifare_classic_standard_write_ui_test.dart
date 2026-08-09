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
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('standard write offers only proven complete saved dumps',
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
    expect(find.text('Legacy EV1 dump'), findsNothing);
    expect(find.text('Incomplete EV1 dump'), findsNothing);
    expect(find.text('Malformed EV1 dump'), findsNothing);
    expect(find.text('4K data marked as 1K'), findsNothing);
    await tester.tap(find.text('Own EV1 dump'));
    await tester.pumpAndSettle();

    expect(find.text('Unverified legacy dump'), findsNothing);
    expect(find.text('✓ Own EV1 dump · 1152 bytes · MIFARE Classic 1K EV1'),
        findsOneWidget);

    expect(
      preferences
          .getCards()
          .firstWhere((card) => card.id == 'legacy-1k-ev1-card')
          .extraData
          .mifareClassicDumpComplete,
      isNull,
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
    expect(find.text('EV1 card keys (1 key)'), findsOneWidget);
    expect(find.text('Own card keys (1 key)'), findsNothing);
    expect(find.text('Load file'), findsOneWidget);
    expect(find.text('OR'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Write and verify'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
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
      await tester.tap(find.text('Safe keys (1 key)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
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
    'file picker failure hides diagnostics from the user and logs them',
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

      await tester.tap(find.text('Load file'));
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
    await tester.tap(find.text('Mini keys (5 keys)').last);
    await tester.pumpAndSettle();

    final blocker = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();
    await tester.tap(find.text('Start'));
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

  testWidgets('successful Standard write reports verified and unchanged blocks',
      (tester) async {
    final targetBlocks = _miniTargetBlocks();
    final preferences = await _standardMiniPreferences(targetBlocks);
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _MiniMaintenanceCommunicator(
      logger,
      [
        for (var block = 0; block < 20; block++)
          Uint8List.fromList(targetBlocks[block]),
      ]..[1] = Uint8List(16),
    );
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = communicator;
    await _prepareStandardMiniPanel(tester, appState);

    final start = find.text('Start');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Complete: 1 block written and verified; 13 blocks already matched.',
      ),
      findsOneWidget,
    );
    expect(communicator.writeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ambiguous Standard write retains verified partial progress',
      (tester) async {
    final targetBlocks = _miniTargetBlocks()..[2][0] = 2;
    final preferences = await _standardMiniPreferences(targetBlocks);
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final communicator = _MiniMaintenanceCommunicator(
      logger,
      [
        for (var block = 0; block < 20; block++)
          Uint8List.fromList(targetBlocks[block]),
      ]
        ..[1] = Uint8List(16)
        ..[2] = Uint8List(16),
      ambiguousWriteBlock: 2,
    );
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = communicator;
    await _prepareStandardMiniPanel(tester, appState);

    final start = find.text('Start');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Progress retained: 1 block was written and verified before the operation stopped.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'The outcome of the last write is unknown. Start again before writing.',
      ),
      findsOneWidget,
    );
    expect(find.text('Write and verify'), findsNothing);
    expect(communicator.writeCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'disposing Standard UI after a sent write keeps mandatory read-back',
      (tester) async {
    final targetBlocks = _miniTargetBlocks();
    targetBlocks[2][0] = 2;
    final preferences = await _standardMiniPreferences(targetBlocks);
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final connector = _TestSerial(log: logger)..connected = true;
    final currentBlocks = [
      for (var block = 0; block < 20; block++)
        Uint8List.fromList(targetBlocks[block]),
    ]
      ..[1] = Uint8List(16)
      ..[2] = Uint8List(16);
    final communicator = _MiniMaintenanceCommunicator(logger, currentBlocks)
      ..writeStarted = Completer<void>()
      ..allowWriteResponse = Completer<void>();
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    await _prepareStandardMiniPanel(tester, appState);

    final start = find.text('Start');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    await communicator.writeStarted!.future.timeout(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('Writing changed blocks: 0/2'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Load file'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Select saved card'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Cancel'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: find.byType(DropdownButtonFormField<String>),
              matching: find.byType(DropdownButton<String>),
            ),
          )
          .onChanged,
      isNull,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    communicator.allowWriteResponse!.complete();
    await appState.rfOperations
        .runForeground(() async {})
        .timeout(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(communicator.writeCalls, 1);
    expect(communicator.postWriteScans, 1);
    expect(communicator.postWriteReads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Standard write stays active offstage, exposes global progress, and stops safely',
      (tester) async {
    final previousWakelock = wakelockPlusPlatformInstance;
    final wakelock = _RecordingWakelock();
    wakelockPlusPlatformInstance = wakelock;
    addTearDown(() => wakelockPlusPlatformInstance = previousWakelock);

    final targetBlocks = _miniTargetBlocks();
    targetBlocks[2][0] = 2;
    final preferences = await _standardMiniPreferences(targetBlocks);
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final connector = _TestSerial(log: logger)..connected = true;
    final currentBlocks = [
      for (var block = 0; block < 20; block++)
        Uint8List.fromList(targetBlocks[block]),
    ]
      ..[1] = Uint8List(16)
      ..[2] = Uint8List(16);
    final communicator = _MiniMaintenanceCommunicator(logger, currentBlocks)
      ..writeStarted = Completer<void>()
      ..allowWriteResponse = Completer<void>();
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;

    tester.view.physicalSize = const Size(1400, 1000);
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

    await tester.tap(find.byIcon(Icons.system_update_alt).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Standard MIFARE Classic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select saved card'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mini dump'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select key profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mini keys (5 keys)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await communicator.writeStarted!.future.timeout(const Duration(seconds: 2));
    await tester.pump();

    final writePage = tester.state<WriteCardPageState>(
      find.byType(WriteCardPage),
    );
    expect(appState.standardWriteActivity?.isActive, isTrue);
    expect(wakelock.states.last, isTrue);

    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pump();
    expect(find.byType(WriteCardPage), findsNothing);
    expect(
      find.byType(WriteCardPage, skipOffstage: false),
      findsOneWidget,
    );
    expect(writePage.mounted, isTrue);
    expect(
      find.byKey(
        const ValueKey('standard-write-global-progress'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('standard-write-global-progress')),
    );
    await tester.pump();
    expect(tester.state<WriteCardPageState>(find.byType(WriteCardPage)),
        same(writePage));
    expect(find.textContaining('Mini dump'), findsWidgets);
    expect(find.text('Writing changed blocks: 0/2'), findsNWidgets(2));

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    communicator.allowWriteResponse!.complete();
    await appState.rfOperations
        .runForeground(() async {})
        .timeout(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(communicator.writeCalls, 1);
    expect(communicator.postWriteScans, 1);
    expect(communicator.postWriteReads, 1);
    expect(
      appState.standardWriteActivity?.state,
      StandardWriteActivityState.cancelled,
    );
    expect(wakelock.states.last, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Standard session replacement after a sent write skips stale read-back',
      (tester) async {
    final targetBlocks = _miniTargetBlocks();
    targetBlocks[2][0] = 2;
    final preferences = await _standardMiniPreferences(targetBlocks);
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);
    final connector = _TestSerial(log: logger)..connected = true;
    final currentBlocks = [
      for (var block = 0; block < 20; block++)
        Uint8List.fromList(targetBlocks[block]),
    ]
      ..[1] = Uint8List(16)
      ..[2] = Uint8List(16);
    final communicator = _MiniMaintenanceCommunicator(logger, currentBlocks)
      ..writeStarted = Completer<void>()
      ..allowWriteResponse = Completer<void>();
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    await _prepareStandardMiniPanel(tester, appState);

    final start = find.text('Start');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    await communicator.writeStarted!.future.timeout(const Duration(seconds: 2));

    connector.connected = false;
    appState
      ..connector = (_TestSerial(log: logger)..connected = true)
      ..communicator = _ReaderModeCommunicator(logger)
      ..changesMade();
    communicator.allowWriteResponse!.complete();
    await appState.rfOperations
        .runForeground(() async {})
        .timeout(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(communicator.writeCalls, 1);
    expect(communicator.postWriteScans, 0);
    expect(communicator.postWriteReads, 0);
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

Future<SharedPreferencesProvider> _standardMiniPreferences(
  List<Uint8List> targetBlocks,
) async {
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
      data: targetBlocks,
    ),
  ]);
  return preferences;
}

Future<void> _prepareStandardMiniPanel(
  WidgetTester tester,
  ChameleonGUIState appState,
) async {
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
  await tester.tap(find.text('Mini keys (5 keys)').last);
  await tester.pumpAndSettle();
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

class _MiniMaintenanceCommunicator extends ChameleonCommunicator {
  _MiniMaintenanceCommunicator(
    super.logger,
    this.blocks, {
    this.ambiguousWriteBlock,
  });

  final List<Uint8List> blocks;
  final int? ambiguousWriteBlock;
  int readerModeCalls = 0;
  int writeCalls = 0;
  int postWriteScans = 0;
  int postWriteReads = 0;
  Completer<void>? writeStarted;
  Completer<void>? allowWriteResponse;

  @override
  Future<bool> isReaderDeviceMode() async {
    readerModeCalls++;
    return true;
  }

  @override
  Future<CardData?> scan14443aTag() async {
    if (writeCalls > 0) {
      postWriteScans++;
    }
    return CardData(
      uid: Uint8List.fromList([1, 2, 3, 4]),
      sak: 0x09,
      atqa: Uint8List.fromList([0x00, 0x04]),
      ats: Uint8List(0),
    );
  }

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
  ) async {
    if (writeCalls > 0) {
      postWriteReads++;
    }
    return ChameleonMessage(
      command: 0,
      status: 0,
      data: Uint8List.fromList(blocks[block]),
    );
  }

  @override
  Future<ChameleonMessage> mf1WriteBlockResult(
    int block,
    int keyType,
    Uint8List key,
    Uint8List data,
  ) async {
    writeCalls++;
    if (block != ambiguousWriteBlock) {
      blocks[block] = Uint8List.fromList(data);
    }
    if (writeStarted != null && !writeStarted!.isCompleted) {
      writeStarted!.complete();
    }
    await allowWriteResponse?.future;
    return ChameleonMessage(command: 0, status: 0, data: Uint8List(0));
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

class _RecordingWakelock extends WakelockPlusPlatformInterface {
  final List<bool> states = [];

  @override
  Future<bool> get enabled async => states.isNotEmpty && states.last;

  @override
  Future<void> toggle({required bool enable}) async {
    states.add(enable);
  }
}
