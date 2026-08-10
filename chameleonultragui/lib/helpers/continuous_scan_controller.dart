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
    try {
      onStateChanged?.call(true);
    } catch (error, stackTrace) {
      _deactivate(handle);
      Error.throwWithStackTrace(error, stackTrace);
    }

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
    bool canContinue;
    try {
      canContinue = _canContinue(handle);
    } catch (error, stackTrace) {
      _handleFailure(handle, error, stackTrace);
      return;
    }
    if (!canContinue ||
        DateTime.now().difference(handle.startedAt) > maxDuration) {
      _stop(handle);
      return;
    }

    var shouldStop = false;
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
      canContinue = _canContinue(handle);
      if (!canContinue) {
        shouldStop = true;
      } else if (!result.acquired) {
        return;
      } else {
        shouldStop = result.value != true || handle.hasResult();
      }
    } catch (error, stackTrace) {
      if (!_owns(handle)) {
        return;
      }
      _handleFailure(handle, error, stackTrace);
      return;
    }

    if (shouldStop) {
      _stop(handle);
    }
  }

  void _stop(_ContinuousScanHandle handle, {bool notify = true}) {
    if (!_deactivate(handle)) {
      return;
    }

    if (notify) {
      handle.onStateChanged?.call(false);
    }
  }

  bool _deactivate(_ContinuousScanHandle handle) {
    if (!_owns(handle)) {
      return false;
    }

    handle.timer.cancel();
    _activeScan = null;
    return true;
  }

  void _handleFailure(
    _ContinuousScanHandle handle,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!_deactivate(handle)) {
      return;
    }

    Object? observerError;
    StackTrace? observerStackTrace;
    try {
      handle.onError?.call(error, stackTrace, handle.session);
    } catch (error, stackTrace) {
      observerError = error;
      observerStackTrace = stackTrace;
    }

    try {
      handle.onStateChanged?.call(false);
    } catch (error, stackTrace) {
      observerError ??= error;
      observerStackTrace ??= stackTrace;
    }

    if (observerError != null) {
      Error.throwWithStackTrace(observerError, observerStackTrace!);
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
