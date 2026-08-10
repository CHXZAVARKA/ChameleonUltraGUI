import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:chameleonultragui/helpers/write.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:flutter/services.dart';

class BaseMifareUltralightWriteHelper extends AbstractWriteHelper {
  HFCardInfo? hfInfo;
  List<int> failedBlocks = [];

  @override
  bool get autoDetect => false;

  @override
  String get name => "gen2";

  static String get staticName => "gen2";
  TextEditingController keyController = TextEditingController();
  String? key;

  BaseMifareUltralightWriteHelper(super.communicator,
      {required super.operationCanContinue});

  @override
  List<AbstractWriteHelper> getAvailableMethods() {
    return [
      BaseMifareUltralightWriteHelper(
        communicator,
        operationCanContinue: () => operationCanContinue,
      ),
    ];
  }

  @override
  List<AbstractWriteHelper> getAvailableMethodsByPriority() {
    return [
      BaseMifareUltralightWriteHelper(
        communicator,
        operationCanContinue: () => operationCanContinue,
      )
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
                    controller: keyController,
                    decoration: InputDecoration(
                        labelText: localizations.key,
                        hintMaxLines: 4,
                        hintText: localizations.enter_something(
                            localizations.ultralight_key_prompt)),
                    inputFormatters: hexFormatter,
                    validator: (value) => validateHex(value, localizations,
                        exactBytes: 4, fieldName: localizations.key),
                  )
                ],
              ))),
      TextButton(
        onPressed: () => {
          setState(() {
            key = keyController.text;
          })
        },
        child: Text(localizations.next),
      ),
      TextButton(
        onPressed: () => {
          setState(() {
            key = "";
          })
        },
        child: Text(localizations.no_key),
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
    return key != null;
  }

  @override
  bool writeWidgetSupported() {
    return true;
  }

  @override
  Future<void> reset() async {
    failedBlocks = [];
    key = null;
  }

  @override
  Future<bool> writeData(
      CardSave card, Function(int writeProgress) update) async {
    if (!operationCanContinue) return false;
    int totalBlocks = card.data.length;

    if (!await communicator.isReaderDeviceMode()) {
      if (!operationCanContinue) return false;
      await communicator.setReaderDeviceMode(true);
    }
    if (!operationCanContinue) return false;

    if (await communicator.scan14443aTag() == null) {
      return false;
    }
    if (!operationCanContinue) return false;

    if (key!.isNotEmpty) {
      if (!operationCanContinue) return false;
      Uint8List pack = await communicator.send14ARaw(
          Uint8List.fromList([0x1B, ...hexToBytes(key!)]),
          keepRfField: true);
      if (!operationCanContinue || pack.length < 2) {
        return false;
      }
    }

    for (var pass = 0; pass < 2; pass++) {
      for (var block = 0; block < totalBlocks; block++) {
        if (!operationCanContinue) return false;
        if (card.data[block].isNotEmpty) {
          List<int> blockData = List.from(card.data[block]);

          if (pass == 0) {
            if (block == 2 && blockData.length >= 4) {
              blockData[2] = 0x00;
              blockData[3] = 0x00;
            }

            if (block == 3) {
              blockData = Uint8List(4);
            }
          } else if (![2, 3].contains(block)) {
            continue;
          }

          Uint8List write = await communicator.send14ARaw(
              Uint8List.fromList([0xA2, block, ...blockData]),
              keepRfField: true,
              checkResponseCrc: false,
              autoSelect: block == 0 || block == 3);
          if (!operationCanContinue) return false;
          if (write.length != 1 || write.single != 0x0A) {
            return false;
          }

          if (block == 2) {
            await communicator.send14ARaw(Uint8List(1)); // reset
            if (!operationCanContinue) return false;

            if (key!.isNotEmpty) {
              await communicator.send14ARaw(
                  Uint8List.fromList([0x1B, ...hexToBytes(key!)]),
                  keepRfField: true);
              if (!operationCanContinue) return false;
            }
          }

          if (!operationCanContinue) return false;
          update((block / (totalBlocks + 2) * 100).round());
        }
      }
    }

    return operationCanContinue && failedBlocks.isEmpty;
  }

  @override
  List<int> getFailedBlocks() {
    return failedBlocks;
  }
}
