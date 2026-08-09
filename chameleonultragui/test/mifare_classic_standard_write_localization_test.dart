// ignore_for_file: non_constant_identifier_names

import 'dart:io';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations_en.dart';
import 'package:chameleonultragui/gui/page/write_card.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mifare_classic_localizations.dart';

class _WriterLocalizations extends AppLocalizationsEn {
  @override
  String get mifare_classic_magic_card_mode => 'Localized magic mode';

  @override
  String get mifare_classic_standard_card_mode => 'Localized standard mode';

  @override
  String get mifare_classic_standard_write_title => 'Localized writer title';

  @override
  String get mifare_classic_standard_safe_blocks_note =>
      'Localized safe blocks note';

  @override
  String get mifare_classic_standard_load_file => 'Localized load file';

  @override
  String get mifare_classic_standard_or => 'Localized or';

  @override
  String get select_saved_card => 'Localized select saved card';

  @override
  String get mifare_classic_standard_select_key_profile =>
      'Localized select profile';

  @override
  String get mifare_classic_standard_start => 'Localized start';

  @override
  String get mifare_classic_standard_phase_preflight =>
      'Localized checking phase';

  @override
  String get mifare_classic_standard_phase_revalidating =>
      'Localized revalidating phase';

  @override
  String get mifare_classic_standard_phase_writing => 'Localized writing phase';

  @override
  String get mifare_classic_standard_phase_verifying =>
      'Localized verifying phase';

  @override
  String mifare_classic_standard_progress(
          String phase, int completed, int total) =>
      'Localized progress: $phase $completed/$total';

  @override
  String get mifare_classic_standard_no_usable_saved_dumps =>
      'Localized no usable dumps';

  @override
  String mifare_classic_standard_operation_failed(String reason) =>
      'Localized operation stopped: $reason';
}

final _writerLocalizationsDelegates =
    mifareClassicTestLocalizationsDelegates(_WriterLocalizations());

void main() {
  test('Standard writer count messages use independent English plurals', () {
    final localizations = AppLocalizationsEn();

    expect(
      localizations.mifare_classic_standard_preflight_ready(1, 2),
      'Preflight passed: 1 block will change and 2 blocks already match.',
    );
    expect(
      localizations.mifare_classic_standard_preflight_ready(2, 1),
      'Preflight passed: 2 blocks will change and 1 block already matches.',
    );
    expect(
      localizations.mifare_classic_standard_preflight_ready(1, 1),
      'Preflight passed: 1 block will change and 1 block already matches.',
    );
    expect(
      localizations.mifare_classic_standard_preflight_ready(2, 2),
      'Preflight passed: 2 blocks will change and 2 blocks already match.',
    );
    expect(
      localizations.mifare_classic_standard_write_complete(1),
      'Complete: 1 block written and verified.',
    );
    expect(
      localizations.mifare_classic_standard_write_complete(2),
      'Complete: 2 blocks written and verified.',
    );
    expect(
      localizations.mifare_classic_standard_write_complete_summary(1, 2),
      'Complete: 1 block written and verified; 2 blocks already matched.',
    );
    expect(
      localizations.mifare_classic_standard_write_complete_summary(2, 1),
      'Complete: 2 blocks written and verified; 1 block already matched.',
    );
    expect(
      localizations.mifare_classic_standard_verified_before_stop(0),
      'Progress retained: 0 blocks were written and verified before the operation stopped.',
    );
    expect(
      localizations.mifare_classic_standard_verified_before_stop(1),
      'Progress retained: 1 block was written and verified before the operation stopped.',
    );
    expect(
      localizations.mifare_classic_standard_unsupported_dump_size(1),
      'Unsupported dump size: 1 byte. Expected 320, 1024, 1152, 2048, or 4096 bytes.',
    );
    expect(
      localizations.mifare_classic_standard_unsupported_dump_size(2),
      'Unsupported dump size: 2 bytes. Expected 320, 1024, 1152, 2048, or 4096 bytes.',
    );
  });

  testWidgets('Standard writer renders through canonical localizations',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
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
          localizationsDelegates: _writerLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const WriteCardPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Localized magic mode'), findsOneWidget);
    expect(find.text('Localized standard mode'), findsOneWidget);

    await tester.tap(find.text('Localized standard mode'));
    await tester.pumpAndSettle();

    expect(find.text('Localized writer title'), findsOneWidget);
    expect(find.text('Localized safe blocks note'), findsOneWidget);
    expect(find.text('Localized load file'), findsOneWidget);
    expect(find.text('Localized or'), findsOneWidget);
    expect(find.text('Localized select saved card'), findsOneWidget);
    expect(find.text('Localized select profile'), findsOneWidget);
    expect(find.text('Localized start'), findsOneWidget);

    await tester.tap(find.text('Localized select saved card'));
    await tester.pumpAndSettle();

    expect(
      find.text('Localized operation stopped: Localized no usable dumps'),
      findsOneWidget,
    );
  });

  test('Standard writer has no temporary feature-string remnants', () {
    expect(
      File('lib/gui/component/mifare/feature_strings.dart').existsSync(),
      isFalse,
    );

    final dartSources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    final productionSource =
        dartSources.map((file) => file.readAsStringSync()).join('\n');

    expect(productionSource, isNot(contains('feature_strings.dart')));
    expect(productionSource, isNot(contains('MifareClassicFeatureStrings')));

    final writerSource = [
      File('lib/gui/component/mifare/standard_write.dart'),
      File('lib/gui/page/write_card.dart'),
    ].map((file) => file.readAsStringSync()).join('\n');
    expect(
      RegExp(r'''(['"])Magic card\1''').hasMatch(writerSource),
      isFalse,
    );
    for (final legacyText in [
      'Standard MIFARE Classic',
      "Write the card's own dump to a standard card",
      'Select a complete Mini,',
      'Only data blocks are written.',
      'Select .bin dump',
      'Load file',
      'OR',
      'No usable saved MIFARE Classic dumps',
      'Unverified legacy dump',
      'predates completeness tracking',
      'Use saved dump',
      'Select key profile',
      'Run preflight',
      'Start',
      'Preflight is running.',
      'Preflight passed:',
      'I confirm this is my card',
      'Write and verify',
      'Keep the card and Chameleon Ultra still.',
      'blocks written and verified.',
      'Operation stopped',
      'Unsupported dump size:',
      'The selected dump is not supported.',
      'The selected key profile is not compatible with this dump.',
      'Communication with Chameleon was lost. Reconnect and try again.',
      'The card check expired.',
      'The presented card does not match the selected dump.',
      'The selected key profile could not authenticate this card.',
      'This card does not allow the requested change',
      'The operation was cancelled.',
      r'${profile.name} (${profile.keyCount})',
    ]) {
      expect(writerSource, isNot(contains(legacyText)), reason: legacyText);
    }
  });
}
