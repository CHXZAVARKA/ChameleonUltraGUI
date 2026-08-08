import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/gui/component/error_page.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/edit.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/gui/menu/dialogs/confirm_delete.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class SlotSettings extends StatefulWidget {
  final int slot;
  final dynamic refresh;

  const SlotSettings({super.key, required this.slot, required this.refresh});

  @override
  SlotSettingsState createState() => SlotSettingsState();
}

class SlotSettingsState extends State<SlotSettings> {
  EnabledSlotInfo enabledSlot = EnabledSlotInfo();
  SlotTypes slotTypes = SlotTypes();
  SlotNames names = SlotNames();
  TagFrequency exportFrequency = TagFrequency.hf;

  @override
  void initState() {
    super.initState();
  }

  Future<void> fetchInfo() async {
    final appState = context.read<ChameleonGUIState>();
    final localizations = AppLocalizations.of(context)!;
    final communicator = appState.communicator;
    if (communicator == null) {
      return;
    }

    await appState.rfOperations.runForeground(() async {
      bool canContinue() =>
          mounted && appState.hasConnectedCommunicator(communicator);
      if (!canContinue()) {
        return;
      }
      await communicator.activateSlot(widget.slot);
      if (!canContinue()) {
        return;
      }

      var hfName = localizations.empty;
      try {
        hfName = (await communicator.getSlotTagName(
          widget.slot,
          TagFrequency.hf,
        ))
            .trim();
        if (!canContinue()) {
          return;
        }
        if (hfName.isEmpty) {
          hfName = localizations.empty;
        }
      } catch (_) {
        if (!canContinue()) {
          return;
        }
      }

      var lfName = localizations.empty;
      try {
        lfName = (await communicator.getSlotTagName(
          widget.slot,
          TagFrequency.lf,
        ))
            .trim();
        if (!canContinue()) {
          return;
        }
        if (lfName.isEmpty) {
          lfName = localizations.empty;
        }
      } catch (_) {
        if (!canContinue()) {
          return;
        }
      }

      final nextEnabledSlots = await communicator.getEnabledSlots();
      if (!canContinue()) {
        return;
      }
      final nextSlotTypes = await communicator.getSlotTagTypes();
      if (!canContinue()) {
        return;
      }

      setState(() {
        names = SlotNames(hf: hfName, lf: lfName);
        enabledSlot = nextEnabledSlots[widget.slot];
        slotTypes = nextSlotTypes[widget.slot];
      });
    });
  }

  Future<bool> _runForegroundCommand(
    Future<void> Function(ChameleonCommunicator communicator) command,
  ) async {
    final appState = context.read<ChameleonGUIState>();
    final communicator = appState.communicator;
    if (communicator == null) {
      return false;
    }
    return appState.rfOperations.runForeground(() async {
      if (!mounted || !appState.hasConnectedCommunicator(communicator)) {
        return false;
      }
      await command(communicator);
      return mounted && appState.hasConnectedCommunicator(communicator);
    });
  }

  Future<bool> _deleteSlot(TagFrequency frequency) {
    final appState = context.read<ChameleonGUIState>();
    final emptyName = AppLocalizations.of(context)!.empty;
    return _runForegroundCommand((communicator) async {
      await communicator.activateSlot(widget.slot);
      if (!mounted || !appState.hasConnectedCommunicator(communicator)) {
        return;
      }
      await communicator.deleteSlotInfo(widget.slot, frequency);
      if (!mounted || !appState.hasConnectedCommunicator(communicator)) {
        return;
      }
      await communicator.setSlotTagName(
        widget.slot,
        emptyName,
        frequency,
      );
      if (!mounted || !appState.hasConnectedCommunicator(communicator)) {
        return;
      }
      await communicator.saveSlotData();
    });
  }

