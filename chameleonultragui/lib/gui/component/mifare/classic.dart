import 'dart:typed_data';

import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/error_message.dart';
import 'package:chameleonultragui/gui/component/key_check_marks.dart';
import 'package:chameleonultragui/gui/component/mifare/feature_strings.dart';
import 'package:chameleonultragui/gui/component/mifare/key_profile_file.dart';
import 'package:chameleonultragui/gui/menu/dialogs/dictionary/export.dart';
import 'package:chameleonultragui/helpers/card_info.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class MifareClassicHelper extends StatefulWidget {
  final HFCardInfo hfInfo;
  final MifareClassicInfo mfcInfo;
  final bool allowSave;

  const MifareClassicHelper(
      {super.key,
      required this.hfInfo,
      required this.mfcInfo,
      this.allowSave = true});

  @override
  State<StatefulWidget> createState() => CardReaderState();
}

class CardReaderState extends State<MifareClassicHelper> {
  String dumpName = "";
  bool skipDefaultDictionary = false;
  bool _profileSelectionInitialized = false;
  MifareClassicRecovery? _profileSelectionRecovery;

  bool _canContinue(
    MifareClassicInfo info,
    MifareClassicRecovery recovery, [
    ConnectedDeviceSession? session,
  ]) {
    return mounted &&
        identical(widget.mfcInfo, info) &&
        identical(info.recovery, recovery) &&
        (session?.isCurrent ?? true);
  }

