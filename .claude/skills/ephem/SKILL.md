---
name: ephem
description: Work on the ePHEM dev instances (Odoo 18) — instance N maps to the odcaN addons tree, odoo-N.conf, database ephem_N, container ephem-N (N = 1, 2 or 3). Use whenever the task targets an instance: editing/updating/installing modules under odca1/odca2/odca3, restarting or tailing logs, running an odoo shell, or checking URLs/ports.
---

# ePHEM dev instances

ePHEM is the platform. The local multi-instance dev stack
(`scripts/dev-instances.sh`) runs instances **1 / 2 / 3** side by side against
one shared Postgres (`ephem-db`) but separate databases. All commands run from
the repo root `/home/ephem/ephem-deploy`.

## Which instance?

The user declares the instance at the **start of the session** ("this session
use odca2", "work on instance 1", etc.). That choice holds for the whole
session — substitute its number for `N` everywhere below. If no instance has
been declared yet, **ask before touching anything**; never guess.

## Instance N facts

| Thing | Value |
|-------|-------|
| Addons tree | `odcaN/` |
| Config file | `odoo-N.conf` (auto-generated — do **not** commit) |
| Container | `ephem-N` |
| Database | `ephem_N` (pinned via `dbfilter = ^ephem_N$`) |
| Web URL | http://localhost:80N0 |
| Longpolling/gevent | 80N2 |
| Odoo version | 18 |
| DB container | `ephem-db` (host `db`, user `odoo`) |
| Odoo master pwd | `9090` (from `odoo-N.conf`) |
| Web login | `admin` / `admin` |

Each `odcaN/` tree is its own git checkout and may sit on a different branch —
check with `git -C odcaN branch --show-current` when it matters (e.g. odca1/3
have run `18_national_dev_new_IAP_levels`, odca2 `18_national_dev_qira`).

All three instances mount container ports 8069/8072; only the host port differs
(instance N → 80N0 / 80N2). Inside the container the config lives at
`/etc/odoo/odoo.conf` and addons at `/mnt/extra-addons`.

## Everyday workflow — restart / update / tail logs

Use `scripts/dev-logs.sh` with the instance number `N` as the first arg.
Anything after it is forwarded to a one-shot `odoo …` run (auto-adds
`-d ephem_N` and `--stop-after-init`), after which the server restarts and logs
are tailed.

```bash
# Just restart instance N and follow its colored logs:
bash scripts/dev-logs.sh N

# Update one or more modules, then restart + tail:
bash scripts/dev-logs.sh N -u eoc_base,eoc_signals

# Install a new module, then restart + tail:
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

(Exception: a one-off, self-contained task the user explicitly asks to land — as
with the sender-policy cherry-picks — may be committed in the same turn.)

## Editing modules

Edit files directly under `odcaN/<module>/`. The generated configs run
`dev_mode = reload,qweb,werkzeug,xml,assets` with `workers = 0`, so Python
reloads on change; XML/assets usually need the `-u <module>` one-shot above (or
a restart) to take effect.
