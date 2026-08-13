import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
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
    final supported = isMifareClassic(card.tag) ||
        isEM410X(card.tag) ||
        card.tag == TagType.hidProx ||
        card.tag == TagType.viking ||
        card.tag == TagType.pac ||
        card.tag == TagType.ioProx ||
        card.tag == TagType.idteck ||
        isMifareUltralight(card.tag);
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
