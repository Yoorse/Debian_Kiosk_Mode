#!/bin/bash
# Switch the Raspberry Pi kiosk (labwc + squeekboard) from Chromium to Firefox ESR.
# Run as the kiosk user (not root):  bash kiosk-switch-to-firefox.sh
# Optional: pass the URL if it can't be read from the autostart:  bash kiosk-switch-to-firefox.sh https://your-url
set -e

AUTOSTART="$HOME/.config/labwc/autostart"
POLICY_DIR="/etc/firefox-esr/policies"

if [ ! -f "$AUTOSTART" ]; then
    echo "Can't find $AUTOSTART - stopping." >&2
    exit 1
fi

# 1. Find the kiosk URL (argument first, otherwise from the Chromium line)
URL="$1"
if [ -z "$URL" ]; then
    URL=$(grep -E '^[^#]*chromium' "$AUTOSTART" | grep -oE 'https?://[^ "&]+' | head -n1)
fi
if [ -z "$URL" ]; then
    echo "Could not find a URL in the Chromium line. Run again with the URL as argument." >&2
    exit 1
fi
echo "Kiosk URL: $URL"

# 2. Install Firefox ESR
sudo apt update
sudo apt install -y firefox-esr

# 3. Policies: no welcome page, no default-browser prompt, no session restore
sudo mkdir -p "$POLICY_DIR"
sudo tee "$POLICY_DIR/policies.json" >/dev/null <<'EOF'
{
  "policies": {
    "DontCheckDefaultBrowser": true,
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "NoDefaultBookmarks": true,
    "PasswordManagerEnabled": false,
    "OfferToSaveLogins": false,
    "UserMessaging": {
      "WhatsNew": false,
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "SkipOnboarding": true
    },
    "Preferences": {
      "browser.sessionstore.resume_from_crash": { "Value": false, "Status": "locked" }
    }
  }
}
EOF

# 4. Back up the autostart, then comment out Chromium and add Firefox
BACKUP="$AUTOSTART.bak-$(date +%Y%m%d-%H%M%S)"
cp "$AUTOSTART" "$BACKUP"
echo "Backup: $BACKUP"

sed -i -E 's/^([^#]*chromium.*)$/# \1/' "$AUTOSTART"
# Remove any Firefox line from an earlier run before adding it again
sed -i '/firefox-esr --kiosk/d' "$AUTOSTART"

cat >> "$AUTOSTART" <<EOF

# Kiosk browser (Firefox ESR, Wayland) - squeekboard pops up via text-input-v3
MOZ_ENABLE_WAYLAND=1 firefox-esr --kiosk "$URL" &
EOF

# 5. Make sure squeekboard is allowed to show
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true 2>/dev/null || true

echo
echo "Done. New autostart:"
echo "----------------------------------------"
cat "$AUTOSTART"
echo "----------------------------------------"
echo "Reboot to test:  sudo reboot"
echo "To go back to Chromium:  cp \"$BACKUP\" \"$AUTOSTART\""
