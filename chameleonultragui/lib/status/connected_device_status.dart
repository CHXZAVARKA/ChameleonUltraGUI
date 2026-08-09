import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/flash.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
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

enum FirmwareState {
  checking,
  upToDate,
  updateAvailable,
  updateRequired,
  checkUnavailable,
  demo,
}

enum FirmwareProtocol { loading, current, legacy, unknown }

enum FirmwareCompatibility { loading, compatible, incompatible, unknown }

enum FirmwareCheckResult { checking, succeeded, unavailable, demo }

enum FirmwareInstallOutcome {
  started,
  failed,
  busy,
  notAvailable,
  connectionChanged,
}

@immutable
class FirmwareStatus {
  const FirmwareStatus({
    required this.state,
    required this.protocol,
    required this.compatibility,
    required this.checkResult,
    this.installedVersion,
    this.installedCommit,
    this.latestVersion,
    this.latestCommit,
    this.installing = false,
    this.installationFailed = false,
  });

  const FirmwareStatus.checking()
      : this(
          state: FirmwareState.checking,
          protocol: FirmwareProtocol.loading,
          compatibility: FirmwareCompatibility.loading,
          checkResult: FirmwareCheckResult.checking,
        );

  const FirmwareStatus.demo()
      : this(
          state: FirmwareState.demo,
          protocol: FirmwareProtocol.unknown,
          compatibility: FirmwareCompatibility.unknown,
          checkResult: FirmwareCheckResult.demo,
        );

  final FirmwareState state;
  final String? installedVersion;
  final String? installedCommit;
  final FirmwareProtocol protocol;
  final FirmwareCompatibility compatibility;
  final String? latestVersion;
  final String? latestCommit;
  final FirmwareCheckResult checkResult;
  final bool installing;
  final bool installationFailed;

  FirmwareStatus copyWith({
    FirmwareState? state,
    String? installedVersion,
    String? installedCommit,
    FirmwareProtocol? protocol,
    FirmwareCompatibility? compatibility,
    String? latestVersion,
    String? latestCommit,
    FirmwareCheckResult? checkResult,
    bool? installing,
    bool? installationFailed,
  }) =>
      FirmwareStatus(
        state: state ?? this.state,
        installedVersion: installedVersion ?? this.installedVersion,
        installedCommit: installedCommit ?? this.installedCommit,
        protocol: protocol ?? this.protocol,
        compatibility: compatibility ?? this.compatibility,
        latestVersion: latestVersion ?? this.latestVersion,
        latestCommit: latestCommit ?? this.latestCommit,
        checkResult: checkResult ?? this.checkResult,
        installing: installing ?? this.installing,
        installationFailed: installationFailed ?? this.installationFailed,
      );

  bool get canInstall =>
      state == FirmwareState.updateAvailable ||
      state == FirmwareState.updateRequired;

  @override
  bool operator ==(Object other) =>
      other is FirmwareStatus &&
      other.state == state &&
      other.installedVersion == installedVersion &&
      other.installedCommit == installedCommit &&
      other.protocol == protocol &&
      other.compatibility == compatibility &&
      other.latestVersion == latestVersion &&
      other.latestCommit == latestCommit &&
      other.checkResult == checkResult &&
      other.installing == installing &&
      other.installationFailed == installationFailed;

  @override
  int get hashCode => Object.hash(
        state,
        installedVersion,
        installedCommit,
        protocol,
        compatibility,
        latestVersion,
        latestCommit,
        checkResult,
        installing,
        installationFailed,
      );
}

enum SlotFieldAvailability { confirmed, unavailable }

enum SlotsAvailability { loading, available, partial, stale, unavailable }

enum SlotFacet { types, enabledStates, names, activeSlot }

