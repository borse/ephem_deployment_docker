# Host Hardening for Production Servers

The containers protect what runs *inside* them. Everything on this page is
about the server they run on, which Docker cannot protect for you. Work
through it once when a server goes to production — about 20 minutes.

> Demo and developer setups on a laptop or office VM do not need this page.

---

## 1. Docker and your firewall — read this first

**Ports published by Docker bypass ufw.** Docker writes its own iptables
rules, so a container port published as `80:80` is reachable from the
internet even when `ufw status` shows nothing allowed. `ufw allow` /
`ufw deny` simply do not apply to Docker-published ports.

What this means in practice:

- The ports this stack publishes (80 and 443 on nginx) are **meant** to be
  public — that part is fine.
- **Never add extra `ports:` entries to `docker-compose.yml` on a server**
  (for example publishing 8069 "to test something"). That exposes raw Odoo
  to the internet and no firewall setting will save you. Developer and demo
  setups DO publish Odoo on every address of the machine, on purpose (a
  phone or a colleague on the same network opens it): they belong on a
  laptop or an office VM, never on a server. `DEV_BIND_HOST=127.0.0.1` in
  `.env` keeps a developer instance on the machine itself.
- **Direct access** (`SERVER_ACCESS=direct`) is the same raw Odoo, chosen on
  purpose: no HTTPS, no login throttle, RPC endpoints open. `setup.sh` asks
  which address of the server answers; give the one of the closed network or
  the VPN, not "every address", on a server that also has a public one.
- ufw still fully protects everything that is *not* Docker: use it for SSH.
- nginx is published on the server's **IPv4** addresses only. Docker cannot
  hand an IPv6 visitor's address to a container on an IPv4 network: it relays
  the connection itself, and nginx would see every IPv6 visitor as one
  address, sharing one login throttle. Do not add `[::]` ports for it.
- **Behind an nginx on another machine** (`SERVER_ACCESS=proxy`), Odoo is
  published on one LAN address, ports 8069 and 8072, for that nginx. setup.sh
  runs `scripts/proxy-firewall.sh apply`, which lets only `PROXY_FROM` reach
  them through Docker's `DOCKER-USER` chain, the one place Docker's own
  rules leave to you. Odoo trusts that nginx's forwarded headers there, so
  set `PROXY_FROM` as soon as the proxy's address is known (it may wait,
  `bash scripts/proxy-firewall.sh detect` finds it once the proxy is in use)
  and run `apply`; until then any machine that reaches the address can skip
  the proxy.

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 22/tcp        # rate-limits SSH brute force at the kernel
sudo ufw enable
sudo ufw status verbose
```

(No rules for 80/443 are needed — Docker publishes them itself. If your
cloud provider has a security-group firewall, allow 22, 80, 443 there.)

## 2. SSH: keys only, no root login

> ⚠️ First make sure you can log in with an SSH **key** as a normal user
> with sudo rights, in a **second terminal**, before applying this — a
> password-only account gets locked out.

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
EOF
sudo sshd -t && sudo systemctl reload ssh
```

Install fail2ban so repeated SSH failures get banned automatically:

```bash
sudo apt install -y fail2ban
sudo systemctl enable --now fail2ban
```

## 3. Automatic security updates

The app image is updated by the ePHEM team, but the host OS and Docker
itself are yours to patch. On Debian and Ubuntu, `bash setup.sh` (Server
deploy) asks about it and sets it up, and so does `bash manage.sh`,
Maintenance (m), then a; the same thing by hand:

```bash
bash scripts/host-updates.sh apply     # asks for sudo
bash scripts/host-updates.sh status    # what is in force, next run, last runs
```

What it does:

- The system's own updater (`unattended-upgrades`) installs the
  distribution's security updates every night, one hour before the restart
  time.
- When an update needs a restart (a new kernel), the server restarts at
  `HOST_REBOOT_TIME` (`.env`, 04:00 when empty, **on the server's clock**:
  a server on UTC restarts at 07:00 in a country at UTC+3, so pick the time
  with that in mind). Nights with nothing that needs it: no restart.
- A restart takes ePHEM down for about two minutes. Docker starts with the
  server and starts every container again, the certificate renewal
  (certbot) included. `bash manage.sh`, Status and checks (v), then c
  (Security check) shows whether any container would stay down.

Docker Engine installed from Docker's own repository is not part of those
updates: a new Docker restarts every container, so run that one yourself at
a chosen moment (`sudo apt update && sudo apt upgrade`).

`bash scripts/host-updates.sh remove` takes the two settings files out
again. On other distributions, turn on the system's own automatic updates.

## 4. Correct time

TLS certificates and two-factor codes both fail confusingly on a server
with wrong time:

```bash
timedatectl    # "NTP service: active" must appear
```

## 5. Application-level settings (after the databases exist)

- **Disable the database manager:** set `ODOO_LIST_DB=False` in `.env` and
  re-run `bash setup.sh` (server mode offers this automatically). Until
  then, `/web/database/manager` can create, drop and **download** databases
  protected only by the master password. `setup.sh` generates that password
  at random on a new server and offers to replace a short one.
- **Two-factor authentication** for every admin user: *Preferences →
  Account Security → Enable two-factor authentication*. Make it policy.
