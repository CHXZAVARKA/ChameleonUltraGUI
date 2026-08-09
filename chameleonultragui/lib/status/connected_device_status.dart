import 'dart:async';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:flutter/widgets.dart';

enum StatusSurface { home, slotManager }

enum BatteryAvailability { loading, available, unavailable }

enum ModeAvailability { loading, available, unavailable }

enum ConnectedDeviceMode { emulator, reader }

enum ModeActionOutcome {
  confirmed,
  failed,
  unsupported,
  busy,
  connectionChanged,
}

enum SlotFieldAvailability { confirmed, unavailable }

enum SlotsAvailability { loading, available, partial, stale, unavailable }

enum SlotFacet { types, enabledStates, names, activeSlot }

@immutable
class SlotField<T> {
  const SlotField.confirmed(this.value)
      : availability = SlotFieldAvailability.confirmed;

  const SlotField.unavailable()
      : availability = SlotFieldAvailability.unavailable,
        value = null;

  final SlotFieldAvailability availability;
  final T? value;

  bool get isConfirmed => availability == SlotFieldAvailability.confirmed;

  @override
  bool operator ==(Object other) =>
      other is SlotField<T> &&
      other.availability == availability &&
      other.value == value;

  @override
  int get hashCode => Object.hash(availability, value);
}

@immutable
class SlotFrequencyStatus {
  const SlotFrequencyStatus({
    required this.type,
    required this.enabled,
    required this.name,
  });

  const SlotFrequencyStatus.unavailable()
      : type = const SlotField<TagType>.unavailable(),
        enabled = const SlotField<bool>.unavailable(),
        name = const SlotField<String>.unavailable();

  final SlotField<TagType> type;
  final SlotField<bool> enabled;
  final SlotField<String> name;

  bool get isConfigured => type.value != null && type.value != TagType.unknown;

  @override
  bool operator ==(Object other) =>
      other is SlotFrequencyStatus &&
      other.type == type &&
      other.enabled == enabled &&
      other.name == name;

  @override
  int get hashCode => Object.hash(type, enabled, name);
}

@immutable
class DeviceSlotStatus {
  const DeviceSlotStatus({
    required this.index,
    required this.hf,
    required this.lf,
  });

  const DeviceSlotStatus.unavailable(int index)
      : this(
          index: index,
          hf: const SlotFrequencyStatus.unavailable(),
          lf: const SlotFrequencyStatus.unavailable(),
        );

  final int index;
  final SlotFrequencyStatus hf;
  final SlotFrequencyStatus lf;

  bool get isConfigured => hf.isConfigured || lf.isConfigured;

  @override
  bool operator ==(Object other) =>
      other is DeviceSlotStatus &&
      other.index == index &&
      other.hf == hf &&
      other.lf == lf;

  @override
  int get hashCode => Object.hash(index, hf, lf);
}

@immutable
class SlotsStatus {
  SlotsStatus({
    required this.availability,
    required List<DeviceSlotStatus> slots,
    required this.activeSlot,
    Set<SlotFacet> unavailableFacets = const {},
    Set<SlotFacet> staleFacets = const {},
  })  : assert(slots.length == 8),
        slots = List.unmodifiable(slots),
        unavailableFacets = Set.unmodifiable(unavailableFacets),
        staleFacets = Set.unmodifiable(staleFacets);

  factory SlotsStatus.loading() => SlotsStatus(
        availability: SlotsAvailability.loading,
        slots: List.generate(8, DeviceSlotStatus.unavailable),
        activeSlot: const SlotField<int>.unavailable(),
        unavailableFacets: SlotFacet.values.toSet(),
      );

  final SlotsAvailability availability;
  final List<DeviceSlotStatus> slots;
  final SlotField<int> activeSlot;
  final Set<SlotFacet> unavailableFacets;
  final Set<SlotFacet> staleFacets;

  bool get hasConfirmedData => SlotFacet.values.any(isFacetConfirmed);

