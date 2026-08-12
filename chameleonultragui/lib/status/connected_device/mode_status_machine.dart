part of '../connected_device_status.dart';

class _ModeStatusMachine {
  _ModeStatusMachine({
    required ConnectedDeviceSession session,
    required RfOperationCoordinator rfOperations,
    required Object operationGroup,
    required bool Function() canPublish,
    required ModeStatus Function() currentStatus,
    required void Function(ModeStatus status) publish,
  })  : _session = session,
        _rfOperations = rfOperations,
        _operationGroup = operationGroup,
        _canPublish = canPublish,
        _currentStatus = currentStatus,
        _publish = publish;

  final ConnectedDeviceSession _session;
  final RfOperationCoordinator _rfOperations;
  final Object _operationGroup;
  final bool Function() _canPublish;
  final ModeStatus Function() _currentStatus;
  final void Function(ModeStatus status) _publish;

  Future<void>? _activeRefresh;

  Future<void> refresh() {
    if (_session.connector.device == ChameleonDevice.lite) {
      return Future.value();
    }
    final currentRefresh = _activeRefresh;
    if (currentRefresh != null) {
      return currentRefresh;
    }

    final refresh = _readAndPublish();
    _activeRefresh = refresh;
    return refresh.whenComplete(() {
      if (identical(_activeRefresh, refresh)) {
        _activeRefresh = null;
      }
    });
  }

  Future<void> _readAndPublish() async {
    try {
      while (_canPublish()) {
        final result = await _rfOperations.tryRunBackground<bool>(
          _session.communicator.isReaderDeviceMode,
          group: _operationGroup,
        );
        if (result.acquired) {
          if (_canPublish()) {
            final confirmed = result.value!
                ? ConnectedDeviceMode.reader
                : ConnectedDeviceMode.emulator;
            final pending = _currentStatus().pendingMode;
            _publish(
              pending == null
                  ? ModeStatus.available(confirmed)
                  : ModeStatus.pending(
                      confirmedMode: confirmed,
                      pendingMode: pending,
                    ),
            );
          }
          return;
        }
        await _rfOperations.waitUntilIdle();
      }
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to read connected-device mode',
        error: error,
        stackTrace: stackTrace,
      );
      if (_canPublish() && _currentStatus().confirmedMode == null) {
        _publish(const ModeStatus.unavailable());
      }
    }
  }

  Future<ModeActionOutcome> switchTo(ConnectedDeviceMode target) async {
    if (!_canPublish()) {
      return ModeActionOutcome.connectionChanged;
    }
    if (_session.connector.device == ChameleonDevice.lite) {
      return target == ConnectedDeviceMode.emulator
          ? ModeActionOutcome.confirmed
          : ModeActionOutcome.unsupported;
    }

    final previous = _currentStatus();
    if (previous.pendingMode != null) {
      return ModeActionOutcome.busy;
    }
    if (previous.availability != ModeAvailability.available ||
        previous.confirmedMode == null) {
      return ModeActionOutcome.failed;
    }
    if (previous.confirmedMode == target) {
      return ModeActionOutcome.confirmed;
    }

    _publish(
      ModeStatus.pending(
        confirmedMode: previous.confirmedMode!,
        pendingMode: target,
      ),
    );
    return _rfOperations.runForeground(() async {
      if (!_canPublish()) {
        return ModeActionOutcome.connectionChanged;
      }

      Object? commandError;
      StackTrace? commandStackTrace;
      try {
        await _session.communicator.setReaderDeviceMode(
          target == ConnectedDeviceMode.reader,
        );
      } catch (error, stackTrace) {
        commandError = error;
        commandStackTrace = stackTrace;
      }
      if (!_canPublish()) {
        return ModeActionOutcome.connectionChanged;
      }

      bool? isReader;
      Object? readError;
      StackTrace? readStackTrace;
      try {
        isReader = await _session.communicator.isReaderDeviceMode();
      } catch (error, stackTrace) {
        readError = error;
        readStackTrace = stackTrace;
      }

      if (!_canPublish()) {
        return ModeActionOutcome.connectionChanged;
      }
      if (commandError != null) {
        _session.appState.log?.w(
          'Unable to change connected-device mode',
          error: commandError,
          stackTrace: commandStackTrace,
        );
      }
      if (readError != null) {
        _session.appState.log?.w(
          'Unable to confirm connected-device mode',
          error: readError,
          stackTrace: readStackTrace,
        );
      }

      final confirmed = isReader == null
          ? null
          : isReader
              ? ConnectedDeviceMode.reader
              : ConnectedDeviceMode.emulator;
      if (readError == null && confirmed != null) {
        _publish(ModeStatus.available(confirmed));
        if (confirmed == target) {
          return ModeActionOutcome.confirmed;
        }
        if (commandError == null) {
          _session.appState.log?.w(
            'Connected-device mode did not match the requested mode',
          );
        }
        return ModeActionOutcome.failed;
      }
      final latestConfirmed =
          _currentStatus().confirmedMode ?? previous.confirmedMode!;
      _publish(ModeStatus.available(latestConfirmed));
      return ModeActionOutcome.failed;
    });
  }

  ModeStatus? mergePendingAction(ModeStatus? reconciled) {
    if (reconciled == null) {
      return null;
    }
    final current = _currentStatus();
    return current.pendingMode == null
        ? reconciled
        : ModeStatus._(
            availability: reconciled.availability,
            confirmedMode: reconciled.confirmedMode,
            pendingMode: current.pendingMode,
          );
  }

  Future<ModeStatus?> readAfterSlotMutation() async {
    try {
      final isReader = await _session.communicator.isReaderDeviceMode();
      if (!_canPublish()) {
        return null;
      }
      return ModeStatus.available(
        isReader ? ConnectedDeviceMode.reader : ConnectedDeviceMode.emulator,
      );
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to reconcile connected-device mode after slot mutation',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_canPublish()) {
        return null;
      }
      return ModeStatus.unavailable(
        confirmedMode: _currentStatus().confirmedMode,
      );
    }
  }
}
