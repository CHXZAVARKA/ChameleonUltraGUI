import 'dart:convert';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/component/toggle_buttons.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
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

class _SlotReadCanceled implements Exception {
  const _SlotReadCanceled();
}

class SlotExportMenu extends StatefulWidget {
  final int slot;
  final SlotNames names;
  final EnabledSlotInfo enabledSlotInfo;
  final SlotTypes slotTypes;

  const SlotExportMenu(
      {super.key,
      required this.slot,
      required this.names,
      required this.enabledSlotInfo,
      required this.slotTypes});

  @override
  SlotExportMenuState createState() => SlotExportMenuState();
}

class SlotExportMenuState extends State<SlotExportMenu> {
  TagFrequency exportFrequency = TagFrequency.unknown;

  Future<CardSave?> rebuildCardSaveFromSlot(TagFrequency frequency) async {
    final appState = context.read<ChameleonGUIState>();
    final result = await appState.runSessionBoundForeground((session) async {
      bool canContinue() => mounted && session.isCurrent;
      if (!canContinue()) {
        return null;
      }
      await session.communicator.activateSlot(widget.slot);
      if (!canContinue()) {
        return null;
      }
      return _rebuildCardSaveUnderLease(
        session.communicator,
        frequency,
        canContinue,
      );
    });
    return result.executed ? result.value : null;
  }

  Future<CardSave?> _rebuildCardSaveUnderLease(
    ChameleonCommunicator communicator,
    TagFrequency frequency,
    bool Function() canContinue,
  ) async {
    Future<T?> read<T>(Future<T> Function() operation) async {
      if (!canContinue()) {
        return null;
      }
      final value = await operation();
      return canContinue() ? value : null;
    }

    if (frequency == TagFrequency.lf) {
      if (isEM410X(widget.slotTypes.lf)) {
        final uid = await read(communicator.getEM410XEmulatorID);
        if (uid == null) {
          return null;
        }
        return CardSave(
          uid: bytesToHexSpace(uid),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.hidProx) {
        final uid = await read(communicator.getHIDProxEmulatorID);
        if (uid == null) {
          return null;
        }
        return CardSave(
          uid: uid.toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.viking) {
        final uid = await read(communicator.getVikingEmulatorID);
        if (uid == null) {
          return null;
        }
        return CardSave(
          uid: uid.toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.pac) {
        final uid = await read(communicator.getPacEmulatorID);
        if (uid == null) {
          return null;
        }
        return CardSave(
          uid: uid.toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.ioProx) {
        final uid = await read(communicator.getIoProxEmulatorID);
        if (uid == null) {
          return null;
        }
        return CardSave(
          uid: uid.toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      } else if (widget.slotTypes.lf == TagType.idteck) {
        final uid = await read(communicator.getIdteckEmulatorID);
        if (uid == null) {
          return null;
        }
        return CardSave(
          uid: uid.toString(),
          name: widget.names.lf,
          tag: widget.slotTypes.lf,
        );
      }
    } else {
      final data = await read(communicator.mf1GetAntiCollData);
      if (data == null) {
        return null;
      }

      if (isMifareUltralight(widget.slotTypes.hf)) {
        int pageCount = mfUltralightGetPagesCount(widget.slotTypes.hf);
        List<Uint8List> pages = [];

        for (int page = 0; page < pageCount; page++) {
          final pageData =
              await read(() => communicator.mf0EmulatorReadPages(page, 1));
          if (pageData == null) {
            return null;
          }
          pages.add(pageData);
        }

        CardSaveExtra extraData = CardSaveExtra();

        final version = await read(communicator.mf0EmulatorGetVersionData);
        if (version == null) {
          return null;
        }
        if (version.isNotEmpty) {
          extraData.ultralightVersion = version;
        }

        final signature = await read(communicator.mf0EmulatorGetSignatureData);
        if (signature == null) {
          return null;
        }
        if (signature.isNotEmpty) {
          extraData.ultralightSignature = signature;
        }

        if (mfUltralightHasCounters(widget.slotTypes.hf)) {
          List<int> counters = [];
          int counterCount = mfUltralightGetCounterCount(widget.slotTypes.hf);

          for (int i = 0; i < counterCount; i++) {
            final counterData =
                await read(() => communicator.mf0EmulatorGetCounterData(i));
            if (counterData == null) {
              return null;
            }
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
        late final MifareClassicSlotDump dump;
        try {
          dump = await readMifareClassicSlotDump(
            blockCount: blockCount,
            readBlocks: (firstBlock, requestedBlocks) async {
              final result = await read(
                () => communicator.mf1GetEmulatorBlock(
                  firstBlock,
                  requestedBlocks,
                ),
              );
              if (result == null) {
                throw const _SlotReadCanceled();
              }
              return result;
            },
          );
        } on _SlotReadCanceled {
          return null;
        }

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
