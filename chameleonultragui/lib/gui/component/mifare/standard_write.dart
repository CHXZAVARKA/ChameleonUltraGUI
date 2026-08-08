import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/component/mifare/feature_strings.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class StandardMifareClassicWritePanel extends StatefulWidget {
  final ValueChanged<bool>? onBusyChanged;

  const StandardMifareClassicWritePanel({super.key, this.onBusyChanged});

  @override
  State<StandardMifareClassicWritePanel> createState() =>
      _StandardMifareClassicWritePanelState();
}

class _StandardMifareClassicWritePanelState
    extends State<StandardMifareClassicWritePanel> {
  Uint8List? _image;
  String? _imageName;
  MifareClassicGeometry? _geometry;
  String? _profileId;
  MifareClassicMaintenancePlan? _plan;
  MifareClassicMaintenance? _maintenance;
  MifareClassicMaintenanceReport? _report;
  MifareClassicMaintenanceProgress? _progress;
  bool _busy = false;
  bool _authorized = false;
  String? _error;
  bool _cancelled = false;

  List<MifareClassicKeyProfile> _profiles(ChameleonGUIState appState) {
    final profiles =
        appState.sharedPreferencesProvider.getMifareClassicKeyProfiles();
    final geometry = _geometry;
    if (geometry == null) {
      return profiles;
    }
    return profiles
        .where((profile) => profile.isCompatible(
              cardType: geometry.cardType,
              sectorCount: geometry.sectorCount,
            ))
        .toList();
  }

  void _invalidatePlan() {
    _plan = null;
    _maintenance = null;
    _report = null;
    _progress = null;
    _authorized = false;
    _error = null;
  }

  void _setBusy(bool value) {
    if (!mounted) {
      return;
    }
    setState(() => _busy = value);
    widget.onBusyChanged?.call(value);
  }

  String _safeMaintenanceError(Object error) {
    final localizations = AppLocalizations.of(context)!;
    if (error is MifareClassicMaintenanceException) {
      return MifareClassicFeatureStrings.of(context)
          .maintenanceFailure(error.failure, localizations);
    }
    return localizations.error;
  }

  void _logMaintenanceError(
    ChameleonGUIState appState,
    Object error,
    StackTrace stackTrace,
  ) {
    (appState.log ?? appState.communicator?.log)?.e(
      'MIFARE Classic maintenance failed',
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  void _selectImage(Uint8List image, String name) {
    setState(() {
      _invalidatePlan();
      final geometry = MifareClassicGeometry.fromImageSize(image.length);
      if (geometry == null) {
        _image = null;
        _imageName = null;
        _geometry = null;
        _profileId = null;
        _error =
            'Unsupported dump size: ${image.length} bytes. Expected 320, 1024, 1152, 2048, or 4096 bytes.';
        return;
      }
      _image = Uint8List.fromList(image);
      _imageName = name;
      _geometry = geometry;
      MifareClassicKeyProfile? selectedProfile;
      for (final profile in context
          .read<ChameleonGUIState>()
          .sharedPreferencesProvider
          .getMifareClassicKeyProfiles()) {
        if (profile.id == _profileId) {
          selectedProfile = profile;
          break;
        }
      }
      if (selectedProfile != null &&
          !selectedProfile.isCompatible(
            cardType: geometry.cardType,
            sectorCount: geometry.sectorCount,
          )) {
        _profileId = null;
      }
    });
  }

  Future<void> _pickBinaryDump() async {
    final appState = context.read<ChameleonGUIState>();
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['bin'],
      );
      if (picked == null) {
        return;
      }
      final bytes = Uint8List.fromList(
        await picked.readAsByteStream().expand((chunk) => chunk).toList(),
      );
      if (!mounted) {
        return;
      }
      _selectImage(bytes, picked.name);
    } catch (error, stackTrace) {
      _logMaintenanceError(appState, error, stackTrace);
      if (mounted) {
        setState(() => _error = _safeMaintenanceError(error));
      }
    }
  }

  Future<void> _pickSavedDump() async {
    final appState = context.read<ChameleonGUIState>();
    final strings = MifareClassicFeatureStrings.of(context);
    final cards = appState.sharedPreferencesProvider
        .getCards()
        .where((card) => card.extraData.mifareClassicDumpComplete != false)
        .where((card) => MifareClassicGeometry.fromSavedCardData(card) != null)
        .toList()
      ..sort((first, second) => first.name.compareTo(second.name));
    if (cards.isEmpty) {
      setState(() => _error = strings.noCompleteSavedCards);
      return;
    }

    await showSearch<String>(
      context: context,
      delegate: CardSearchDelegate(
        cards: cards,
        onTap: _selectSavedDump,
        filter: SearchFilter.hf,
      ),
    );
  }

  Future<void> _selectSavedDump(
    CardSave selected,
    void Function(BuildContext context, String result) closeSearch,
    AppLocalizations localizations,
  ) async {
    if (!mounted) {
      return;
    }
    final geometry = MifareClassicGeometry.fromSavedCardData(selected);
    if (geometry == null) {
      return;
    }

    if (selected.extraData.mifareClassicDumpComplete == null) {
      final strings = MifareClassicFeatureStrings.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(strings.legacySavedDumpTitle),
          content: Text(strings.legacySavedDumpDescription),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(localizations.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(strings.useLegacySavedDump),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }

      final appState = context.read<ChameleonGUIState>();
      final cards = appState.sharedPreferencesProvider.getCards();
      final index = cards.indexWhere((card) => card.id == selected.id);
      if (index >= 0) {
        cards[index].extraData.mifareClassicDumpComplete = true;
        appState.sharedPreferencesProvider.setCards(cards);
        appState.changesMade();
      }
    }

    _selectImage(
      mfClassicGetExportBytes(
        geometry.type,
        selected.data,
        isEV1: geometry.isEV1,
      ),
      selected.name,
    );
    closeSearch(context, selected.name);
  }

  Future<void> _runPreflight() async {
    final appState = context.read<ChameleonGUIState>();
    final communicator = appState.communicator;
    final profiles = _profiles(appState);
    MifareClassicKeyProfile? profile;
    for (final candidate in profiles) {
      if (candidate.id == _profileId) {
        profile = candidate;
        break;
      }
    }
    if (_image == null || profile == null || communicator == null) {
      return;
    }

    setState(_invalidatePlan);
    _setBusy(true);
    try {
      final maintenance = MifareClassicMaintenance(
        ChameleonMifareClassicMaintenancePort(communicator),
      );
      final plan = await appState.rfOperations.runForeground(() async {
        if (_cancelled) {
          return null;
        }
        return maintenance.preflight(
            image: _image!,
            profile: profile!,
            shouldCancel: () => _cancelled,
            onProgress: (progress) {
              if (mounted) {
                setState(() => _progress = progress);
              }
            });
      });
      if (plan == null) {
        return;
      }
      if (mounted) {
        setState(() {
          _maintenance = maintenance;
          _plan = plan;
        });
      }
    } catch (error, stackTrace) {
      _logMaintenanceError(appState, error, stackTrace);
      if (mounted) {
        setState(() => _error = _safeMaintenanceError(error));
      }
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _writeAndVerify() async {
    final plan = _plan;
    final maintenance = _maintenance;
    if (plan == null || maintenance == null || !_authorized) {
      return;
    }
    final appState = context.read<ChameleonGUIState>();

    setState(() {
      _error = null;
      _report = null;
    });
    _setBusy(true);
    try {
      final report = await appState.rfOperations.runForeground(() async {
        if (_cancelled) {
          return null;
        }
        return maintenance.execute(plan,
            shouldCancel: () => _cancelled,
            onProgress: (progress) {
              if (mounted) {
                setState(() => _progress = progress);
              }
            });
      });
      if (report == null) {
        return;
      }
      if (mounted) {
        setState(() {
          _report = report;
          _plan = null;
          _maintenance = null;
          _progress = null;
          _authorized = false;
        });
      }
    } catch (error, stackTrace) {
      _logMaintenanceError(appState, error, stackTrace);
      if (mounted) {
        setState(() {
          _error = _safeMaintenanceError(error);
          _plan = null;
          _maintenance = null;
          _progress = null;
          _authorized = false;
        });
      }
    } finally {
      _setBusy(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<ChameleonGUIState>();
    final strings = MifareClassicFeatureStrings.of(context);
    final profiles = _profiles(appState);
    final selectedProfileExists =
        profiles.any((profile) => profile.id == _profileId);
    final progress = _progress;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                strings.standardWriteTitle,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(strings.standardWriteDescription),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.shield_outlined, color: Colors.green),
                      const SizedBox(width: 12),
                      Expanded(child: Text(strings.safeBlocksNote)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickBinaryDump,
                    icon: const Icon(Icons.file_open),
                    label: Text(strings.selectBinDump),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickSavedDump,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: Text(strings.selectSavedDump),
                  ),
                ],
              ),
              if (_imageName != null) ...[
                const SizedBox(height: 8),
                Text(
                    '✓ $_imageName · ${_image!.length} bytes · ${_geometry!.label}'),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(_profileId),
                initialValue: selectedProfileExists ? _profileId : null,
                decoration: InputDecoration(
                  labelText: strings.selectKeyProfile,
                  border: const OutlineInputBorder(),
                ),
                items: profiles
                    .map((profile) => DropdownMenuItem(
                          value: profile.id,
                          child: Text(
                            '${profile.name} (${profile.keyCount})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: _busy
                    ? null
                    : (value) {
                        setState(() {
                          _invalidatePlan();
                          _profileId = value;
                        });
                      },
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: !_busy &&
                        _image != null &&
                        selectedProfileExists &&
                        appState.communicator != null
                    ? _runPreflight
                    : null,
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(strings.runPreflight),
              ),
              if (_busy && progress != null) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: progress.total == 0
                      ? null
                      : progress.completed / progress.total,
                ),
                const SizedBox(height: 8),
                Text(
                  progress.phase == MifareClassicMaintenancePhase.preflight
                      ? strings.preflightRunning
                      : strings.keepCardStable,
                ),
              ],
              if (_plan != null && !_busy) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(strings.preflightReady(
                        _plan!.changedBlocks, _plan!.unchangedBlocks)),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _authorized,
                  onChanged: (value) =>
                      setState(() => _authorized = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(strings.authorizedCardConfirmation),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: _authorized ? _writeAndVerify : null,
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(strings.writeAndVerify),
                ),
              ],
              if (_report != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: Colors.green.withValues(alpha: 0.15),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(strings.writeComplete(_report!.verifiedBlocks)),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('${strings.operationFailed}: $_error'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
