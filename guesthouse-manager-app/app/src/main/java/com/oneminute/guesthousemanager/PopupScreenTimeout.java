package com.oneminute.guesthousemanager;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

/** A fixed visible-session budget, never extended by another incoming alert. */
final class PopupScreenTimeout {
    static final long DURATION_MS = 5 * 60_000L;
    private static final String STATE_KEY = "oms_popup_deadline";
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable expire;
    private long deadline;
    private boolean running;
    private final Runnable tick = () -> check(SystemClock.elapsedRealtime());

    PopupScreenTimeout(Runnable expire) { this.expire = expire; }
    void start(Bundle state) {
        if (running) return;
        long now = SystemClock.elapsedRealtime();
        deadline = state == null ? now + DURATION_MS : state.getLong(STATE_KEY, now + DURATION_MS);
        deadline = Math.min(deadline, now + DURATION_MS);
        running = true;
        check(now);
    }
    void resume() { if (running) check(SystemClock.elapsedRealtime()); }
    void save(Bundle state) { state.putLong(STATE_KEY, deadline); }
    void stop() { running = false; handler.removeCallbacks(tick); }
    void check(long now) {
        if (!running) return;
        handler.removeCallbacks(tick);
        if (now >= deadline) { stop(); expire.run(); }
        else handler.postDelayed(tick, deadline - now);
    }
}
