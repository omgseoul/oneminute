package com.omgworks.calendar;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.widget.Toast;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Persist completion work before hiding a row; a stopped job can safely resume it. */
final class WidgetTasks {
    static final String PENDING = "widget_pending_completions", EPOCH = "widget_session_epoch";
    private WidgetTasks() {}
    static synchronized String epoch(Context context) {
        SharedPreferences p = CalendarRefresh.preferences(context);
        String value = p.getString(EPOCH, "");
        if (value.isEmpty() && p.contains("token")) {
            value = UUID.randomUUID().toString(); p.edit().putString(EPOCH, value).commit();
        }
        return value;
    }
    static Set<String> pending(SharedPreferences p) { return new HashSet<>(p.getStringSet(PENDING, new HashSet<>())); }
    static JSONObject find(SharedPreferences p, String id) {
        if (id == null || !id.matches("[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")) return null;
        try { for (JSONObject row : CalendarRefresh.rows(new JSONArray(p.getString("widget_tasks", "[]"))))
            if (id.equals(row.optString("id"))) return row;
        } catch (Exception ignored) {}
        return null;
    }
    static boolean current(Context c, String epoch) {
        SharedPreferences p = CalendarRefresh.preferences(c);
        return p.contains("token") && epoch != null && !epoch.isEmpty() && epoch.equals(p.getString(EPOCH, ""));
    }
    static boolean enqueue(Context c, String id, String epoch) {
        synchronized (CalendarRefresh.class) {
            SharedPreferences p = CalendarRefresh.preferences(c);
            JSONObject item = find(p, id);
            if (!current(c, epoch) || item == null || item.optBoolean("photo_required")) return false;
            Set<String> pending = pending(p);
            if (!pending.add(id)) return false;
            if (!p.edit().putStringSet(PENDING, pending).commit()) return false;
        }
        CalendarWidgets.refresh(c, true);
        CalendarRefresh.scheduleCompletion(c);
        return true;
    }
    interface Caller { JSONObject call(String name, JSONObject body) throws Exception; }
    static void process(Context c, Caller caller) throws Exception {
        SharedPreferences p = CalendarRefresh.preferences(c);
        String token = p.getString("token", ""), epoch = epoch(c);
        for (String id : pending(p)) {
            if (!current(c, epoch)) return;
            JSONObject item = find(p, id);
            boolean success = false;
            try {
                if (item == null || item.optBoolean("photo_required")) throw new IllegalStateException();
                boolean owner = "owner".equals(p.getString("role", ""));
                JSONObject body = new JSONObject().put("p_access_token", token);
                String name;
                if (owner) {
                    name = "calendar_private_items_action";
                    body.put("p_action", "complete").put("p_item", new JSONObject().put("id", id)
                            .put("note", "위젯에서 완료했습니다.").put("photo", ""));
                } else {
                    name = "complete_mission";
                    body.put("p_mission_id", id).put("p_note", "위젯에서 완료했습니다.").put("p_photo_data_url", "");
                }
                JSONObject result = caller.call(name, body);
                success = result.optBoolean("ok") || "already_completed".equals(result.optString("code"));
            } catch (Exception ignored) { /* Roll back the optimistic hide on failure. */ }
            synchronized (CalendarRefresh.class) {
                if (!current(c, epoch)) return;
                Set<String> pending = pending(p); pending.remove(id);
                SharedPreferences.Editor edit = p.edit().putStringSet(PENDING, pending);
                if (success) {
                    JSONArray remaining = new JSONArray();
                    for (JSONObject row : CalendarRefresh.rows(new JSONArray(p.getString("widget_tasks", "[]"))))
                        if (!id.equals(row.optString("id"))) remaining.put(row);
                    edit.putString("widget_tasks", remaining.toString());
                }
                edit.commit();
                CalendarWidgets.refresh(c, true);
            }
            if (!success) toast(c, "완료 처리에 실패해 항목을 다시 표시했습니다. 다시 눌러주세요.");
        }
    }
    static void toast(Context c, String text) {
        new Handler(Looper.getMainLooper()).post(() -> Toast.makeText(c, text, Toast.LENGTH_LONG).show());
    }
}
