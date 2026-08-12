import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/edit.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/view.dart';
import 'package:chameleonultragui/gui/menu/pages/dump_editor.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_viewport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('normal card edit invalidates complete Classic BIN eligibility', (
    tester,
  ) async {
    final harness = await _EditHarness.create(tester);

    await harness.pump(CardEditMenu(tagSave: harness.card));
    await tester.enterText(find.byType(TextFormField).first, 'Renamed card');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final savedCard = harness.preferences.getCards().single;
    expect(savedCard.name, 'Renamed card');
    expect(savedCard.extraData.mifareClassicDumpComplete, isFalse);
    expect(MifareClassicGeometry.fromSavedCard(savedCard), isNull);
  });

  testWidgets('changing card type removes inherited Classic BIN eligibility', (
    tester,
  ) async {
    final harness = await _EditHarness.create(tester);

    await harness.pump(CardEditMenu(tagSave: harness.card));
    final typeSelector = tester.widget<DropdownButton<TagType>>(
      find.byType(DropdownButton<TagType>),
    );
    typeSelector.onChanged!(TagType.ntag213);
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-card-data')));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final savedCard = harness.preferences.getCards().single;
    expect(savedCard.tag, TagType.ntag213);
    expect(savedCard.extraData.mifareClassicDumpComplete, isNull);
    expect(MifareClassicGeometry.fromSavedCard(savedCard), isNull);
  });

  testWidgets('Dump Editor save invalidates complete Classic BIN eligibility', (
    tester,
  ) async {
    final harness = await _EditHarness.create(tester);

    await harness.pump(
      CardViewMenu(tagSave: harness.card, onMove: (_) async {}),
    );
    await tester.tap(find.byIcon(Icons.edit_document));
    await tester.pumpAndSettle();

    expect(find.byType(DumpEditor), findsOneWidget);
    final firstEditor = find.byType(TextFormField).first;
    final field = tester.widget<TextFormField>(firstEditor);
    final editedText = field.controller!.text.replaceFirst('00', '01');
    field.controller!.text = editedText;
    await tester.pump();
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();

    final savedCard = harness.preferences.getCards().single;
    expect(savedCard.data.first.first, 1);
    expect(savedCard.extraData.mifareClassicDumpComplete, isFalse);
    expect(MifareClassicGeometry.fromSavedCard(savedCard), isNull);
  });
}

class _EditHarness {
  _EditHarness({
    required this.tester,
    required this.preferences,
    required this.appState,
    required this.card,
  });

  final WidgetTester tester;
  final SharedPreferencesProvider preferences;
  final ChameleonGUIState appState;
  final CardSave card;

  static Future<_EditHarness> create(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final card = CardSave(
      id: 'complete-card',
      uid: '01 02 03 04',
      name: 'Complete card',
      tag: TagType.mifare1K,
      sak: 0x08,
      atqa: Uint8List.fromList([0x00, 0x04]),
      data: List.generate(64, (_) => Uint8List(16)),
      extraData: CardSaveExtra(mifareClassicDumpComplete: true),
    );
    preferences.setCards([card]);
    final appState = ChameleonGUIState(preferences);

    setTestViewport(tester, size: const Size(1200, 1400));

    return _EditHarness(
      tester: tester,
      preferences: preferences,
      appState: appState,
      card: card,
    );
  }

  Future<void> pump(Widget child) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}
