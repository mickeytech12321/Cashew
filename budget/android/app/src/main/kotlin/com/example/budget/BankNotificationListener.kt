package com.mickey.cashew

import android.app.Notification
import android.database.ContentObserver
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel

class BankNotificationListener : NotificationListenerService() {
    private val retained by lazy { BankNotificationRetention(this) }
    private val permissionObserver = object : ContentObserver(main) {
        override fun onChange(selfChange: Boolean) {
            if (!BankNotificationRetention.hasAccess(this@BankNotificationListener)) {
                runCatching { retained.revoke() }
            }
        }
    }
    private val expireOldRecords = object : Runnable {
        override fun run() {
            runCatching { retained.read() }
            main.postDelayed(this, 3_600_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        contentResolver.registerContentObserver(
            Settings.Secure.getUriFor("enabled_notification_listeners"), false, permissionObserver,
        )
        main.post(expireOldRecords)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        main.post {
            connected = this
            replayRetained()
            replayActive()
        }
    }

    override fun onListenerDisconnected() {
        main.post {
            if (connected === this) connected = null
            if (!BankNotificationRetention.hasAccess(this)) runCatching { retained.revoke() }
        }
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        if (connected === this) connected = null
        contentResolver.unregisterContentObserver(permissionObserver)
        main.removeCallbacks(expireOldRecords)
        if (!BankNotificationRetention.hasAccess(this)) runCatching { retained.revoke() }
        super.onDestroy()
    }

    private fun replayRetained() {
        val target = sink ?: return
        runCatching { retained.read() }.getOrNull().orEmpty()
            .filter { it.packageName in allowedPackages && it.postedAt >= since }
            .forEach { event ->
                target.success(runCatching { retained.identify(event) }.getOrDefault(event).event())
            }
    }

    private fun replayActive() {
        if (sink == null || allowedPackages.isEmpty()) return
        val active = try {
            activeNotifications.orEmpty()
        } catch (_: SecurityException) {
            return
        }
        active.asSequence()
            .filter { it.packageName in allowedPackages &&
                it.postTime >= maxOf(since, System.currentTimeMillis() - 86_400_000L) &&
                it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
            .sortedByDescending { it.postTime }
            .take(100)
            .toList()
            .asReversed()
            .forEach { send(it, retain = false) }
    }

    override fun onNotificationPosted(posted: StatusBarNotification) {
        main.post { if (connected === this) send(posted, retain = true) }
    }

    private fun send(posted: StatusBarNotification, retain: Boolean) {
        if (posted.packageName == packageName ||
            !BankNotificationRetention.hasAccess(this)) return
        val notification = posted.notification
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras ?: return
        val content = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)
        val event = BankNotificationRecord(
            id = posted.key,
            packageName = posted.packageName,
            postedAt = posted.postTime,
            title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            content = content?.toString(),
        )
        val saved = if (retain) runCatching { retained.enqueue(event) }.getOrNull() else null
        if (posted.packageName in allowedPackages && posted.postTime >= since) {
            val delivery = saved ?: runCatching { retained.identify(event) }.getOrDefault(event)
            sink?.success(delivery.event())
        }
    }

    companion object {
        // Listener callbacks can arrive off the main thread on older Android versions.
        private val main = Handler(Looper.getMainLooper())
        private var connected: BankNotificationListener? = null
        private var sink: EventChannel.EventSink? = null
        private var allowedPackages: Set<String> = emptySet()
        private var since = Long.MAX_VALUE

        internal fun startStream(packages: Set<String>, from: Long, events: EventChannel.EventSink) {
            allowedPackages = packages
            since = from
            sink = events
            connected?.replayRetained()
            connected?.replayActive()
        }

        internal fun stopStream() {
            sink = null
            allowedPackages = emptySet()
            since = Long.MAX_VALUE
        }
    }
}
