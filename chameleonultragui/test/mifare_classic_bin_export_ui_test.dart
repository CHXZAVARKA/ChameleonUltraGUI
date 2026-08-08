import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/mifare/classic.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('partial MIFARE Classic recovery cannot be exported as BIN',
      (tester) async {
    const filePickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
      StandardMethodCodec(),
    );
    final filePickerCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(filePickerChannel, (call) async {
      filePickerCalls.add(call);
      return '/tmp/partial.bin';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(filePickerChannel, null));

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/wakelock'),
      (call) async => null,
    );

    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences);
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
      dumpComplete: false,
      cardData: List.generate(
        256,
        (block) => block < 64
            ? Uint8List.fromList(List.filled(16, block))
            : Uint8List(0),
      ),
    );
    final info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.save,
    )..recovery = recovery;

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: MifareClassicHelper(
                hfInfo: HFCardInfo(
                  uid: '01 02 03 04',
                  sak: '08',
                  atqa: '00 04',
                  ats: localizations.no,
                ),
                mfcInfo: info,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Save as .bin'));
    await tester.pump();

    expect(filePickerCalls, isEmpty);
    expect(
      find.text(
        'BIN export requires a complete MIFARE Classic dump. '
        'Save this partial recovery in the app instead.',
      ),
      findsOneWidget,
    );
  });

  final invalidGeometryCases = <(String, List<Uint8List>)>[
    (
      'a missing block',
      List.generate(63, (_) => Uint8List(16)),
    ),
    (
      'a 15-byte block',
      List.generate(
        64,
        (block) => Uint8List(block == 12 ? 15 : 16),
      ),
    ),
    (
      'a non-empty trailing block',
      List.generate(
        256,
        (block) => block <= 64 ? Uint8List(16) : Uint8List(0),
      ),
    ),
  ];

  for (final (malformation, cardData) in invalidGeometryCases) {
    testWidgets(
        'complete MIFARE Classic recovery with $malformation cannot be exported as BIN',
        (tester) async {
      const filePickerChannel = MethodChannel(
        'miguelruivo.flutter.plugins.filepicker',
        StandardMethodCodec(),
      );
      final filePickerCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(filePickerChannel, (call) async {
        filePickerCalls.add(call);
        return '/tmp/invalid.bin';
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(filePickerChannel, null));

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/wakelock'),
        (call) async => null,
      );

      SharedPreferences.setMockInitialValues({});
      final preferences = SharedPreferencesProvider();
      await preferences.load();
      final appState = ChameleonGUIState(preferences);
      final localizations =
          await AppLocalizations.delegate.load(const Locale('en'));
      final recovery = MifareClassicRecovery(
        appState: appState,
        update: () {},
        localizations: localizations,
        mifareClassicType: MifareClassicType.m1k,
        dumpComplete: true,
        cardData: cardData,
      );
      final info = MifareClassicInfo(
        type: MifareClassicType.m1k,
        state: MifareClassicState.save,
      )..recovery = recovery;

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: MifareClassicHelper(
                  hfInfo: HFCardInfo(
                    uid: '01 02 03 04',
                    sak: '08',
                    atqa: '00 04',
                    ats: localizations.no,
                  ),
                  mfcInfo: info,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Save as .bin'));
      await tester.pump();

      expect(filePickerCalls, isEmpty);
      expect(
        find.text(
          'BIN export requires a complete MIFARE Classic dump. '
          'Save this partial recovery in the app instead.',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('partial MIFARE Classic recovery can be saved in the app',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/wakelock'),
      (call) async => null,
    );

    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences);
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
      dumpComplete: false,
      cardData: List.generate(
        256,
        (block) => block < 64
            ? Uint8List.fromList(List.filled(16, block))
            : Uint8List(0),
      ),
    );
    final info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.save,
    )..recovery = recovery;

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: MifareClassicHelper(
                hfInfo: HFCardInfo(
                  uid: '01 02 03 04',
                  sak: '08',
                  atqa: '00 04',
                  ats: localizations.no,
                ),
                mfcInfo: info,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Partial recovery');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final savedCard = preferences.getCards().single;
    expect(savedCard.name, 'Partial recovery');
    expect(savedCard.data, recovery.cardData);
    expect(savedCard.extraData.mifareClassicDumpComplete, isFalse);
  });

  testWidgets(
      'complete MIFARE Classic recovery exports unchanged BIN bytes for every geometry',
      (tester) async {
    const filePickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
      StandardMethodCodec(),
    );
    final filePickerCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(filePickerChannel, (call) async {
      filePickerCalls.add(call);
      return '/tmp/complete.bin';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(filePickerChannel, null));

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/wakelock'),
      (call) async => null,
    );

    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences);
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    const cases = [
      (
        name: 'Mini',
        type: MifareClassicType.mini,
        isEV1: false,
        blockCount: 20,
      ),
      (
        name: '1K',
        type: MifareClassicType.m1k,
        isEV1: false,
        blockCount: 64,
      ),
      (
        name: 'EV1',
        type: MifareClassicType.m1k,
        isEV1: true,
        blockCount: 72,
      ),
      (
        name: '2K',
        type: MifareClassicType.m2k,
        isEV1: false,
        blockCount: 128,
      ),
      (
        name: '4K',
        type: MifareClassicType.m4k,
        isEV1: false,
        blockCount: 256,
      ),
    ];

    for (final geometryCase in cases) {
      final expectedBin = Uint8List.fromList(List.generate(
        geometryCase.blockCount * 16,
        (index) => (index % 251) + 1,
      ));
      final recovery = MifareClassicRecovery(
        appState: appState,
        update: () {},
        localizations: localizations,
        mifareClassicType: geometryCase.type,
        isMifareClassicEV1: geometryCase.isEV1,
        dumpComplete: true,
        cardData: List.generate(
          256,
          (block) => block < geometryCase.blockCount
              ? Uint8List.sublistView(
                  expectedBin,
                  block * 16,
                  (block + 1) * 16,
                )
              : Uint8List(0),
        ),
      );
      final info = MifareClassicInfo(
        type: geometryCase.type,
        isEV1: geometryCase.isEV1,
        state: MifareClassicState.save,
      )..recovery = recovery;

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: MifareClassicHelper(
                  hfInfo: HFCardInfo(
                    uid: '01 02 03 04',
                    sak: '08',
                    atqa: '00 04',
                    ats: localizations.no,
                  ),
                  mfcInfo: info,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Save as .bin'));
      await tester.pump();

      final arguments = filePickerCalls.last.arguments as Map;
      expect(filePickerCalls.last.method, 'save', reason: geometryCase.name);
      expect(arguments['fileName'], '01020304.bin', reason: geometryCase.name);
      expect(arguments['bytes'], expectedBin, reason: geometryCase.name);
    }

    expect(filePickerCalls, hasLength(cases.length));
  });
}
