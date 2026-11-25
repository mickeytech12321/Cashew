package com.mickey.cashew

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var assistantKeyMethods: MethodChannel? = null
    private var assistantSpeech: AssistantSpeechBridge? = null
    private var notificationMethods: MethodChannel? = null
    private var notificationEvents: EventChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        assistantSpeech = AssistantSpeechBridge(this, messenger)
        val assistantKey = LocalEncryptedFile(this, "assistant-api-key")
        assistantKeyMethods = MethodChannel(messenger, "cashew/assistant_key")
        assistantKeyMethods?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> result.success(assistantKey.read())
                    "save" -> {
                        val value = call.arguments as? String
                        if (value == null || value.isEmpty() || value.length > 300) {
                            result.error("invalid", "Invalid API key", null)
                        } else {
                            assistantKey.write(value)
                            result.success(null)
                        }
                    }
                    "clear" -> {
                        assistantKey.clear()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("storage", "Could not access protected storage", null)
            }
        }
        val retained = BankNotificationRetention(this)
        notificationMethods = MethodChannel(messenger, "cashew/bank_notifications/settings")
        notificationMethods?.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" -> result.success(BankNotificationRetention.hasAccess(this))
                "configureRetention", "acknowledge" -> {
                    try {
                        if (call.method == "configureRetention") {
                            val packages = call.argument<List<String>>("packages").orEmpty()
                                .filter { it != packageName && it.length <= 255 }
                                .take(20).toSet()
                            val since = call.argument<Number>("since")?.toLong() ?: 0L
                            retained.configure(packages, since)
                        } else {
                            call.arguments?.let { retained.acknowledge(it as String) }
                        }
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("storage", "Could not access notification retention", null)
                    }
                }
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
                if (!BankNotificationRetention.hasAccess(this@MainActivity)) return
                val options = arguments as? Map<*, *> ?: return
                val packages = (options["packages"] as? List<*>)
                    ?.filterIsInstance<String>()?.toSet().orEmpty()
                val from = (options["since"] as? Number)?.toLong() ?: return
                BankNotificationListener.startStream(packages, from, events)
            }

            override fun onCancel(arguments: Any?) = clearBankNotificationStream()
        })
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        clearBankNotificationStream()
        assistantSpeech?.dispose()
        assistantSpeech = null
        assistantKeyMethods?.setMethodCallHandler(null)
        assistantKeyMethods = null
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
        BankNotificationListener.stopStream()
    }

}
