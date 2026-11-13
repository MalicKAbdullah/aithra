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

status=0
"$root/android/gradlew" -p "$root/android" app:connectedDebugAndroidTest \
  -Ptarget="$root/integration_test/app_test.dart" "$@" || status=$?

adb logcat -d > test-logcat.txt
adb exec-out screencap -p > test-screen.png
exit "$status"
