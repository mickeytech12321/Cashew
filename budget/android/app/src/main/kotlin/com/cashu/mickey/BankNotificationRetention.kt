package com.cashu.mickey

import android.app.NotificationManager
import android.app.AlarmManager
import android.app.PendingIntent
import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONException
import javax.crypto.AEADBadTagException
import java.security.MessageDigest
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

internal data class BankNotificationRecord(
    val id: String,
    val packageName: String,
    val postedAt: Long,
    val title: String?,
    val content: String?,
    val receipt: String? = null,
    val signature: String? = null,
) {
    fun event() = mapOf(
        "id" to id,
        "packageName" to packageName,
        "postedAt" to postedAt,
        "title" to title,
        "content" to content,
        "receipt" to receipt,
        "signature" to signature,
    )

    fun retained(): BankNotificationRecord? {
        val text = listOfNotNull(title, content).joinToString(" ").trim()
        if (text.length !in 1..2000 || !currencyHint.containsMatchIn(text) ||
            !numberHint.containsMatchIn(text) || !movementHint.containsMatchIn(text) ||
            credentialHint.containsMatchIn(text)) return null
        val hash = MessageDigest.getInstance("SHA-256")
            .digest(JSONArray(listOf(id, packageName, postedAt, title, content)).toString()
                .toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        return copy(receipt = hash)
    }

    companion object {
        private val currencyHint = Regex(
            """\b(?:EGP|LE|USD|EUR|GBP|SAR|AED|KWD|QAR|BHD|OMR|JOD)\b|جنيه|ج\.?\s*م|دولار|E£|L\.\s*E\.""",
            RegexOption.IGNORE_CASE,
        )
        private val numberHint = Regex("""[0-9٠-٩۰-۹]""")
        private val movementHint = Regex(
            """\b(?:purchase[ds]?|paid|payment of|charged|withdraw(?:al|n)?|debited|sent|received|credited|deposit(?:ed)?|refund(?:ed)?|transfer|cash in|cash out)\b|خصم|شراء|سحب|دفعت|إرسال|ارسال|استلام|استلمت|تم استقبال|إيداع|ايداع|استرداد|إضافة|اضافة|تم شحن|تم تحويل|حولت""",
            RegexOption.IGNORE_CASE,
        )
        private val credentialHint =
            Regex("""\b(?:otp|pin|passcode|password|(?:verification|security|activation|confirmation) code)\b|(?:رمز|كود|رقم)\s+(?:التحقق|التأكيد|التفعيل|الأمان|السري)""",
                RegexOption.IGNORE_CASE)

        fun decode(json: JSONObject) = BankNotificationRecord(
            id = json.getString("id"),
            packageName = json.getString("packageName"),
            postedAt = json.getLong("postedAt"),
            title = if (json.isNull("title")) null else json.getString("title"),
            content = if (json.isNull("content")) null else json.getString("content"),
            receipt = json.getString("receipt"),
            signature = if (json.isNull("signature")) null else json.getString("signature"),
        )
    }
}

// Activity and listener calls are serialized on Android's main thread.
internal class BankNotificationRetention(private val context: Context, private val sms: Boolean = false) {
    private val settings = context.getSharedPreferences(
        if (sms) "bank_sms_retention" else "bank_notification_retention", Context.MODE_PRIVATE,
    )
    private val storage = LocalEncryptedFile(context, if (sms) "bank-sms-queue" else "bank-notification-queue")
    private fun permitted() = if (sms) hasSmsAccess(context) else hasAccess(context)

    fun configure(packages: Set<String>, since: Long) {
        if (!permitted()) {
            revoke()
            return
        }
        val previous = settings.getStringSet("packages", emptySet()).orEmpty()
        val previousSince = settings.getLong("since", 0L)
        if (previous == packages && previousSince == since) return
        revoke()
        if (packages.isNotEmpty()) {
            check(settings.edit().putStringSet("packages", packages).putLong("since", since).commit())
        }
    }

    fun revoke() {
        check(settings.edit().clear().commit())
        storage.clear()
        if (sms) scheduleSmsExpiry(null)
    }

    fun identify(event: BankNotificationRecord): BankNotificationRecord {
        if (event.signature != null ||
            (event.title?.length ?: 0) + (event.content?.length ?: 0) > 2000) return event
        val alias = "cashew.bank-notification-identities"
        val vault = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = vault.getKey(alias, null) as? SecretKey
            ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build())
            }.generateKey()
        val signature = Mac.getInstance("HmacSHA256").apply { init(key) }
            .doFinal(JSONArray(listOf(event.packageName, event.id, event.title, event.content))
                .toString().toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        return event.copy(signature = signature)
    }

    fun enqueue(event: BankNotificationRecord): BankNotificationRecord? {
        val packages = settings.getStringSet("packages", emptySet()).orEmpty()
        if (event.packageName !in packages) return null
        val now = System.currentTimeMillis()
        if (event.postedAt < cutoff(now) || event.postedAt > now) return null
        val retained = event.retained()?.let(::identify) ?: return null
        val rows = read()
        if (rows.any { it.receipt == retained.receipt }) return retained
        save((rows + retained).sortedBy { it.postedAt }.takeLast(MAX_RECORDS))
        return retained
    }

    fun acknowledge(receipt: String) {
        if (receipt.length != 64) return
        val rows = read()
        val remaining = rows.filter { it.receipt != receipt }
        if (remaining.size != rows.size) save(remaining)
    }

    fun read(): List<BankNotificationRecord> {
        if (!permitted()) {
            revoke()
            return emptyList()
        }
        val packages = settings.getStringSet("packages", emptySet()).orEmpty()
        if (packages.isEmpty()) return emptyList()
        val rows = try {
            val json = storage.read() ?: return emptyList()
            val array = JSONArray(json)
            (0 until array.length()).map { BankNotificationRecord.decode(array.getJSONObject(it)) }
        } catch (_: AEADBadTagException) {
            storage.clear()
            return emptyList()
        } catch (_: JSONException) {
            storage.clear()
            return emptyList()
        }
        val now = System.currentTimeMillis()
        val cutoff = cutoff(now)
        val active = rows.filter { it.packageName in packages && it.postedAt in cutoff..now }
        if (active.size != rows.size) save(active)
        return active
    }

    private fun cutoff(now: Long) = maxOf(settings.getLong("since", 0L), now - DAY)

    private fun save(rows: List<BankNotificationRecord>) {
        if (rows.isEmpty()) {
            storage.clear()
        } else {
            val json = JSONArray()
            rows.forEach { json.put(JSONObject(it.event())) }
            storage.write(json.toString())
        }
        if (sms) scheduleSmsExpiry(rows.firstOrNull()?.postedAt?.plus(DAY))
    }

    private fun scheduleSmsExpiry(time: Long?) {
        val alarm = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = PendingIntent.getBroadcast(context, 8317,
            Intent(context, BankSmsExpiryReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        if (time == null) alarm.cancel(intent)
        else alarm.setAndAllowWhileIdle(AlarmManager.RTC, time + 1000, intent)
    }

    companion object {
        private const val DAY = 86_400_000L
        private const val MAX_RECORDS = 100

        fun hasSmsAccess(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED

        fun hasAccess(context: Context): Boolean {
            val component = ComponentName(context, BankNotificationListener::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                return context.getSystemService(NotificationManager::class.java)
                    ?.isNotificationListenerAccessGranted(component) == true
            }
            val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            return enabled.orEmpty().split(':').any { ComponentName.unflattenFromString(it) == component }
        }
    }
}
