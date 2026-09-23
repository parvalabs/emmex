#!/bin/zsh
# Wrap the SwiftPM-built MlexApp binary into Mlex.app (ad-hoc signed) so it runs as a real Mac app.
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=${1:-debug}
# Real signing (needed for Private Cloud Compute): set MLEX_SIGN_IDENTITY to a "Apple Development: …"
# identity from `security find-identity -v -p codesigning` and MLEX_PROFILE to a .provisionprofile
# whose entitlements include com.apple.developer.private-cloud-compute. Otherwise the app is ad-hoc signed.
IDENTITY=${MLEX_SIGN_IDENTITY:-}
PROFILE=${MLEX_PROFILE:-}
swift build -c "$CONF" --product MlexApp
APP=.build/Mlex.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONF/MlexApp" "$APP/Contents/MacOS/Mlex"
# SwiftPM resource bundles go in Contents/Resources, where Bundle.main.resourceURL points.
for b in .build/$CONF/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# mlx finds default.metallib through the SwiftPM bundle in Resources. Do not put a loose
# metallib in Contents/MacOS: codesign treats it as unsigned nested code and refuses.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mlex</string>
  <key>CFBundleDisplayName</key><string>mlex</string>
  <key>CFBundleIdentifier</key><string>com.gonzalovallejos.mlex</string>
  <key>CFBundleExecutable</key><string>Mlex</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Gonzalo Vallejos</string>
</dict></plist>
PLIST
if [ -n "$IDENTITY" ]; then
  ENT=scripts/Mlex.entitlements
  if [ -n "$PROFILE" ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    # Entitlements must match the profile: derive them from it (application-identifier, team, PCC…).
    ENT=.build/Mlex.entitlements
    security cms -D -i "$PROFILE" | python3 -c "
import sys, plistlib
d = plistlib.loads(sys.stdin.buffer.read())['Entitlements']
ents = {k: v for k, v in d.items() if k in ('com.apple.application-identifier', 'com.apple.developer.team-identifier', 'com.apple.developer.private-cloud-compute', 'keychain-access-groups')}
ents['com.apple.security.get-task-allow'] = True
open('$ENT', 'wb').write(plistlib.dumps(ents))"
  fi
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" --entitlements "$ENT" "$APP"
  codesign -dvv --entitlements - "$APP" 2>&1 | grep -E "Authority=|private-cloud-compute" | head -3
else
  codesign --force --sign - --entitlements scripts/Mlex.entitlements "$APP" >/dev/null
fi
echo "built $APP"
