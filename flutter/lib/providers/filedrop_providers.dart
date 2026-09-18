import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../models/events.dart';
import '../models/transfer.dart';
import '../services/filedrop_ffi_service.dart';

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

  /// Receive mode: nearby devices are shown while the user waits for an
  /// incoming pairing/transfer request (surfaced separately via the
  /// [pairingRequestsProvider]-driven overlay, not by navigating away).
  receiveMode,
}

/// Drives the Home tab's flow stage plus the file/device selections made
/// along the way, so the state survives tab switches and can be read from
/// wherever `home_screen.dart` needs it.
class HomeFlowNotifier extends Notifier<HomeFlowState> {
  @override
  HomeFlowState build() => const HomeFlowState();

  void startSend() => state = state.copyWith(stage: HomeFlowStage.filePicker, clearFiles: true);

  void startReceive() => state = state.copyWith(stage: HomeFlowStage.receiveMode);

  void filesPicked(List<String> filePaths) {
    state = state.copyWith(stage: HomeFlowStage.deviceSelectSend, filePaths: filePaths);
  }

  void deviceSelected(Device device) {
    state = state.copyWith(stage: HomeFlowStage.confirmSend, device: device);
  }

  /// Returns to idle (Send/Receive choice). Used both after a successful
  /// dispatch (the active-transfer view then takes over) and when the
  /// user backs out of the flow mid-way.
  void reset() => state = const HomeFlowState();

  /// Step back one stage, discarding whatever was selected at the stage
  /// being left. Used for in-flow back-button handling.
  void back() {
    switch (state.stage) {
      case HomeFlowStage.idle:
      case HomeFlowStage.receiveMode:
        state = const HomeFlowState();
      case HomeFlowStage.filePicker:
        state = const HomeFlowState();
      case HomeFlowStage.deviceSelectSend:
        state = state.copyWith(stage: HomeFlowStage.filePicker, clearDevice: true);
      case HomeFlowStage.confirmSend:
        state = state.copyWith(stage: HomeFlowStage.deviceSelectSend, clearDevice: true);
    }
  }
}

final homeFlowProvider = NotifierProvider<HomeFlowNotifier, HomeFlowState>(HomeFlowNotifier.new);

class HomeFlowState {
  final HomeFlowStage stage;
  final List<String> filePaths;
  final Device? device;

  const HomeFlowState({
    this.stage = HomeFlowStage.idle,
    this.filePaths = const [],
    this.device,
  });

  HomeFlowState copyWith({
    HomeFlowStage? stage,
    List<String>? filePaths,
    Device? device,
    bool clearFiles = false,
    bool clearDevice = false,
  }) =>
      HomeFlowState(
        stage: stage ?? this.stage,
        filePaths: clearFiles ? const [] : (filePaths ?? this.filePaths),
        device: clearDevice ? null : (device ?? this.device),
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
