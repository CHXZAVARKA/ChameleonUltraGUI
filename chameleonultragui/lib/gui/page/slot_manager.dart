import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/full_device_backup.dart';
import 'package:chameleonultragui/helpers/full_device_backup_workflow.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/slot_payload.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:provider/provider.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class SlotManagerPage extends StatefulWidget {
  const SlotManagerPage({super.key});

  @override
  SlotManagerPageState createState() => SlotManagerPageState();
}

class SlotManagerPageState extends State<SlotManagerPage> {
  int progress = -1;
  int gridPosition = 0;
  bool onlyOneSlot = false;
  bool _backupBusy = false;
  FullDeviceBackupProgress? _backupProgress;
  ConnectedDeviceStatus? _status;
  StatusPresence? _presence;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextStatus =
        Provider.of<ChameleonGUIState>(context).connectedDeviceStatus;
    if (identical(nextStatus, _status)) {
      return;
    }
    _presence?.dispose();
    _status = nextStatus;
    _presence = nextStatus?.present(StatusSurface.slotManager);
  }

  @override
  void dispose() {
    _presence?.dispose();
    super.dispose();
  }

  void setUploadState(int progressBar) {
    if (!mounted) {
      return;
    }
    setState(() {
      progress = progressBar;
    });
  }

  Future<void> onTap(
      CardSave card, dynamic close, AppLocalizations localizations) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    final status = _status;
    if (status == null) {
      return;
    }
    final supported = SlotPayloadWriter.supports(card.tag);
    close(context, card.name);
    if (!supported) {
      appState.log!.e("Can't write this card type yet.");
      return;
    }

    try {
      await status.mutateSlots((mutation) async {
        await mutation.run(
          (communicator) => communicator.setReaderDeviceMode(false),
        );
        await SlotPayloadWriter.writeCard(
          runner: mutation,
          position: gridPosition,
          card: card,
          enabled: true,
          name: card.name.isEmpty ? localizations.no_name : card.name,
          targetType: isEM410X(card.tag)
              ? (card.tag == TagType.em410XElectra
                  ? TagType.em410XElectra
                  : TagType.em410X)
              : null,
          activateAfterEnable: true,
          onProgress: setUploadState,
        );
        await mutation.run((communicator) => communicator.saveSlotData());
      }, reconcileMode: true);
    } on SlotMutationConnectionChanged {
      return;
    } finally {
      setUploadState(-1);
    }
  }

  Future<String?> cardSelectDialog(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();
    var tags = appState.sharedPreferencesProvider.getCards();

    // Don't allow user to upload more tags while already uploading dump
    if (progress != -1 || _backupBusy) {
      return Future.value("");
    }

    tags.sort((a, b) => a.name.compareTo(b.name));

    return showSearch<String>(
      context: context,
      delegate: CardSearchDelegate(cards: tags, onTap: onTap),
    );
  }

  Future<void> _backupAllSlots(
    ChameleonGUIState appState,
    ConnectedDeviceStatus status,
    AppLocalizations localizations,
  ) async {
    if (_backupBusy || progress != -1) {
      return;
    }
    setState(() {
      _backupBusy = true;
      _backupProgress = const FullDeviceBackupProgress(
        currentPosition: 0,
        positions: [],
      );
    });
    final outcome = await appState.fullDeviceBackupWorkflow.export(
      status: status,
      onProgress: (progress) {
        if (!mounted) {
          return;
        }
        setState(() => _backupProgress = progress);
      },
      approve: (backup) {
        if (mounted) {
          setState(() => _backupProgress = null);
        }
        return _showBackupReport(backup, localizations);
      },
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _backupBusy = false;
      _backupProgress = null;
    });
    final message = switch (outcome) {
      FullDeviceBackupExportOutcome.saved => localizations.device_backup_saved,
      FullDeviceBackupExportOutcome.cancelled ||
      FullDeviceBackupExportOutcome.declined =>
        null,
      FullDeviceBackupExportOutcome.writeFailed =>
        localizations.device_backup_write_failed,
      FullDeviceBackupExportOutcome.connectionChanged =>
        localizations.device_backup_connection_changed,
      FullDeviceBackupExportOutcome.unavailable ||
      FullDeviceBackupExportOutcome.captureFailed =>
        localizations.device_backup_failed,
    };
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<bool> _showBackupReport(
    FullDeviceBackup backup,
    AppLocalizations localizations,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(localizations.device_backup_report),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  localizations.device_backup_confirmed_context(
                    backup.activeSlot + 1,
                    _modeLabel(backup.mode, localizations),
                  ),
                ),
                if (backup.hasLimitations) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      localizations.device_backup_partial_warning,
                      key: const Key('device-backup-partial-warning'),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                ...backup.positions.map(
                  (position) => Semantics(
                    label: localizations.device_backup_position_semantics(
                      position.slot.sourcePosition + 1,
                      _captureStateLabel(position.state, localizations),
                      _captureStateLabel(position.hfState, localizations),
                      _captureStateLabel(position.lfState, localizations),
                    ),
                    child: ListTile(
                      key: Key(
                        'device-backup-report-position-${position.slot.sourcePosition}',
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        localizations.device_backup_position_summary(
                          position.slot.sourcePosition + 1,
                          _captureStateLabel(position.state, localizations),
                        ),
                      ),
                      subtitle: Text(
                        localizations.device_backup_frequency_states(
                          _captureStateLabel(position.hfState, localizations),
                          _captureStateLabel(position.lfState, localizations),
                        ),
                      ),
                    ),
                  ),
                ),
                const Divider(),
                Text(
                  localizations.device_backup_firmware_facts,
                  style: Theme.of(dialogContext).textTheme.titleMedium,
                ),
                _factRow(
                  localizations.device_backup_firmware_version,
                  backup.firmware.version,
                  localizations,
                ),
                _factRow(
                  localizations.device_backup_firmware_commit,
                  backup.firmware.commit,
                  localizations,
                ),
                _factRow(
                  localizations.device_backup_firmware_protocol,
                  backup.firmware.protocol,
                  localizations,
                ),
                const Divider(),
                Text(
                  localizations.device_backup_safe_preferences,
                  style: Theme.of(dialogContext).textTheme.titleMedium,
                ),
                _factRow(
                  localizations.device_backup_animation_mode,
                  backup.preferences.animationMode,
                  localizations,
                ),
                _factRow(
                  localizations.device_backup_button_a_press,
                  backup.preferences.buttonAPress,
                  localizations,
                ),
                _factRow(
                  localizations.device_backup_button_b_press,
                  backup.preferences.buttonBPress,
                  localizations,
                ),
                _factRow(
                  localizations.device_backup_button_a_long_press,
                  backup.preferences.buttonALongPress,
                  localizations,
                ),
                _factRow(
                  localizations.device_backup_button_b_long_press,
                  backup.preferences.buttonBLongPress,
                  localizations,
                ),
                _factRow(
                  localizations.device_backup_sleep_timeout,
                  backup.preferences.sleepTimeoutSeconds,
                  localizations,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('device-backup-cancel-save'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(localizations.cancel),
          ),
          ElevatedButton(
            key: const Key('device-backup-confirm-save'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              backup.hasLimitations
                  ? localizations.device_backup_save_partial
                  : localizations.device_backup_save,
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _factRow<T>(
    String label,
    BackupFact<T> fact,
    AppLocalizations localizations,
  ) {
    final value = fact.state == BackupFactState.confirmed
        ? fact.value is Enum
            ? (fact.value as Enum).name
            : fact.value.toString()
        : _factStateLabel(fact.state, localizations);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(value),
    );
  }

  String _modeLabel(
    FullDeviceOperatingMode mode,
    AppLocalizations localizations,
  ) =>
      mode == FullDeviceOperatingMode.reader
          ? localizations.reader
          : localizations.emulator;

  String _captureStateLabel(
    FullDeviceCaptureState state,
    AppLocalizations localizations,
  ) =>
      switch (state) {
        FullDeviceCaptureState.complete =>
          localizations.device_backup_state_complete,
        FullDeviceCaptureState.partial =>
          localizations.device_backup_state_partial,
        FullDeviceCaptureState.unsupported =>
          localizations.device_backup_state_unsupported,
        FullDeviceCaptureState.skipped =>
          localizations.device_backup_state_skipped,
        FullDeviceCaptureState.failed =>
          localizations.device_backup_state_failed,
      };

  String _factStateLabel(
    BackupFactState state,
    AppLocalizations localizations,
  ) =>
      switch (state) {
        BackupFactState.confirmed => localizations.device_backup_state_complete,
        BackupFactState.unsupported =>
          localizations.device_backup_state_unsupported,
        BackupFactState.failed => localizations.device_backup_state_failed,
      };

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    final status = _status;

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.slot_manager),
        actions: [
          IconButton(
            key: const Key('slot-manager-backup-all'),
            tooltip: localizations.backup_all_slots,
            onPressed: status == null || _backupBusy || progress != -1
                ? null
                : () => _backupAllSlots(
                      context.read<ChameleonGUIState>(),
                      status,
                      localizations,
                    ),
            icon: const Icon(Icons.settings_backup_restore),
          ),
        ],
      ),
      body: status == null
          ? Center(child: Text(localizations.unavailable))
          : ListenableBuilder(
              listenable: status,
              builder: (context, _) {
                final slots = status.snapshot.slots;
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      if (slots.availability == SlotsAvailability.unavailable ||
                          slots.availability == SlotsAvailability.partial ||
                          slots.availability == SlotsAvailability.stale)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              slots.availability == SlotsAvailability.stale
                                  ? '${localizations.slot_status}: ${localizations.unknown}'
                                  : localizations.unavailable,
                            ),
                            IconButton(
                              onPressed: status.refreshSlots,
                              tooltip: localizations.slot_status,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                      Expanded(child: _buildGrid(context, slots)),
                      if (_backupProgress != null)
                        _buildBackupProgress(context, _backupProgress!),
                      if (progress != -1) ...[
                        const SizedBox(height: 32),
                        Text(localizations.uploading_dump),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: LinearProgressIndicator(
                            value: (progress / 100).toDouble(),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildBackupProgress(
    BuildContext context,
    FullDeviceBackupProgress backupProgress,
  ) {
    final localizations = AppLocalizations.of(context)!;
    return Semantics(
      key: const Key('device-backup-progress'),
      liveRegion: true,
      label: localizations.device_backup_progress_semantics(
        backupProgress.currentPosition + 1,
        backupProgress.completedPositions,
      ),
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                localizations.device_backup_progress(
                  backupProgress.currentPosition + 1,
                  backupProgress.completedPositions,
                ),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: backupProgress.fraction),
              if (backupProgress.positions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: backupProgress.positions
                      .map(
                        (position) => Chip(
                          key: Key(
                            'device-backup-progress-position-${position.slot.sourcePosition}',
                          ),
                          label: Text(
                            localizations.device_backup_progress_position(
                              position.slot.sourcePosition + 1,
                              _captureStateLabel(
                                position.state,
                                localizations,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, SlotsStatus slots) {
    final localizations = AppLocalizations.of(context)!;
    return AlignedGridView.count(
      padding: const EdgeInsets.all(20),
      crossAxisCount: MediaQuery.of(context).size.width >= 700 ? 2 : 1,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      itemCount: 8,
      itemBuilder: (context, index) {
        final slot = slots.slots[index];
        return Container(
          constraints: const BoxConstraints(minHeight: 100),
          child: ElevatedButton(
            onPressed: progress == -1 && !_backupBusy
                ? () {
                    setState(() => gridPosition = index);
                    cardSelectDialog(context);
                  }
                : null,
            style: ButtonStyle(
              shape: WidgetStateProperty.all<RoundedRectangleBorder>(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18.0),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 8, left: 8, bottom: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Icon(Icons.nfc, color: _enabledColor(context, slot)),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '${localizations.slot} ${index + 1}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _frequencyRow(
                    icon: Icons.credit_card,
                    frequency: slot.hf,
                    localizations: localizations,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _frequencyRow(
                          icon: Icons.wifi,
                          frequency: slot.lf,
                          localizations: localizations,
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          showDialog<void>(
                            context: context,
                            builder: (_) => SlotSettings(
                              slot: index,
                            ),
                          );
                        },
                        icon: const Icon(Icons.settings),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _frequencyRow({
    required IconData icon,
    required SlotFrequencyStatus frequency,
    required AppLocalizations localizations,
  }) {
    final name = frequency.name.isConfirmed
        ? (frequency.name.value!.isEmpty
            ? localizations.no_name
            : frequency.name.value!)
        : localizations.unavailable;
    final type = frequency.type.isConfirmed
        ? chameleonTagToString(frequency.type.value!, localizations)
        : localizations.unavailable;
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Icon(icon),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            '$name ($type)',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Color _enabledColor(BuildContext context, DeviceSlotStatus slot) {
    if (slot.hf.enabled.value == true || slot.lf.enabled.value == true) {
      return Colors.green;
    }
    if (slot.hf.enabled.isConfirmed && slot.lf.enabled.isConfirmed) {
      return Colors.deepOrange;
    }
    return Theme.of(context).colorScheme.outline;
  }
}
