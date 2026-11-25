package com.cashu.mickey

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import io.flutter.plugin.common.EventChannel
import java.util.Locale

class BankSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION ||
            !BankNotificationRetention.hasSmsAccess(context)) return
        val parts = runCatching { Telephony.Sms.Intents.getMessagesFromIntent(intent) }
            .getOrNull() ?: return
        val first = parts.firstOrNull() ?: return
        val sender = first.originatingAddress?.trim()?.lowercase(Locale.ROOT) ?: return
        if (!validSender.matches(sender) || parts.any { it.originatingAddress != first.originatingAddress }) return
        val text = parts.joinToString("") { it.messageBody.orEmpty() }
        val now = System.currentTimeMillis()
        val message = BankNotificationRecord(
            id = "$sender:${first.timestampMillis}", packageName = sender,
            postedAt = now, title = null, content = text,
        )
        val retained = runCatching { BankNotificationRetention(context, sms = true).enqueue(message) }
            .getOrNull() ?: return
        sink?.success(retained.event() + ("source" to "sms"))
    }

    companion object {
        internal val validSender = Regex("[a-z0-9+_. -]{1,32}")
        internal var sink: EventChannel.EventSink? = null
    }
}

class BankSmsExpiryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        runCatching { BankNotificationRetention(context, sms = true).read() }
    }
}
