import 'dart:async';

import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/main.dart';

typedef ContinuousScanRead = Future<bool> Function(
  ConnectedDeviceSession session,
  bool Function() canContinue,
);

class ContinuousScanController {
  ContinuousScanController({
    this.interval = const Duration(seconds: 2),
    this.maxDuration = const Duration(minutes: 1),
  });

  final Duration interval;
  final Duration maxDuration;

  _ContinuousScanHandle? _activeScan;

  bool get isActive => _activeScan != null;
  ConnectedDeviceSession? get session => _activeScan?.session;

  Future<void> start({
    required ChameleonGUIState appState,
    required bool Function() isAvailable,
    required ContinuousScanRead read,
    required bool Function() hasResult,
    void Function(bool active)? onStateChanged,
    void Function(
      Object error,
      StackTrace stackTrace,
      ConnectedDeviceSession session,
    )? onError,
  }) async {
    if (isActive) {
      return;
    }

    final session = ConnectedDeviceSession.capture(appState);
    if (session == null) {
      return;
    }

    late final _ContinuousScanHandle handle;
    final timer = Timer.periodic(interval, (_) {
      if (!_canContinue(handle) ||
          DateTime.now().difference(handle.startedAt) > maxDuration) {
        _stop(handle);
        return;
      }
      unawaited(_runTick(handle));
    });
    handle = _ContinuousScanHandle(
      appState: appState,
      session: session,
      timer: timer,
      startedAt: DateTime.now(),
      isAvailable: isAvailable,
      read: read,
      hasResult: hasResult,
      onStateChanged: onStateChanged,
      onError: onError,
    );
    _activeScan = handle;
    onStateChanged?.call(true);

    await _runTick(handle);
  }

  void stop() {
    final handle = _activeScan;
    if (handle != null) {
      _stop(handle);
    }
  }

  void dispose() {
    final handle = _activeScan;
    if (handle != null) {
      _stop(handle, notify: false);
    }
  }

  bool _owns(_ContinuousScanHandle handle) => identical(_activeScan, handle);

  bool _canContinue(_ContinuousScanHandle handle) =>
      _owns(handle) && handle.isAvailable() && handle.session.isCurrent;

  Future<void> _runTick(_ContinuousScanHandle handle) async {
    if (!_canContinue(handle)) {
      _stop(handle);
      return;
    }

    try {
      final result = await handle.appState.rfOperations.tryRunBackground(
        () => handle.read(
          handle.session,
          () => _canContinue(handle),
        ),
      );
      if (!_owns(handle)) {
        return;
      }
      if (!_canContinue(handle)) {
        _stop(handle);
        return;
      }
      if (!result.acquired) {
        return;
      }
      if (result.value != true || handle.hasResult()) {
        _stop(handle);
      }
    } catch (error, stackTrace) {
      if (!_owns(handle)) {
        return;
      }
      handle.onError?.call(error, stackTrace, handle.session);
      _stop(handle);
    }
  }

  void _stop(_ContinuousScanHandle handle, {bool notify = true}) {
    if (!_owns(handle)) {
      return;
    }

    handle.timer.cancel();
    _activeScan = null;
    if (notify) {
      handle.onStateChanged?.call(false);
    }
  }
}

class _ContinuousScanHandle {
  const _ContinuousScanHandle({
    required this.appState,
    required this.session,
    required this.timer,
    required this.startedAt,
    required this.isAvailable,
    required this.read,
    required this.hasResult,
    required this.onStateChanged,
    required this.onError,
  });

  final ChameleonGUIState appState;
  final ConnectedDeviceSession session;
  final Timer timer;
  final DateTime startedAt;
  final bool Function() isAvailable;
  final ContinuousScanRead read;
  final bool Function() hasResult;
  final void Function(bool active)? onStateChanged;
  final void Function(
    Object error,
    StackTrace stackTrace,
    ConnectedDeviceSession session,
  )? onError;
}
