# Windows machines (WSL): ePHEM comes back after Windows starts (November 2026)

For every install inside WSL with Docker Desktop: developer machines, demo
and training laptops. Linux servers and Macs are not affected.

What was wrong: when Docker Desktop starts (Windows sign in, opened by hand,
or its own restart) it starts the containers about two seconds before Ubuntu
shares the project files with it. Odoo and nginx mount a single config file,
fail before they run (`Exited (127)`, "not a directory ... odoo.conf"), and
Docker never retries that kind of failure. ePHEM stayed down until someone
started it, although nothing was broken.

What changes:

1. **A start-up helper** (`scripts/dev-autostart.sh --install`): a small
   service in Ubuntu that starts those containers again each time Docker
   comes up. It never recreates or updates anything. `setup.sh` offers it,
   and the home screen of `bash manage.sh` says when it is missing.
2. **Starting a refused container keeps it as it is.** The menu's start and
   `scripts/dev-logs.sh` used to recreate any container Docker had refused,
   which rebuilt it from the compose files checked out at that moment. They
   now try a plain start first and recreate only when Docker still refuses
   (its config file was replaced).

## Steps (once per Windows machine)

```bash
cd ~/ephem-deploy
git pull --ff-only
bash scripts/dev-autostart.sh --install    # or: bash manage.sh, m, then s
```

It asks for your sudo password once. It needs systemd in WSL; when that is
off, the script prints the two lines to add to `/etc/wsl.conf` and the
`wsl --shutdown` that applies them.

## Verify afterwards

```bash
bash scripts/dev-autostart.sh --status     # Installed and active
```

After the next Windows start, `journalctl -u ephem-autostart` shows which
containers it started, if any.

## Rolling back

```bash
bash scripts/dev-autostart.sh --uninstall
```

# Updating an Existing Server (November 2026: after the security test)

Code and configuration only: no new image, no data, no module update.
**Take this one soon.** Item 1 is a way round a protection every server with
nginx relies on, found by attacking a test server from another machine.

What changes:

1. **The RPC endpoints are blocked under a language code as well.** nginx
   refused `/xmlrpc` and `/jsonrpc`, but Odoo answers the same endpoints as
   `/en/xmlrpc/2/common` or `/en/jsonrpc` in every database that has the
   portal or website app, which is every ePHEM database. A blocked server
   took passwords that way, four guesses a second from one address, and
   Odoo's own limit on failed logins does not apply to these endpoints.
   Setup writes the nginx config again with the fix. **Proxy mode:** the
   block lives on the proxy machine, so copy `nginx/proxy/DOMAIN.conf` there
   again and reload its nginx; until then that server is still open this way.
2. **The database manager is covered the same way, and closed at nginx once
   it is disabled.** Its limit of 10 requests a minute did not apply to
   `/en/web/database/...`. And with `ODOO_LIST_DB=False` Odoo refused every
   action but still served the page and its forms, which is what a scanner
   reports: nginx now answers 403 for all of it. Creating a database from
   `bash manage.sh` now ends by offering to disable the manager, instead of
   leaving that to the next run of setup. In proxy mode the manager was
   meant to be closed outright and was reachable under a language code:
   same fix, same file to copy.
3. **Live updates cannot be taken down by one address.** Every open browser
   holds one connection to `/websocket`, and Odoo serves them all from one
   process that could hold about 340 (Docker gives a process 1024 open files).
   One machine opening that many, logged in or not, stopped live updates for
   everyone. nginx now lets one address hold 200, and the Odoo container may
   hold 65536 files, so a few hundred users are no longer the ceiling either.
4. **Proxy mode: the firewall is there before Odoo is, and stays.** Its unit
   ran after Docker and took its rules out when it stopped, so Odoo answered
   any machine for a moment at every boot, every shutdown and every Docker
   restart (a machine that should have been refused got an answer in the
   test). The rules now go in before Docker starts and only `remove` takes
   them out. A second way in is shut too: a machine on the same network
   segment could send packets for the container's own address through the
   server, which Docker before version 28 lets through to a published port.
   Setup applies both when it runs.
