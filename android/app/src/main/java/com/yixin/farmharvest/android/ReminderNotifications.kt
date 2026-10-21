package com.yixin.farmharvest.android

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private const val CHANNEL_ID = "farmharvest-reminders"
private const val CHANNEL_NAME = "事项提醒"
private const val ACTION_REMINDER = "com.yixin.farmharvest.android.REMINDER"
private const val ACTION_RECONCILE = "com.yixin.farmharvest.android.RECONCILE"
private const val SCHEDULED_PREFS = "farm-harvest-alarms"
private const val SCHEDULED_KEY = "scheduled-identifiers"

object ReminderScheduler {
    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "事项提醒时间到达前和到达时的通知"
                enableVibration(true)
            },
        )
    }

    fun reschedule(context: Context, records: List<CropRecord>) {
        ensureChannel(context)
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = context.getSharedPreferences(SCHEDULED_PREFS, Context.MODE_PRIVATE)
        val old = prefs.getStringSet(SCHEDULED_KEY, emptySet()).orEmpty().toSet()
        old.forEach { key ->
            pendingIntent(context, key, PendingIntent.FLAG_NO_CREATE)?.let { intent ->
                alarmManager.cancel(intent)
                intent.cancel()
            }
        }

        val now = System.currentTimeMillis()
        val newKeys = mutableSetOf<String>()
        records.forEach { record ->
            val all = record.harvests.sortedBy { it.date }
            val total = all.size
            record.harvests.filterNot { it.harvested }.forEach { cycle ->
                val position = all.indexOfFirst { it.id == cycle.id } + 1
                val suffix = if (total > 1) "（第 $position/$total 次）" else ""
                if (cycle.date > now) {
                    val dueKey = "at|${record.id}|${cycle.id}"
                    schedule(
                        context,
                        alarmManager,
                        dueKey,
                        cycle.date,
                        "${record.name} 时间到了$suffix",
                        "提醒时间 ${formatDateTime(cycle.date)}，快去看看",
                    )
                    newKeys += dueKey
                }
                val preDate = cycle.date - 2 * 60_000L
                if (preDate > now) {
                    val preKey = "pre|${record.id}|${cycle.id}"
                    schedule(
                        context,
                        alarmManager,
                        preKey,
                        preDate,
                        "${record.name} 即将到时间$suffix",
                        "还有 2 分钟 · 提醒时间 ${formatDateTime(cycle.date)}",
                    )
                    newKeys += preKey
                }
            }
        }
        prefs.edit().putStringSet(SCHEDULED_KEY, newKeys).apply()
    }

    private fun schedule(
        context: Context,
        manager: AlarmManager,
        key: String,
        at: Long,
        title: String,
        body: String,
    ) {
        val intent = pendingIntent(
            context,
            key,
            PendingIntent.FLAG_UPDATE_CURRENT,
            title = title,
            body = body,
        ) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && manager.canScheduleExactAlarms()) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
            } else {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
            }
        } catch (_: SecurityException) {
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
        }
    }

    private fun pendingIntent(
        context: Context,
        key: String,
        extraFlags: Int,
        title: String? = null,
        body: String? = null,
    ): PendingIntent? {
        val alarmIntent = Intent(context, ReminderReceiver::class.java)
            .setAction(ACTION_REMINDER)
            .setData(Uri.parse("farmharvest://alarm/${Uri.encode(key)}"))
        if (title != null) alarmIntent.putExtra("title", title)
        if (body != null) alarmIntent.putExtra("body", body)
        val flags = extraFlags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, 0, alarmIntent, flags)
    }

    private fun formatDateTime(timestamp: Long): String =
        SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(timestamp))
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_REMINDER) return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return

        ReminderScheduler.ensureChannel(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        val contentIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(intent.getStringExtra("title") ?: "事项提醒")
            .setContentText(intent.getStringExtra("body") ?: "提醒时间到了，快去看看")
            .setStyle(
                Notification.BigTextStyle().bigText(
                    intent.getStringExtra("body") ?: "提醒时间到了，快去看看",
                ),
            )
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .build()
        manager.notify(intent.dataString?.hashCode() ?: System.currentTimeMillis().toInt(), notification)
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"
        ) return
        ReminderScheduler.reschedule(context, FarmStore.loadRecords(context))
    }
}
