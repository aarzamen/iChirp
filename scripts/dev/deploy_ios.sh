#!/usr/bin/env bash
set -euo pipefail

# Build, assemble, codesign, and deploy MacParakeet to a physical iPhone device via devicectl.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/ios"
APP_BUNDLE="$DIST_DIR/MacParakeet.app"
DEVICE_CORE_ID="${DEVICE_CORE_ID:-4FC3C1DC-B809-552A-B60F-B1723ADB45B8}"
DEVICE_UDID="${DEVICE_UDID:-00008150-0018046C0188401C}"
TEAM_ID="${DEVELOPMENT_TEAM:-XM6E4PUXTU}"
SIGN_IDENTITY="${SIGN_IDENTITY:-4D7FF1AF669C1DAADFC2B57D2DBD0B0FD8E87441}"
PROFILE_PATH="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/5be0241b-d1a7-4505-b419-04063ac6475a.mobileprovision"

echo "==> Building MacParakeetMobile for iOS (generic/platform=iOS)..."
xcodebuild build -scheme MacParakeetMobile -destination "generic/platform=iOS" -skipMacroValidation

DERIVED_DATA_BUILD_DIR="$HOME/Library/Developer/Xcode/DerivedData/macparakeet-gycmincunrvguzcquobawgrtsvkk/Build/Products/Debug-iphoneos"
BINARY_SOURCE="$DERIVED_DATA_BUILD_DIR/MacParakeetMobile"

if [[ ! -f "$BINARY_SOURCE" ]]; then
    echo "Error: Binary not found at $BINARY_SOURCE"
    exit 1
fi

echo "==> Assembling iOS App Bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE"

# 1. Copy executable
cp "$BINARY_SOURCE" "$APP_BUNDLE/MacParakeetMobile"
chmod +x "$APP_BUNDLE/MacParakeetMobile"

# 2. Copy SPM resource bundles
for bundle in "$DERIVED_DATA_BUILD_DIR"/*.bundle; do
    if [[ -d "$bundle" ]]; then
        echo "   Copying $(basename "$bundle")..."
        cp -R "$bundle" "$APP_BUNDLE/"
    fi
done

# 3. Copy App Intents metadata if present
if [[ -d "$DERIVED_DATA_BUILD_DIR/MacParakeetMobileUI.appintents" ]]; then
    echo "   Copying MacParakeetMobileUI.appintents..."
    cp -R "$DERIVED_DATA_BUILD_DIR/MacParakeetMobileUI.appintents" "$APP_BUNDLE/"
fi

# 4. Copy Provisioning Profile
if [[ -f "$PROFILE_PATH" ]]; then
    echo "   Embedding provisioning profile..."
    cp "$PROFILE_PATH" "$APP_BUNDLE/embedded.mobileprovision"
else
    echo "Warning: Provisioning profile not found at $PROFILE_PATH"
fi

# 5. Generate Info.plist
cat <<EOF > "$APP_BUNDLE/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacParakeetMobile</string>
    <key>CFBundleIdentifier</key>
    <string>com.macparakeet.app</string>
    <key>CFBundleName</key>
    <string>MacParakeet</string>
    <key>CFBundleDisplayName</key>
    <string>MacParakeet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>MinimumOSVersion</key>
    <string>17.0</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
    </array>
    <key>NSMicrophoneUsageDescription</key>
    <string>MacParakeet uses the microphone for local on-device voice dictation and meeting recording.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>MacParakeet uses speech recognition models locally on device to transcribe your voice.</string>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
EOF

# 6. Generate Entitlements
ENTITLEMENTS_FILE="$DIST_DIR/entitlements.plist"
cat <<EOF > "$ENTITLEMENTS_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>${TEAM_ID}.com.macparakeet.app</string>
    <key>com.apple.developer.team-identifier</key>
    <string>${TEAM_ID}</string>
    <key>get-task-allow</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>${TEAM_ID}.com.macparakeet.app</string>
    </array>
</dict>
</plist>
EOF

echo "==> Code signing bundle with identity: $SIGN_IDENTITY..."
# Sign all nested bundles first
find "$APP_BUNDLE" -name "*.bundle" -exec codesign --force --sign "$SIGN_IDENTITY" --timestamp=none {} +

# Sign main app bundle
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" --timestamp=none "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign -vvv --deep --strict "$APP_BUNDLE"

echo "==> Deploying to Aaron’s iPhone ($DEVICE_CORE_ID)..."
xcrun devicectl device install app --device "$DEVICE_CORE_ID" "$APP_BUNDLE"

echo "==> Launching MacParakeet on device..."
xcrun devicectl device process launch --device "$DEVICE_CORE_ID" com.macparakeet.app || true

echo "==> Deployment complete! MacParakeet is running on device."
