package com.omgworks.calendar;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.RemoteViews;
import org.json.JSONArray;
import org.json.JSONObject;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

public final class CalendarWidgets {
    private static final String PICK_DATE = "com.omgworks.calendar.PICK_WIDGET_DATE";
    private static final String[] WEEK = {"일", "월", "화", "수", "목", "금", "토"};
    private CalendarWidgets() {}

    public static final class Events extends AppWidgetProvider {
        @Override public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
            refresh(context, false);
            CalendarRefresh.schedule(context, true);
        }
        @Override public void onAppWidgetOptionsChanged(Context context, AppWidgetManager manager, int id, Bundle options) {
            render(context, manager, id, false);
        }
        @Override public void onReceive(Context context, Intent intent) {
            super.onReceive(context, intent);
            if (!PICK_DATE.equals(intent.getAction())) return;
            int id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1);
            if (id < 0) return;
            CalendarRefresh.preferences(context).edit().putString("widget_day_" + id, intent.getStringExtra("date")).apply();
            render(context, AppWidgetManager.getInstance(context), id, false);
        }
        @Override public void onDeleted(Context context, int[] ids) {
            SharedPreferences.Editor prefs = CalendarRefresh.preferences(context).edit();
            for (int id : ids) prefs.remove("widget_day_" + id);
            prefs.apply();
        }
    }

    public static final class Tasks extends AppWidgetProvider {
        @Override public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
            refresh(context, true);
            CalendarRefresh.schedule(context, true);
        }
        @Override public void onAppWidgetOptionsChanged(Context context, AppWidgetManager manager, int id, Bundle options) {
            render(context, manager, id, true);
        }
    }

    static void refresh(Context context, boolean tasks) {
        AppWidgetManager manager = AppWidgetManager.getInstance(context);
        for (int id : manager.getAppWidgetIds(new ComponentName(context, tasks ? Tasks.class : Events.class))) {
            render(context, manager, id, tasks);
        }
    }

    private static RemoteViews layout(Context context, int id) { return new RemoteViews(context.getPackageName(), id); }

    private static List<JSONObject> load(SharedPreferences prefs, String key) {
        try { return CalendarRefresh.rows(new JSONArray(prefs.getString(key, "[]"))); }
        catch (Exception ignored) { return CalendarRefresh.rows(null); }
    }

    private static void render(Context context, AppWidgetManager manager, int id, boolean tasks) {
        SharedPreferences prefs = CalendarRefresh.preferences(context);
        int height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 120);
        ZoneId zone = ZoneId.of(prefs.getString("zone", "Asia/Seoul"));
        ZonedDateTime now = ZonedDateTime.now(zone);
        LocalDate today = now.toLocalDate(), selected = today;
        try { selected = LocalDate.parse(prefs.getString("widget_day_" + id, today.toString())); }
        catch (Exception ignored) {}
        boolean month = !tasks && height >= 240;
        boolean week = !tasks && height >= 166 && !month;
        if (!(month || week) || (month && selected.getMonth() != today.getMonth())
                || (week && !sunday(selected).equals(sunday(today)))) selected = today;

        RemoteViews views = layout(context, R.layout.widget_calendar);
        views.setOnClickPendingIntent(R.id.widget_panel, open(context, tasks, false));
        views.setTextViewText(R.id.widget_title, tasks ? "OMS To do"
                : month ? format(today, "yyyy년 M월")
                : week ? format(sunday(today), "M월 d일") + " – " + format(sunday(today).plusDays(6), "M월 d일")
                : format(today, "M월 d일 EEEE"));

        if (tasks) {
            views.setViewVisibility(R.id.widget_action, View.VISIBLE);
            views.setTextViewText(R.id.widget_action, "+");
            views.setContentDescription(R.id.widget_action, "To do 추가");
            views.setOnClickPendingIntent(R.id.widget_action, open(context, true, true));
        }

        if (!prefs.contains("token")) {
            entry(context, views, "", "앱에서 로그인하면 표시됩니다.", "", "");
        } else if (tasks) {
            List<JSONObject> list = load(prefs, "widget_tasks");
            list.sort(Comparator.<JSONObject>comparingInt(item -> due(item).isBefore(now.toInstant()) ? 0 : 1)
                    .thenComparingInt(CalendarRefresh::priority).thenComparing(CalendarWidgets::due));
            int limit = Math.max(1, (height - 44) / 25);
            for (JSONObject item : list.subList(0, Math.min(list.size(), limit))) {
                Instant deadline = due(item);
                String date = deadline.equals(Instant.MAX) ? "" : format(deadline.atZone(zone).toLocalDate(), "M월 d일");
                String status = deadline.equals(Instant.MAX) ? "예정" : deadline.isBefore(now.toInstant()) ? "지연"
                        : deadline.atZone(zone).toLocalDate().equals(today) ? "오늘" : CalendarRefresh.priority(item) < 2 ? "중요" : "";
                entry(context, views, "□", item.optString("title"), status, date);
            }
            if (list.isEmpty()) entry(context, views, "", "미완료 할 일이 없습니다.", "", "");
        } else {
            List<JSONObject> list = load(prefs, "widget_events");
            if (month || week) grid(context, views, id, list, zone, today, selected, month);
            int limit = month ? 1 : week ? Math.max(1, (height - 100) / 25) : Math.max(1, (height - 44) / 25);
            int count = 0;
            for (JSONObject item : list) {
                if (!occurs(item, selected, zone)) continue;
                if (count++ >= limit) break;
                String when = item.optBoolean("all_day") ? "종일" : DateTimeFormatter.ofPattern("HH:mm")
                        .withZone(zone).format(CalendarRefresh.time(item, "start_at", Instant.EPOCH));
                entry(context, views, "•", when + "   " + item.optString("title"), "", "");
            }
            if (count == 0) entry(context, views, "", "일정이 없습니다.", "", "");
        }
        manager.updateAppWidget(id, views);
    }

    private static Instant due(JSONObject item) {
        return CalendarRefresh.time(item, "due_at", Instant.MAX);
    }

    private static LocalDate sunday(LocalDate date) { return date.minusDays(date.getDayOfWeek().getValue() % 7); }
    private static String format(LocalDate date, String pattern) { return date.format(DateTimeFormatter.ofPattern(pattern, Locale.KOREAN)); }

    private static boolean occurs(JSONObject item, LocalDate date, ZoneId zone) {
        return CalendarRefresh.time(item, "start_at", Instant.MAX).isBefore(date.plusDays(1).atStartOfDay(zone).toInstant())
                && CalendarRefresh.time(item, "end_at", Instant.MIN).isAfter(date.atStartOfDay(zone).toInstant());
    }

    private static PendingIntent open(Context context, boolean tasks, boolean create) {
        Intent intent = new Intent(context, CalendarActivity.class).putExtra("tasks", tasks).putExtra("create", create);
        return PendingIntent.getActivity(context, create ? 3 : tasks ? 2 : 1, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static void grid(Context context, RemoteViews views, int id, List<JSONObject> events,
                             ZoneId zone, LocalDate today, LocalDate selected, boolean month) {
        RemoteViews labels = layout(context, R.layout.widget_date_row);
        for (String day : WEEK) labels.addView(R.id.widget_dates, cell(context, day, false, false, false));
        views.addView(R.id.widget_grid, labels);
        LocalDate first = month ? today.withDayOfMonth(1) : sunday(today);
        LocalDate end = first.plusDays(weekLength(first, month));
        for (LocalDate start = sunday(first); start.isBefore(end); start = start.plusDays(7)) {
            RemoteViews row = layout(context, R.layout.widget_date_row);
            for (int offset = 0; offset < 7; offset++) {
                LocalDate date = start.plusDays(offset);
                boolean shown = !date.isBefore(first) && date.isBefore(end);
                RemoteViews day = cell(context, shown ? String.valueOf(date.getDayOfMonth()) : "",
                        date.equals(today), date.equals(selected), shown && events.stream().anyMatch(event -> occurs(event, date, zone)));
                if (shown) {
                    Intent pick = new Intent(context, Events.class).setAction(PICK_DATE)
                            .setData(android.net.Uri.parse("oms-widget:" + id + "/" + date))
                            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id).putExtra("date", date.toString());
                    day.setOnClickPendingIntent(R.id.widget_cell, PendingIntent.getBroadcast(context, 0, pick, PendingIntent.FLAG_IMMUTABLE));
                }
                row.addView(R.id.widget_dates, day);
            }
            views.addView(R.id.widget_grid, row);
        }
    }

    private static int weekLength(LocalDate first, boolean month) { return month ? first.lengthOfMonth() : 7; }

    private static RemoteViews cell(Context context, String value, boolean today, boolean selected, boolean dot) {
        RemoteViews cell = layout(context, R.layout.widget_date_cell);
        cell.setTextViewText(R.id.widget_number, value);
        cell.setTextViewText(R.id.widget_dot, dot ? "●" : "");
        if (today || selected) cell.setInt(R.id.widget_number, "setBackgroundResource", today ? R.drawable.widget_today : R.drawable.widget_selected);
        if (today) cell.setTextColor(R.id.widget_number, 0xffffffff);
        return cell;
    }

    private static void entry(Context context, RemoteViews views, String marker, String title, String status, String when) {
        RemoteViews row = layout(context, R.layout.widget_entry);
        row.setTextViewText(R.id.widget_marker, marker);
        row.setTextViewText(R.id.widget_entry_title, title);
        row.setTextViewText(R.id.widget_status, status);
        row.setTextViewText(R.id.widget_when, when);
        if ("지연".equals(status)) row.setTextColor(R.id.widget_status, 0xffa54113);
        views.addView(R.id.widget_entries, row);
    }
}
