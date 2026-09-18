import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:theme/theme.dart';

import 'providers/filedrop_providers.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/transfer_history_screen.dart';
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
    return MaterialApp(
      title: 'FileDrop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: ThemeMode.system,
      navigatorKey: _rootNavigatorKey,
      home: const _FileDropStartup(),
    );
  }
}

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Initializes the Rust engine + local server on first frame, then shows
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
    await service.init(deviceName: _defaultDeviceName(), appDataDir: appDataDir.path);
    await service.startServer();
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
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
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

/// The 3-tab bottom-navigation shell: Home / History / Settings, switched
/// via an [IndexedStack] so each tab keeps its scroll position and state
/// (e.g. the Home tab's in-flight Send/Receive flow) when the user
/// switches away and back.
///
/// Also owns the app-wide incoming-transfer overlay: listens to
/// [pairingRequestsProvider] and shows [IncomingTransferSheet] as a
/// themed bottom sheet on top of whatever tab is active, so it works
/// regardless of navigation state within a tab.
class _AppShell extends ConsumerStatefulWidget {
  const _AppShell();

  @override
  ConsumerState<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<_AppShell> {
  int _tabIndex = 0;
  bool _sheetOpen = false;

  static const _tabs = [HomeScreen(), TransferHistoryScreen(), SettingsScreen()];

  static const _destinations = [
    ThemeNavigationDestinationItem(icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Home'),
    ThemeNavigationDestinationItem(
      icon: Icons.history_outlined,
      selectedIcon: Icons.history,
      label: 'History',
    ),
    ThemeNavigationDestinationItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    ref.listen(pairingRequestsProvider, (previous, next) {
      if (next.isNotEmpty && !_sheetOpen) {
        final request = next.first;
        _sheetOpen = true;
        ThemeBottomSheet.show(
          context,
          isScrollControlled: true,
          builder: (_) => IncomingTransferSheet(request: request),
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

    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: _tabs),
      bottomNavigationBar: ThemeNavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: _destinations,
      ),
    );
  }
}
