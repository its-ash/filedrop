import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/device.dart';
import '../models/events.dart';
import '../models/transfer.dart';
import '../services/filedrop_ffi_service.dart';
import '../services/wifi_direct_service.dart';

/// Which step of the Home tab's Send/Receive flow is currently shown.
///
/// This only governs the flow *when there is no active transfer* — the
/// active-transfer view (state 1 in the Home screen's priority order)
/// always wins regardless of [HomeFlowStage], per the Home tab state
/// machine spec.
enum HomeFlowStage {
  /// Send/Receive choice buttons.
  idle,

  /// Picking local files to send.
  filePicker,

  /// Picking which nearby device to send the already-picked files to.
  deviceSelectSend,

  /// Reviewing the picked files + destination device before dispatching
  /// `sendFiles`.
  confirmSend,

  /// Receive mode: see [ReceiveStage] for the sub-flow (LAN check,
  /// Create Network prompt, Wi-Fi Direct group creation, waiting to
  /// receive). Incoming pairing/transfer requests are surfaced separately
  /// via the [pairingRequestsProvider]-driven overlay, not by navigating
  /// away from this stage.
  receiveMode,
}

/// Sub-state of [HomeFlowStage.receiveMode], driving which view
/// `_ReceiveModeView` in `home_screen.dart` renders.
enum ReceiveStage {
  /// [check_usable_lan] is in flight.
  checkingLan,

  /// No usable LAN interface was found; show the "Create Network" prompt
  /// (a Wi-Fi Direct group is the way to get one).
  noLanFound,

  /// Permission request + [WifiDirectService.createGroup] is in flight.
  creatingGroup,

  /// [WifiDirectService.createGroup] failed; show the error with a Retry
  /// button back to [noLanFound].
  wifiDirectError,

  /// A usable IP (LAN or freshly-created Wi-Fi Direct group) is known and
  /// the transfer server is up — show the waiting-for-incoming-files view.
  waiting,
}

/// Immutable snapshot of the receive sub-flow, held on [HomeFlowState].
class ReceiveState {
  final ReceiveStage stage;

  /// The IP other devices should connect to, once known (LAN address or
  /// Wi-Fi Direct group owner address).
  final String? address;

  /// Error message from a failed [WifiDirectService.createGroup] call,
  /// set only while [stage] is [ReceiveStage.wifiDirectError].
  final String? errorMessage;

  /// Whether a Wi-Fi Direct group was created this session, so
  /// [HomeFlowNotifier.reset]/[HomeFlowNotifier.back] know whether calling
  /// `removeGroup()` is meaningful.
  final bool groupCreated;

  const ReceiveState({
    this.stage = ReceiveStage.checkingLan,
    this.address,
    this.errorMessage,
    this.groupCreated = false,
  });

  ReceiveState copyWith({
    ReceiveStage? stage,
    String? address,
    String? errorMessage,
    bool? groupCreated,
    bool clearError = false,
  }) =>
      ReceiveState(
        stage: stage ?? this.stage,
        address: address ?? this.address,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        groupCreated: groupCreated ?? this.groupCreated,
      );
}

/// Drives the Home tab's flow stage plus the file/device selections made
/// along the way, so the state survives tab switches and can be read from
/// wherever `home_screen.dart` needs it.
class HomeFlowNotifier extends Notifier<HomeFlowState> {
  @override
  HomeFlowState build() => const HomeFlowState();

  void startSend() => state = state.copyWith(stage: HomeFlowStage.filePicker, clearFiles: true);

  /// Enters receive mode and kicks off the LAN check. See
  /// `_ReceiveModeView` in `home_screen.dart` for the resulting UI per
  /// [ReceiveStage].
  Future<void> startReceive() async {
    state = state.copyWith(
      stage: HomeFlowStage.receiveMode,
      receive: const ReceiveState(),
    );
    await _checkLanAndMaybeWait();
  }

  Future<void> _checkLanAndMaybeWait() async {
    final service = ref.read(fileDropServiceProvider);
    String? ip;
    try {
      ip = await service.checkUsableLan();
    } catch (_) {
      ip = null;
    }

    if (state.stage != HomeFlowStage.receiveMode) return; // user navigated away meanwhile

    if (ip == null) {
      state = state.copyWith(receive: state.receive.copyWith(stage: ReceiveStage.noLanFound));
      return;
    }

    await _startServerAndEnterWaiting(ip);
  }

  Future<void> _startServerAndEnterWaiting(String address) async {
    final service = ref.read(fileDropServiceProvider);
    try {
      await service.ensureServerRunning();
    } catch (_) {
      // start_server failing is a genuine engine problem, not a
      // Wi-Fi-Direct-specific one; fall back to showing the address we do
      // have rather than hanging indefinitely on the checking state.
    }

    if (state.stage != HomeFlowStage.receiveMode) return;
    state = state.copyWith(
      receive: state.receive.copyWith(stage: ReceiveStage.waiting, address: address),
    );
  }

