import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/gui/component/error_page.dart';
import 'package:chameleonultragui/gui/component/toggle_buttons.dart';
import 'package:chameleonultragui/gui/menu/pages/mfkey32.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:flutter/material.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class _SlotOperationCanceled implements Exception {
  const _SlotOperationCanceled();
}

class SlotEditMenu extends StatefulWidget {
  final String name;
  final bool isEnabled;
  final TagType slotType;
  final TagFrequency frequency;
  final int slot;
  final dynamic update;

  const SlotEditMenu(
      {super.key,
      required this.name,
      required this.isEnabled,
      required this.slotType,
      required this.frequency,
      required this.slot,
      required this.update});

  @override
  SlotEditMenuState createState() => SlotEditMenuState();
}

class SlotEditMenuState extends State<SlotEditMenu> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
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

  TagType? selectedType;
  TagType previousTagType = TagType.unknown;
  EmulatorSettings? emulatorSettings;
  Mf1PrngType? mf1PrngType;
  int detectionCount = 0;

  @override
  void initState() {
    super.initState();
    selectedType = widget.slotType;
    nameController.text = widget.name;
  }

  String getMf1PrngLabel(Mf1PrngType type, AppLocalizations localizations) {
    switch (type) {
      case Mf1PrngType.static:
        return localizations.prng_type_static;
      case Mf1PrngType.weak:
        return localizations.prng_type_weak;
      case Mf1PrngType.hard:
        return localizations.prng_type_hard;
    }
  }

  bool _canContinue(ConnectedDeviceSession session) =>
      mounted && session.isCurrent;

  Future<T> _awaitTransport<T>(
    ConnectedDeviceSession session,
    Future<T> Function() operation,
  ) async {
    if (!_canContinue(session)) throw const _SlotOperationCanceled();
    final result = await operation();
    if (!_canContinue(session)) throw const _SlotOperationCanceled();
    return result;
  }

  Future<bool> _runSlotOperation(
    Future<void> Function(ConnectedDeviceSession session) operation,
  ) async {
    final appState = context.read<ChameleonGUIState>();
    final result = await appState.runSessionBoundForeground((session) async {
      try {
        if (!_canContinue(session)) return false;
        await operation(session);
        return _canContinue(session);
      } on _SlotOperationCanceled {
        return false;
      }
    });
    return result.executed && result.value == true;
  }

  Future<bool> _runCommand(
    Future<void> Function(ChameleonCommunicator communicator) command,
  ) {
    return _runSlotOperation((session) async {
      await _awaitTransport(
        session,
        () => command(session.communicator),
      );
    });
  }

  Future<T?> _runReadCommand<T>(
    Future<T> Function(ChameleonCommunicator communicator) command,
  ) async {
    T? value;
    final completed = await _runSlotOperation((session) async {
      value = await _awaitTransport(
        session,
        () => command(session.communicator),
      );
    });
    return completed ? value : null;
  }

  Future<void> updateInfo() async {
    if (previousTagType == selectedType ||
        isMifareClassic(previousTagType) && isMifareClassic(selectedType!)) {
      return;
    }
    await _runSlotOperation(_updateInfo);
  }

  Future<void> _updateInfo(ConnectedDeviceSession session) async {
    await _awaitTransport(
        session, () => session.communicator.activateSlot(widget.slot));

    if (isEM410X(selectedType!)) {
      try {
        uidController.text = bytesToHexSpace(await _awaitTransport(
            session, session.communicator.getEM410XEmulatorID));
      } catch (_) {}
    } else if (selectedType! == TagType.hidProx) {
      try {
        HIDCard hidCard = await _awaitTransport(
            session, session.communicator.getHIDProxEmulatorID);
        uidController.text = bytesToHexSpace(hidCard.uid);
        hidTypeController.text = hidCard.hidType.toString();
        facilityCodeController.text = hidCard.facilityCode.toString();
        issueLevelController.text = hidCard.issueLevel.toString();
        oemController.text = hidCard.oem.toString();
      } catch (_) {}
    } else if (selectedType! == TagType.viking) {
      try {
        VikingCard vikingCard = await _awaitTransport(
            session, session.communicator.getVikingEmulatorID);
        uidController.text = bytesToHexSpace(vikingCard.uid);
      } catch (_) {}
    } else if (selectedType! == TagType.pac) {
      try {
        PacCard pacCard = await _awaitTransport(
            session, session.communicator.getPacEmulatorID);
        uidController.text = bytesToHexSpace(pacCard.uid);
      } catch (_) {}
    } else if (selectedType! == TagType.ioProx) {
      try {
        IoProxCard ioProxCard = await _awaitTransport(
            session, session.communicator.getIoProxEmulatorID);
        uidController.text = bytesToHexSpace(ioProxCard.uid);
      } catch (_) {}
    } else if (selectedType! == TagType.idteck) {
      try {
        IdteckCard idteckCard = await _awaitTransport(
            session, session.communicator.getIdteckEmulatorID);
        uidController.text = bytesToHexSpace(idteckCard.uid);
      } catch (_) {}
    } else if (isMifareClassic(selectedType!) ||
        isMifareUltralight(selectedType!)) {
      try {
        CardData data = await _awaitTransport(
            session, session.communicator.mf1GetAntiCollData);
        uidController.text = bytesToHexSpace(data.uid);
        sakController.text = bytesToHex(u8ToBytes(data.sak));
        atqaController.text = bytesToHexSpace(data.atqa);
        atsController.text = bytesToHexSpace(data.ats);

        if (isMifareClassic(selectedType!)) {
          emulatorSettings = await _awaitTransport(
              session, session.communicator.getMf1EmulatorSettings);

          if (emulatorSettings!.isDetectionEnabled) {
            detectionCount = await _awaitTransport(
                session, session.communicator.getMf1DetectionCount);
          }

          try {
            mf1PrngType = await _awaitTransport(
                session, session.communicator.getMf1PrngType);
          } catch (_) {
            mf1PrngType = null;
          }
        } else if (isMifareUltralight(selectedType!)) {
          Uint8List version = await _awaitTransport(
              session, session.communicator.mf0EmulatorGetVersionData);
          ultralightVersionController.text = bytesToHexSpace(version);

          Uint8List signature = await _awaitTransport(
              session, session.communicator.mf0EmulatorGetSignatureData);
          ultralightSignatureController.text = bytesToHexSpace(signature);

          if (mfUltralightHasCounters(selectedType!)) {
            ultralightCounterControllers.clear();
            int counterCount = mfUltralightGetCounterCount(selectedType!);

            for (int i = 0; i < counterCount; i++) {
              TextEditingController controller = TextEditingController();
              var counterData = await _awaitTransport(session,
                  () => session.communicator.mf0EmulatorGetCounterData(i));
              controller.text = counterData.$1.toString();
              ultralightCounterControllers.add(controller);
            }
          }

          emulatorSettings = await _awaitTransport(
              session, session.communicator.mf0NtagGetEmulatorConfig);

          if (emulatorSettings!.isDetectionEnabled) {
            detectionCount = await _awaitTransport(
                session, session.communicator.mf0NtagGetDetectionCount);
          }
        }
      } catch (_) {}
    }

    if (!_canContinue(session)) return;
    setState(() {
      previousTagType = selectedType!;
    });
  }

  Future<bool> save() {
    return _runSlotOperation(_save);
  }

  Future<void> _save(ConnectedDeviceSession session) async {
    await _awaitTransport(
        session, () => session.communicator.activateSlot(widget.slot));
    if (widget.slotType != selectedType) {
      await _awaitTransport(session,
          () => session.communicator.setSlotType(widget.slot, selectedType!));
      bool oldIsClassic = isMifareClassic(widget.slotType);
      bool newIsClassic = isMifareClassic(selectedType!);
      bool oldIsUltralight = isMifareUltralight(widget.slotType);
      bool newIsUltralight = isMifareUltralight(selectedType!);

      if (!((oldIsClassic && newIsClassic) ||
          (oldIsUltralight && newIsUltralight))) {
        await _awaitTransport(
            session,
            () => session.communicator
                .setDefaultDataToSlot(widget.slot, selectedType!));
      }
    }

    if (isEM410X(selectedType!)) {
      await _awaitTransport(
          session,
          () => session.communicator
              .setEM410XEmulatorID(hexToBytes(uidController.text)));
    } else if (selectedType! == TagType.hidProx) {
      try {
        int hidType = int.parse(hidTypeController.text);
        int facilityCode = int.parse(facilityCodeController.text);
        int issueLevel = int.parse(issueLevelController.text);
        int oem = int.parse(oemController.text);

        Uint8List uid = hexToBytes(uidController.text.replaceAll(' ', ''));

        HIDCard hidCard = HIDCard(
          hidType: hidType,
          facilityCode: facilityCode,
          uid: uid,
          issueLevel: issueLevel,
          oem: oem,
        );

        await _awaitTransport(
            session,
            () => session.communicator
                .setHIDProxEmulatorID(hexToBytes(hidCard.toString())));
      } on _SlotOperationCanceled {
        rethrow;
      } catch (_) {}
    } else if (selectedType! == TagType.pac) {
      await _awaitTransport(
          session,
          () => session.communicator.setPacEmulatorID(
              hexToBytes(uidController.text.replaceAll(' ', ''))));
    } else if (selectedType! == TagType.ioProx) {
      await _awaitTransport(
          session,
          () => session.communicator.setIoProxEmulatorID(
              hexToBytes(uidController.text.replaceAll(' ', ''))));
    } else if (selectedType! == TagType.idteck) {
      await _awaitTransport(
          session,
          () => session.communicator.setIdteckEmulatorID(
              hexToBytes(uidController.text.replaceAll(' ', ''))));
    } else if (isMifareClassic(selectedType!) ||
        isMifareUltralight(selectedType!)) {
      var cardData = CardData(
          uid: hexToBytes(uidController.text),
          atqa: hexToBytes(atqaController.text),
          sak: bytesToU8(hexToBytes(sakController.text)),
          ats: hexToBytes(atsController.text));
      await _awaitTransport(
          session, () => session.communicator.setMf1AntiCollision(cardData));

      // Save Ultralight-specific data
      if (isMifareUltralight(selectedType!)) {
        await _awaitTransport(
            session,
            () => session.communicator.mf0EmulatorSetVersionData(
                hexToBytes(ultralightVersionController.text)));

        await _awaitTransport(
            session,
            () => session.communicator.mf0EmulatorSetSignatureData(
                hexToBytes(ultralightSignatureController.text)));

        if (mfUltralightHasCounters(selectedType!)) {
          for (int i = 0; i < ultralightCounterControllers.length; i++) {
            int counterValue =
                int.tryParse(ultralightCounterControllers[i].text) ?? 0;
            await _awaitTransport(
                session,
                () => session.communicator
                    .mf0EmulatorSetCounterData(i, counterValue, true));
          }
        }
      }
    }

    await _awaitTransport(
        session,
        () => session.communicator.setSlotTagName(
            widget.slot, nameController.text, widget.frequency));
    await _awaitTransport(session, session.communicator.saveSlotData);

    widget.update(nameController.text, widget.frequency, selectedType);
  }

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    var appState = context.watch<ChameleonGUIState>();

    return AlertDialog(
      title: Text(localizations.edit_slot_data),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            children: [
              TextFormField(
                controller: nameController,
                validator: (value) => validateName(value, localizations),
              ),
              const SizedBox(height: 8),
              DropdownButton<TagType>(
                value: selectedType,
                items: [
                  ...getTagTypesByFrequency(widget.frequency),
                  TagType.unknown
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
                    });
                  }
                },
              ),
              FutureBuilder(
                  future: updateInfo(),
                  builder: (BuildContext context, AsyncSnapshot snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        !(previousTagType == selectedType ||
                            isMifareClassic(previousTagType) &&
                                isMifareClassic(selectedType!))) {
                      return const Column(
                          children: [CircularProgressIndicator()]);
                    } else if (snapshot.hasError) {
                      appState.connector!.performDisconnect();
                      return ErrorPage(errorMessage: snapshot.error.toString());
                    } else {
                      return Visibility(
                          visible: selectedType != TagType.unknown,
                          child: Column(children: [
                            Column(children: [
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: uidController,
                                decoration: InputDecoration(
                                    labelText: localizations.uid,
                                    hintText: localizations
                                        .enter_something(localizations.uid)),
                                inputFormatters: hexFormatter,
                                validator: (value) => validateUid(
                                    value,
                                    localizations,
                                    selectedType ?? widget.slotType),
                              ),
                              Visibility(
                                  visible: chameleonTagToFrequency(
                                          selectedType ?? widget.slotType) !=
                                      TagFrequency.lf,
                                  child: Column(
                                    children: [
                                      const SizedBox(height: 20),
                                      TextFormField(
                                        controller: sakController,
                                        decoration: InputDecoration(
                                            labelText: localizations.sak,
                                            hintText:
                                                localizations.enter_something(
                                                    localizations.sak)),
                                        inputFormatters: hexFormatter,
                                        validator: (value) =>
                                            chameleonTagToFrequency(
                                                        selectedType ??
                                                            widget.slotType) ==
                                                    TagFrequency.lf
                                                ? null
                                                : validateHex(
                                                    value, localizations,
                                                    exactBytes: 1,
                                                    fieldName:
                                                        localizations.sak,
                                                    required: true),
                                      ),
                                      const SizedBox(height: 20),
                                      TextFormField(
                                        controller: atqaController,
                                        decoration: InputDecoration(
                                            labelText: localizations.atqa,
                                            hintText:
                                                localizations.enter_something(
                                                    localizations.atqa)),
                                        inputFormatters: hexFormatter,
                                        validator: (value) =>
                                            chameleonTagToFrequency(
                                                        selectedType ??
                                                            widget.slotType) ==
                                                    TagFrequency.lf
                                                ? null
                                                : validateHex(
                                                    value, localizations,
                                                    exactBytes: 2,
                                                    fieldName:
                                                        localizations.atqa,
                                                    required: true),
                                      ),
                                      const SizedBox(height: 20),
                                      TextFormField(
                                          controller: atsController,
                                          decoration: InputDecoration(
                                              labelText: localizations.ats,
                                              hintText:
                                                  localizations.enter_something(
                                                      localizations.ats)),
                                          inputFormatters: hexFormatter,
                                          validator: (value) => validateHex(
                                              value, localizations)),
                                      if (isMifareUltralight(
                                          selectedType!)) ...[
                                        const SizedBox(height: 20),
                                        TextFormField(
                                            controller:
                                                ultralightVersionController,
                                            decoration: InputDecoration(
                                                labelText: localizations
                                                    .ultralight_version,
                                                hintText: localizations
                                                    .enter_something(localizations
                                                        .ultralight_version)),
                                            validator: (value) => validateHex(
                                                value, localizations)),
                                        const SizedBox(height: 20),
                                        TextFormField(
                                            controller:
                                                ultralightSignatureController,
                                            decoration: InputDecoration(
                                                labelText: localizations
                                                    .ultralight_signature,
                                                hintText: localizations
                                                    .enter_something(localizations
                                                        .ultralight_signature)),
                                            validator: (value) => validateHex(
                                                value, localizations)),
                                        if (mfUltralightHasCounters(
                                            selectedType!)) ...[
                                          const SizedBox(height: 20),
                                          ...ultralightCounterControllers
                                              .asMap()
                                              .entries
                                              .map((entry) {
                                            int index = entry.key;
                                            TextEditingController controller =
                                                entry.value;
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 10),
                                              child: TextFormField(
                                                controller: controller,
                                                decoration: InputDecoration(
                                                    labelText: localizations
                                                        .ultralight_counter(
                                                            index),
                                                    hintText: localizations
                                                        .ultralight_counter_value),
                                                validator: (value) =>
                                                    validateIntRange(
                                                        value, localizations,
                                                        min: 0,
                                                        max: 16777215,
                                                        emptyMessage: localizations
                                                            .counter_value_empty),
                                              ),
                                            );
                                          }),
                                        ],
                                      ],
                                      if (isMifareClassic(selectedType!) &&
                                          emulatorSettings != null)
                                        Column(children: [
                                          const SizedBox(height: 20),
                                          Text(
                                            localizations
                                                .mifare_classic_emulator_settings,
                                            textScaler:
                                                const TextScaler.linear(1.1),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(localizations.mode_gen1a),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isGen1a
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) =>
                                                        communicator
                                                            .setMf1Gen1aMode(
                                                                index == 0));
                                              }),
                                          const SizedBox(height: 8),
                                          Text(localizations.mode_gen2),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isGen2
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) =>
                                                        communicator
                                                            .setMf1Gen2Mode(
                                                                index == 0));
                                              }),
                                          if (mf1PrngType != null) ...[
                                            const SizedBox(height: 8),
                                            Text(localizations.prng_type),
                                            const SizedBox(height: 8),
                                            ToggleButtonsWrapper(
                                                items: Mf1PrngType.values
                                                    .map((type) =>
                                                        getMf1PrngLabel(type,
                                                            localizations))
                                                    .toList(),
                                                selectedValue:
                                                    mf1PrngType!.value,
                                                onChange: (int index) async {
                                                  Mf1PrngType nextType =
                                                      Mf1PrngType.values[index];
                                                  setState(() {
                                                    mf1PrngType = nextType;
                                                  });
                                                  await _runCommand(
                                                      (communicator) =>
                                                          communicator
                                                              .setMf1PrngType(
                                                                  nextType));
                                                }),
                                          ],
                                          const SizedBox(height: 8),
                                          Text(localizations.use_from_block),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isAntiColl
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) => communicator
                                                        .setMf1UseFirstBlockColl(
                                                            index == 0));
                                              }),
                                          const SizedBox(height: 8),
                                          Text(localizations
                                              .collect_nonces('Mfkey32')),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue: emulatorSettings!
                                                      .isDetectionEnabled
                                                  ? 0
                                                  : 1,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) => communicator
                                                        .setMf1DetectionStatus(
                                                            index == 0));
                                              }),
                                          ...(emulatorSettings!
                                                  .isDetectionEnabled)
                                              ? [
                                                  ...(detectionCount == 0)
                                                      ? [
                                                          const SizedBox(
                                                              height: 8),
                                                          Text(
                                                              localizations
                                                                  .present_cham_reader_keys,
                                                              textScaler:
                                                                  const TextScaler
                                                                      .linear(
                                                                      0.8))
                                                        ]
                                                      : [
                                                          const SizedBox(
                                                              height: 8),
                                                          Row(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                TextButton(
                                                                    onPressed:
                                                                        () {
                                                                      Navigator.pop(
                                                                          context);
                                                                      Navigator
                                                                          .push(
                                                                        context,
                                                                        MaterialPageRoute(
                                                                          builder: (context) =>
                                                                              const Mfkey32Menu(),
                                                                        ),
                                                                      );
                                                                    },
                                                                    child: Row(
                                                                      children: [
                                                                        const Icon(
                                                                            Icons.lock_open),
                                                                        Text(localizations
                                                                            .recover_keys),
                                                                      ],
                                                                    )),
                                                              ]),
                                                        ],
                                                ]
                                              : [
                                                  const SizedBox(height: 8),
                                                  Text(
                                                      localizations
                                                          .ena_coll_recover_keys,
                                                      textScaler:
                                                          const TextScaler
                                                              .linear(0.8))
                                                ],
                                          const SizedBox(height: 8),
                                          Text(localizations.write_mode),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.normal,
                                                localizations.decline,
                                                localizations.deceive,
                                                localizations.shadow
                                              ],
                                              selectedValue: emulatorSettings!
                                                  .writeMode.value,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) =>
                                                        communicator
                                                            .setMf1WriteMode(
                                                                MifareWriteMode
                                                                        .values[
                                                                    index]));
                                              }),
                                        ]),
                                      if (isMifareUltralight(selectedType!) &&
                                          emulatorSettings != null)
                                        Column(children: [
                                          const SizedBox(height: 20),
                                          Text(
                                            localizations
                                                .mifare_ultralight_emulator_settings,
                                            textScaler:
                                                const TextScaler.linear(1.1),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(localizations.mode_gen2),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isGen2
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) =>
                                                        communicator
                                                            .mf0SetMagicMode(
                                                                index == 0));
                                              }),
                                          const SizedBox(height: 8),
                                          Text(
                                              localizations.password_detection),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue: emulatorSettings!
                                                      .isDetectionEnabled
                                                  ? 0
                                                  : 1,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) => communicator
                                                        .mf0NtagSetDetectionEnable(
                                                            index == 0));
                                              }),
                                          ...(emulatorSettings!
                                                  .isDetectionEnabled)
                                              ? [
                                                  ...(detectionCount == 0)
                                                      ? [
                                                          const SizedBox(
                                                              height: 8),
                                                          Text(
                                                              localizations
                                                                  .present_cham_reader_keys,
                                                              textScaler:
                                                                  const TextScaler
                                                                      .linear(
                                                                      0.8))
                                                        ]
                                                      : [
                                                          const SizedBox(
                                                              height: 8),
                                                          Text(
                                                              '${localizations.passwords_detected}: $detectionCount',
                                                              textScaler:
                                                                  const TextScaler
                                                                      .linear(
                                                                      0.9)),
                                                          const SizedBox(
                                                              height: 8),
                                                          Row(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                TextButton(
                                                                    onPressed:
                                                                        () async {
                                                                      final passwords =
                                                                          await _runReadCommand((communicator) =>
                                                                              communicator.mf0NtagGetDetectionLog(0));

                                                                      if (passwords ==
                                                                              null ||
                                                                          !context
                                                                              .mounted) {
                                                                        return;
                                                                      }

                                                                      showDialog(
                                                                        context:
                                                                            context,
                                                                        builder:
                                                                            (BuildContext
                                                                                context) {
                                                                          TextEditingController
                                                                              passwordController =
                                                                              TextEditingController();
                                                                          passwordController.text = passwords
                                                                              .join('\n')
                                                                              .toUpperCase();

                                                                          return AlertDialog(
                                                                            title:
                                                                                Text(localizations.detected_passwords),
                                                                            content:
                                                                                SizedBox(
                                                                              width: double.maxFinite,
                                                                              child: TextFormField(
                                                                                maxLines: null,
                                                                                controller: passwordController,
                                                                                readOnly: true,
                                                                                style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 16.0),
                                                                              ),
                                                                            ),
                                                                            actions: [
                                                                              TextButton(
                                                                                onPressed: () {
                                                                                  Navigator.of(context).pop();
                                                                                },
                                                                                child: Text(localizations.close),
                                                                              ),
                                                                            ],
                                                                          );
                                                                        },
                                                                      );
                                                                    },
                                                                    child: Row(
                                                                      children: [
                                                                        const Icon(
                                                                            Icons.visibility),
                                                                        Text(localizations
                                                                            .view_passwords),
                                                                      ],
                                                                    )),
                                                              ]),
                                                        ],
                                                ]
                                              : [
                                                  const SizedBox(height: 8),
                                                  Text(
                                                      localizations
                                                          .enable_password_detection,
                                                      textScaler:
                                                          const TextScaler
                                                              .linear(0.8))
                                                ],
                                          const SizedBox(height: 8),
                                          Text(localizations.write_mode),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.normal,
                                                localizations.decline,
                                                localizations.deceive,
                                                localizations.shadow
                                              ],
                                              selectedValue: emulatorSettings!
                                                  .writeMode.value,
                                              onChange: (int index) async {
                                                await _runCommand(
                                                    (communicator) =>
                                                        communicator
                                                            .mf0NtagSetWriteMode(
                                                                MifareWriteMode
                                                                        .values[
                                                                    index]));
                                              }),
                                        ]),
                                    ],
                                  )),
                            ]),
                            if (selectedType == TagType.hidProx)
                              Column(children: [
                                const SizedBox(height: 20),
                                DropdownButton<int>(
                                  value:
                                      int.tryParse(hidTypeController.text) ?? 1,
                                  items: List.generate(30, (index) => index + 1)
                                      .map<DropdownMenuItem<int>>((int type) {
                                    return DropdownMenuItem<int>(
                                      value: type,
                                      child: Text(getNameForHIDProxType(type)),
                                    );
                                  }).toList(),
                                  onChanged: (int? newValue) {
                                    if (newValue != null) {
                                      setState(() {
                                        hidTypeController.text =
                                            newValue.toString();
                                      });
                                    }
                                  },
                                  isExpanded: true,
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: facilityCodeController,
                                  decoration: InputDecoration(
                                      labelText: localizations.facility_code,
                                      hintText: localizations.enter_something(
                                          localizations.facility_code)),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  validator: (value) => validateIntRange(
                                      value, localizations,
                                      min: 0, max: 4294967295),
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: issueLevelController,
                                  decoration: InputDecoration(
                                      labelText: localizations.issue_level,
                                      hintText: localizations.enter_something(
                                          localizations.issue_level)),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  validator: (value) => validateIntRange(
                                      value, localizations,
                                      min: 0, max: 255),
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: oemController,
                                  decoration: InputDecoration(
                                      labelText: "OEM",
                                      hintText:
                                          localizations.enter_something('OEM')),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  validator: (value) => validateIntRange(
                                      value, localizations,
                                      min: 0, max: 65535),
                                ),
                              ])
                          ]));
                    }
                  })
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(localizations.cancel),
        ),
        TextButton(
          onPressed: () async {
            if (!_formKey.currentState!.validate()) {
              return;
            }

            if (!await save()) {
              return;
            }

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
