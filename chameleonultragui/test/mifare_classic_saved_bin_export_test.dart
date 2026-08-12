import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/element_button.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/view.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_viewport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'saved card BIN export rejects a known partial MIFARE Classic dump',
      (tester) async {
    final filePickerCalls = await _recordFilePickerCalls();
    late BuildContext exportContext;

    await tester.pumpWidget(_testApp(
      Builder(builder: (context) {
        exportContext = context;
        return const SizedBox();
      }),
    ));

    await saveTag(
      _mifareClassic1KCard(
        name: 'Partial recovery',
        complete: false,
        data: List.generate(
          64,
          (block) => block == 12 ? Uint8List(0) : Uint8List(16),
        ),
      ),
      exportContext,
      true,
    );
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

  testWidgets('saved card BIN export rejects malformed complete geometry',
      (tester) async {
    final filePickerCalls = await _recordFilePickerCalls();
    late BuildContext exportContext;

    await tester.pumpWidget(_testApp(
      Builder(builder: (context) {
        exportContext = context;
        return const SizedBox();
      }),
    ));

    await saveTag(
      _mifareClassic1KCard(
        name: 'Malformed complete dump',
        complete: true,
        data: List.generate(
          64,
          (block) => Uint8List(block == 12 ? 15 : 16),
        ),
      ),
      exportContext,
      true,
    );
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

  testWidgets('partial MIFARE Classic saved card remains exportable as JSON',
      (tester) async {
    final filePickerCalls = await _recordFilePickerCalls();
    late BuildContext exportContext;

    await tester.pumpWidget(_testApp(
      Builder(builder: (context) {
        exportContext = context;
        return const SizedBox();
      }),
    ));

    await saveTag(
      _mifareClassic1KCard(
        name: 'Partial JSON',
        complete: false,
        data: List.generate(
          64,
          (block) => block == 12 ? Uint8List(0) : Uint8List(16),
        ),
      ),
      exportContext,
      false,
    );

    expect(filePickerCalls, hasLength(1));
    final arguments = filePickerCalls.single.arguments as Map;
    final json = jsonDecode(
      utf8.decode(List<int>.from(arguments['bytes'] as List)),
    ) as Map<String, dynamic>;
    expect(arguments['fileName'], 'Partial JSON.json');
    expect(
      (json['extra'] as Map<String, dynamic>)['mifareClassicDumpComplete'],
      isFalse,
    );
  });

  testWidgets('complete saved cards export exact BIN bytes for every geometry',
      (tester) async {
    final filePickerCalls = await _recordFilePickerCalls();
    late BuildContext exportContext;

    await tester.pumpWidget(_testApp(
      Builder(builder: (context) {
        exportContext = context;
        return const SizedBox();
      }),
    ));

    const cases = [
      (name: 'Mini', tag: TagType.mifareMini, blockCount: 20, imageSize: 320),
      (name: '1K', tag: TagType.mifare1K, blockCount: 64, imageSize: 1024),
      (name: 'EV1', tag: TagType.mifare1K, blockCount: 72, imageSize: 1152),
      (name: '2K', tag: TagType.mifare2K, blockCount: 128, imageSize: 2048),
      (name: '4K', tag: TagType.mifare4K, blockCount: 256, imageSize: 4096),
    ];

    for (final geometryCase in cases) {
      final expectedBin = Uint8List.fromList(List.generate(
        geometryCase.imageSize,
        (index) => (index % 251) + 1,
      ));
      final card = CardSave(
        uid: '01 02 03 04',
        name: geometryCase.name,
        tag: geometryCase.tag,
        data: List.generate(
          256,
          (block) => block < geometryCase.blockCount
              ? Uint8List.sublistView(
                  expectedBin,
                  block * 16,
                  (block + 1) * 16,
                )
              : Uint8List(0),
        ),
        extraData: CardSaveExtra(mifareClassicDumpComplete: true),
      );

      await saveTag(card, exportContext, true);

      final arguments = filePickerCalls.last.arguments as Map;
      expect(arguments['fileName'], '${geometryCase.name}.bin');
      expect(arguments['bytes'], expectedBin, reason: geometryCase.name);
      expect(
        (arguments['bytes'] as Uint8List).length,
        geometryCase.imageSize,
        reason: geometryCase.name,
      );
    }

    expect(filePickerCalls, hasLength(cases.length));
  });

  testWidgets(
      'Saved Cards does not offer BIN for a partial MIFARE Classic dump',
      (tester) async {
    final filePickerCalls = await _recordFilePickerCalls();
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    preferences.setCards([
      _mifareClassic1KCard(
        name: 'Partial saved card',
        complete: false,
        data: List.generate(
          64,
          (block) => block == 12 ? Uint8List(0) : Uint8List(16),
        ),
      ),
    ]);
    final appState = ChameleonGUIState(preferences);

    setTestViewport(tester, size: const Size(1200, 1400));

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: _testApp(const SavedCardsPage()),
      ),
    );
    await tester.pumpAndSettle();

    final cardTile = find.ancestor(
      of: find.text('Partial saved card'),
      matching: find.byType(ElementButton),
    );
    await tester.tap(
      find.descendant(of: cardTile, matching: find.byIcon(Icons.download)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Save as .bin'), findsNothing);
    expect(find.text('Save as .json'), findsOneWidget);
    expect(filePickerCalls, isEmpty);
  });

  testWidgets('Card View does not offer BIN for malformed MIFARE Classic data',
      (tester) async {
    final filePickerCalls = await _recordFilePickerCalls();
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final malformedCard = _mifareClassic1KCard(
      name: 'Malformed saved card',
      complete: true,
      data: List.generate(
        64,
        (block) => Uint8List(block == 12 ? 15 : 16),
      ),
    );
    preferences.setCards([malformedCard]);
    final appState = ChameleonGUIState(preferences);

    setTestViewport(tester, size: const Size(1200, 1400));

    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: _testApp(
          CardViewMenu(
            tagSave: malformedCard,
            onMove: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Save as .bin'), findsNothing);
    expect(find.text('Save as .json'), findsOneWidget);
    expect(filePickerCalls, isEmpty);
  });
}

Future<List<MethodCall>> _recordFilePickerCalls() async {
  const channel = MethodChannel(
    'miguelruivo.flutter.plugins.filepicker',
    StandardMethodCodec(),
  );
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return '/tmp/export.bin';
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  return calls;
}

Widget _testApp(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

CardSave _mifareClassic1KCard({
  required String name,
  required bool complete,
  required List<Uint8List> data,
}) =>
    CardSave(
      uid: '01 02 03 04',
      name: name,
      tag: TagType.mifare1K,
      data: data,
      extraData: CardSaveExtra(mifareClassicDumpComplete: complete),
    );
