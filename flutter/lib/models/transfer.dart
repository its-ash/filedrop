/// Mirrors `filedrop_core::transfer::{TransferStatus, TransferProgress}`.
enum TransferStatus {
  queued,
  connecting,
  inProgress,
  paused,
  completed,
  failed,
  cancelled;

  static TransferStatus fromWire(String value) {
    switch (value) {
      case 'Queued':
        return TransferStatus.queued;
      case 'Connecting':
        return TransferStatus.connecting;
      case 'InProgress':
        return TransferStatus.inProgress;
      case 'Paused':
        return TransferStatus.paused;
      case 'Completed':
        return TransferStatus.completed;
      case 'Failed':
        return TransferStatus.failed;
      case 'Cancelled':
        return TransferStatus.cancelled;
      default:
        return TransferStatus.failed;
    }
  }
}

class TransferProgress {
  final String transferId;
  final String fileName;
  final int bytesTransferred;
  final int totalBytes;
  final TransferStatus status;
  final double bytesPerSec;
  final String? error;

  const TransferProgress({
    required this.transferId,
    required this.fileName,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.status,
    required this.bytesPerSec,
    this.error,
  });

  double get percent => totalBytes == 0 ? 0 : (bytesTransferred / totalBytes) * 100;

  factory TransferProgress.fromJson(Map<String, dynamic> json) => TransferProgress(
        transferId: json['transfer_id'] as String,
        fileName: json['file_name'] as String,
        bytesTransferred: (json['bytes_transferred'] as num).toInt(),
        totalBytes: (json['total_bytes'] as num).toInt(),
        status: TransferStatus.fromWire(json['status'] as String),
        bytesPerSec: (json['bytes_per_sec'] as num).toDouble(),
        error: json['error'] as String?,
      );

  TransferProgress copyWith({
    int? bytesTransferred,
    TransferStatus? status,
    double? bytesPerSec,
    String? error,
  }) =>
      TransferProgress(
        transferId: transferId,
        fileName: fileName,
        bytesTransferred: bytesTransferred ?? this.bytesTransferred,
        totalBytes: totalBytes,
        status: status ?? this.status,
        bytesPerSec: bytesPerSec ?? this.bytesPerSec,
        error: error ?? this.error,
      );
}

/// Mirrors `filedrop_core::storage::TransferRecord`.
class TransferRecord {
  final String id;
  final String fileName;
  final int fileSizeBytes;
  final String peerDeviceId;
  final String peerName;
  final bool outgoing;
  final String status; // "Completed" | "Failed" | "Cancelled"
  final String? sha256;
  final int startedAt;
  final int completedAt;
  final String? savedPath;

  const TransferRecord({
    required this.id,
    required this.fileName,
    required this.fileSizeBytes,
    required this.peerDeviceId,
    required this.peerName,
    required this.outgoing,
    required this.status,
    this.sha256,
    required this.startedAt,
    required this.completedAt,
    this.savedPath,
  });

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
        id: json['id'] as String,
        fileName: json['file_name'] as String,
        fileSizeBytes: (json['file_size_bytes'] as num).toInt(),
        peerDeviceId: json['peer_device_id'] as String,
        peerName: json['peer_name'] as String,
        outgoing: json['outgoing'] as bool,
        status: json['status'] as String,
        sha256: json['sha256'] as String?,
        startedAt: (json['started_at'] as num).toInt(),
        completedAt: (json['completed_at'] as num).toInt(),
        savedPath: json['saved_path'] as String?,
      );
}
