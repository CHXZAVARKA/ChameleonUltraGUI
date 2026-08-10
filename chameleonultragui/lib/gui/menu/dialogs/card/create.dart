import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:flutter/material.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:chameleonultragui/gui/component/generated_card_identity_fields.dart';
import 'package:chameleonultragui/helpers/card_generator.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class CardCreateMenu extends StatefulWidget {
  final String? folderId;

  const CardCreateMenu({super.key, this.folderId});

  @override
  CardCreateMenuState createState() => CardCreateMenuState();
}

class CardCreateMenuState extends State<CardCreateMenu> {
  TagType selectedType = TagType.mifare1K;
  TextEditingController nameController = TextEditingController();
  TextEditingController uidController = TextEditingController();
  TextEditingController sakController = TextEditingController();
  TextEditingController atqaController = TextEditingController();
  TextEditingController atsController = TextEditingController();

  TextEditingController ultralightVersionController = TextEditingController();
  TextEditingController ultralightSignatureController = TextEditingController();
  List<TextEditingController> ultralightCounterControllers = [];

  TextEditingController hidTypeController = TextEditingController(text: '1');
  TextEditingController facilityCodeController = TextEditingController();
  TextEditingController issueLevelController = TextEditingController();
  TextEditingController oemController = TextEditingController();

  Color pickerColor = Colors.deepOrange;
  Color currentColor = Colors.deepOrange;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final CardIdentityControllers identityControllers;

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
    _resetCounterControllers();
  }

  void _resetCounterControllers() {
    for (final controller in ultralightCounterControllers) {
      controller.dispose();
    }
    ultralightCounterControllers = List.generate(
      mfUltralightGetCounterCount(selectedType),
      (_) => TextEditingController(text: '0'),
    );
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(localizations.create_card),
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
                              (chameleonTagToFrequency(selectedType) ==
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
                items: [
                  ...getTagTypesByFrequency(TagFrequency.hf),
                  ...getTagTypesByFrequency(TagFrequency.lf)
                ].map<DropdownMenuItem<TagType>>((TagType type) {
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
                      _resetCounterControllers();
                    });
                  }
                  appState.changesMade();
                },
              ),
              GeneratedCardIdentityFields(
                type: selectedType,
                controllers: identityControllers,
                ultralightCounters: ultralightCounterControllers,
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
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }

            String finalUid;
            if (selectedType == TagType.hidProx) {
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
            } else {
              finalUid = bytesToHexSpace(hexToBytes(uidController.text));
            }

            final sak = chameleonTagToFrequency(selectedType) == TagFrequency.lf
                ? 0
                : hexToBytes(sakController.text)[0];
            final atqa =
                chameleonTagToFrequency(selectedType) == TagFrequency.lf
                    ? Uint8List(0)
                    : hexToBytes(atqaController.text);
            final ats = chameleonTagToFrequency(selectedType) == TagFrequency.lf
                ? Uint8List(0)
                : hexToBytes(atsController.text);

            final blocks = generateBlankCardData(
              type: selectedType,
              uid: hexToBytes(uidController.text),
              sak: sak,
              atqa: atqa,
            );

            var tag = CardSave(
                name: nameController.text,
                sak: sak,
                atqa: atqa,
                uid: finalUid,
                extraData: CardSaveExtra(
                  mifareClassicDumpComplete:
                      isMifareClassic(selectedType) ? true : null,
                  ultralightSignature:
                      hexToBytes(ultralightSignatureController.text),
                  ultralightVersion:
                      hexToBytes(ultralightVersionController.text),
                  ultralightCounters: ultralightCounterControllers
                      .map((controller) => int.parse(controller.text))
                      .toList(),
                ),
                tag: selectedType,
                data: blocks,
                folderId: widget.folderId,
                color: currentColor,
                ats: ats);

            var tags = appState.sharedPreferencesProvider.getCards();
            tags.add(tag);

            appState.sharedPreferencesProvider.setCards(tags);
            appState.changesMade();
            Navigator.pop(context);
          },
          child: Text(localizations.create),
        ),
      ],
    );
  }
}
