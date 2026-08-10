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
  Object? _readOperation;
  ChameleonGUIState? _appState;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = context.read<ChameleonGUIState>();
    if (_appState != null && !identical(_appState, appState)) {
      _cancelReadForLifecycleChange();
    }
    _appState = appState;
  }

  @override
  void didUpdateWidget(covariant MifareUltralightHelper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.hfInfo, widget.hfInfo)) {
      _cancelReadForLifecycleChange();
    }
  }

  void _cancelReadForLifecycleChange() {
    _readOperation = null;
    state = MifareUltralightState.none;
    cardData = [];
    version = '';
    signature = '';
    counters = [];
    dumpName = '';
    progress = -1;
    error = '';
    keyController.clear();
  }

  void _restoreCanceledRead(Object operation) {
    if (!identical(_readOperation, operation) ||
        state != MifareUltralightState.read) {
      return;
    }

    void restore() {
      if (!identical(_readOperation, operation) ||
          state != MifareUltralightState.read) {
        return;
      }
      _readOperation = null;
      state = MifareUltralightState.none;
      progress = -1;
    }

    if (mounted) {
      setState(restore);
    } else {
      restore();
    }
  }

  Future<void> readCard({bool withPassword = false}) async {
    final appState = _appState ?? context.read<ChameleonGUIState>();
    final localizations = AppLocalizations.of(context)!;
    final hfInfo = widget.hfInfo;
    final type = hfInfo.type;
    final password = keyController.text;
    final pageCount = mfUltralightGetPagesCount(type);
    final operation = Object();

    setState(() {
      _readOperation = operation;
      cardData = [];
      error = "";
      state = MifareUltralightState.read;
    });

    final result =
        await appState.runSessionBoundForegroundCatching((session) async {
      bool canContinue() =>
          mounted &&
          identical(_appState, appState) &&
          identical(widget.hfInfo, hfInfo) &&
          identical(_readOperation, operation) &&
          session.isCurrent;
      bool canceled() {
        if (canContinue()) {
          return false;
        }
        _restoreCanceledRead(operation);
        return true;
      }

      if (canceled()) {
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
          if (canceled()) {
            return;
          }
          if (pack.length < 2) {
            setState(() {
              _readOperation = null;
              state = MifareUltralightState.none;
              error = localizations.invalid_password;
            });
            return;
          }
        }

        final pageData = await communicator.send14ARaw(
          Uint8List.fromList([0x30, page]),
        );
        if (canceled()) {
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
          _readOperation = null;
          state = MifareUltralightState.none;
        });
        return;
      }

      final nextVersion = await mfUltralightGetVersion(communicator);
      if (canceled()) {
        return;
      }
      final nextSignature = await mfUltralightGetSignature(communicator);
      if (canceled()) {
        return;
      }

      var nextCounters = <int>[];
      if (mfUltralightHasCounters(type)) {
        nextCounters = await mfUltralightReadAllCountersFromCard(
          communicator,
          type,
          canContinue: canContinue,
        );
        if (canceled()) {
          return;
        }
      }

      final passwordPage = mfUltralightGetPasswordPage(type);
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
        _readOperation = null;
        state = MifareUltralightState.save;
      });
    });
    if (!result.executed) {
      _restoreCanceledRead(operation);
      return;
    }
    if (result.error != null) {
      final session = result.session;
      final isCurrentFailure = session != null &&
          mounted &&
          identical(_appState, appState) &&
          identical(widget.hfInfo, hfInfo) &&
          identical(_readOperation, operation) &&
          session.isCurrent;
      if (!isCurrentFailure) {
        _restoreCanceledRead(operation);
        return;
      }

      (appState.log ?? session.communicator.log)
          .e('MIFARE Ultralight read failed');
      setState(() {
        _readOperation = null;
        state = MifareUltralightState.none;
        progress = -1;
        error = localizations.error;
      });
    }
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
