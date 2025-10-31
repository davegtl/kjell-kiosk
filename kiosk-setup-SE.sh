#!/bin/bash
set -euo pipefail

LOG=/var/log/kiosk-setup.log
exec > >(tee -a "$LOG") 2>&1

echo "[kiosk-setup] starting at $(date)"

export DEBIAN_FRONTEND=noninteractive
KIOSK_USER="kiosk"
KIOSK_HOME="/home/${KIOSK_USER}"

# Ensure user exists (autoinstall should create it, but be safe)
if ! id -u "$KIOSK_USER" >/dev/null 2>&1; then
  echo "[kiosk-setup] creating user '${KIOSK_USER}'"
  useradd -m -s /bin/bash "$KIOSK_USER"
fi
mkdir -p "$KIOSK_HOME"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME"

echo "[kiosk-setup] apt-get update && install packages"
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
  locales

# Optional Wi‑Fi tools (harmless if no Wi‑Fi present)
apt-get install -y --no-install-recommends iw wireless-tools wpasupplicant firmware-iwlwifi || true

# Locale (Swedish)
locale-gen sv_SE.UTF-8
update-locale LANG=sv_SE.UTF-8

# Autologin on tty1
echo "[kiosk-setup] enabling tty1 autologin"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
EOF
systemctl daemon-reload

# Firefox Enterprise Policies (restrict browsing, set homepage, etc.)
# NOTE: For Firefox Snap, policies go under /var/snap/firefox/common/.mozilla/firefox/distribution/policies.json
# We write to both paths to cover deb/snap transparently.
echo "[kiosk-setup] writing Firefox policies"
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
    "DNSOverHTTPS": {
      "Enabled": false
    },
    "OfferToSaveLogins": false,
    "PasswordManagerEnabled": false,
    "DisablePrivateBrowsing": false
  }
}
EOF
cp /usr/lib/firefox/distribution/policies.json /var/snap/firefox/common/.mozilla/firefox/distribution/policies.json || true

# Kiosk session files
echo "[kiosk-setup] creating kiosk session files"

# 1) .xinitrc
cat > "${KIOSK_HOME}/.xinitrc" <<'EOF'
#!/bin/sh
# Keep screen on
xset s off
xset -dpms
xset s noblank

# Hide cursor when idle
unclutter -idle 2 &

# Lightweight WM
openbox-session &

# On-screen keyboard
onboard &

# Idle reset loop
/home/kiosk/reset.sh &

# Launch Firefox in kiosk + private window
/home/kiosk/launch-browser.sh &

wait
EOF
chmod +x "${KIOSK_HOME}/.xinitrc"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.xinitrc"

# 2) Browser launcher (Firefox)
cat > "${KIOSK_HOME}/launch-browser.sh" <<'EOF'
#!/bin/bash
export LANG=sv_SE.UTF-8
export LC_ALL=sv_SE.UTF-8
setxkbmap se || true

# Firefox kiosk + private mode
firefox --kiosk --private-window "https://kjell.com/se/"
EOF
chmod +x "${KIOSK_HOME}/launch-browser.sh"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/launch-browser.sh"

# 3) Idle reset: restart browser after 5 min inactivity
cat > "${KIOSK_HOME}/reset.sh" <<'EOF'
#!/bin/bash
while true; do
  idle_ms=$(xprintidle 2>/dev/null || echo 0)
  if [ "$idle_ms" -gt 300000 ]; then  # 5 minutes
    pkill -x firefox || true
    /home/kiosk/launch-browser.sh
  fi
  sleep 30
done
EOF
chmod +x "${KIOSK_HOME}/reset.sh"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/reset.sh"

# Auto-start X after autologin (only on tty1)
PROFILE="${KIOSK_HOME}/.profile"
if ! grep -q 'startx' "$PROFILE" 2>/dev/null; then
  cat >> "$PROFILE" <<'EOF'

# Auto-start X only on tty1 and if not already in X
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  startx
fi
EOF
  chown "${KIOSK_USER}:${KIOSK_USER}" "$PROFILE"
fi

# Nightly reboot at 02:00
echo "[kiosk-setup] adding nightly reboot cron"
crontab -u "$KIOSK_USER" -l 2>/dev/null | { cat; echo "0 2 * * * /sbin/reboot"; } | crontab -u "$KIOSK_USER" -

# Boot QoL: don't wait for network online
systemctl disable systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd-wait-online.service || true


echo "[SWEDISH-kiosk-setup] done at $(date)"
