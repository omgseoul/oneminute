#!/usr/bin/env bash
set -euo pipefail

# Each emulator-runner script line has its own shell. Keep discovery, listener
# permission and execution together, and choose a real launcher instead of FallbackHome.
adb shell settings put global device_provisioned 1
adb shell settings put secure user_setup_complete 1
adb shell settings put secure notification_badging 1
adb shell pm grant com.oneminute.guesthousemanager android.permission.POST_NOTIFICATIONS
adb shell cmd package query-activities --brief --components -a android.intent.action.MAIN -c android.intent.category.HOME
launcher_component=$(adb shell cmd package query-activities --brief --components -a android.intent.action.MAIN -c android.intent.category.HOME | tr -d '\r' | grep -E '^com\.(android\.launcher3|google\.android\.apps\.nexuslauncher)/' | head -1)
test -n "$launcher_component"
launcher_package=${launcher_component%%/*}
adb shell cmd package set-home-activity "$launcher_component"
listener_component=$(adb shell cmd package query-services --brief --components -a android.service.notification.NotificationListenerService -p "$launcher_package" | tr -d '\r' | grep 'NotificationListener' | head -1)
test -n "$listener_component"
printf 'Launcher: %s; notification listener: %s\n' "$launcher_component" "$listener_component"
adb shell cmd notification allow_listener "$listener_component"
adb shell am start -W -n "$launcher_component"
adb shell am instrument -w -e phase badge com.oneminute.guesthousemanager.test/com.oneminute.guesthousemanager.UpdateProbe | tee "$RUNNER_TEMP/oms-badge.txt"

# Retain diagnostics even when the launcher assertion fails.
for state in before after cleared failed; do
    target="$RUNNER_TEMP/oms-native-launcher-$state.png"
    if ! adb exec-out run-as com.oneminute.guesthousemanager cat "files/launcher-badge-$state.png" > "$target"; then
        rm -f "$target"
    fi
done
grep -q 'oms_badge=ok' "$RUNNER_TEMP/oms-badge.txt"
