#!/bin/bash
set -euo pipefail

KIOSK_USER="kiosk"
KIOSK_HOME="/home/$KIOSK_USER"

# Create user if missing
if ! id -u "$KIOSK_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$KIOSK_USER"
fi

# Minimal packages: X, WM, startx deps, Firefox (snap)
apt-get update
apt-get install -y --no-install-recommends \
  xserver-xorg xinit openbox x11-xserver-utils xauth dbus-x11 unclutter snapd
systemctl enable --now snapd.socket || true
snap list firefox >/dev/null 2>&1 || snap install firefox

# Autologin on tty1 as kiosk
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF
systemctl daemon-reload

# Systemd unit to start X on tty1 (no .bash_profile hacks)
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

[Install]
WantedBy=multi-user.target
EOF
systemctl enable startx@kiosk.service

# User X session: Openbox + Firefox kiosk to your URL
install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 0755 -d "$KIOSK_HOME"
cat >"${KIOSK_HOME}/.xinitrc" <<'EOF'
#!/bin/bash
set -e
# keep screen awake
xset s off -dpms s noblank || true
# start WM
openbox-session &
# hide cursor after 2s idle (optional)
(unclutter -idle 2 || true) &
# launch Firefox in kiosk
exec snap run firefox --no-remote --kiosk --private-window "https://kjell.com/se/"
EOF
chown "$KIOSK_USER:$KIOSK_USER" "${KIOSK_HOME}/.xinitrc"
chmod +x "${KIOSK_HOME}/.xinitrc"

echo "Done. Reboot to enter kiosk."
