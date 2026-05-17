#!/usr/bin/env bash
#
# Apply the iOS + Android URL-scheme declarations the OIDC mobile
# sign-in flow needs. Idempotent — re-running is a no-op when the
# scheme is already declared.
#
# When to run:
#   - First time after `flutter create . --platforms=ios,android` in
#     a fresh clone (the `ios/` + `android/` directories are
#     gitignored — see client/.gitignore).
#   - Any time `flutter create` regenerates the native scaffolding
#     and wipes prior local edits.
#
# Why this is a script rather than committed files: per
# `.gitignore`, the entire `ios/` / `android/` trees are regenerated
# locally. We can't ship configured Info.plist / AndroidManifest.xml
# files. The script does the patches as marker-bracketed inserts so
# `flutter create`'s churn doesn't fight us.
#
# What gets patched:
#   1. ios/Runner/Info.plist  — adds a CFBundleURLTypes entry
#      declaring the `fulfilled` scheme so iOS routes
#      `fulfilled://*` URLs back to the app.
#   2. android/app/src/main/AndroidManifest.xml — adds the
#      `com.linusu.flutter_web_auth_2.CallbackActivity` activity
#      with an intent-filter on the `fulfilled` scheme so Android
#      routes `fulfilled://*` URLs through Chrome Custom Tab back
#      to the running auth session.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="fulfilled"

cd "$CLIENT_DIR"

# ─── iOS ──────────────────────────────────────────────────────────
INFO_PLIST="ios/Runner/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "skipping iOS — $INFO_PLIST not present (run 'flutter create . --platforms=ios' first)"
else
  if grep -q "<string>$SCHEME</string>" "$INFO_PLIST"; then
    echo "iOS — already declares CFBundleURLSchemes=$SCHEME (skipping)"
  else
    # Insert a CFBundleURLTypes block just before the closing
    # `</dict>` of the top-level plist dict. The Info.plist's
    # outermost structure is always `<plist><dict>…</dict></plist>`
    # so the last `</dict>` before `</plist>` is the target.
    awk -v scheme="$SCHEME" '
      /<\/dict>[[:space:]]*$/ && !done && getline_next != 0 {
        print "\t<key>CFBundleURLTypes</key>"
        print "\t<array>"
        print "\t\t<dict>"
        print "\t\t\t<key>CFBundleURLSchemes</key>"
        print "\t\t\t<array>"
        print "\t\t\t\t<string>" scheme "</string>"
        print "\t\t\t</array>"
        print "\t\t</dict>"
        print "\t</array>"
        done = 1
      }
      { print }
    ' "$INFO_PLIST" > "$INFO_PLIST.new"
    mv "$INFO_PLIST.new" "$INFO_PLIST"
    echo "iOS — added CFBundleURLSchemes=$SCHEME to $INFO_PLIST"
  fi
fi

# ─── Android ──────────────────────────────────────────────────────
ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"
if [[ ! -f "$ANDROID_MANIFEST" ]]; then
  echo "skipping Android — $ANDROID_MANIFEST not present (run 'flutter create . --platforms=android' first)"
else
  if grep -q 'flutter_web_auth_2.CallbackActivity' "$ANDROID_MANIFEST"; then
    echo "Android — already declares flutter_web_auth_2 CallbackActivity (skipping)"
  else
    # Insert the CallbackActivity inside the <application> block,
    # right before its closing tag. Using a temp marker so the
    # heredoc indentation is predictable.
    python3 - "$ANDROID_MANIFEST" "$SCHEME" <<'PY'
import sys
path, scheme = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    src = f.read()
activity_block = f'''
        <activity
            android:name="com.linusu.flutter_web_auth_2.CallbackActivity"
            android:exported="true">
            <intent-filter android:label="flutter_web_auth_2">
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="{scheme}" />
            </intent-filter>
        </activity>
'''
needle = '</application>'
if needle not in src:
    print("ERR: couldn't find </application> in", path, file=sys.stderr)
    sys.exit(1)
out = src.replace(needle, activity_block + '    ' + needle, 1)
with open(path, 'w') as f:
    f.write(out)
PY
    echo "Android — added flutter_web_auth_2 CallbackActivity to $ANDROID_MANIFEST"
  fi
fi

echo "done"