  @override
  void didUpdateWidget(covariant MifareClassicHelper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.mfcInfo.recovery, widget.mfcInfo.recovery) ||
        oldWidget.hfInfo.uid != widget.hfInfo.uid ||
        oldWidget.mfcInfo.type != widget.mfcInfo.type ||
        oldWidget.mfcInfo.isEV1 != widget.mfcInfo.isEV1) {
      if (oldWidget.hfInfo.uid != widget.hfInfo.uid ||
          oldWidget.mfcInfo.type != widget.mfcInfo.type ||
          oldWidget.mfcInfo.isEV1 != widget.mfcInfo.isEV1) {
        widget.mfcInfo.recovery?.selectedKeyProfile = null;
      }
      _profileSelectionInitialized = false;
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _getKeyProfileName() async {
    final localizations = AppLocalizations.of(context)!;
    final featureStrings = MifareClassicFeatureStrings.of(context);
    final controller = TextEditingController(
        text: widget.hfInfo.uid.replaceAll(RegExp(r'[^0-9a-fA-F]'), ''));

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(featureStrings.enterKeyProfileName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: controller, autofocus: true),
            const SizedBox(height: 12),
            Text(
              featureStrings.keyProfilePlaintextWarning,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(localizations.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(dialogContext, name);
              }
            },
            child: Text(localizations.ok),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  void _storeKeyProfile(MifareClassicKeyProfile profile) {
    final appState = context.read<ChameleonGUIState>();
    final profiles = appState.sharedPreferencesProvider
        .upsertMifareClassicKeyProfile(profile);
    widget.mfcInfo.recovery!
      ..keyProfiles = profiles
      ..selectedKeyProfile = profile;
  }

  Future<void> saveKeyProfile() async {
    final localizations = AppLocalizations.of(context)!;
    final featureStrings = MifareClassicFeatureStrings.of(context);
    final name = await _getKeyProfileName();
    if (name == null || !mounted) {
      return;
    }

    final profile = widget.mfcInfo.recovery!.createKeyProfile(
      name: name,
      uid: widget.hfInfo.uid,
    );

    final exportToFile = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(featureStrings.saveKeyProfile),
        content: Text(featureStrings.keyProfilePlaintextWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(localizations.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(featureStrings.saveKeyProfileInApp),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(featureStrings.exportKeyProfileToFile),
          ),
        ],
      ),
    );
    if (exportToFile == null || !mounted) {
      return;
    }

    if (exportToFile) {
      final exported = await exportMifareClassicKeyProfileFile(
        profile,
        dialogTitle: '${localizations.output_file}:',
      );
      if (!exported) {
        return;
      }
    } else {
      _storeKeyProfile(profile);
      setState(() {});
    }
    _showMessage(featureStrings.keyProfileSaved);
  }

  Future<bool> _confirmSelectedProfileUid() async {
    final profile = widget.mfcInfo.recovery?.selectedKeyProfile;
    if (profile == null ||
        profile.uid == null ||
        profile.matchesUid(widget.hfInfo.uid)) {
      return true;
    }

    final localizations = AppLocalizations.of(context)!;
    final featureStrings = MifareClassicFeatureStrings.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(featureStrings.keyProfileUidMismatch),
            content: Text(featureStrings.keyProfileUidMismatchDescription),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(localizations.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(featureStrings.useKeyProfile),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> exportFoundKeys() async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return DictionaryExportMenu(keys: widget.mfcInfo.recovery!.validKeys);
      },
    );
  }

  Future<void> saveCard({bool bin = false, bool skipDump = false}) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    var localizations = AppLocalizations.of(context)!;
    if (bin) {
      final recovery = widget.mfcInfo.recovery;
      final geometry = MifareClassicGeometry.fromType(
        widget.mfcInfo.type,
        isEV1: widget.mfcInfo.isEV1,
      );
      if (recovery == null ||
          !recovery.dumpComplete ||
          geometry == null ||
          !geometry.matchesBlockData(recovery.cardData)) {
        _showMessage(
            MifareClassicFeatureStrings.of(context).partialBinExportBlocked);
        return;
      }
    }

    Uint8List cardDump = Uint8List(0);
    if (!skipDump) {
      cardDump = mfClassicGetExportBytes(
          widget.mfcInfo.type, widget.mfcInfo.recovery!.cardData,
          isEV1: widget.mfcInfo.isEV1);
    }

    if (bin) {
      await FilePicker.saveFile(
        dialogTitle: '${localizations.output_file}:',
        fileName: '${widget.hfInfo.uid.replaceAll(" ", "")}.bin',
        bytes: cardDump,
      );
    } else {
      var tags = appState.sharedPreferencesProvider.getCards();
      tags.add(CardSave(
          uid: widget.hfInfo.uid,
          sak: hexToBytes(widget.hfInfo.sak)[0],
          atqa: hexToBytes(widget.hfInfo.atqa),
          name: dumpName,
          tag: (skipDump)
              ? TagType.mifare1K
              : mfClassicGetChameleonTagType(widget.mfcInfo.type),
          data: widget.mfcInfo.recovery!.cardData,
          extraData: CardSaveExtra(
            mifareClassicDumpComplete:
                !skipDump && widget.mfcInfo.recovery!.dumpComplete,
          ),
          ats: (widget.hfInfo.ats != localizations.no)
              ? hexToBytes(widget.hfInfo.ats)
              : Uint8List(0)));
      appState.sharedPreferencesProvider.setCards(tags);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    var localizations = AppLocalizations.of(context)!;
    final featureStrings = MifareClassicFeatureStrings.of(context);
    final isSmallScreen = screenSize.width < 800;

    double checkmarkFontSize = isSmallScreen ? 12 : 16;
    double checkmarkSize = isSmallScreen ? 16 : 20;
    int checkmarkPerRow = (screenSize.width < 600) ? 8 : 16;

    var appState = context.watch<ChameleonGUIState>();
    if (!identical(_profileSelectionRecovery, widget.mfcInfo.recovery)) {
      _profileSelectionRecovery = widget.mfcInfo.recovery;
      _profileSelectionInitialized = false;
    }
    widget.mfcInfo.recovery?.dictionaries =
        appState.sharedPreferencesProvider.getDictionaries(keyLength: 12);
    widget.mfcInfo.recovery?.dictionaries
        .insert(0, Dictionary(id: "", name: localizations.empty, keys: []));
    widget.mfcInfo.recovery?.selectedDictionary ??=
        widget.mfcInfo.recovery?.dictionaries[0];
    final sectorCount = mfClassicGetSectorCount(widget.mfcInfo.type,
        isEV1: widget.mfcInfo.isEV1);
    widget.mfcInfo.recovery?.keyProfiles = appState.sharedPreferencesProvider
        .getMifareClassicKeyProfiles()
        .where((profile) => profile.isCompatible(
            cardType: widget.mfcInfo.type.name, sectorCount: sectorCount))
        .toList();
    final selectedProfile = widget.mfcInfo.recovery?.selectedKeyProfile;
    if (selectedProfile != null &&
        !(widget.mfcInfo.recovery?.keyProfiles
                .any((profile) => profile.id == selectedProfile.id) ??
            false)) {
      widget.mfcInfo.recovery?.selectedKeyProfile = null;
    }
    if (!_profileSelectionInitialized) {
      for (final profile in widget.mfcInfo.recovery?.keyProfiles ??
          <MifareClassicKeyProfile>[]) {
        if (profile.matchesUid(widget.hfInfo.uid)) {
          widget.mfcInfo.recovery?.selectedKeyProfile = profile;
          break;
        }
      }
      _profileSelectionInitialized = true;
    }

    WakelockPlus.toggle(
        enable: [
      MifareClassicState.checkKeysOngoing,
      MifareClassicState.recoveryOngoing,
      MifareClassicState.dumpOngoing
    ].contains(widget.mfcInfo.state));

    return Column(children: [
      const SizedBox(height: 16),
      Text(
        localizations.keys,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
        ),
      ),
      if (widget.mfcInfo.recovery != null) ...[
        Row(
          children: [
            const Spacer(),
            KeyCheckMarks(
                checkMarks: widget.mfcInfo.recovery!.checkMarks,
                validKeys: widget.mfcInfo.recovery!.validKeys,
                fontSize: checkmarkFontSize,
                checkmarkSize: checkmarkSize,
                checkmarkCount: mfClassicGetSectorCount(widget.mfcInfo.type,
                    isEV1: widget.mfcInfo.isEV1),
                checkmarkPerRow: checkmarkPerRow,
                onCheckmarkChanged: (index, newValue) {
                  widget.mfcInfo.recovery!.checkMarks[index] = newValue;
                  widget.mfcInfo.recovery!.update();
                }),
            const Spacer(),
          ],
        ),
        if (widget.mfcInfo.recovery!.hasVerifiedKeys &&
            ![
              MifareClassicState.checkKeysOngoing,
              MifareClassicState.recoveryOngoing,
              MifareClassicState.dumpOngoing,
            ].contains(widget.mfcInfo.state)) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: saveKeyProfile,
            icon: const Icon(Icons.key),
            label: Text(featureStrings.saveKeyProfile),
          ),
        ],
        if (widget.mfcInfo.recovery?.error != "") ...[
          const SizedBox(height: 16),
          ErrorMessage(errorMessage: widget.mfcInfo.recovery!.error),
        ],
        if (widget.mfcInfo.recovery?.state != "") ...[
          const SizedBox(height: 8),
          Text(widget.mfcInfo.recovery!.state),
        ],
        const SizedBox(height: 12),
        if (widget.mfcInfo.recovery?.dumpProgress != 0) ...[
          LinearProgressIndicator(value: widget.mfcInfo.recovery?.dumpProgress),
          const SizedBox(height: 8)
        ],
        if (widget.mfcInfo.recovery?.hardnestedProgress != null &&
            widget.mfcInfo.recovery?.error == "") ...[
          LinearProgressIndicator(
              value: widget.mfcInfo.recovery?.hardnestedProgress),
          const SizedBox(height: 12)
        ],
        if (widget.mfcInfo.recovery?.keyCheckProgress != null) ...[
          LinearProgressIndicator(
              value: widget.mfcInfo.recovery?.keyCheckProgress),
          const SizedBox(height: 12)
        ],
        if (widget.mfcInfo.state == MifareClassicState.recovery ||
            widget.mfcInfo.state == MifareClassicState.recoveryOngoing)
          _ResponsiveButtonGroup(children: [
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: (widget.mfcInfo.state == MifareClassicState.recovery)
                  ? () async {
                      final info = widget.mfcInfo;
                      final recovery = info.recovery!;
                      final session = ConnectedDeviceSession.capture(appState);
                      if (session == null) {
                        return;
                      }
                      setState(() {
                        info.state = MifareClassicState.recoveryOngoing;
                      });

                      final completed =
                          await appState.rfOperations.runForeground(() async {
                        if (!_canContinue(info, recovery, session)) {
                          return false;
                        }
                        return recovery.recoverKeys();
                      });
                      if (!completed ||
                          !_canContinue(info, recovery, session)) {
                        return;
                      }

                      if (recovery.error.isNotEmpty) {
                        setState(() {
                          info.state = MifareClassicState.recovery;
                        });
                      } else {
                        setState(() {
                          info.state = MifareClassicState.dump;
                        });
                      }
                    }
                  : null,
              style: customCardButtonStyle(appState),
              child: Text(localizations.recover_keys),
            ),
            if (widget.allowSave) ...[
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: (widget.mfcInfo.state == MifareClassicState.recovery)
                    ? () async {
                        final info = widget.mfcInfo;
                        final recovery = info.recovery!;
                        final session =
                            ConnectedDeviceSession.capture(appState);
                        if (session == null) {
                          return;
                        }
                        setState(() {
                          info.state = MifareClassicState.dumpOngoing;
                        });

                        try {
                          final completed = await appState.rfOperations
                              .runForeground(() async {
                            if (!_canContinue(info, recovery, session)) {
                              return false;
                            }
                            return recovery.dumpData();
                          });
                          if (!completed ||
                              !_canContinue(info, recovery, session)) {
                            return;
                          }

                          setState(() {
                            recovery.dumpProgress = 0;
                            info.state = MifareClassicState.save;
                          });
                        } catch (_) {
                          if (!_canContinue(info, recovery, session)) {
                            return;
                          }
                          setState(() {
                            recovery.error =
                                localizations.recovery_error_dump_data;
                            info.state = MifareClassicState.dump;
                          });
                        }
                      }
                    : null,
                style: customCardButtonStyle(appState),
                child: Text(localizations.dump_partial_data),
              )
            ],
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () async {
                await exportFoundKeys();
              },
              style: customCardButtonStyle(appState),
              child: Text(localizations.export_to_dictionary),
            ),
          ]),
        if (widget.mfcInfo.state == MifareClassicState.checkKeys ||
            widget.mfcInfo.state == MifareClassicState.checkKeysOngoing)
          Column(children: [
            if (widget.mfcInfo.state == MifareClassicState.checkKeys)
              Column(children: [
                Align(
                    alignment: Alignment.center,
                    child: SizedBox(
                        width: 275, // WIP: center without this
                        child: CheckboxListTile(
                          title: Text(localizations.skip_default_dictionary),
                          value: skipDefaultDictionary,
                          onChanged: (bool? newValue) {
                            setState(() {
                              skipDefaultDictionary = newValue!;
                            });
                          },
                          controlAffinity: ListTileControlAffinity.leading,
                        ))),
                const SizedBox(height: 8),
                Text(featureStrings.assignedKeyProfile),
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 340,
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value:
                            widget.mfcInfo.recovery?.selectedKeyProfile?.id ??
                                '',
                        items: [
                          DropdownMenuItem<String>(
                            value: '',
                            child: Text(localizations.empty),
                          ),
                          ...widget.mfcInfo.recovery!.keyProfiles.map(
                            (profile) => DropdownMenuItem<String>(
                              value: profile.id,
                              child: Text(
                                '${profile.name} (${profile.keyCount} ${localizations.keys.toLowerCase()})'
                                '${profile.uid == null ? '' : ' · UID ${profile.uid}'}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (profileId) {
                          setState(() {
                            if (profileId == null || profileId.isEmpty) {
                              widget.mfcInfo.recovery?.selectedKeyProfile =
                                  null;
                              return;
                            }
                            widget.mfcInfo.recovery?.selectedKeyProfile =
                                widget.mfcInfo.recovery!.keyProfiles.firstWhere(
                                    (profile) => profile.id == profileId);
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(localizations.additional_key_dict),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: widget.mfcInfo.recovery?.selectedDictionary!.id,
                  items: widget.mfcInfo.recovery?.dictionaries
                      .map<DropdownMenuItem<String>>((Dictionary dictionary) {
                    return DropdownMenuItem<String>(
                      value: dictionary.id,
                      child: Text(
                          "${dictionary.name} (${dictionary.keys.length} ${localizations.keys.toLowerCase()})"),
                    );
                  }).toList(),
                  onChanged: (String? newValue) {
                    for (var dictionary
                        in widget.mfcInfo.recovery!.dictionaries) {
                      if (dictionary.id == newValue) {
                        setState(() {
                          widget.mfcInfo.recovery?.selectedDictionary =
                              dictionary;
                        });
                        break;
                      }
                    }
                  },
                ),
                const SizedBox(height: 8),
              ]),
            ElevatedButton(
              onPressed: (widget.mfcInfo.state == MifareClassicState.checkKeys)
                  ? () async {
                      final info = widget.mfcInfo;
                      final recovery = info.recovery!;
                      final session = ConnectedDeviceSession.capture(appState);
                      if (session == null) {
                        return;
                      }
                      setState(() {
                        info.state = MifareClassicState.checkKeysOngoing;
                      });

                      try {
                        if (!await _confirmSelectedProfileUid()) {
                          if (!_canContinue(info, recovery, session)) {
                            return;
                          }
                          setState(() {
                            info.state = MifareClassicState.checkKeys;
                          });
                          return;
                        }
                        if (!_canContinue(info, recovery, session)) {
                          return;
                        }
                        final completed =
                            await appState.rfOperations.runForeground(
                          () async {
                            if (!_canContinue(info, recovery, session)) {
                              return false;
                            }
                            return recovery.checkKeys(
                              skipDefaultDictionary: skipDefaultDictionary,
                            );
                          },
                        );
                        if (!completed ||
                            !_canContinue(info, recovery, session)) {
                          return;
                        }

                        if (recovery.allKeysExists) {
                          // all keys exists
                          setState(() {
                            info.state = MifareClassicState.dump;
                          });
                        } else {
                          setState(() {
                            info.state = MifareClassicState.recovery;
                          });
                        }
                      } catch (_) {
                        if (!_canContinue(info, recovery, session)) {
                          return;
                        }
                        for (var checkmark = 0; checkmark < 80; checkmark++) {
                          if (recovery.checkMarks[checkmark] ==
                              ChameleonKeyCheckmark.checking) {
                            recovery.checkMarks[checkmark] =
                                ChameleonKeyCheckmark.none;
                          }
                        }

                        setState(() {
                          recovery.checkMarks = recovery.checkMarks;
                          recovery.error = localizations.recovery_error_dict;
                          info.state = MifareClassicState.checkKeys;
                        });
                      }
                    }
                  : null,
              style: customCardButtonStyle(appState),
              child: Text(localizations.check_keys_dict),
            )
          ]),
        if ((widget.mfcInfo.state == MifareClassicState.dump ||
                widget.mfcInfo.state == MifareClassicState.dumpOngoing) &&
            widget.allowSave)
          _ResponsiveButtonGroup(children: [
            ElevatedButton(
              onPressed: (widget.mfcInfo.state == MifareClassicState.dump)
                  ? () async {
                      final info = widget.mfcInfo;
                      final recovery = info.recovery!;
                      final session = ConnectedDeviceSession.capture(appState);
                      if (session == null) {
                        return;
                      }
                      setState(() {
                        info.state = MifareClassicState.dumpOngoing;
                      });

                      try {
                        final completed =
                            await appState.rfOperations.runForeground(() async {
                          if (!_canContinue(info, recovery, session)) {
                            return false;
                          }
                          return recovery.dumpData();
                        });
                        if (!completed ||
                            !_canContinue(info, recovery, session)) {
                          return;
                        }

                        setState(() {
                          recovery.dumpProgress = 0;
                          info.state = MifareClassicState.save;
                        });
                      } catch (_) {
                        if (!_canContinue(info, recovery, session)) {
                          return;
                        }
                        setState(() {
                          recovery.error =
                              localizations.recovery_error_dump_data;
                          info.state = MifareClassicState.dump;
                        });
                      }
                    }
                  : null,
              style: customCardButtonStyle(appState),
              child: Text(localizations.dump_card),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () async {
                await exportFoundKeys();
              },
              style: customCardButtonStyle(appState),
              child: Text(localizations.export_to_dictionary),
            ),
          ]),
      ],
      if (widget.mfcInfo.state == MifareClassicState.save && widget.allowSave)
        _ResponsiveButtonGroup(centerOnly: true, children: [
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
        ]),
    ]);
  }
}

class _ResponsiveButtonGroup extends StatelessWidget {
  final List<Widget> children;
  final bool centerOnly;

  const _ResponsiveButtonGroup({
    required this.children,
    this.centerOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).size.width < 800) {
      final buttons = children.where((child) => child is! SizedBox).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < buttons.length; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            buttons[index],
          ],
        ],
      );
    }

    final row = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );

    if (centerOnly) {
      return Center(child: row);
    }

    return FittedBox(
      alignment: Alignment.topCenter,
      fit: BoxFit.scaleDown,
      child: row,
    );
  }
}
