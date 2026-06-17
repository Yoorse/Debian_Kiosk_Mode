# 🖥️ Debian Kiosk Mode

> Automated kiosk setup for Raspberry Pi 4 running Debian — boots straight into Chromium using Wayland and [cage](https://github.com/cage-kiosk/cage).

---

## Requirements

- A machine that can run Linux. For my usecase it will be running on a Raspberry Pi 4.
- Debian (minimal install)
- Internet connection

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/Yoorse/Debian_Kiosk_Mode
cd Debian_Kiosk_Mode
```

### 2. Configure

Open `kiosk.sh` and change the values to match your setup:

```bash
nano kiosk.sh
# or
vim kiosk.sh
```

The main thing to set is your kiosk URL:

```bash
KIOSK_URL="https://yoursite.com"
```

### 3. Make the script executable

```bash
chmod +x kiosk.sh
```

### 4. Run

```bash
./kiosk.sh
```

Then reboot:

```bash
sudo reboot
```

---

## What it does

- Installs `cage` and `chromium`
- Enables `seatd` for Wayland seat management
- Configures autologin on tty1
- Sets up `~/.bash_profile` to launch Chromium in kiosk mode on boot

---

## License

MIT
