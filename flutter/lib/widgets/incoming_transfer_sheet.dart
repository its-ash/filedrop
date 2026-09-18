import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:theme/theme.dart';

import '../models/events.dart';
import '../providers/filedrop_providers.dart';

/// Content of the incoming-transfer overlay, extracted from the old
/// `incoming_transfer_screen.dart`. Shown via [ThemeBottomSheet.show] from
/// the app shell (`main.dart`) on top of whatever tab is active, rather
/// than pushed as a full-screen route — see `main.dart` for the
/// `ref.listen(pairingRequestsProvider, ...)` trigger.
class IncomingTransferSheet extends ConsumerWidget {
  const IncomingTransferSheet({super.key, required this.request});

  final PairingRequestedEvent request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(fileDropServiceProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_for_offline_outlined, size: 56),
            const SizedBox(height: 20),
            Text(
              '${request.deviceName} wants to send you files',
              textAlign: TextAlign.center,
              style: AppTypography.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Pairing token: ${request.token.substring(0, 8)}…',
              style: AppTypography.bodyMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      ref.read(pairingRequestsProvider.notifier).dismiss(request.deviceId);
                      await service.rejectTransfer(request.deviceId);
                      if (navigator.mounted) navigator.pop();
                    },
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      ref.read(pairingRequestsProvider.notifier).dismiss(request.deviceId);
                      await service.acceptTransfer(request.deviceId);
                      if (navigator.mounted) navigator.pop();
                    },
                    icon: const Icon(Icons.check),
                    label: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
