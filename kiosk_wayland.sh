#!/bin/bash
# Kiosk setup script for Raspberry Pi 4 (Debian)
# Wayland setup using labwc + Chromium
# Includes autologin, SSH and an on-screen keyboard (Chromium extension)
# that pops up automatically when a text field is tapped and hides again.
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
# On-screen keyboard: Manifest V3 port of the "Virtual Keyboard" extension
# (xontab) that the old Raspbian kiosk used.
VKB_REPO="${VKB_REPO:-https://github.com/foonerd/chrome-virtual-keyboard-v3}"
VKB_SRC="$HOME/.local/share/kiosk-virtual-keyboard"
# Keyboard language. The extension has no Danish layout, so the script
# adds one (Norwegian layout with æ and ø in Danish order) and locks the
# keyboard to it.
VKB_LANG="da"

echo "==> Wayland Kiosk setup starting..."
echo "    User: $KIOSK_USER"
for url in "${KIOSK_URLS[@]}"; do
    echo "    Tab:  $url"
done
echo ""

# --- Install packages ---
echo "==> Installing packages..."
sudo apt update
sudo apt install -y \
    labwc \
    chromium \
    seatd \
    openssh-server \
    xdg-user-dirs \
    git

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

# --- Install the on-screen keyboard Chromium extension ---
echo "==> Installing on-screen keyboard extension..."
# Always start from a fresh copy, because the Danish changes below are
# applied on top of it (a git pull would trip over them).
rm -rf "$VKB_SRC"
git clone --depth 1 "$VKB_REPO" "$VKB_SRC"

# The extension may live in the repo root or in a subfolder:
# use the folder that holds manifest.json.
VKB_MANIFEST="$(find "$VKB_SRC" -name manifest.json -not -path '*/.git/*' -not -path '*/node_modules/*' | head -n 1)"
if [ -z "$VKB_MANIFEST" ]; then
    echo "!! No manifest.json found in $VKB_SRC - cannot load the keyboard extension." >&2
    exit 1
fi
VKB_DIR="$(dirname "$VKB_MANIFEST")"
if ! grep -q '"manifest_version"[[:space:]]*:[[:space:]]*3' "$VKB_MANIFEST"; then
    echo "!! $VKB_MANIFEST is not Manifest V3 - current Chromium will not load it." >&2
    exit 1
fi
echo "    Keyboard extension: $VKB_DIR"

# --- Danish keyboard layout ---
echo "==> Adding Danish (DK) keyboard layout..."
VKB_JS="$VKB_DIR/script.js"
VKB_NO="$VKB_DIR/layouts/keyboard_no.html"
VKB_DA="$VKB_DIR/layouts/keyboard_da.html"
if [ ! -f "$VKB_NO" ] || [ ! -f "$VKB_JS" ]; then
    echo "!! The keyboard extension has changed layout; cannot add Danish." >&2
    exit 1
fi

# Danish = Norwegian with æ and ø swapped (DK: ... k l æ ø).
# Also fixes the uppercase Æ entity, which is misspelt in the Norwegian file.
sed -e 's/&oslash;/@@oe@@/g' -e 's/&Oslash;/@@OE@@/g' \
    -e 's/&aelig;/\&oslash;/g' -e 's/&Aelig;/\&Oslash;/g' -e 's/&AElig;/\&Oslash;/g' \
    -e 's/@@oe@@/\&aelig;/g' -e 's/@@OE@@/\&AElig;/g' \
    "$VKB_NO" > "$VKB_DA"

# The extension normally picks its layout from a Volumio setting and falls
# back to English. Lock it to Danish, make Danish the default and add it to
# the layout list.
sed -i \
    -e "s/virtualKeyboardChromeExtensionKeyboardLayout1Setting = getVolumioKeyboardLayout();/virtualKeyboardChromeExtensionKeyboardLayout1Setting = \"$VKB_LANG\";/" \
    -e "s/^var DEFAULT_LAYOUT = \"en\";/var DEFAULT_LAYOUT = \"$VKB_LANG\";/" \
    -e 's/^var ALT_LAYOUTS = \[/&\n    {"value":"da","name":"Dansk"},/' \
    "$VKB_JS"

if ! grep -q "KeyboardLayout1Setting = \"$VKB_LANG\";" "$VKB_JS" \
   || ! grep -q '_key="&aelig;"' "$VKB_DA"; then
    echo "!! Could not switch the keyboard to Danish (the extension's code has changed)." >&2
    exit 1
fi

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
# Start Chromium with one tab per URL (no --kiosk, so the tab bar shows).
# Two unpacked extensions are loaded: keep-tabs and the on-screen keyboard.
# The keyboard pops up when a text field is tapped and hides afterwards.
# The loop starts Chromium again if it is closed or crashes.
while pgrep -x labwc > /dev/null; do
  chromium \\
    --noerrdialogs \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --touch-events=enabled \\
    --disable-features=DisableLoadExtensionCommandLineSwitch \\
    --load-extension="$EXT_DIR,$VKB_DIR" \\
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
echo "    The on-screen keyboard uses the Danish (DK) layout"
echo "    To update the on-screen keyboard, run this script again (it fetches the latest version)"
echo "    To manage remotely, SSH in: ssh $KIOSK_USER@<ip-address>"
