import 'dart:async';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/confirm_delete.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/edit.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
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
    final status = context.read<ChameleonGUIState>().connectedDeviceStatus;
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
        final slot = status.snapshot.slots.slots[widget.slot];
        final names = SlotNames(
          hf: _name(slot.hf, localizations),
          lf: _name(slot.lf, localizations),
        );
        final slotTypes = SlotTypes(
          hf: slot.hf.type.value ?? TagType.unknown,
          lf: slot.lf.type.value ?? TagType.unknown,
        );
        final enabledSlot = EnabledSlotInfo(
          hf: slot.hf.enabled.value ?? false,
          lf: slot.lf.enabled.value ?? false,
        );

        return AlertDialog(
          title: Row(
            children: [
              Text(localizations.slot_settings),
              const Spacer(),
              IconButton(
                onPressed: slotTypes.notMatch()
                    ? () {
                        showDialog<String>(
                          context: context,
                          builder: (context) => SlotExportMenu(
                            names: names,
                            enabledSlotInfo: enabledSlot,
                            slotTypes: slotTypes,
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
                  name: names.hf,
                  type: slotTypes.hf,
                  enabled: enabledSlot.hf,
                ),
                const SizedBox(height: 8),
                _frequencySettings(
                  status: status,
                  appState: appState,
                  localizations: localizations,
                  frequency: TagFrequency.lf,
                  name: names.lf,
                  type: slotTypes.lf,
                  enabled: enabledSlot.lf,
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
    required String name,
    required TagType type,
    required bool enabled,
  }) {
    final frequencyName =
        frequency == TagFrequency.hf ? localizations.hf : localizations.lf;
    final keySuffix = frequency.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$frequencyName:'),
            const Spacer(),
            IconButton(
              key: Key('slot-settings-edit-$keySuffix'),
              onPressed: () {
                showDialog<String>(
                  context: context,
                  builder: (context) => SlotEditMenu(
                    name: name,
                    isEnabled: enabled,
                    slotType: type,
                    frequency: frequency,
                    slot: widget.slot,
                  ),
                );
              },
              icon: const Icon(Icons.edit),
            ),
            IconButton(
              key: Key('slot-settings-delete-$keySuffix'),
              onPressed: () => _deleteFrequency(
                status,
                appState,
                frequency,
                name,
                localizations,
              ),
              icon: const Icon(Icons.clear_rounded),
            ),
            Switch(
              key: Key('slot-settings-enable-$keySuffix'),
              value: enabled,
              onChanged: (value) =>
                  _setFrequencyEnabled(status, frequency, value),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: null,
            child: Text(name, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }

  String _name(
    SlotFrequencyStatus frequency,
    AppLocalizations localizations,
  ) {
    if (!frequency.name.isConfirmed) {
      return localizations.unavailable;
    }
    final name = frequency.name.value!;
    return name.isEmpty ? localizations.empty : name;
  }
}
