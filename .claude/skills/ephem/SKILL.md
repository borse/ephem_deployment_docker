---
name: ephem
description: Work on the ePHEM developer dev stack (Odoo 18). Three instances run side by side — instance N maps to the odcaN addons tree, odoo-N.conf, database ephem_N, container ephem-N (N = 1, 2 or 3). Use whenever the task targets an instance: editing/updating/installing modules under odca1/odca2/odca3, restarting or tailing logs, running an odoo shell, or checking URLs/ports.
---

# ePHEM dev instances

This is a **developer deployment environment for ePHEM**, which is built on
**Odoo 18**. The local multi-instance dev stack (`scripts/dev-instances.sh`)
runs **three instances side by side** against one shared Postgres (`ephem-db`)
but with separate databases. All commands run from the repo root
`/home/ephem/ephem-deploy`.

## Instance map (the core correspondence)

There are 3 instances: **odca1, odca2, odca3**. Each one lines up across its
addons tree, its config file, its database, and its container:

| Instance | Addons tree | Config file  | Database  | Container |
|----------|-------------|--------------|-----------|-----------|
| odca1    | `odca1/`    | `odoo-1.conf`| `ephem_1` | `ephem-1` |
| odca2    | `odca2/`    | `odoo-2.conf`| `ephem_2` | `ephem-2` |
| odca3    | `odca3/`    | `odoo-3.conf`| `ephem_3` | `ephem-3` |

So `odca1 ↔ odoo-1.conf ↔ ephem_1`, `odca2 ↔ odoo-2.conf ↔ ephem_2`,
`odca3 ↔ odoo-3.conf ↔ ephem_3`. Substitute the instance number for `N`
everywhere below.

| Thing (instance N)  | Value |
|---------------------|-------|
| Addons tree         | `odcaN/` |
| Config file         | `odoo-N.conf` (auto-generated — do **not** commit) |
| Database            | `ephem_N` (pinned via `dbfilter = ^ephem_N$`) |
| Container           | `ephem-N` |
| Web URL             | http://localhost:80N0 |
| Longpolling/gevent  | 80N2 |
| Odoo version        | 18 |
| DB container        | `ephem-db` (host `db`, user `odoo`) |
| Odoo master pwd     | `9090` (from `odoo-N.conf`) |
| Web login           | `admin` / `admin` |

All three containers mount ports 8069/8072 internally; only the host port
differs (instance N → 80N0 / 80N2). Inside the container the config lives at
`/etc/odoo/odoo.conf` and addons at `/mnt/extra-addons`.

Each `odcaN/` tree is its own git checkout and may sit on a different branch —
check with `git -C odcaN branch --show-current` when it matters.

## Which instance?

The user declares the instance at the **start of the session** ("this session
use odca2", "work on instance 1", etc.). That choice holds for the whole
session. If no instance has been declared yet, **ask before touching
anything**; never guess.

## Everyday workflow — restart / update / tail logs

Driven by `scripts/dev-logs.sh` with the instance number `N` as the first arg.
From WSL this is the script at
`\\wsl.localhost\Ubuntu\home\ephem\ephem-deploy\scripts\dev-logs.sh`, run as a
PyCharm Shell-Script run config (or from the shell). Anything after the instance
number is forwarded to a one-shot `odoo …` run (auto-adds `-d ephem_N` and
`--stop-after-init`), after which the server restarts and logs are tailed.

The first arg is the instance; the rest are odoo flags. For example
`1 -u eoc_base,eoc_signals` loads database **ephem_1** (instance **odca1**) and
**updates** the `eoc_base` and `eoc_signals` modules, then restarts + tails.

```bash
# Just restart instance N and follow its colored logs:
bash scripts/dev-logs.sh N

# Update one or more modules on instance 1 (ephem_1 / odca1), then restart + tail:
bash scripts/dev-logs.sh 1 -u eoc_base,eoc_signals

# Install a new module on instance N, then restart + tail:
bash scripts/dev-logs.sh N -i my_new_module

# Forward extra odoo flags (e.g. force xml dev mode):
bash scripts/dev-logs.sh N -u eoc_base --dev=xml
```

Stop the run to detach from the log tail — the container keeps running.

Reminder (from project memory): frontend/asset edits only show up with
`dev_mode=…,assets` (already set in the generated configs) and often a restart;
translation changes need `--i18n-overwrite` on the update.

## Managing the stack

```bash
bash scripts/dev-instances.sh up 1 2 3   # (re)generate + start instances
bash scripts/dev-instances.sh status     # ports + URLs + health
bash scripts/dev-instances.sh logs N     # follow instance N
bash scripts/dev-instances.sh down       # stop, keep data
bash scripts/dev-instances.sh down -v    # stop + wipe DB/filestore
```

## Odoo shell against instance N

Run inside the container, pointing at the shared Postgres explicitly (creds live
in `.env`: `POSTGRES_USER=odoo`, `POSTGRES_PASSWORD` = the DB password):

```bash
docker exec -it ephem-N odoo shell -d ephem_N \
  --db_host db --db_user odoo --db_password "$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)" \
  --no-http
```

## Editing modules

Edit files directly under `odcaN/<module>/`. The generated configs run
`dev_mode = reload,qweb,werkzeug,xml,assets` with `workers = 0`, so Python
reloads on change; XML/assets usually need the `-u <module>` one-shot above (or
a restart) to take effect.

## Commit discipline (default working rule)

Leave edits **uncommitted** by default. Do not `git commit` the changes you make
in response to a prompt.

The user reviews changes one prompt behind. So on each new prompt:

1. If the user signals they liked the **previous** change ("okay", "good",
   "super", "looks right", etc.), **commit that previous, already-reviewed
   change now** — a focused commit covering only those files.
2. Make the **new** change requested by the current prompt, and **leave it
   uncommitted** for the user to review next time.

In short: at any moment the working tree holds one unreviewed change; a prompt's
approval is the trigger to commit the prior one. Never bundle the just-made
change into the commit. If it's ambiguous whether a message is approval of the
last change vs. a new request, ask before committing.
