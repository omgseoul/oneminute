package com.oneminute.guesthousemanager;

import android.Manifest;
import android.app.NotificationManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;

public class MainActivity extends AppCompatActivity {
    private static final int NOTIFICATION_PERMISSION_REQUEST = 10;
    private static final int FULL_SCREEN_PERMISSION_REQUEST = 11;
    private static final int OVERLAY_PERMISSION_REQUEST = 12;
    private boolean openedWebApp;
    private boolean fullScreenPromptedThisLaunch;
    private boolean overlayPromptedThisLaunch;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (Build.VERSION.SDK_INT >= 33 && ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_PERMISSION_REQUEST);
            return;
        }
        continueStartup();
    }

    private void continueStartup() {
        if (Build.VERSION.SDK_INT >= 34) {
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null && !manager.canUseFullScreenIntent()
                    && !fullScreenPromptedThisLaunch) {
                fullScreenPromptedThisLaunch = true;
                Intent settings = new Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                        Uri.parse("package:" + getPackageName()));
                try {
                    startActivityForResult(settings, FULL_SCREEN_PERMISSION_REQUEST);
                    return;
                } catch (Exception ignored) {
                    // Some vendor Android builds omit this settings screen.
                }
            }
        }
        if (!Settings.canDrawOverlays(this) && !overlayPromptedThisLaunch) {
            overlayPromptedThisLaunch = true;
            Intent settings = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName()));
            try {
                startActivityForResult(settings, OVERLAY_PERMISSION_REQUEST);
                return;
            } catch (Exception ignored) {
                // Some vendor Android builds omit this settings screen.
            }
        }
        // Firebase is used only for native push notifications. A fresh install must
        // never block the Supabase employee/owner login behind the old Firebase
        // device account screen.
        openWebApp();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST) continueStartup();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == FULL_SCREEN_PERMISSION_REQUEST
                || requestCode == OVERLAY_PERMISSION_REQUEST) continueStartup();
    }

    private void openWebApp() {
        if (openedWebApp) return;
        openedWebApp = true;
        startActivity(new Intent(this,AttendanceActivity.class));
        finish();
    }
}
