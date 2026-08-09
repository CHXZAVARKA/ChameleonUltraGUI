import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/import_image.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class StandardMifareClassicWritePanel extends StatefulWidget {
  const StandardMifareClassicWritePanel({super.key});

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
  MifareClassicMaintenanceReport? _report;
  MifareClassicMaintenanceProgress? _progress;
  bool _busy = false;
  String? _error;
  bool _stopRequested = false;

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

  void _clearProgress() {
    _progress = null;
  }

  void _invalidatePlan() {
    _clearProgress();
    _report = null;
    _error = null;
  }

  void _setBusy(bool value) {
    if (!mounted) {
      return;
    }
    setState(() => _busy = value);
  }

  void _publishActivity(
    ChameleonGUIState appState,
    ConnectedDeviceSession session,
    MifareClassicMaintenanceProgress progress, {
    StandardWriteActivityState state = StandardWriteActivityState.active,
    String? outcome,
  }) {
    appState.publishStandardWriteActivity(
      connector: session.connector,
      communicator: session.communicator,
      activity: StandardWriteActivity(
        state: state,
        phase: progress.phase,
        completed: progress.completed,
        total: progress.total,
        outcome: outcome,
      ),
    );
  }

  void _updateProgress(
    ChameleonGUIState appState,
    ConnectedDeviceSession session,
    MifareClassicMaintenanceProgress progress,
  ) {
    if (mounted) {
      setState(() => _progress = progress);
    }
    _publishActivity(appState, session, progress);
  }

  void _stop() {
    if (!_busy || _stopRequested) {
      return;
    }
    setState(() => _stopRequested = true);
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
    if (error is FormatException) {
      return localizations.mifare_classic_maintenance_invalid_image;
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
    _stopRequested = true;
    super.dispose();
  }

  void _selectImage(
    Uint8List image,
    String name, {
    MifareClassicGeometry? geometry,
  }) {
    final localizations = AppLocalizations.of(context)!;
    setState(() {
      _invalidatePlan();
      final selectedGeometry =
          geometry ?? MifareClassicGeometry.fromImageSize(image.length);
      if (selectedGeometry == null ||
          selectedGeometry.imageSize != image.length) {
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
      _geometry = selectedGeometry;
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
            cardType: selectedGeometry.cardType,
            sectorCount: selectedGeometry.sectorCount,
          )) {
        _profileId = null;
      }
    });
  }

  void _clearImage() {
    setState(() {
      _invalidatePlan();
      _image = null;
      _imageName = null;
      _geometry = null;
    });
  }

  Future<void> _pickDumpFile() async {
    final appState = context.read<ChameleonGUIState>();
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null) {
        return;
      }
      if (!mounted) {
        return;
      }
      _clearImage();
      final contents = Uint8List.fromList(
        await picked.readAsByteStream().expand((chunk) => chunk).toList(),
      );
      if (!mounted) {
        return;
      }
      final imported = importMifareClassicImage(contents);
      _selectImage(
        imported.bytes,
        picked.name,
        geometry: imported.geometry,
      );
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
        .where((card) => card.extraData.mifareClassicDumpComplete == true)
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

  void _selectSavedDump(
    CardSave selected,
    void Function(BuildContext context, String result) closeSearch,
    AppLocalizations _,
  ) {
    if (!mounted) {
      return;
    }
    final geometry = MifareClassicGeometry.fromSavedCardData(selected);
    if (geometry == null) {
      return;
    }

    _selectImage(
      mfClassicGetExportBytes(
        geometry.type,
        selected.data,
        isEV1: geometry.isEV1,
      ),
      selected.name,
      geometry: geometry,
    );
    closeSearch(context, selected.name);
  }

  Future<void> _start() async {
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
    final operationSession = ConnectedDeviceSession.capture(appState);
    if (operationSession == null) {
      return;
    }
    final initialProgress = MifareClassicMaintenanceProgress(
      phase: MifareClassicMaintenancePhase.preflight,
      completed: 0,
      total: _geometry?.sectorCount ?? 1,
    );

    setState(() {
      _invalidatePlan();
      _stopRequested = false;
      _progress = initialProgress;
    });
    _setBusy(true);
    _publishActivity(appState, operationSession, initialProgress);
    final wakelockOwner = appState.acquireSessionWakelock(
      connector: operationSession.connector,
      communicator: operationSession.communicator,
    );
    try {
      final result = await appState.runSessionBoundForeground((session) async {
        if (_stopRequested ||
            !identical(session.connector, operationSession.connector) ||
            !identical(
              session.communicator,
              operationSession.communicator,
            )) {
          return null;
        }
        final maintenance = MifareClassicMaintenance(
          ChameleonMifareClassicMaintenancePort(session.communicator),
        );
        final plan = await maintenance.preflight(
            image: image,
            profile: selectedProfile,
            shouldCancel: () => _stopRequested || !session.isCurrent,
            onProgress: (progress) =>
                _updateProgress(appState, session, progress));
        return maintenance.execute(
          plan,
          shouldCancel: () => _stopRequested,
          isSessionCurrent: () => session.isCurrent,
          onProgress: (progress) =>
              _updateProgress(appState, session, progress),
        );
      });
      final report = result.value;
      if (!result.executed || report == null) {
        if (mounted) {
          final error = _safeMaintenanceError(
            const MifareClassicMaintenanceException(
              MifareClassicMaintenanceFailure.stalePlan,
              'The connected device session changed before execution',
            ),
          );
          final progress = _progress ?? initialProgress;
          setState(() {
            _clearProgress();
            _error = error;
          });
          _publishActivity(
            appState,
            operationSession,
            progress,
            state: StandardWriteActivityState.failed,
            outcome: error,
          );
        }
        return;
      }
      if (mounted) {
        final progress = _progress ?? initialProgress;
        final outcome = AppLocalizations.of(context)!
            .mifare_classic_standard_write_complete_summary(
          report.verifiedBlocks,
          report.unchangedBlocks,
        );
        setState(() {
          _report = report;
          _clearProgress();
        });
        _publishActivity(
          appState,
          operationSession,
          progress,
          state: StandardWriteActivityState.succeeded,
          outcome: outcome,
        );
      }
    } catch (error, stackTrace) {
      _logMaintenanceError(appState, error, stackTrace);
      if (mounted) {
        final safeError = _safeMaintenanceError(error);
        final progress = _progress ?? initialProgress;
        setState(() {
          _error = safeError;
          _clearProgress();
        });
        _publishActivity(
          appState,
          operationSession,
          progress,
          state: error is MifareClassicMaintenanceException &&
                  error.failure == MifareClassicMaintenanceFailure.cancelled
              ? StandardWriteActivityState.cancelled
              : StandardWriteActivityState.failed,
          outcome: safeError,
        );
      }
    } finally {
      appState.releaseSessionWakelock(wakelockOwner);
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
    final progressPhase = switch (progress?.phase) {
      MifareClassicMaintenancePhase.preflight =>
        localizations.mifare_classic_standard_phase_preflight,
      MifareClassicMaintenancePhase.revalidating =>
        localizations.mifare_classic_standard_phase_revalidating,
      MifareClassicMaintenancePhase.writing =>
        localizations.mifare_classic_standard_phase_writing,
      MifareClassicMaintenancePhase.verifying =>
        localizations.mifare_classic_standard_phase_verifying,
      null => '',
    };

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
              LayoutBuilder(
                builder: (context, constraints) {
                  final loadFile = OutlinedButton.icon(
                    onPressed: _busy ? null : _pickDumpFile,
                    icon: const Icon(Icons.file_open),
                    label: Text(
                      localizations.mifare_classic_standard_load_file,
                    ),
                  );
                  final selectSavedCard = OutlinedButton.icon(
                    onPressed: _busy ? null : _pickSavedDump,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: Text(localizations.select_saved_card),
                  );
                  final separator = Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      localizations.mifare_classic_standard_or,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  );
                  if (constraints.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [loadFile, separator, selectSavedCard],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: loadFile),
                      separator,
                      Expanded(child: selectSavedCard),
                    ],
                  );
                },
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
                    ? _start
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  localizations.mifare_classic_standard_start,
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
                  localizations.mifare_classic_standard_progress(
                    progressPhase,
                    progress.completed,
                    progress.total,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _stopRequested ? null : _stop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(localizations.cancel),
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
