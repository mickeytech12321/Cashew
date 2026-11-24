package com.mickey.cashew

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel

class BankNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(posted: StatusBarNotification) {
        if (posted.packageName !in allowedPackages || posted.packageName == packageName) return
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
        // The Flutter event handler and notification callbacks run on the main thread.
        internal var sink: EventChannel.EventSink? = null
        internal var allowedPackages: Set<String> = emptySet()
    }
}
