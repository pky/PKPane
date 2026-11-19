ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssh-server \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /run/sshd \
  && rm -f /etc/ssh/ssh_host_*
# Debian の postinst がイメージ内にホスト鍵を焼き込むため削除し、コンテナ起動時に台ごとに生成する。
COPY sshd.d/ /etc/pkpane/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0644 /etc/pkpane/*.conf && chmod 0755 /usr/local/bin/entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
