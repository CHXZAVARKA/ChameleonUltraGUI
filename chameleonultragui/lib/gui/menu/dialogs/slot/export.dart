import 'dart:convert';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/component/toggle_buttons.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/slot_command_runner.dart';
import 'package:chameleonultragui/helpers/slot_payload.dart';
import 'package:flutter/material.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

export 'package:chameleonultragui/helpers/slot_payload.dart'
    show MifareClassicSlotDump, readMifareClassicSlotDump;

void overwriteCardSaveFromSlot(CardSave target, CardSave source) {
  target.uid = source.uid;
  target.tag = source.tag;
  target.sak = source.sak;
  target.atqa = source.atqa;
  target.ats = source.ats;
  target.data = source.data;
  target.extraData.mifareClassicDumpComplete = isMifareClassic(source.tag)
      ? source.extraData.mifareClassicDumpComplete == true &&
          MifareClassicGeometry.fromSavedCardData(source) != null
      : null;
}

final class _SessionSlotCommandRunner implements SlotCommandRunner {
  const _SessionSlotCommandRunner(this.session, {required this.mounted});

  final ConnectedDeviceSession session;
  final bool Function() mounted;

  @override
  Future<T> run<T>(
    Future<T> Function(ChameleonCommunicator communicator) operation,
  ) async {
    if (!mounted() || !session.isCurrent) {
      throw const _SlotReadCanceled();
    }
    final result = await operation(session.communicator);
    if (!mounted() || !session.isCurrent) {
      throw const _SlotReadCanceled();
    }
    return result;
  }
}

class _SlotReadCanceled implements SlotCommandRunnerChanged {
  const _SlotReadCanceled();
}

class SlotExportMenu extends StatefulWidget {
  final int slot;
  final SlotNames names;
  final EnabledSlotInfo enabledSlotInfo;
  final SlotTypes slotTypes;
  final ConnectedDeviceStatus? expectedStatus;

  const SlotExportMenu(
      {super.key,
      required this.slot,
      required this.names,
      required this.enabledSlotInfo,
      required this.slotTypes,
      this.expectedStatus});

  @override
  SlotExportMenuState createState() => SlotExportMenuState();
}

class SlotExportMenuState extends State<SlotExportMenu> {
  TagFrequency exportFrequency = TagFrequency.unknown;

  Future<CardSave?> rebuildCardSaveFromSlot(TagFrequency frequency) async {
    final appState = context.read<ChameleonGUIState>();
    final expectedStatus = widget.expectedStatus;
    if (expectedStatus != null &&
        (!expectedStatus.isCurrentSession ||
            !identical(appState.connectedDeviceStatus, expectedStatus))) {
      return null;
    }
    final result = await appState.runSessionBoundForeground((session) async {
      bool canContinue() =>
          mounted &&
          session.isCurrent &&
          (expectedStatus == null ||
              (expectedStatus.isCurrentSession &&
                  identical(
                    appState.connectedDeviceStatus,
                    expectedStatus,
                  )));
      if (!canContinue()) {
        return null;
      }
      await session.communicator.activateSlot(widget.slot);
      if (!canContinue()) {
        return null;
      }
      final type = frequency == TagFrequency.hf
          ? widget.slotTypes.hf
          : widget.slotTypes.lf;
      if (!SlotPayloadReader.supports(type)) {
        return null;
      }
      try {
        final result = await SlotPayloadReader.read(
          runner: _SessionSlotCommandRunner(session, mounted: () => mounted),
          type: type,
        );
        return result.toCardSave(
          type: type,
          name:
              frequency == TagFrequency.hf ? widget.names.hf : widget.names.lf,
        );
      } on _SlotReadCanceled {
        return null;
      }
    });
    return result.executed ? result.value : null;
  }

  Future<void> onTap(
      CardSave card, dynamic close, AppLocalizations localizations) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    close(context, card.name);

