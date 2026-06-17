#!/bin/bash
# Kiosk setup script for Raspberry Pi 4 (Debian)
# Wayland setup using labwc + squeekboard + Chromium
# Includes autologin and SSH

set -e

# --- Configuration ---
KIOSK_URL="${1:-https://example.com}"
KIOSK_USER="$(whoami)"

echo "==> Wayland Kiosk setup starting..."
echo "    User: $KIOSK_USER"
echo "    URL:  $KIOSK_URL"
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

# --- Configure labwc autostart ---
echo "==> Configuring labwc autostart..."
mkdir -p "$HOME/.config/labwc"
cat > "$HOME/.config/labwc/autostart" <<EOF
# Start squeekboard virtual keyboard
squeekboard &

# Start Chromium in kiosk mode
chromium --kiosk \
  --noerrdialogs \
  --disable-infobars \
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
echo "    To manage remotely, SSH in: ssh $KIOSK_USER@<ip-address>"
