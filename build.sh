#!/bin/bash
# Builds TrackpadTyping.app.
#
# A real bundle (rather than a bare executable) is required for two reasons:
# Accessibility permission is granted per bundle identifier, and LSUIElement is
# what keeps this out of the Dock and the app switcher.
set -euo pipefail
cd "$(dirname "$0")"

APP="TrackpadTyping.app"
BUNDLE_ID="com.local.trackpadtyping"

echo "==> Compiling"
swift build -c release

BIN=".build/release/TrackpadTyping"
[ -f "$BIN" ] || { echo "build produced no binary" >&2; exit 1; }

# Signing over a bundle whose binary is currently executing fails partway and
# leaves the bundle broken; stop the app first.
pkill -f "$APP/Contents/MacOS/TrackpadTyping" 2>/dev/null && sleep 1 || true

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TrackpadTyping"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>TrackpadTyping</string>
    <key>CFBundleDisplayName</key>       <string>TrackpadTyping</string>
    <key>CFBundleExecutable</key>        <string>TrackpadTyping</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menu-bar only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string></string>
</dict>
</plist>
PLIST

# A real (if self-signed) identity beats ad hoc here: TCC pins an ad-hoc
# app's Accessibility grant to the exact binary hash, so every rebuild
# silently revokes it. With a certificate the grant pins to
# identifier+certificate and survives rebuilds.
# Launch Services and Finder decorate bundles with extended attributes that
# codesign refuses to seal; strip them or signing fails with "detritus".
xattr -cr "$APP"

IDENTITY="TrackpadTyping Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> Signing ($IDENTITY)"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> Signing (ad hoc — Accessibility will need re-granting after every rebuild)"
    codesign --force --deep --sign - "$APP"
fi

# Signing has intermittently produced a half-written signature (seen when
# LaunchServices touches the bundle mid-sign). Verify, and re-sign once
# before letting a broken bundle out the door.
if ! codesign --verify --deep "$APP" 2>/dev/null; then
    echo "==> Signature failed verification; re-signing"
    sleep 1
    xattr -cr "$APP"
    codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null \
        || codesign --force --deep --sign - "$APP"
    codesign --verify --deep "$APP" || { echo "signing is broken" >&2; exit 1; }
fi

# Ad-hoc signatures pin the Accessibility grant to the exact binary: the
# designated requirement is a bare cdhash. Any rebuild therefore revokes
# permission, and the stale entry stays in the list looking identical to the
# new one, which is a genuinely confusing failure. Say so explicitly.
echo
echo "Built $(pwd)/$APP"
# Only an ad-hoc signature pins the Accessibility grant to the exact binary;
# with the certificate the grant survives rebuilds and no warning is needed.
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
    echo
    echo "!! Ad-hoc signature: macOS revokes Accessibility on every rebuild."
    echo "   Re-grant with:  tccutil reset Accessibility $BUNDLE_ID"
    echo "   then relaunch and approve the prompt."
fi
echo
echo "Launch with:  open $APP"
