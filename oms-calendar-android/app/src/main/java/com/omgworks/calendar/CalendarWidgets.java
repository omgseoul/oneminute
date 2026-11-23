package com.omgworks.calendar;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.widget.RemoteViews;

public final class CalendarWidgets {
    private CalendarWidgets() {}

    public static final class Events extends AppWidgetProvider {
        @Override public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
            refresh(context, false);
            CalendarRefresh.schedule(context, true);
        }
    }

    public static final class Tasks extends AppWidgetProvider {
        @Override public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
            refresh(context, true);
            CalendarRefresh.schedule(context, true);
        }
    }

    static void refresh(Context context, boolean tasks) {
        String kind = tasks ? "tasks" : "events";
        RemoteViews views = new RemoteViews(context.getPackageName(), tasks ? R.layout.widget : R.layout.widget_calendar);
        views.setTextViewText(R.id.widget_title, tasks ? "OMS To do" : "OMS 캘린더");
        String summary = CalendarRefresh.preferences(context).getString(kind + "_widget", "앱에서 로그인하면 표시됩니다.");
        views.setTextViewText(R.id.widget_rows, tasks ? summary : summary.split("\n", 2)[0]);
        if (!tasks) views.setTextViewText(R.id.widget_month,
                CalendarRefresh.preferences(context).getString("events_month", ""));
        Intent open = new Intent(context, CalendarActivity.class).putExtra("tasks", tasks);
        views.setOnClickPendingIntent(R.id.widget_panel, PendingIntent.getActivity(context, tasks ? 2 : 1, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        AppWidgetManager.getInstance(context).updateAppWidget(new ComponentName(context, tasks ? Tasks.class : Events.class), views);
    }
}
