import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/element_button.dart';
import 'package:chameleonultragui/gui/component/mifare/feature_strings.dart';
import 'package:chameleonultragui/gui/component/mifare/key_profile_file.dart';
import 'package:chameleonultragui/gui/menu/dialogs/confirm_delete.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/main.dart';
import 'package:file_picker/file_picker.dart';
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
    final strings = MifareClassicFeatureStrings.of(context);
    try {
      final profile = await pickProfile();
      if (profile == null) {
        return;
      }
      appState.sharedPreferencesProvider.upsertMifareClassicKeyProfile(profile);
      appState.changesMade();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.keyProfileImported)),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${strings.keyProfileImportFailed}: $error')),
        );
      }
    }
  }

  Future<void> _exportProfile(
      BuildContext context, MifareClassicKeyProfile profile) async {
    final localizations = AppLocalizations.of(context)!;
    final safeName = profile.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
    await FilePicker.saveFile(
      dialogTitle: '${localizations.output_file}:',
      fileName: '$safeName.mf1keys.json',
      bytes: profile.toFile(),
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

  String _description(MifareClassicKeyProfile profile) {
    MifareClassicType? type;
    for (final candidate in MifareClassicType.values) {
      if (candidate.name == profile.cardType) {
        type = candidate;
        break;
      }
    }
    final geometry = type == null
        ? null
        : MifareClassicGeometry.fromType(
            type,
            isEV1: type == MifareClassicType.m1k && profile.sectorCount == 18,
          );
    final cardLabel = geometry?.label ?? profile.cardType;
    final uid = profile.uid == null ? '' : ' · UID ${profile.uid}';
    return '$cardLabel · ${profile.keyCount} keys$uid';
  }

  String _sectors(List<int> sectors, MifareClassicFeatureStrings strings) =>
      sectors.isEmpty ? strings.noAssignedSectors : sectors.join(', ');

  Future<void> _inspectProfile(
      BuildContext context, MifareClassicKeyProfile profile) {
    final localizations = AppLocalizations.of(context)!;
    final strings = MifareClassicFeatureStrings.of(context);
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
                Text(_description(profile)),
                const SizedBox(height: 12),
                Text(strings.keyProfilePlaintextWarning),
                const Divider(height: 32),
                for (final usage in profile.keyUsages) ...[
                  SelectableText(
                    usage.keyHex,
                    style: const TextStyle(fontFamily: 'RobotoMono'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${strings.keyASectors}: '
                    '${_sectors(usage.keyASectors, strings)}',
                  ),
                  Text(
                    '${strings.keyBSectors}: '
                    '${_sectors(usage.keyBSectors, strings)}',
                  ),
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
    final strings = MifareClassicFeatureStrings.of(context);
    final title = Text(
      strings.assignedKeyProfiles,
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
                  tooltip: strings.importKeyProfile,
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
    final strings = MifareClassicFeatureStrings.of(context);
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
                  label: Text(strings.importKeyProfile),
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
                    secondLine: _description(profile),
                    itemIndex: index,
                    onPressed: () => _inspectProfile(context, profile),
                    children: [
                      IconButton(
                        onPressed: () => _exportProfile(context, profile),
                        tooltip: strings.exportKeyProfile,
                        icon: const Icon(Icons.download),
                      ),
                      IconButton(
                        onPressed: () => _deleteProfile(context, profile),
                        tooltip: strings.deleteKeyProfile,
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
