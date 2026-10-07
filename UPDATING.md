# Updating an Existing Server (October 2026: two images, release 1.0.5)

This release moves LibreOffice out of the app image into a second container,
the office converter (`borrs/ephem-office`), which runs on an internal network
with no route out. App image 1.0.5 keeps the patched wkhtmltopdf (PDF reports
get their running headers, footers and page numbers back), pins every Python
package by hash, and adds pypdfium2 (ePHEM AI crops the charts of PDF reports)
and pypdf (uploads are compressed). The code update is large: every installed
module is updated. Allow about 30 minutes and one Odoo restart. No data is
removed; one migration repairs signal records, so take the backup first.

Code: ePHEM-core commits `1b38bedac` to `6412479b1` (branch
`18_national_dev_new_IAP_levels`). Images: `borrs/ephem:1.0.5` and
`borrs/ephem-office:1.0.5`, released together under one number.

What it delivers:

1. **ePHEM AI.** The pictures and charts of the material (PDF pages, slides,
   web pages) placed in the narrative with a caption; a progress panel while
   it works; the ePHEM AI button on a signal reads links and files the same
   way as the one on the kanban; old Office, RTF and OpenDocument files go
   through the office converter.
2. **Signals.** The discard paths that left a signal half discarded are
   closed and the affected records repaired (update log line
   `eoc_signals: outcome repair`); a decided signal keeps its type; the intake
   stage is "Potential Signal"; FYI and RFI notification types with the
   source links and files in the body; the duty officer's daily and the
   coordinator's weekly reports.
3. **Incidents.** The board grouped by activation level, faster M&E and Acute
   dashboards, 7-1-7 fixes, responses placed by the escalating officer's level.
4. **Health facilities.** HeRAMS baseline and daily status on one facility
   form, referrals with the Field Desk and the referral wall, the rebuilt EMT
   modules, Training Mode stories for them.
5. **Team Performance** with a PDF report, **ePHEM Documents** (the shared
   document repository), compressed uploads and attachments.

## Steps (run on each server)

```bash
cd ~/ephem-deploy
git pull              # brings the office service into docker-compose.yml

# 1. Back up every database and filestore
bash scripts/backup.sh

# 2. Images 1.0.5 (app + office converter)
bash manage.sh        # 4) Update the ePHEM app image, version 1.0.5
                      # It checks that the office image exists for that version.
                      # By hand instead: EPHEM_IMAGE_TAG=1.0.5 in .env, then
                      #   docker compose pull && docker compose up -d
                      # (pulls both images, starts the ephem-office container)

# 3. New ePHEM code
bash manage.sh        # 5) Addons, ePHEM-core, 1) Pull latest
                      # "Apply the new code now?": answer n, step 4 does it

# 4. Update every module on every database (Odoo restarts at the end)
bash scripts/update-modules.sh --auto
```

## After the update

- `docker compose ps` lists `ephem-office` as healthy, with no published port.
- `docker compose exec odoo wkhtmltopdf --version` prints
  `0.12.6.1 (with patched qt)`: a printed report shows its header and footer.
- `docker compose exec odoo python3 -c "import urllib.request; print(urllib.request.urlopen('http://office:2003/health', timeout=5).read())"`
  prints `b'ok'`: Odoo reaches the converter.
- `docker compose exec odoo soffice --version` now fails: LibreOffice is no
  longer in the app container, by design.
- The update log of `eoc_signals` carries one line `eoc_signals: outcome
  repair, N kept Relevant (...)` naming the repaired signals. A line
  `outcome repair left N signals ... for review` lists records the repair
  did not touch: send that list to the maintainers.

**Data leaving the server.** Unchanged: ePHEM AI sends the text and the
pictures of the documents, links and EIOS articles it reads to the configured
AI provider. LibreOffice now runs in its own container with no network at
all, no database access and no files but the one being converted.

## Servers without Docker (Odoo installed on the VM)

```bash
# New Python packages, in Odoo's environment
sudo -u odoo /opt/odoo/venv/bin/pip install pypdfium2==5.14.0 pypdf==6.19.0

# LibreOffice stays on the VM: without an office converter service, ePHEM AI
# converts with it directly, under the same limits.

# New code: pull the ePHEM-core clone listed in addons_path, then
sudo systemctl stop odoo18
sudo -u odoo /opt/odoo/venv/bin/python3 /opt/odoo/odoo18/odoo-bin \
    -c /etc/odoo/odoo18.conf -d DATABASE -u all --stop-after-init
sudo systemctl start odoo18
```

Repeat the update line for each database. Paths and the service name follow
the VM deployment guide; adjust them if the server differs.

## Rolling back

Image: set `EPHEM_IMAGE_TAG=1.0.3` in `.env` and, because 1.0.3 has no office
image of its own, `EPHEM_OFFICE_TAG=1.0.5` (manage.sh option 4 sets it by
itself when the chosen release has none), then
`docker compose pull && docker compose up -d`. Code: restore the backup from
step 1 together with the previous ePHEM-core commit (`d7e9ebf87`).

---

# Previous update (September 2026: EIOS and ePHEM AI, image 1.0.3)

This release changes the EIOS connector and ePHEM AI. It needs app image
1.0.3, which adds LibreOffice (headless) for document conversion, and an update
of three modules. Allow about 15 minutes and one Odoo restart. No data is
removed.

Code: ePHEM-core commits `2006f5930` to `d7e9ebf87` (branch
`18_national_dev_new_IAP_levels`). Image: `borrs/ephem:1.0.3`.

What it delivers:

1. **EIOS.** A **Fetch from EIOS** button (signals kanban and list) with a
   progress window. One fetch runs at a time, whether started by a user or by
   the schedule. New signals receive the pinning analyst, the countries, the
   source name and the source country, then ePHEM AI completes them:
   aetiology, onset date, states, health interfaces, title and narrative.
   Articles that were discarded no longer make the fetch fail.
