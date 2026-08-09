// ignore_for_file: non_constant_identifier_names

import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations_en.dart';
import 'package:chameleonultragui/gui/component/mifare/saved_key_profiles.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Ticket06Localizations extends AppLocalizationsEn {
  @override
  String get mifare_classic_assigned_key_profiles =>
      'Localized assigned key profiles';

  @override
  String get mifare_classic_import_key_profile => 'Localized import profile';

  @override
  String get mifare_classic_export_key_profile => 'Localized export profile';

  @override
  String get mifare_classic_delete_key_profile => 'Localized delete profile';

  @override
  String get mifare_classic_key_profile_imported =>
      'Localized profile imported';

  @override
  String get mifare_classic_key_profile_import_failed =>
      'Localized profile import failed';

  @override
  String get mifare_classic_key_profile_plaintext_warning =>
      'Localized plaintext warning';

  @override
  String mifare_classic_key_profile_summary(String cardType, int keyCount) =>
      'Localized summary: $cardType / $keyCount';

  @override
  String mifare_classic_key_profile_summary_with_uid(
    String cardType,
    int keyCount,
    String uid,
  ) =>
      'Localized summary: $cardType / $keyCount / $uid';

  @override
  String mifare_classic_key_a_sectors(String sectors) =>
      'Localized A sectors: $sectors';

  @override
  String mifare_classic_key_b_sectors(String sectors) =>
      'Localized B sectors: $sectors';
}

class _Ticket06LocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _Ticket06LocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) =>
      Future.value(_Ticket06Localizations());

  @override
  bool shouldReload(_Ticket06LocalizationsDelegate old) => false;
}

List<LocalizationsDelegate<dynamic>> get _localizationsDelegates => [
      const _Ticket06LocalizationsDelegate(),
      ...AppLocalizations.localizationsDelegates,
    ];

void main() {
  testWidgets('saved cards imports a canonical profile from its import action',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final profile = MifareClassicKeyProfile(
      id: 'imported-profile',
      name: 'Imported keys',
      cardType: 'm1k',
      sectorCount: 16,
      assignments: [
        MifareClassicKeyAssignment(
          sector: 0,
          keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
        ),
      ],
    );
    final appState = ChameleonGUIState(preferences);
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: _localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MifareClassicKeyProfilesCard(
              pickProfile: () async => profile,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Localized import profile'));
    await tester.pumpAndSettle();

    expect(find.text('Imported keys'), findsOneWidget);
    expect(find.text('Localized profile imported'), findsOneWidget);
    expect(preferences.getMifareClassicKeyProfiles().single.id,
        'imported-profile');
  });

  testWidgets('profile import keeps technical details out of localized UI',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: _localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MifareClassicKeyProfilesCard(
              pickProfile: () =>
                  Future.error(const FormatException('raw parser detail')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Localized import profile'));
    await tester.pumpAndSettle();

    expect(find.text('Localized profile import failed'), findsOneWidget);
    expect(find.textContaining('raw parser detail'), findsNothing);
  });

  testWidgets('saved cards automatically lists assigned key profiles',
      (tester) async {
    SharedPreferences.setMockInitialValues({'confirm_delete': false});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    preferences.setMifareClassicKeyProfiles([
      MifareClassicKeyProfile(
        id: 'own-card-profile',
        name: 'Own 4K card',
        cardType: 'm4k',
        sectorCount: 40,
        uid: '01020304',
        assignments: [
          MifareClassicKeyAssignment(
            sector: 0,
            keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          ),
          MifareClassicKeyAssignment(
            sector: 1,
            keyB: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
          ),
        ],
      ),
    ]);
    final appState = ChameleonGUIState(preferences);

    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: _localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SavedCardsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cards'), findsOneWidget);
    expect(find.text('Dictionaries'), findsOneWidget);
    expect(find.text('Localized assigned key profiles'), findsOneWidget);
    expect(find.text('Own 4K card'), findsOneWidget);
    expect(find.text('Localized summary: MIFARE Classic 4K / 2 / 01020304'),
        findsOneWidget);

    await tester.tap(find.text('Own 4K card'));
    await tester.pumpAndSettle();
    expect(find.text('010203040506'), findsOneWidget);
    expect(find.text('Localized plaintext warning'), findsOneWidget);
    expect(find.text('Localized A sectors: 0'), findsOneWidget);
    expect(find.text('Localized B sectors: 1'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Localized delete profile'));
    await tester.pumpAndSettle();

    expect(preferences.getMifareClassicKeyProfiles(), isEmpty);
    expect(find.text('Own 4K card'), findsNothing);
  });
}
