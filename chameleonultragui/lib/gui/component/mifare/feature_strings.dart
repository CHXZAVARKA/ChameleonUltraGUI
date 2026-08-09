import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance.dart';
import 'package:flutter/widgets.dart';

/// English source strings for this feature branch.
///
/// Upstream translations must be added through the project's Crowdin flow;
/// generated `app_*.arb` files are intentionally not changed here.
class MifareClassicFeatureStrings {
  const MifareClassicFeatureStrings._();

  factory MifareClassicFeatureStrings.of(BuildContext context) =>
      const MifareClassicFeatureStrings._();

  String get magicCardMode => 'Magic card';
  String get standardCardMode => 'Standard MIFARE Classic';
  String get standardWriteTitle =>
      "Write the card's own dump to a standard card";
  String get standardWriteDescription =>
      'Select a complete Mini, 1K, 1K EV1, 2K, or 4K dump and its assigned '
      'key profile.';
  String get safeBlocksNote =>
      'Only data blocks are written. Block 0, keys, and access bits are left unchanged.';
  String get selectBinDump => 'Select .bin dump';
  String get selectSavedDump => 'Select saved card';
  String get noCompleteSavedCards => 'No usable saved MIFARE Classic dumps';
  String get legacySavedDumpTitle => 'Unverified legacy dump';
  String get legacySavedDumpDescription =>
      'This saved card predates completeness tracking. Its block structure is '
      'valid, but the app cannot prove that every block was read successfully. '
      'Continue only if this is a complete dump; missing reads may contain zeros.';
  String get useLegacySavedDump => 'Use saved dump';
  String get selectKeyProfile => 'Select key profile';
  String get runPreflight => 'Run preflight';
  String get preflightRunning =>
      'Preflight is running. Nothing is written until it completes.';
  String preflightReady(int changed, int unchanged) =>
      'Preflight passed: $changed blocks will change and $unchanged already match.';
  String get authorizedCardConfirmation =>
      'I confirm this is my card and I am authorized to change its data.';
  String get writeAndVerify => 'Write and verify';
  String get keepCardStable => 'Keep the card and Chameleon Ultra still.';
  String writeComplete(int count) =>
      'Complete: $count blocks written and verified.';
  String get operationFailed => 'Operation stopped';

  /// Localization gate: maintenance-specific reasons must be added through
  /// Crowdin before this feature can be considered fully localized.
  String maintenanceFailure(
    MifareClassicMaintenanceFailure failure,
    AppLocalizations localizations,
  ) {
    return switch (failure) {
      MifareClassicMaintenanceFailure.invalidImage =>
        'The selected dump is not supported.',
      MifareClassicMaintenanceFailure.incompatibleProfile =>
        'The selected key profile is not compatible with this dump.',
      MifareClassicMaintenanceFailure.communicationLost =>
        'Communication with Chameleon was lost. Reconnect and try again.',
      MifareClassicMaintenanceFailure.stalePlan =>
        'The card check expired. Run preflight again.',
      MifareClassicMaintenanceFailure.noCard => localizations.no_card_found,
      MifareClassicMaintenanceFailure.wrongCardType ||
      MifareClassicMaintenanceFailure.identityMismatch =>
        'The presented card does not match the selected dump.',
      MifareClassicMaintenanceFailure.authenticationFailed =>
        'The selected key profile could not authenticate this card.',
      MifareClassicMaintenanceFailure.readFailed =>
        localizations.recovery_error_dump_data,
      MifareClassicMaintenanceFailure.invalidAccessBits ||
      MifareClassicMaintenanceFailure.writeNotAllowed ||
      MifareClassicMaintenanceFailure.verificationNotAllowed =>
        'This card does not allow the requested change with the selected key profile.',
      MifareClassicMaintenanceFailure.writeFailed ||
      MifareClassicMaintenanceFailure.verificationFailed =>
        localizations.magic_failed_write,
      MifareClassicMaintenanceFailure.cancelled =>
        'The operation was cancelled.',
    };
  }
}
