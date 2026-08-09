import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
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
  ConnectedDeviceSession? _maintenanceSession;
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

  void _discardPlan() {
    _plan = null;
    _maintenance = null;
    _maintenanceSession = null;
    _progress = null;
    _authorized = false;
  }

  void _invalidatePlan() {
    _discardPlan();
    _report = null;
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
      final reason = switch (error.failure) {
        MifareClassicMaintenanceFailure.invalidImage =>
          localizations.mifare_classic_maintenance_invalid_image,
        MifareClassicMaintenanceFailure.incompatibleProfile =>
          localizations.mifare_classic_maintenance_incompatible_profile,
        MifareClassicMaintenanceFailure.communicationLost =>
          localizations.mifare_classic_maintenance_communication_lost,
        MifareClassicMaintenanceFailure.stalePlan =>
          localizations.mifare_classic_maintenance_stale_plan,
        MifareClassicMaintenanceFailure.noCard => localizations.no_card_found,
        MifareClassicMaintenanceFailure.wrongCardType ||
        MifareClassicMaintenanceFailure.identityMismatch =>
          localizations.mifare_classic_maintenance_card_mismatch,
        MifareClassicMaintenanceFailure.authenticationFailed =>
          localizations.mifare_classic_maintenance_authentication_failed,
        MifareClassicMaintenanceFailure.readFailed =>
          localizations.recovery_error_dump_data,
        MifareClassicMaintenanceFailure.invalidAccessBits ||
        MifareClassicMaintenanceFailure.writeNotAllowed ||
        MifareClassicMaintenanceFailure.verificationNotAllowed =>
          localizations.mifare_classic_maintenance_change_not_allowed,
        MifareClassicMaintenanceFailure.writeFailed ||
        MifareClassicMaintenanceFailure.verificationFailed =>
          localizations.magic_failed_write,
        MifareClassicMaintenanceFailure.cancelled =>
          localizations.mifare_classic_maintenance_cancelled,
      };
      return [
        reason,
        if (error.verifiedBlocks > 0 ||
            error.writeOutcome == MifareClassicWriteOutcome.unknown)
          localizations.mifare_classic_standard_verified_before_stop(
            error.verifiedBlocks,
          ),
        if (error.writeOutcome == MifareClassicWriteOutcome.unknown)
          localizations.mifare_classic_standard_unknown_write_outcome,
      ].join(' ');
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
    final localizations = AppLocalizations.of(context)!;
    setState(() {
      _invalidatePlan();
      final geometry = MifareClassicGeometry.fromImageSize(image.length);
      if (geometry == null) {
        _image = null;
        _imageName = null;
        _geometry = null;
        _profileId = null;
        _error = localizations
            .mifare_classic_standard_unsupported_dump_size(image.length);
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
    final localizations = AppLocalizations.of(context)!;
    final cards = appState.sharedPreferencesProvider
        .getCards()
        .where((card) => card.extraData.mifareClassicDumpComplete != false)
        .where((card) => MifareClassicGeometry.fromSavedCardData(card) != null)
        .toList()
      ..sort((first, second) => first.name.compareTo(second.name));
    if (cards.isEmpty) {
      setState(() =>
          _error = localizations.mifare_classic_standard_no_usable_saved_dumps);
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
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            localizations.mifare_classic_standard_legacy_dump_title,
          ),
          content: Text(
            localizations.mifare_classic_standard_legacy_dump_description,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(localizations.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                localizations.mifare_classic_standard_use_legacy_dump,
              ),
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
    final profiles = _profiles(appState);
    MifareClassicKeyProfile? profile;
    for (final candidate in profiles) {
      if (candidate.id == _profileId) {
        profile = candidate;
        break;
      }
    }
    final image = _image;
    if (image == null || profile == null) {
      return;
    }
    final selectedProfile = profile;

    setState(_invalidatePlan);
    _setBusy(true);
    try {
      final result = await appState.runSessionBoundForeground((session) async {
        if (_cancelled) {
          return null;
        }
        final maintenance = MifareClassicMaintenance(
          ChameleonMifareClassicMaintenancePort(session.communicator),
        );
        final plan = await maintenance.preflight(
            image: image,
            profile: selectedProfile,
            shouldCancel: () => _cancelled || !session.isCurrent,
            onProgress: (progress) {
              if (mounted) {
                setState(() => _progress = progress);
              }
            });
        return (maintenance: maintenance, plan: plan);
      });
      final value = result.value;
      if (!result.executed || value == null) {
        return;
      }
      if (mounted) {
        setState(() {
          _maintenance = value.maintenance;
          _maintenanceSession = result.session;
          _plan = value.plan;
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
    final maintenanceSession = _maintenanceSession;
    if (plan == null ||
        maintenance == null ||
        maintenanceSession == null ||
        !_authorized) {
      return;
    }
    final appState = context.read<ChameleonGUIState>();

    setState(() {
      _error = null;
      _report = null;
    });
    _setBusy(true);
    try {
      final result = await appState.runSessionBoundForeground((session) async {
        if (_cancelled ||
            !identical(session.connector, maintenanceSession.connector) ||
            !identical(session.communicator, maintenanceSession.communicator)) {
          return null;
        }
        return maintenance.execute(plan,
            shouldCancel: () => _cancelled,
            isSessionCurrent: () => session.isCurrent,
            onProgress: (progress) {
              if (mounted) {
                setState(() => _progress = progress);
              }
            });
      });
      final report = result.value;
      if (!result.executed || report == null) {
        if (mounted) {
          setState(() {
            _discardPlan();
            _error = _safeMaintenanceError(
              const MifareClassicMaintenanceException(
                MifareClassicMaintenanceFailure.stalePlan,
                'The connected device session changed before execution',
              ),
            );
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _report = report;
          _discardPlan();
        });
      }
    } catch (error, stackTrace) {
      _logMaintenanceError(appState, error, stackTrace);
      if (mounted) {
        setState(() {
          _error = _safeMaintenanceError(error);
          _discardPlan();
        });
      }
    } finally {
      _setBusy(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<ChameleonGUIState>();
    final localizations = AppLocalizations.of(context)!;
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
                localizations.mifare_classic_standard_write_title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(localizations.mifare_classic_standard_write_description),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.shield_outlined, color: Colors.green),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          localizations
                              .mifare_classic_standard_safe_blocks_note,
                        ),
                      ),
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
                    label: Text(
                      localizations.mifare_classic_standard_select_bin_dump,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickSavedDump,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: Text(localizations.select_saved_card),
                  ),
                ],
              ),
              if (_imageName != null) ...[
                const SizedBox(height: 8),
                Text(
                    localizations.mifare_classic_standard_selected_dump_summary(
                  _imageName!,
                  _image!.length,
                  _geometry!.label,
                )),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(_profileId),
                initialValue: selectedProfileExists ? _profileId : null,
                decoration: InputDecoration(
                  labelText:
                      localizations.mifare_classic_standard_select_key_profile,
                  border: const OutlineInputBorder(),
                ),
                items: profiles
                    .map((profile) => DropdownMenuItem(
                          value: profile.id,
                          child: Text(
                            localizations.mifare_classic_key_profile_option(
                              profile.name,
                              profile.keyCount,
                            ),
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
                label: Text(
                  localizations.mifare_classic_standard_run_preflight,
                ),
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
                      ? localizations.mifare_classic_standard_preflight_running
                      : localizations.mifare_classic_standard_keep_card_stable,
                ),
              ],
              if (_plan != null && !_busy) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      localizations.mifare_classic_standard_preflight_ready(
                        _plan!.changedBlocks,
                        _plan!.unchangedBlocks,
                      ),
                    ),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _authorized,
                  onChanged: (value) =>
                      setState(() => _authorized = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    localizations
                        .mifare_classic_standard_authorized_confirmation,
                  ),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: _authorized ? _writeAndVerify : null,
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(
                    localizations.mifare_classic_standard_write_and_verify,
                  ),
                ),
              ],
              if (_report != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: Colors.green.withValues(alpha: 0.15),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      localizations
                          .mifare_classic_standard_write_complete_summary(
                        _report!.verifiedBlocks,
                        _report!.unchangedBlocks,
                      ),
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      localizations.mifare_classic_standard_operation_failed(
                        _error!,
                      ),
                    ),
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
