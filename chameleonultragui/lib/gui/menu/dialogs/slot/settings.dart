import 'dart:async';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:chameleonultragui/gui/menu/dialogs/confirm_delete.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/edit.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:chameleonultragui/helpers/single_slot_backup_workflow.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SlotSettings extends StatefulWidget {
  const SlotSettings({
    super.key,
    required this.slot,
    this.expectedStatus,
  });

  final int slot;
  final ConnectedDeviceStatus? expectedStatus;

  @override
  SlotSettingsState createState() => SlotSettingsState();
}

class SlotSettingsState extends State<SlotSettings> {
  ConnectedDeviceStatus? _status;
  bool _ready = false;
  bool _backupBusy = false;
  Object? _loadError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final status = context.watch<ChameleonGUIState>().connectedDeviceStatus;
    if (status == null ||
        !status.isCurrentSession ||
        (widget.expectedStatus != null &&
            !identical(status, widget.expectedStatus))) {
      _status = null;
      _ready = false;
      return;
    }
    if (identical(status, _status)) {
      return;
    }
    _status = status;
    _ready = false;
    _loadError = null;
    unawaited(_activateSlot(status));
  }

  Future<void> _activateSlot(ConnectedDeviceStatus status) async {
    try {
      await status.mutateSlots(
        (mutation) => mutation.run(
          (communicator) => communicator.activateSlot(widget.slot),
        ),
      );
      if (mounted && identical(status, _status) && status.isCurrentSession) {
        setState(() => _ready = true);
      }
    } catch (error) {
      if (mounted && identical(status, _status)) {
        setState(() => _loadError = error);
      }
    }
  }

  Future<void> _deleteFrequency(
    ConnectedDeviceStatus status,
    ChameleonGUIState appState,
    TagFrequency frequency,
    String name,
    AppLocalizations localizations,
  ) async {
    if (appState.sharedPreferencesProvider.getConfirmDelete()) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => ConfirmDeletionMenu(thingBeingDeleted: name),
      );
      if (confirm != true) {
        return;
      }
    }

    await status.mutateSlots((mutation) async {
      await mutation.run(
        (communicator) => communicator.deleteSlotInfo(widget.slot, frequency),
      );
      await mutation.run(
        (communicator) => communicator.setSlotTagName(
          widget.slot,
          localizations.empty,
          frequency,
        ),
      );
      await mutation.run((communicator) => communicator.saveSlotData());
    });
  }

  Future<void> _setFrequencyEnabled(
    ConnectedDeviceStatus status,
    TagFrequency frequency,
    bool enabled,
  ) =>
      status.mutateSlots(
        (mutation) => mutation.run(
          (communicator) => communicator.enableSlot(
            widget.slot,
            frequency,
            enabled,
          ),
        ),
      );

  Future<void> _exportBackup(
    ChameleonGUIState appState,
    ConnectedDeviceStatus status,
    AppLocalizations localizations,
  ) async {
    if (_backupBusy) {
      return;
    }
    setState(() => _backupBusy = true);
    final outcome = await appState.singleSlotBackupWorkflow.export(
      status: status,
      position: widget.slot,
    );
    if (!mounted) {
      return;
    }
    setState(() => _backupBusy = false);
    if (outcome == SlotBackupExportOutcome.saved) {
      _showMessage(localizations.slot_backup_saved);
    } else if (outcome != SlotBackupExportOutcome.cancelled) {
      _showMessage(localizations.slot_backup_failed);
    }
  }

  Future<void> _openRestore(
    ChameleonGUIState appState,
    ConnectedDeviceStatus status,
    AppLocalizations localizations,
  ) async {
    if (_backupBusy) {
      return;
    }
    setState(() => _backupBusy = true);
    final opened = await appState.singleSlotBackupWorkflow.open();
    if (!mounted) {
      return;
    }
    setState(() => _backupBusy = false);
    if (opened.outcome == SlotBackupOpenOutcome.cancelled) {
      return;
    }
    if (opened.outcome != SlotBackupOpenOutcome.ready) {
      _showMessage(localizations.slot_backup_invalid);
      return;
    }
    final backup = opened.backup!;
    final compatible = backup.sourceDevice == status.snapshot.identity.device;
    final canRestore = backup.isRestorable && compatible;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(localizations.slot_restore_preview),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              localizations.slot_restore_preview_description(
                backup.sourcePosition + 1,
                widget.slot + 1,
              ),
            ),
            const SizedBox(height: 16),
            _backupFrequencySummary(
              backup.hf,
              localizations.hf,
              localizations,
            ),
            const SizedBox(height: 8),
            _backupFrequencySummary(
              backup.lf,
              localizations.lf,
              localizations,
            ),
            if (!backup.isRestorable) ...[
              const SizedBox(height: 16),
              Text(localizations.slot_restore_incomplete),
            ] else if (!compatible) ...[
              const SizedBox(height: 16),
              Text(localizations.slot_restore_incompatible),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(localizations.cancel),
          ),
          ElevatedButton(
            key: const Key('slot-backup-confirm-restore'),
            onPressed:
                canRestore ? () => Navigator.pop(dialogContext, true) : null,
            child: Text(localizations.restore_slot),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _backupBusy = true);
    final outcome = await appState.singleSlotBackupWorkflow.restore(
      status: status,
      backup: backup,
      targetPosition: widget.slot,
    );
    if (!mounted) {
      return;
    }
    setState(() => _backupBusy = false);
    _showMessage(switch (outcome) {
      SlotBackupRestoreOutcome.restored => localizations.slot_restore_completed,
      SlotBackupRestoreOutcome.incompatibleDevice =>
        localizations.slot_restore_incompatible,
      SlotBackupRestoreOutcome.incomplete =>
        localizations.slot_restore_incomplete,
      SlotBackupRestoreOutcome.invalid => localizations.slot_backup_invalid,
      SlotBackupRestoreOutcome.connectionChanged ||
      SlotBackupRestoreOutcome.failed =>
        localizations.slot_restore_failed,
    });
  }

  Widget _backupFrequencySummary(
    SlotFrequencyBackup frequency,
    String frequencyName,
    AppLocalizations localizations,
  ) {
    final type = frequency.type;
    final typeLabel = type == null || type == TagType.unknown
        ? localizations.empty
        : chameleonTagToString(type, localizations);
    final enabledLabel = frequency.enabled == null
        ? localizations.unknown
        : frequency.enabled!
            ? localizations.enabled
            : localizations.disabled;
    return Text(
      localizations.slot_backup_frequency_summary(
        frequencyName,
        _backupStateLabel(frequency.state, localizations),
        typeLabel,
        enabledLabel,
      ),
    );
  }

  String _backupStateLabel(
    SlotBackupCompleteness state,
    AppLocalizations localizations,
  ) =>
      switch (state) {
        SlotBackupCompleteness.empty => localizations.slot_backup_state_empty,
        SlotBackupCompleteness.complete =>
          localizations.slot_backup_state_complete,
        SlotBackupCompleteness.partial =>
          localizations.slot_backup_state_partial,
        SlotBackupCompleteness.unavailable =>
          localizations.slot_backup_state_unavailable,
        SlotBackupCompleteness.unsupported =>
          localizations.slot_backup_state_unsupported,
      };

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.read<ChameleonGUIState>();
    final localizations = AppLocalizations.of(context)!;
    final status = _status;
    if (status == null) {
      return AlertDialog(
        title: Text(localizations.slot_settings),
        content: Text(localizations.unavailable),
      );
    }
    if (!_ready) {
      return AlertDialog(
        title: Text(localizations.slot_settings),
        content: _loadError == null
            ? ChameleonLoadingIndicator(
                size: 48,
                semanticLabel: localizations.loading,
              )
            : Text(localizations.unavailable),
      );
    }

    return ListenableBuilder(
      listenable: status,
      builder: (context, _) {
        final slots = status.snapshot.slots;
        final slot = slots.slots[widget.slot];
        final hf = _SlotFrequencyView(slots, slot.hf);
        final lf = _SlotFrequencyView(slots, slot.lf);
        final canExport = hf.isCurrent &&
            lf.isCurrent &&
            (hf.type.value != TagType.unknown ||
                lf.type.value != TagType.unknown);
        final needsRefresh =
            slots.unavailableFacets.isNotEmpty || slots.staleFacets.isNotEmpty;

        return AlertDialog(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  localizations.slot_settings,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (needsRefresh)
                IconButton(
                  key: const Key('slot-settings-refresh'),
                  onPressed: status.refreshSlots,
                  tooltip: localizations.slot_status,
                  icon: const Icon(Icons.refresh),
                ),
              IconButton(
                key: const Key('slot-settings-backup'),
                onPressed: _backupBusy
                    ? null
                    : () => _exportBackup(
                          appState,
                          status,
                          localizations,
                        ),
                tooltip: localizations.backup_slot,
                icon: const Icon(Icons.backup_outlined),
              ),
              IconButton(
                key: const Key('slot-settings-restore'),
                onPressed: _backupBusy
                    ? null
                    : () => _openRestore(
                          appState,
                          status,
                          localizations,
                        ),
                tooltip: localizations.restore_slot,
                icon: const Icon(Icons.restore_page_outlined),
              ),
              IconButton(
                key: const Key('slot-settings-export'),
                onPressed: canExport
                    ? () {
                        showDialog<String>(
                          context: context,
                          builder: (context) => SlotExportMenu(
                            slot: widget.slot,
                            names: SlotNames(
                              hf: hf.name.value!,
                              lf: lf.name.value!,
                            ),
                            enabledSlotInfo: EnabledSlotInfo(
                              hf: hf.enabled.value!,
                              lf: lf.enabled.value!,
                            ),
                            slotTypes: SlotTypes(
                              hf: hf.type.value!,
                              lf: lf.type.value!,
                            ),
                            expectedStatus: status,
                          ),
                        );
                      }
                    : null,
                icon: const Icon(Icons.download),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              children: [
                _frequencySettings(
                  status: status,
                  appState: appState,
                  localizations: localizations,
                  frequency: TagFrequency.hf,
                  frequencyStatus: hf,
                ),
                const SizedBox(height: 8),
                _frequencySettings(
                  status: status,
                  appState: appState,
                  localizations: localizations,
                  frequency: TagFrequency.lf,
                  frequencyStatus: lf,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _frequencySettings({
    required ConnectedDeviceStatus status,
    required ChameleonGUIState appState,
    required AppLocalizations localizations,
    required TagFrequency frequency,
    required _SlotFrequencyView frequencyStatus,
  }) {
    final frequencyName =
        frequency == TagFrequency.hf ? localizations.hf : localizations.lf;
    final keySuffix = frequency.name;
    final nameLabel = _fieldLabel(
      frequencyStatus.name,
      localizations,
      (name) => name.isEmpty ? localizations.empty : name,
    );
    final typeLabel = _fieldLabel(
      frequencyStatus.type,
      localizations,
      (type) => type == TagType.unknown
          ? localizations.empty
          : chameleonTagToString(type, localizations),
    );
    final canEdit = frequencyStatus.isCurrent;
    final canDelete =
        frequencyStatus.type.isCurrent && frequencyStatus.name.isCurrent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$frequencyName:'),
            const Spacer(),
            IconButton(
              key: Key('slot-settings-edit-$keySuffix'),
              onPressed: canEdit
                  ? () {
                      showDialog<String>(
                        context: context,
                        builder: (context) => SlotEditMenu(
                          status: status,
                          name: frequencyStatus.name.value!,
                          isEnabled: frequencyStatus.enabled.value!,
                          slotType: frequencyStatus.type.value!,
                          frequency: frequency,
                          slot: widget.slot,
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.edit),
            ),
            IconButton(
              key: Key('slot-settings-delete-$keySuffix'),
              onPressed: canDelete
                  ? () => _deleteFrequency(
                        status,
                        appState,
                        frequency,
                        _confirmedName(
                          frequencyStatus.name,
                          localizations,
                        ),
                        localizations,
                      )
                  : null,
              icon: const Icon(Icons.clear_rounded),
            ),
            _enabledControl(
              status: status,
              localizations: localizations,
              frequency: frequency,
              frequencyName: frequencyName,
              enabled: frequencyStatus.enabled,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(nameLabel, overflow: TextOverflow.ellipsis),
                Text(
                  typeLabel,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _enabledControl({
    required ConnectedDeviceStatus status,
    required AppLocalizations localizations,
    required TagFrequency frequency,
    required String frequencyName,
    required _SlotFieldView<bool> enabled,
  }) {
    final key = Key('slot-settings-enable-${frequency.name}');
    if (!enabled.field.isConfirmed) {
      return Semantics(
        key: key,
        container: true,
        enabled: false,
        label:
            '$frequencyName ${localizations.enabled.toLowerCase()}: ${localizations.unavailable}',
        child: SizedBox(
          width: 72,
          height: 48,
          child: ExcludeSemantics(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.remove, size: 20),
                Text(
                  localizations.unavailable,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final value = enabled.field.value!;
    final state = value ? localizations.enabled : localizations.disabled;
    final semanticsLabel = enabled.isCurrent
        ? '$frequencyName ${localizations.enabled.toLowerCase()}: $state'
        : '$frequencyName ${localizations.enabled.toLowerCase()}: $state (${localizations.unavailable})';
    final toggle = Switch(
      key: key,
      value: value,
      onChanged: enabled.isCurrent
          ? (value) => _setFrequencyEnabled(status, frequency, value)
          : null,
    );
    return Semantics(
      label: semanticsLabel,
      child: enabled.isCurrent
          ? toggle
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                toggle,
                ExcludeSemantics(
                  child: Text(
                    localizations.unavailable,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
    );
  }

  String _confirmedName(
    _SlotFieldView<String> name,
    AppLocalizations localizations,
  ) {
    assert(name.isCurrent);
    return name.field.value!.isEmpty ? localizations.empty : name.field.value!;
  }

  String _fieldLabel<T>(
    _SlotFieldView<T> field,
    AppLocalizations localizations,
    String Function(T value) label,
  ) {
    if (!field.field.isConfirmed) {
      return localizations.unavailable;
    }
    final confirmed = label(field.field.value as T);
    return field.isCurrent
        ? confirmed
        : '$confirmed (${localizations.unavailable})';
  }
}

class _SlotFrequencyView {
  _SlotFrequencyView(SlotsStatus slots, SlotFrequencyStatus frequency)
      : type = _SlotFieldView(
          frequency.type,
          unavailable: slots.unavailableFacets.contains(SlotFacet.types),
          stale: slots.staleFacets.contains(SlotFacet.types),
        ),
        enabled = _SlotFieldView(
          frequency.enabled,
          unavailable:
              slots.unavailableFacets.contains(SlotFacet.enabledStates),
          stale: slots.staleFacets.contains(SlotFacet.enabledStates),
        ),
        name = _SlotFieldView(
          frequency.name,
          unavailable: slots.unavailableFacets.contains(SlotFacet.names),
          stale: slots.staleFacets.contains(SlotFacet.names),
        );

  final _SlotFieldView<TagType> type;
  final _SlotFieldView<bool> enabled;
  final _SlotFieldView<String> name;

  bool get isCurrent => type.isCurrent && enabled.isCurrent && name.isCurrent;
}

class _SlotFieldView<T> {
  const _SlotFieldView(
    this.field, {
    required this.unavailable,
    required this.stale,
  });

  final SlotField<T> field;
  final bool unavailable;
  final bool stale;

  T? get value => field.value;

  bool get isCurrent => field.isConfirmed && !unavailable && !stale;
}
