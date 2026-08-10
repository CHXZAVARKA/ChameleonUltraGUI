import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:flutter/widgets.dart';

List<LocalizationsDelegate<dynamic>> mifareClassicTestLocalizationsDelegates(
  AppLocalizations localizations,
) =>
    [
      _MifareClassicTestLocalizationsDelegate(localizations),
      ...AppLocalizations.localizationsDelegates,
    ];

class _MifareClassicTestLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _MifareClassicTestLocalizationsDelegate(this.localizations);

  final AppLocalizations localizations;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) => Future.value(localizations);

  @override
  bool shouldReload(_MifareClassicTestLocalizationsDelegate old) => false;
}
