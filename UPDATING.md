# Updating an Existing Server (August 2026 hardening)

This update hardens every production server. Apply it on each server —
about 10 minutes, no data is touched.

What it delivers:

1. **Least-privilege database role** — the app's `odoo` role loses its
   SUPERUSER rights (a compromised addon can no longer read/drop every
   database or run OS commands in the db container). New installs get this
   automatically. Existing servers need a **one-time migration during a
   short maintenance window** (`scripts/migrate-db-cluster.sh` — PostgreSQL
   cannot demote the user the cluster was initialized with, so the cluster
   is dumped, re-initialized and restored; a rollback copy is kept).
2. **RPC endpoints blocked** — `/xmlrpc` and `/jsonrpc` (the main
   credential-stuffing target; unused by the web client) now return 403.
3. **Login throttling** — repeated login POSTs are rate-limited (30/min
   per IP); normal page loads are never throttled.
4. **Encrypted, monitored backups** — `scripts/backup.sh` can now encrypt
   snapshots with `age` and ping a healthcheck URL, so you learn when
   backups stop working.
5. **Container hardening** — dropped Linux capabilities,
   `no-new-privileges`, log rotation on all containers.

## Steps (run on each server)

```bash
cd ~/ephem-deploy          # or wherever the repo is cloned

# 1. Get the changes
git pull

# 2. (Recommended) add the new backup settings to .env — see .env.example:
#      BACKUP_AGE_RECIPIENT=age1...     (encrypt backups; sudo apt install -y age)
#      BACKUP_PING_URL=https://hc-ping.com/...   (alert when backups stop)
nano .env

# 3. Re-run setup — recreates the containers with the hardened settings
#    (all data is kept) and checks the database role. On servers installed
#    before August 2026 it will print a SECURITY notice — then, during a
#    short maintenance window (site is down a few minutes):
bash setup.sh              # choose 1) Server deploy
bash scripts/migrate-db-cluster.sh    # only if setup told you to; asks to confirm

# 4. Refresh the nginx config so the RPC block + login throttle are active
#    ── servers WITH HTTPS (you ran ssl-setup.sh before):
bash scripts/ssl-setup.sh YOUR.DOMAIN YOUR@EMAIL     # cert is reused, not re-issued
#    ── servers WITHOUT HTTPS (HTTP/IP only):
cp nginx/default.conf nginx/active.conf && docker compose restart nginx

# 5. Verify
docker compose exec db psql -U odoo -d postgres -c \
  "SELECT rolname, rolsuper FROM pg_roles WHERE rolname IN ('odoo','postgres');"
#   → odoo must show rolsuper = f, postgres = t
curl -s -o /dev/null -w '%{http_code}\n' https://YOUR.DOMAIN/xmlrpc/2/common   # → 403
bash scripts/backup.sh && ls -lh backups/ | tail
```

> **If anything using XML-RPC integrations calls INTO this server** (rare —
> outbound integrations from Odoo are unaffected), open RPC for that
> tenant's domain, or allow-list the caller's address server-wide, with
> `bash manage.sh` → 11) Advanced → 4) RPC endpoints. That writes
> `NGINX_RPC_OPEN` / `NGINX_RPC_ALLOW` to `.env` and re-renders nginx; an
> edit made by hand to `nginx/active.conf` is lost the next time a domain
> is added or removed.

Also work through **[HARDENING.md](HARDENING.md)** once per server — host
settings (SSH, ufw/Docker, automatic OS updates) that containers cannot
provide.

---

# Previous update (July 2026 fixes)

This update fixes four production issues. **Every server deployed between
April and July 2026 must apply it — those servers currently have NO database
backups** (`scripts/backup.sh` had been accidentally overwritten and did
nothing under cron).

What this update delivers:

1. **Backups work again** — `scripts/backup.sh` dumps every database +
   the filestore nightly again (cron setup unchanged, see README).
2. **HTTPS keeps working past cert renewal** — nginx now reloads renewed
   Let's Encrypt certificates automatically (previously it served the old
   cert until it expired at ~90 days).
3. **App version pinning** — production servers pin an image release in
   `.env` so `docker compose pull` never jumps versions silently.
4. **Database manager locked down** — the public `/web/database/manager`
   page is rate-limited, and setup disables it once your databases exist.

## Steps (run on each server, ~5 minutes, no data is touched)

```bash
cd ~/ephem-deploy          # or wherever the repo is cloned

# 1. Get the fixes
git pull

# 2. Pin the app version (add the line if it doesn't exist)
nano .env                  #   EPHEM_IMAGE_TAG=1.0.2

# 3. Recreate containers (picks up the nginx auto-reload; keeps all data)
docker compose up -d

# 4. Refresh the nginx config so the database-manager rate limit is active
#    ── servers WITH HTTPS (you ran ssl-setup.sh before):
bash scripts/ssl-setup.sh YOUR.DOMAIN YOUR@EMAIL     # cert is reused, not re-issued
#    ── servers WITHOUT HTTPS (HTTP/IP only):
cp nginx/default.conf nginx/active.conf && docker compose restart nginx

# 5. Re-run setup — it will offer to disable the database manager
#    (answer Y unless you still need to create databases)
bash setup.sh              # choose 1) Server deploy

# 6. Prove backups work NOW
bash scripts/backup.sh
ls -lh backups/            # you must see fresh .sql.gz files
```

## Verify afterwards

- `ls backups/` shows a `.sql.gz` per database with today's date.
- `crontab -l` still has the nightly backup line (see README → Backups).
- Site loads over HTTPS; `docker ps` shows db, odoo (ephem-app), nginx,
  certbot all `Up`.
- `https://YOUR.DOMAIN/web/database/manager` says the database manager is
  disabled (if you answered Y in step 5).

> **Reminder:** copy `backups/` off the server regularly — local backups
> are lost if the server dies.

## Rolling back an app update (new)

If a new release misbehaves, set the previous version in `.env`
(e.g. `EPHEM_IMAGE_TAG=1.0.0`), then:

```bash
docker compose pull && docker compose up -d
```
