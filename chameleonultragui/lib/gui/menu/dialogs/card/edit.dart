import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:flutter/material.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/gui/component/generated_card_identity_fields.dart';
import 'package:chameleonultragui/helpers/card_generator.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class CardEditMenu extends StatefulWidget {
  final CardSave tagSave;
  final bool isNew;

  const CardEditMenu({super.key, required this.tagSave, this.isNew = false});

  @override
  CardEditMenuState createState() => CardEditMenuState();
}

class CardEditMenuState extends State<CardEditMenu> {
  TagType selectedType = TagType.unknown;
  TextEditingController nameController = TextEditingController();
  TextEditingController uidController = TextEditingController();
  TextEditingController sakController = TextEditingController();
  TextEditingController atqaController = TextEditingController();
  TextEditingController atsController = TextEditingController();

  TextEditingController ultralightVersionController = TextEditingController();
  TextEditingController ultralightSignatureController = TextEditingController();
  List<TextEditingController> ultralightCounterControllers = [];

  TextEditingController hidTypeController = TextEditingController();
  TextEditingController facilityCodeController = TextEditingController();
  TextEditingController issueLevelController = TextEditingController();
  TextEditingController oemController = TextEditingController();

  Color pickerColor = Colors.deepOrange;
  Color currentColor = Colors.deepOrange;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final CardIdentityControllers identityControllers;

  String originalUid = '';
  String originalSak = '';
  String originalAtqa = '';
  bool _generatedWholeCard = false;

  @override
  void initState() {
    super.initState();
    identityControllers = CardIdentityControllers(
      uid: uidController,
      sak: sakController,
      atqa: atqaController,
      ats: atsController,
      ultralightVersion: ultralightVersionController,
      ultralightSignature: ultralightSignatureController,
      hidType: hidTypeController,
      facilityCode: facilityCodeController,
      issueLevel: issueLevelController,
      oem: oemController,
    );
    selectedType = widget.tagSave.tag;
    uidController.text = widget.tagSave.uid;
    sakController.text = bytesToHexSpace(u8ToBytes(widget.tagSave.sak));
    atqaController.text = bytesToHexSpace(widget.tagSave.atqa);
    atsController.text = bytesToHexSpace(widget.tagSave.ats);
    ultralightVersionController.text =
        bytesToHexSpace(widget.tagSave.extraData.ultralightVersion);
    ultralightSignatureController.text =
        bytesToHexSpace(widget.tagSave.extraData.ultralightSignature);

    initCounterControllers();

    if (selectedType == TagType.hidProx) {
      initHIDFields();
    }

    nameController.text = widget.tagSave.name;
    pickerColor = widget.tagSave.color;
    currentColor = widget.tagSave.color;

    originalUid = widget.tagSave.uid;
    originalSak = bytesToHexSpace(u8ToBytes(widget.tagSave.sak));
    originalAtqa = bytesToHexSpace(widget.tagSave.atqa);
  }

  bool hasDataChanged() {
    return uidController.text != originalUid ||
        sakController.text != originalSak ||
        atqaController.text != originalAtqa;
  }

