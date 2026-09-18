import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../models/events.dart';
import '../models/transfer.dart';
import '../src/rust/api.dart' as frb;
import '../src/rust/frb_generated.dart';

/// Dart-side service layer wrapping the Rust `filedrop-ffi` crate.
///
/// Calls through to `src/rust/` — the bindings `flutter_rust_bridge_codegen
/// generate` produces from `rust/filedrop-ffi/src/api/mod.rs` (config:
/// `flutter_rust_bridge.yaml` at the repo root). [_RustBindings] adapts the
/// generated FRB types (`UuidValue`, `BigInt`, the freezed
/// `frb.FileDropEventDto` sealed class, etc.) to this file's existing
/// hand-rolled Dart models (`Device`, `TransferProgress`,
/// `FileDropEvent`) so every other call site in the app (Riverpod
/// providers, screens) is unaffected by the FFI implementation swap.
///
/// The service is a singleton (one Rust engine per app process) exposed
/// via Riverpod in `providers/filedrop_providers.dart`.
class FileDropFfiService {
  FileDropFfiService._();
  static final FileDropFfiService instance = FileDropFfiService._();

  final _bindings = _RustBindings();
  final StreamController<FileDropEvent> _eventsController =
      StreamController<FileDropEvent>.broadcast();
  StreamSubscription<frb.FileDropEventDto>? _eventsSubscription;

  /// Broadcast stream of every event Rust emits (device discovery,
  /// pairing requests, transfer lifecycle). Screens subscribe to this via
  /// the `fileDropEventsProvider` Riverpod stream provider rather than
  /// calling this directly.
  Stream<FileDropEvent> get events => _eventsController.stream;

  bool _initialized = false;

  /// Must be called once at app startup (see `main.dart`). Initializes
  /// flutter_rust_bridge itself, then the Rust engine, and begins
  /// forwarding the Rust event stream.
  Future<String> init({required String deviceName, required String appDataDir}) async {
    if (_initialized) {
      throw StateError('FileDropFfiService.init called more than once');
    }
    if (!RustLib.instance.initialized) {
      await RustLib.init();
    }
    final deviceId = await _bindings.initEngine(deviceName: deviceName, appDataDir: appDataDir);
    _initialized = true;
    _startEventForwarding();
    return deviceId;
  }

  /// Starts the HTTP/WebSocket transfer server on a free local port.
  ///
  /// Tracks whether the server is already running so callers (e.g. the
  /// receive flow) can avoid double-binding — the underlying Rust
  /// `start_server` binds a fresh listener every call with no idempotency
  /// of its own.
  Future<({String address, int port})> startServer() async {
    final result = await _bindings.startServer();
    _serverRunning = true;
    return result;
  }

  Future<void> stopServer() async {
    await _bindings.stopServer();
    _serverRunning = false;
  }

  bool _serverRunning = false;

  /// Whether [startServer] has been called and [stopServer] has not since.
  bool get isServerRunning => _serverRunning;

  /// Ensures the transfer server is running, starting it only if it isn't
  /// already (avoids double-binding a second listener on top of the one
  /// `main.dart` starts at app launch).
  Future<({String address, int port})?> ensureServerRunning() async {
    if (_serverRunning) return null;
    return startServer();
  }

  /// Real, non-heuristic check for a usable LAN interface right now (see
  /// `check_usable_lan` in `rust/filedrop-ffi/src/api/mod.rs`): enumerates
  /// non-loopback interfaces and returns the first private-range IPv4
  /// address found, or `null` if none exists.
  Future<String?> checkUsableLan() => frb.checkUsableLan();

  /// Starts mDNS + UDP broadcast discovery. Discovered devices arrive as
  /// [DeviceDiscoveredEvent]s on [events], not as a return value.
  Future<void> startDiscovery(Device selfDevice) => _bindings.startDiscovery(selfDevice);

  Future<void> stopDiscovery() => _bindings.stopDiscovery();

  Future<List<Device>> getNearbyDevices() => _bindings.getNearbyDevices();

  /// Generates a pairing token + QR payload for `peerDeviceId`/`peerName`.
  Future<Map<String, dynamic>> pairDevice({
    required String peerDeviceId,
    required String peerName,
  }) =>
      _bindings.pairDevice(peerDeviceId: peerDeviceId, peerName: peerName);

  /// Queues one or more local file paths for sending to a peer. Returns
  /// the transfer IDs immediately (queued); progress arrives via
  /// [TransferStartedEvent]/[TransferProgressEvent]/[TransferCompletedEvent]
  /// on [events].
  Future<List<String>> sendFiles({
    required String peerAddress,
    required int peerPort,
    required String peerDeviceId,
    required List<String> filePaths,
  }) =>
      _bindings.sendFiles(
        peerAddress: peerAddress,
        peerPort: peerPort,
        peerDeviceId: peerDeviceId,
        filePaths: filePaths,
      );

