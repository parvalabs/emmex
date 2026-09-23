#!/bin/zsh
# Wrap the SwiftPM-built MlexApp binary into Mlex.app (ad-hoc signed) so it runs as a real Mac app.
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=${1:-debug}
swift build -c "$CONF" --product MlexApp
APP=.build/Mlex.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONF/MlexApp" "$APP/Contents/MacOS/Mlex"
# SwiftPM resource bundles go in Contents/Resources, where Bundle.main.resourceURL points.
for b in .build/$CONF/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# mlx looks for a colocated mlx.metallib next to the binary first; give it one.
ML=.build/$CONF/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
[ -e "$ML" ] && cp "$ML" "$APP/Contents/MacOS/mlx.metallib"
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
codesign --force --sign - --entitlements scripts/Mlex.entitlements "$APP" >/dev/null
echo "built $APP"
