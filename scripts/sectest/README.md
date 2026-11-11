# Security test of a production setup

Two things live here.

## 1. `probe.py`: ask a real server from outside

```bash
python3 scripts/sectest/probe.py ephem.health.gov.xx            # from a laptop, not the server
python3 scripts/sectest/probe.py ephem.health.gov.xx --burst    # also the throttles (noisy)
```

It only asks: nothing is changed and no password is tried. Each line is
something the server must refuse (the RPC endpoints and the database manager,
with and without a language code in front, a certificate for a request by IP
address, TLS below 1.2, a cookie without Secure). Python 3.8, no package.

## 2. The rig: a throwaway production server to attack

What the November 2026 test ran on. A container with systemd and its own
Docker stands in for an Ubuntu server, so `bash setup.sh` runs as it does in
production (Server deploy, nginx, HTTPS in the same run), and other containers
on the same network are the machines of an attacker, of the proxy, and of a
certificate authority. Nothing of the developer stack is touched.

```bash
R=scripts/sectest
docker build -t pentest-server:local -f $R/server.Dockerfile $R
docker build -t pentest-attacker:local -f $R/client.Dockerfile $R
docker network create --subnet 10.77.0.0/24 pentest-net
docker volume create pentest-dind; docker volume create pentest-containerd

# The server. Both volumes are needed: Docker 29 keeps images in
# /var/lib/containerd, and on the container's own filesystem the app image
# does not unpack ("failed to convert whiteout file").
docker run -d --name pentest-srv --hostname ephem-prod --privileged --cgroupns=private \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec \
  -v pentest-dind:/var/lib/docker -v pentest-containerd:/var/lib/containerd \
  --network pentest-net --ip 10.77.0.10 pentest-server:local

# Two other machines: one attacks, one plays the proxy of proxy mode.
docker run -d --name pentest-attacker --network pentest-net --ip 10.77.0.66 \
  --cap-add NET_ADMIN --cap-add NET_RAW pentest-attacker:local
docker run -d --name pentest-proxy --network pentest-net --ip 10.77.0.20 \
  --cap-add NET_ADMIN pentest-attacker:local

# A certificate authority that speaks ACME (Let's Encrypt's own test server)
# and a DNS that points every name at the server.
docker run -d --name pentest-challtestsrv --network pentest-net --ip 10.77.0.31 \
  ghcr.io/letsencrypt/pebble-challtestsrv:latest -defaultIPv6 "" -defaultIPv4 10.77.0.10 \
  -http01 "" -https01 "" -tlsalpn01 "" -doh ""
docker run -d --name pentest-pebble --network pentest-net --ip 10.77.0.30 \
  -e PEBBLE_VA_NOSLEEP=1 -e PEBBLE_WFE_NONCEREJECT=0 \
  -v "$PWD/$R/pebble-config.json:/test/config/pebble-config.json:ro" \
  ghcr.io/letsencrypt/pebble:latest -config /test/config/pebble-config.json -dnsserver 10.77.0.31:8053
```

Inside the server (`docker exec -it pentest-srv bash`), once:

1. On WSL the kernel says "microsoft" and the scripts would take the server
   for a Windows machine: `echo "Linux version 6.8.0-45-generic" > /srv/v &&
   mount --bind /srv/v /proc/version` (again after each restart of the
   container).
2. An account as on a real server: `useradd -m -G docker,sudo deploy` with
   passwordless sudo, and this checkout copied to `/home/deploy/ephem-deploy`
   (`git ls-files | tar` from the developer machine; `docker cp` cannot write
   into `/tmp` there, it is in memory).
3. The addons without a GitHub key: a bare clone of the ePHEM branch at
   `/srv/ePHEM.git`, `git config --global url.file:///srv/ePHEM.git.insteadOf
   git@github-ephem-addons:borse/ePHEM.git`, and a stand-in
   `/usr/local/bin/ssh` that answers `ssh -T git@github...` with "successfully
   authenticated" and hands everything else to `/usr/bin/ssh`.
4. certbot pointed at the test authority, before the first certificate:
   `printf 'server = https://10.77.0.30:14000/dir\nno-verify-ssl = true\n'`
   into `/etc/letsencrypt/cli.ini` of the `certbot-etc` volume. No `dig` on
   the server (setup then skips its DNS check), or a stand-in that prints
   10.77.0.10.

Then `bash setup.sh` as `deploy`, with a domain such as
`ephem.health.example`, and attack from `pentest-attacker` (it has nmap,
testssl.sh in `/opt/testssl`, Python with requests and websocket-client;
add `10.77.0.10 ephem.health.example` to its `/etc/hosts`). `ws_flood.py`
is the live update flood: `python3 ws_flood.py 260 30` asks for 260
connections and holds them 30 seconds.

What this rig can show that the developer machine cannot: each client has
its own address (rate limits per address, the proxy firewall with real
packets, a restart of the server with `docker restart pentest-srv`), and
certificates are issued, renewed and deleted for real.

Remove everything afterwards (about 10 GB):

```bash
docker rm -f pentest-srv pentest-attacker pentest-proxy pentest-pebble pentest-challtestsrv
docker volume rm pentest-dind pentest-containerd; docker network rm pentest-net
```
