package com.mickey.cashew

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var assistantSpeech: AssistantSpeechBridge? = null
    private var notificationMethods: MethodChannel? = null
    private var notificationEvents: EventChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        assistantSpeech = AssistantSpeechBridge(this, messenger)
        notificationMethods = MethodChannel(messenger, "cashew/bank_notifications/settings")
        notificationMethods?.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" -> result.success(hasBankNotificationAccess())
                "listApps" -> {
                    val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    @Suppress("DEPRECATION")
                    val apps = packageManager.queryIntentActivities(launcher, 0)
                        .filter { it.activityInfo.packageName != packageName }
                        .distinctBy { it.activityInfo.packageName }
                        .map { mapOf(
                            "package" to it.activityInfo.packageName,
                            "label" to it.loadLabel(packageManager).toString(),
                        ) }
                    result.success(apps)
                }
                "openAccessSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    } catch (_: android.content.ActivityNotFoundException) {
                        result.error("unavailable", "Notification access settings unavailable", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        notificationEvents = EventChannel(messenger, "cashew/bank_notifications/events")
        notificationEvents?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                BankNotificationListener.allowedPackages =
                    (arguments as? List<*>)?.filterIsInstance<String>()?.toSet().orEmpty()
                BankNotificationListener.sink = events
            }

            override fun onCancel(arguments: Any?) = clearBankNotificationStream()
        })
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        clearBankNotificationStream()
        assistantSpeech?.dispose()
        assistantSpeech = null
        notificationMethods?.setMethodCallHandler(null)
        notificationEvents?.setStreamHandler(null)
        notificationMethods = null
        notificationEvents = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStop() {
        assistantSpeech?.stopActiveRecognition()
        super.onStop()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        assistantSpeech?.onPermissions(requestCode, grantResults)
    }

    private fun clearBankNotificationStream() {
        BankNotificationListener.sink = null
        BankNotificationListener.allowedPackages = emptySet()
    }

    private fun hasBankNotificationAccess(): Boolean {
        val component = ComponentName(this, BankNotificationListener::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            return getSystemService(NotificationManager::class.java)
                ?.isNotificationListenerAccessGranted(component) == true
        }
        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        return enabled.orEmpty().split(':').any { ComponentName.unflattenFromString(it) == component }
    }
}