5. **A database with a crafted name can no longer break the nightly backup.**
   The application's database role may create databases. One named
   `../../x` made `scripts/backup.sh` write its dump outside `backups/`, and
   one named `--version` stopped the run before the filestore was saved.
   Such a database is now skipped out loud, everything else is saved, and
   the run ends as failed, so the monitor is not pinged.
6. **Every cookie is Secure and says SameSite=Lax** (HTTPS). Odoo sets
   neither; the session cookie already had Secure and HttpOnly from nginx,
   the others had nothing.
7. **Port 80 sends only our own names on to HTTPS.** The redirect repeated
   whatever name a request carried. A request by IP address or under a name
   this server does not serve now gets no answer (the Let's Encrypt check
   still does).
8. **`/website/info` is hidden** (it lists the installed apps and their
   versions to anyone when the website app is installed), also under a
   language code. It was hidden in proxy mode only.
9. **The certbot container is held like the others:** no capability, an
   image nothing can be changed in. It holds every private key and talks to
   the internet. Issuing, renewing and deleting certificates were run this
   way against a test ACME server before the change.
10. **The Security check asks the running server.** New lines: the RPC block
    and the closed database manager are requested through nginx itself, a
    config from before this fix is named, a container published beyond what
    the setup uses is reported, and so are a Docker older than 28, images of
    nginx, PostgreSQL and certbot older than two months, a clock that is not
    synchronised and SSH that accepts passwords.

## Steps (run on each server)

```bash
cd ~/ephem-deploy
git pull --ff-only
bash setup.sh          # Enter keeps every answer
```

Setup recreates the Odoo, nginx and certbot containers (about a minute
offline, no data is touched) and writes the nginx config again.

**Proxy mode, one more step, on the proxy machine:** install the new
`nginx/proxy/DOMAIN.conf` the way its first lines say, then
`sudo nginx -t && sudo systemctl reload nginx`.

## Verify afterwards

```bash
# The RPC block holds under a language code (expect 403 twice)
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://YOUR.DOMAIN/xmlrpc/2/common
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://YOUR.DOMAIN/en/xmlrpc/2/common

# The disabled database manager is refused by nginx (expect 403 twice)
curl -s -o /dev/null -w '%{http_code}\n' https://YOUR.DOMAIN/web/database/manager
curl -s -o /dev/null -w '%{http_code}\n' https://YOUR.DOMAIN/en/web/database/manager

# Cookies (expect Secure and SameSite=Lax on each line)
curl -s -D - -o /dev/null https://YOUR.DOMAIN/web/login | grep -i '^set-cookie'

# Open files for Odoo, and certbot held (expect 65536, then true [ALL])
docker inspect -f '{{range .HostConfig.Ulimits}}{{.Soft}}{{end}}' ephem-app
docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' ephem-certbot

# Proxy mode: the unit is the new one (expect a ✓ line)
bash scripts/proxy-firewall.sh check
```

`bash manage.sh`, Status and checks (`v`), then `c` (Security check) asks
the first four itself, on the server.

## Rolling back

Go back to the previous commit and run its `bash setup.sh`: it writes the
older nginx config and recreates the containers without the new limits.
Proxy mode: its `bash scripts/proxy-firewall.sh apply` puts the older unit
back. The certbot log volume (`certbot-log`) stays and does no harm.

# Updating an Existing Server (November 2026: second hardening pass)

Code and configuration only: no new image, no data, no module update.

What changes:

1. **The database password leaves Odoo's command line.** The app image
   handed it to Odoo as an argument (`--db_password`), and a command line can
   be read by every account on the server (`ps aux`); the database answers on
   its Docker address from the server itself, so any such account could read
   every database. `setup.sh` now writes an empty `db_password` line into
   `odoo.conf` and the container gets the password in its environment
   (`PGPASSWORD`), which only the container sees. `scripts/update-modules.sh`
   does the same for its update runs. In force once setup has run again.
