import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/device.dart';
import '../models/events.dart';
import '../models/transfer.dart';
import '../services/filedrop_ffi_service.dart';
import '../services/wifi_direct_service.dart';

/// Which step of the Home flow is currently shown.
///
/// Nothing network-related (discovery, server, Wi-Fi Direct) runs in
/// [idle] or [filePicker]; it starts only once the user has picked Send
/// (after choosing files) or Receive, and stops when they leave.
/// The active-transfer view always wins over the stage.
enum HomeFlowStage {
  /// Two big choices: Send or Receive.
  idle,

  /// Picking local files to send.
  filePicker,

  /// Files picked: the transport is detected automatically ([SendLink]),
  /// then nearby devices are listed.
  deviceSelectSend,

  /// Reviewing the picked files + destination device before sending.
  confirmSend,

  /// Receive mode, see [ReceiveStage].
  receiveMode,
}

/// How files travel: over the shared Wi-Fi network, or phone to phone.
enum TransferTransport { wifi, direct }

/// Sub-state of the send link set-up (stage [HomeFlowStage.deviceSelectSend]).
enum SendLinkStage {
  /// Detecting Wi-Fi / connecting.
  checking,

  /// Wi-Fi radio is off and no network is available: ask the user to turn it on.
  needWifi,

  /// Link is up and device discovery is running.
  ready,

  /// Direct connection failed.
  error,
}

/// Sub-state of [HomeFlowStage.receiveMode].
enum ReceiveStage {
  /// Detecting Wi-Fi.
  checkingLan,

  /// Wi-Fi radio is off: ask the user to turn it on (system panel).
  needWifi,

  /// Creating the Wi-Fi Direct group (no Wi-Fi network).
  creatingGroup,

  /// Wi-Fi Direct group creation failed.
  wifiDirectError,

  /// Server is up and advertised; waiting for a sender.
  waiting,
}

/// Immutable snapshot of the receive sub-flow, held on [HomeFlowState].
class ReceiveState {
  final ReceiveStage stage;

  /// The IP other devices should connect to, once known.
  final String? address;

  final String? errorMessage;

  /// Transport in use (set once known).
  final TransferTransport? transport;

  const ReceiveState({
    this.stage = ReceiveStage.checkingLan,
    this.address,
    this.errorMessage,
    this.transport,
  });

  ReceiveState copyWith({
    ReceiveStage? stage,
    String? address,
    String? errorMessage,
    TransferTransport? transport,
    bool clearError = false,
  }) =>
      ReceiveState(
        stage: stage ?? this.stage,
        address: address ?? this.address,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        transport: transport ?? this.transport,
      );
}

/// Send link snapshot: which transport was picked and how set-up is going.
class SendLink {
  final SendLinkStage stage;
  final TransferTransport? transport;
  final String? errorMessage;

  const SendLink({
    this.stage = SendLinkStage.checking,
    this.transport,
    this.errorMessage,
  });

