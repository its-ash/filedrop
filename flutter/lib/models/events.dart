import 'device.dart';
import 'transfer.dart';

/// Mirrors `filedrop_ffi::events::FileDropEvent`. Each event JSON payload
/// looks like `{"type": "DeviceDiscovered", "data": {...}}` per the
/// serde `#[serde(tag = "type", content = "data")]` encoding on the Rust
/// side — see docs/FFI_INTERFACE.md.
sealed class FileDropEvent {
  const FileDropEvent();

  static FileDropEvent? fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final data = json['data'] as Map<String, dynamic>? ?? const {};
    switch (type) {
      case 'DeviceDiscovered':
        return DeviceDiscoveredEvent(Device.fromJson(data['device'] as Map<String, dynamic>));
      case 'DeviceConnected':
        return DeviceConnectedEvent(data['device_id'] as String);
      case 'PairingRequested':
        return PairingRequestedEvent(
          deviceId: data['device_id'] as String,
          deviceName: data['device_name'] as String,
          token: data['token'] as String,
        );
      case 'TransferStarted':
        return TransferStartedEvent(
          transferId: data['transfer_id'] as String,
          fileName: data['file_name'] as String,
          totalBytes: (data['total_bytes'] as num).toInt(),
        );
      case 'TransferProgress':
        return TransferProgressEvent(
          TransferProgress.fromJson(data['progress'] as Map<String, dynamic>),
        );
      case 'TransferPaused':
        return TransferPausedEvent(data['transfer_id'] as String);
      case 'TransferCompleted':
        return TransferCompletedEvent(
          transferId: data['transfer_id'] as String,
          sha256: data['sha256'] as String,
        );
      case 'TransferFailed':
        return TransferFailedEvent(
          transferId: data['transfer_id'] as String,
          error: data['error'] as String,
        );
      case 'DeviceDisconnected':
        return DeviceDisconnectedEvent(data['device_id'] as String);
      default:
        return null;
    }
  }
}

class DeviceDiscoveredEvent extends FileDropEvent {
  final Device device;
  const DeviceDiscoveredEvent(this.device);
}

class DeviceConnectedEvent extends FileDropEvent {
  final String deviceId;
  const DeviceConnectedEvent(this.deviceId);
}

class PairingRequestedEvent extends FileDropEvent {
  final String deviceId;
  final String deviceName;
  final String token;
  const PairingRequestedEvent({required this.deviceId, required this.deviceName, required this.token});
}

class TransferStartedEvent extends FileDropEvent {
  final String transferId;
  final String fileName;
  final int totalBytes;
  const TransferStartedEvent({required this.transferId, required this.fileName, required this.totalBytes});
}

class TransferProgressEvent extends FileDropEvent {
  final TransferProgress progress;
  const TransferProgressEvent(this.progress);
}

class TransferPausedEvent extends FileDropEvent {
  final String transferId;
  const TransferPausedEvent(this.transferId);
}

class TransferCompletedEvent extends FileDropEvent {
  final String transferId;
  final String sha256;
  const TransferCompletedEvent({required this.transferId, required this.sha256});
}

class TransferFailedEvent extends FileDropEvent {
  final String transferId;
  final String error;
  const TransferFailedEvent({required this.transferId, required this.error});
}

class DeviceDisconnectedEvent extends FileDropEvent {
  final String deviceId;
  const DeviceDisconnectedEvent(this.deviceId);
}