  /// "Create Network" button: requests the SDK-appropriate runtime
  /// permission, then creates a Wi-Fi Direct group.
  Future<void> createWifiDirectGroup() async {
    state = state.copyWith(
      receive: state.receive.copyWith(stage: ReceiveStage.creatingGroup, clearError: true),
    );

    try {
      final granted = await _requestWifiDirectPermission();
      if (!granted) {
        state = state.copyWith(
          receive: state.receive.copyWith(
            stage: ReceiveStage.wifiDirectError,
            errorMessage: 'Permission was not granted, so a Wi-Fi Direct network '
                'cannot be created.',
          ),
        );
        return;
      }

      final address = await WifiDirectService.instance.createGroup();
      if (state.stage != HomeFlowStage.receiveMode) return;

      state = state.copyWith(receive: state.receive.copyWith(groupCreated: true));
      await _startServerAndEnterWaiting(address);
    } on WifiDirectException catch (e) {
      if (state.stage != HomeFlowStage.receiveMode) return;
      state = state.copyWith(
        receive: state.receive.copyWith(stage: ReceiveStage.wifiDirectError, errorMessage: e.message),
      );
    } catch (e) {
      if (state.stage != HomeFlowStage.receiveMode) return;
      state = state.copyWith(
        receive: state.receive.copyWith(
          stage: ReceiveStage.wifiDirectError,
          errorMessage: 'Could not create a Wi-Fi Direct network: $e',
        ),
      );
    }
  }

  /// Retries from the error state back to the Create Network prompt.
  void retryWifiDirect() {
    state = state.copyWith(
      receive: state.receive.copyWith(stage: ReceiveStage.noLanFound, clearError: true),
    );
  }

  /// Android 13+ (API 33) requires `NEARBY_WIFI_DEVICES`; older versions
  /// require `ACCESS_FINE_LOCATION` for any Wi-Fi P2P API. `permission_handler`
  /// resolves the right underlying platform permission for the running
  /// device's SDK level via [Permission.nearbyWifiDevices]/[Permission.locationWhenInUse]
  /// respectively — request both in sequence and treat either being
  /// granted (the one actually applicable to this OS version) as success,
  /// since a denial of the inapplicable one on old/new OS is reported as
  /// `PermissionStatus.granted` by the plugin already (it only asks for
  /// what the platform actually needs).
  Future<bool> _requestWifiDirectPermission() async {
    final nearbyStatus = await Permission.nearbyWifiDevices.request();
    if (nearbyStatus.isGranted) return true;

    final locationStatus = await Permission.locationWhenInUse.request();
    return locationStatus.isGranted;
  }

  void filesPicked(List<String> filePaths) {
    state = state.copyWith(stage: HomeFlowStage.deviceSelectSend, filePaths: filePaths);
  }

  void deviceSelected(Device device) {
    state = state.copyWith(stage: HomeFlowStage.confirmSend, device: device);
  }

  /// Returns to idle (Send/Receive choice). Used both after a successful
  /// dispatch (the active-transfer view then takes over) and when the
  /// user backs out of the flow mid-way.
  void reset() {
    _maybeRemoveWifiDirectGroup();
    state = const HomeFlowState();
  }

  /// Step back one stage, discarding whatever was selected at the stage
  /// being left. Used for in-flow back-button handling.
  void back() {
    switch (state.stage) {
      case HomeFlowStage.idle:
        state = const HomeFlowState();
      case HomeFlowStage.receiveMode:
        _maybeRemoveWifiDirectGroup();
        state = const HomeFlowState();
      case HomeFlowStage.filePicker:
        state = const HomeFlowState();
      case HomeFlowStage.deviceSelectSend:
        state = state.copyWith(stage: HomeFlowStage.filePicker, clearDevice: true);
      case HomeFlowStage.confirmSend:
        state = state.copyWith(stage: HomeFlowStage.deviceSelectSend, clearDevice: true);
    }
  }

  /// Tears down any Wi-Fi Direct group created this session. Only called
  /// (fire-and-forget) when leaving receive mode, and only actually calls
  /// into the platform channel if a group was created — `removeGroup()`
  /// on the Kotlin side is harmless even with nothing to remove, but this
  /// avoids the call entirely in the common ExistingLan-only case.
  void _maybeRemoveWifiDirectGroup() {
    if (!state.receive.groupCreated) return;
    // Fire-and-forget: nothing in the UI blocks on teardown completing,
    // and WifiDirectService.removeGroup already treats "no group"/failure
    // as a benign outcome on the Kotlin side.
    unawaited(WifiDirectService.instance.removeGroup().catchError((_) {}));
  }
}

final homeFlowProvider = NotifierProvider<HomeFlowNotifier, HomeFlowState>(HomeFlowNotifier.new);

