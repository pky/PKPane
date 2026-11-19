FROM alpine:3.20
# Dropbear は sftp-server を /usr/libexec/sftp-server に固定で探すため、OpenSSH 由来の実体をリンクする。
RUN apk add --no-cache dropbear openssh-sftp-server \
  && mkdir -p /etc/dropbear /usr/libexec \
  && ln -sf /usr/lib/ssh/sftp-server /usr/libexec/sftp-server
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
