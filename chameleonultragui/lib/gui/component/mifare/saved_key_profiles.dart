import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/element_button.dart';
import 'package:chameleonultragui/gui/component/mifare/key_profile_file.dart';
import 'package:chameleonultragui/gui/menu/dialogs/confirm_delete.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:provider/provider.dart';

class MifareClassicKeyProfilesCard extends StatelessWidget {
  final Future<MifareClassicKeyProfile?> Function() pickProfile;

  const MifareClassicKeyProfilesCard({
    super.key,
    this.pickProfile = pickMifareClassicKeyProfileFile,
  });

  Future<void> _importProfile(BuildContext context) async {
    final appState = context.read<ChameleonGUIState>();
    final localizations = AppLocalizations.of(context)!;
    try {
      final profile = await pickProfile();
      if (profile == null) {
        return;
      }
      appState.sharedPreferencesProvider.upsertMifareClassicKeyProfile(profile);
      appState.changesMade();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizations.mifare_classic_key_profile_imported),
          ),
        );
      }
    } catch (error, stackTrace) {
      (appState.log ?? appState.communicator?.log)?.e(
        'Failed to import MIFARE Classic key profile',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(localizations.mifare_classic_key_profile_import_failed),
          ),
        );
      }
    }
  }

  Future<void> _exportProfile(
      BuildContext context, MifareClassicKeyProfile profile) async {
    final localizations = AppLocalizations.of(context)!;
    await exportMifareClassicKeyProfileFile(
      profile,
      dialogTitle: '${localizations.output_file}:',
    );
  }

  Future<void> _deleteProfile(
      BuildContext context, MifareClassicKeyProfile profile) async {
    final appState = context.read<ChameleonGUIState>();
    if (appState.sharedPreferencesProvider.getConfirmDelete()) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) =>
            ConfirmDeletionMenu(thingBeingDeleted: profile.name),
      );
      if (confirmed != true) {
        return;
      }
    }
    final profiles = appState.sharedPreferencesProvider
        .getMifareClassicKeyProfiles()
        .where((candidate) => candidate.id != profile.id)
        .toList();
    appState.sharedPreferencesProvider.setMifareClassicKeyProfiles(profiles);
    appState.changesMade();
  }

  String _description(
    AppLocalizations localizations,
    MifareClassicKeyProfile profile,
  ) {
    final cardLabel = profile.geometry?.label ?? profile.cardType;
    final uid = profile.uid;
    return uid == null
        ? localizations.mifare_classic_key_profile_summary(
            cardLabel,
            profile.keyCount,
          )
        : localizations.mifare_classic_key_profile_summary_with_uid(
            cardLabel,
            profile.keyCount,
            uid,
          );
  }

  String _sectors(List<int> sectors, AppLocalizations localizations) =>
      sectors.isEmpty ? localizations.none : sectors.join(', ');

  Future<void> _inspectProfile(
      BuildContext context, MifareClassicKeyProfile profile) {
    final localizations = AppLocalizations.of(context)!;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(profile.name),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_description(localizations, profile)),
                const SizedBox(height: 12),
                Text(
                  localizations.mifare_classic_key_profile_plaintext_warning,
                ),
                const Divider(height: 32),
                for (final usage in profile.keyUsages) ...[
                  SelectableText(
                    usage.keyHex,
                    style: const TextStyle(fontFamily: 'RobotoMono'),
                  ),
                  const SizedBox(height: 4),
                  Text(localizations.mifare_classic_key_a_sectors(
                    _sectors(usage.keyASectors, localizations),
                  )),
                  Text(localizations.mifare_classic_key_b_sectors(
                    _sectors(usage.keyBSectors, localizations),
                  )),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(localizations.close),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, bool isCompact) {
    final localizations = AppLocalizations.of(context)!;
    final title = Text(
      localizations.mifare_classic_assigned_key_profiles,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: isCompact
          ? Row(
              children: [
                const SizedBox(width: 48),
                Expanded(child: title),
                IconButton(
                  onPressed: () => _importProfile(context),
                  tooltip: localizations.mifare_classic_import_key_profile,
                  icon: const Icon(Icons.file_upload),
                ),
              ],
            )
          : title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<ChameleonGUIState>();
    final localizations = AppLocalizations.of(context)!;
    final profiles = appState.sharedPreferencesProvider
        .getMifareClassicKeyProfiles()
      ..sort((first, second) => first.name.compareTo(second.name));
    final isCompact = MediaQuery.of(context).size.width < 700;

    return Card(
      child: Column(
        children: [
          _header(context, isCompact),
          Visibility(
            visible: !isCompact,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _importProfile(context),
                  style: customCardButtonStyle(appState),
                  icon: const Icon(Icons.file_upload),
                  label: Text(localizations.mifare_classic_import_key_profile),
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: AlignedGridView.count(
                clipBehavior: Clip.antiAlias,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(10),
                crossAxisCount:
                    MediaQuery.of(context).size.width >= 700 ? 2 : 1,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                itemCount: profiles.length,
                shrinkWrap: true,
                itemBuilder: (context, index) {
                  final profile = profiles[index];
                  return ElementButton(
                    icon: Icons.vpn_key_outlined,
                    iconColor: Colors.deepOrange,
                    firstLine: profile.name,
                    secondLine: _description(localizations, profile),
                    itemIndex: index,
                    onPressed: () => _inspectProfile(context, profile),
                    children: [
                      IconButton(
                        onPressed: () => _exportProfile(context, profile),
                        tooltip:
                            localizations.mifare_classic_export_key_profile,
                        icon: const Icon(Icons.download),
                      ),
                      IconButton(
                        onPressed: () => _deleteProfile(context, profile),
                        tooltip:
                            localizations.mifare_classic_delete_key_profile,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
