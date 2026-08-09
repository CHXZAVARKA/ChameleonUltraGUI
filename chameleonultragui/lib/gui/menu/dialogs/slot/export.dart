import 'dart:convert';

import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/component/toggle_buttons.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:flutter/material.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class MifareClassicSlotDump {
  final List<Uint8List> blocks;
  final bool complete;

  const MifareClassicSlotDump({
    required this.blocks,
    required this.complete,
  });
}

Future<MifareClassicSlotDump> readMifareClassicSlotDump({
  required int blockCount,
  required Future<Uint8List> Function(int firstBlock, int blockCount)
      readBlocks,
  int maxBlocksPerRead = 16,
}) async {
  if (blockCount <= 0 || maxBlocksPerRead <= 0) {
    throw ArgumentError('Block counts must be positive');
  }

  final binData = Uint8List(blockCount * 16);
  var complete = true;

  for (var firstBlock = 0;
      firstBlock < blockCount;
      firstBlock += maxBlocksPerRead) {
    final remainingBlocks = blockCount - firstBlock;
    final requestedBlocks =
        remainingBlocks < maxBlocksPerRead ? remainingBlocks : maxBlocksPerRead;
    final result = await readBlocks(firstBlock, requestedBlocks);
    final expectedLength = requestedBlocks * 16;

    if (result.length != expectedLength) {
      complete = false;
    }

    final copyLength =
        result.length < expectedLength ? result.length : expectedLength;
    final destinationOffset = firstBlock * 16;
    binData.setRange(
      destinationOffset,
      destinationOffset + copyLength,
      result,
    );
  }

  final blocks = <Uint8List>[];
  for (var offset = 0; offset < binData.length; offset += 16) {
    blocks.add(Uint8List.fromList(binData.sublist(offset, offset + 16)));
  }

  return MifareClassicSlotDump(blocks: blocks, complete: complete);
}

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

class SlotExportMenu extends StatefulWidget {
  final SlotNames names;
  final EnabledSlotInfo enabledSlotInfo;
  final SlotTypes slotTypes;

  const SlotExportMenu(
      {super.key,
      required this.names,
      required this.enabledSlotInfo,
      required this.slotTypes});

  @override
  SlotExportMenuState createState() => SlotExportMenuState();
}

class SlotExportMenuState extends State<SlotExportMenu> {
  TagFrequency exportFrequency = TagFrequency.unknown;

  Future<CardSave?> rebuildCardSaveFromSlot(TagFrequency frequency) async {
    var appState = context.read<ChameleonGUIState>();

    if (frequency == TagFrequency.lf) {
      if (isEM410X(widget.slotTypes.lf)) {
        return CardSave(
          uid: bytesToHexSpace(
              await appState.communicator!.getEM410XEmulatorID()),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.hidProx) {
        return CardSave(
          uid: (await appState.communicator!.getHIDProxEmulatorID()).toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.viking) {
        return CardSave(
          uid: (await appState.communicator!.getVikingEmulatorID()).toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.pac) {
        return CardSave(
          uid: (await appState.communicator!.getPacEmulatorID()).toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.ioProx) {
        return CardSave(
          uid: (await appState.communicator!.getIoProxEmulatorID()).toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.idteck) {
        return CardSave(
          uid: (await appState.communicator!.getIdteckEmulatorID()).toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      }
    } else {
      CardData data = await appState.communicator!.mf1GetAntiCollData();

      if (isMifareUltralight(widget.slotTypes.hf)) {
        int pageCount = mfUltralightGetPagesCount(widget.slotTypes.hf);
        List<Uint8List> pages = [];

        for (int page = 0; page < pageCount; page++) {
          Uint8List pageData =
              await appState.communicator!.mf0EmulatorReadPages(page, 1);
          pages.add(pageData);
        }

        CardSaveExtra extraData = CardSaveExtra();

        Uint8List version =
            await appState.communicator!.mf0EmulatorGetVersionData();
        if (version.isNotEmpty) {
          extraData.ultralightVersion = version;
        }

        Uint8List signature =
            await appState.communicator!.mf0EmulatorGetSignatureData();
        if (signature.isNotEmpty) {
          extraData.ultralightSignature = signature;
        }

        if (mfUltralightHasCounters(widget.slotTypes.hf)) {
          List<int> counters = [];
          int counterCount = mfUltralightGetCounterCount(widget.slotTypes.hf);

          for (int i = 0; i < counterCount; i++) {
            var counterData =
                await appState.communicator!.mf0EmulatorGetCounterData(i);
            counters.add(counterData.$1);
          }

          if (counters.isNotEmpty) {
            extraData.ultralightCounters = counters;
          }
        }

        return CardSave(
          uid: bytesToHexSpace(data.uid),
          name: widget.names.hf,
          sak: data.sak,
          atqa: data.atqa,
          ats: data.ats,
          tag: widget.slotTypes.hf,
          data: pages,
          extraData: extraData,
        );
      } else {
        int blockCount = mfClassicGetBlockCount(
            chameleonTagTypeGetMfClassicType(widget.slotTypes.hf));
        final dump = await readMifareClassicSlotDump(
          blockCount: blockCount,
          readBlocks: appState.communicator!.mf1GetEmulatorBlock,
        );

        return CardSave(
          uid: bytesToHexSpace(data.uid),
          name: widget.names.hf,
          sak: data.sak,
          atqa: data.atqa,
          ats: data.ats,
          tag: widget.slotTypes.hf,
          data: dump.blocks,
          extraData: CardSaveExtra(
            mifareClassicDumpComplete: dump.complete,
          ),
        );
      }
    }

    return null;
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

    // modify only changeable values
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
