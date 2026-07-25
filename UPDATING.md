# Updating an Existing Server (July 2026 fixes)

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
