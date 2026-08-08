import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/error_message.dart';
import 'package:chameleonultragui/helpers/card_info.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

enum MifareUltralightState { none, read, save }

class MifareUltralightHelper extends StatefulWidget {
  final HFCardInfo hfInfo;
  final bool allowSave;

  const MifareUltralightHelper(
      {super.key, required this.hfInfo, this.allowSave = true});

  @override
  State<StatefulWidget> createState() => CardReaderState();
}

class CardReaderState extends State<MifareUltralightHelper> {
  TextEditingController keyController = TextEditingController();
  MifareUltralightState state = MifareUltralightState.none;
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  List<Uint8List> cardData = [];
  String version = "";
  String signature = "";
  List<int> counters = [];
  String dumpName = "";
  String error = "";
  double progress = -1;

  Future<void> readCard({bool withPassword = false}) async {
    final appState = context.read<ChameleonGUIState>();
    final localizations = AppLocalizations.of(context)!;
    final session = ConnectedDeviceSession.capture(appState);
    if (session == null) {
      return;
    }
    final password = keyController.text;
    final pageCount = mfUltralightGetPagesCount(widget.hfInfo.type);

    setState(() {
      cardData = [];
      error = "";
      state = MifareUltralightState.read;
    });

    await appState.rfOperations.runForeground(() async {
      bool canContinue() => mounted && session.isCurrent;
      if (!canContinue()) {
        return;
      }

      final communicator = session.communicator;
      final nextCardData = <Uint8List>[];
      Uint8List? pack;
      for (var page = 0; page < pageCount; page++) {
        if (withPassword) {
          pack = await communicator.send14ARaw(
            Uint8List.fromList([0x1B, ...hexToBytes(password)]),
            keepRfField: true,
          );
          if (!canContinue()) {
            return;
          }
          if (pack.length < 2) {
            setState(() {
              state = MifareUltralightState.none;
              error = localizations.invalid_password;
            });
            return;
          }
        }

        final pageData = await communicator.send14ARaw(
          Uint8List.fromList([0x30, page]),
        );
        if (!canContinue()) {
          return;
        }
        nextCardData.add(pageData.isNotEmpty
            ? Uint8List.fromList(pageData.slice(0, 4).toList())
            : Uint8List(0));
        setState(() {
          progress = page / pageCount;
        });
      }

      if (!nextCardData.any((block) => block.isNotEmpty)) {
        setState(() {
          progress = 0;
          cardData = [];
          error = localizations.failed_to_read_block;
          state = MifareUltralightState.none;
        });
        return;
      }

      final nextVersion = await mfUltralightGetVersion(communicator);
      if (!canContinue()) {
        return;
      }
      final nextSignature = await mfUltralightGetSignature(communicator);
      if (!canContinue()) {
        return;
      }

      var nextCounters = <int>[];
      if (mfUltralightHasCounters(widget.hfInfo.type)) {
        nextCounters = await mfUltralightReadAllCountersFromCard(
          communicator,
          widget.hfInfo.type,
          canContinue: canContinue,
        );
        if (!canContinue()) {
          return;
        }
      }

      final passwordPage = mfUltralightGetPasswordPage(widget.hfInfo.type);
      if (passwordPage != 0 && withPassword) {
        nextCardData[passwordPage] = hexToBytes(password);
        nextCardData[passwordPage + 1] = Uint8List(4);
        for (var byte = 0; byte < pack!.length; byte++) {
          nextCardData[passwordPage + 1][byte] = pack[byte];
        }
      }

      setState(() {
        cardData = nextCardData;
        version = bytesToHexSpace(nextVersion);
        signature = bytesToHexSpace(nextSignature);
        counters = nextCounters;
        error = "";
        state = MifareUltralightState.save;
      });
    });
  }

  Future<void> saveCard({bool bin = false}) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    List<int> cardDump = [];
    var localizations = AppLocalizations.of(context)!;
    for (var page = 0;
        page < mfUltralightGetPagesCount(widget.hfInfo.type);
        page++) {
      if (cardData[page].isEmpty) {
        cardDump.addAll(Uint8List(4));
      } else {
        cardDump.addAll(cardData[page]);
      }
    }

    if (bin) {
      await FilePicker.saveFile(
        dialogTitle: '${localizations.output_file}:',
        fileName: '${widget.hfInfo.uid.replaceAll(" ", "")}.bin',
        bytes: Uint8List.fromList(cardDump),
      );
    } else {
      var tags = appState.sharedPreferencesProvider.getCards();
      tags.add(CardSave(
          uid: widget.hfInfo.uid,
          sak: hexToBytes(widget.hfInfo.sak)[0],
          atqa: hexToBytes(widget.hfInfo.atqa),
          name: dumpName,
          tag: widget.hfInfo.type,
          data: cardData,
          extraData: CardSaveExtra(
            ultralightSignature: hexToBytes(signature),
            ultralightVersion: hexToBytes(version),
            ultralightCounters: counters,
          ),
          ats: (widget.hfInfo.ats != localizations.no)
              ? hexToBytes(widget.hfInfo.ats)
              : Uint8List(0)));
      appState.sharedPreferencesProvider.setCards(tags);
    }
  }

  @override
  Widget build(BuildContext context) {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    var localizations = AppLocalizations.of(context)!;

    return Column(
      children: [
        const SizedBox(height: 16),
        if (state == MifareUltralightState.none) ...[
          Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: TextFormField(
              controller: keyController,
              decoration: InputDecoration(
                  labelText: localizations.key,
                  hintMaxLines: 4,
                  hintText: localizations
                      .enter_something(localizations.ultralight_key_prompt)),
              inputFormatters: hexFormatter,
              validator: (value) => validateHex(value, localizations,
                  exactBytes: 4, fieldName: localizations.key),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: () async => {await readCard(withPassword: true)},
                child: Text(localizations.read_with_key),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () async => {await readCard(withPassword: false)},
                child: Text(localizations.read_without_key),
              ),
            ),
          ]),
        ],
        if (error != "") ...[
          const SizedBox(height: 16),
          ErrorMessage(errorMessage: error),
        ],
        if (state == MifareUltralightState.read) ...[
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8)
        ],
        if (state == MifareUltralightState.save)
          Center(
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                ElevatedButton(
                  onPressed: () async {
                    await showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          title: Text(localizations.enter_name_of_card),
                          content: TextField(
                            onChanged: (value) {
                              setState(() {
                                dumpName = value;
                              });
                            },
                          ),
                          actions: [
                            ElevatedButton(
                              onPressed: () async {
                                await saveCard();
                                if (context.mounted) {
                                  Navigator.pop(context);
                                }
                              },
                              child: Text(localizations.ok),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                Navigator.pop(
                                    context); // Close the modal without saving
                              },
                              child: Text(localizations.cancel),
                            ),
                          ],
                        );
                      },
                    );
                  },
                  style: customCardButtonStyle(appState),
                  child: Text(localizations.save),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    await saveCard(bin: true);
                  },
                  style: customCardButtonStyle(appState),
                  child: Text(localizations.save_as(".bin")),
                ),
              ])),
      ],
    );
  }
}
