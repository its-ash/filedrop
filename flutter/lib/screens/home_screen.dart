import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
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

/// Receive mode: a small sub-flow (see [ReceiveStage]) rather than the
/// nearby-devices list — the key behavior change from the old
/// `_ReceiveModeView`, since incoming requests arrive via the
/// [pairingRequestsProvider]-driven overlay (see `main.dart`) regardless
/// of what this view shows, and browsing nearby devices has no purpose
/// while receiving. Back returns to idle (and tears down any Wi-Fi Direct
/// group created this session via [HomeFlowNotifier.back]).
class _ReceiveModeView extends ConsumerWidget {
  const _ReceiveModeView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receive = ref.watch(homeFlowProvider.select((s) => s.receive));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(homeFlowProvider.notifier).back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Receive'),
          leading: BackButton(onPressed: () => ref.read(homeFlowProvider.notifier).back()),
        ),
        body: switch (receive.stage) {
          ReceiveStage.checkingLan => const _CheckingLanBody(),
          ReceiveStage.noLanFound => const _CreateNetworkPromptBody(),
          ReceiveStage.creatingGroup => const _CreatingGroupBody(),
          ReceiveStage.wifiDirectError => _WifiDirectErrorBody(message: receive.errorMessage),
          ReceiveStage.waiting => _WaitingToReceiveBody(address: receive.address),
        },
      ),
    );
  }
}

class _CheckingLanBody extends StatelessWidget {
  const _CheckingLanBody();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemeSpinner(type: ThemeSpinnerType.dualRing),
          SizedBox(height: 20),
          Text('Checking your network…'),
        ],
      ),
    );
  }
}

/// No usable LAN was found — prompts the user to create a transient
/// Wi-Fi Direct network so a sender with no shared Wi-Fi can still reach
/// this device.
class _CreateNetworkPromptBody extends ConsumerWidget {
  const _CreateNetworkPromptBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ThemeCard(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_off_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 20),
                const Text('No Wi-Fi network found', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                  'FileDrop couldn\'t find a shared Wi-Fi network to receive over. Create a '
                  'temporary Wi-Fi Direct network so a nearby device can send you files '
                  'directly, with no router needed.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => ref.read(homeFlowProvider.notifier).createWifiDirectGroup(),
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Create Network'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CreatingGroupBody extends StatelessWidget {
  const _CreatingGroupBody();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ThemeSpinner(type: ThemeSpinnerType.pulse),
          SizedBox(height: 20),
          Text('Creating Wi-Fi Direct network…'),
        ],
      ),
    );
  }
}

class _WifiDirectErrorBody extends ConsumerWidget {
  const _WifiDirectErrorBody({this.message});

  final String? message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ThemeErrorState(
      title: 'Couldn\'t create network',
      subtitle: message ?? 'An unknown error occurred while setting up Wi-Fi Direct.',
      icon: Icons.wifi_tethering_error_rounded,
      onRetry: () => ref.read(homeFlowProvider.notifier).retryWifiDirect(),
    );
  }
}

/// Waiting to receive: shows this device's address and a spinner. No
/// nearby-devices list here — the incoming-transfer prompt arrives via
/// the app-shell-level [pairingRequestsProvider] overlay regardless of
/// what's on screen.
class _WaitingToReceiveBody extends StatelessWidget {
  const _WaitingToReceiveBody({this.address});

  final String? address;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ThemeSpinner(type: ThemeSpinnerType.ripple, size: 56),
            const SizedBox(height: 24),
            const Text('Waiting for incoming files…', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              'Keep this screen open. You\'ll be prompted here when another device '
              'wants to send you files.',
              textAlign: TextAlign.center,
            ),
            if (address != null) ...[
              const SizedBox(height: 20),
              ThemeCard(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lan_outlined, size: 18),
                      const SizedBox(width: 8),
                      Text(address!, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        tooltip: 'Copy address',
                        onPressed: () => Clipboard.setData(ClipboardData(text: address!)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
