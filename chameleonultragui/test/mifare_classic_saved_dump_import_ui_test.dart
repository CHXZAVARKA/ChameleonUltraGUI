import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/gui/page/write_card.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_viewport.dart';

void main() {
  for (final uidLength in [4, 7]) {
    testWidgets(
      '4K BIN saved as 1K with $uidLength-byte UID stays incomplete for writer',
      (tester) => _verifyOversizedImport(tester, uidLength),
    );
  }

  testWidgets('exact Mini, 1K, EV1, 2K, and 4K BINs import as complete',
      (tester) async {
    const cases = [
      (
        name: 'Mini dump',
        imageSize: 320,
        type: MifareClassicType.mini,
        isEV1: false,
      ),
      (
        name: '1K dump',
        imageSize: 1024,
        type: MifareClassicType.m1k,
        isEV1: false,
      ),
      (
        name: '1K EV1 dump',
        imageSize: 1152,
        type: MifareClassicType.m1k,
        isEV1: true,
      ),
      (
        name: '2K dump',
        imageSize: 2048,
        type: MifareClassicType.m2k,
        isEV1: false,
      ),
      (
        name: '4K dump',
        imageSize: 4096,
        type: MifareClassicType.m4k,
        isEV1: false,
      ),
    ];
    var selectedCase = cases.first;

    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final appState = ChameleonGUIState(preferences);

    setTestViewport(tester, size: const Size(1200, 1400));

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SavedCardsPage(
            pickFile: () async => PlatformFile(
              name: '${selectedCase.name}.bin',
              path: '/tmp/${selectedCase.name}.bin',
              size: selectedCase.imageSize,
            ),
            readFile: (_) async => Uint8List(selectedCase.imageSize),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final geometryCase in cases) {
      selectedCase = geometryCase;
      await tester.tap(find.byIcon(Icons.file_upload).first);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextFormField).last, geometryCase.name);
      await tester.tap(find.text('Save as 4 byte UID'));
      await tester.pumpAndSettle();
    }

    final cards = preferences.getCards();
    expect(cards, hasLength(cases.length));
    for (final geometryCase in cases) {
      final card = cards.singleWhere((card) => card.name == geometryCase.name);
      final geometry = MifareClassicGeometry.fromSavedCard(card);
      expect(
        (
          card.extraData.mifareClassicDumpComplete,
          geometry?.type,
          geometry?.isEV1,
          geometry?.imageSize,
        ),
        (
          true,
          geometryCase.type,
          geometryCase.isEV1,
          geometryCase.imageSize,
        ),
        reason: geometryCase.name,
      );
    }
  });
}

Future<void> _verifyOversizedImport(
  WidgetTester tester,
  int uidLength,
) async {
  final dumpBytes = Uint8List(4096);
  final dump = PlatformFile(
    name: 'oversized.bin',
    path: '/tmp/oversized.bin',
    size: dumpBytes.length,
  );

  SharedPreferences.setMockInitialValues({});
  final preferences = SharedPreferencesProvider();
  await preferences.load();
  final appState = ChameleonGUIState(preferences);

  setTestViewport(tester, size: const Size(1200, 1400));

  Widget page(Widget child) {
    return ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );
  }

  Future<void> settle() async {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
  }

  await tester.pumpWidget(page(SavedCardsPage(
    pickFile: () async => dump,
    readFile: (_) async => dumpBytes,
  )));
  await settle();

  await tester.tap(find.byIcon(Icons.file_upload).first);
  await settle();
  expect(find.text('Correct tag details'), findsOneWidget);

  final cardName = 'Oversized as 1K ($uidLength-byte UID)';
  await tester.enterText(find.byType(TextFormField).last, cardName);
  await tester.tap(find.text('Mifare Classic 4K'));
  await settle();
  await tester.tap(find.text('Mifare Classic 1K').last);
  await settle();
  if (uidLength == 7) {
    await tester.enterText(find.byType(TextFormField).at(5), '00 00');
  }
  await tester.ensureVisible(find.text('Save as $uidLength byte UID'));
  await tester.tap(find.text('Save as $uidLength byte UID'));
  await settle();

  final imported = preferences.getCards().single;
  expect(imported.extraData.mifareClassicDumpComplete, isFalse);

  await tester.pumpWidget(page(const WriteCardPage()));
  await settle();
  await tester.tap(find.text('Standard MIFARE Classic'));
  await settle();
  await tester.tap(find.text('Select saved card'));
  await settle();

  expect(
    find.textContaining('No usable saved MIFARE Classic dumps'),
    findsOneWidget,
  );
  expect(find.text(cardName), findsNothing);
}
