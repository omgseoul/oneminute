package com.omgworks.calendar;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Build;
import android.util.SizeF;
import android.content.res.Configuration;
import java.util.LinkedHashMap;
import java.util.Map;
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
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;

public final class CalendarWidgets {
    static final String TASK_ACTION = "com.omgworks.calendar.TASK_WIDGET_ACTION";
    private static final String CHANGE_MONTH = "com.omgworks.calendar.CHANGE_WIDGET_MONTH";
    private static final String[] WEEK = {"일", "월", "화", "수", "목", "금", "토"};
    private CalendarWidgets() {}

    public static class Events extends AppWidgetProvider {
        @Override public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
            refresh(context, false);
            CalendarRefresh.schedule(context, true);
        }
        @Override public void onAppWidgetOptionsChanged(Context context, AppWidgetManager manager, int id, Bundle options) {
            render(context, manager, id, false);
        }
        @Override public void onReceive(Context context, Intent intent) {
            super.onReceive(context, intent);
            if (CHANGE_MONTH.equals(intent.getAction())) {
                int widget = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1);
                if (widget < 0) return;
                SharedPreferences prefs = CalendarRefresh.preferences(context);
                LocalDate today = LocalDate.now(ZoneId.of(prefs.getString("zone", "Asia/Seoul"))).withDayOfMonth(1);
                LocalDate month;
                try { month = LocalDate.parse(prefs.getString("widget_month_" + widget, today.toString())); }
                catch (Exception ignored) { month = today; }
                month = month.plusMonths(intent.getIntExtra("direction", 0));
                if (month.isBefore(today.minusMonths(11)) || month.isAfter(today.plusMonths(11))) return;
                prefs.edit().putString("widget_month_" + widget, month.toString())
                        .putString("widget_day_" + widget, month.equals(today) ? LocalDate.now(ZoneId.of(prefs.getString("zone", "Asia/Seoul"))).toString() : month.toString()).apply();
                render(context, AppWidgetManager.getInstance(context), widget, false);
                CalendarRefresh.schedule(context, true);
                return;
            }

        }
        @Override public void onDeleted(Context context, int[] ids) {
            SharedPreferences.Editor prefs = CalendarRefresh.preferences(context).edit();
            for (int id : ids) prefs.remove("widget_day_" + id).remove("widget_month_" + id);
            prefs.apply();
        }
    }

    public static final class Fortnight extends Events {}

    public static final class Tasks extends AppWidgetProvider {
        @Override public void onReceive(Context context, Intent intent) {
            super.onReceive(context, intent);
            if (!TASK_ACTION.equals(intent.getAction())) return;
            String id = intent.getStringExtra("task_id"), epoch = intent.getStringExtra("session_epoch");
            if (!WidgetTasks.current(context, epoch)) return;
            JSONObject item = WidgetTasks.find(CalendarRefresh.preferences(context), id);
            if (item == null) return;
            if ("complete".equals(intent.getStringExtra("operation")) && !item.optBoolean("photo_required")) {
                WidgetTasks.enqueue(context, id, epoch);
            } else {
                context.startActivity(CalendarActivity.taskIntent(context, id, false));
                if ("complete".equals(intent.getStringExtra("operation")))
                    WidgetTasks.toast(context, "완료 사진이 필요한 항목입니다. 상세 화면에서 완료해주세요.");
            }
        }
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
        int[] ids = manager.getAppWidgetIds(new ComponentName(context, tasks ? Tasks.class : Events.class));
        for (int id : ids) render(context, manager, id, tasks);
        if (tasks) manager.notifyAppWidgetViewDataChanged(ids, R.id.widget_task_list);
        else for (int id : manager.getAppWidgetIds(new ComponentName(context, Fortnight.class))) render(context, manager, id, false);
    }

    private static RemoteViews layout(Context context, int id) { return new RemoteViews(context.getPackageName(), id); }

    private static List<JSONObject> load(SharedPreferences prefs, String key) {
        try {
            List<JSONObject> unique = new ArrayList<>();
            HashSet<String> seen = new HashSet<>();
            for (JSONObject item : CalendarRefresh.rows(new JSONArray(prefs.getString(key, "[]")))) {
                String id = item.optString("id", "");
                // Same titles can belong to different tasks. Deduplicate only stable IDs.
                if (id.isEmpty() || seen.add(id)) unique.add(item);
            }
            return unique;
        }
        catch (Exception ignored) { return CalendarRefresh.rows(null); }
    }

    private static void render(Context context, AppWidgetManager manager, int id, boolean tasks) {
        SharedPreferences prefs = CalendarRefresh.preferences(context);
        Bundle options = manager.getAppWidgetOptions(id);
        ZoneId zone = ZoneId.of(prefs.getString("zone", "Asia/Seoul"));
        ZonedDateTime now = ZonedDateTime.now(zone);
        if (Build.VERSION.SDK_INT >= 31) {
            ArrayList<SizeF> sizes = options.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES);
            if (sizes != null && !sizes.isEmpty()) {
                Map<SizeF, RemoteViews> layouts = new LinkedHashMap<>();
                for (SizeF size : sizes) {
                    if (size.getWidth() > 0 && size.getHeight() > 0 && layouts.size() < 16)
                        layouts.put(size, buildViews(context, id, tasks, Math.round(size.getHeight()), now));
                }
                if (!layouts.isEmpty()) {
                    manager.updateAppWidget(id, new RemoteViews(layouts));
                    return;
                }
            }
        }
        boolean landscape = context.getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE;
        int height = options.getInt(landscape ? AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
                : AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT,
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, tasks ? 72 : 240));
        manager.updateAppWidget(id, buildViews(context, id, tasks, height, now));
    }

    static RemoteViews buildViews(Context context, int id, boolean tasks, int height, ZonedDateTime now) {
        SharedPreferences prefs = CalendarRefresh.preferences(context);
        ZoneId zone = now.getZone();
        LocalDate today = now.toLocalDate(), selected = today;
        try { selected = LocalDate.parse(prefs.getString("widget_day_" + id, today.toString())); }
        catch (Exception ignored) {}
        LocalDate displayMonth = today.withDayOfMonth(1);
        try { displayMonth = LocalDate.parse(prefs.getString("widget_month_" + id, displayMonth.toString())); }
        catch (Exception ignored) {}
        android.appwidget.AppWidgetProviderInfo info = AppWidgetManager.getInstance(context).getAppWidgetInfo(id);
        boolean fortnight = info != null && Fortnight.class.getName().equals(info.provider.getClassName());
        boolean month = !tasks && !fortnight && height >= 225;
        boolean week = !tasks && !month;
        if (!(month || week) || (week && !sunday(selected).equals(sunday(today)))) selected = today;
        if (month && !selected.withDayOfMonth(1).equals(displayMonth)) selected = displayMonth.equals(today.withDayOfMonth(1)) ? today : displayMonth;

        RemoteViews views = layout(context, R.layout.widget_calendar);
        // Launchers reapply RemoteViews to existing layouts during resize and refresh.
        // Always replace dynamic children, including when switching to an empty state.
        views.removeAllViews(R.id.widget_grid);
        views.removeAllViews(R.id.widget_entries);
        views.setViewVisibility(R.id.widget_grid, !tasks && (month || week) && prefs.contains("token") ? View.VISIBLE : View.GONE);
        views.setViewVisibility(R.id.widget_action, tasks ? View.VISIBLE : View.GONE);
        views.setOnClickPendingIntent(R.id.widget_title, open(context, tasks, false));
        views.setViewVisibility(R.id.widget_previous, month ? View.VISIBLE : View.GONE);
        views.setViewVisibility(R.id.widget_next, month ? View.VISIBLE : View.GONE);
        views.setViewVisibility(R.id.widget_task_list, tasks ? View.VISIBLE : View.GONE);
        views.setViewVisibility(R.id.widget_task_empty, View.GONE);
        views.setViewVisibility(R.id.widget_entries, tasks || prefs.contains("token") ? View.GONE : View.VISIBLE);
        views.setViewVisibility(R.id.widget_count, tasks ? View.VISIBLE : View.GONE);
        views.setViewVisibility(R.id.widget_title, tasks ? View.GONE : View.VISIBLE);
        views.setViewVisibility(R.id.widget_task_heading, tasks ? View.VISIBLE : View.GONE);
        views.setOnClickPendingIntent(R.id.widget_task_heading, open(context, true, false));
        if (month) {
            views.setOnClickPendingIntent(R.id.widget_previous, changeMonth(context, id, -1));
            views.setOnClickPendingIntent(R.id.widget_next, changeMonth(context, id, 1));
        }
        views.setTextViewText(R.id.widget_title, tasks ? "OMS To do"
                : month ? format(displayMonth, "yyyy년 M월")
                : week ? format(sunday(today), "M월 d일") + " – " + format(sunday(today).plusDays(13), "M월 d일")
                : format(today, "M월 d일 EEEE"));

        if (tasks) {
            views.setViewVisibility(R.id.widget_action, View.VISIBLE);
            views.setTextViewText(R.id.widget_action, "+");
            views.setContentDescription(R.id.widget_action, "To do 추가");
            views.setOnClickPendingIntent(R.id.widget_action, open(context, true, true));
        }

        if (tasks) {
            List<JSONObject> list = prefs.contains("token") ? sortedTasks(prefs, now) : new ArrayList<>();
            views.setTextViewText(R.id.widget_count, String.valueOf(list.size()));
            views.setTextViewText(R.id.widget_task_empty, prefs.contains("token") ? "미완료 할 일이 없습니다." : "앱에서 로그인하면 표시됩니다.");
            views.setOnClickPendingIntent(R.id.widget_task_empty, open(context, true, false));
            Intent adapter = new Intent(context, TaskWidgetService.class).setData(android.net.Uri.parse("oms-tasks://widget/" + id));
            views.setRemoteAdapter(R.id.widget_task_list, adapter);
            views.setEmptyView(R.id.widget_task_list, R.id.widget_task_empty);
            Intent action = new Intent(context, Tasks.class).setAction(TASK_ACTION).setData(android.net.Uri.parse("oms-tasks://action/" + id));
            views.setPendingIntentTemplate(R.id.widget_task_list, PendingIntent.getBroadcast(context, id, action,
                    PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0)));
        } else if (!prefs.contains("token")) {
            entry(context, views, "", "앱에서 로그인하면 표시됩니다.", "", "");
        } else {
            List<JSONObject> list = load(prefs, "widget_events");
            grid(context, views, id, list, zone, today, selected, month, displayMonth, height);
        }
        return views;
    }

    static List<JSONObject> sortedTasks(SharedPreferences prefs, ZonedDateTime now) {
        List<JSONObject> list = load(prefs, "widget_tasks");
        java.util.Set<String> pending = WidgetTasks.pending(prefs);
        list.removeIf(item -> pending.contains(item.optString("id")));
        list.sort(Comparator.<JSONObject>comparingInt(item -> due(item).isBefore(now.toInstant()) ? 0 : 1)
                .thenComparingInt(CalendarRefresh::priority).thenComparing(CalendarWidgets::due));
        return list;
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
        Intent intent = tasks ? CalendarActivity.taskIntent(context, "", create) : new Intent(context, CalendarActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        return PendingIntent.getActivity(context, create ? 3 : tasks ? 2 : 1, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static void grid(Context context, RemoteViews views, int id, List<JSONObject> events,
                             ZoneId zone, LocalDate today, LocalDate selected, boolean month, LocalDate displayMonth, int height) {
        RemoteViews labels = layout(context, R.layout.widget_weekday_row);
        labels.removeAllViews(R.id.widget_dates);
        for (int n = 0; n < WEEK.length; n++) {
            RemoteViews label = cell(context, WEEK[n], false, false, false);
            label.setTextColor(R.id.widget_number, dayColor(n));
            labels.addView(R.id.widget_dates, label);
        }
        views.addView(R.id.widget_grid, labels);
        LocalDate first = month ? displayMonth : sunday(today);
        LocalDate end = first.plusDays(weekLength(first, month));
        int rows = (int)((java.time.temporal.ChronoUnit.DAYS.between(sunday(first), end) + 6) / 7);
        int lines = Math.max(0, Math.min(month ? 2 : 6, ((height - 60) / rows - 16) / 12));
        events.sort(Comparator.comparing(e -> CalendarRefresh.time(e, "start_at", Instant.MAX)));
        for (LocalDate start = sunday(first); start.isBefore(end); start = start.plusDays(7)) {
            RemoteViews row = layout(context, R.layout.widget_date_row);
            row.removeAllViews(R.id.widget_dates);
            for (int offset = 0; offset < 7; offset++) {
                LocalDate date = start.plusDays(offset);
                boolean shown = !date.isBefore(first) && date.isBefore(end);
                RemoteViews day = cell(context, shown ? String.valueOf(date.getDayOfMonth()) : "",
                        date.equals(today), date.equals(selected), false);
                if (shown) {
                    if (!date.equals(today)) day.setTextColor(R.id.widget_number, dayColor(offset));
                    day.setContentDescription(R.id.widget_cell, format(date, "M월 d일 EEEE"));
                    PendingIntent target = PendingIntent.getActivity(context, 0,
                            CalendarActivity.dateIntent(context, date), PendingIntent.FLAG_IMMUTABLE);
                    day.setOnClickPendingIntent(R.id.widget_cell, target);
                    int count = 0;
                    for (JSONObject event : events) {
                        if (count >= lines) break;
                        if (!occurs(event, date, zone)) continue;
                        RemoteViews title = layout(context, R.layout.widget_cell_event);
                        title.setTextViewText(R.id.widget_cell_event, event.optString("title"));
                        title.setOnClickPendingIntent(R.id.widget_cell_event, target);
                        day.addView(R.id.widget_cell_events, title);
                        count++;
                    }
                }
                row.addView(R.id.widget_dates, day);
            }
            views.addView(R.id.widget_grid, row);
        }
    }

    private static int dayColor(int day) { return day == 0 ? 0xffD94B55 : day == 6 ? 0xff2563EB : 0xff17243A; }

    private static PendingIntent changeMonth(Context context, int id, int direction) {
        Intent intent = new Intent(context, Events.class).setAction(CHANGE_MONTH)
                .setData(android.net.Uri.parse("oms-month://" + id + "/" + direction))
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id).putExtra("direction", direction);
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static RemoteViews taskRow(Context context, JSONObject item, ZonedDateTime now, String epoch) {
        RemoteViews row = layout(context, R.layout.widget_task_entry);
        String title = item.optString("title"), id = item.optString("id");
        int priority = CalendarRefresh.priority(item);
        row.setTextViewText(R.id.widget_task_title, title);
        row.setViewVisibility(R.id.widget_priority, priority < 2 ? View.VISIBLE : View.GONE);
        row.setTextColor(R.id.widget_priority, priority == 0 ? 0xffD94B55 : 0xffE5A000);
        row.setContentDescription(R.id.widget_priority, priority == 0 ? "긴급" : "중요");
        Instant deadline = due(item);
        boolean late = deadline.isBefore(now.toInstant());
        String when = deadline.equals(Instant.MAX) ? "예정"
                : deadline.atZone(now.getZone()).toLocalDate().equals(now.toLocalDate()) ? "오늘"
                : format(deadline.atZone(now.getZone()).toLocalDate(), "M.dd");
        row.setTextViewText(R.id.widget_task_due, (late ? "지연 · " : "") + when);
        row.setTextColor(R.id.widget_task_due, late ? 0xffD94B55 : deadline.equals(Instant.MAX) ? 0xff758094 : 0xff2563EB);
        Intent open = new Intent().putExtra("operation", "open").putExtra("task_id", id).putExtra("session_epoch", epoch);
        Intent complete = new Intent().putExtra("operation", "complete").putExtra("task_id", id).putExtra("session_epoch", epoch);
        row.setOnClickFillInIntent(R.id.widget_task_open, open);
        row.setOnClickFillInIntent(R.id.widget_complete, complete);
        row.setContentDescription(R.id.widget_task_open, (priority < 2 ? priority == 0 ? "긴급 · " : "중요 · " : "") + title + " 상세 열기");
        row.setContentDescription(R.id.widget_complete, title + " 완료");
        return row;
    }

    private static int weekLength(LocalDate first, boolean month) { return month ? first.lengthOfMonth() : 14; }

    private static RemoteViews cell(Context context, String value, boolean today, boolean selected, boolean dot) {
        RemoteViews cell = layout(context, R.layout.widget_date_cell);
        cell.setTextViewText(R.id.widget_number, value);
        cell.setViewVisibility(R.id.widget_dot, View.GONE);
        cell.setInt(R.id.widget_number, "setBackgroundResource", today ? R.drawable.widget_today : selected ? R.drawable.widget_selected : 0);
        cell.setTextColor(R.id.widget_number, today ? 0xffffffff : 0xff17254b);
        return cell;
    }

    private static void entry(Context context, RemoteViews views, String marker, String title, String status, String when) {
        RemoteViews row = layout(context, R.layout.widget_entry);
        row.setTextViewText(R.id.widget_marker, marker);
        row.setTextViewText(R.id.widget_entry_title, title);
        row.setTextViewText(R.id.widget_status, status);
        row.setTextViewText(R.id.widget_when, when);
        row.setViewVisibility(R.id.widget_status, status.isEmpty() ? View.GONE : View.VISIBLE);
        row.setViewVisibility(R.id.widget_when, when.isEmpty() ? View.GONE : View.VISIBLE);
        if ("지연".equals(status)) row.setTextColor(R.id.widget_status, 0xffa54113);
        views.addView(R.id.widget_entries, row);
    }
}
