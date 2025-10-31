#!/bin/bash
set -euo pipefail

LOG=/var/log/kiosk-setup.log
exec > >(tee -a "$LOG") 2>&1

echo "[kiosk-setup] starting at $(date)"

export DEBIAN_FRONTEND=noninteractive
KIOSK_USER="kiosk"
KIOSK_HOME="/home/${KIOSK_USER}"

# --- Ensure user exists ---
echo "[kiosk-setup] Ensuring user '${KIOSK_USER}' exists"
if ! id -u "$KIOSK_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$KIOSK_USER"
fi
mkdir -p "$KIOSK_HOME"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME"

# --- Packages for Ubuntu 24.04.x ---
echo "[kiosk-setup] Installing packages"
apt-get update
apt-get install -y --no-install-recommends \
  xserver-xorg \
  xinit \
  openbox \
  x11-xserver-utils \
  xkb-data \
  xprintidle \
  xauth \
  onboard \
  unclutter \
  dbus-x11 \
  ca-certificates \
  curl \
  locales \
  language-pack-sv \
  iw wireless-tools wpasupplicant \
  snapd \
  linux-firmware

# --- Locale sv_SE.UTF-8 ---
echo "[kiosk-setup] Configuring sv_SE.UTF-8 locale"
if ! locale -a | grep -qi '^sv_SE\.utf8$'; then
  sed -i 's/^# *sv_SE.UTF-8/sv_SE.UTF-8/' /etc/locale.gen || true
  locale-gen sv_SE.UTF-8
fi
update-locale LANG=sv_SE.UTF-8

# --- Install Firefox (Snap) ---
echo "[kiosk-setup] Installing Firefox (snap)"
systemctl enable --now snapd.socket || true
if ! snap list firefox >/dev/null 2>&1; then
  snap install core || true
  snap install firefox
fi
FIREFOX_BIN="snap run firefox"

# --- Autologin on tty1 ---
echo "[kiosk-setup] Configuring autologin on tty1 for ${KIOSK_USER}"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF
systemctl daemon-reload

# --- Systemd service to start X on tty1 as kiosk (no .bash_profile needed) ---
echo "[kiosk-setup] Installing startx@kiosk systemd service"
cat >/etc/systemd/system/startx@.service <<'EOF'
[Unit]
Description=Start X on %I
After=getty@tty1.service
Requires=getty@tty1.service
Conflicts=display-manager.service

[Service]
User=%i
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
StandardInput=tty
StandardOutput=tty
StandardError=tty
Environment=DISPLAY=:0
ExecStart=/bin/bash -lc 'startx -- -nocursor'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl enable startx@kiosk.service

# --- Firefox Enterprise Policies (Snap path) ---
echo "[kiosk-setup] Writing Firefox policies"
POLICY_DIR="/var/snap/firefox/common/.mozilla/firefox/distribution"
mkdir -p "$POLICY_DIR"
cat > "${POLICY_DIR}/policies.json" <<'EOF'
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

# --- Kiosk session files ---
echo "[kiosk-setup] Creating kiosk session files"

# .xinitrc
cat > "${KIOSK_HOME}/.xinitrc" <<'EOF'
#!/bin/bash
set -euxo pipefail

# Prevent blank screen / power saving
xset s off -dpms s noblank || true

# Wait for X to settle before launching
sleep 2

# Start Openbox
openbox-session &

# On-screen keyboard
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
cat > "${KIOSK_HOME}/launch-browser.sh" <<EOF
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
${FIREFOX_BIN} --no-remote --kiosk --private-window "https://kjell.com/se/"
EOF
chmod +x "${KIOSK_HOME}/launch-browser.sh"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/launch-browser.sh"

# reset.sh
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

# --- Nightly reboot at 02:00 ---
echo "[kiosk-setup] Adding nightly reboot cron job"
( crontab -u "$KIOSK_USER" -l 2>/dev/null; echo "0 2 * * * /sbin/reboot" ) | crontab -u "$KIOSK_USER" -

# --- Speed boot: disable wait-online only if present ---
if systemctl list-unit-files | grep -q '^systemd-networkd-wait-online.service'; then
  echo "[kiosk-setup] Disabling network-wait-online"
  systemctl disable systemd-networkd-wait-online.service || true
  systemctl mask systemd-networkd-wait-online.service || true
fi

