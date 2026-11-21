# The ePHEM development environment

Two repositories make up a developer machine:

- **ephem-deploy**: the stack. `setup.sh` installs it, `manage.sh` is the menu
  for daily operations, `scripts/` holds the commands. You do not change it as
  part of feature work.
- **ePHEM** (`borse/ePHEM` on GitHub): the addons, `eoc_*`, `ephem_*` and
  `cmp_*`. `setup.sh` clones it into the stack. This is the repository you
  branch, commit and push.

The image `borrs/ephem` carries Odoo 18 Community and every Python package the
addons need. Odoo's own source is inside it at
`/usr/lib/python3/dist-packages/odoo`, read only.

---

## 1. The three layouts

### Docker, multi instance (Linux, WSL)

`bash setup.sh`, choose Developer, then Multi instance. Several Odoo servers
side by side, each with its own clone, branch, database and port:

| Instance | Folder (mounted) | ePHEM clone | Config | Database | Container | Service | Web | Live updates |
|---|---|---|---|---|---|---|---|---|
| 1 | `odca1/` | `odca1/ePHEM-core/` | `odoo-1.conf` | `ephem_1` | `ephem-1` | `odoo_1` | 8010 | 8012 |
| 2 | `odca2/` | `odca2/ePHEM-core/` | `odoo-2.conf` | `ephem_2` | `ephem-2` | `odoo_2` | 8020 | 8022 |
| 3 | `odca3/` | `odca3/ePHEM-core/` | `odoo-3.conf` | `ephem_3` | `ephem-3` | `odoo_3` | 8030 | 8032 |

- `odcaN/` is mounted read write at `/mnt/extra-addons` inside its container.
  It is a parent folder: the ePHEM clone is `odcaN/ePHEM-core/`, and any other
  addons repository added from `manage.sh` sits next to it. Run git inside
  `odcaN/ePHEM-core/`, never in `odcaN/` (not a repository).
- `odoo-N.conf` pins the instance to its database (`dbfilter=^ephem_N$`),
  runs `workers=0`, `log_level=debug` and
  `dev_mode=reload,qweb,werkzeug,xml,assets`.
- `.dev-instances` lists the instances; the position in that file sets the
  port (8010 plus 10 per position).
- One Postgres container, `ephem-db`, serves every instance (user `odoo`, the
  password is `POSTGRES_PASSWORD` in `.env`).
- `docker compose` must always get both files, or it resolves the single
  instance stack:
  `docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml restart odoo_1`.

### Docker, single instance

`bash setup.sh`, Developer, single layout. One server:

| Folder | ePHEM clone | Config | Database | Container | Service | Web |
|---|---|---|---|---|---|---|
| `addons/` | `addons/ePHEM-core/` | `odoo.conf` | the one you created in the browser | `ephem-app` | `odoo` | 8069 |

Commands take the database by name: `bash scripts/dev-logs.sh -u eoc_x -d mydb --no-follow`.

### macOS native

On a Mac, Developer mode offers **Native** (recommended) or Docker. Native runs
Odoo directly on macOS: Homebrew PostgreSQL 16, one Odoo 18.0 source and one
Python 3.12 environment in `~/Developer/ephem`. The mapping is the same as the
multi instance stack (instance N, `odcaN/`, port 80N0, database `ephem_N`,
`conf/odoo-N.conf`, `logs/odoo-N.log`), with two differences:

- each `odcaN/` is a **git worktree** of one clone, `~/Developer/ephem/ePHEM/`,
  on its own local branch `odcaN/<branch>` tracking `origin/<branch>`;
- the commands are `bash scripts/macos/dev.sh <verb> N ...`: `status`,
  `restart N`, `update N mod`, `install N mod`, `shell N`, `switch N branch`,
  `fetch`, `backup N`, `restore N`, `new`, `remove N`.

Each instance gets a generated `CLAUDE.md` (kept out of git) with its paths and
rules. Start the agent inside `~/Developer/ephem/odcaN`. Never run `git
worktree`, `git gc --prune` or `git stash drop` or `clear` there: the object
store and the stash are shared by every instance. The full guide is
`docs/macos-native-dev.md` in ephem-deploy.

### Credentials

Configs, `.env` and the database hold development credentials. They never go
into a commit, a document, a screenshot or a message. Read them from the file
when a command needs them; do not copy them anywhere.

---

## 2. dev-logs.sh in depth (Docker)

`scripts/dev-logs.sh [N] [-u mods | -i mods] [odoo args] [--no-follow]`

With `-u` or `-i` it stops the instance (to free database locks), runs a one
shot `docker compose run --rm --no-deps odoo_N odoo ... -d ephem_N
--stop-after-init`, starts the instance again (even when the one shot failed)
and then either tails the log or, with `--no-follow`, waits until Odoo answers
`/web/login` and returns. Extra arguments go to Odoo unchanged.

| Exit | Meaning |
|---|---|
| 0 | Odoo answers again |
| 1 | the container stopped, or kept answering 500 |
| 2 | no answer after `DEV_LOGS_WAIT_TIMEOUT` seconds (default 300) |
| 3 | another one shot is running on this instance: wait, do not force |

Give the tool call a generous timeout rather than wrapping it in `timeout`.
A one module update takes about 15 seconds end to end.

**Reading the result.** Exit 0 plus `Modules loaded.` or `Registry loaded`.
Then scan for `CRITICAL`, `Traceback` and `ERROR` lines that name your module.
Known noise that is not yours: `View error context` for a couple of old views,
walls of `Unexpected indentation` (docstrings), `no translation language
detected`, `Importing test framework`.

