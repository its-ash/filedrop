import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:theme/theme.dart';

import 'providers/filedrop_providers.dart';
import 'screens/home_screen.dart';
import 'widgets/incoming_transfer_sheet.dart';

void main() {
  runApp(const ProviderScope(child: FileDropApp()));
}

/// Root widget. Theming comes entirely from the shared `theme` package
/// (`/Users/ashvinijangid/Desktop/android/theme`, published as `its-ash/theme`)
/// per project convention — FileDrop does not define its own ThemeData.
class FileDropApp extends StatelessWidget {
  const FileDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return UiApp(
      title: 'FileDrop',
      navigatorKey: _rootNavigatorKey,
      home: const _FileDropStartup(),
    );
  }
}

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Initializes the Rust engine (no server) on first frame, then shows
/// the [_AppShell]. Also listens for [PairingRequestedEvent]s for the
/// lifetime of the app and shows [IncomingTransferSheet] as an overlay
/// when one arrives, regardless of which tab is currently active.
class _FileDropStartup extends ConsumerStatefulWidget {
  const _FileDropStartup();

  @override
  ConsumerState<_FileDropStartup> createState() => _FileDropStartupState();
}

class _FileDropStartupState extends ConsumerState<_FileDropStartup> {
  late final Future<void> _initFuture = _init();

  Future<void> _init() async {
    final service = ref.read(fileDropServiceProvider);
    final appDataDir = await getApplicationSupportDirectory();
    await service.init(
      deviceName: _defaultDeviceName(),
      appDataDir: appDataDir.path,
    );
    // No server, discovery or Wi-Fi Direct work here: it starts only when
    // the user picks Send or Receive on the home screen.
  }

  String _defaultDeviceName() {
    // A real implementation would pull the OS hostname / device model via
    // a platform channel; kept as a static default here since device-name
    // resolution is a platform-integration detail out of scope for this
    // scaffold pass (see docs/ARCHITECTURE.md).
    return 'FileDrop Device';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Failed to start FileDrop engine:\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        return const _AppShell();
      },
    );
  }
}

/// The app shell: the [HomeScreen] (Settings and History open from its app
/// bar) plus the app-wide incoming-transfer overlay: listens to
/// [pairingRequestsProvider] and shows [IncomingTransferSheet] as a
/// themed bottom sheet on top of whatever is on screen.
class _AppShell extends ConsumerStatefulWidget {
  const _AppShell();

  @override
  ConsumerState<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<_AppShell> {
  bool _sheetOpen = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(pairingRequestsProvider, (previous, next) {
      if (next.isNotEmpty && !_sheetOpen) {
        final request = next.first;
        _sheetOpen = true;
        UiSheet.show<void>(
          context,
          padding: EdgeInsets.zero,
          child: IncomingTransferSheet(request: request),
        ).whenComplete(() {
          _sheetOpen = false;
          // Guard against the user dismissing the sheet (tap outside /
          // swipe down) without tapping Accept/Reject, which would
          // otherwise leave a stale request in the queue and re-show the
          // same sheet as soon as any other provider state changes.
          ref.read(pairingRequestsProvider.notifier).dismiss(request.deviceId);
        });
      }
    });

    return const HomeScreen();
  }
}