  SendLink copyWith({
    SendLinkStage? stage,
    TransferTransport? transport,
    String? errorMessage,
    bool clearError = false,
  }) =>
      SendLink(
        stage: stage ?? this.stage,
        transport: transport ?? this.transport,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

/// Drives the Home flow plus the selections made along the way.
class HomeFlowNotifier extends Notifier<HomeFlowState> {
  /// Whether this session joined/created a Wi-Fi Direct group that must be
  /// removed when the flow is left.
  bool _directActive = false;

  /// Bumped on every teardown so late async results from a previous
  /// attempt are ignored.
  int _generation = 0;

  @override
  HomeFlowState build() => const HomeFlowState();

  FileDropFfiService get _service => ref.read(fileDropServiceProvider);

  void startSend() {
    _teardown();
    state = const HomeFlowState(stage: HomeFlowStage.filePicker);
  }

  /// Receive: if on Wi-Fi, start the server on the LAN; otherwise use
  /// Wi-Fi Direct (asking the user to turn the Wi-Fi radio on if needed).
  Future<void> startReceive() async {
    _teardown();
    state = const HomeFlowState(stage: HomeFlowStage.receiveMode);
    await _prepareReceive(_generation);
  }

  bool _receiving(int gen) =>
      gen == _generation && state.stage == HomeFlowStage.receiveMode;

  void _setReceive(ReceiveState Function(ReceiveState) f) =>
      state = state.copyWith(receive: f(state.receive));

  Future<void> _prepareReceive(int gen) async {
    _setReceive((r) => const ReceiveState());
    String? ip;
    try {
      ip = await _service.checkUsableLan();
    } catch (_) {
      ip = null;
    }
    if (!_receiving(gen)) return;

    if (ip != null) {
      await _startServerAndWait(gen, ip, TransferTransport.wifi);
      return;
    }

    if (!await WifiDirectService.instance.isWifiEnabled()) {
      if (!_receiving(gen)) return;
      _setReceive((r) => r.copyWith(stage: ReceiveStage.needWifi));
      return;
    }
    await _createDirectGroup(gen);
  }

  Future<void> _startServerAndWait(
    int gen,
    String address,
    TransferTransport transport,
  ) async {
    try {
      await _service.ensureServerRunning();
      if (!_receiving(gen)) return;
      // Advertise this device so a sender's discovery can find it.
      await _service.startDiscovery(_service.selfDevice);
    } catch (_) {
      // Engine problem: still show the address we have.
    }
    if (!_receiving(gen)) return;
    _setReceive(
      (r) => r.copyWith(
        stage: ReceiveStage.waiting,
        address: address,
        transport: transport,
      ),
    );
  }

  Future<void> _createDirectGroup(int gen) async {
    _setReceive((r) => r.copyWith(stage: ReceiveStage.creatingGroup, clearError: true));
    try {
      if (!await _requestWifiDirectPermission()) {
        if (!_receiving(gen)) return;
        _setReceive(
          (r) => r.copyWith(
            stage: ReceiveStage.wifiDirectError,
            errorMessage: 'Permission was not granted, so a Wi-Fi Direct '
                'connection cannot be started.',
          ),
        );
        return;
      }
      final address = await WifiDirectService.instance.createGroup();
      _directActive = true;
      if (!_receiving(gen)) {
        _teardown();
        return;
      }
      await _startServerAndWait(gen, address, TransferTransport.direct);
    } on WifiDirectException catch (e) {
      if (!_receiving(gen)) return;
      _setReceive(
        (r) => r.copyWith(stage: ReceiveStage.wifiDirectError, errorMessage: e.message),
      );
    } catch (e) {
      if (!_receiving(gen)) return;
      _setReceive(
        (r) => r.copyWith(
          stage: ReceiveStage.wifiDirectError,
          errorMessage: 'Could not start a Wi-Fi Direct connection: $e',
        ),
      );
    }
  }

  /// Opens the system Wi-Fi panel (Android 10+ cannot toggle Wi-Fi).
  Future<void> openWifiPanel() => WifiDirectService.instance.openWifiPanel();

  /// Re-runs transport detection for whichever flow is active.
  Future<void> retry() {
    if (state.stage == HomeFlowStage.receiveMode) {
      _generation++;
      return _prepareReceive(_generation);
    }
    if (state.stage == HomeFlowStage.deviceSelectSend) {
      _generation++;
      return _prepareSend(_generation);
    }
    return Future.value();
  }

  /// Android 13+ needs `NEARBY_WIFI_DEVICES`; older versions need location.
  Future<bool> _requestWifiDirectPermission() async {
    final nearbyStatus = await Permission.nearbyWifiDevices.request();
    if (nearbyStatus.isGranted) return true;
    final locationStatus = await Permission.locationWhenInUse.request();
    return locationStatus.isGranted;
  }

  /// Files are picked: only now does the send side detect the transport
  /// and start looking for devices.
  void filesPicked(List<String> filePaths) {
    _teardown();
    ref.read(nearbyDevicesProvider.notifier).clear();
    state = HomeFlowState(
      stage: HomeFlowStage.deviceSelectSend,
      filePaths: filePaths,
    );
    unawaited(_prepareSend(_generation));
  }

  bool _sending(int gen) =>
      gen == _generation && state.stage == HomeFlowStage.deviceSelectSend;

  void _setSend(SendLink Function(SendLink) f) =>
      state = state.copyWith(send: f(state.send));

  Future<void> _prepareSend(int gen) async {
    _setSend((_) => const SendLink());
    String? ip;
    try {
      ip = await _service.checkUsableLan();
    } catch (_) {
      ip = null;
    }
    if (!_sending(gen)) return;

    if (ip != null) {
      _setSend((s) => s.copyWith(transport: TransferTransport.wifi));
      await _startSendDiscovery(gen);
      return;
    }

    _setSend((s) => s.copyWith(transport: TransferTransport.direct));
    if (!await WifiDirectService.instance.isWifiEnabled()) {
      if (!_sending(gen)) return;
      _setSend((s) => s.copyWith(stage: SendLinkStage.needWifi));
      return;
    }
    try {
      if (!await _requestWifiDirectPermission()) {
        if (!_sending(gen)) return;
        _setSend(
          (s) => s.copyWith(
            stage: SendLinkStage.error,
            errorMessage: 'Permission was not granted, so a Wi-Fi Direct '
                'connection cannot be started.',
          ),
        );
        return;
      }
      await WifiDirectService.instance.joinNearbyGroup();
      _directActive = true;
      if (!_sending(gen)) {
        _teardown();
        return;
      }
      await _startSendDiscovery(gen);
    } on WifiDirectException catch (e) {
      if (!_sending(gen)) return;
      _setSend((s) => s.copyWith(stage: SendLinkStage.error, errorMessage: e.message));
    } catch (e) {
      if (!_sending(gen)) return;
      _setSend(
        (s) => s.copyWith(
          stage: SendLinkStage.error,
          errorMessage: 'Could not start a Wi-Fi Direct connection: $e',
        ),
      );
    }
  }

  Future<void> _startSendDiscovery(int gen) async {
    try {
      await _service.startDiscovery(_service.selfDevice);
    } catch (e) {
      if (!_sending(gen)) return;
      _setSend((s) => s.copyWith(stage: SendLinkStage.error, errorMessage: '$e'));
      return;
    }
    if (!_sending(gen)) return;
    _setSend((s) => s.copyWith(stage: SendLinkStage.ready, clearError: true));
  }

  void deviceSelected(Device device) {
    unawaited(_service.stopDiscovery().catchError((_) {}));
    state = state.copyWith(stage: HomeFlowStage.confirmSend, device: device);
  }

  /// Back to the Send/Receive choice. With [keepLink] (after a send was
  /// dispatched) the connection is left up so the transfer can finish;
  /// it is torn down by the next flow or when the user backs out.
  void reset({bool keepLink = false}) {
    if (keepLink) {
      unawaited(_service.stopDiscovery().catchError((_) {}));
    } else {
      _teardown();
    }
    state = const HomeFlowState();
  }

  /// Step back one stage. Leaving a Send/Receive screen stops discovery,
  /// the server and any Wi-Fi Direct link.
  void back() {
    switch (state.stage) {
      case HomeFlowStage.idle:
      case HomeFlowStage.filePicker:
      case HomeFlowStage.receiveMode:
        reset();
      case HomeFlowStage.deviceSelectSend:
        _teardown();
        state = HomeFlowState(stage: HomeFlowStage.filePicker, filePaths: state.filePaths);
      case HomeFlowStage.confirmSend:
        // Discovery was stopped on selection; restart it for the list.
        state = state.copyWith(
          stage: HomeFlowStage.deviceSelectSend,
          clearDevice: true,
        );
        unawaited(_startSendDiscovery(_generation));
    }
  }

  /// Stops discovery, the receive server and any Wi-Fi Direct link, and
  /// invalidates in-flight async set-up.
  void _teardown() {
    _generation++;
    unawaited(_service.stopDiscovery().catchError((_) {}));
    if (_service.isServerRunning) {
      unawaited(_service.stopServer().catchError((_) {}));
    }
    if (_directActive) {
      _directActive = false;
      unawaited(WifiDirectService.instance.removeGroup().catchError((_) {}));
    }
  }
}

final homeFlowProvider = NotifierProvider<HomeFlowNotifier, HomeFlowState>(HomeFlowNotifier.new);

class HomeFlowState {
  final HomeFlowStage stage;
  final List<String> filePaths;
  final Device? device;
  final ReceiveState receive;
  final SendLink send;

  const HomeFlowState({
    this.stage = HomeFlowStage.idle,
    this.filePaths = const [],
    this.device,
    this.receive = const ReceiveState(),
    this.send = const SendLink(),
  });

  HomeFlowState copyWith({
    HomeFlowStage? stage,
    List<String>? filePaths,
    Device? device,
    ReceiveState? receive,
    SendLink? send,
    bool clearDevice = false,
  }) =>
      HomeFlowState(
        stage: stage ?? this.stage,
        filePaths: filePaths ?? this.filePaths,
        device: clearDevice ? null : (device ?? this.device),
        receive: receive ?? this.receive,
        send: send ?? this.send,
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

  /// Clears stale entries from a previous discovery session.
  void clear() => state = const {};
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

  /// Drops completed/failed entries so the home screen can return to the
  /// Send/Receive choice once nothing is in flight.
  void clearFinished() {
    state = {
      for (final e in state.entries)
        if (e.value.status == TransferStatus.inProgress ||
            e.value.status == TransferStatus.paused)
          e.key: e.value,
    };
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