2. **The login throttle also covers the language addresses.** With the
   website app, Odoo answers the login, password reset and sign up pages
   under a language code as well (`/fr/web/login`), and those went round the
   limit of 30 a minute. Setup re-renders the nginx config with the fix.
   Proxy mode: copy `nginx/proxy/DOMAIN.conf` to the proxy machine again.
3. **nginx is published on IPv4 only.** Published without an address, Docker
   also listened on the server's IPv6 addresses and relayed those connections
   itself, so nginx saw every IPv6 visitor as one address (Docker's own):
   one shared login throttle, that address in the logs, and a pass through
   any `NGINX_RPC_ALLOW` range that covers it. Visitors with both kinds of
   address fall back to IPv4 on their own. A server that people can ONLY
   reach over IPv6 must not take this update as it is: tell us first.
4. **`ODOO_LIST_DB` in another spelling no longer leaves the database
   manager open.** Odoo reads the words True and False only; `FALSE`, `0`,
   `no` or `off` counted as true. Setup rewrites them as `False`.
5. **A database created from the menu no longer starts as admin / admin.**
   `bash manage.sh`, Databases and backups (`d`), then `n` sets a random
   password for admin before Odoo is back, and shows it once.
6. Smaller: `.env` is private from the moment it is created; setup acts on
   the database role named in `POSTGRES_USER` instead of assuming `odoo`; on
   a server without python3 the master password is hashed with the app image.
7. **The server stays on one release of the app image.** Setup asks once and
   pins the release the server runs now (`EPHEM_IMAGE_TAG` in `.env`).
   Before, a server without the key followed `latest` and moved to a newer
   release at any download. Updates stay where they were: `bash manage.sh`,
   Update (`u`), then `i`.
8. **HTTPS in the same run.** On a server with nginx and no certificate
   yet, setup asks for the domain name and the email and gets the
   certificate at the end, instead of leaving `ssl-setup.sh` for later while
   the site already answers on plain HTTP.
9. **Direct access asks which address answers** (a Linux server), instead of
   publishing Odoo on every address without a word. **Behind a proxy with
   `PROXY_FROM` still empty**, setup shows the machines connected to Odoo and
   proposes the address when there is exactly one, so an open server closes
   at the next run.
10. **Without the converter, nothing downloads it.** At `OFFICE_CONVERTER=0`
    `docker compose up -d` still fetched the 600 MB image, and failed as a
    whole when it could not. The tools now write `OFFICE_PULL_POLICY=never`
    next to it.
11. **The database and nginx run on read only images, and every container
    has a bound on its processes.** When the server runs out of memory, an
    Odoo worker is stopped before the database. HARDENING.md, section 5c.
12. **Odoo and nginx keep about a gigabyte of logs each** (compressed on
    disk), instead of 30 MB: weeks instead of hours when something has to be
    looked into.

## Steps

```bash
cd ~/ephem-deploy
git pull --ff-only
bash setup.sh          # Enter keeps every answer
```

Setup recreates every container, the database included (its image becomes
read only): about a minute offline, and no data is touched. New questions on
this run: the domain for HTTPS when the server has no certificate yet, and
the release to stay on.

One habit changes: files can no longer be copied or written into the
database container (`docker cp`, `pg_dump -f /tmp/...`): Docker refuses,
"container rootfs is marked read-only". Feed them through instead:
`docker compose exec -T db psql -U odoo -d NAME < file.sql`, and
`docker compose exec -T db pg_dump -U odoo NAME > file.sql`.

## Verify afterwards

```bash
# The database password is not in the process list (expect 0)
ps aux | grep '[o]doo' | grep -c -- --db_password

# nginx listens on IPv4 only (expect 0.0.0.0:80 and 0.0.0.0:443, no [::])
sudo ss -tlnp | grep -E ':(80|443) '

# The throttle under a language code: 429 must appear
for i in {1..40}; do curl -s -o /dev/null -w '%{http_code} ' -X POST https://YOUR.DOMAIN/fr/web/login; done; echo

# Read only images and process bounds in force (expect true and a number)
docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.PidsLimit}}' ephem-db ephem-nginx

# The release this server stays on (expect a number, not latest)
grep '^EPHEM_IMAGE_TAG=' .env
```

`bash manage.sh`, Status and checks (`v`), then `c` (Security check) has a
line for the first one.

## Rolling back

Go back to the previous commit AND run its `bash setup.sh`: the older
`docker-compose.yml` does not hand the password over in the environment, so
with the empty `db_password` line still in `odoo.conf` Odoo would not start
(its log says "Missing required database parameters"). The older setup
writes the file without that line.

# Updating an Existing Server (November 2026: certificate renewal after a restart, automatic updates, new menu)

Code and configuration only: no new image, no data, no module update.

What changes:

1. **The certificate renewal comes back after a restart of the server**
   (servers with `SERVER_ACCESS=nginx`). The `certbot` container was the only
   one without a restart policy: after a reboot it stayed down, nothing
   looked broken, and the certificates ran out some weeks later. Check a
   server that was restarted since its last `docker compose up -d`:
   `docker ps` must list `ephem-certbot`.
2. **The server can install its own security updates** (Debian and Ubuntu).
   `bash setup.sh` asks; with yes, updates install every night and the server
   restarts at the chosen time (04:00 by default, on the server's clock) on
   the nights an update needs it. HARDENING.md, section 3.
3. **`bash manage.sh` is the new menu.** Numbers are places (repositories,
   databases) and letters are actions: `u` update, `d` databases and backups,
   `w` web access, `m` maintenance, `v` status and checks, `h` help. The
   numbered menu still opens with `bash manage_old.sh`, and that file has to
   stay: the new menu loads the work itself from it. Both have a screen for
   the automatic updates (Maintenance, then `a`; old menu: Advanced, 9).

## Steps

```bash
cd ~/ephem-deploy
git pull --ff-only

# 1. Recreates the certbot container with its restart policy; the other
#    containers are not touched.
docker compose up -d

# 2. Automatic updates: answer the new question in setup, or directly
bash scripts/host-updates.sh apply      # asks for sudo
```

Servers reached directly or behind another machine's nginx
(`SERVER_ACCESS=direct` or `proxy`) have no certbot: step 2 only.

## Verify afterwards

```bash
docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' ephem-certbot   # unless-stopped
bash scripts/host-updates.sh status
```

`bash manage.sh`, Status and checks (`v`), then `c` (Security check) has the
same lines under "This server".

## Rolling back

`bash scripts/host-updates.sh remove` deletes the two settings files it
wrote; the restart policy has nothing to roll back.

# Updating an Existing Server (October 2026: nginx fixes, proxy mode)

Code and configuration only: no new image, no data, no module update.

What changes:

1. **nginx (servers with `SERVER_ACCESS=nginx`).** Each security header is
   sent once: Odoo sends `X-Frame-Options` and a `Content-Security-Policy`
   itself on some answers, and those came out twice. Odoo's own policy on
   files (`default-src 'none'`, which stops an uploaded HTML or SVG file from
   running scripts) is kept as it is. nginx gives up on connecting to Odoo
   after 10 seconds instead of hanging, every module's static files and the
   asset bundles stay out of the general rate limit (an office behind one
   address no longer meets a 429 on a first visit), and no other location
   can take a database manager URL.
2. **A third way to reach Odoo: behind an nginx on another machine**
   (`SERVER_ACCESS=proxy`, README → Mode 1). For servers where a ministry's
   own proxy holds the domain and the certificate. Until now such servers ran
   the direct choice, which means one Odoo process (`workers = 0`), no live
   updates through the proxy, and every user seen as the proxy's address.

## Steps

Every server:

```bash
cd ~/ephem-deploy
git pull
bash setup.sh          # 1) Server deploy, Enter keeps your access choice
```

On an nginx server setup re-renders `nginx/active.conf` with the fixes
(tested first, rolled back if nginx refuses it). Without a setup run, any
change in `bash manage.sh`, Web access (`w`), `u` or `p`, re-renders it too.

A **direct server behind another machine's nginx** moves to proxy mode in the
same run: choose **3** at "How will people reach ePHEM?", then give this
server's LAN address, the proxy machine's address and the domain. The proxy's
address may be left empty when it is not known: no firewall then, set
`PROXY_FROM` in `.env` later and run `bash scripts/proxy-firewall.sh apply`
(`detect` finds it once the proxy is in use). On a server that already runs
behind the proxy, Odoo's log shows it now (direct mode has `proxy_mode` off,
so every request comes from it):

```bash
docker logs --since 15m ephem-app 2>&1 | grep -oE 'werkzeug: [0-9.]+' | sort | uniq -c | sort -rn | head
```

Setup asks for sudo once (the firewall rule, when the address is set),
restarts Odoo with workers, and writes `nginx/proxy/DOMAIN.conf`. Then, on the proxy machine:

1. Copy that file and install it as its first lines say (back up the current
   site config outside `/etc/nginx` first).
2. `sudo nginx -t && sudo systemctl reload nginx`, then
   `sudo certbot renew --dry-run`.
3. In Odoo, Settings → Technical → System Parameters: `web.base.url` must be
   `https://DOMAIN`; add `web.base.url.freeze` = `True`.

Either machine can go first: the old proxy config keeps working against the
new Odoo (only the live updates stay broken until the new config is in), and
the new proxy config against the old Odoo (the live updates answer 502 until
setup has run).

## Verify afterwards

```bash
bash manage.sh          # v, then c (Security check): firewall and proxy_mode lines
bash scripts/proxy-firewall.sh status                                       # proxy mode
curl -s -o /dev/null -w '%{http_code}\n' https://DOMAIN/websocket/health    # 200
curl -s -o /dev/null -w '%{http_code}\n' https://DOMAIN/xmlrpc/2/common     # 403
```

## Rolling back

`git checkout` the previous commit and run `bash setup.sh` again with your old
access choice. Leaving proxy mode removes the firewall rule (it asks for sudo).

---

# Updating an Existing Server (October 2026: network hardening)

Code and configuration only: no new image, no data is touched, no module
update. Allow about 10 minutes. Odoo is offline for about a minute while its
container is recreated, and the database restarts once (short).

What changes:

1. **The office converter no longer shares a network with Odoo.** Odoo talks
   to a small relay, the **office gate** (`ephem-office-gate`, the nginx image
   you already have), and only the gate talks to the converter. A conversion
   is one request Odoo opens; the converted file comes back on that same
   connection. Before, a taken-over converter could reach Odoo's port
   directly, past nginx and its throttles.
2. **The containers are separated.** nginx shares a network with Odoo only
   (`edge`), the database with Odoo only, certbot has its own (`acme`).
3. **The database superuser can no longer log in over the network**
   (`db-config/pg_hba.conf`), and it gets a password of its own
   (`POSTGRES_ADMIN_PASSWORD`; before, it defaulted to the application's).
4. **Secrets.** `.env` becomes owner-only, `backups/` closed to other users,
   `odoo.conf` stores the Odoo master password as a hash, and `setup.sh`
   offers to replace a short master password with a random one.
5. **nginx.** A catch-all HTTPS server (connections by IP address or with an
   unknown name get no certificate; a forged `Host` header never reaches
   Odoo), TLS 1.2 limited to forward-secret AEAD ciphers, the session cookie
   always `Secure` and `HttpOnly`, three more response headers, slow-client
   timeouts, and the same login throttle on password reset and sign-up.
6. **ePHEM AI** reads the converter's reply with a size cap (addon code, comes
   with the next ePHEM-core pull).
7. **GitHub's SSH host keys** are accepted only when they match GitHub's
   published fingerprints.

## Steps (run on each server)

```bash
cd ~/ephem-deploy
git pull                # new: office-gate/, db-config/, scripts/ssh-hostkeys-lib.sh

# 1. Back up first (the database container restarts once)
bash scripts/backup.sh

# 2. Apply it. setup.sh generates the missing secrets, hashes the master
#    password, tightens file permissions, recreates the containers on their new
#    networks and re-renders nginx (tested first, rolled back if refused).
bash setup.sh           # 1) Server deploy, then your usual access choice
```

When it asks to replace a short `ODOO_ADMIN_PASSWORD`, answer Y and write the
new one down: it is printed once and kept in `.env`. Answering n keeps the old
one and the check below keeps warning about it.

## Verify afterwards

```bash
bash manage.sh          # v, then c (Security check): every line should show a tick
docker compose ps       # ephem-office-gate and ephem-office healthy, neither with a published port
```

By hand, if you want to see it:

```bash
# Odoo reaches the converter through the gate (expect b'ok')
docker compose exec odoo python3 -c "import urllib.request; print(urllib.request.urlopen('http://office-gate:2003/health', timeout=5).read())"
# ...and the converter cannot find Odoo (expect: Name or service not known)
docker compose exec office python3 -I -c "import socket; socket.gethostbyname('odoo')"
# the database superuser is refused over the network (expect: pg_hba.conf rejects connection)
docker compose exec odoo python3 -c "import os,psycopg2; psycopg2.connect(host='db', user='postgres', password=os.environ['PASSWORD'], dbname='postgres')"
```

Then upload an old `.doc`, `.ppt` or `.rtf` file to ePHEM AI: it converts as
before.

## Things to know

- **A server installed before August 2026** (the app role is the cluster
  superuser) still needs `scripts/migrate-db-cluster.sh`; `setup.sh` and the
  security check say so. Everything above works without it, but the
  superuser rule protects nothing there until the migration is done: on such
  a cluster the application's own role is the superuser.
- **Direct access servers** (`SERVER_ACCESS=direct`) pull the `nginx:alpine`
  image once, for the gate. They can also set `DIRECT_BIND_HOST` in `.env` to
  publish Odoo on one interface (a VPN or LAN address) instead of all of them.
- **Several tenants on one server:** the converter now handles one conversion
  at a time (`OFFICE_CONCURRENCY=1`), so two uploads never share its memory.
  A second waits up to 60 seconds. Raise it in `.env` only if every user of
  the server trusts the others.
- **Browsing to `https://SERVER_IP`** (no name) now fails on purpose. Use the
  domain; a monitor that checks by IP needs to send the domain as the server
  name.

## Rolling back

```bash
git log --oneline -8                      # find the commit before this update
git checkout <that commit> -- docker-compose.yml
docker compose up -d --remove-orphans     # removes the gate, puts Odoo back on one network
```

`.env` keeps its new secrets (they are valid for the old compose file too),
and `odoo.conf` keeps its hashed master password, which Odoo accepts in any
release. Run `bash setup.sh` afterwards to re-render nginx for the template
you rolled back to.

---

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
bash manage.sh        # u (Update), then i (App image only), version 1.0.5
                      # It checks that the office image exists for that version.
                      # By hand instead: EPHEM_IMAGE_TAG=1.0.5 in .env, then
                      #   docker compose pull && docker compose up -d
                      # (pulls both images, starts the ephem-office container)

# 3. New ePHEM code
bash manage.sh        # p (Pull the latest code), ePHEM-core
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
image of its own, `EPHEM_OFFICE_TAG=1.0.5` (the app image update in manage.sh sets it by
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
bash manage.sh        # u (Update), then i (App image only), version 1.0.3
                      # By hand instead: EPHEM_IMAGE_TAG=1.0.3 in .env, then
                      #   docker compose pull && docker compose up -d

# 3. New ePHEM code
bash manage.sh        # p (Pull the latest code), ePHEM-core
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
2. **`bash manage.sh`, Maintenance (`m`), then `g` (Local basemap)**, which downloads a
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
bash manage.sh             # m (Maintenance), g (Local basemap), then 1) Download
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
2. **More repositories without re-running setup.** `bash manage.sh`, then `+`
   (Add a repository) clones another repository next to `ePHEM-core`,
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
bash manage.sh             # the table on the home screen lists ePHEM-core
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
bash manage.sh             # + (Add a repository)
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
> `bash manage.sh`, Web access (`w`), then `p` (RPC endpoints). That writes
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
