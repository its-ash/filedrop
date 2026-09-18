import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:theme/theme.dart';

import '../models/transfer.dart';
import '../providers/filedrop_providers.dart';

/// ASCII mockup reference (spec):
/// ```
/// +----------------------------------+
/// |  Transfer History                 |
/// |------------------------------------|
/// |  ^ photo.jpg      Ashvini's MacBook|
/// |    2.1 MB · Completed · 2m ago    |
/// |  v report.pdf     Pixel 8         |
/// |    850 KB · Completed · 1h ago    |
/// +----------------------------------+
/// ```
class TransferHistoryScreen extends ConsumerWidget {
  const TransferHistoryScreen({super.key});

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatAgo(int unixSeconds) {
    final then = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final diff = DateTime.now().difference(then);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(transferHistoryProvider);

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('Transfer History'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(transferHistoryProvider),
            ),
          ],
        ),
        historyAsync.when(
          loading: () => const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (err, _) => SliverFillRemaining(
            child: Center(child: Text('Failed to load history: $err')),
          ),
          data: (records) {
            if (records.isEmpty) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: ThemeEmptyState(
                  icon: Icons.history,
                  title: 'No transfers yet',
                  subtitle: 'Completed sends and receives will appear here.',
                ),
              );
            }
            return SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              sliver: SliverList.separated(
                itemCount: records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _HistoryTile(
                  record: records[i],
                  formatBytes: _formatBytes,
                  formatAgo: _formatAgo,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.record, required this.formatBytes, required this.formatAgo});

  final TransferRecord record;
  final String Function(int) formatBytes;
  final String Function(int) formatAgo;

  @override
  Widget build(BuildContext context) {
    final isFailed = record.status == 'Failed';
    return ThemeCard(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(record.outgoing ? Icons.arrow_upward : Icons.arrow_downward,
            color: isFailed ? Theme.of(context).colorScheme.error : null),
        title: Text(record.fileName, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${formatBytes(record.fileSizeBytes)} · ${record.peerName} · '
          '${record.status} · ${formatAgo(record.completedAt)}',
        ),
      ),
    );
  }
}
