#!/usr/bin/env bash
# Installs an APK on the running emulator, cold-launches it and fails if the
# process died or logged a crash within the first 15 seconds.
set -euo pipefail

apk="$1"
pkg=dev.abdullah.aithra

adb uninstall "$pkg" >/dev/null 2>&1 || true
adb install -r "$apk"
adb logcat -c
adb shell am start -W -n "$pkg/.MainActivity"
sleep 15

adb logcat -d > launch-logcat.txt
adb exec-out screencap -p > launch-screen.png

failed=0
if ! adb shell pidof "$pkg" >/dev/null; then
  echo "::error::$pkg is not running 15 s after launch"
  failed=1
fi
if grep -A2 "FATAL EXCEPTION" launch-logcat.txt | grep -q "Process: $pkg"; then
  echo "::error::$pkg threw a fatal exception"
  failed=1
fi
if grep "Fatal signal" launch-logcat.txt | grep -q "$pkg"; then
  echo "::error::$pkg died from a fatal signal"
  failed=1
fi
if [ "$failed" = 1 ]; then
  grep -E -A30 "FATAL EXCEPTION|Fatal signal" launch-logcat.txt || true
  exit 1
fi
echo "$pkg is running with no crash in logcat"
