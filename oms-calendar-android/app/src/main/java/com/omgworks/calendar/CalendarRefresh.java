package com.omgworks.calendar;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.net.URL;
import java.net.HttpURLConnection;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;

public final class CalendarRefresh extends JobService {
    private static final String API = "https://rfcozgyvupvachhhblzn.supabase.co/rest/v1/rpc/";
    private static final String PUBLIC_KEY = "sb_publishable_Gy0_TtIcJ6xKDEiGWEnXAg_f4_eyXPI";
    private static final int PERIODIC = 71, IMMEDIATE = 72;
    private static final ExecutorService NETWORK = Executors.newSingleThreadExecutor();

    static SharedPreferences preferences(Context c) { return c.getSharedPreferences("calendar", MODE_PRIVATE); }

    static synchronized void bind(Context c, String token, String role, String id, String property, String zone) {
        if (!"owner".equals(role) && !"staff".equals(role)) return;
        SharedPreferences prefs = preferences(c);
        if (!token.equals(prefs.getString("token", ""))) {
            prefs.edit().remove(WidgetTasks.PENDING).putString(WidgetTasks.EPOCH, java.util.UUID.randomUUID().toString()).remove("events_widget").remove("events_month").remove("widget_events").remove("widget_tasks").remove("tasks_widget").remove("events_last").remove("tasks_last").apply();
            CalendarWidgets.refresh(c, false);
            CalendarWidgets.refresh(c, true);
        }
        prefs.edit().putString("token", token).putString("role", role).putString("id", id)
                .putString("property", property).putString("zone", zone).apply();
        schedule(c, true);
    }

    static synchronized void clear(Context c) {
        preferences(c).edit().remove(WidgetTasks.PENDING).remove(WidgetTasks.EPOCH).remove("token").remove("events_widget").remove("events_month").remove("widget_events").remove("widget_tasks").remove("tasks_widget")
                .remove("events_last").remove("tasks_last").apply();
        c.getSystemService(JobScheduler.class).cancelAll();
        c.getSystemService(NotificationManager.class).cancelAll();
        CalendarWidgets.refresh(c, false);
        CalendarWidgets.refresh(c, true);
    }

