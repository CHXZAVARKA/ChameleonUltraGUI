import 'package:flutter/widgets.dart';

/// English source strings for this feature branch.
///
/// Upstream translations must be added through the project's Crowdin flow;
/// generated `app_*.arb` files are intentionally not changed here.
class MifareClassicFeatureStrings {
  const MifareClassicFeatureStrings._();

  factory MifareClassicFeatureStrings.of(BuildContext context) =>
      const MifareClassicFeatureStrings._();

  String get assignedKeyProfile => 'Assigned key profile';
  String get assignedKeyProfiles => 'Assigned key profiles';
  String get importKeyProfile => 'Import key profile';
  String get exportKeyProfile => 'Export key profile';
  String get deleteKeyProfile => 'Delete key profile';
  String get keyASectors => 'Key A sectors';
  String get keyBSectors => 'Key B sectors';
  String get noAssignedSectors => 'None';
  String get saveKeyProfile => 'Save assigned key profile';
  String get saveKeyProfileInApp => 'Save in app';
  String get exportKeyProfileToFile => 'Export to JSON file';
  String get enterKeyProfileName => 'Enter key profile name';
  String get keyProfileSaved => 'Key profile saved';
  String get keyProfileImported => 'Key profile imported';
  String get keyProfileImportFailed => 'Could not import key profile';
  String get keyProfileUidMismatch => 'Key profile UID differs';
  String get keyProfileUidMismatchDescription =>
      'This profile was saved for another UID. Use it only if both cards '
      'intentionally share the same sector keys.';
  String get useKeyProfile => 'Use profile';
  String get keyProfilePlaintextWarning =>
      'The profile stores sector keys as plain text. Keep exported files private.';
  String get partialBinExportBlocked =>
      'BIN export requires a complete MIFARE Classic dump. '
      'Save this partial recovery in the app instead.';

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
}
