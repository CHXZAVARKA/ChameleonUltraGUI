import 'package:chameleonultragui/helpers/card_info.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:chameleonultragui/helpers/write.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:flutter/services.dart';

class BaseT55XXCardHelper extends AbstractWriteHelper {
  LFCardInfo? lfInfo;

  @override
  bool get autoDetect => true;

  @override
  String get name => "t55xx";

  static String get staticName => "t55xx";
  TextEditingController newKeyController = TextEditingController();
  TextEditingController currentKeyController = TextEditingController();
  String currentKey = "";
  String newKey = "";

  BaseT55XXCardHelper(super.communicator,
      {required super.operationCanContinue});

  @override
  List<AbstractWriteHelper> getAvailableMethods() {
    return [
      inheritOperationContinuation(BaseT55XXCardHelper(
        communicator,
        operationCanContinue: () => operationCanContinue,
      )),
    ];
  }

  @override
  List<AbstractWriteHelper> getAvailableMethodsByPriority() {
    return [
      inheritOperationContinuation(BaseT55XXCardHelper(
        communicator,
        operationCanContinue: () => operationCanContinue,
      ))
    ];
  }

  @override
  Widget getWriteWidget(BuildContext context, setState) {
    var localizations = AppLocalizations.of(context)!;
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();

    return Row(children: [
      Expanded(
          child: Form(
              key: formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: Column(
                children: [
                  TextFormField(
                    controller: currentKeyController,
                    decoration: InputDecoration(
                        labelText: localizations.key,
                        hintMaxLines: 4,
                        hintText: localizations
                            .enter_something(localizations.t55xx_key_prompt)),
                    inputFormatters: hexFormatter,
                    validator: (value) => validateHex(value, localizations,
                        exactBytes: 4, fieldName: localizations.key),
                  ),
                  TextFormField(
                    controller: newKeyController,
                    decoration: InputDecoration(
                        labelText: localizations.new_key,
                        hintMaxLines: 4,
                        hintText: localizations.enter_something(
                            localizations.t55xx_new_key_prompt)),
                    inputFormatters: hexFormatter,
                    validator: (value) => validateHex(value, localizations,
                        exactBytes: 4, fieldName: localizations.key),
                  )
                ],
              ))),
      TextButton(
        onPressed: () => {
          if (newKeyController.text.isNotEmpty)
            {
              if (currentKeyController.text.isNotEmpty)
                {
                  setState(() {
                    currentKey = currentKeyController.text;
                    newKey = newKeyController.text;
                  })
                }
              else
                {
                  setState(() {
                    currentKey = "20206666";
                    newKey = "20206666";
                  })
                }
            }
          else
            {
              if (currentKeyController.text.isNotEmpty)
                {
                  setState(() {
                    currentKey = currentKeyController.text;
                    newKey = currentKeyController.text;
                  })
                }
              else
                {
                  setState(() {
                    currentKey = "20206666";
                    newKey = "20206666";
                  })
                }
            }
        },
        child: Text(localizations.next),
      )
    ]);
  }

  @override
  Future<bool> isCompatible(CardSave card) async {
    return true;
  }

  @override
  Future<bool> isMagic(data) async {
    return false;
  }

  @override
  bool isReady() {
    return currentKey.length == 8 && newKey.length == 8;
  }

  @override
  bool writeWidgetSupported() {
    return true;
  }

  @override
  Future<void> reset() async {
    currentKey = "";
    newKey = "";
  }

  @override
  Future<bool> writeData(
      CardSave card, Function(int writeProgress) update) async {
    if (!operationCanContinue) return false;
    if (isEM410X(card.tag)) {
      await communicator.writeEM410XtoT55XX(hexToBytes(card.uid),
          hexToBytes(newKey), [hexToBytes(currentKey), Uint8List(4)]);
      if (!operationCanContinue) return false;
      // A write may have reached the tag. Keep only its safety read-back.
      await Future.delayed(const Duration(milliseconds: 500));
      if (!operationCanContinue) return false;
      var newCard = await communicator.readEM410X();
      return operationCanContinue && newCard.toString() == card.uid;
    } else if (card.tag == TagType.hidProx) {
      await communicator.writeHIDProxToT55XX(hexToBytes(card.uid),
          hexToBytes(newKey), [hexToBytes(currentKey), Uint8List(4)]);
      if (!operationCanContinue) return false;
      await Future.delayed(const Duration(milliseconds: 500));
      if (!operationCanContinue) return false;
      var newCard = await communicator.readHIDProx();
      return operationCanContinue && newCard.toString() == card.uid;
    } else if (card.tag == TagType.viking) {
      await communicator.writeVikingToT55XX(hexToBytes(card.uid),
          hexToBytes(newKey), [hexToBytes(currentKey), Uint8List(4)]);
      if (!operationCanContinue) return false;
      await Future.delayed(const Duration(milliseconds: 500));
      if (!operationCanContinue) return false;
      var newCard = await communicator.readViking();
      return operationCanContinue && newCard.toString() == card.uid;
    } else if (card.tag == TagType.pac) {
      await communicator.writePacToT55XX(hexToBytes(card.uid),
          hexToBytes(newKey), [hexToBytes(currentKey), Uint8List(4)]);
      if (!operationCanContinue) return false;
      var newCard = await communicator.readPac();
      return operationCanContinue && newCard.toString() == card.uid;
    } else if (card.tag == TagType.ioProx) {
      await communicator.writeIoProxToT55XX(hexToBytes(card.uid),
          hexToBytes(newKey), [hexToBytes(currentKey), Uint8List(4)]);
      if (!operationCanContinue) return false;
      await Future.delayed(const Duration(milliseconds: 500));
      if (!operationCanContinue) return false;
      var newCard = await communicator.readIoProx();
      return operationCanContinue && newCard.toString() == card.uid;
    } else if (card.tag == TagType.idteck) {
      await communicator.writeIdteckToT55XX(hexToBytes(card.uid),
          hexToBytes(newKey), [hexToBytes(currentKey), Uint8List(4)]);
      // IDTECK read is not implemented in the firmware (PSK demodulation
      // on the envelope-only tag-emulation ADC path is a follow-up), so we
      // cannot read back the tag for verification. Assume the T55xx write
      // succeeded if the firmware did not raise an error.
      return operationCanContinue;
    }

    return false;
  }
}