  Future<void> acceptTransfer(String transferId) => _bindings.acceptTransfer(transferId);
  Future<void> rejectTransfer(String transferId) => _bindings.rejectTransfer(transferId);
  Future<void> pauseTransfer(String transferId) => _bindings.pauseTransfer(transferId);
  Future<void> resumeTransfer(String transferId) => _bindings.resumeTransfer(transferId);
  Future<void> cancelTransfer(String transferId) => _bindings.cancelTransfer(transferId);

  Future<TransferProgress> getTransferStatus(String transferId) =>
      _bindings.getTransferStatus(transferId);

  Future<List<TransferRecord>> getTransferHistory() => _bindings.getTransferHistory();

  void _startEventForwarding() {
    // Push-based subscription backed by the FRB-generated
    // `subscribeEvents()` Stream (see `rust/filedrop-ffi/src/api/mod.rs`),
    // replacing the old 100ms polling timer stand-in.
    _eventsSubscription = _bindings.subscribeEvents().listen(
      (dto) {
        final event = _bindings.toFileDropEvent(dto);
        if (event != null) {
          _eventsController.add(event);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _eventsController.addError(error, stackTrace);
      },
    );
  }

  void dispose() {
    _eventsSubscription?.cancel();
    _eventsController.close();
  }
}

/// Adapts the flutter_rust_bridge-generated bindings (`src/rust/api.dart`)
/// to this app's hand-rolled Dart models. Every method here documents the
/// generated function it calls.
class _RustBindings {
  Future<String> initEngine({required String deviceName, required String appDataDir}) async {
    final id = await frb.initEngine(deviceName: deviceName, appDataDir: appDataDir);
    return id.toString();
  }

  Future<({String address, int port})> startServer() async {
    final endpoint = await frb.startServer();
    return (address: endpoint.address, port: endpoint.port);
  }

  Future<void> stopServer() => frb.stopServer();

  Future<void> startDiscovery(Device selfDevice) => frb.startDiscovery(
        selfDevice: frb.DiscoveredDeviceDto(
          deviceId: UuidValue.fromString(selfDevice.deviceId),
          name: selfDevice.name,
          address: selfDevice.address,
          port: selfDevice.port,
          platform: selfDevice.platform,
          paired: selfDevice.paired,
        ),
      );

  Future<void> stopDiscovery() => frb.stopDiscovery();

  Future<List<Device>> getNearbyDevices() async {
    final devices = await frb.getNearbyDevices();
    return devices.map(_deviceFromDto).toList();
  }

  Future<Map<String, dynamic>> pairDevice({
    required String peerDeviceId,
    required String peerName,
  }) async {
    final payload = await frb.pairDevice(
      peerDeviceId: UuidValue.fromString(peerDeviceId),
      peerName: peerName,
    );
    return {
      'version': payload.version,
      'device_id': payload.deviceId.toString(),
      'device_name': payload.deviceName,
      'address': payload.address,
      'port': payload.port,
      'token': payload.token,
      'expires_at': payload.expiresAt.toInt(),
    };
  }

  Future<List<String>> sendFiles({
    required String peerAddress,
    required int peerPort,
    required String peerDeviceId,
    required List<String> filePaths,
  }) async {
    final ids = await frb.sendFiles(
      peerAddress: peerAddress,
      peerPort: peerPort,
      peerDeviceId: UuidValue.fromString(peerDeviceId),
      filePaths: filePaths,
    );
    return ids.map((id) => id.toString()).toList();
  }

  Future<void> acceptTransfer(String transferId) =>
      frb.acceptTransfer(transferId: UuidValue.fromString(transferId));

  Future<void> rejectTransfer(String transferId) =>
      frb.rejectTransfer(transferId: UuidValue.fromString(transferId));

  Future<void> pauseTransfer(String transferId) =>
      frb.pauseTransfer(transferId: UuidValue.fromString(transferId));

  Future<void> resumeTransfer(String transferId) =>
      frb.resumeTransfer(transferId: UuidValue.fromString(transferId));

  Future<void> cancelTransfer(String transferId) =>
      frb.cancelTransfer(transferId: UuidValue.fromString(transferId));

  Future<TransferProgress> getTransferStatus(String transferId) async {
    final dto = await frb.getTransferStatus(transferId: UuidValue.fromString(transferId));
    return _progressFromDto(dto);
  }

  Future<List<TransferRecord>> getTransferHistory() async {
    final records = await frb.getTransferHistory();
    return records.map(_recordFromDto).toList();
  }

