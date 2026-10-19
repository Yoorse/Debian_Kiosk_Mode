#!/usr/bin/env bash
#
# kiosk-wayland-setup.sh
# Raspberry Pi OS / Debian kiosk on the normal Wayland desktop (labwc/wayfire)
# with Squeekboard, which pops up by itself when a text field is tapped.
#
#  - Undoes kiosk-xorg-setup.sh (re-enables lightdm, removes tty1 startx, etc.)
#  - Chromium (normal maximized window, not --kiosk) started at login,
#    restarted automatically if it closes
#  - Two sites opened as pinned tabs (local extension)
#  - "Squeekboard key bridge" extension: Squeekboard types via the input method,
#    so pages that filter on keyup never react. The bridge sends the missing
#    keydown/keyup events after each typed character.
#
# Usage (as root):
#   sudo ./kiosk-wayland-setup.sh -u pi -1 "http://mes-server/mes/" -2 "http://other-site/"
#
# Safe to run more than once.

set -euo pipefail

KIOSK_USER="${KIOSK_USER:-pi}"
PIN_URL1="${PIN_URL1:-http://your-mes-server/mes/}"
PIN_URL2="${PIN_URL2:-http://your-second-site/}"
PIN_EXT="/opt/kiosk-pin-tabs"
BRIDGE_EXT="/opt/squeekboard-key-bridge"
LAUNCHER="/usr/local/bin/kiosk-browser"

usage() {
    echo "Usage: $0 [-u user] [-1 first_pinned_url] [-2 second_pinned_url]"
    exit 1
}

while getopts "u:1:2:h" opt; do
    case "$opt" in
        u) KIOSK_USER="$OPTARG" ;;
        1) PIN_URL1="$OPTARG" ;;
        2) PIN_URL2="$OPTARG" ;;
        *) usage ;;
    esac
done

log()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m!!\e[0m $*"; }

# --- Sanity checks ----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root (sudo)." >&2
    exit 1
fi
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    echo "User '$KIOSK_USER' does not exist. Use -u <user>." >&2
    exit 1
fi

HOME_DIR="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
STAMP="$(date +%Y%m%d-%H%M%S)"

backup() {
    if [ -f "$1" ]; then
        cp -a "$1" "$1.bak-$STAMP"
        warn "Backed up $1 -> $1.bak-$STAMP"
    fi
}

log "User         : $KIOSK_USER ($HOME_DIR)"
log "Pinned tab 1 : $PIN_URL1"
log "Pinned tab 2 : $PIN_URL2"

# ============================================================================
# 1. Undo the Xorg setup (if it was applied)
# ============================================================================
log "Reverting Xorg kiosk changes (if any)..."

# Re-enable services the Xorg script disabled
DISABLED_LOG=/root/kiosk-disabled-services.txt
if [ -f "$DISABLED_LOG" ]; then
    sort -u "$DISABLED_LOG" | while read -r svc; do
        [ -n "$svc" ] || continue
        systemctl enable "$svc" && log "Re-enabled $svc"
    done
    mv "$DISABLED_LOG" "$DISABLED_LOG.reverted-$STAMP"
fi

# Make sure the graphical login (lightdm) is on
if systemctl list-unit-files lightdm.service >/dev/null 2>&1 && \
   systemctl list-unit-files lightdm.service | grep -q lightdm; then
    systemctl enable lightdm >/dev/null 2>&1 || true
fi
systemctl set-default graphical.target

# Remove the tty1 console autologin (lightdm handles autologin to the desktop)
GETTY_CONF=/etc/systemd/system/getty@tty1.service.d/autologin.conf
if [ -f "$GETTY_CONF" ] && grep -q -- "--autologin" "$GETTY_CONF"; then
    backup "$GETTY_CONF"
    rm -f "$GETTY_CONF"
    log "Removed tty1 console autologin"
fi

# Remove 'exec startx' block from ~/.bash_profile
if [ -f "$HOME_DIR/.bash_profile" ] && grep -qF "# kiosk-xorg-setup: start X on tty1" "$HOME_DIR/.bash_profile"; then
    backup "$HOME_DIR/.bash_profile"
    sed -i '/# kiosk-xorg-setup: start X on tty1/,/^fi$/d' "$HOME_DIR/.bash_profile"
    log "Removed startx from $HOME_DIR/.bash_profile"
fi

# Remove the Onboard dconf settings
if [ -f /etc/dconf/db/local.d/00-kiosk-onboard ]; then
    rm -f /etc/dconf/db/local.d/00-kiosk-onboard /etc/dconf/db/local.d/locks/00-kiosk-onboard
    command -v dconf >/dev/null && dconf update || true
    log "Removed Onboard settings"
fi

# Desktop autologin for the user (Raspberry Pi OS: B4 = desktop autologin)
if command -v raspi-config >/dev/null 2>&1; then
    SUDO_USER="$KIOSK_USER" raspi-config nonint do_boot_behaviour B4 || \
        warn "raspi-config could not set desktop autologin; set it in raspi-config > System > Boot / Auto Login"
elif [ -f /etc/lightdm/lightdm.conf ]; then
    backup /etc/lightdm/lightdm.conf
    if grep -q '^autologin-user=' /etc/lightdm/lightdm.conf; then
        sed -i "s/^autologin-user=.*/autologin-user=$KIOSK_USER/" /etc/lightdm/lightdm.conf
    else
        sed -i "/^\[Seat:\*\]/a autologin-user=$KIOSK_USER" /etc/lightdm/lightdm.conf
    fi
fi

systemctl daemon-reload

# ============================================================================
# 2. Chromium
# ============================================================================
CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
if [ -z "$CHROMIUM_BIN" ]; then
    log "Installing Chromium..."
    apt-get update
    apt-get install -y chromium || apt-get install -y chromium-browser
    CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium)"
