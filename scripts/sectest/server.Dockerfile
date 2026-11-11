# Throwaway stand-in for a production Ubuntu server: systemd as PID 1, Docker
# Engine from the distribution, the tools setup.sh expects on a server.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates curl git openssl python3 openssh-client sudo \
      iproute2 iptables kmod procps less cron tzdata lsb-release \
      docker.io docker-compose-v2 unattended-upgrades apt-utils ufw \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && systemctl mask getty@tty1.service console-getty.service systemd-udevd.service \
      systemd-udevd-kernel.socket systemd-udevd-control.socket \
      sys-kernel-debug.mount sys-kernel-tracing.mount systemd-logind.service \
 && systemctl enable docker
STOPSIGNAL SIGRTMIN+3
VOLUME /var/lib/docker
CMD ["/sbin/init"]
