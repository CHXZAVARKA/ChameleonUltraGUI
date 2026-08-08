import 'dart:async';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:flutter/widgets.dart';

enum StatusSurface { home }

enum BatteryAvailability { loading, available, unavailable }

@immutable
class DeviceIdentityStatus {
  const DeviceIdentityStatus({
    required this.device,
    required this.portName,
    required this.connectionType,
  });

  final ChameleonDevice device;
  final String portName;
  final ConnectionType connectionType;

  @override
  bool operator ==(Object other) =>
      other is DeviceIdentityStatus &&
      other.device == device &&
      other.portName == portName &&
      other.connectionType == connectionType;

  @override
  int get hashCode => Object.hash(device, portName, connectionType);
}

@immutable
class BatteryStatus {
  const BatteryStatus._({
    required this.availability,
    this.percent,
    this.voltageMillivolts,
  });

  const BatteryStatus.loading()
      : this._(availability: BatteryAvailability.loading);

  const BatteryStatus.unavailable()
      : this._(availability: BatteryAvailability.unavailable);

  const BatteryStatus.available({
    required int percent,
    required int voltageMillivolts,
  }) : this._(
          availability: BatteryAvailability.available,
          percent: percent,
          voltageMillivolts: voltageMillivolts,
        );

  final BatteryAvailability availability;
  final int? percent;
  final int? voltageMillivolts;

  @override
  bool operator ==(Object other) =>
      other is BatteryStatus &&
      other.availability == availability &&
      other.percent == percent &&
      other.voltageMillivolts == voltageMillivolts;

  @override
  int get hashCode => Object.hash(availability, percent, voltageMillivolts);
}

@immutable
class DeviceStatusSnapshot {
  const DeviceStatusSnapshot({
    required this.identity,
    required this.battery,
  });

  final DeviceIdentityStatus identity;
  final BatteryStatus battery;

  DeviceStatusSnapshot copyWith({BatteryStatus? battery}) =>
      DeviceStatusSnapshot(
          identity: identity, battery: battery ?? this.battery);

  @override
  bool operator ==(Object other) =>
      other is DeviceStatusSnapshot &&
      other.identity == identity &&
      other.battery == battery;

  @override
  int get hashCode => Object.hash(identity, battery);
}

class StatusPresence {
  StatusPresence._(this._onDispose);

  VoidCallback? _onDispose;

  void dispose() {
    final onDispose = _onDispose;
    _onDispose = null;
    onDispose?.call();
  }
}

class ConnectedDeviceStatus extends ChangeNotifier with WidgetsBindingObserver {
  ConnectedDeviceStatus({
    required ConnectedDeviceSession session,
    required RfOperationCoordinator rfOperations,
    this.batteryPollInterval = const Duration(seconds: 15),
  })  : _session = session,
        _rfOperations = rfOperations,
        _snapshot = DeviceStatusSnapshot(
          identity: DeviceIdentityStatus(
            device: session.connector.device,
            portName: session.connector.portName,
            connectionType: session.connector.connectionType,
          ),
          battery: const BatteryStatus.loading(),
        ) {
    WidgetsBinding.instance.addObserver(this);
  }

  final ConnectedDeviceSession _session;
  final RfOperationCoordinator _rfOperations;
  final Duration batteryPollInterval;

  DeviceStatusSnapshot _snapshot;
  DeviceStatusSnapshot get snapshot => _snapshot;

  Timer? _batteryTimer;
  Future<void>? _batteryRefresh;
  int _homePresenceCount = 0;
  bool _disposed = false;

  StatusPresence present(StatusSurface surface) {
    switch (surface) {
      case StatusSurface.home:
        _homePresenceCount++;
        if (_homePresenceCount == 1 && _isAppActive) {
          unawaited(refreshBattery());
          _startBatteryTimer();
        }
        return StatusPresence._(() => _leaveHome());
    }
  }

  Future<void> refreshBattery() {
    final currentRefresh = _batteryRefresh;
    if (currentRefresh != null) {
      return currentRefresh;
    }

    final refresh = _refreshBattery();
    _batteryRefresh = refresh;
    return refresh.whenComplete(() {
      if (identical(_batteryRefresh, refresh)) {
        _batteryRefresh = null;
      }
    });
  }

  Future<void> _refreshBattery() async {
    try {
      final result = await _rfOperations.tryRunBackground<BatteryCharge>(
        _session.communicator.getBatteryCharge,
      );
      if (!result.acquired || !_canPublish) {
        return;
      }

      final charge = result.value!;
      _publish(
        _snapshot.copyWith(
          battery: BatteryStatus.available(
            percent: charge.percent,
            voltageMillivolts: charge.voltage,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to read connected-device battery status',
        error: error,
        stackTrace: stackTrace,
      );
      if (_canPublish) {
        _publish(
          _snapshot.copyWith(battery: const BatteryStatus.unavailable()),
        );
      }
    }
  }

  bool get _canPublish => !_disposed && _session.isCurrent;

  bool get _isAppActive {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _publish(DeviceStatusSnapshot next) {
    if (next == _snapshot) {
      return;
    }
    _snapshot = next;
    notifyListeners();
  }

  void _startBatteryTimer() {
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(
      batteryPollInterval,
      (_) => unawaited(refreshBattery()),
    );
  }

  void _leaveHome() {
    if (_homePresenceCount == 0) {
      return;
    }
    _homePresenceCount--;
    if (_homePresenceCount == 0) {
      _batteryTimer?.cancel();
      _batteryTimer = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_homePresenceCount == 0) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshBattery());
      _startBatteryTimer();
    } else {
      _batteryTimer?.cancel();
      _batteryTimer = null;
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _batteryTimer?.cancel();
    _batteryTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
