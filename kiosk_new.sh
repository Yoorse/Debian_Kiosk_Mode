#!/bin/bash
# =====================================================================
#  Raspberry Pi 4 kiosk - Debian + labwc + Firefox ESR + wvkbd
#
#  - Autologin on tty1 -> labwc -> Firefox in kiosk mode
#  - On-screen keyboard (wvkbd) sends REAL key presses, so search
#    fields filter as you type (keydown/keyup reach the page)
#  - A small local Firefox add-on shows the keyboard when an input
#    field is tapped and hides it again when focus leaves
#
#  Run as the kiosk user (NOT root), with sudo rights:
#      bash kiosk-setup.sh
#      bash kiosk-setup.sh https://some-other-url
# =====================================================================
set -e

KIOSK_URL="${1:-https://dand-mes.matholdingsinc.com}"
KIOSK_USER="$(whoami)"
KIOSK_DIR="/opt/kiosk"
BRIDGE_PORT="8765"
FF_DIR="/usr/lib/firefox-esr"

if [ "$KIOSK_USER" = "root" ]; then
    echo "Run this as the kiosk user, not as root (sudo is used where needed)." >&2
    exit 1
fi

echo "==> Kiosk user: $KIOSK_USER"
echo "==> Kiosk URL:  $KIOSK_URL"

# ---------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------
echo "==> Installing packages"
sudo apt update
sudo apt install -y labwc firefox-esr wvkbd python3

# Old setup used squeekboard - make sure it isn't started anymore
pkill -x squeekboard 2>/dev/null || true

# ---------------------------------------------------------------------
# 2. Keyboard bridge: localhost:8765/show|hide -> signals to wvkbd
# ---------------------------------------------------------------------
echo "==> Writing keyboard bridge"
sudo mkdir -p "$KIOSK_DIR"
sudo tee "$KIOSK_DIR/osk-bridge.py" >/dev/null <<EOF
#!/usr/bin/env python3
# Tiny local HTTP service: the Firefox add-on calls /show or /hide,
# and this sends the matching signal to wvkbd.
import os, signal, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

SIGNALS = {
    "/show": signal.SIGUSR2,
    "/hide": signal.SIGUSR1,
    "/toggle": signal.SIGRTMIN,
}

def send(sig):
    try:
        pids = subprocess.run(["pgrep", "-x", "wvkbd-mobintl"],
                              capture_output=True, text=True).stdout.split()
    except Exception:
        return
    for pid in pids:
        try:
            os.kill(int(pid), sig)
        except Exception:
            pass

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        sig = SIGNALS.get(self.path.split("?")[0])
        if sig is not None:
            send(sig)
            self.send_response(204)
        else:
            self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", $BRIDGE_PORT), Handler).serve_forever()
EOF
sudo chmod 755 "$KIOSK_DIR/osk-bridge.py"

# ---------------------------------------------------------------------
# 3. Firefox add-on: show keyboard on input focus, hide on blur
# ---------------------------------------------------------------------
echo "==> Building Firefox add-on"
BUILD="$(mktemp -d)"

cat > "$BUILD/manifest.json" <<'EOF'
{
  "manifest_version": 2,
  "name": "Kiosk On-Screen Keyboard",
  "version": "1.0",
  "browser_specific_settings": { "gecko": { "id": "kiosk-osk@local" } },
  "permissions": ["http://127.0.0.1/*"],
  "background": { "scripts": ["background.js"] },
  "content_scripts": [{
    "matches": ["<all_urls>"],
    "js": ["content.js"],
    "all_frames": true,
    "run_at": "document_start"
  }]
}
EOF

cat > "$BUILD/background.js" <<EOF
// Debounced show/hide so moving between fields (or frames) doesn't flicker
let hideTimer = null;
function call(action) {
  fetch("http://127.0.0.1:$BRIDGE_PORT/" + action).catch(() => {});
}
browser.runtime.onMessage.addListener((msg) => {
  if (msg === "show") {
    clearTimeout(hideTimer);
    hideTimer = null;
    call("show");
  } else if (msg === "hide") {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => call("hide"), 300);
  }
});
EOF

cat > "$BUILD/content.js" <<'EOF'
const TEXT_TYPES = ["text", "search", "email", "password", "url", "tel", "number", ""];

function isTextField(el) {
  if (!el || el.disabled || el.readOnly) return false;
  if (el.isContentEditable) return true;
  if (el.tagName === "TEXTAREA") return true;
  if (el.tagName === "INPUT") {
    return TEXT_TYPES.includes((el.getAttribute("type") || "text").toLowerCase());
  }
  return false;
}

