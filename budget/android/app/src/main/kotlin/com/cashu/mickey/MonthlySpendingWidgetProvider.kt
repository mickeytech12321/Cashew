package com.cashu.mickey

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MonthlySpendingWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val currentMonth = SimpleDateFormat("yyyy-MM", Locale.ROOT).format(Date())
        val snapshot = runCatching {
            JSONObject(widgetData.getString("monthlySpendingSnapshot", null) ?: "{}")
        }.getOrNull()
        val amount = if (snapshot?.optString("month") == currentMonth) {
            snapshot.optString("amount", "—")
        } else "—"
        val views = RemoteViews(context.packageName, R.layout.net_worth_widget_layout).apply {
            setTextViewText(R.id.net_worth_title, context.getString(R.string.monthly_spending_widget))
            setTextViewText(R.id.net_worth_amount, amount)
            setViewVisibility(R.id.net_worth_transactions_number, View.GONE)
            val launch = HomeWidgetLaunchIntent.getActivity(
                context, MainActivity::class.java, Uri.parse("monthlySpendingWidget"),
            )
            setOnClickPendingIntent(R.id.widget_container, launch)
        }
        appWidgetManager.updateAppWidget(appWidgetIds, views)
    }
}
