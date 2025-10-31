#!/bin/bash
set -euo pipefail

LOG=/var/log/kiosk-setup.log
exec > >(tee -a "$LOG") 2>&1

echo "[kiosk-setup] starting at $(date)"

export DEBIAN_FRONTEND=noninteractive
KIOSK_USER="kiosk"
KIOSK_HOME="/home/${KIOSK_USER}"

# --- Ensure user exists ---
echo "[kiosk-setup] Checking if user '${KIOSK_USER}' exists"
if ! id -u "$KIOSK_USER" >/dev/null 2>&1; then
  echo "[kiosk-setup] User '${KIOSK_USER}' not found, creating user"
  useradd -m -s /bin/bash "$KIOSK_USER"
else
  echo "[kiosk-setup] User '${KIOSK_USER}' already exists"
fi
mkdir -p "$KIOSK_HOME"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME"

# --- Install packages ---
echo "[kiosk-setup] Installing required packages"
apt-get update
apt-get install -y --no-install-recommends \
  firefox \
  xserver-xorg \
  xinit \
  openbox \
  x11-xserver-utils \
  xprintidle \
  onboard \
  unclutter \
  dbus-x11 \
  ca-certificates \
  curl \
  language-pack-sv \
  locales \
  iw wireless-tools wpasupplicant firmware-iwlwifi || true

echo "[kiosk-setup] Locale setup: Generating sv_SE.UTF-8 locale"
locale-gen sv_SE.UTF-8
update-locale LANG=sv_SE.UTF-8

# --- Autologin on tty1 ---
echo "[kiosk-setup] Configuring autologin for user '${KIOSK_USER}' on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
EOF
systemctl daemon-reload

# --- Firefox Enterprise Policies ---
echo "[kiosk-setup] Writing Firefox policies"
mkdir -p /usr/lib/firefox/distribution
mkdir -p /var/snap/firefox/common/.mozilla/firefox/distribution
cat > /usr/lib/firefox/distribution/policies.json <<'EOF'
{
  "policies": {
    "DontCheckDefaultBrowser": true,
    "DisableAppUpdate": true,
    "DisableFirefoxStudies": true,
    "DisableTelemetry": true,
    "BlockAboutConfig": true,
    "Homepage": {
      "URL": "https://kjell.com/se/",
      "Locked": true
    },
    "WebsiteFilter": {
      "Block": ["*"],
      "Exceptions": [
        "https://kjell.com/se/*",
        "https://www.kjell.com/se/*",
        "https://*.kjell.com/*"
      ]
    },
    "DNSOverHTTPS": { "Enabled": false },
    "OfferToSaveLogins": false,
    "PasswordManagerEnabled": false,
    "DisablePrivateBrowsing": false
  }
}
EOF
cp /usr/lib/firefox/distribution/policies.json /var/snap/firefox/common/.mozilla/firefox/distribution/policies.json || true

# --- Kiosk session files ---
echo "[kiosk-setup] Creating kiosk session files"

# .xinitrc
echo "[kiosk-setup] Writing .xinitrc to start Openbox and Firefox"
cat > "${KIOSK_HOME}/.xinitrc" <<'EOF'
#!/bin/bash
set -euxo pipefail

# Prevent blank screen / power saving
xset s off -dpms s noblank || true

# Wait for X to settle before launching
sleep 2

# Start Openbox (lightweight WM)
openbox-session &

# Launch On-screen keyboard safely
(onboard || true) &

# Hide cursor when idle
(unclutter -idle 2 || true) &

# Start idle-reset loop
(/home/kiosk/reset.sh || true) &

# Start browser after slight delay (ensures X + WM ready)
sleep 3
/home/kiosk/launch-browser.sh &

wait
EOF
chmod +x "${KIOSK_HOME}/.xinitrc"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.xinitrc"

# launch-browser.sh
echo "[kiosk-setup] Writing launch-browser.sh to start Firefox in kiosk mode"
cat > "${KIOSK_HOME}/launch-browser.sh" <<'EOF'
#!/bin/bash
set -euxo pipefail
export DISPLAY=:0
export LANG=sv_SE.UTF-8
export LC_ALL=sv_SE.UTF-8
setxkbmap se || true

# Kill leftover Firefox before starting a new one
pkill -x firefox || true
sleep 1

# Launch Firefox in kiosk mode
firefox --no-remote --kiosk --private-window "https://kjell.com/se/"
EOF
chmod +x "${KIOSK_HOME}/launch-browser.sh"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/launch-browser.sh"

# reset.sh
echo "[kiosk-setup] Writing reset.sh to restart Firefox after inactivity"
cat > "${KIOSK_HOME}/reset.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export DISPLAY=:0
while true; do
  idle_ms=$(xprintidle 2>/dev/null || echo 0)
  if [ "$idle_ms" -gt 300000 ]; then
    pkill -x firefox || true
    /home/kiosk/launch-browser.sh &
  fi
  sleep 30
done
EOF
chmod +x "${KIOSK_HOME}/reset.sh"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/reset.sh"

# --- Auto-start X after autologin ---
echo "[kiosk-setup] Writing auto-start X configuration"
PROFILE="${KIOSK_HOME}/.bash_profile"
cat > "$PROFILE" <<'EOF'
# Auto-start X only on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  startx -- -nocursor
fi
EOF
chown "${KIOSK_USER}:${KIOSK_USER}" "$PROFILE"

# --- Nightly reboot at 02:00 ---
echo "[kiosk-setup] Adding nightly reboot cron job"
( crontab -u "$KIOSK_USER" -l 2>/dev/null; echo "0 2 * * * /sbin/reboot" ) | crontab -u "$KIOSK_USER" -

# --- Speed boot ---
echo "[kiosk-setup] Disabling network-wait-online service to speed up boot"
systemctl disable systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd-wait-online.service || true

echo "[kiosk-setup] Setup completed at $(date)"
echo "Please unplug the USB drive within 30 seconds."
sleep 30
