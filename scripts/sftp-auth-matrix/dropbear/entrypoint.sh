#!/bin/sh
# 試験ユーザー・fixture・ed25519 ホスト鍵を用意し、Dropbear を前面実行する(password と publickey の両方を提示)。
set -eu
: "${PKPANE_MATRIX_PASSWORD:?PKPANE_MATRIX_PASSWORD が必要}"
: "${PKPANE_MATRIX_AUTHORIZED_KEY:?PKPANE_MATRIX_AUTHORIZED_KEY が必要}"

if ! id matrix >/dev/null 2>&1; then
  adduser -D -s /bin/sh matrix
fi
printf '%s:%s\n' matrix "$PKPANE_MATRIX_PASSWORD" | chpasswd

home=/home/matrix
mkdir -p "$home/.ssh"
printf '%s\n' "$PKPANE_MATRIX_AUTHORIZED_KEY" > "$home/.ssh/authorized_keys"
printf 'PKPane auth matrix fixture\n' > "$home/read-only.txt"
chown -R matrix:matrix "$home"
chmod 0700 "$home/.ssh"
chmod 0600 "$home/.ssh/authorized_keys"
unset PKPANE_MATRIX_PASSWORD PKPANE_MATRIX_AUTHORIZED_KEY

if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
  dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
fi
exec dropbear -F -E -p 22 -r /etc/dropbear/dropbear_ed25519_host_key