  /// The generated push-based event stream (see `subscribe_events` in
  /// `rust/filedrop-ffi/src/api/mod.rs`), replacing the hand-written ABI's
  /// `filedrop_poll_event` polling loop.
  Stream<frb.FileDropEventDto> subscribeEvents() => frb.subscribeEvents();

  /// Converts a generated `frb.FileDropEventDto` (freezed sealed class) to
  /// this app's existing `FileDropEvent` sealed class. Returns `null` only
  /// if a future FRB codegen pass adds a variant not yet mirrored here.
  FileDropEvent? toFileDropEvent(frb.FileDropEventDto dto) {
    return switch (dto) {
      frb.FileDropEventDto_DeviceDiscovered(:final device) =>
        DeviceDiscoveredEvent(_deviceFromDto(device)),
      frb.FileDropEventDto_DeviceConnected(:final deviceId) =>
        DeviceConnectedEvent(deviceId.toString()),
      frb.FileDropEventDto_PairingRequested(:final deviceId, :final deviceName, :final token) =>
        PairingRequestedEvent(deviceId: deviceId.toString(), deviceName: deviceName, token: token),
      frb.FileDropEventDto_TransferStarted(:final transferId, :final fileName, :final totalBytes) =>
        TransferStartedEvent(
          transferId: transferId.toString(),
          fileName: fileName,
          totalBytes: totalBytes.toInt(),
        ),
      frb.FileDropEventDto_TransferProgress(:final progress) =>
        TransferProgressEvent(_progressFromDto(progress)),
      frb.FileDropEventDto_TransferPaused(:final transferId) =>
        TransferPausedEvent(transferId.toString()),
      frb.FileDropEventDto_TransferCompleted(:final transferId, :final sha256) =>
        TransferCompletedEvent(transferId: transferId.toString(), sha256: sha256),
      frb.FileDropEventDto_TransferFailed(:final transferId, :final error) =>
        TransferFailedEvent(transferId: transferId.toString(), error: error),
      frb.FileDropEventDto_DeviceDisconnected(:final deviceId) =>
        DeviceDisconnectedEvent(deviceId.toString()),
    };
  }

  Device _deviceFromDto(frb.DiscoveredDeviceDto dto) => Device(
        deviceId: dto.deviceId.toString(),
        name: dto.name,
        address: dto.address,
        port: dto.port,
        platform: dto.platform,
        paired: dto.paired,
      );

  TransferProgress _progressFromDto(frb.TransferProgressDto dto) => TransferProgress(
        transferId: dto.transferId.toString(),
        fileName: dto.fileName,
        bytesTransferred: dto.bytesTransferred.toInt(),
        totalBytes: dto.totalBytes.toInt(),
        status: _statusFromDto(dto.status),
        bytesPerSec: dto.bytesPerSec,
        error: dto.error,
      );

  TransferStatus _statusFromDto(frb.TransferStatusDto status) => switch (status) {
        frb.TransferStatusDto.queued => TransferStatus.queued,
        frb.TransferStatusDto.connecting => TransferStatus.connecting,
        frb.TransferStatusDto.inProgress => TransferStatus.inProgress,
        frb.TransferStatusDto.paused => TransferStatus.paused,
        frb.TransferStatusDto.completed => TransferStatus.completed,
        frb.TransferStatusDto.failed => TransferStatus.failed,
        frb.TransferStatusDto.cancelled => TransferStatus.cancelled,
      };

  TransferRecord _recordFromDto(frb.TransferRecordDto dto) => TransferRecord(
        id: dto.id.toString(),
        fileName: dto.fileName,
        fileSizeBytes: dto.fileSizeBytes.toInt(),
        peerDeviceId: dto.peerDeviceId.toString(),
        peerName: dto.peerName,
        outgoing: dto.outgoing,
        status: switch (dto.status) {
          frb.TransferRecordStatusDto.completed => 'Completed',
          frb.TransferRecordStatusDto.failed => 'Failed',
          frb.TransferRecordStatusDto.cancelled => 'Cancelled',
        },
        sha256: dto.sha256,
        startedAt: dto.startedAt.toInt(),
        completedAt: dto.completedAt.toInt(),
        savedPath: dto.savedPath,
      );
}

/// Thrown when a Rust-side call returns an `Err` (flutter_rust_bridge
/// surfaces this as a `PanicException`/`FrbException`); wrapped here so
/// existing call sites catching `FileDropFfiException` keep working
/// verbatim across the FFI implementation swap.
class FileDropFfiException implements Exception {
  final String message;
  const FileDropFfiException(this.message);
  @override
  String toString() => 'FileDropFfiException: $message';
}