- **Password policy:** install the `auth_password_policy` module and set a
  minimum length of 12+.
- **Signup stays invitation-only:** *Settings → General Settings →
  Customer Account → "On invitation"*.

## 5b. Docker on the host

Docker itself is part of the attack surface, and `docker` group membership is
root on the machine.

- Put only administrators in the `docker` group.
- Keep other people's accounts off this server where you can. Every account,
  with or without sudo, can read the command line of every process
  (`ps aux`) and can connect to the containers on their Docker addresses.
  `setup.sh` keeps the database password out of Odoo's command line for that
  reason (section 7 has the check); a secret typed as an argument of any
  command is visible the same way while that command runs.
- Never mount `/var/run/docker.sock` into a container (nothing in this stack
  does).
- Enable `live-restore` and default `no-new-privileges` in
  `/etc/docker/daemon.json`, then `sudo systemctl restart docker`:

  ```json
  { "live-restore": true, "no-new-privileges": true }
  ```
- Keep the host kernel and Docker patched (section 3). Containers share the
  host kernel, so a kernel escape is the one thing no container setting
  prevents.

## 5c. What the containers are held to

Set in `docker-compose.yml`; nothing to do, listed so you know what a
scanner will and will not find.

- **No capabilities** beyond the few the database and nginx need to start,
  and no way to gain new ones (`no-new-privileges`), on every container.
- **Read only images** for the database, nginx, the converter and its gate:
  nothing in them can be changed from inside. Their data and scratch space
  are volumes and memory. Odoo is not read only: it runs as an unprivileged
  user that cannot change the image either, and the documented quick patch
  (`pip install` as root for a module your own addons need) has to keep
  working.
- **A bound on processes** for every container, so one that multiplies
  without end cannot use up every process the server has.
- **When the server runs out of memory** the kernel stops an Odoo worker,
  which Odoo starts again, before the database or the SSH service.
- **Logs**: Odoo and nginx keep 20 files of 50 MB each, the closed ones
  compressed (weeks on most servers). Read them with
  `docker compose logs --since 24h nginx`. They are gone when the container
  is removed (`docker compose down`), so for an incident copy them out first:
  `docker compose logs --no-color nginx > nginx.log`. For longer keeping,
  send them to another machine.

## 6. Backups that survive the server

`scripts/backup.sh` runs nightly via cron (README → Backups). Three
settings in `.env` decide whether those backups help you on a bad day:

- `BACKUP_AGE_RECIPIENT` — encrypts every snapshot; the private key stays
  off the server. Without it, dumps of health data sit on disk in plain
  text.
- `BACKUP_PING_URL` — a free healthchecks.io / Uptime Kuma check that
  alerts you when backups **stop** arriving.
- Copy snapshots **off the server** (rclone to object storage, a second
  machine, a regional hub). A backup on the same disk dies with the disk.

Rehearse a restore at least once — a backup that has never been restored
is not yet known to work.

## 7. Verify

```bash
# Public listeners: expect sshd (22) and docker-proxy (80, 443) ONLY.
# 8069/8072/5432 must NOT appear on 0.0.0.0 — loopback or absent is correct.
# Proxy mode: 8069 and 8072 on PROXY_BIND_HOST only, no 80/443.
sudo ss -tlnp
# Proxy mode: only the proxy machine may reach them (expect a ✓ line and two
# rules naming PROXY_BIND_HOST)
bash scripts/proxy-firewall.sh status

# The database password is not in the process list (expect 0; otherwise
# run bash setup.sh again, it rewrites odoo.conf)
ps aux | grep '[o]doo' | grep -c -- --db_password

# The app's database role must not be a superuser (expect superuser=f)
docker compose exec db psql -U odoo -d postgres -c \
  "SELECT rolname, rolsuper FROM pg_roles WHERE rolname = 'odoo';"

# Nobody gets a certificate for a name that is not yours (expect a failed
# handshake, no certificate printed), nor by IP address
openssl s_client -connect YOUR.DOMAIN:443 -servername not-ours.example </dev/null 2>&1 | grep -c 'BEGIN CERTIFICATE'   # 0
openssl s_client -connect YOUR.DOMAIN:443 -noservername </dev/null 2>&1 | grep -c 'BEGIN CERTIFICATE'                  # 0

# The session cookie is Secure and HttpOnly (expect both words)
curl -s -D - -o /dev/null https://YOUR.DOMAIN/web/login | grep -i '^set-cookie: session_id'

# Everything this stack can verify about itself, in one place
bash manage.sh        # v (Status and checks), then c (Security check)

# RPC endpoints blocked (expect 403, unless you opened them for this domain
# or your address in manage.sh, Web access (w), then p), database manager throttled/disabled
curl -s -o /dev/null -w '%{http_code}\n' https://YOUR.DOMAIN/xmlrpc/2/common
curl -s -o /dev/null -w '%{http_code}\n' https://YOUR.DOMAIN/web/database/manager

# Login throttle: repeated POSTs must start returning 429
for i in {1..40}; do curl -s -o /dev/null -w '%{http_code} ' -X POST https://YOUR.DOMAIN/web/login; done; echo

# A recent backup exists and (if configured) is encrypted
ls -lh backups/ | tail
```
