# Ubuntu host for spec/system: real sshd, sudo with and without a password,
# and the tools Herd commands drive (PostgreSQL, gpg, visudo, git, rsync, crontab).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
 && apt-get install -qq -y --no-install-recommends \
      openssh-server sudo postgresql gnupg git rsync curl ca-certificates locales cron \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

# herd: sudo asks for its password, as on a freshly provisioned server.
# nopass: NOPASSWD sudo, as on CI images and cloud defaults.
# SHA-512 rather than Ubuntu's default yescrypt, which is deliberately slow: every SSH login
# and every sudo of herd verifies the password, hundreds of times per run.
RUN useradd -m -s /bin/bash herd \
 && echo 'herd:herd-password' | chpasswd -c SHA512 \
 && usermod -aG sudo herd \
 && useradd -m -s /bin/bash nopass \
 && echo 'nopass:nopass-password' | chpasswd -c SHA512 \
 && echo 'nopass ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/nopass \
 && chmod 440 /etc/sudoers.d/nopass

RUN sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
