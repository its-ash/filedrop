package com.itsash.filedrop

import android.content.Context
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Real Wi-Fi Direct platform-channel handler backing
 * `flutter/lib/services/wifi_direct_service.dart`.
 *
 * Wraps `android.net.wifi.p2p.WifiP2pManager` — the Java/Kotlin-only
 * Android framework service reached over Binder IPC that Rust cannot call
 * directly (see `docs/ARCHITECTURE.md`'s "No router / direct connect"
 * table and `rust/filedrop-core/src/networking/mode.rs`). Only group
 * creation/teardown is implemented here; peer discovery is intentionally
 * NOT performed (`discoverPeers()` is never called) — FileDrop uses its
 * own mDNS/UDP discovery once a link exists, so no physical-location
 * derivation happens here (see the `neverForLocation` manifest flag).
 */
class WifiDirectHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "FileDropWifiDirect"
        const val CHANNEL_NAME = "com.itsash.filedrop/wifi_direct"
    }

    private val manager: WifiP2pManager? =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private var p2pChannel: WifiP2pManager.Channel? = null

    private fun ensureChannel(): WifiP2pManager.Channel? {
        val mgr = manager ?: return null
        if (p2pChannel == null) {
            p2pChannel = mgr.initialize(context, context.mainLooper, null)
        }
        return p2pChannel
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createGroup" -> createGroup(result)
            "removeGroup" -> removeGroup(result)
            else -> result.notImplemented()
        }
    }

    private fun createGroup(result: MethodChannel.Result) {
        val mgr = manager
        if (mgr == null) {
            result.error("P2P_UNSUPPORTED", "Wi-Fi Direct is not available on this device.", null)
            return
        }

        val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifiManager != null && !wifiManager.isWifiEnabled) {
            result.error("WIFI_DISABLED", "Wi-Fi is turned off.", null)
            return
        }

        val channel = ensureChannel()
        if (channel == null) {
            result.error("P2P_UNSUPPORTED", "Wi-Fi Direct is not available on this device.", null)
            return
        }

        try {
            mgr.createGroup(
                channel,
                object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.i(TAG, "createGroup: onSuccess, requesting connection info")
                        requestGroupOwnerAddress(mgr, channel, result)
                    }

                    override fun onFailure(reasonCode: Int) {
                        Log.w(TAG, "createGroup: onFailure reason=$reasonCode")
                        result.error(
                            reasonCodeToErrorCode(reasonCode),
                            "Failed to create Wi-Fi Direct group (${reasonName(reasonCode)}).",
                            reasonCode,
                        )
                    }
                },
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "createGroup: permission denied", e)
            result.error("PERMISSION_DENIED", "Missing permission for Wi-Fi Direct.", e.message)
        }
    }

    private fun requestGroupOwnerAddress(
        mgr: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        result: MethodChannel.Result,
    ) {
        try {
            mgr.requestConnectionInfo(channel) { info ->
                val address = info?.groupOwnerAddress?.hostAddress
                if (info != null && info.groupFormed && address != null) {
                    Log.i(TAG, "requestConnectionInfo: groupOwnerAddress=$address")
                    result.success(address)
                } else {
                    Log.w(TAG, "requestConnectionInfo: no group info available")
                    result.error(
                        "NO_GROUP_INFO",
                        "Wi-Fi Direct group was created but its address could not be determined.",
                        null,
                    )
                }
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "requestConnectionInfo: permission denied", e)
            result.error("PERMISSION_DENIED", "Missing permission for Wi-Fi Direct.", e.message)
        }
    }

    private fun removeGroup(result: MethodChannel.Result) {
        val mgr = manager
        val channel = p2pChannel
        if (mgr == null || channel == null) {
            // Nothing was ever initialized/created — a benign no-op.
            result.success(null)
            return
        }

        try {
            mgr.removeGroup(
                channel,
                object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.i(TAG, "removeGroup: onSuccess")
                        result.success(null)
                    }

                    override fun onFailure(reasonCode: Int) {
                        // WifiP2pManager reports a failure here even when there
                        // was simply no group to remove; treat any removeGroup
                        // failure as a benign no-op rather than surfacing an
                        // error Dart-side has no meaningful retry for.
                        Log.i(TAG, "removeGroup: onFailure reason=$reasonCode (treated as no-op)")
                        result.success(null)
                    }
                },
            )
        } catch (e: SecurityException) {
            Log.w(TAG, "removeGroup: permission denied, treating as no-op", e)
            result.success(null)
        }
    }

    private fun reasonCodeToErrorCode(reasonCode: Int): String = when (reasonCode) {
        WifiP2pManager.P2P_UNSUPPORTED -> "P2P_UNSUPPORTED"
        WifiP2pManager.BUSY -> "BUSY"
        else -> "ERROR"
    }

    private fun reasonName(reasonCode: Int): String = when (reasonCode) {
        WifiP2pManager.P2P_UNSUPPORTED -> "P2P_UNSUPPORTED"
        WifiP2pManager.BUSY -> "BUSY"
        WifiP2pManager.ERROR -> "ERROR"
        else -> "reason=$reasonCode"
    }
}
