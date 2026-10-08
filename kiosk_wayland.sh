#!/bin/bash
# Kiosk setup script for Raspberry Pi 4 (Debian)
# Wayland setup using labwc + squeekboard + Chromium
# Includes autologin, SSH and an on-screen keyboard with a numpad.
# Chromium opens one pinned tab per URL; a closed tab is reopened and
# Chromium itself is restarted if it is closed.
#
# Usage: set the URLs in KIOSK_URLS below and run ./kiosk.sh
#        or pass them directly: ./kiosk.sh URL [URL ...]

set -e

# --- Configuration ---
# One tab per URL, in this order. Put each URL in quotes on its own line,
# with no commas between them.
KIOSK_URLS=(
    "https://example.com"
)
# URLs given on the command line replace the list above.
if [ $# -gt 0 ]; then
    KIOSK_URLS=("$@")
fi
KIOSK_USER="$(whoami)"
# Keyboard layout names the numpad layout is installed under.
# Squeekboard loads the file matching the active layout, so list every
# layout the kiosk might use (space separated).
KIOSK_KBD_LAYOUTS="${KIOSK_KBD_LAYOUTS:-us dk}"

echo "==> Wayland Kiosk setup starting..."
echo "    User: $KIOSK_USER"
for url in "${KIOSK_URLS[@]}"; do
    echo "    Tab:  $url"
done
echo "    Keyboard layouts: $KIOSK_KBD_LAYOUTS"
echo ""

# --- Install packages ---
echo "==> Installing packages..."
sudo apt update
sudo apt install -y \
    labwc \
    squeekboard \
    chromium \
    seatd \
    openssh-server \
    xdg-user-dirs

# --- Enable and start services ---
echo "==> Enabling services..."
sudo systemctl enable seatd
sudo systemctl start seatd
sudo systemctl enable ssh
sudo systemctl start ssh

# --- Add user to seat group ---
echo "==> Adding $KIOSK_USER to seat group..."
sudo groupadd -f seat
sudo usermod -aG seat "$KIOSK_USER"

# --- Autologin via systemd drop-in ---
echo "==> Configuring autologin for $KIOSK_USER on tty1..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF

sudo systemctl daemon-reload

# --- Install squeekboard layout (letters + numpad) ---
echo "==> Installing squeekboard layout with numpad..."
KBD_DIR="$HOME/.local/share/squeekboard/keyboards"
KBD_TMP="$(mktemp)"
mkdir -p "$KBD_DIR"
cat > "$KBD_TMP" <<'YAML'
---
# Kiosk layout: letters on the left, numpad always visible on the right.
# Install as ~/.local/share/squeekboard/keyboards/<layout>_wide.yaml
#
# Every row adds up to 720 units wide (528 letters + 192 numpad),
# which is what keeps the numpad columns lined up. If you change a
# row, keep that total.

outlines:
    default:   { width: 48,  height: 50 }
    special:   { width: 48,  height: 50 }
    wide:      { width: 96,  height: 50 }
    spaceline: { width: 288, height: 50 }
    altline:   { width: 64,  height: 50 }   # numpad keys

views:
    base:
        - "q w e r t y u i o p å   np7 np8 np9"
        - "a s d f g h j k l æ ø   np4 np5 np6"
        - "Shift_L z x c v b n m BackSpace   np1 np2 np3"
        - "show_symbols space period Return   np_comma np0 np_period"
    upper:
        - "Q W E R T Y U I O P Å   np7 np8 np9"
        - "A S D F G H J K L Æ Ø   np4 np5 np6"
        - "Shift_L Z X C V B N M BackSpace   np1 np2 np3"
        - "show_symbols space period Return   np_comma np0 np_period"
    symbols:
        - "@ # $ % & - _ + = ( )   np7 np8 np9"
        - "! ? , ' colon ; * / € < >   np4 np5 np6"
        - "[ ] { } \\ | ~ ^ ° BackSpace   np1 np2 np3"
        - "show_letters space period Return   np_comma np0 np_period"

buttons:
    Shift_L:
        action:
            locking:
                lock_view: "upper"
                unlock_view: "base"
        outline: "wide"
        icon: "key-shift"
    BackSpace:
        outline: "wide"
        icon: "edit-clear-symbolic"
        action: "erase"
    show_symbols:
        action:
            set_view: "symbols"
        outline: "wide"
        label: "#+="
    show_letters:
        action:
            set_view: "base"
        outline: "wide"
        label: "ABC"
    period:
        outline: "special"
        text: "."
    colon:
        text: ":"
    space:
        outline: "spaceline"
        text: " "
    Return:
        outline: "wide"
        icon: "key-enter"
        keysym: "Return"

    # Numpad
    np0:
        outline: "altline"
        text: "0"
    np1:
        outline: "altline"
        text: "1"
    np2:
        outline: "altline"
        text: "2"
    np3:
        outline: "altline"
        text: "3"
    np4:
        outline: "altline"
        text: "4"
    np5:
        outline: "altline"
        text: "5"
    np6:
        outline: "altline"
        text: "6"
    np7:
        outline: "altline"
        text: "7"
    np8:
        outline: "altline"
        text: "8"
    np9:
        outline: "altline"
        text: "9"
    np_comma:
        outline: "altline"
        text: ","
    np_period:
        outline: "altline"
        text: "."
YAML

# One copy per layout name: plain (portrait) and _wide (landscape)
for layout in $KIOSK_KBD_LAYOUTS; do
    cp "$KBD_TMP" "$KBD_DIR/$layout.yaml"
    cp "$KBD_TMP" "$KBD_DIR/${layout}_wide.yaml"
done
rm -f "$KBD_TMP"

# --- Install the keep-tabs Chromium extension ---
# Pins the kiosk tabs (no close button) and reopens one if it is closed.
echo "==> Installing Chromium keep-tabs extension..."
EXT_DIR="$HOME/.local/share/kiosk-keep-tabs"
mkdir -p "$EXT_DIR"
cat > "$EXT_DIR/manifest.json" <<'JSON'
{
  "manifest_version": 3,
  "name": "Kiosk keep tabs",
  "version": "1.0",
  "description": "Pins the kiosk tabs and reopens any of them that gets closed.",
  "permissions": ["storage"],
  "background": { "service_worker": "background.js" }
}
JSON

cat > "$EXT_DIR/background.js" <<'JS'
// Kiosk keep tabs
// The kiosk URLs are listed in urls.json. The first tabs Chromium opens are
// "adopted" as the kiosk tabs (one per URL, in order) and pinned. If one of
// them is closed it is reopened in the same place; if it is unpinned it is
// pinned again. Tabs a user opens themselves are left alone.

const KEY = "kioskTabIds";            // tab id per URL, kept for this browser run
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;

async function loadUrls() {
  const res = await fetch(chrome.runtime.getURL("urls.json"));
  return res.json();
}

async function normalTabs() {
  const tabs = await chrome.tabs.query({ windowType: "normal" });
  return tabs.sort((a, b) => a.windowId - b.windowId || a.index - b.index);
}

async function ensureTabs() {
  const urls = await loadUrls();
  const stored = (await chrome.storage.session.get(KEY))[KEY];

  let tabs = await normalTabs();
  if (!stored) {
    // First run after Chromium starts: wait for the startup tabs to exist.
    for (let i = 0; i < 20 && tabs.length < urls.length; i++) {
      await sleep(250);
      tabs = await normalTabs();
    }
  }
  // No window left: Chromium is closing, and the kiosk script restarts it.
  if (tabs.length === 0) return;

  // First run: adopt the startup tabs in order, one per URL.
  const ids = stored || urls.map((_, i) => (tabs[i] ? tabs[i].id : null));
  const open = new Map(tabs.map((t) => [t.id, t]));
  const home = (ids.map((id) => open.get(id)).find(Boolean) || tabs[0]).windowId;

  let failed = false;
  for (let i = 0; i < urls.length; i++) {
    try {
      const tab = ids[i] != null ? open.get(ids[i]) : null;
      if (tab) {
        if (!tab.pinned) {
          await chrome.tabs.update(tab.id, { pinned: true });
          await chrome.tabs.move(tab.id, { index: i });
        }
        continue;
      }
      // The tab for this URL is gone: open it again in the same place.
      const created = await chrome.tabs.create({
        windowId: home, url: urls[i], index: i, pinned: true, active: false,
      });
      ids[i] = created.id;
    } catch (e) {
      console.warn("kiosk tabs: could not restore tab", i, e);
      failed = true;
    }
  }
  await chrome.storage.session.set({ [KEY]: ids });

  // Chromium refuses tab changes for a moment in some cases (for example
  // while a tab is being dragged), so try again shortly, a limited number
  // of times.
  failures = failed ? failures + 1 : 0;
  if (failed && failures < 30) setTimeout(check, 1000);
}

// Run one check at a time so two quick closes cannot open duplicates.
let queue = Promise.resolve();
function check() {
  queue = queue.then(ensureTabs).catch((e) => console.error("kiosk tabs:", e));
  return queue;
}

chrome.tabs.onRemoved.addListener(() => check());
chrome.tabs.onUpdated.addListener((_id, change) => {
  if (change.pinned === false) check();
});
chrome.runtime.onStartup.addListener(() => check());
chrome.runtime.onInstalled.addListener(() => check());
check();
JS

# The tab list for the extension (JSON) and for the Chromium command line
{
    echo "["
    sep=""
    for url in "${KIOSK_URLS[@]}"; do
        esc=${url//\\/\\\\}
        esc=${esc//\"/\\\"}
        printf '%s  "%s"' "$sep" "$esc"
        sep=$',\n'
    done
    printf '\n]\n'
} > "$EXT_DIR/urls.json"

URL_ARGS=""
for url in "${KIOSK_URLS[@]}"; do
    URL_ARGS="$URL_ARGS '${url//\'/\'\\\'\'}'"
done

# --- Configure labwc autostart ---
echo "==> Configuring labwc autostart..."
mkdir -p "$HOME/.config/labwc"
cat > "$HOME/.config/labwc/autostart" <<EOF
# Start squeekboard virtual keyboard.
# SQUEEKBOARD_KEYBOARDSDIR points it at the kiosk layouts; without it the
# Raspberry Pi build only looks in /usr/share/misc/squeekboard/keyboards.
SQUEEKBOARD_KEYBOARDSDIR="$KBD_DIR" squeekboard &

# Start Chromium with one tab per URL (no --kiosk, so the tab bar shows).
# The loop starts it again if it is closed or crashes.
while pgrep -x labwc > /dev/null; do
  chromium \\
    --noerrdialogs \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --touch-events=enabled \\
    --load-extension="$EXT_DIR" \\
   $URL_ARGS
  sleep 2
done &
EOF

# --- Create ~/.bash_profile to launch labwc on login ---
echo "==> Creating ~/.bash_profile..."
cat > "$HOME/.bash_profile" <<EOF
if [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    labwc
fi
EOF

echo ""
echo "==> Done! Please reboot to start kiosk mode:"
echo "    sudo reboot"
echo ""
echo "    To change the tabs later, run this script again with the new URLs"
echo "    To change the on-screen keyboard, edit the files in $KBD_DIR"
echo "    To manage remotely, SSH in: ssh $KIOSK_USER@<ip-address>"