2. **ePHEM AI, new signal.** PowerPoint and Excel files; old Office, RTF and
   OpenDocument files through LibreOffice; several signals from one document;
   a custom prompt; the expected number of signals (I don't know, one, or
   several) with aetiologies and countries of interest.
3. **Settings.** Signals settings: ePHEM AI on or off, and the language it
   writes in. EIOS settings: ePHEM AI enrichment on or off.
4. **My level.** Also lists the signals and incidents created or reported by
   users of the same level and area.

## Steps (run on each server)

```bash
cd ~/ephem-deploy
git pull

# 1. Back up every database and filestore
bash scripts/backup.sh

# 2. App image 1.0.3 (adds LibreOffice)
bash manage.sh        # 4) Update the ePHEM app image, version 1.0.3
                      # By hand instead: EPHEM_IMAGE_TAG=1.0.3 in .env, then
                      #   docker compose pull && docker compose up -d

# 3. New ePHEM code
bash manage.sh        # 5) Addons, ePHEM-core, 1) Pull latest
                      # "Apply the new code now?": answer n, step 4 does it

# 4. Update the modules on every database (Odoo restarts at the end)
bash scripts/update-modules.sh
                      # Modules: eoc_signals, eoc_ai, eoc_eios_connector
                      # Databases: all
```

Answering **Y** in step 3 instead updates every module on every database and
restarts Odoo. The result is the same; it takes longer.

## After the update

- `docker compose exec odoo soffice --headless --version` prints LibreOffice 24.2.
- **Settings, ePHEM AI:** a default AI provider with an API key. Without one,
  EIOS signals are created with EIOS data only and the connector log shows
  "ePHEM AI not configured".
- **Settings, EOC Signals:** ePHEM AI on, and ePHEM AI Language set (installed
  languages only).
- **Settings, EIOS Connector:** Enrich New Signals with ePHEM AI on (the default).
- **Settings, Technical, Scheduled Actions:** EIOS API Fetch and EIOS Fetch Run
  Worker are active.
- **Signals, Fetch from EIOS:** the progress window opens and the fetch completes.

Optional: **Settings, EIOS Connector, Refresh from EIOS** sets the source name
and source country of older EIOS signals. It runs in the background; start it
outside working hours.

**Data leaving the server.** ePHEM AI sends the text of the documents, links
and EIOS articles it reads to the configured AI provider. LibreOffice runs on
the server with no network access and no macros.

## Servers without Docker (Odoo installed on the VM)

```bash
# LibreOffice, headless
sudo apt-get install -y --no-install-recommends \
    libreoffice-writer-nogui libreoffice-impress-nogui libreoffice-calc-nogui

# New code: pull the ePHEM-core clone listed in addons_path, then
sudo systemctl stop odoo18
sudo -u odoo /opt/odoo/venv/bin/python3 /opt/odoo/odoo18/odoo-bin \
    -c /etc/odoo/odoo18.conf -d DATABASE \
    -u eoc_signals,eoc_ai,eoc_eios_connector --stop-after-init
sudo systemctl start odoo18
```

Repeat the update line for each database. Paths and the service name follow
the VM deployment guide; adjust them if the server differs.

## Rolling back

Image: set `EPHEM_IMAGE_TAG=1.0.2` in `.env`, then
`docker compose pull && docker compose up -d`. Without LibreOffice, old Office
and OpenDocument files are refused with a message; everything else works.
Code: restore the backup from step 1 together with the previous ePHEM-core
commit.

---

# Previous update (September 2026 odoo.conf leaves Git)

`odoo.conf` is generated on each server by `setup.sh` and edited there by
`manage.sh`, but an old developer copy of it was committed to Git by mistake.
Git still tracked it despite `.gitignore`, so any local edit (a database
filter, a routing option) blocked `git pull`. The repository no longer tracks
it. Nothing changes on the server itself: the file stays where it is, with its
content, and Odoo keeps reading it.

**Do the steps below BEFORE the first `git pull` that brings this change.**
A plain pull would either refuse (the server edited its `odoo.conf`) or
delete the file (it did not), and Odoo would start with no configuration on
its next restart: the container mounts that single file.

## Steps (run on each server, once)

```bash
cd ~/ephem-deploy

# 1. Keep a copy of the server's configuration
cp odoo.conf ~/odoo.conf.before-pull

# 2. Stop tracking it on this server too. The file stays on disk.
git rm --cached odoo.conf

# 3. Only if git status lists other local edits (for example
#    scripts/dev-logs.sh), put them aside so the pull can go through
git status
git stash push -m "server edits before pull" -- scripts/dev-logs.sh

# 4. Pull. --ff-only refuses instead of creating a merge on the server.
git config --global pull.ff only
git pull

# 5. Check
ls -l odoo.conf        # still there, same size as the copy from step 1
git status             # odoo.conf must no longer be listed
```

No restart is needed. If `git stash show -p` in step 3 holds something the
new version of the file lacks, bring it back with `git stash pop`, otherwise
`git stash drop`.

**The admin password in the old copy.** The committed file carried a real
`admin_passwd` value, and it stays readable in the Git history. Compare it
with the server's own: `git show 44cd8e3:odoo.conf | grep admin_passwd`
against `grep admin_passwd odoo.conf`. If they match, change the server's
database master password (`admin_passwd` in `odoo.conf`, then restart Odoo).

If `odoo.conf` ever needs restoring, copy it over the existing file
(`cp ~/odoo.conf.before-pull odoo.conf`) so the running container sees the
change; never move or replace the file.

---

# Previous update (September 2026 local basemap)

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
