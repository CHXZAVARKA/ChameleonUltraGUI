import 'dart:async';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/confirm_delete.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/edit.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SlotSettings extends StatefulWidget {
  const SlotSettings({super.key, required this.slot});

  final int slot;

  @override
  SlotSettingsState createState() => SlotSettingsState();
}

class SlotSettingsState extends State<SlotSettings> {
  ConnectedDeviceStatus? _status;
  bool _ready = false;
  Object? _loadError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final status = context.watch<ChameleonGUIState>().connectedDeviceStatus;
    if (identical(status, _status)) {
      return;
    }
    _status = status;
    _ready = false;
    _loadError = null;
    if (status != null) {
      unawaited(_activateSlot(status));
    }
  }

  Future<void> _activateSlot(ConnectedDeviceStatus status) async {
    try {
      await status.mutateSlots(
        (mutation) => mutation.run(
          (communicator) => communicator.activateSlot(widget.slot),
        ),
      );
      if (mounted && identical(status, _status)) {
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
            ? const CircularProgressIndicator()
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
                onPressed: canExport
                    ? () {
                        showDialog<String>(
                          context: context,
                          builder: (context) => SlotExportMenu(
                            names: SlotNames(
                              hf: _confirmedName(hf.name, localizations),
                              lf: _confirmedName(lf.name, localizations),
                            ),
                            enabledSlotInfo: EnabledSlotInfo(
                              hf: hf.enabled.value!,
                              lf: lf.enabled.value!,
                            ),
                            slotTypes: SlotTypes(
                              hf: hf.type.value!,
                              lf: lf.type.value!,
                            ),
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
