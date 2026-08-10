import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/generated_card_field.dart';
import 'package:chameleonultragui/helpers/card_generator.dart';
import 'package:chameleonultragui/helpers/card_profile.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CardIdentityControllers {
  const CardIdentityControllers({
    required this.uid,
    required this.sak,
    required this.atqa,
    required this.ats,
    required this.ultralightVersion,
    required this.ultralightSignature,
    required this.hidType,
    required this.facilityCode,
    required this.issueLevel,
    required this.oem,
  });

  final TextEditingController uid;
  final TextEditingController sak;
  final TextEditingController atqa;
  final TextEditingController ats;
  final TextEditingController ultralightVersion;
  final TextEditingController ultralightSignature;
  final TextEditingController hidType;
  final TextEditingController facilityCode;
  final TextEditingController issueLevel;
  final TextEditingController oem;
}

class GeneratedCardIdentityFields extends StatefulWidget {
  const GeneratedCardIdentityFields({
    super.key,
    required this.type,
    required this.controllers,
    this.ultralightCounters = const [],
    this.onFullProfileApplied,
  });

  final TagType type;
  final CardIdentityControllers controllers;
  final List<TextEditingController> ultralightCounters;
  final ValueChanged<GeneratedCardProfile>? onFullProfileApplied;

  @override
  State<GeneratedCardIdentityFields> createState() =>
      _GeneratedCardIdentityFieldsState();
}

