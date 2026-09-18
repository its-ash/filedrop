import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:theme/theme.dart';

import '../providers/filedrop_providers.dart';
import '../widgets/active_transfers_list.dart';
import '../widgets/file_picker_body.dart';
import '../widgets/nearby_devices_body.dart';
import '../widgets/send_confirmation_body.dart';

/// Home tab: a state machine on a single widget rather than a stack of
/// pushed routes, per the navigation-restructure spec. States, in
/// priority order:
///
///  1. Any active transfer in [activeTransfersProvider] (sending or
///     receiving, in progress) — shows the active-transfer view for ALL
///     of them (parallel transfers), regardless of [HomeFlowStage].
///  2. Otherwise, [HomeFlowStage] drives Send/Receive choice -> file
///     picker -> device select -> confirm, or receive mode.
///
/// ASCII mockup reference (spec, idle state):
/// ```
/// +----------------------------------+
/// |  FileDrop                    [*] |
/// |------------------------------------|
/// |   [ Send Files ]   [ Receive ]    |
/// |                                    |
/// |  Nearby Devices --------------->   |
/// |  o Ashvini's MacBook   (LAN)       |
/// |  o Pixel 8             (LAN)       |
/// |                                    |
/// |  Active Transfers ---------------> |
/// |  (none)                            |
/// +----------------------------------+
/// ```
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasActiveTransfers = ref.watch(activeTransfersProvider).isNotEmpty;

    if (hasActiveTransfers) {
      return const _ActiveTransfersView();
    }

    final stage = ref.watch(homeFlowProvider).stage;
    return switch (stage) {
      HomeFlowStage.idle => const _IdleView(),
      HomeFlowStage.filePicker => const _FilePickerView(),
      HomeFlowStage.deviceSelectSend => const _DeviceSelectSendView(),
      HomeFlowStage.confirmSend => const _ConfirmSendView(),
      HomeFlowStage.receiveMode => const _ReceiveModeView(),
    };
  }
}

/// State 1: one or more active transfers in progress.
class _ActiveTransfersView extends StatelessWidget {
  const _ActiveTransfersView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Active Transfers')),
      body: const ActiveTransfersList(),
    );
  }
}

/// State 2 (idle): Send/Receive choice buttons.
class _IdleView extends ConsumerWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverAppBar.large(title: Text('FileDrop')),
            SliverPadding(
              padding: const EdgeInsets.all(20),
              sliver: SliverList.list(children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => ref.read(homeFlowProvider.notifier).startSend(),
                        icon: const Icon(Icons.upload_outlined),
                        label: const Text('Send Files'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => ref.read(homeFlowProvider.notifier).startReceive(),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('Receive'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                const ThemeSectionHeader(title: 'Nearby Devices'),
                const SizedBox(height: 8),
                SizedBox(height: 240, child: _NearbyPreview()),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _NearbyPreview extends ConsumerWidget {
  const _NearbyPreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(nearbyDevicesProvider);
    if (devices.isEmpty) {
      return const ThemeEmptyState(
        icon: Icons.wifi_tethering,
        title: 'Searching for devices…',
        subtitle: 'Make sure both devices are on the same Wi-Fi network.',
      );
    }
    return const NearbyDevicesBody();
  }
}

/// Send flow, step 1: pick files. Back returns to idle.
class _FilePickerView extends ConsumerWidget {
  const _FilePickerView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(homeFlowProvider.notifier).back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => ref.read(homeFlowProvider.notifier).back()),
        ),
        body: FilePickerBody(
          onContinue: (paths) => ref.read(homeFlowProvider.notifier).filesPicked(paths),
        ),
      ),
    );
  }
}

/// Send flow, step 2: pick the destination device. Back returns to file
/// picking (discarding the device selection, if any was already made).
class _DeviceSelectSendView extends ConsumerWidget {
  const _DeviceSelectSendView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(homeFlowProvider.notifier).back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Nearby Devices'),
          leading: BackButton(onPressed: () => ref.read(homeFlowProvider.notifier).back()),
        ),
        body: NearbyDevicesBody(
          onDeviceSelected: (device) => ref.read(homeFlowProvider.notifier).deviceSelected(device),
        ),
      ),
    );
  }
}

/// Send flow, step 3: confirm and dispatch. On successful dispatch the
/// flow resets to idle; [HomeScreen] then flips to the active-transfer
/// view as soon as the resulting `TransferStarted` event lands in
/// [activeTransfersProvider].
class _ConfirmSendView extends ConsumerWidget {
  const _ConfirmSendView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(homeFlowProvider);
    final device = flow.device;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(homeFlowProvider.notifier).back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => ref.read(homeFlowProvider.notifier).back()),
        ),
        body: device == null
            ? const SizedBox.shrink()
            : SendConfirmationBody(
                device: device,
                filePaths: flow.filePaths,
                onSent: () => ref.read(homeFlowProvider.notifier).reset(),
              ),
      ),
    );
  }
}

/// Receive mode: nearby devices shown while waiting for an incoming
/// request, which surfaces as an overlay from the app shell (see
/// `main.dart`) rather than by navigating away from this view. Back
/// returns to idle.
class _ReceiveModeView extends ConsumerWidget {
  const _ReceiveModeView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(homeFlowProvider.notifier).reset();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Waiting to Receive'),
          leading: BackButton(onPressed: () => ref.read(homeFlowProvider.notifier).reset()),
        ),
        body: const NearbyDevicesBody(
          emptyTitle: 'Waiting for nearby devices…',
          emptySubtitle: 'Keep this screen open — you\'ll be prompted here when another '
              'device wants to send you files.',
        ),
      ),
    );
  }
}