  bool isFacetConfirmed(SlotFacet facet) {
    switch (facet) {
      case SlotFacet.types:
        return slots.every(
          (slot) => slot.hf.type.isConfirmed && slot.lf.type.isConfirmed,
        );
      case SlotFacet.enabledStates:
        return slots.every(
          (slot) => slot.hf.enabled.isConfirmed && slot.lf.enabled.isConfirmed,
        );
      case SlotFacet.names:
        return slots.every(
          (slot) => slot.hf.name.isConfirmed && slot.lf.name.isConfirmed,
        );
      case SlotFacet.activeSlot:
        return activeSlot.isConfirmed;
    }
  }

  bool get hasConfirmedTypes =>
      !unavailableFacets.contains(SlotFacet.types) &&
      slots.every(
          (slot) => slot.hf.type.isConfirmed && slot.lf.type.isConfirmed);

  SlotsStatus copyWith({
    SlotsAvailability? availability,
    List<DeviceSlotStatus>? slots,
    SlotField<int>? activeSlot,
    Set<SlotFacet>? unavailableFacets,
    Set<SlotFacet>? staleFacets,
  }) =>
      SlotsStatus(
        availability: availability ?? this.availability,
        slots: slots ?? this.slots,
        activeSlot: activeSlot ?? this.activeSlot,
        unavailableFacets: unavailableFacets ?? this.unavailableFacets,
        staleFacets: staleFacets ?? this.staleFacets,
      );