**Without dev-logs.sh** (when compose is broken):

```bash
PW=$(docker exec ephem-1 printenv PASSWORD)
docker exec ephem-1 odoo -c /etc/odoo/odoo.conf -d ephem_1 -u eoc_x \
  --db_host=db --db_user=odoo --db_password="$PW" --no-http --stop-after-init
docker restart ephem-1
```

`docker exec` skips the image entrypoint, so the database arguments must be
given explicitly or Odoo looks for a local socket and fails.

---

## 3. Shell and database

**Odoo shell** (Docker): pipe a script in, give the database arguments.

```bash
PW=$(docker exec ephem-1 printenv PASSWORD)
cat script.py | docker exec -i ephem-1 odoo shell -c /etc/odoo/odoo.conf \
  -d ephem_1 --db_host=db --db_user=odoo --db_password="$PW" --no-http
```

macOS: `bash scripts/macos/dev.sh shell N < script.py`.

- `env.user` there is the system user: it bypasses access rights but holds no
  group, so code that checks `has_group` behaves differently. To act as a real
  person: `env(user=env.ref('base.user_admin'))`, or the user under test.
- The shell never commits by itself. End a dry run with `env.cr.rollback()`;
  call `env.cr.commit()` only when the change is meant.
- A group change committed from a shell does not reach the running server's
  cache: restart the instance.
- Write scripts outside the repository.

**psql:** `docker exec ephem-db psql -U odoo -d ephem_1 -c "select id, name->>'en_US' from eoc_signal limit 5;"`.
Translatable columns are JSONB (`name->>'en_US'`). Name the columns you need;
never `select *` on tables that hold credentials.

---

## 4. Tests

- Tests live in `<module>/tests/`, imported from `tests/__init__.py`, and run
  only for modules updated or installed in the same run.
- `--test-tags /eoc_x` selects a module, `/eoc_x:TestClass.test_method` one
  test. Naming a module that is not in the `-u` list runs nothing, silently.
- With tests on, Odoo opens its HTTP server during loading. Add
  `--http-port=8099 --gevent-port=8098 --max-cron-threads=0` so it does not
  collide with the running instance.
- Verdict: no `FAIL:` or `ERROR:` line from `odoo.addons.<module>`, and a
  `odoo.tests.result` line with 0 failed and 0 errors.
- A database with Demo Mode on puts every new user on a default preset, which
  overwrites the level and roles a test gives. A test that creates users sets
  `self.env['ir.config_parameter'].set_param('eoc_demo_mode.active', 'False')`
  in `setUpClass` first.
- Before a pull request: `bash scripts/ci/run_module_tests.sh origin/18_ephem_2`
  from the clone. It installs the changed modules on a fresh database without
  demo data and runs their tests, exactly as the pull request check does. It
  needs Docker and the `borrs/ephem` image, also on a native Mac.
- The image ships no tests for Odoo's own modules; exercise core behaviour in
  a shell instead.
- A library installed with `pip` inside a running container is gone in the
  one shot test container (a fresh copy of the image). New Python
  dependencies go through the ePHEM team (they are added to the image).

---

## 5. Frontend and assets

- `dev_mode` includes `assets` on multi instance stacks, so a reload usually
  shows a JS, SCSS or OWL change. When it does not, `-u` the module and
  restart before debugging the code.
- **Never write a mixed unit `min()` or `max()` in SCSS** (`min(1400px,
  96vw)`): the SCSS compiler fails and the whole stylesheet bundle stops
  updating, while JS changes keep loading. Use a media query.
- **Right to left**: Odoo flips CSS for Arabic. Wrap what must not flip
  (Leaflet and similar) in `/*rtl:begin:ignore*/ ... /*rtl:end:ignore*/`,
  exactly that token.
- A menu's `web_icon` image is copied into the menu record when the module
  loads: after replacing the image, `-u` the module.

---

## 6. Working on a copy

Anything risky on data (a migration, a mass change, an import, a restore of
another branch's database) runs on a copy first:

```bash
docker exec ephem-db bash -c "createdb -U odoo ephem_1_copy && pg_dump -U odoo ephem_1 | psql -U odoo -q ephem_1_copy"
docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml run --rm --no-deps -T odoo_1 \
  odoo -d ephem_1_copy --db-filter='^ephem_1_copy$' -u eoc_x --stop-after-init
```

Copy the filestore too when attachments matter. Drop the copy afterwards.
The `--db-filter` matters: the instance config pins `ephem_N`, so without it
HTTP requests (and HTTP tests) are served by the real database.

---

## 7. When the stack misbehaves

| Symptom | Cause and fix |
|---|---|
| `psycopg2.OperationalError ... /var/run/postgresql/.s.PGSQL.5432` | `docker exec` without `--db_host`, `--db_user`, `--db_password` |
| a style change never shows, JS changes do | a SCSS compile error (often mixed unit `min()`), see section 5 |
| `Address already in use` in a test run | the test flags of section 4 are missing |
| exit 3 from dev-logs.sh | another one shot is running on that instance; wait |
| the instance container exited after the machine started | start it again: `docker start ephem-1` |
| `Module loading base failed ... already exist` after `-u all` | never `-u all` on a national database; update named modules |
| an update stops on a foreign key of a wizard's `_rel` table | orphan rows of a vacuumed wizard: delete them on that table, then update |
| a new dependency module is not found | it must be in the addons path; a new module in the same repository installs with the update |

Never run `docker compose down -v` or `dev-instances.sh down -v` unless asked
in so many words: it deletes every database and filestore of the stack.
