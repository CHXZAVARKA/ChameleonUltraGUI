import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum _AnimationModeAvailability {
  loading,
  available,
  unsupported,
  unavailable,
}

/// A session-bound editor for the LED animation mode stored on the device.
///
/// The selected value always comes from a device read. A write is not
/// published as successful until a follow-up read confirms the device state.
class AnimationModeSetting extends StatefulWidget {
  const AnimationModeSetting({super.key});

  @override
  State<AnimationModeSetting> createState() => _AnimationModeSettingState();
}

class _AnimationModeSettingState extends State<AnimationModeSetting> {
  _AnimationModeAvailability _availability = _AnimationModeAvailability.loading;
  ConnectedDeviceSession? _session;
  AnimationSetting? _confirmedMode;
  bool _pending = false;
  bool _showUpdateError = false;
  int _operationGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _operationGeneration++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_operationGeneration;
    if (mounted) {
      setState(() {
        _availability = _AnimationModeAvailability.loading;
        _session = null;
        _confirmedMode = null;
        _pending = false;
        _showUpdateError = false;
      });
    }

    final appState = context.read<ChameleonGUIState>();
    final session = ConnectedDeviceSession.capture(appState);
    if (session == null) {
      _publishUnavailable(generation);
      return;
    }

    try {
      final capabilities = await session.communicator.getDeviceCapabilities();
      if (!_canPublish(generation, session)) {
        _publishUnavailable(generation);
        return;
      }

      final requiredCommands = <int>{
        ChameleonCommand.getAnimationMode.value,
        ChameleonCommand.setAnimationMode.value,
        ChameleonCommand.saveSettings.value,
      };
      if (!capabilities.toSet().containsAll(requiredCommands)) {
        setState(() {
          _availability = _AnimationModeAvailability.unsupported;
          _session = session;
          _confirmedMode = null;
        });
        return;
      }

      final mode = await session.communicator.getAnimationMode();
      if (!_canPublish(generation, session)) {
        _publishUnavailable(generation);
        return;
      }
      setState(() {
        _availability = _AnimationModeAvailability.available;
        _session = session;
        _confirmedMode = mode;
      });
    } catch (_) {
      _publishUnavailable(generation);
    }
  }

  Future<void> _selectMode(AnimationSetting requestedMode) async {
    if (_pending ||
        _availability != _AnimationModeAvailability.available ||
        requestedMode == _confirmedMode) {
      return;
    }

    final session = _session;
    if (session == null || !session.isCurrent) {
      _publishUnavailable(++_operationGeneration);
      return;
    }

    final generation = ++_operationGeneration;
    setState(() {
      _pending = true;
      _showUpdateError = false;
    });

    try {
      await session.communicator.setAnimationMode(requestedMode);
      if (!_canPublish(generation, session)) {
        _publishUnavailable(generation);
        return;
      }

      await session.communicator.saveSettings();
      if (!_canPublish(generation, session)) {
        _publishUnavailable(generation);
        return;
      }

      final confirmedMode = await session.communicator.getAnimationMode();
      if (!_canPublish(generation, session)) {
        _publishUnavailable(generation);
        return;
      }

      setState(() {
        _confirmedMode = confirmedMode;
        _pending = false;
        _showUpdateError = confirmedMode != requestedMode;
      });
      if (confirmedMode == requestedMode) {
        session.appState.changesMade();
      }
    } catch (_) {
      await _reconcileAfterFailure(generation, session);
    }
  }

  Future<void> _reconcileAfterFailure(
    int generation,
    ConnectedDeviceSession session,
  ) async {
    if (!_canPublish(generation, session)) {
      _publishUnavailable(generation);
      return;
    }

    try {
      final confirmedMode = await session.communicator.getAnimationMode();
      if (!_canPublish(generation, session)) {
        _publishUnavailable(generation);
        return;
      }
      setState(() {
        _availability = _AnimationModeAvailability.available;
        _confirmedMode = confirmedMode;
        _pending = false;
        _showUpdateError = true;
      });
    } catch (_) {
      _publishUnavailable(generation);
    }
  }

  bool _canPublish(int generation, ConnectedDeviceSession session) {
    return mounted && generation == _operationGeneration && session.isCurrent;
  }

  void _publishUnavailable(int generation) {
    if (!mounted || generation != _operationGeneration) {
      return;
    }
    setState(() {
      _availability = _AnimationModeAvailability.unavailable;
      _session = null;
      _confirmedMode = null;
      _pending = false;
      _showUpdateError = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final isAvailable = _availability == _AnimationModeAvailability.available;
    final isLoading =
        _availability == _AnimationModeAvailability.loading || _pending;

    final String? helperText;
    final String? errorText;
    switch (_availability) {
      case _AnimationModeAvailability.unsupported:
        helperText = localizations.animation_mode_unsupported;
        errorText = null;
      case _AnimationModeAvailability.unavailable:
        helperText = null;
        errorText = localizations.animation_mode_unavailable;
      case _AnimationModeAvailability.loading:
      case _AnimationModeAvailability.available:
        helperText = null;
        errorText = _showUpdateError
            ? localizations.animation_mode_update_failed
            : null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            labelText: localizations.animations,
            helperText: helperText,
            errorText: errorText,
            suffixIcon: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      key: Key('animation-mode-progress'),
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<AnimationSetting>(
              key: const Key('animation-mode-dropdown'),
              isExpanded: true,
              value: _confirmedMode,
              hint: Text(
                _availability == _AnimationModeAvailability.loading
                    ? localizations.loading
                    : localizations.unavailable,
              ),
              items: [
                DropdownMenuItem(
                  value: AnimationSetting.full,
                  child: Text(localizations.full),
                ),
                DropdownMenuItem(
                  value: AnimationSetting.minimal,
                  child: Text(localizations.animation_mode_minimal),
                ),
                DropdownMenuItem(
                  value: AnimationSetting.symmetric,
                  child: Text(localizations.symmetric),
                ),
                DropdownMenuItem(
                  value: AnimationSetting.none,
                  child: Text(localizations.none),
                ),
              ],
              onChanged: isAvailable && !_pending
                  ? (mode) {
                      if (mode != null) {
                        _selectMode(mode);
                      }
                    }
                  : null,
            ),
          ),
        ),
        if (_availability == _AnimationModeAvailability.unavailable) ...[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: OutlinedButton.icon(
              key: const Key('animation-mode-retry'),
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(localizations.retry),
            ),
          ),
        ],
      ],
    );
  }
}
