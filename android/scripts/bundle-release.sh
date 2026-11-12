#!/bin/bash
set -euo pipefail
set +x

cd "$(dirname "$0")/.."
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PARLA_UPLOAD_KEYSTORE="$HOME/.android/parla-upload.jks"
PARLA_UPLOAD_PASSWORD="$(security find-generic-password -s parla-android-upload -w)"
export PARLA_UPLOAD_PASSWORD
test -f "$PARLA_UPLOAD_KEYSTORE"
test -n "$PARLA_UPLOAD_PASSWORD"
exec ./gradlew :app:bundleRelease --no-configuration-cache
