package com.meshcore.meshcore_open

import android.companion.AssociationInfo
import android.companion.CompanionDeviceManager
import android.companion.CompanionDeviceService
import android.companion.DevicePresenceEvent
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * Android binds this service while an associated radio is in range (Android
 * 12+, presence observation on). Binding starts the process if it is not
 * running, for example after the system killed it at night; the app then
 * starts its foreground service and reconnects.
 *
 * Android 12 calls the address variants, Android 13 to 15 the
 * [AssociationInfo] ones and Android 16+ [onDevicePresenceEvent].
 */
@RequiresApi(Build.VERSION_CODES.S)
class RadioPresenceService : CompanionDeviceService() {

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Bound by the companion device manager")
        CompanionRadioPlugin.startHeadlessEngine(this)
    }

    @Deprecated("Android 12")
    override fun onDeviceAppeared(address: String) = onPresence(address, true)

    @Deprecated("Android 12")
    override fun onDeviceDisappeared(address: String) = onPresence(address, false)

    @Deprecated("Android 13 to 15")
    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        associationInfo.deviceMacAddress?.let { onPresence(it.toString(), true) }
    }

    @Deprecated("Android 13 to 15")
    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        associationInfo.deviceMacAddress?.let { onPresence(it.toString(), false) }
    }

    @RequiresApi(Build.VERSION_CODES.BAKLAVA)
    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        val present = when (event.event) {
            DevicePresenceEvent.EVENT_BLE_APPEARED,
            DevicePresenceEvent.EVENT_BT_CONNECTED,
            -> true
            DevicePresenceEvent.EVENT_BLE_DISAPPEARED,
            DevicePresenceEvent.EVENT_BT_DISCONNECTED,
            -> false
            else -> return
        }
        val manager = getSystemService(CompanionDeviceManager::class.java) ?: return
        val address = CompanionRadioPlugin.addressFor(manager, event.associationId) ?: return
        onPresence(address, present)
    }

    private fun onPresence(address: String, present: Boolean) {
        // Android 16+ can report one change through more than one callback.
        if (lastPresence[address.uppercase()] == present) return
        lastPresence[address.uppercase()] = present
        Log.i(TAG, "Radio $address ${if (present) "appeared" else "disappeared"}")
        if (present) CompanionRadioPlugin.startHeadlessEngine(this)
        CompanionRadioPlugin.dispatchPresence(address, present)
    }

    private companion object {
        const val TAG = "CompanionRadio"

        // Main thread only.
        val lastPresence = mutableMapOf<String, Boolean>()
    }
}
