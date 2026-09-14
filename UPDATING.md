# Updating an Existing Server (September 2026 local basemap)

This update lets a server draw its maps from its own copy of its area instead
of OpenFreeMap. It is opt in: a server that never downloads a basemap keeps
its maps exactly as they are. Applying the update takes a few minutes and one
short restart of Odoo and nginx; no data is touched. Apply the September 2026
addons layout update below first if this server has not had it.

What it delivers:

1. **A `basemaps/` folder** next to `addons/`, mounted read only into Odoo
   (`/mnt/basemaps`) and nginx (`/srv/basemaps`). nginx serves it at
   `/ephem/basemap/`, so map tiles never queue behind Odoo requests.
2. **`bash manage.sh` → 11) Advanced → 6) Local basemap**, which downloads a
   country, several countries or a WHO region from the Protomaps daily build
   (OpenStreetMap data, no key, no account) and points a database at it, or
   back to OpenFreeMap. It shows the size before downloading. For example:
   Yemen 176 MB, Iraq 455 MB, Nigeria 1.3 GB at full street detail, about an
   eighth of that with towns and main roads only.
3. **Why a country would opt in:** no outside request limit however many
   staff use the maps, and a real basemap in a training room with no internet.

## Steps (run on each server)

```bash
cd ~/ephem-deploy

# 1. Back up first
bash scripts/backup.sh

# 2. Get the changes and let setup create basemaps/ and recreate the
#    containers with the new mount (answer the prompts as last time)
git pull
bash setup.sh              # choose 1) Server deploy

# 3. Only when this country wants a local basemap
bash manage.sh             # 11) Advanced -> 6) Local basemap -> 1) Download
#    type the country code (YE), or several (YE,SA,OM), or a WHO region,
#    check the size it prints, confirm, then let it switch the database:
#    it restarts Odoo
```

## Verify afterwards

- `docker compose exec odoo ls /mnt/basemaps` and
  `docker compose exec nginx ls /srv/basemaps` both list the file.
- Open a map (a signal or incident form, Health Facilities): the credit at
  the bottom names Protomaps instead of OpenFreeMap.
- Back to OpenFreeMap at any time: the same menu, 2) Choose the basemap a
  database uses, 0) none.

A basemap is not in the backups (it downloads again in minutes). Refresh it
every few months by downloading again and switching the database to the new
file, then delete the old one from the same menu.

---

# Previous update (September 2026 addons layout)

This update changes where the ePHEM code lives on the server. Apply it on
each server: about five minutes, one short restart of Odoo, no data is
touched.

What it delivers:

1. **A parent addons folder.** Odoo mounts `addons/`, and the ePHEM clone
   lives inside it as `addons/ePHEM-core/`. Before this update the clone was
   the mounted folder itself (`custom-addons/`).
2. **More repositories without re-running setup.** `bash manage.sh` → 5)
   Addons → 3) Add a source clones another repository next to `ePHEM-core`,
   with its own deploy key, and puts it on the addons path. The same menu
   pulls every source, switches a branch, removes or renames a source.
3. **A safe move of existing installs.** `setup.sh` renames the folder, moves
   the clone one level down, regenerates `odoo.conf` and recreates the Odoo
   container so it sees the new place. The deploy key, the ssh alias and the
   remote inside the clone are untouched.

## Steps (run on each server)

```bash
cd ~/ephem-deploy          # or wherever the repo is cloned

# 1. Back up first, as before any change on production
bash scripts/backup.sh

# 2. Get the changes, then go STRAIGHT to setup. Do not run any
#    docker compose command in between: the compose file now mounts
#    ./addons, and an early "up -d" would hand Odoo an empty folder
#    until setup fixes it.
git pull
bash setup.sh              # choose 1) Server deploy

# 3. Answer the prompts conservatively:
#      "Pull updates now?" for the addons   -> N, unless you want a code
#                                              update in the same window
#                                              (a pull needs step 5)
#      "Check for Odoo image updates?"      -> N, unless intended
#      the database manager prompt          -> as before

# 4. Verify
docker compose logs --tail=100 odoo | grep "addons paths"
#    must list /mnt/extra-addons/ePHEM-core
bash manage.sh             # 1) Status shows the Addons table with ePHEM-core
#    then open the site in the browser

# 5. ONLY if you pulled new addon commits in step 3
bash scripts/update-modules.sh --auto
```

Setup prints what it moved:

```
  ✓ custom-addons/ renamed to addons/
  ✓ addons/ was the ePHEM clone itself: moved into addons/ePHEM-core/ (nothing deleted)
```

**If the site answers 502 Bad Gateway afterwards**, restart nginx:

```bash
docker compose restart nginx
```

nginx resolves Odoo's address once, when it starts. Recreating the Odoo
container gives it a new address, and nginx keeps sending requests to the
old one. Setup restarts nginx by itself when it has recreated the container
(added the day after the first server was migrated), and so does the app
image update in the menu; a server that pulled the scripts before that fix
needs the one command above.

The move itself needs no module update: the code did not change, only its
folder. Expect roughly a minute of downtime while the container is
recreated and Odoo loads.

## Verify afterwards

- `ls addons/` shows `ePHEM-core`, and `custom-addons/` is gone.
- `grep addons_path odoo.conf` reads
  `/mnt/extra-addons/ePHEM-core,/usr/lib/python3/dist-packages/odoo/addons`.
- `docker ps` shows db, odoo (ephem-app), nginx and certbot all `Up`.
- The site loads and the ePHEM apps are still installed.

## If something looks wrong

Check out the previous deploy commit, move the clone back, and re-run
setup; the old scripts regenerate the old config and mount.

```bash
git checkout 3a41909 -- .
mv addons/ePHEM-core custom-addons && rmdir addons
bash setup.sh              # choose 1) Server deploy
```

## Adding a repository later

```bash
bash manage.sh             # 5) Addons -> 3) Add a source
```

It asks for the repository, the folder name, the branch (defaults to the
one ePHEM-core is on) and how the server reaches it. On a server the default
is a deploy key made for that one repository: the menu prints the key, you
add it under the repository's Settings → Deploy keys (or send it to the
ePHEM team for an ePHEM repository), then run the same menu item again with
the same repository and folder name. The key is kept and reused. After the
clone the menu rewrites the addons path and offers the module update.

---

# Previous update (August 2026 hardening)

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
