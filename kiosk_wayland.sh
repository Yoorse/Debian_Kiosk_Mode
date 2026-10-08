#!/bin/bash
# Kiosk setup script for Raspberry Pi 4 (Debian)
# Wayland setup using labwc + squeekboard + Chromium
# Includes autologin, SSH and an on-screen keyboard with a numpad

set -e

# --- Configuration ---
KIOSK_URL="${1:-https://example.com}"
KIOSK_USER="$(whoami)"
# Keyboard layout names the numpad layout is installed under.
# Squeekboard loads the file matching the active layout, so list every
# layout the kiosk might use (space separated).
KIOSK_KBD_LAYOUTS="${KIOSK_KBD_LAYOUTS:-us dk}"

echo "==> Wayland Kiosk setup starting..."
echo "    User: $KIOSK_USER"
echo "    URL:  $KIOSK_URL"
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

# --- Configure labwc autostart ---
echo "==> Configuring labwc autostart..."
mkdir -p "$HOME/.config/labwc"
cat > "$HOME/.config/labwc/autostart" <<EOF
# Start squeekboard virtual keyboard.
# SQUEEKBOARD_KEYBOARDSDIR points it at the kiosk layouts; without it the
# Raspberry Pi build only looks in /usr/share/misc/squeekboard/keyboards.
SQUEEKBOARD_KEYBOARDSDIR="$KBD_DIR" squeekboard &

# Start Chromium in kiosk mode
chromium --disable-infobars \
  --disable-session-crashed-bubble \
  --touch-events=enabled \
  $KIOSK_URL &
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
echo "    To change the URL later, edit ~/.config/labwc/autostart"
echo "    To change the on-screen keyboard, edit the files in $KBD_DIR"
echo "    To manage remotely, SSH in: ssh $KIOSK_USER@<ip-address>"
