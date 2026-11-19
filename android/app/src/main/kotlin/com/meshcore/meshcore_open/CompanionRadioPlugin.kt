package com.meshcore.meshcore_open

import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.ObservingDevicePresenceRequest
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Companion Device Manager for the BLE radio.
 *
 * An association lets Android bind [RadioPresenceService] when the radio comes
 * into range (Android 12+), which starts the process even after the system
 * killed it, and lets the app start its foreground service from the
 * background. When no Flutter engine runs at that moment, [startHeadlessEngine]
 * runs the app's `main()` without a window; it reconnects on its own and
 * [MainActivity] later shows that same engine.
 */
class CompanionRadioPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val TAG = "CompanionRadio"
        private const val REQUEST_ASSOCIATE = 0x4d43
        const val HEADLESS_ENGINE_ID = "meshcore_open_headless"

        // Touched on the main thread only.
        private val attached = mutableSetOf<CompanionRadioPlugin>()
        private val presenceSinks = mutableSetOf<EventChannel.EventSink>()
        private var startedByPresence = false

        fun isSupported(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                context.packageManager.hasSystemFeature(
                    PackageManager.FEATURE_COMPANION_DEVICE_SETUP,
                )

        fun dispatchPresence(address: String, present: Boolean) {
            val event = mapOf("address" to address.uppercase(), "present" to present)
            for (sink in presenceSinks.toList()) sink.success(event)
        }

        /** Runs `main()` in a windowless engine unless one already runs. */
        fun startHeadlessEngine(context: Context) {
            if (attached.isNotEmpty() ||
                FlutterEngineCache.getInstance().contains(HEADLESS_ENGINE_ID)
            ) {
                return
            }
            Log.i(TAG, "Radio in range and the app is not running: starting it")
            startedByPresence = true
            val engine = FlutterEngine(context.applicationContext)
            engine.plugins.add(CompanionRadioPlugin())
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
            FlutterEngineCache.getInstance().put(HEADLESS_ENGINE_ID, engine)
        }

        @Suppress("DEPRECATION")
        private fun associations(manager: CompanionDeviceManager): List<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.myAssociations.mapNotNull {
                    it.deviceMacAddress?.toString()?.uppercase()
                }
            } else {
                manager.associations.map { it.uppercase() }
            }

        @RequiresApi(Build.VERSION_CODES.TIRAMISU)
        fun associationFor(
            manager: CompanionDeviceManager,
            address: String,
        ): AssociationInfo? = manager.myAssociations.firstOrNull {
            it.deviceMacAddress?.toString().equals(address, ignoreCase = true)
        }

        @RequiresApi(Build.VERSION_CODES.TIRAMISU)
        fun addressFor(manager: CompanionDeviceManager, associationId: Int): String? =
            manager.myAssociations
                .firstOrNull { it.id == associationId }
                ?.deviceMacAddress
                ?.toString()

        @Suppress("DEPRECATION")
        fun setObserving(context: Context, address: String, observe: Boolean) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
            val manager = context.getSystemService(CompanionDeviceManager::class.java)
                ?: return
            if (!associations(manager).contains(address.uppercase())) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                val association = associationFor(manager, address) ?: return
                val request = ObservingDevicePresenceRequest.Builder()
                    .setAssociationId(association.id)
                    .build()
                if (observe) {
                    manager.startObservingDevicePresence(request)
                } else {
                    manager.stopObservingDevicePresence(request)
                }
            } else if (observe) {
                manager.startObservingDevicePresence(address.uppercase())
            } else {
                manager.stopObservingDevicePresence(address.uppercase())
            }
            Log.i(TAG, "Presence observation for $address: $observe")
        }
    }

    private var context: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingAddress: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "meshcore_open/companion_device",
        ).also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(
            binding.binaryMessenger,
            "meshcore_open/companion_device/presence",
        ).also { it.setStreamHandler(this) }
        attached.add(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached.remove(this)
        eventSink?.let { presenceSinks.remove(it) }
        eventSink = null
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        presenceSinks.add(events)
    }

    override fun onCancel(arguments: Any?) {
        eventSink?.let { presenceSinks.remove(it) }
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context ?: return result.error("detached", null, null)
        when (call.method) {
            "isSupported" -> result.success(isSupported(context))
            "canObservePresence" -> result.success(
                isSupported(context) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S,
            )
            "takeStartedByPresence" -> {
                result.success(startedByPresence)
                startedByPresence = false
            }
            "isAssociated" -> {
                val address = call.argument<String>("address")
                    ?: return result.error("args", "address missing", null)
                val manager = manager(context) ?: return result.success(false)
                result.success(associations(manager).contains(address.uppercase()))
            }
            "associate" -> {
                val address = call.argument<String>("address")
                    ?: return result.error("args", "address missing", null)
                associate(address.uppercase(), result)
            }
            "disassociate" -> {
                val address = call.argument<String>("address")
                    ?: return result.error("args", "address missing", null)
                disassociate(context, address.uppercase())
                result.success(null)
            }
            "setObserving" -> {
                val address = call.argument<String>("address")
                    ?: return result.error("args", "address missing", null)
                val observe = call.argument<Boolean>("observe") ?: true
                try {
                    setObserving(context, address, observe)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("observe", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun manager(context: Context): CompanionDeviceManager? =
        if (isSupported(context)) {
            context.getSystemService(CompanionDeviceManager::class.java)
        } else {
            null
        }

    @Suppress("DEPRECATION")
    private fun associate(address: String, result: MethodChannel.Result) {
        val activity = activityBinding?.activity
            ?: return result.error("no_activity", "Needs a visible activity", null)
        val manager = manager(activity)
            ?: return result.error("unsupported", "Companion devices not supported", null)
        if (pendingResult != null) return result.error("busy", "Already associating", null)
        if (associations(manager).contains(address)) {
            startObservingQuietly(activity, address)
            return result.success("associated")
        }
        // A bonded radio matches the classic filter from the bonded list
        // right away, even while it is connected and not advertising. An
        // unbonded one has to be found by its advertisement.
        val request = AssociationRequest.Builder()
            .addDeviceFilter(BluetoothDeviceFilter.Builder().setAddress(address).build())
            .addDeviceFilter(
                BluetoothLeDeviceFilter.Builder()
                    .setScanFilter(ScanFilter.Builder().setDeviceAddress(address).build())
                    .build(),
            )
            .setSingleDevice(true)
            .build()
        pendingResult = result
        pendingAddress = address
        val callback = object : CompanionDeviceManager.Callback() {
            override fun onAssociationPending(intentSender: IntentSender) =
                launchChooser(activity, intentSender)

            @Deprecated("Android 12L and older")
            override fun onDeviceFound(intentSender: IntentSender) =
                launchChooser(activity, intentSender)

            override fun onAssociationCreated(associationInfo: AssociationInfo) =
                finishAssociated()

            override fun onFailure(errorCode: Int, error: CharSequence?) {
                Log.w(TAG, "Association failed: $errorCode $error")
                finish(
                    if (errorCode == CompanionDeviceManager.RESULT_DISCOVERY_TIMEOUT) {
                        "notFound"
                    } else if (errorCode == CompanionDeviceManager.RESULT_USER_REJECTED ||
                        errorCode == CompanionDeviceManager.RESULT_CANCELED
                    ) {
                        "cancelled"
                    } else {
                        "failed"
                    },
                )
            }

            override fun onFailure(error: CharSequence?) {
                Log.w(TAG, "Association failed: $error")
                finish("notFound")
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.associate(request, activity.mainExecutor, callback)
        } else {
            manager.associate(request, callback, Handler(Looper.getMainLooper()))
        }
    }

    @Suppress("DEPRECATION")
    private fun launchChooser(activity: Activity, intentSender: IntentSender) {
        try {
            activity.startIntentSenderForResult(
                intentSender,
                REQUEST_ASSOCIATE,
                null,
                0,
                0,
                0,
            )
        } catch (e: IntentSender.SendIntentException) {
            Log.w(TAG, "Could not show the association dialog", e)
            finish("failed")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_ASSOCIATE) return false
        if (resultCode == Activity.RESULT_OK) finishAssociated() else finish("cancelled")
        return true
    }

    private fun finishAssociated() {
        val address = pendingAddress ?: return
        context?.let { startObservingQuietly(it, address) }
        finish("associated")
    }

    private fun startObservingQuietly(context: Context, address: String) {
        try {
            setObserving(context, address, true)
        } catch (e: Exception) {
            Log.w(TAG, "Could not observe $address", e)
        }
    }

    private fun finish(outcome: String) {
        val result = pendingResult ?: return
        pendingResult = null
        pendingAddress = null
        result.success(outcome)
    }

    @Suppress("DEPRECATION")
    private fun disassociate(context: Context, address: String) {
        val manager = manager(context) ?: return
        try {
            setObserving(context, address, false)
        } catch (e: Exception) {
            Log.w(TAG, "Could not stop observing $address", e)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            associationFor(manager, address)?.let { manager.disassociate(it.id) }
        } else if (associations(manager).contains(address)) {
            manager.disassociate(address)
        }
    }
}
