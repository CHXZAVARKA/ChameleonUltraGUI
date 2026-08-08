import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/mifare/classic.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/read_card_session.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('mifare_classic_assigned_profile_visual_smoke', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/wakelock'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    preferences.setMifareClassicKeyProfiles([
      MifareClassicKeyProfile(
        id: 'matching-profile',
        name: 'Office doors',
        cardType: 'm1k',
        sectorCount: 16,
        uid: '01 02 03 04',
        assignments: [
          MifareClassicKeyAssignment(
            sector: 0,
            keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          ),
        ],
      ),
      MifareClassicKeyProfile(
        id: 'matching-ev1-profile',
        name: 'Office doors EV1',
        cardType: 'm1k',
        sectorCount: 18,
        uid: '01 02 03 04',
        assignments: [
          MifareClassicKeyAssignment(
            sector: 0,
            keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          ),
        ],
      ),
    ]);
    final appState = ChameleonGUIState(preferences);
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
    );
    final info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      state: MifareClassicState.checkKeys,
    )..recovery = recovery;

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
          home: Scaffold(
            body: SingleChildScrollView(
              child: MifareClassicHelper(
                hfInfo: HFCardInfo(uid: '01 02 03 04'),
                mfcInfo: info,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Assigned key profile'), findsOneWidget);
    expect(find.textContaining('Office doors'), findsOneWidget);
    expect(find.byTooltip('Import key profile'), findsNothing);
    expect(recovery.selectedKeyProfile?.id, 'matching-profile');

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
                hfInfo: HFCardInfo(uid: '01 02 03 04'),
                mfcInfo: replacementInfo,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(replacementRecovery.selectedKeyProfile?.id, 'matching-profile');

    final ev1Info = MifareClassicInfo(
      type: MifareClassicType.m1k,
      isEV1: true,
      state: MifareClassicState.checkKeys,
    )..recovery = replacementRecovery;
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
                hfInfo: HFCardInfo(uid: '01 02 03 04'),
                mfcInfo: ev1Info,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(replacementRecovery.selectedKeyProfile?.id, 'matching-ev1-profile');
  });
}