  Future<bool> showUpdateDataDialog(BuildContext context) async {
    final localizations = AppLocalizations.of(context)!;

    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text(localizations.update_data_title),
              content: Text(localizations.update_data_message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(localizations.no),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(localizations.yes),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  List<Uint8List> updateSavedCardData({
    required TagType selectedType,
    required String uid,
    required String sak,
    required String atqa,
    required List<Uint8List> originalData,
  }) {
    if (originalData.isEmpty) {
      return originalData;
    }

    List<Uint8List> updatedData = List<Uint8List>.from(originalData);

    if (isMifareClassic(selectedType)) {
      updatedData[0] = mfClassicGenerateFirstBlock(
          hexToBytes(uid), hexToBytes(sak)[0], hexToBytes(atqa));
    } else if (isMifareUltralight(selectedType)) {
      final newBlocks =
          mfUltralightGenerateFirstBlocks(hexToBytes(uid), selectedType);

      for (int i = 0; i < newBlocks.length && i < updatedData.length; i++) {
        updatedData[i] = newBlocks[i];
      }
    }

    return updatedData;
  }

  bool canUpdateSavedCardData(CardSave tagSave, TagType selectedType) {
    if (!(isMifareClassic(selectedType) || isMifareUltralight(selectedType))) {
      return false;
    }

    return tagSave.data.isNotEmpty;
  }

  void initCounterControllers() {
    ultralightCounterControllers.clear();
    int counterCount = mfUltralightGetCounterCount(selectedType);

    for (int i = 0; i < counterCount; i++) {
      TextEditingController controller = TextEditingController();
      if (i < widget.tagSave.extraData.ultralightCounters.length) {
        controller.text =
            widget.tagSave.extraData.ultralightCounters[i].toString();
      } else {
        controller.text = '0';
      }
      ultralightCounterControllers.add(controller);
    }
  }

  void initHIDFields() {
    HIDCard hidCard = HIDCard.fromUID(widget.tagSave.uid);
    uidController.text = bytesToHexSpace(hidCard.uid);
    hidTypeController.text = hidCard.hidType.toString();
    facilityCodeController.text = hidCard.facilityCode.toString();
    issueLevelController.text = hidCard.issueLevel.toString();
    oemController.text = hidCard.oem.toString();
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(localizations.edit_card),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            children: [
              TextFormField(
                controller: nameController,
                validator: (value) => validateName(value, localizations),
                decoration: InputDecoration(
                    labelText: localizations.name,
                    hintText: localizations.enter_name_of_card,
                    prefix: Transform(
                        transform: Matrix4.translationValues(0, 7, 0),
                        child: IconButton(
                          icon: Icon(
                              (chameleonTagToFrequency(widget.tagSave.tag) ==
                                      TagFrequency.hf)
                                  ? Icons.credit_card
                                  : Icons.wifi,
                              color: currentColor),
                          onPressed: () async {
                            showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return AlertDialog(
                                  title: Text(localizations.pick_color),
                                  content: SingleChildScrollView(
                                    child: ColorPicker(
                                      pickerColor: pickerColor,
                                      onColorChanged: (Color color) {
                                        setState(() {
                                          pickerColor = color;
                                        });
                                      },
                                      pickerAreaHeightPercent: 0.8,
                                    ),
                                  ),
                                  actions: <Widget>[
                                    TextButton(
                                      onPressed: () {
                                        setState(() => currentColor =
                                            pickerColor = Colors.deepOrange);
                                        Navigator.pop(context);
                                      },
                                      child: Text(localizations.reset_default),
                                    ),
                                    TextButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                      },
                                      child: Text(localizations.cancel),
                                    ),
                                    TextButton(
                                      child: Text(localizations.ok),
                                      onPressed: () {
                                        setState(
                                            () => currentColor = pickerColor);
                                        Navigator.pop(context);
                                      },
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        ))),
              ),
              const SizedBox(height: 8),
              DropdownButton<TagType>(
                value: selectedType,
                items: getTagTypes()
                    .map<DropdownMenuItem<TagType>>((TagType type) {
                  return DropdownMenuItem<TagType>(
                    value: type,
                    child: Text(
                      chameleonTagToString(type, localizations),
                    ),
                  );
                }).toList(),
                onChanged: (TagType? newValue) {
                  if (newValue! != TagType.unknown) {
                    setState(() {
                      selectedType = newValue;
                      initCounterControllers();
                    });
                  }
                  appState.changesMade();
                },
              ),
              GeneratedCardIdentityFields(
                type: selectedType,
                controllers: identityControllers,
                ultralightCounters: ultralightCounterControllers,
                onFullProfileApplied: (_) {
                  setState(() => _generatedWholeCard = true);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: Text(localizations.cancel),
        ),
        TextButton(
          onPressed: () async {
            if (!_formKey.currentState!.validate()) {
              return;
            }

            List<Uint8List> cardData = widget.tagSave.data;

            if (_generatedWholeCard) {
              cardData = generateBlankCardData(
                type: selectedType,
                uid: hexToBytes(uidController.text),
                sak: chameleonTagToFrequency(selectedType) == TagFrequency.lf
                    ? 0
                    : hexToBytes(sakController.text)[0],
                atqa: hexToBytes(atqaController.text),
              );
            } else if (hasDataChanged() &&
                canUpdateSavedCardData(widget.tagSave, selectedType)) {
              bool shouldUpdateData = await showUpdateDataDialog(context);
              if (shouldUpdateData) {
                cardData = updateSavedCardData(
                  selectedType: selectedType,
                  uid: uidController.text,
                  sak: sakController.text,
                  atqa: atqaController.text,
                  originalData: widget.tagSave.data,
                );
              }
            }

            String finalUid;
            if (selectedType == TagType.hidProx) {
              try {
                int hidType = int.parse(hidTypeController.text);
                int facilityCode = int.parse(facilityCodeController.text);
                int issueLevel = int.parse(issueLevelController.text);
                int oem = int.parse(oemController.text);

                Uint8List uid =
                    hexToBytes(uidController.text.replaceAll(' ', ''));

                HIDCard hidCard = HIDCard(
                  hidType: hidType,
                  facilityCode: facilityCode,
                  uid: uid,
                  issueLevel: issueLevel,
                  oem: oem,
                );

                finalUid = hidCard.toString();
              } catch (e) {
                finalUid = bytesToHexSpace(hexToBytes(uidController.text));
              }
            } else {
              finalUid = bytesToHexSpace(hexToBytes(uidController.text));
            }

            var tag = CardSave(
                folderId: widget.tagSave.folderId,
                id: widget.tagSave.id,
                name: nameController.text,
                sak: chameleonTagToFrequency(selectedType) == TagFrequency.lf
                    ? widget.tagSave.sak
                    : hexToBytes(sakController.text)[0],
                atqa: hexToBytes(atqaController.text),
                uid: finalUid,
                extraData: CardSaveExtra(
                  mifareClassicDumpComplete:
                      _generatedWholeCard && isMifareClassic(selectedType)
                          ? true
                          : isMifareClassic(selectedType)
                              ? false
                              : null,
                  ultralightSignature:
                      hexToBytes(ultralightSignatureController.text),
                  ultralightVersion:
                      hexToBytes(ultralightVersionController.text),
                  ultralightCounters: ultralightCounterControllers
                      .map((controller) => int.tryParse(controller.text) ?? 0)
                      .toList(),
                ),
                tag: selectedType,
                data: cardData,
                color: currentColor,
                ats: hexToBytes(atsController.text));

            var tags = appState.sharedPreferencesProvider.getCards();
            var index =
                tags.indexWhere((element) => element.id == widget.tagSave.id);

            if (index != -1) {
              tags[index] = tag;
            }

            appState.sharedPreferencesProvider.setCards(tags);
            appState.changesMade();
            if (context.mounted) {
              Navigator.pop(context);
            }
          },
          child: Text(localizations.save),
        ),
      ],
    );
  }
}
