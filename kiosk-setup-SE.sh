#!/bin/bash
set -euo pipefail
LOG=/var/log/kiosk-setup.log
exec > >(tee -a "$LOG") 2>&1

echo "[kiosk-setup] starting at $(date)"

export DEBIAN_FRONTEND=noninteractive
KIOSK_USER="kiosk"
KIOSK_HOME="/home/${KIOSK_USER}"

# --- Create kiosk user ---
id "$KIOSK_USER" &>/dev/null || useradd -m -s /bin/bash "$KIOSK_USER"

# --- Install packages ---
apt-get update
apt-get install -y --no-install-recommends \
  cage \
  snapd \
  dbus-user-session \
  fonts-dejavu-core \
  ca-certificates \
  curl

systemctl enable --now snapd.socket || true
snap list firefox >/dev/null 2>&1 || snap install firefox

# --- Autologin on tty1 ---
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF
systemctl daemon-reload

# --- Wayland kiosk service ---
cat >/etc/systemd/system/cage@.service <<'EOF'
[Unit]
Description=Wayland Kiosk (Cage) on %I
After=getty@tty1.service
Requires=getty@tty1.service
Conflicts=display-manager.service

[Service]
User=%i
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=tty
StandardError=tty
Environment=MOZ_ENABLE_WAYLAND=1
ExecStart=/usr/bin/cage -- snap run firefox --kiosk --private-window https://kjell.com/se/
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl enable cage@kiosk.service

echo "[kiosk-setup] done. reboot to start kiosk."
