#!/bin/sh
# 試験ユーザー・fixture・ホスト鍵を起動時に用意し、変種別の sshd_config で sshd を前面実行する。
set -eu
: "${SSHD_VARIANT:?SSHD_VARIANT が必要}"
: "${PKPANE_MATRIX_PASSWORD:?PKPANE_MATRIX_PASSWORD が必要}"
: "${PKPANE_MATRIX_AUTHORIZED_KEY:?PKPANE_MATRIX_AUTHORIZED_KEY が必要}"

if ! id matrix >/dev/null 2>&1; then
  useradd -m -s /bin/sh matrix
fi
printf '%s:%s\n' matrix "$PKPANE_MATRIX_PASSWORD" | chpasswd

home=/home/matrix
mkdir -p "$home/.ssh"
printf '%s\n' "$PKPANE_MATRIX_AUTHORIZED_KEY" > "$home/.ssh/authorized_keys"
printf 'PKPane auth matrix fixture\n' > "$home/read-only.txt"
chown -R matrix:matrix "$home"
chmod 0700 "$home/.ssh"
chmod 0600 "$home/.ssh/authorized_keys"
# 秘密を子プロセス(sshd)の環境へ残さない。
unset PKPANE_MATRIX_PASSWORD PKPANE_MATRIX_AUTHORIZED_KEY

ssh-keygen -A
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e -f "/etc/pkpane/${SSHD_VARIANT}.conf"