class HomeFlowState {
  final HomeFlowStage stage;
  final List<String> filePaths;
  final Device? device;
  final ReceiveState receive;

  const HomeFlowState({
    this.stage = HomeFlowStage.idle,
    this.filePaths = const [],
    this.device,
    this.receive = const ReceiveState(),
  });

  HomeFlowState copyWith({
    HomeFlowStage? stage,
    List<String>? filePaths,
    Device? device,
    ReceiveState? receive,
    bool clearFiles = false,
    bool clearDevice = false,
  }) =>
      HomeFlowState(
        stage: stage ?? this.stage,
        filePaths: clearFiles ? const [] : (filePaths ?? this.filePaths),
        device: clearDevice ? null : (device ?? this.device),
        receive: receive ?? this.receive,
      );
}

/// Singleton service provider.
final fileDropServiceProvider = Provider<FileDropFfiService>((ref) {
  final service = FileDropFfiService.instance;
  ref.onDispose(service.dispose);
  return service;
});

/// Raw event stream from Rust, fanned out to the more specific state
/// providers below via their own listeners.
final fileDropEventsProvider = StreamProvider<FileDropEvent>((ref) {
  return ref.watch(fileDropServiceProvider).events;
});

/// Nearby devices discovered via mDNS/UDP broadcast, keyed by device id
/// and updated as [DeviceDiscoveredEvent]s arrive.
class NearbyDevicesNotifier extends Notifier<Map<String, Device>> {
  @override
  Map<String, Device> build() {
    ref.listen(fileDropEventsProvider, (previous, next) {
      next.whenData((event) {
        if (event is DeviceDiscoveredEvent) {
          state = {...state, event.device.deviceId: event.device};
        } else if (event is DeviceDisconnectedEvent) {
          final updated = Map<String, Device>.from(state)..remove(event.deviceId);
          state = updated;
        }
      });
    });
    return const {};
  }
}

final nearbyDevicesProvider = NotifierProvider<NearbyDevicesNotifier, Map<String, Device>>(
  NearbyDevicesNotifier.new,
);

/// Active (in-flight) transfers keyed by transfer id, updated from
/// TransferStarted/Progress/Paused/Completed/Failed events.
class ActiveTransfersNotifier extends Notifier<Map<String, TransferProgress>> {
  @override
  Map<String, TransferProgress> build() {
    ref.listen(fileDropEventsProvider, (previous, next) {
      next.whenData(_handle);
    });
    return const {};
  }

  void _handle(FileDropEvent event) {
    switch (event) {
      case TransferStartedEvent e:
        state = {
          ...state,
          e.transferId: TransferProgress(
            transferId: e.transferId,
            fileName: e.fileName,
            bytesTransferred: 0,
            totalBytes: e.totalBytes,
            status: TransferStatus.inProgress,
            bytesPerSec: 0,
          ),
        };
      case TransferProgressEvent e:
        state = {...state, e.progress.transferId: e.progress};
      case TransferPausedEvent e:
        final existing = state[e.transferId];
        if (existing != null) {
          state = {...state, e.transferId: existing.copyWith(status: TransferStatus.paused)};
        }
      case TransferCompletedEvent e:
        final existing = state[e.transferId];
        if (existing != null) {
          state = {
            ...state,
            e.transferId: existing.copyWith(status: TransferStatus.completed),
          };
        }
      case TransferFailedEvent e:
        final existing = state[e.transferId];
        if (existing != null) {
          state = {
            ...state,
            e.transferId: existing.copyWith(status: TransferStatus.failed, error: e.error),
          };
        }
      default:
        break;
    }
  }
}

final activeTransfersProvider =
    NotifierProvider<ActiveTransfersNotifier, Map<String, TransferProgress>>(
  ActiveTransfersNotifier.new,
);

/// Pending pairing requests awaiting local user confirmation.
class PairingRequestsNotifier extends Notifier<List<PairingRequestedEvent>> {
  @override
  List<PairingRequestedEvent> build() {
    ref.listen(fileDropEventsProvider, (previous, next) {
      next.whenData((event) {
        if (event is PairingRequestedEvent) {
          state = [...state, event];
        }
      });
    });
    return const [];
  }

  void dismiss(String deviceId) {
    state = state.where((r) => r.deviceId != deviceId).toList();
  }
}

final pairingRequestsProvider =
    NotifierProvider<PairingRequestsNotifier, List<PairingRequestedEvent>>(
  PairingRequestsNotifier.new,
);

/// Transfer history, loaded on demand (Transfer History screen) rather
/// than streamed, since it is a point-in-time query
/// (`filedrop_get_transfer_history`) not an event feed.
final transferHistoryProvider = FutureProvider<List<TransferRecord>>((ref) {
  return ref.watch(fileDropServiceProvider).getTransferHistory();
});