fi
log "Chromium     : $CHROMIUM_BIN"

# ============================================================================
# 3. Extension: Squeekboard key bridge
# ============================================================================
log "Writing Squeekboard key bridge to $BRIDGE_EXT..."
mkdir -p "$BRIDGE_EXT"

cat > "$BRIDGE_EXT/manifest.json" <<'EOF'
{
  "manifest_version": 3,
  "name": "Squeekboard key bridge",
  "version": "1.0",
  "description": "Sends keydown/keyup to the page when Squeekboard inserts text via the input method, so keyup-based filters react.",
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_start",
      "all_frames": true,
      "world": "MAIN"
    }
  ]
}
EOF

cat > "$BRIDGE_EXT/content.js" <<'EOF'
// Squeekboard (Wayland text-input) inserts characters as IME text, so the page
// gets an `input` event but no normal keydown/keyup. Pages that filter on keyup
// never react. This script fakes the missing key events after IME input.
// Real keyboard and barcode-scanner keystrokes are left alone.
(() => {
  let realKeyPending = false;

  // Remember when a real (non-IME) key was pressed, so we don't double up.
  document.addEventListener('keydown', e => {
    if (e.isTrusted && e.keyCode !== 229) realKeyPending = true;
  }, true);

  const fire = (el, type, ch) => {
    const code = ch ? ch.toUpperCase().charCodeAt(0) : 0;
    const ev = new KeyboardEvent(type, { key: ch || 'Unidentified', bubbles: true, cancelable: true });
    // Old-style handlers read keyCode/which; make them look like a real key.
    Object.defineProperty(ev, 'keyCode', { get: () => code });
    Object.defineProperty(ev, 'which', { get: () => code });
    Object.defineProperty(ev, 'charCode', { get: () => (type === 'keypress' ? code : 0) });
    el.dispatchEvent(ev);
  };

  document.addEventListener('input', e => {
    if (!e.isTrusted) return;
    const el = e.target;
    if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) return;

    if (realKeyPending) {            // came from a real keyboard/scanner
      realKeyPending = false;
      return;
    }
    if (!e.inputType || !e.inputType.startsWith('insert')) return;

    const ch = (e.data || '').slice(-1);
    fire(el, 'keydown', ch);
    fire(el, 'keypress', ch);
    fire(el, 'keyup', ch);
  }, true);
})();
EOF

# ============================================================================
# 4. Extension: pinned tabs
# ============================================================================
log "Writing pinned-tabs extension to $PIN_EXT..."
mkdir -p "$PIN_EXT"

cat > "$PIN_EXT/manifest.json" <<'EOF'
{
  "manifest_version": 3,
  "name": "Kiosk pinned tabs",
  "version": "1.0",
  "description": "Keeps the configured kiosk sites open as pinned tabs.",
  "permissions": ["tabs"],
  "background": { "service_worker": "background.js" }
}
EOF

js_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cat > "$PIN_EXT/background.js" <<EOF
// Generated by kiosk-wayland-setup.sh on $STAMP
const PINNED = [
  "$(js_str "$PIN_URL1")",
  "$(js_str "$PIN_URL2")"
];

