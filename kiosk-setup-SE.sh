#!/bin/bash
set -euo pipefail
LOG=/var/log/kiosk-setup.log
exec > >(tee -a "$LOG") 2>&1

echo "[kiosk-setup] starting at $(date)"
export DEBIAN_FRONTEND=noninteractive

KIOSK_USER="kiosk"
KIOSK_HOME="/home/${KIOSK_USER}"

# ---------- user ----------
id "$KIOSK_USER" &>/dev/null || useradd -m -s /bin/bash "$KIOSK_USER"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$KIOSK_HOME"

# ---------- common pkgs ----------
apt-get update
apt-get install -y --no-install-recommends \
  snapd dbus-user-session ca-certificates curl fonts-dejavu-core
systemctl enable --now snapd.socket || true
snap list firefox >/dev/null 2>&1 || snap install firefox

# ---------- try to expose a DRM device (Proxmox virtio-gpu) ----------
modprobe virtio_gpu || true
echo virtio_gpu >/etc/modules-load.d/virtio_gpu.conf || true
apt-get install -y --no-install-recommends libdrm2 libgbm1 libgl1 mesa-vulkan-drivers mesa-va-drivers

# ---------- autologin on tty1 ----------
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF
systemctl daemon-reload

# ---------- detect graphics path ----------
if [ -e /dev/dri/card0 ] || [ -e /dev/dri/renderD128 ]; then
  MODE="wayland"
else
  MODE="xorg"
fi
echo "[kiosk-setup] graphics mode chosen: ${MODE}"

# ========== WAYLAND (Cage) path ==========
if [ "$MODE" = "wayland" ]; then
  apt-get install -y --no-install-recommends cage
  usermod -aG video,input,render "$KIOSK_USER" || true
  loginctl enable-linger "$KIOSK_USER" || true

  cat >/etc/systemd/system/cage@.service <<'EOF'
[Unit]
Description=Wayland Kiosk (Cage) on %I
After=getty@tty1.service systemd-logind.service
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
Environment=MOZ_ENABLE_WAYLAND=1
Environment=XDG_RUNTIME_DIR=/run/user/%U
ExecStartPre=/bin/bash -lc 'mkdir -p /run/user/%U && chown %U:%U /run/user/%U && chmod 700 /run/user/%U'
ExecStart=/usr/bin/cage -- snap run firefox --kiosk --private-window https://kjell.com/se/
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable cage@${KIOSK_USER}.service

# ========== XORG + OPENBOX fallback ==========
else
  apt-get install -y --no-install-recommends \
    xserver-xorg xinit openbox x11-xserver-utils xauth dbus-x11 unclutter

  # user session that launches firefox kiosk
  cat >"${KIOSK_HOME}/.xinitrc" <<'EOF'
#!/bin/bash
set -e
xset s off -dpms s noblank || true
openbox-session &
(unclutter -idle 2 || true) &
exec snap run firefox --no-remote --kiosk --private-window "https://kjell.com/se/"
EOF
  chown "$KIOSK_USER:$KIOSK_USER" "${KIOSK_HOME}/.xinitrc"
  chmod +x "${KIOSK_HOME}/.xinitrc"

  # systemd unit to start X on tty1 for kiosk
  cat >/etc/systemd/system/startx@.service <<'EOF'
[Unit]
Description=Start X (kiosk) on %I
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

  systemctl enable startx@${KIOSK_USER}.service
fi

echo "[kiosk-setup] done. Reboot to enter ${MODE} kiosk."
