import 'dart:async';

import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
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
  int progress = -1;
  int gridPosition = 0;
  bool onlyOneSlot = false;
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

  void refreshSlot() {
    setUploadState(-1);
    final status = _status;
    if (status != null) {
      unawaited(status.refreshSlots());
    }
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

    if (isMifareClassic(card.tag)) {
      close(context, card.name);
      setUploadState(0);
      var isEV1 = chameleonTagSaveCheckForMifareClassicEV1(card);
      if (isEV1) {
        card.tag = TagType.mifare2K;
      }

      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.hf, true);
      await appState.communicator!.activateSlot(gridPosition);
      await appState.communicator!.setSlotType(gridPosition, card.tag);
      await appState.communicator!.setDefaultDataToSlot(gridPosition, card.tag);
      var cardData = CardData(
          uid: hexToBytes(card.uid),
          atqa: card.atqa,
          sak: card.sak,
          ats: card.ats);
      await appState.communicator!.setMf1AntiCollision(cardData);

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
            await appState.communicator!
                .setMf1BlockData(lastSend, Uint8List.fromList(blockChunk));
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
      }

      if (blockChunk.isNotEmpty) {
        await appState.communicator!
            .setMf1BlockData(lastSend, Uint8List.fromList(blockChunk));
      }

      setUploadState(100);

      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.hf);
      await appState.communicator!.saveSlotData();
      appState.changesMade();
      refreshSlot();
    } else if (isEM410X(card.tag)) {
      close(context, card.name);
      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.lf, true);
      await appState.communicator!.activateSlot(gridPosition);
      TagType slotTagType = card.tag == TagType.em410XElectra
          ? TagType.em410XElectra
          : TagType.em410X;
      await appState.communicator!.setSlotType(gridPosition, slotTagType);
      await appState.communicator!
          .setDefaultDataToSlot(gridPosition, slotTagType);
      await appState.communicator!.setEM410XEmulatorID(hexToBytes(card.uid));
      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf);
      await appState.communicator!.saveSlotData();
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.hidProx) {
      close(context, card.name);
      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.lf, true);
      await appState.communicator!.activateSlot(gridPosition);
      await appState.communicator!.setSlotType(gridPosition, card.tag);
      await appState.communicator!.setDefaultDataToSlot(gridPosition, card.tag);
      await appState.communicator!.setHIDProxEmulatorID(
          hexToBytes(HIDCard.fromUID(card.uid).toString()));
      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf);
      await appState.communicator!.saveSlotData();
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.viking) {
      close(context, card.name);
      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.lf, true);
      await appState.communicator!.activateSlot(gridPosition);
      await appState.communicator!.setSlotType(gridPosition, card.tag);
      await appState.communicator!.setDefaultDataToSlot(gridPosition, card.tag);
      await appState.communicator!.setVikingEmulatorID(hexToBytes(card.uid));
      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf);
      await appState.communicator!.saveSlotData();
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.pac) {
      close(context, card.name);
      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.lf, true);
      await appState.communicator!.activateSlot(gridPosition);
      await appState.communicator!.setSlotType(gridPosition, card.tag);
      await appState.communicator!.setDefaultDataToSlot(gridPosition, card.tag);
      await appState.communicator!.setPacEmulatorID(hexToBytes(card.uid));
      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf);
      await appState.communicator!.saveSlotData();
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.ioProx) {
      close(context, card.name);
      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.lf, true);
      await appState.communicator!.activateSlot(gridPosition);
      await appState.communicator!.setSlotType(gridPosition, card.tag);
      await appState.communicator!.setDefaultDataToSlot(gridPosition, card.tag);
      await appState.communicator!.setIoProxEmulatorID(hexToBytes(card.uid));
      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf);
      await appState.communicator!.saveSlotData();
      appState.changesMade();
      refreshSlot();
    } else if (card.tag == TagType.idteck) {
      close(context, card.name);
      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.lf, true);
      await appState.communicator!.activateSlot(gridPosition);
      await appState.communicator!.setSlotType(gridPosition, card.tag);
      await appState.communicator!.setDefaultDataToSlot(gridPosition, card.tag);
      await appState.communicator!.setIdteckEmulatorID(hexToBytes(card.uid));
      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.lf);
      await appState.communicator!.saveSlotData();
      appState.changesMade();
      refreshSlot();
    } else if (isMifareUltralight(card.tag)) {
      close(context, card.name);
      setUploadState(0);

      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!
          .enableSlot(gridPosition, TagFrequency.hf, true);
      await appState.communicator!.activateSlot(gridPosition);
      await appState.communicator!.setSlotType(gridPosition, card.tag);
      await appState.communicator!.setDefaultDataToSlot(gridPosition, card.tag);
      var cardData = CardData(
          uid: hexToBytes(card.uid),
          atqa: card.atqa,
          sak: card.sak,
          ats: card.ats);
      await appState.communicator!.setMf1AntiCollision(cardData);

      for (var page = 0;
          page < mfUltralightGetPagesCount(card.tag) && card.data.length > page;
          page++) {
        await appState.communicator!
            .mf0EmulatorWritePages(page, card.data[page]);

        setUploadState(
            (page / mfUltralightGetPagesCount(card.tag) * 100).round());

        await asyncSleep(1);
      }

      if (card.extraData.ultralightVersion.isNotEmpty) {
        await appState.communicator!
            .mf0EmulatorSetVersionData(card.extraData.ultralightVersion);
      }

      if (card.extraData.ultralightSignature.isNotEmpty) {
        await appState.communicator!
            .mf0EmulatorSetSignatureData(card.extraData.ultralightSignature);
      }

      if (card.extraData.ultralightCounters.isNotEmpty) {
        for (int i = 0; i < card.extraData.ultralightCounters.length; i++) {
          await appState.communicator!.mf0EmulatorSetCounterData(
              i, card.extraData.ultralightCounters[i], true);
        }
      }

      if (mfUltralightHasCounters(card.tag)) {
        await appState.communicator!.mf0ResetAuthCount();
      }

      setUploadState(100);

      await appState.communicator!.setSlotTagName(
          gridPosition,
          (card.name.isEmpty) ? localizations.no_name : card.name,
          TagFrequency.hf);
      await appState.communicator!.saveSlotData();
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
    var localizations = AppLocalizations.of(context)!;
    final status = _status;

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.slot_manager),
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
          constraints: const BoxConstraints(maxHeight: 160, minHeight: 100),
          child: ElevatedButton(
            onPressed: progress == -1
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
                              refresh: refreshSlot,
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
