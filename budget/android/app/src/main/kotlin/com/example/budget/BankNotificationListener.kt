package com.mickey.cashew

import android.app.Notification
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel

class BankNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        main.post {
            connected = this
            replayActive()
        }
    }

    override fun onListenerDisconnected() {
        main.post { if (connected === this) connected = null }
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        if (connected === this) connected = null
        super.onDestroy()
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
            .forEach(::send)
    }

    override fun onNotificationPosted(posted: StatusBarNotification) {
        main.post { if (connected === this) send(posted) }
    }

    private fun send(posted: StatusBarNotification) {
        if (posted.packageName !in allowedPackages || posted.packageName == packageName ||
            posted.postTime < since) return
        val target = sink ?: return
        val notification = posted.notification
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras ?: return
        val content = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)
        target.success(mapOf(
            "id" to posted.key,
            "packageName" to posted.packageName,
            "postedAt" to posted.postTime,
            "title" to extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            "content" to content?.toString(),
        ))
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
            connected?.replayActive()
        }

        internal fun stopStream() {
            sink = null
            allowedPackages = emptySet()
            since = Long.MAX_VALUE
        }
    }
}
