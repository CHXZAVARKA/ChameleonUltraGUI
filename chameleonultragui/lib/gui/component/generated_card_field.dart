import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GeneratedCardField extends StatelessWidget {
  const GeneratedCardField({
    super.key,
    required this.controller,
    required this.label,
    this.helperText,
    required this.inputFormatters,
    required this.validator,
    this.onGenerate,
    this.generateTooltip,
  });

  final TextEditingController controller;
  final String label;
  final String? helperText;
  final List<TextInputFormatter> inputFormatters;
  final FormFieldValidator<String> validator;
  final VoidCallback? onGenerate;
  final String? generateTooltip;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        suffixIcon: onGenerate == null
            ? null
            : IconButton(
                icon: const Icon(Icons.casino_outlined),
                tooltip: generateTooltip,
                onPressed: onGenerate,
              ),
      ),
      inputFormatters: inputFormatters,
      validator: validator,
    );
  }
}
