import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:theme/theme.dart';

import '../models/transfer.dart';
import '../providers/filedrop_providers.dart';
import '../services/filedrop_ffi_service.dart';

/// Body-only (no `Scaffold`/`AppBar`) list of every in-flight transfer,
/// extracted from the old `active_transfers_screen.dart` so it can be
/// embedded directly as the Home tab's state-1 view (active transfer(s)
/// in progress) as well as anywhere else that wants to show progress.
///
/// Renders every entry in [activeTransfersProvider] — the provider already
/// keys transfers by id in a `Map`, so multiple simultaneous sends/receives
/// are shown as separate cards, one per transfer, preserving parallel
/// transfer support.
class ActiveTransfersList extends ConsumerWidget {
  const ActiveTransfersList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(activeTransfersProvider).values.toList();
    final service = ref.watch(fileDropServiceProvider);

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: transfers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _TransferCard(progress: transfers[i], service: service),
    );
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({required this.progress, required this.service});

  final TransferProgress progress;
  final FileDropFfiService service;

  String _formatRate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatEta(TransferProgress p) {
    if (p.bytesPerSec <= 0) return '';
    final remaining = p.totalBytes - p.bytesTransferred;
    if (remaining <= 0) return '';
    final seconds = remaining / p.bytesPerSec;
    if (seconds < 60) return ' · ${seconds.toStringAsFixed(0)}s left';
    final minutes = seconds / 60;
    return ' · ${minutes.toStringAsFixed(0)}m left';
  }

  @override
  Widget build(BuildContext context) {
    final isPaused = progress.status == TransferStatus.paused;
    final isDone = progress.status == TransferStatus.completed;
    final isFailed = progress.status == TransferStatus.failed;

    return ThemeCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(progress.fileName, style: AppTypography.titleMedium, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress.totalBytes == 0 ? null : progress.percent / 100,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${progress.percent.toStringAsFixed(0)}% · '
                  '${_formatBytes(progress.bytesTransferred)} / ${_formatBytes(progress.totalBytes)}',
                  style: AppTypography.bodyMedium,
                ),
                Text(
                  isDone
                      ? 'Completed'
                      : isFailed
                          ? (progress.error ?? 'Failed')
                          : '${_formatRate(progress.bytesPerSec)}${_formatEta(progress)}',
                  style: AppTypography.bodyMedium,
                ),
              ],
            ),
            if (!isDone && !isFailed) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => isPaused
                        ? service.resumeTransfer(progress.transferId)
                        : service.pauseTransfer(progress.transferId),
                    icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
                    label: Text(isPaused ? 'Resume' : 'Pause'),
                  ),
                  TextButton.icon(
                    onPressed: () => service.cancelTransfer(progress.transferId),
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
