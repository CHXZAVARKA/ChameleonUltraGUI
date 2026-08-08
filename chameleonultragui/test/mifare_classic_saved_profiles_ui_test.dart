import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/mifare/saved_key_profiles.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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

    await tester.tap(find.text('Import key profile'));
    await tester.pumpAndSettle();

    expect(find.text('Imported keys'), findsOneWidget);
    expect(preferences.getMifareClassicKeyProfiles().single.id,
        'imported-profile');
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SavedCardsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cards'), findsOneWidget);
    expect(find.text('Dictionaries'), findsOneWidget);
    expect(find.text('Assigned key profiles'), findsOneWidget);
    expect(find.text('Own 4K card'), findsOneWidget);
    expect(
        find.text('MIFARE Classic 4K · 2 keys · UID 01020304'), findsOneWidget);

    await tester.tap(find.text('Own 4K card'));
    await tester.pumpAndSettle();
    expect(find.text('010203040506'), findsOneWidget);
    expect(find.text('Key A sectors: 0'), findsOneWidget);
    expect(find.text('Key B sectors: 1'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete key profile'));
    await tester.pumpAndSettle();

    expect(preferences.getMifareClassicKeyProfiles(), isEmpty);
    expect(find.text('Own 4K card'), findsNothing);
  });
}
