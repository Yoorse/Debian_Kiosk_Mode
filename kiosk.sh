#!/bin/bash
# Kiosk setup script for Raspberry Pi 4 (Debian)
# Sets up cage + Chromium in kiosk mode with autologin

set -e

# --- Configuration ---
KIOSK_URL="${1:-https://example.com}"
KIOSK_USER="$(whoami)"

echo "==> Kiosk setup starting..."
echo "    User: $KIOSK_USER"
echo "    URL:  $KIOSK_URL"
echo ""

# --- Install packages ---
echo "==> Installing cage and chromium..."
sudo apt update
sudo apt install -y cage chromium seatd

# --- Enable seatd ---
echo "==> Enabling seatd..."
sudo groupadd seat
sudo usermod -aG seat "$KIOSK_USER"
sudo systemctl enable seatd
sudo systemctl start seatd


# --- Autologin via systemd drop-in ---
echo "==> Configuring autologin for $KIOSK_USER on tty1..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf > /dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF

sudo systemctl daemon-reload

# --- Create ~/.bash_profile ---
echo "==> Creating ~/.bash_profile..."
cat > "$HOME/.bash_profile" <<EOF
if [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    cage -- chromium --kiosk --noerrdialogs  --disable-session-crashed-bubble $KIOSK_URL
fi
EOF

echo ""
echo "==> Done! Please reboot to start kiosk mode:"
echo "    sudo reboot"
echo ""
echo "    To change the URL later, edit ~/.bash_profile"
