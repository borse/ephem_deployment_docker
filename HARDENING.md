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
  modes bind to `127.0.0.1` for exactly this reason.
- ufw still fully protects everything that is *not* Docker: use it for SSH.

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
itself are yours to patch:

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades    # answer "Yes"
```

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
  protected only by the master password.
- **Two-factor authentication** for every admin user: *Preferences →
  Account Security → Enable two-factor authentication*. Make it policy.
- **Password policy:** install the `auth_password_policy` module and set a
  minimum length of 12+.
- **Signup stays invitation-only:** *Settings → General Settings →
  Customer Account → "On invitation"*.

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
sudo ss -tlnp

# The app's database role must not be a superuser (expect superuser=f)
docker compose exec db psql -U odoo -d postgres -c \
  "SELECT rolname, rolsuper FROM pg_roles WHERE rolname = 'odoo';"

# RPC endpoints blocked (expect 403, unless you allow-listed an address via
# manage.sh → 11 → 4), database manager throttled/disabled
curl -s -o /dev/null -w '%{http_code}\n' https://YOUR.DOMAIN/xmlrpc/2/common
curl -s -o /dev/null -w '%{http_code}\n' https://YOUR.DOMAIN/web/database/manager

# Login throttle: repeated POSTs must start returning 429
for i in {1..40}; do curl -s -o /dev/null -w '%{http_code} ' -X POST https://YOUR.DOMAIN/web/login; done; echo

# A recent backup exists and (if configured) is encrypted
ls -lh backups/ | tail
```
