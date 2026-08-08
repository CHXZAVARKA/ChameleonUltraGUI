import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/edit.dart';
import 'package:chameleonultragui/gui/page/write_card.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
}