    CardSave modify = card;
    CardSave? newCard =
        await rebuildCardSaveFromSlot(chameleonTagToFrequency(card.tag));

    if (newCard == null) {
      return;
    }

    overwriteCardSaveFromSlot(modify, newCard);

    var tags = appState.sharedPreferencesProvider.getCards();
    var index = tags.indexWhere((element) => element.id == modify.id);

    if (index != -1) {
      tags[index] = modify;
    }

    appState.sharedPreferencesProvider.setCards(tags);

    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    var appState = context.watch<ChameleonGUIState>();
    if (widget.expectedStatus != null &&
        (!widget.expectedStatus!.isCurrentSession ||
            !identical(
              appState.connectedDeviceStatus,
              widget.expectedStatus,
            ))) {
      return AlertDialog(
        title: Text(localizations.export_slot_data),
        content: Text(localizations.unavailable),
      );
    }

    List<String> buttons = [];
    if (widget.slotTypes.hf != TagType.unknown) {
      buttons.add(localizations.hf);
    }

    if (widget.slotTypes.lf != TagType.unknown) {
      buttons.add(localizations.lf);
    }

    if (exportFrequency == TagFrequency.unknown) {
      setState(() {
        exportFrequency =
            buttons[0] == localizations.hf ? TagFrequency.hf : TagFrequency.lf;
      });
    }

    return AlertDialog(
      title: Text(localizations.export_slot_data),
      content: SingleChildScrollView(
          child: Column(
        children: [
          Text(localizations.frequency_to_export),
          const SizedBox(height: 8),
          ToggleButtonsWrapper(
              items: buttons,
              selectedValue: 0,
              onChange: (int index) async {
                setState(() {
                  exportFrequency = buttons[index] == localizations.hf
                      ? TagFrequency.hf
                      : TagFrequency.lf;
                });
              }),
        ],
      )),
      actions: [
        ElevatedButton(
          onPressed: () async {
            CardSave? cardSave = await rebuildCardSaveFromSlot(exportFrequency);

            if (cardSave == null) {
              return;
            }

            Uint8List export = const Utf8Encoder().convert(cardSave.toJson());
            await FilePicker.saveFile(
              dialogTitle: '${localizations.output_file}:',
              fileName: '${cardSave.name}.json',
              bytes: export,
            );
            if (context.mounted) {
              Navigator.pop(context);
            }
          },
          child: Text(localizations.save_to_file),
        ),
        ElevatedButton(
          onPressed: () async {
            CardSave? tag = await rebuildCardSaveFromSlot(exportFrequency);
            if (context.mounted && tag != null) {
              await showDialog(
                context: context,
                builder: (BuildContext dialogContext) {
                  TextEditingController controller =
                      TextEditingController(text: tag.name);
                  return AlertDialog(
                    title: Text(localizations.enter_name_of_card),
                    content: TextField(controller: controller),
                    actions: [
                      ElevatedButton(
                        onPressed: () async {
                          tag.name = controller.text;
                          var tags =
                              appState.sharedPreferencesProvider.getCards();
                          tags.add(tag);
                          appState.sharedPreferencesProvider.setCards(tags);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                            Navigator.pop(context);
                          }
                        },
                        child: Text(localizations.ok),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                        },
                        child: Text(localizations.cancel),
                      ),
                    ],
                  );
                },
              );
            }
          },
          child: Text(localizations.export_to_new_card),
        ),
        ElevatedButton(
          onPressed: () async {
            var appState = context.read<ChameleonGUIState>();
            var tags = appState.sharedPreferencesProvider.getCards();

            tags.sort((a, b) => a.name.compareTo(b.name));

            showSearch<String>(
              context: context,
              delegate: CardSearchDelegate(
                  cards: tags,
                  onTap: onTap,
                  filter: exportFrequency == TagFrequency.hf
                      ? SearchFilter.hf
                      : SearchFilter.lf),
            );
          },
          child: Text(localizations.update_saved_card),
        ),
      ],
    );
  }
}