const Object _keepPendingActivation = Object();

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
    this.pendingActivation,
    Set<SlotFacet> unavailableFacets = const {},
    Set<SlotFacet> staleFacets = const {},
  })  : assert(slots.length == 8),
        assert(
          pendingActivation == null ||
              (pendingActivation >= 0 && pendingActivation < 8),
        ),
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
  final int? pendingActivation;
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
    Object? pendingActivation = _keepPendingActivation,
    Set<SlotFacet>? unavailableFacets,
    Set<SlotFacet>? staleFacets,
  }) =>
      SlotsStatus(
        availability: availability ?? this.availability,
        slots: slots ?? this.slots,
        activeSlot: activeSlot ?? this.activeSlot,
        pendingActivation: identical(
          pendingActivation,
          _keepPendingActivation,
        )
            ? this.pendingActivation
            : pendingActivation as int?,
        unavailableFacets: unavailableFacets ?? this.unavailableFacets,
        staleFacets: staleFacets ?? this.staleFacets,
      );

  @override
  bool operator ==(Object other) {
    if (other is! SlotsStatus ||
        other.availability != availability ||
        other.activeSlot != activeSlot ||
        other.pendingActivation != pendingActivation ||
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
        pendingActivation,
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

  const ModeStatus.unavailable({ConnectedDeviceMode? confirmedMode})
      : this._(
          availability: ModeAvailability.unavailable,
          confirmedMode: confirmedMode,
        );

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
    required this.firmware,
  });

  final DeviceIdentityStatus identity;
  final BatteryStatus battery;
  final ModeStatus mode;
  final SlotsStatus slots;
  final FirmwareStatus firmware;

  DeviceStatusSnapshot copyWith({
    BatteryStatus? battery,
    ModeStatus? mode,
    SlotsStatus? slots,
    FirmwareStatus? firmware,
  }) =>
      DeviceStatusSnapshot(
        identity: identity,
        battery: battery ?? this.battery,
        mode: mode ?? this.mode,
        slots: slots ?? this.slots,
        firmware: firmware ?? this.firmware,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceStatusSnapshot &&
      other.identity == identity &&
      other.battery == battery &&
      other.mode == mode &&
      other.slots == slots &&
      other.firmware == firmware;

  @override
  int get hashCode => Object.hash(identity, battery, mode, slots, firmware);
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

class SlotMutationConnectionChanged implements Exception {
  const SlotMutationConnectionChanged();

  @override
  String toString() => 'The connected-device session changed';
}

class SlotMutationScope {
  const SlotMutationScope._(this._session);

  final ConnectedDeviceSession _session;

  bool get isCurrent => _session.isCurrent;

  void ensureCurrent() {
    if (!isCurrent) {
      throw const SlotMutationConnectionChanged();
    }
  }

  Future<T> run<T>(
    Future<T> Function(ChameleonCommunicator communicator) operation,
  ) async {
    ensureCurrent();
    final result = await operation(_session.communicator);
    ensureCurrent();
    return result;
  }
}

@immutable
class _FirmwareFacts {
  const _FirmwareFacts({
    required this.installedVersion,
    required this.installedCommit,
    required this.protocol,
    required this.compatibility,
  });

  final String? installedVersion;
  final String? installedCommit;
  final FirmwareProtocol protocol;
  final FirmwareCompatibility compatibility;
}

class ConnectedDeviceStatus extends ChangeNotifier with WidgetsBindingObserver {
  ConnectedDeviceStatus({
    required ConnectedDeviceSession session,
    required RfOperationCoordinator rfOperations,
    FirmwareCatalog firmwareCatalog = const GitHubFirmwareCatalog(),
    Future<void> Function()? firmwareInstaller,
    this.batteryPollInterval = const Duration(seconds: 15),
  })  : _session = session,
        _rfOperations = rfOperations,
        _firmwareCatalog = firmwareCatalog,
        _firmwareInstaller =
            firmwareInstaller ?? (() => flashFirmware(session.appState)),
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
          firmware: session.connector.portName == 'Demo'
              ? const FirmwareStatus.demo()
              : const FirmwareStatus.checking(),
        ) {
    WidgetsBinding.instance.addObserver(this);
  }

  final ConnectedDeviceSession _session;
  final RfOperationCoordinator _rfOperations;
  final FirmwareCatalog _firmwareCatalog;
  final Future<void> Function() _firmwareInstaller;
  final Duration batteryPollInterval;

  DeviceStatusSnapshot _snapshot;
  DeviceStatusSnapshot get snapshot => _snapshot;

  Timer? _batteryTimer;
  Timer? _activeSlotTimer;
  Future<void>? _batteryRefresh;
  Future<void>? _modeRefresh;
  Future<void>? _slotsRefresh;
  Future<void>? _activeSlotRefresh;
  Future<void>? _firmwareRefresh;
  _FirmwareFacts? _firmwareFacts;
  bool _firmwareLookupAttempted = false;
  bool _firmwareWarningClaimed = false;
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
          _startHomeTimers();
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
    final firmwareRefresh = refreshFirmware();
    await Future.wait(
      [batteryRefresh, modeRefresh, slotsRefresh, firmwareRefresh],
    );
  }

  Future<void> _refreshHomeAfterResume() async {
    final batteryRefresh = refreshBattery();
    final modeRefresh = _snapshot.mode.availability == ModeAvailability.loading
        ? refreshMode()
        : Future<void>.value();
    final activeSlotRefresh = _scheduleActiveSlotRefresh();
    final firmwareRefresh = refreshFirmware();
    await Future.wait(
      [batteryRefresh, modeRefresh, activeSlotRefresh, firmwareRefresh],
    );
  }

  Future<void> refreshFirmware() {
    if (_snapshot.firmware.state == FirmwareState.demo ||
        _firmwareLookupAttempted) {
      return _firmwareRefresh ?? Future.value();
    }
    _firmwareLookupAttempted = true;
    return _startFirmwareRefresh(readFacts: true);
  }

  Future<void> retryFirmwareCheck() {
    if (_snapshot.firmware.state == FirmwareState.demo ||
        _snapshot.firmware.checkResult != FirmwareCheckResult.unavailable) {
      return _firmwareRefresh ?? Future.value();
    }
    return _startFirmwareRefresh(readFacts: _firmwareFacts == null);
  }

  Future<void> _startFirmwareRefresh({required bool readFacts}) {
    final currentRefresh = _firmwareRefresh;
    if (currentRefresh != null) {
      return currentRefresh;
    }

    final refresh = _refreshFirmware(readFacts: readFacts);
    _firmwareRefresh = refresh;
    return refresh.whenComplete(() {
      if (identical(_firmwareRefresh, refresh)) {
        _firmwareRefresh = null;
      }
    });
  }

  Future<void> _refreshFirmware({required bool readFacts}) async {
    if (!_canPublish || _snapshot.firmware.state == FirmwareState.demo) {
      return;
    }

    _publish(
      _snapshot.copyWith(
        firmware: _snapshot.firmware.copyWith(
          state: _snapshot.firmware.compatibility ==
                  FirmwareCompatibility.incompatible
              ? FirmwareState.updateRequired
              : FirmwareState.checking,
          checkResult: FirmwareCheckResult.checking,
          installationFailed: false,
        ),
      ),
    );

    if (readFacts || _firmwareFacts == null) {
      final facts = await _readFirmwareFacts();
      if (!_canPublish || facts == null) {
        return;
      }
      _firmwareFacts = facts;
      _publish(
        _snapshot.copyWith(
          firmware: FirmwareStatus(
            state: facts.compatibility == FirmwareCompatibility.incompatible
                ? FirmwareState.updateRequired
                : FirmwareState.checking,
            installedVersion: facts.installedVersion,
            installedCommit: facts.installedCommit,
            protocol: facts.protocol,
            compatibility: facts.compatibility,
            checkResult: FirmwareCheckResult.checking,
          ),
        ),
      );
    }

    final facts = _firmwareFacts!;
    try {
      final latest = await _firmwareCatalog.latestFirmware(
        device: _session.connector.device,
        installedCommit: facts.installedCommit,
      );
      if (!_canPublish) {
        return;
      }
      final comparisonAvailable = latest.updateAvailable != null;
      final state = facts.compatibility == FirmwareCompatibility.incompatible
          ? FirmwareState.updateRequired
          : latest.updateAvailable == true
              ? FirmwareState.updateAvailable
              : latest.updateAvailable == false
                  ? FirmwareState.upToDate
                  : FirmwareState.checkUnavailable;
      _publish(
        _snapshot.copyWith(
          firmware: FirmwareStatus(
            state: state,
            installedVersion: facts.installedVersion,
            installedCommit: facts.installedCommit,
            protocol: facts.protocol,
            compatibility: facts.compatibility,
            latestVersion: latest.latestVersion,
            latestCommit: latest.latestCommit,
            checkResult: comparisonAvailable
                ? FirmwareCheckResult.succeeded
                : FirmwareCheckResult.unavailable,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to check the latest connected-device firmware',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_canPublish) {
        return;
      }
      _publish(
        _snapshot.copyWith(
          firmware: FirmwareStatus(
            state: facts.compatibility == FirmwareCompatibility.incompatible
                ? FirmwareState.updateRequired
                : FirmwareState.checkUnavailable,
            installedVersion: facts.installedVersion,
            installedCommit: facts.installedCommit,
            protocol: facts.protocol,
            compatibility: facts.compatibility,
            checkResult: FirmwareCheckResult.unavailable,
          ),
        ),
      );
    }
  }

  Future<_FirmwareFacts?> _readFirmwareFacts() async {
    while (_canPublish) {
      final result = await _rfOperations.tryRunBackground<_FirmwareFacts?>(
        () async {
          FirmwareVersion? version;
          String? commit;
          List<int>? capabilities;

          if (!_canPublish) {
            return null;
          }
          try {
            version = await _session.communicator.getFirmwareVersion();
          } catch (error, stackTrace) {
            if (!_canPublish) {
              return null;
            }
            _logFirmwareFactFailure('version', error, stackTrace);
          }
          if (!_canPublish) {
            return null;
          }

          try {
            commit = await _session.communicator.getGitCommitHash();
            if (commit.isEmpty) {
              commit = null;
            }
          } catch (error, stackTrace) {
            if (!_canPublish) {
              return null;
            }
            _logFirmwareFactFailure('commit', error, stackTrace);
          }
          if (!_canPublish) {
            return null;
          }

          try {
            capabilities = await _session.communicator.getDeviceCapabilities();
          } catch (error, stackTrace) {
            if (!_canPublish) {
              return null;
            }
            _logFirmwareFactFailure('compatibility', error, stackTrace);
          }
          if (!_canPublish) {
            return null;
          }

          final legacy = version?.legacyProtocol == true;
          final requiredCapability = ChameleonCommand.setIdteckEmulatorID.value;
          final compatibility = legacy ||
                  (capabilities != null &&
                      !capabilities.contains(requiredCapability))
              ? FirmwareCompatibility.incompatible
              : capabilities == null || version == null
                  ? FirmwareCompatibility.unknown
                  : FirmwareCompatibility.compatible;

          return _FirmwareFacts(
            installedVersion:
                version == null ? null : numToVerCode(version.version),
            installedCommit: commit,
            protocol: version == null
                ? FirmwareProtocol.unknown
                : legacy
                    ? FirmwareProtocol.legacy
                    : FirmwareProtocol.current,
            compatibility: compatibility,
          );
        },
        group: _backgroundOperationGroup,
      );
      if (result.acquired) {
        return result.value;
      }
      await _rfOperations.waitUntilIdle();
    }
    return null;
  }

  void _logFirmwareFactFailure(
    String fact,
    Object error,
    StackTrace stackTrace,
  ) {
    _session.appState.log?.w(
      'Unable to read connected-device firmware $fact',
      error: error,
      stackTrace: stackTrace,
    );
  }

  bool claimFirmwareCompatibilityWarning() {
    if (_firmwareWarningClaimed ||
        _snapshot.firmware.compatibility !=
            FirmwareCompatibility.incompatible) {
      return false;
    }
    _firmwareWarningClaimed = true;
    return true;
  }

  Future<FirmwareInstallOutcome> installFirmware() async {
    if (!_canPublish) {
      return FirmwareInstallOutcome.connectionChanged;
    }
    final firmware = _snapshot.firmware;
    if (!firmware.canInstall) {
      return FirmwareInstallOutcome.notAvailable;
    }
    if (firmware.installing) {
      return FirmwareInstallOutcome.busy;
    }

    _publish(
      _snapshot.copyWith(
        firmware: firmware.copyWith(
          installing: true,
          installationFailed: false,
        ),
      ),
    );
    try {
      final installationStarted = await _rfOperations.runForeground(() async {
        if (!_canPublish) {
          return false;
        }
        await _firmwareInstaller();
        return true;
      });
      if (!installationStarted || !_canPublish) {
        return FirmwareInstallOutcome.connectionChanged;
      }
      _publish(
        _snapshot.copyWith(
          firmware: _snapshot.firmware.copyWith(installing: false),
        ),
      );
      return FirmwareInstallOutcome.started;
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to install connected-device firmware',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_canPublish) {
        return FirmwareInstallOutcome.connectionChanged;
      }
      _publish(
        _snapshot.copyWith(
          firmware: _snapshot.firmware.copyWith(
            installing: false,
            installationFailed: true,
          ),
        ),
      );
      return FirmwareInstallOutcome.failed;
    }
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
            final confirmed = result.value!
                ? ConnectedDeviceMode.reader
                : ConnectedDeviceMode.emulator;
            final pending = _snapshot.mode.pendingMode;
            _publish(
              _snapshot.copyWith(
                mode: pending == null
                    ? ModeStatus.available(confirmed)
                    : ModeStatus.pending(
                        confirmedMode: confirmed,
                        pendingMode: pending,
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
      if (readError == null && confirmed != null) {
        _publish(_snapshot.copyWith(mode: ModeStatus.available(confirmed)));
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
          _snapshot.mode.confirmedMode ?? previous.confirmedMode!;
      _publish(
        _snapshot.copyWith(mode: ModeStatus.available(latestConfirmed)),
      );
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

  Future<T> mutateSlots<T>(
    Future<T> Function(SlotMutationScope mutation) operation, {
    bool reconcileMode = false,
  }) {
    return _rfOperations.runForeground(() async {
      final mutation = SlotMutationScope._(_session);
      mutation.ensureCurrent();
      late T result;
      Object? mutationError;
      StackTrace? mutationStackTrace;
      try {
        result = await operation(mutation);
        mutation.ensureCurrent();
      } catch (error, stackTrace) {
        mutationError = error;
        mutationStackTrace = stackTrace;
      }

      if (_canPublish) {
        try {
          final slots = await _readSlots(_snapshot.slots);
          ModeStatus? mode;
          if (reconcileMode && _canPublish) {
            mode = await _readModeAfterSlotMutation();
          }
          if (_canPublish && slots != null) {
            _publish(
              _snapshot.copyWith(
                slots: _mergePendingSlotActivation(slots),
                mode: _mergePendingModeAction(mode),
              ),
            );
          }
        } catch (error, stackTrace) {
          _session.appState.log?.w(
            'Unable to reconcile connected-device slots after mutation',
            error: error,
            stackTrace: stackTrace,
          );
          if (_canPublish) {
            _publish(
              _snapshot.copyWith(slots: _failedSlots(_snapshot.slots)),
            );
          }
        }
      }

      if (mutationError != null) {
        Error.throwWithStackTrace(mutationError, mutationStackTrace!);
      }
      mutation.ensureCurrent();
      return result;
    });
  }

  SlotsStatus _mergePendingSlotActivation(SlotsStatus reconciled) {
    return reconciled.copyWith(
      pendingActivation: _snapshot.slots.pendingActivation,
    );
  }

  ModeStatus? _mergePendingModeAction(ModeStatus? reconciled) {
    if (reconciled == null) {
      return null;
    }
    final current = _snapshot.mode;
    return current.pendingMode == null
        ? reconciled
        : ModeStatus._(
            availability: reconciled.availability,
            confirmedMode: reconciled.confirmedMode,
            pendingMode: current.pendingMode,
          );
  }

  Future<ModeStatus?> _readModeAfterSlotMutation() async {
    try {
      final isReader = await _session.communicator.isReaderDeviceMode();
      if (!_canPublish) {
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
      if (!_canPublish) {
        return null;
      }
      return ModeStatus.unavailable(
        confirmedMode: _snapshot.mode.confirmedMode,
      );
    }
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
            _publish(
              _snapshot.copyWith(
                slots: status.copyWith(
                  pendingActivation: _snapshot.slots.pendingActivation,
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
    if (slot < 0 ||
        slot >= 8 ||
        !_canPublish ||
        _snapshot.slots.pendingActivation != null) {
      return false;
    }
    _publish(
      _snapshot.copyWith(
        slots: _snapshot.slots.copyWith(pendingActivation: slot),
      ),
    );
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
              pendingActivation: null,
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
              pendingActivation: null,
            ),
          ),
        );
      } else if (_canPublish) {
        _publish(
          _snapshot.copyWith(
            slots: _snapshot.slots.copyWith(pendingActivation: null),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _scheduleActiveSlotRefresh() {
    if (_slotsRefresh != null || _snapshot.slots.pendingActivation != null) {
      return Future.value();
    }
    final currentRefresh = _activeSlotRefresh;
    if (currentRefresh != null) {
      return currentRefresh;
    }
    final refresh = _refreshActiveSlot();
    _activeSlotRefresh = refresh;
    return refresh.whenComplete(() {
      if (identical(_activeSlotRefresh, refresh)) {
        _activeSlotRefresh = null;
      }
    });
  }

  Future<void> _refreshActiveSlot() async {
    try {
      final result = await _rfOperations.tryRunBackground<int>(
        _session.communicator.getActiveSlot,
        group: _backgroundOperationGroup,
      );
      if (!result.acquired || !_canPublish) {
        return;
      }
      final confirmedSlot = result.value!;
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
    } catch (error, stackTrace) {
      _session.appState.log?.w(
        'Unable to poll connected-device active slot',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_canPublish) {
        return;
      }
      final currentSlots = _snapshot.slots;
      final staleFacets = {...currentSlots.staleFacets};
      final unavailableFacets = {...currentSlots.unavailableFacets};
      if (currentSlots.activeSlot.isConfirmed) {
        staleFacets.add(SlotFacet.activeSlot);
        unavailableFacets.remove(SlotFacet.activeSlot);
      } else {
        unavailableFacets.add(SlotFacet.activeSlot);
      }
      _publish(
        _snapshot.copyWith(
          slots: currentSlots.copyWith(
            availability: _slotsAvailability(staleFacets, unavailableFacets),
            staleFacets: staleFacets,
            unavailableFacets: unavailableFacets,
          ),
        ),
      );
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
          enabled: _slotEnabledState(
            previous: old.hf.enabled,
            enabled: enabledInfo?.hf,
            slotIndex: index,
            frequency: TagFrequency.hf,
          ),
          name: slotNames == null
              ? _preservedOrUnavailable(old.hf.name)
              : SlotField.confirmed(slotNames.hf),
        ),
        lf: SlotFrequencyStatus(
          type: type == null
              ? _preservedOrUnavailable(old.lf.type)
              : SlotField.confirmed(type.lf),
          enabled: _slotEnabledState(
            previous: old.lf.enabled,
            enabled: enabledInfo?.lf,
            slotIndex: index,
            frequency: TagFrequency.lf,
          ),
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

  SlotField<bool> _slotEnabledState({
    required SlotField<bool> previous,
    required bool? enabled,
    required int slotIndex,
    required TagFrequency frequency,
  }) {
    if (enabled == null) {
      return _preservedOrUnavailable(previous);
    }
    if (!_session.connector.slotEnabledStateCertainty.isConfirmed(
      slotIndex,
      highFrequency: frequency == TagFrequency.hf,
    )) {
      return const SlotField<bool>.unavailable();
    }
    return SlotField.confirmed(enabled);
  }

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

  void _startHomeTimers() {
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(
      batteryPollInterval,
      (_) => unawaited(refreshBattery()),
    );
    _activeSlotTimer?.cancel();
    _activeSlotTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_scheduleActiveSlotRefresh()),
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
      _activeSlotTimer?.cancel();
      _activeSlotTimer = null;
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
      _startHomeTimers();
    } else {
      _batteryTimer?.cancel();
      _batteryTimer = null;
      _activeSlotTimer?.cancel();
      _activeSlotTimer = null;
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
    _activeSlotTimer?.cancel();
    _activeSlotTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