    static void schedule(Context c, boolean immediate) {
        if (!preferences(c).contains("token")) return;
        JobScheduler jobs = c.getSystemService(JobScheduler.class);
        ComponentName service = new ComponentName(c, CalendarRefresh.class);
        try {
            if (jobs.getPendingJob(PERIODIC) == null) jobs.schedule(new JobInfo.Builder(PERIODIC, service)
                    .setPeriodic(15 * 60 * 1000L).setPersisted(true).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).build());
            if (immediate && jobs.getPendingJob(IMMEDIATE) == null) jobs.schedule(new JobInfo.Builder(IMMEDIATE, service)
                    .setMinimumLatency(0).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).build());
        } catch (SecurityException | IllegalStateException unavailable) {
            // A background refresh failure must not close the signed-in calendar.
            android.util.Log.w("OMSCalendar", "Background calendar refresh could not be scheduled", unavailable);
        }
    }

    static void scheduleCompletion(Context c) {
        if (!preferences(c).contains("token")) return;
        try { c.getSystemService(JobScheduler.class).schedule(new JobInfo.Builder(73, new ComponentName(c, CalendarRefresh.class))
                .setMinimumLatency(0).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPersisted(true).build()); }
        catch (SecurityException | IllegalStateException ignored) { schedule(c, true); }
    }

    @Override public boolean onStartJob(JobParameters params) {
        NETWORK.execute(() -> {
            try { WidgetTasks.process(this, this::rpc); refresh(); }
            catch (Exception ignored) { /* Keep the last successful read during transient network failures. */ }
            finally {
                synchronized (CalendarRefresh.class) {
                    jobFinished(params, false);
                    if (!WidgetTasks.pending(preferences(this)).isEmpty()) scheduleCompletion(this);
                }
            }
        });
        return true;
    }
    @Override public boolean onStopJob(JobParameters params) { return true; }

    private JSONObject rpc(String name, JSONObject data) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(API + name).openConnection();
        try {
            connection.setConnectTimeout(10000);
            connection.setReadTimeout(10000);
            connection.setRequestMethod("POST");
            connection.setRequestProperty("apikey", PUBLIC_KEY);
            connection.setRequestProperty("Content-Type", "application/json");
            connection.setDoOutput(true);
            try (java.io.OutputStream stream = connection.getOutputStream()) {
                stream.write(data.toString().getBytes(StandardCharsets.UTF_8));
            }
            try (InputStream stream = connection.getInputStream(); ByteArrayOutputStream body = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[4096];
                int count;
                while ((count = stream.read(buffer)) != -1) body.write(buffer, 0, count);
                return new JSONObject(body.toString("UTF-8"));
            }
        } finally { connection.disconnect(); }
    }

    private void refresh() throws Exception {
        SharedPreferences prefs = preferences(this);
        String token = prefs.getString("token", "");
        if (token.isEmpty()) return;
        JSONObject session = rpc("get_app_session", new JSONObject().put("p_access_token", token));
        if (!session.optBoolean("ok")) {
            synchronized (CalendarRefresh.class) {
                if (token.equals(prefs.getString("token", ""))) clear(this);
            }
            return;
        }
        ZoneId zone = ZoneId.of(prefs.getString("zone", "Asia/Seoul"));
        ZonedDateTime now = ZonedDateTime.now(zone);
        LocalDate today = now.toLocalDate();
        LocalDate rangeFirst = today.withDayOfMonth(1), rangeLast = rangeFirst;
        for (java.util.Map.Entry<String, ?> pref : prefs.getAll().entrySet()) {
            if (!pref.getKey().startsWith("widget_month_")) continue;
            try { LocalDate month = LocalDate.parse(String.valueOf(pref.getValue()));
                if (month.isBefore(today.minusYears(1)) || month.isAfter(today.plusYears(1))) continue;
                if (month.isBefore(rangeFirst)) rangeFirst = month;
                if (month.isAfter(rangeLast)) rangeLast = month;
            } catch (Exception ignored) {}
        }
        boolean owner = "owner".equals(prefs.getString("role", ""));
        String person = prefs.getString("id", "");
        List<JSONObject> events = new ArrayList<>(), tasks = new ArrayList<>();
        JSONObject items = rpc(owner ? "calendar_private_items_action" : "calendar_event_action",
                owner ? new JSONObject().put("p_access_token", token).put("p_action", "list")
                        : new JSONObject().put("p_access_token", token).put("p_action", "list").put("p_event", new JSONObject()
                        .put("range_start", rangeFirst.minusDays(7).atStartOfDay(zone).toInstant().toString())
                        .put("range_end", rangeLast.plusMonths(1).plusDays(14).atStartOfDay(zone).toInstant().toString())));
        if (!items.optBoolean("ok")) return;
        if (owner) for (JSONObject item : rows(items.optJSONArray("items"))) {
            if ("event".equals(item.optString("kind"))) events.add(item); else tasks.add(item);
        }
        else {
            events.addAll(rows(items.optJSONArray("events")));
            JSONObject mission = rpc("list_missions", new JSONObject().put("p_access_token", token));
            if (!mission.optBoolean("ok")) return;
            tasks.addAll(rows(mission.optJSONArray("missions")));
        }
        Instant start = today.atStartOfDay(zone).toInstant(), end = today.plusDays(1).atStartOfDay(zone).toInstant();
        events.sort(Comparator.comparing(item -> time(item, "start_at", Instant.MAX)));
        tasks.removeIf(item -> !item.optBoolean("active", true) || present(item, "owner_completed_at")
                || present(item, "completed_at") || contains(item.optJSONArray("completion_employee_ids"), person)
                || ("any".equals(item.optString("completion_mode")) && item.optInt("completed_count") > 0));
        tasks.sort(Comparator.<JSONObject>comparingInt(item -> overdue(item, now) ? 0 : 1)
                .thenComparingInt(CalendarRefresh::priority).thenComparing(item -> time(item, "due_at", Instant.MAX)));
        List<JSONObject> todayEvents = new ArrayList<>(events), overdue = new ArrayList<>(tasks);
        todayEvents.removeIf(item -> !time(item, "start_at", Instant.MAX).isBefore(end) || !time(item, "end_at", Instant.MIN).isAfter(start));
        overdue.removeIf(item -> !overdue(item, now));
        synchronized (CalendarRefresh.class) {
            if (!token.equals(prefs.getString("token", ""))) return;
            prefs.edit().putString("widget_events", widgetData(events, false).toString())
                    .putString("widget_tasks", widgetData(tasks, true).toString()).apply();
            CalendarWidgets.refresh(this, false);
            CalendarWidgets.refresh(this, true);
            notifyAt(prefs, "events", "오늘 일정", todayEvents.size(), widgetEvents(todayEvents, zone), now, 540, false);
            notifyAt(prefs, "tasks", "지연 To do", overdue.size(), taskLines(overdue, now, 4), now, 600, true);
        }
    }

    static List<JSONObject> rows(JSONArray values) {
        List<JSONObject> list = new ArrayList<>();
        if (values != null) for (int i = 0; i < values.length(); i++) {
            JSONObject item = values.optJSONObject(i);
            if (item != null) list.add(item);
        }
        return list;
    }
    private static boolean present(JSONObject item, String key) { return item.has(key) && !item.isNull(key); }
    private static boolean contains(JSONArray ids, String id) {
        if (ids != null) for (int i = 0; i < ids.length(); i++) if (id.equals(ids.optString(i))) return true;
        return false;
    }
    static Instant time(JSONObject item, String key, Instant fallback) {
        try { return Instant.parse(item.optString(key)); } catch (Exception ignored) { return fallback; }
    }
    private static boolean overdue(JSONObject item, ZonedDateTime now) {
        return time(item, "due_at", Instant.MAX).isBefore(now.toInstant());
    }
    static int priority(JSONObject item) {
        String value = item.optString("priority");
        return "urgent".equals(value) ? 0 : "important".equals(value) ? 1 : 2;
    }
    private static JSONArray widgetData(List<JSONObject> items, boolean task) throws Exception {
        JSONArray result = new JSONArray();
        for (JSONObject item : items) {
            JSONObject row = new JSONObject().put("title", item.optString("title"));
            if (item.has("id")) row.put("id", item.get("id"));
            for (String field : task ? new String[]{"due_at", "priority", "timing", "photo_required", "private_owner_id"} : new String[]{"start_at", "end_at", "all_day"}) {
                if (item.has(field)) row.put(field, item.get(field));
            }
            result.put(row);
        }
        return result;
    }
    private static String widgetEvents(List<JSONObject> events, ZoneId zone) {
        StringBuilder result = new StringBuilder();
        DateTimeFormatter timed = DateTimeFormatter.ofPattern("M/d HH:mm").withZone(zone);
        DateTimeFormatter allDay = DateTimeFormatter.ofPattern("M/d").withZone(zone);
        for (JSONObject item : events.subList(0, Math.min(events.size(), 4))) {
            if (result.length() > 0) result.append('\n');
            Instant start = time(item, "start_at", Instant.EPOCH);
            result.append(item.optBoolean("all_day") ? allDay.format(start) + " 종일" : timed.format(start))
                    .append("  ").append(item.optString("title"));
        }
        return result.length() == 0 ? "다가오는 일정이 없습니다." : result.toString();
    }
    private static String taskLines(List<JSONObject> tasks, ZonedDateTime now, int max) {
        StringBuilder result = new StringBuilder();
        for (JSONObject item : tasks.subList(0, Math.min(tasks.size(), max))) {
            if (result.length() > 0) result.append('\n');
            result.append(overdue(item, now) ? "지연  " : "□  ").append(item.optString("title"));
        }
        return result.length() == 0 ? "미완료 할 일이 없습니다." : result.toString();
    }
    private void notifyAt(SharedPreferences prefs, String kind, String title, int count, String body,
                          ZonedDateTime now, int defaultTime, boolean tasks) {
        String today = now.toLocalDate().toString();
        if (!prefs.getBoolean(kind + "_enabled", false) || count == 0
                || today.equals(prefs.getString(kind + "_last", ""))
                || now.getHour() * 60 + now.getMinute() < prefs.getInt(kind + "_time", defaultTime)) return;
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (!manager.areNotificationsEnabled()) return;
        manager.createNotificationChannel(new NotificationChannel(kind, title, NotificationManager.IMPORTANCE_DEFAULT));
        PendingIntent target = PendingIntent.getActivity(this, tasks ? 2 : 1,
                new Intent(this, CalendarActivity.class).putExtra("tasks", tasks),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        manager.notify(tasks ? 102 : 101, new Notification.Builder(this, kind)
                .setSmallIcon(R.drawable.calendar_icon).setContentTitle(title + " " + count + "건")
                .setContentText(body.split("\n", 2)[0]).setStyle(new Notification.BigTextStyle().bigText(body))
                .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(target).build());
        prefs.edit().putString(kind + "_last", today).apply();
    }
}
