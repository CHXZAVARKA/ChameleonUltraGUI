import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/create.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/edit.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('create dialog explains field sizes and generates a whole card',
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: CardCreateMenu()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Required · 4 or 7 bytes'), findsOneWidget);
    expect(find.text('Optional · any length'), findsOneWidget);
    expect(find.byIcon(Icons.casino_outlined), findsWidgets);

    await tester.tap(find.byKey(const Key('generate-card-data')));
    await tester.pump();

    final state = tester.state<CardCreateMenuState>(
      find.byType(CardCreateMenu),
    );
    expect(state.uidController.text, isNotEmpty);
    expect(state.sakController.text, '08');
    expect(state.atqaController.text, isNotEmpty);
    expect(state.atsController.text, isEmpty);

    state.nameController.text = 'Random Classic';
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final saved = preferences.getCards().single;
    expect(saved.data, hasLength(64));
    expect(saved.extraData.mifareClassicDumpComplete, isTrue);
  });

  testWidgets('whole-card generation in edit rebuilds the saved memory',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final original = CardSave(
      id: 'generated-card',
      name: 'Generated card',
      uid: '0F 01 02 03',
      sak: 0x08,
      atqa: Uint8List.fromList([0x00, 0x04]),
      tag: TagType.mifare1K,
      data: List.generate(64, (_) => Uint8List.fromList(List.filled(16, 0xAA))),
    );
    preferences.setCards([original]);
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
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CardEditMenu(tagSave: original),
                ),
                child: const Text('Open edit'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('generate-card-data')));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = preferences.getCards().single;
    expect(saved.data, hasLength(64));
    expect(saved.data.first, isNot(original.data.first));
    expect(saved.extraData.mifareClassicDumpComplete, isTrue);
  });

  testWidgets('create stores generated counters for NTAG cards',
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: CardCreateMenu()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<TagType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NTAG213').last);
    await tester.pumpAndSettle();

    final state = tester.state<CardCreateMenuState>(
      find.byType(CardCreateMenu),
    );
    expect(state.ultralightCounterControllers, hasLength(1));

    state.nameController.text = 'Random NTAG';
    await tester.tap(find.byKey(const Key('generate-card-data')));
    await tester.pump();
    final generatedCounter =
        int.parse(state.ultralightCounterControllers.single.text);
    expect(generatedCounter, inInclusiveRange(0, 0xFFFFFF));

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(
      preferences.getCards().single.extraData.ultralightCounters,
      [generatedCounter],
    );
  });
}
