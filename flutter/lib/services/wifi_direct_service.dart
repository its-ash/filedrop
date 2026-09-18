import 'package:flutter/services.dart';

/// Dart-side service layer wrapping the platform channel to
/// `android.net.wifi.p2p.WifiP2pManager` (Kotlin implementation:
/// `flutter/android/app/src/main/kotlin/com/itsash/filedrop/WifiDirectHandler.kt`,
/// registered from `MainActivity.configureFlutterEngine`).
///
/// This is Android-only native code (see `docs/ARCHITECTURE.md`'s "No
/// router / direct connect" table) reached the same way any Flutter
/// platform-channel wrapper is: a thin class around [MethodChannel] that
/// converts [PlatformException]s into a typed, UI-friendly exception.
/// Kept consistent in style with `FileDropFfiService`
/// (`filedrop_ffi_service.dart`) — a singleton instance, `Future<T>`
/// methods, exceptions rather than result wrappers.
class WifiDirectService {
  WifiDirectService._();
  static final WifiDirectService instance = WifiDirectService._();

  static const MethodChannel _channel = MethodChannel('com.itsash.filedrop/wifi_direct');

  /// Requests runtime creation of a Wi-Fi Direct autonomous group and
  /// returns the resulting group owner's IPv4 address (e.g. `"192.168.49.1"`),
  /// read from the real `WifiP2pInfo.groupOwnerAddress` on the Kotlin
  /// side via `requestConnectionInfo` — never hardcoded.
  ///
  /// Throws a [WifiDirectException] with a specific, human-readable
  /// message on failure (Wi-Fi disabled, permission denied, hardware
  /// unsupported, or a generic `WifiP2pManager` failure reason).
  Future<String> createGroup() async {
    try {
      final address = await _channel.invokeMethod<String>('createGroup');
      if (address == null || address.isEmpty) {
        throw const WifiDirectException(
          'Wi-Fi Direct group was created but no group owner address was returned.',
        );
      }
      return address;
    } on PlatformException catch (e) {
      throw WifiDirectException(_messageFor(e), code: e.code);
    }
  }

  /// Tears down any Wi-Fi Direct group owned by this device. Tolerant of
  /// "no group to remove" — that is treated as a benign no-op by the
  /// Kotlin side, not surfaced as an error.
  Future<void> removeGroup() async {
    try {
      await _channel.invokeMethod<void>('removeGroup');
    } on PlatformException catch (e) {
      // removeGroup failures are non-fatal from the Dart caller's point of
      // view (there is nothing further the UI can meaningfully retry);
      // still surface as a typed exception so callers that care can log
      // it, but never let it crash a reset()/back() call site.
      throw WifiDirectException(_messageFor(e), code: e.code);
    }
  }

  String _messageFor(PlatformException e) {
    return switch (e.code) {
      'WIFI_DISABLED' => 'Wi-Fi is turned off. Turn on Wi-Fi and try again.',
      'PERMISSION_DENIED' =>
        'FileDrop needs nearby-devices/location permission to create a Wi-Fi Direct network.',
      'P2P_UNSUPPORTED' => 'This device does not support Wi-Fi Direct.',
      'BUSY' => 'Wi-Fi Direct is busy. Try again in a moment.',
      'NO_GROUP_INFO' => 'Could not determine the Wi-Fi Direct group address.',
      _ => e.message ?? 'Wi-Fi Direct request failed (${e.code}).',
    };
  }
}

/// Thrown when a Wi-Fi Direct platform-channel call fails, with a message
/// already suitable for display in the receive flow's error state.
class WifiDirectException implements Exception {
  const WifiDirectException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'WifiDirectException: $message';
}