class _GeneratedCardIdentityFieldsState
    extends State<GeneratedCardIdentityFields> {
  final CardProfileGenerator _generator = CardProfileGenerator();

  int _currentHidType() => int.tryParse(widget.controllers.hidType.text) ?? 1;

  GeneratedCardProfile _newProfile({int? uidLength}) => _generator.generate(
        widget.type,
        uidLength: uidLength,
        hidType: widget.type == TagType.hidProx ? _currentHidType() : null,
      );

  int? _currentUidLength() {
    final length = widget.controllers.uid.text.replaceAll(' ', '').length ~/ 2;
    return validUidLengthsForTagType(widget.type).contains(length)
        ? length
        : null;
  }

  String _uidByteDescription(AppLocalizations localizations) {
    final lengths = validUidLengthsForTagType(widget.type);
    return lengths.length == 1
        ? localizations.bytes_count(lengths.single)
        : localizations.bytes_count_either(lengths[0], lengths[1]);
  }

  String? _validateUid(String? value, AppLocalizations localizations) {
    final lengthError = validateUid(value, localizations, widget.type);
    if (lengthError != null || widget.type != TagType.hidProx) {
      return lengthError;
    }

    final cardNumber = int.parse(value!.replaceAll(' ', ''), radix: 16);
    final maximum = hidFormatLimits(_currentHidType()).cardNumber;
    if (cardNumber > maximum) {
      return localizations.must_be_between(
        '0x0',
        '0x${maximum.toRadixString(16).toUpperCase()}',
      );
    }
    return null;
  }

  void _applyFullProfile() {
    final profile = _newProfile();
    final controllers = widget.controllers;
    controllers.uid.text = generatedHex(profile.uid);
    if (profile.sak != null) {
      controllers.sak.text = generatedHex(
        Uint8List.fromList([profile.sak!]),
      );
    }
    if (profile.atqa != null) {
      controllers.atqa.text = generatedHex(profile.atqa);
    }
    controllers.ats.clear();
    controllers.ultralightVersion.text =
        generatedHex(profile.ultralightVersion);
    controllers.ultralightSignature.clear();
    for (final controller in widget.ultralightCounters) {
      controller.text = _generator.generateUltralightCounter().toString();
    }
    if (profile.hidType != null) {
      controllers.hidType.text = profile.hidType.toString();
      controllers.facilityCode.text = profile.facilityCode.toString();
      controllers.issueLevel.text = profile.issueLevel.toString();
      controllers.oem.text = profile.oem.toString();
    }
    widget.onFullProfileApplied?.call(profile);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final controllers = widget.controllers;

    return Column(
      children: [
        const SizedBox(height: 8),
        Text(
          localizations.generated_fields_note,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('generate-card-data'),
          onPressed: widget.type == TagType.unknown ? null : _applyFullProfile,
          icon: const Icon(Icons.casino_outlined),
          label: Text(localizations.generate_card_data),
        ),
        if (widget.type != TagType.unknown) ...[
          GeneratedCardField(
            controller: controllers.uid,
            label: localizations.uid,
            helperText: localizations.required_bytes(
              _uidByteDescription(localizations),
            ),
            inputFormatters: hexFormatter,
            validator: (value) => _validateUid(value, localizations),
            generateTooltip: localizations.generate_field_value,
            onGenerate: () {
              final profile = _newProfile(uidLength: _currentUidLength());
              controllers.uid.text = generatedHex(profile.uid);
              if (profile.atqa != null) {
                controllers.atqa.text = generatedHex(profile.atqa);
              }
            },
          ),
          if (chameleonTagToFrequency(widget.type) != TagFrequency.lf) ...[
            const SizedBox(height: 20),
            GeneratedCardField(
              controller: controllers.sak,
              label: localizations.sak,
              helperText: localizations.required_bytes(
                localizations.bytes_count(1),
              ),
              inputFormatters: hexFormatter,
              validator: (value) => validateHex(
                value,
                localizations,
                exactBytes: 1,
                fieldName: localizations.sak,
                required: true,
              ),
              generateTooltip: localizations.generate_field_value,
              onGenerate: () {
                final sak = _newProfile().sak;
                if (sak != null) {
                  controllers.sak.text = generatedHex(
                    Uint8List.fromList([sak]),
                  );
                }
              },
            ),
            const SizedBox(height: 20),
            GeneratedCardField(
              controller: controllers.atqa,
              label: localizations.atqa,
              helperText: localizations.required_bytes(
                localizations.bytes_count(2),
              ),
              inputFormatters: hexFormatter,
              validator: (value) => validateHex(
                value,
                localizations,
                exactBytes: 2,
                fieldName: localizations.atqa,
                required: true,
              ),
              generateTooltip: localizations.generate_field_value,
              onGenerate: () {
                final atqa = _newProfile(
                  uidLength: _currentUidLength(),
                ).atqa;
                if (atqa != null) {
                  controllers.atqa.text = generatedHex(atqa);
                }
              },
            ),
            const SizedBox(height: 20),
            GeneratedCardField(
              controller: controllers.ats,
              label: localizations.ats,
              helperText: localizations.optional_bytes(
                localizations.any_byte_length,
              ),
              inputFormatters: hexFormatter,
              validator: (value) => validateHex(value, localizations),
            ),
            if (isMifareUltralight(widget.type)) ...[
              const SizedBox(height: 20),
              GeneratedCardField(
                controller: controllers.ultralightVersion,
                label: localizations.ultralight_version,
                helperText: localizations.optional_bytes(
                  localizations.bytes_count(8),
                ),
                inputFormatters: hexFormatter,
                validator: (value) => validateHex(
                  value,
                  localizations,
                  exactBytes: 8,
                  fieldName: localizations.ultralight_version,
                ),
                generateTooltip: localizations.generate_field_value,
                onGenerate: _newProfile().ultralightVersion == null
                    ? null
                    : () {
                        controllers.ultralightVersion.text = generatedHex(
                          _newProfile().ultralightVersion,
                        );
                      },
              ),
              const SizedBox(height: 20),
              GeneratedCardField(
                controller: controllers.ultralightSignature,
                label: localizations.ultralight_signature,
                helperText: localizations.optional_bytes(
                  localizations.bytes_count(32),
                ),
                inputFormatters: hexFormatter,
                validator: (value) => validateHex(
                  value,
                  localizations,
                  exactBytes: 32,
                  fieldName: localizations.ultralight_signature,
                ),
              ),
              if (widget.ultralightCounters.isNotEmpty) ...[
                const SizedBox(height: 20),
                ...widget.ultralightCounters.asMap().entries.map((entry) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GeneratedCardField(
                      controller: entry.value,
                      label: localizations.ultralight_counter(entry.key),
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      validator: (value) => validateIntRange(
                        value,
                        localizations,
                        min: 0,
                        max: 16777215,
                        emptyMessage: localizations.counter_value_empty,
                      ),
                      generateTooltip: localizations.generate_field_value,
                      onGenerate: () => entry.value.text =
                          _generator.generateUltralightCounter().toString(),
                    ),
                  );
                }),
              ],
            ],
          ],
          if (widget.type == TagType.hidProx) ...[
            const SizedBox(height: 20),
            DropdownButton<int>(
              value: int.tryParse(controllers.hidType.text) ?? 1,
              items: List.generate(hidFormatCount, (index) => index + 1)
                  .map(
                    (type) => DropdownMenuItem<int>(
                      value: type,
                      child: Text(getNameForHIDProxType(type)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => controllers.hidType.text = value.toString());
                }
              },
              isExpanded: true,
            ),
            const SizedBox(height: 20),
            GeneratedCardField(
              controller: controllers.facilityCode,
              label: localizations.facility_code,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) => validateIntRange(
                value,
                localizations,
                min: 0,
                max: hidFormatLimits(_currentHidType()).facilityCode,
              ),
              generateTooltip: localizations.generate_field_value,
              onGenerate: () => controllers.facilityCode.text =
                  _newProfile().facilityCode.toString(),
            ),
            const SizedBox(height: 20),
            GeneratedCardField(
              controller: controllers.issueLevel,
              label: localizations.issue_level,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) => validateIntRange(
                value,
                localizations,
                min: 0,
                max: hidFormatLimits(_currentHidType()).issueLevel,
              ),
              generateTooltip: localizations.generate_field_value,
              onGenerate: () => controllers.issueLevel.text =
                  _newProfile().issueLevel.toString(),
            ),
            const SizedBox(height: 20),
            GeneratedCardField(
              controller: controllers.oem,
              label: 'OEM',
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: (value) => validateIntRange(
                value,
                localizations,
                min: 0,
                max: hidFormatLimits(_currentHidType()).oem,
              ),
              generateTooltip: localizations.generate_field_value,
              onGenerate: () =>
                  controllers.oem.text = _newProfile().oem.toString(),
            ),
          ],
        ],
      ],
    );
  }
}
