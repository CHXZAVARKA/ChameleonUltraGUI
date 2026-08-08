import 'dart:typed_data';

import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/component/error_page.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  List<SlotTypes> usedSlots = List.generate(
    8,
    (_) => SlotTypes(),
  );

  List<EnabledSlotInfo> enabledSlots = List.generate(
    8,
    (_) => EnabledSlotInfo(),
  );

  List<SlotNames> slotData = List.generate(
    8,
    (_) => SlotNames(),
  );

  int progress = -1;
  int gridPosition = 0;
  bool onlyOneSlot = false;

  Future<void> loadSlotData() async {
    if (progress != -1) {
      return;
    }

    var appState = context.read<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;

    usedSlots = await appState.communicator!.getSlotTagTypes();
    enabledSlots = await appState.communicator!.getEnabledSlots();
    slotData = await appState.communicator!.getSlotTagNames();

    for (SlotNames slot in slotData) {
      slot.hf = slot.hf.isEmpty ? localizations.no_name : slot.hf;
      slot.lf = slot.lf.isEmpty ? localizations.no_name : slot.lf;
    }
  }

  void refreshSlot() {
    setUploadState(-1);

    var appState = context.read<ChameleonGUIState>();
    appState.changesMade();
  }

  void setUploadState(int progressBar) {
    setState(() {
      progress = progressBar;
    });

    var appState = context.read<ChameleonGUIState>();
    appState.changesMade();
  }

  Future<void> onTap(
      CardSave card, dynamic close, AppLocalizations localizations) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    final targetSlot = gridPosition;

    await appState.runSessionBoundForeground((session) async {
      if (!mounted || !session.isCurrent) {
        return;
      }

      try {
        await _uploadCardUnderLease(
          card,
          close,
          localizations,
          session,
          targetSlot,
        );
      } finally {
        if (mounted && progress != -1) {
          setUploadState(-1);
        }
      }
    });
  }

  Future<void> _uploadCardUnderLease(
    CardSave card,
    dynamic close,
    AppLocalizations localizations,
    ConnectedDeviceSession session,
    int gridPosition,
  ) async {
    final appState = session.appState;
    final communicator = session.communicator;
    bool canContinue() => mounted && session.isCurrent;
    Future<bool> waitFor(Future<void> command) async {
      await command;
      return canContinue();
    }

    if (isMifareClassic(card.tag)) {
      close(context, card.name);
      setUploadState(0);
      var isEV1 = chameleonTagSaveCheckForMifareClassicEV1(card);
      if (isEV1) {
        card.tag = TagType.mifare2K;
      }

      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.hf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      if (!await waitFor(communicator.setSlotType(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, card.tag))) {
        return;
      }
      var cardData = CardData(
          uid: hexToBytes(card.uid),
          atqa: card.atqa,
          sak: card.sak,
          ats: card.ats);
      if (!await waitFor(communicator.setMf1AntiCollision(cardData))) return;

      List<int> blockChunk = [];
      int lastSend = 0;

      for (var blockOffset = 0;
          blockOffset <
              mfClassicGetBlockCount(
                  chameleonTagTypeGetMfClassicType(card.tag));
          blockOffset++) {
        if ((card.data.length > blockOffset &&
                card.data[blockOffset].isEmpty) ||
            blockChunk.length >= 128) {
          if (blockChunk.isNotEmpty) {
            if (!await waitFor(communicator.setMf1BlockData(
                lastSend, Uint8List.fromList(blockChunk)))) {
              return;
            }
            blockChunk = [];
            lastSend = blockOffset;
          }
        }

        if (card.data.length > blockOffset &&
            card.data[blockOffset].length == 16) {
          blockChunk.addAll(card.data[blockOffset]);
        }

        setUploadState((blockOffset /
                mfClassicGetBlockCount(
                    chameleonTagTypeGetMfClassicType(card.tag)) *
                100)
            .round());
        await asyncSleep(1);
        if (!canContinue()) return;
      }

      if (blockChunk.isNotEmpty) {
        if (!await waitFor(communicator.setMf1BlockData(
            lastSend, Uint8List.fromList(blockChunk)))) {
          return;
        }
      }

      setUploadState(100);

      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.hf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else if (isEM410X(card.tag)) {
      close(context, card.name);
      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.lf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      TagType slotTagType = card.tag == TagType.em410XElectra
          ? TagType.em410XElectra
          : TagType.em410X;
      if (!await waitFor(communicator.setSlotType(gridPosition, slotTagType))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, slotTagType))) {
        return;
      }
      if (!await waitFor(
          communicator.setEM410XEmulatorID(hexToBytes(card.uid)))) {
        return;
      }
      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.hidProx) {
      close(context, card.name);
      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.lf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      if (!await waitFor(communicator.setSlotType(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(communicator.setHIDProxEmulatorID(
          hexToBytes(HIDCard.fromUID(card.uid).toString())))) {
        return;
      }
      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.viking) {
      close(context, card.name);
      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.lf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      if (!await waitFor(communicator.setSlotType(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setVikingEmulatorID(hexToBytes(card.uid)))) {
        return;
      }
      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.pac) {
      close(context, card.name);
      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.lf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      if (!await waitFor(communicator.setSlotType(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(communicator.setPacEmulatorID(hexToBytes(card.uid)))) {
        return;
      }
      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.ioProx) {
      close(context, card.name);
      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.lf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      if (!await waitFor(communicator.setSlotType(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setIoProxEmulatorID(hexToBytes(card.uid)))) {
        return;
      }
      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.idteck) {
      close(context, card.name);
      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.lf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      if (!await waitFor(communicator.setSlotType(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setIdteckEmulatorID(hexToBytes(card.uid)))) {
        return;
      }
      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else if (isMifareUltralight(card.tag)) {
      close(context, card.name);
      setUploadState(0);

      if (!await waitFor(communicator.setReaderDeviceMode(false))) return;
      if (!await waitFor(
          communicator.enableSlot(gridPosition, TagFrequency.hf, true))) {
        return;
      }
      if (!await waitFor(communicator.activateSlot(gridPosition))) return;
      if (!await waitFor(communicator.setSlotType(gridPosition, card.tag))) {
        return;
      }
      if (!await waitFor(
          communicator.setDefaultDataToSlot(gridPosition, card.tag))) {
        return;
      }
      var cardData = CardData(
          uid: hexToBytes(card.uid),
          atqa: card.atqa,
          sak: card.sak,
          ats: card.ats);
      if (!await waitFor(communicator.setMf1AntiCollision(cardData))) return;

      for (var page = 0;
          page < mfUltralightGetPagesCount(card.tag) && card.data.length > page;
          page++) {
        if (!await waitFor(
            communicator.mf0EmulatorWritePages(page, card.data[page]))) {
          return;
        }

        setUploadState(
            (page / mfUltralightGetPagesCount(card.tag) * 100).round());

        await asyncSleep(1);
        if (!canContinue()) return;
      }

      if (card.extraData.ultralightVersion.isNotEmpty) {
        if (!await waitFor(communicator
            .mf0EmulatorSetVersionData(card.extraData.ultralightVersion))) {
          return;
        }
      }

      if (card.extraData.ultralightSignature.isNotEmpty) {
        if (!await waitFor(communicator
            .mf0EmulatorSetSignatureData(card.extraData.ultralightSignature))) {
          return;
        }
      }

      if (card.extraData.ultralightCounters.isNotEmpty) {
        for (int i = 0; i < card.extraData.ultralightCounters.length; i++) {
          if (!await waitFor(communicator.mf0EmulatorSetCounterData(
              i, card.extraData.ultralightCounters[i], true))) {
            return;
          }
        }
      }

      if (mfUltralightHasCounters(card.tag)) {
        if (!await waitFor(communicator.mf0ResetAuthCount())) return;
      }

      setUploadState(100);

      if (!await waitFor(communicator.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.hf))) {
        return;
      }
      if (!await waitFor(communicator.saveSlotData())) return;
      appState.changesMade();
      refreshSlot();
    } else {
      appState.log!.e("Can't write this card type yet.");
      close(context, card.name);
    }
  }

  Future<String?> cardSelectDialog(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();
    var tags = appState.sharedPreferencesProvider.getCards();

    // Don't allow user to upload more tags while already uploading dump
    if (progress != -1) {
      return Future.value("");
    }

    tags.sort((a, b) => a.name.compareTo(b.name));

    return showSearch<String>(
      context: context,
      delegate: CardSearchDelegate(cards: tags, onTap: onTap),
    );
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.slot_manager),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FutureBuilder(
              future: loadSlotData(),
              builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting ||
                    progress != -1) {
                  return const Center(child: CircularProgressIndicator());
                } else if (snapshot.hasError) {
                  appState.connector!.performDisconnect();
                  return ErrorPage(errorMessage: snapshot.error.toString());
                } else {
                  return Expanded(
                    child: AlignedGridView.count(
                        padding: const EdgeInsets.all(20),
                        crossAxisCount:
                            MediaQuery.of(context).size.width >= 700 ? 2 : 1,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        itemCount: 8,
                        itemBuilder: (BuildContext context, int index) {
                          return Container(
                            constraints: const BoxConstraints(
                                maxHeight: 160, minHeight: 100),
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  gridPosition = index;
                                });
                                cardSelectDialog(context);
                              },
                              style: ButtonStyle(
                                shape: WidgetStateProperty.all<
                                    RoundedRectangleBorder>(
                                  RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18.0),
                                  ),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.only(
                                    top: 8.0, left: 8.0, bottom: 6.0),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.nfc,
                                            color: enabledSlots[index].any()
                                                ? Colors.green
                                                : Colors.deepOrange),
                                        const SizedBox(width: 5),
                                        Expanded(
                                          child: Text(
                                            "${localizations.slot} ${index + 1}",
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 20),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.start,
                                      children: [
                                        const Icon(Icons.credit_card),
                                        const SizedBox(width: 5),
                                        Expanded(
                                            child: Text(
                                          "${slotData[index].hf} (${chameleonTagToString(usedSlots[index].hf, localizations)})",
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ))
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.start,
                                            children: [
                                              const Icon(Icons.wifi),
                                              const SizedBox(width: 5),
                                              Expanded(
                                                  child: Text(
                                                "${slotData[index].lf} (${chameleonTagToString(usedSlots[index].lf, localizations)})",
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                softWrap: true,
                                              ))
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () {
                                            showDialog(
                                              context: context,
                                              builder: (BuildContext context) {
                                                return SlotSettings(
                                                    slot: index,
                                                    refresh: refreshSlot);
                                              },
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
                        }),
                  );
                }
              },
            ),
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
            ]
          ],
        ),
      ),
    );
  }
}
