package com.itsash.filedrop

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
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
 * table and `rust/filedrop-core/src/networking/mode.rs`). Receiver:
 * group creation/teardown. Sender: `joinNearbyGroup` (peer discovery +
 * connect, only when the user chose Send and no Wi-Fi is available).
 * FileDrop's own mDNS/UDP discovery runs once the link exists.
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
            "joinNearbyGroup" -> joinNearbyGroup(result)
            "isWifiEnabled" -> {
                val wm = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                result.success(wm?.isWifiEnabled ?: false)
            }
            "openWifiPanel" -> openWifiPanel(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Android 10+ apps cannot toggle Wi-Fi; show the system Internet panel
     * (Wi-Fi switch) instead, or the Wi-Fi settings page on older versions.
     */
    private fun openWifiPanel(result: MethodChannel.Result) {
        try {
            val action = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Settings.Panel.ACTION_WIFI
            } else {
                Settings.ACTION_WIFI_SETTINGS
            }
            context.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.success(null)
        } catch (e: Exception) {
            result.error("ERROR", "Could not open Wi-Fi settings.", e.message)
        }
    }

    /**
     * Sender side of Wi-Fi Direct: discover peers, prefer a group owner,
     * connect to it and return the group owner address once the link is up.
     * Polls (peers every second up to 15 s, link up to 25 s).
     */
    private fun joinNearbyGroup(result: MethodChannel.Result) {
        val mgr = manager
        val channel = ensureChannel()
        if (mgr == null || channel == null) {
            result.error("P2P_UNSUPPORTED", "Wi-Fi Direct is not available on this device.", null)
            return
        }
        val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifiManager != null && !wifiManager.isWifiEnabled) {
            result.error("WIFI_DISABLED", "Wi-Fi is turned off.", null)
            return
        }
        val handler = Handler(Looper.getMainLooper())
        try {
            mgr.discoverPeers(
                channel,
                object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        pollPeers(mgr, channel, handler, result, 0)
                    }

                    override fun onFailure(reasonCode: Int) {
                        result.error(
                            reasonCodeToErrorCode(reasonCode),
                            "Could not search for nearby devices (${reasonName(reasonCode)}).",
                            reasonCode,
                        )
                    }
                },
            )
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Missing permission for Wi-Fi Direct.", e.message)
        }
    }

    private fun pollPeers(
        mgr: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        handler: Handler,
        result: MethodChannel.Result,
        attempt: Int,
    ) {
        try {
            mgr.requestPeers(channel) { peers ->
                val list = peers?.deviceList?.toList() ?: emptyList()
                val target = list.firstOrNull { it.isGroupOwner } ?: list.firstOrNull()
                if (target != null) {
                    connectToPeer(mgr, channel, handler, result, target.deviceAddress)
                } else if (attempt >= 15) {
                    result.error("NO_PEERS", "No nearby device in receive mode was found.", null)
                } else {
                    handler.postDelayed({ pollPeers(mgr, channel, handler, result, attempt + 1) }, 1000)
                }
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Missing permission for Wi-Fi Direct.", e.message)
        }
    }

    private fun connectToPeer(
        mgr: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        handler: Handler,
        result: MethodChannel.Result,
        deviceAddress: String,
    ) {
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
        }
        try {
            mgr.connect(
                channel,
                config,
                object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        pollConnection(mgr, channel, handler, result, 0)
                    }

                    override fun onFailure(reasonCode: Int) {
                        result.error(
                            reasonCodeToErrorCode(reasonCode),
                            "Could not connect to the nearby device (${reasonName(reasonCode)}).",
                            reasonCode,
                        )
                    }
                },
            )
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Missing permission for Wi-Fi Direct.", e.message)
        }
    }

    private fun pollConnection(
        mgr: WifiP2pManager,
        channel: WifiP2pManager.Channel,
        handler: Handler,
        result: MethodChannel.Result,
        attempt: Int,
    ) {
        try {
            mgr.requestConnectionInfo(channel) { info ->
                val address = info?.groupOwnerAddress?.hostAddress
                if (info != null && info.groupFormed && address != null) {
                    result.success(address)
                } else if (attempt >= 25) {
                    result.error("NO_GROUP_INFO", "The nearby device did not accept the connection.", null)
                } else {
                    handler.postDelayed({ pollConnection(mgr, channel, handler, result, attempt + 1) }, 1000)
                }
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Missing permission for Wi-Fi Direct.", e.message)
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
