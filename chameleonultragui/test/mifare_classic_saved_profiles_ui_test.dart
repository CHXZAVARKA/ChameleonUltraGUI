// ignore_for_file: non_constant_identifier_names

import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations_en.dart';
import 'package:chameleonultragui/gui/component/mifare/saved_key_profiles.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mifare_classic_localizations.dart';
import 'support/test_viewport.dart';

class _SavedProfilesLocalizations extends AppLocalizationsEn {
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

final _savedProfilesLocalizationsDelegates =
    mifareClassicTestLocalizationsDelegates(_SavedProfilesLocalizations());

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
    setTestViewport(tester, size: const Size(1200, 1400));
    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: _savedProfilesLocalizationsDelegates,
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

  testWidgets('profile import keeps plaintext keys out of UI and stored logs',
      (tester) async {
    const plaintextKey = 'A0A1A2A3A4A5';
    const malformedProfile =
        '{"assignments":[{"sector":0,"keyA":"$plaintextKey"}]';
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(
      filter: ChameleonLogFilter(),
      printer: PrettyPrinter(noBoxingByDefault: true),
      output: SharedPreferencesLogger(preferences),
    );
    addTearDown(logger.close);
    final appState = ChameleonGUIState(preferences)..log = logger;

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: _savedProfilesLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MifareClassicKeyProfilesCard(
              pickProfile: () => Future.error(
                const FormatException(
                  'Unexpected end of input',
                  malformedProfile,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Localized import profile'));
    await tester.pumpAndSettle();

    expect(find.text('Localized profile import failed'), findsOneWidget);
    expect(find.textContaining(plaintextKey), findsNothing);
    final storedLog = preferences.getLogLines().join('\n');
    expect(storedLog, contains('Failed to import MIFARE Classic key profile'));
    expect(storedLog, isNot(contains(plaintextKey)));
    expect(storedLog, isNot(contains(malformedProfile)));
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

    setTestViewport(tester, size: const Size(1200, 1400));

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: _savedProfilesLocalizationsDelegates,
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
    expect(find.text('Localized summary: MIFARE Classic 4K / 1 / 01020304'),
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