function target(e) {
  // Look inside shadow DOM as well
  return (e.composedPath && e.composedPath()[0]) || e.target;
}

document.addEventListener("focusin", (e) => {
  if (isTextField(target(e))) browser.runtime.sendMessage("show");
}, true);

document.addEventListener("focusout", (e) => {
  if (isTextField(target(e))) browser.runtime.sendMessage("hide");
}, true);

// Hide when the page navigates away (e.g. after pressing Enter on login)
window.addEventListener("pagehide", () => {
  browser.runtime.sendMessage("hide");
});
EOF

python3 - "$BUILD" <<'EOF'
import sys, zipfile, os
src = sys.argv[1]
with zipfile.ZipFile(os.path.join(src, "kiosk-osk.xpi"), "w", zipfile.ZIP_DEFLATED) as z:
    for name in ("manifest.json", "background.js", "content.js"):
        z.write(os.path.join(src, name), name)
EOF
sudo cp "$BUILD/kiosk-osk.xpi" "$KIOSK_DIR/kiosk-osk.xpi"
sudo chmod 644 "$KIOSK_DIR/kiosk-osk.xpi"
rm -rf "$BUILD"

# ---------------------------------------------------------------------
# 4. Firefox config: allow the local (unsigned) add-on, kiosk policies
# ---------------------------------------------------------------------
echo "==> Configuring Firefox"
sudo tee "$FF_DIR/defaults/pref/autoconfig.js" >/dev/null <<'EOF'
pref("general.config.filename", "mozilla.cfg");
pref("general.config.obscure_value", 0);
EOF

sudo tee "$FF_DIR/mozilla.cfg" >/dev/null <<'EOF'
// Kiosk autoconfig - first line must be a comment
lockPref("xpinstall.signatures.required", false);
lockPref("browser.sessionstore.resume_from_crash", false);
lockPref("browser.shell.checkDefaultBrowser", false);
lockPref("datareporting.policy.dataSubmissionEnabled", false);
lockPref("browser.aboutwelcome.enabled", false);
lockPref("browser.translations.automaticallyPopup", false);
EOF

sudo mkdir -p /etc/firefox-esr/policies
sudo tee /etc/firefox-esr/policies/policies.json >/dev/null <<'EOF'
{
  "policies": {
    "DontCheckDefaultBrowser": true,
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableAppUpdate": true,
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
    "ExtensionSettings": {
      "kiosk-osk@local": {
        "installation_mode": "force_installed",
        "install_url": "file:///opt/kiosk/kiosk-osk.xpi"
      }
    }
  }
}
EOF

# ---------------------------------------------------------------------
# 5. labwc autostart (old file is backed up)
# ---------------------------------------------------------------------
echo "==> Writing labwc autostart"
mkdir -p "$HOME/.config/labwc"
if [ -f "$HOME/.config/labwc/autostart" ]; then
    cp "$HOME/.config/labwc/autostart" "$HOME/.config/labwc/autostart.bak-$(date +%Y%m%d-%H%M%S)"
fi

cat > "$HOME/.config/labwc/autostart" <<EOF
# Kiosk autostart - generated by kiosk-setup.sh

# On-screen keyboard, hidden until an input field is focused
wvkbd-mobintl --hidden -L 260 -H 300 &

# Bridge between the Firefox add-on and wvkbd
python3 $KIOSK_DIR/osk-bridge.py &

# Firefox in kiosk mode, restarted automatically if it closes or crashes
( while true; do
    MOZ_ENABLE_WAYLAND=1 firefox-esr --kiosk "$KIOSK_URL"
    sleep 2
  done ) &
EOF

# ---------------------------------------------------------------------
# 6. Autologin on tty1 and start labwc there
# ---------------------------------------------------------------------
echo "==> Setting up autologin"
if systemctl is-enabled display-manager >/dev/null 2>&1; then
    echo "    Disabling existing display manager (labwc starts from tty1 instead)"
    sudo systemctl disable display-manager || true
fi

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
sudo systemctl daemon-reload

PROFILE="$HOME/.bash_profile"
touch "$PROFILE"
if ! grep -q "kiosk-setup: start labwc" "$PROFILE"; then
    cat >> "$PROFILE" <<'EOF'

# kiosk-setup: start labwc on tty1
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec labwc
fi
EOF
fi

echo
echo "==> Done."
echo "    Reboot to start the kiosk:  sudo reboot"
