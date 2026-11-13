#!/usr/bin/env bash
# Runs integration_test/app_test.dart on the running emulator as an Android
# instrumentation test: Gradle installs the debug app (built with the test as
# its Dart entrypoint) and the androidTest APK, and FlutterTestRunner reports
# every Dart testWidgets result to JUnit, so a failing test fails Gradle.
# No flutter_tools or Dart Development Service connection is involved.
set -euo pipefail

pkg=dev.abdullah.aithra
root="$(cd "$(dirname "$0")/../.." && pwd)"

# The first test walks through onboarding, which shows only on a fresh install.
adb uninstall "$pkg" >/dev/null 2>&1 || true
adb logcat -c

# Flutter draws no frames while the display is asleep, and the tests pump
# frames, so they stall until it wakes. Keep it awake and unlocked.
adb shell svc power stayon true
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard

status=0
# FlutterTestRunner waits without limit for the Dart results, so a Dart side
# that never reports would otherwise hang until the job is killed, with no
# logcat saved.
timeout 20m "$root/android/gradlew" -p "$root/android" app:connectedDebugAndroidTest \
  -Ptarget="$root/integration_test/app_test.dart" "$@" || status=$?

adb logcat -d > test-logcat.txt
adb exec-out screencap -p > test-screen.png
exit "$status"