  @override
  bool operator ==(Object other) {
    if (other is! SlotsStatus ||
        other.availability != availability ||
        other.activeSlot != activeSlot ||
        !_setEquals(other.unavailableFacets, unavailableFacets) ||
        !_setEquals(other.staleFacets, staleFacets) ||
        other.slots.length != slots.length) {
      return false;
    }
    for (var index = 0; index < slots.length; index++) {
      if (other.slots[index] != slots[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        availability,
        activeSlot,
        Object.hashAll(slots),
        unavailableFacets.fold<int>(
          0,
          (hash, facet) => hash ^ facet.hashCode,
        ),
        staleFacets.fold<int>(0, (hash, facet) => hash ^ facet.hashCode),
      );
}

bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

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
class ModeStatus {
  const ModeStatus._({
    required this.availability,
    this.confirmedMode,
    this.pendingMode,
  });

  const ModeStatus.loading() : this._(availability: ModeAvailability.loading);

  const ModeStatus.unavailable()
      : this._(availability: ModeAvailability.unavailable);

  const ModeStatus.available(ConnectedDeviceMode mode)
      : this._(
          availability: ModeAvailability.available,
          confirmedMode: mode,
        );

  const ModeStatus.pending({
    required ConnectedDeviceMode confirmedMode,
    required ConnectedDeviceMode pendingMode,
  }) : this._(
          availability: ModeAvailability.available,
          confirmedMode: confirmedMode,
          pendingMode: pendingMode,
        );

  final ModeAvailability availability;
  final ConnectedDeviceMode? confirmedMode;
  final ConnectedDeviceMode? pendingMode;

  @override
  bool operator ==(Object other) =>
      other is ModeStatus &&
      other.availability == availability &&
      other.confirmedMode == confirmedMode &&
      other.pendingMode == pendingMode;

  @override
  int get hashCode => Object.hash(availability, confirmedMode, pendingMode);
}

@immutable
class DeviceStatusSnapshot {
  const DeviceStatusSnapshot({
    required this.identity,
    required this.battery,
    required this.mode,
    required this.slots,
  });

  final DeviceIdentityStatus identity;
  final BatteryStatus battery;
  final ModeStatus mode;
  final SlotsStatus slots;

  DeviceStatusSnapshot copyWith({
    BatteryStatus? battery,
    ModeStatus? mode,
    SlotsStatus? slots,
  }) =>
      DeviceStatusSnapshot(
        identity: identity,
        battery: battery ?? this.battery,
        mode: mode ?? this.mode,
        slots: slots ?? this.slots,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceStatusSnapshot &&
      other.identity == identity &&
      other.battery == battery &&
      other.mode == mode &&
      other.slots == slots;

  @override
  int get hashCode => Object.hash(identity, battery, mode, slots);
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
          mode: session.connector.device == ChameleonDevice.lite
              ? const ModeStatus.available(ConnectedDeviceMode.emulator)
              : const ModeStatus.loading(),
          slots: SlotsStatus.loading(),
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
  Future<void>? _modeRefresh;
  Future<void>? _slotsRefresh;
  final Object _backgroundOperationGroup = Object();
  int _homePresenceCount = 0;
  int _slotManagerPresenceCount = 0;
  bool _disposed = false;

  StatusPresence present(StatusSurface surface) {
    switch (surface) {
      case StatusSurface.home:
        _homePresenceCount++;
        if (_homePresenceCount == 1 && _isAppActive) {
          unawaited(_refreshHomeOnEntry());
          _startBatteryTimer();
        }
        return StatusPresence._(() => _leaveHome());
      case StatusSurface.slotManager:
        _slotManagerPresenceCount++;
        if (_slotManagerPresenceCount == 1 && _isAppActive) {
          unawaited(refreshSlots());
        }
        return StatusPresence._(() => _leaveSlotManager());
    }
  }

  Future<void> _refreshHomeOnEntry() async {
    final batteryRefresh = refreshBattery();
    final modeRefresh = refreshMode();
    final slotsRefresh = refreshSlots();
    await Future.wait([batteryRefresh, modeRefresh, slotsRefresh]);
  }

  Future<void> _refreshHomeAfterResume() async {
    final batteryRefresh = refreshBattery();
    final slotsRefresh = refreshSlots();
    await Future.wait([batteryRefresh, slotsRefresh]);
  }

  Future<void> refreshMode() {
    if (_session.connector.device == ChameleonDevice.lite) {
      return Future.value();
    }
    final currentRefresh = _modeRefresh;
    if (currentRefresh != null) {
      return currentRefresh;
    }

    final refresh = _refreshMode();
    _modeRefresh = refresh;
    return refresh.whenComplete(() {
      if (identical(_modeRefresh, refresh)) {
        _modeRefresh = null;
      }
    });
  }

  Future<void> _refreshMode() async {
    try {
      while (_canPublish) {
        final result = await _rfOperations.tryRunBackground<bool>(
          _session.communicator.isReaderDeviceMode,
          group: _backgroundOperationGroup,
        );
        if (result.acquired) {
          if (_canPublish) {
            _publish(
              _snapshot.copyWith(
                mode: ModeStatus.available(
                  result.value!
                      ? ConnectedDeviceMode.reader
                      : ConnectedDeviceMode.emulator,
                ),
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
      if (_canPublish && _snapshot.mode.confirmedMode == null) {
        _publish(_snapshot.copyWith(mode: const ModeStatus.unavailable()));
      }
    }
  }

  Future<ModeActionOutcome> switchMode(ConnectedDeviceMode target) async {
    if (!_canPublish) {
      return ModeActionOutcome.connectionChanged;
    }
    if (_session.connector.device == ChameleonDevice.lite) {
      return target == ConnectedDeviceMode.emulator
          ? ModeActionOutcome.confirmed
          : ModeActionOutcome.unsupported;
    }

    final previous = _snapshot.mode;
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
      _snapshot.copyWith(
        mode: ModeStatus.pending(
          confirmedMode: previous.confirmedMode!,
          pendingMode: target,
        ),
      ),
    );
    return _rfOperations.runForeground(() async {
      if (!_canPublish) {
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

      bool? isReader;
      Object? readError;
      StackTrace? readStackTrace;
      try {
        isReader = await _session.communicator.isReaderDeviceMode();
      } catch (error, stackTrace) {
        readError = error;
        readStackTrace = stackTrace;
      }

      if (!_canPublish) {
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
      if (commandError == null && readError == null && confirmed == target) {
        _publish(_snapshot.copyWith(mode: ModeStatus.available(target)));
        return ModeActionOutcome.confirmed;
      }

      if (commandError == null && readError == null) {
        _session.appState.log?.w(
          'Connected-device mode did not match the requested mode',
        );
      }
      _publish(_snapshot.copyWith(mode: previous));
      return ModeActionOutcome.failed;
    });
  }

  Future<void> refreshSlots() {
    final currentRefresh = _slotsRefresh;
    if (currentRefresh != null) {
      return currentRefresh;
    }

    final refresh = _refreshSlots();
    _slotsRefresh = refresh;
    return refresh.whenComplete(() {
      if (identical(_slotsRefresh, refresh)) {
        _slotsRefresh = null;
      }
    });
  }

  Future<void> _refreshSlots() async {
    try {
      while (_canPublish) {
        final result = await _rfOperations.tryRunBackground<SlotsStatus?>(
          () => _readSlots(_snapshot.slots),
          group: _backgroundOperationGroup,
        );
        if (result.acquired) {
          final status = result.value;
          if (_canPublish && status != null) {
            _publish(_snapshot.copyWith(slots: status));
          }
          return;
        }
        await _rfOperations.waitUntilIdle();
      }
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to refresh connected-device slots',
        error: error,
        stackTrace: stackTrace,
      );
      if (_canPublish) {
        _publish(_snapshot.copyWith(slots: _failedSlots(_snapshot.slots)));
      }
    }
  }

  Future<bool> activateSlot(int slot) async {
    if (slot < 0 || slot >= 8 || !_canPublish) {
      return false;
    }
    try {
      return await _rfOperations.runForeground(() async {
        if (!_session.isCurrent) {
          return false;
        }
        await _session.communicator.activateSlot(slot);
        if (!_canPublish) {
          return false;
        }
        final confirmedSlot = await _session.communicator.getActiveSlot();
        if (!_canPublish) {
          return false;
        }
        if (confirmedSlot < 0 || confirmedSlot >= 8) {
          throw RangeError.range(confirmedSlot, 0, 7, 'activeSlot');
        }
        final currentSlots = _snapshot.slots;
        final staleFacets = {...currentSlots.staleFacets}
          ..remove(SlotFacet.activeSlot);
        final unavailableFacets = {...currentSlots.unavailableFacets}
          ..remove(SlotFacet.activeSlot);
        _publish(
          _snapshot.copyWith(
            slots: currentSlots.copyWith(
              availability: _slotsAvailability(staleFacets, unavailableFacets),
              activeSlot: SlotField.confirmed(confirmedSlot),
              staleFacets: staleFacets,
              unavailableFacets: unavailableFacets,
            ),
          ),
        );
        return confirmedSlot == slot;
      });
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to activate connected-device slot',
        error: error,
        stackTrace: stackTrace,
      );
      if (_canPublish && _snapshot.slots.activeSlot.isConfirmed) {
        final currentSlots = _snapshot.slots;
        _publish(
          _snapshot.copyWith(
            slots: currentSlots.copyWith(
              availability: SlotsAvailability.stale,
              staleFacets: {
                ...currentSlots.staleFacets,
                SlotFacet.activeSlot,
              },
            ),
          ),
        );
      }
      return false;
    }
  }

  Future<SlotsStatus?> _readSlots(SlotsStatus previous) async {
    final failures = <SlotFacet>{};
    List<SlotTypes>? types;
    List<EnabledSlotInfo>? enabled;
    List<SlotNames>? names;
    int? activeSlot;

    if (!_canPublish) {
      return null;
    }
    try {
      types = await _session.communicator.getSlotTagTypes();
      if (!_canPublish) {
        return null;
      }
      if (types.length != 8) {
        throw StateError('Expected 8 slot type records, got ${types.length}');
      }
    } catch (error, stackTrace) {
      if (!_canPublish) {
        return null;
      }
      types = null;
      failures.add(SlotFacet.types);
      _logSlotFacetFailure(SlotFacet.types, error, stackTrace);
    }
    if (!_canPublish) {
      return null;
    }
    try {
      enabled = await _session.communicator.getEnabledSlots();
      if (!_canPublish) {
        return null;
      }
      if (enabled.length != 8) {
        throw StateError(
          'Expected 8 enabled-slot records, got ${enabled.length}',
        );
      }
    } catch (error, stackTrace) {
      if (!_canPublish) {
        return null;
      }
      enabled = null;
      failures.add(SlotFacet.enabledStates);
      _logSlotFacetFailure(SlotFacet.enabledStates, error, stackTrace);
    }
    if (!_canPublish) {
      return null;
    }
    try {
      names = await _session.communicator.getSlotTagNames();
      if (!_canPublish) {
        return null;
      }
      if (names.length != 8) {
        throw StateError('Expected 8 slot-name records, got ${names.length}');
      }
    } catch (error, stackTrace) {
      if (!_canPublish) {
        return null;
      }
      names = null;
      failures.add(SlotFacet.names);
      _logSlotFacetFailure(SlotFacet.names, error, stackTrace);
    }
    if (!_canPublish) {
      return null;
    }
    try {
      final readActiveSlot = await _session.communicator.getActiveSlot();
      if (!_canPublish) {
        return null;
      }
      if (readActiveSlot < 0 || readActiveSlot >= 8) {
        throw RangeError.range(readActiveSlot, 0, 7, 'activeSlot');
      }
      activeSlot = readActiveSlot;
    } catch (error, stackTrace) {
      if (!_canPublish) {
        return null;
      }
      failures.add(SlotFacet.activeSlot);
      _logSlotFacetFailure(SlotFacet.activeSlot, error, stackTrace);
    }

    final normalized = List.generate(8, (index) {
      final old = previous.slots[index];
      final type = index < (types?.length ?? 0) ? types![index] : null;
      final enabledInfo =
          index < (enabled?.length ?? 0) ? enabled![index] : null;
      final slotNames = index < (names?.length ?? 0) ? names![index] : null;
      return DeviceSlotStatus(
        index: index,
        hf: SlotFrequencyStatus(
          type: type == null
              ? _preservedOrUnavailable(old.hf.type)
              : SlotField.confirmed(type.hf),
          enabled: enabledInfo == null
              ? _preservedOrUnavailable(old.hf.enabled)
              : SlotField.confirmed(enabledInfo.hf),
          name: slotNames == null
              ? _preservedOrUnavailable(old.hf.name)
              : SlotField.confirmed(slotNames.hf),
        ),
        lf: SlotFrequencyStatus(
          type: type == null
              ? _preservedOrUnavailable(old.lf.type)
              : SlotField.confirmed(type.lf),
          enabled: enabledInfo == null
              ? _preservedOrUnavailable(old.lf.enabled)
              : SlotField.confirmed(enabledInfo.lf),
          name: slotNames == null
              ? _preservedOrUnavailable(old.lf.name)
              : SlotField.confirmed(slotNames.lf),
        ),
      );
    });

    final staleFacets = failures.where(previous.isFacetConfirmed).toSet();
    final unavailableFacets =
        failures.where((facet) => !previous.isFacetConfirmed(facet)).toSet();

    return SlotsStatus(
      availability: _slotsAvailability(staleFacets, unavailableFacets),
      slots: normalized,
      activeSlot: activeSlot == null
          ? _preservedOrUnavailable(previous.activeSlot)
          : SlotField.confirmed(activeSlot),
      unavailableFacets: unavailableFacets,
      staleFacets: staleFacets,
    );
  }

  SlotField<T> _preservedOrUnavailable<T>(SlotField<T> previous) =>
      previous.isConfirmed ? previous : SlotField<T>.unavailable();

  SlotsStatus _failedSlots(SlotsStatus previous) {
    final staleFacets =
        SlotFacet.values.where(previous.isFacetConfirmed).toSet();
    final unavailableFacets = SlotFacet.values
        .where((facet) => !previous.isFacetConfirmed(facet))
        .toSet();
    return previous.copyWith(
      availability: _slotsAvailability(staleFacets, unavailableFacets),
      staleFacets: staleFacets,
      unavailableFacets: unavailableFacets,
    );
  }

  SlotsAvailability _slotsAvailability(
    Set<SlotFacet> staleFacets,
    Set<SlotFacet> unavailableFacets,
  ) {
    if (staleFacets.isNotEmpty) {
      return SlotsAvailability.stale;
    }
    if (unavailableFacets.isEmpty) {
      return SlotsAvailability.available;
    }
    return unavailableFacets.length == SlotFacet.values.length
        ? SlotsAvailability.unavailable
        : SlotsAvailability.partial;
  }

  void _logSlotFacetFailure(
    SlotFacet facet,
    Object error,
    StackTrace stackTrace,
  ) {
    _session.appState.log?.w(
      'Unable to read connected-device slot facet: ${facet.name}',
      error: error,
      stackTrace: stackTrace,
    );
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
        group: _backgroundOperationGroup,
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

  void _leaveSlotManager() {
    if (_slotManagerPresenceCount > 0) {
      _slotManagerPresenceCount--;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_homePresenceCount == 0) {
      if (state == AppLifecycleState.resumed && _slotManagerPresenceCount > 0) {
        unawaited(refreshSlots());
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshHomeAfterResume());
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