const urlOf = t => t.pendingUrl || t.url || "";
const isPinnedSite = u => PINNED.some(p => u.startsWith(p));

async function pinMatching() {
  const tabs = await chrome.tabs.query({});
  for (const t of tabs) {
    if (!t.pinned && isPinnedSite(urlOf(t))) {
      await chrome.tabs.update(t.id, { pinned: true });
    }
  }
}

async function ensureOpen() {
  const tabs = await chrome.tabs.query({});
  for (let i = 0; i < PINNED.length; i++) {
    const p = PINNED[i];
    const existing = tabs.find(t => urlOf(t).startsWith(p));
    if (existing) {
      await chrome.tabs.update(existing.id, { pinned: true });
      await chrome.tabs.move(existing.id, { index: i });
    } else {
      await chrome.tabs.create({ url: p, pinned: true, index: i, active: i === 0 });
    }
  }
  // Close the leftover empty New Tab page, if any
  const after = await chrome.tabs.query({});
  for (const t of after) {
    const u = urlOf(t);
    if (!t.pinned && (u === "chrome://newtab/" || u === "chrome://new-tab-page/")) {
      await chrome.tabs.remove(t.id);
    }
  }
  const [first] = await chrome.tabs.query({ pinned: true, index: 0 });
  if (first) await chrome.tabs.update(first.id, { active: true });
}

const startup = () => setTimeout(() => ensureOpen().catch(console.error), 1500);
chrome.runtime.onStartup.addListener(startup);
chrome.runtime.onInstalled.addListener(startup);

chrome.tabs.onUpdated.addListener((id, info) => {
  if (info.url || info.status === "complete") pinMatching().catch(console.error);
});
EOF

chmod -R a+rX "$PIN_EXT" "$BRIDGE_EXT"

# ============================================================================
# 5. Browser launcher + autostart
# ============================================================================
log "Writing launcher $LAUNCHER..."
cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Generated by kiosk-wayland-setup.sh on $STAMP
# Starts Chromium on Wayland with Squeekboard support, and restarts it if closed.

CHROMIUM="$CHROMIUM_BIN"
PREFS="\$HOME/.config/chromium/Default/Preferences"

while true; do
    # Suppress the "Chromium didn't shut down correctly" bubble
    if [ -f "\$PREFS" ]; then
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' "\$PREFS"
    fi

    "\$CHROMIUM" \\
        --start-maximized \\
        --ozone-platform=wayland \\
        --enable-wayland-ime \\
        --wayland-text-input-version=3 \\
        --load-extension="$PIN_EXT,$BRIDGE_EXT" \\
        --disable-features=DisableLoadExtensionCommandLineSwitch \\
        --noerrdialogs \\
        --disable-infobars \\
        --disable-session-crashed-bubble \\
        --no-first-run \\
        --check-for-update-interval=31536000

    sleep 2
done
EOF
chmod 755 "$LAUNCHER"

AUTOSTART_DIR="$HOME_DIR/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

# Disable other Chromium autostart entries, so Chromium doesn't start twice
# (a second launch would join the first window and ignore our extensions).
for f in "$AUTOSTART_DIR"/*.desktop; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "kiosk-browser.desktop" ] && continue
    if grep -qi '^Exec=.*chromium' "$f"; then
        mv "$f" "$f.disabled-$STAMP"
        warn "Disabled old autostart entry: $f"
    fi
done

cat > "$AUTOSTART_DIR/kiosk-browser.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Kiosk browser
Exec=$LAUNCHER
X-GNOME-Autostart-enabled=true
EOF

chown -R "$KIOSK_USER": "$HOME_DIR/.config"

# Warn about Chromium being started from compositor config files as well
for f in "$HOME_DIR/.config/labwc/autostart" "$HOME_DIR/.config/wayfire.ini" \
         /etc/xdg/labwc/autostart /etc/wayfire/defaults.ini; do
    if [ -f "$f" ] && grep -qi 'chromium' "$f"; then
        warn "Chromium is also started in $f - remove that line, or it will start twice."
    fi
done

# ============================================================================
log "Done."
echo
echo "  Reboot to start:  sudo reboot"
echo
echo "  Squeekboard pops up by itself when a text field is tapped."
echo "  If it does not appear: raspi-config > Display Options > On-screen Keyboard"
echo
echo "  Pinned tabs match by URL prefix. If a site redirects elsewhere"
echo "  (http -> https, login on another host), use the address it ends up on,"
echo "  or edit PINNED in $PIN_EXT/background.js."
