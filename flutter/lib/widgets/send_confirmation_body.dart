import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:theme/theme.dart';

import '../models/device.dart';
import '../providers/filedrop_providers.dart';

/// Body-only (no `Scaffold`/`AppBar`) send-confirmation UI, extracted from
/// the old `send_confirmation_screen.dart` for reuse as the last step of
/// the Home tab's Send flow. On confirm, dispatches `sendFiles` via
/// [FileDropFfiService] and calls [onSent] — the Home screen then flips to
/// the active-transfer view once `TransferStarted` events populate
/// [activeTransfersProvider].
class SendConfirmationBody extends ConsumerStatefulWidget {
  const SendConfirmationBody({
    super.key,
    required this.device,
    required this.filePaths,
    required this.onSent,
  });

  final Device device;
  final List<String> filePaths;
  final VoidCallback onSent;

  @override
  ConsumerState<SendConfirmationBody> createState() => _SendConfirmationBodyState();
}

class _SendConfirmationBodyState extends ConsumerState<SendConfirmationBody> {
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final service = ref.read(fileDropServiceProvider);
      await service.sendFiles(
        peerAddress: widget.device.address,
        peerPort: widget.device.port,
        peerDeviceId: widget.device.deviceId,
        filePaths: widget.filePaths,
      );
      if (mounted) widget.onSent();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Confirm Send', style: AppTypography.headlineSmall),
          const SizedBox(height: 16),
          Text(
            'Sending ${widget.filePaths.length} file'
            '${widget.filePaths.length == 1 ? '' : 's'} to:',
            style: AppTypography.titleMedium,
          ),
          const SizedBox(height: 16),
          ThemeCard(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.laptop_mac)),
              title: Text(widget.device.name),
              subtitle: Text('${widget.device.address}:${widget.device.port}'),
            ),
          ),
          const SizedBox(height: 16),
          if (widget.filePaths.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: widget.filePaths.length,
                itemBuilder: (context, i) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(widget.filePaths[i].split('/').last),
                ),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text(_sending ? 'Sending…' : 'Send Now'),
            ),
          ),
        ],
      ),
    );
  }
}
