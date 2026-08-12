part of '../connected_device_status.dart';

class _BatteryStatusMachine {
  _BatteryStatusMachine({
    required ConnectedDeviceSession session,
    required RfOperationCoordinator rfOperations,
    required Object operationGroup,
    required bool Function() canPublish,
    required void Function(BatteryStatus status) publish,
  })  : _session = session,
        _rfOperations = rfOperations,
        _operationGroup = operationGroup,
        _canPublish = canPublish,
        _publish = publish;

  final ConnectedDeviceSession _session;
  final RfOperationCoordinator _rfOperations;
  final Object _operationGroup;
  final bool Function() _canPublish;
  final void Function(BatteryStatus status) _publish;

  Future<void>? _activeRefresh;

  Future<void> refresh() {
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
      final result = await _rfOperations.tryRunBackground<BatteryCharge>(
        _session.communicator.getBatteryCharge,
        group: _operationGroup,
      );
      if (!result.acquired || !_canPublish()) {
        return;
      }

      final charge = result.value!;
      _publish(
        BatteryStatus.available(
          percent: charge.percent,
          voltageMillivolts: charge.voltage,
        ),
      );
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to read connected-device battery status',
        error: error,
        stackTrace: stackTrace,
      );
      if (_canPublish()) {
        _publish(const BatteryStatus.unavailable());
      }
    }
  }
}