  void updateSlot(String name, TagFrequency frequency, TagType type) {
    if (frequency == TagFrequency.hf) {
      names.hf = name;
      slotTypes.hf = type;
    } else if (frequency == TagFrequency.lf) {
      names.lf = name;
      slotTypes.lf = type;
    }

    widget.refresh();

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;

    return FutureBuilder(
        future: (names.hf.isNotEmpty) ? Future.value(null) : fetchInfo(),
        builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              names.hf.isEmpty) {
            return AlertDialog(
                title: Text(localizations.slot_settings),
                content: const SingleChildScrollView(
                    child: Column(children: [CircularProgressIndicator()])));
          } else if (snapshot.hasError) {
            appState.connector!.performDisconnect();
            return AlertDialog(
                title: Text(localizations.slot_settings),
                content: ErrorPage(errorMessage: snapshot.error.toString()));
          } else {
            return AlertDialog(
                title: Row(
                  children: [
                    Text(localizations.slot_settings),
                    const Spacer(
                      flex: 1,
                    ),
                    IconButton(
                      onPressed: (slotTypes.notMatch())
                          ? () {
                              showDialog<String>(
                                  context: context,
                                  builder: (BuildContext context) =>
                                      SlotExportMenu(
                                          slot: widget.slot,
                                          names: names,
                                          enabledSlotInfo: enabledSlot,
                                          slotTypes: slotTypes));
                            }
                          : null,
                      icon: const Icon(Icons.download),
                    ),
                  ],
                ),
                content: SingleChildScrollView(
                    child: Column(children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('${localizations.hf}:'),
                          const Spacer(),
                          IconButton(
                            onPressed: () async {
                              showDialog<String>(
                                  context: context,
                                  builder: (BuildContext context) =>
                                      SlotEditMenu(
                                          name: names.hf,
                                          isEnabled: enabledSlot.hf,
                                          slotType: slotTypes.hf,
                                          frequency: TagFrequency.hf,
                                          slot: widget.slot,
                                          update: updateSlot));
                            },
                            icon: const Icon(Icons.edit),
                          ),
                          IconButton(
                            onPressed: () async {
                              if (appState.sharedPreferencesProvider
                                      .getConfirmDelete() ==
                                  true) {
                                var confirm = await showDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return ConfirmDeletionMenu(
                                        thingBeingDeleted: names.hf);
                                  },
                                );

                                if (confirm != true) {
                                  return;
                                }
                              }
                              if (!await _deleteSlot(TagFrequency.hf)) {
                                return;
                              }

                              setState(() {
                                names.hf = localizations.empty;
                                slotTypes.hf = TagType.unknown;
                              });

                              widget.refresh();
                            },
                            icon: const Icon(Icons.clear_rounded),
                          ),
                          Switch(
                            value: enabledSlot.hf,
                            onChanged: (bool value) async {
                              if (!await _runForegroundCommand(
                                  (communicator) => communicator.enableSlot(
                                        widget.slot,
                                        TagFrequency.hf,
                                        value,
                                      ))) {
                                return;
                              }

                              setState(() {
                                enabledSlot.hf = value;
                              });

                              widget.refresh();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: null,
                          child: Text(
                            names.hf,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('${localizations.lf}:'),
                          const Spacer(),
                          IconButton(
                            onPressed: () async {
                              showDialog<String>(
                                  context: context,
                                  builder: (BuildContext context) =>
                                      SlotEditMenu(
                                          name: names.lf,
                                          isEnabled: enabledSlot.lf,
                                          slotType: slotTypes.lf,
                                          frequency: TagFrequency.lf,
                                          slot: widget.slot,
                                          update: updateSlot));
                            },
                            icon: const Icon(Icons.edit),
                          ),
                          IconButton(
                            onPressed: () async {
                              if (appState.sharedPreferencesProvider
                                      .getConfirmDelete() ==
                                  true) {
                                var confirm = await showDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return ConfirmDeletionMenu(
                                        thingBeingDeleted: names.lf);
                                  },
                                );

                                if (confirm != true) {
                                  return;
                                }
                              }
                              if (!await _deleteSlot(TagFrequency.lf)) {
                                return;
                              }

                              setState(() {
                                names.lf = localizations.empty;
                                slotTypes.lf = TagType.unknown;
                              });

                              widget.refresh();
                            },
                            icon: const Icon(Icons.clear_rounded),
                          ),
                          Switch(
                            value: enabledSlot.lf,
                            onChanged: (bool value) async {
                              if (!await _runForegroundCommand(
                                  (communicator) => communicator.enableSlot(
                                        widget.slot,
                                        TagFrequency.lf,
                                        value,
                                      ))) {
                                return;
                              }

                              setState(() {
                                enabledSlot.lf = value;
                              });

                              widget.refresh();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: null,
                          child: Text(
                            names.lf,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ])));
          }
        });
  }
}
