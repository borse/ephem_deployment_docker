# Native developer setup on macOS

On a Mac, developer mode can run Odoo straight on macOS instead of in Docker.
Docker Desktop runs containers in a Linux VM, and every file Odoo reads from
your addons folder crosses into that VM; natively the files are read at full
speed and a restart takes a couple of seconds.

This applies to **macOS only**. On Linux and under WSL nothing here is used and
developer mode is the Docker stack described in the [README](../README.md#mode-3--developer).

- [What you get](#what-you-get)
- [Install](#install)
- [Moving from the Docker developer stack](#moving-from-the-docker-developer-stack)
- [Layout](#layout)
- [Daily commands](#daily-commands)
- [Branches and worktrees](#branches-and-worktrees)
- [More repositories in an instance](#more-repositories-in-an-instance)
- [One coding agent per instance](#one-coding-agent-per-instance)
- [PyCharm](#pycharm)
- [Databases: create, back up, restore](#databases-create-back-up-restore)
- [Settings](#settings)
- [What matches the Docker image, and what does not](#what-matches-the-docker-image-and-what-does-not)
- [Docker next to it](#docker-next-to-it)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Removing it](#removing-it)

## What you get

| Instance | URL | Database | Folder | Config | Log |
|---|---|---|---|---|---|
| 1 | `http://localhost:8010` | `ephem_1` | `odca1/` (`ePHEM-core/` + repos) | `conf/odoo-1.conf` | `logs/odoo-1.log` |
| 2 | `http://localhost:8020` | `ephem_2` | `odca2/` | `conf/odoo-2.conf` | `logs/odoo-2.log` |
| 3 | `http://localhost:8030` | `ephem_3` | `odca3/` | `conf/odoo-3.conf` | `logs/odoo-3.log` |

The same ports and database names as the Docker multi-instance stack. Instance
N is always port `80N0` and database `ephem_N`; N goes from 1 to 9. All instances share one PostgreSQL 16 (a Homebrew service), one
Odoo 18.0 source tree and one Python 3.12 virtualenv.

## Install

```bash
cd ~/Developer/ephem_deployment_docker
bash setup.sh          # 3) Developer, then 1) Native (recommended on Mac)
```

`setup.sh` hands off to `scripts/macos/install.sh`, which can also be run
directly and run again at any time: every step looks first and only does what
is missing.

```bash
bash scripts/macos/install.sh                     # asks where, which instances, which branch
bash scripts/macos/install.sh --yes               # every default: ~/Developer/ephem, instances 1 2 3, 18_ephem_2
bash scripts/macos/install.sh --home ~/work/ephem --instances "1 2" --branch 18_national_main
bash scripts/macos/install.sh --no-instances      # tools only
bash scripts/macos/install.sh --update-odoo       # also pull the Odoo source
```

What it does, in order:

1. **Homebrew** (installs it when missing: Homebrew's own installer asks for
   your Mac password once), then `postgresql@16`, `uv`, `node`, `openldap`,
   `openssl@3`, `cairo`, `freetype` and `libmagic`.
2. **Rosetta**, on Apple Silicon: the patched wkhtmltopdf exists for Intel only.
3. **PostgreSQL 16** as a Homebrew service (it starts with the Mac), and the
   app role `odoo`: `LOGIN CREATEDB`, no superuser, the same role
   `db-init/01-app-role.sh` creates in the Docker stack.
4. The **Odoo 18.0 source** (latest commit only) and a **Python 3.12
   virtualenv** with Odoo's `requirements.txt` plus
   `scripts/macos/requirements-ephem.txt`.
5. **wkhtmltopdf 0.12.6 with patched Qt**, unpacked into `tools/` (checksum
   verified, no sudo), and **rtlcss** for right-to-left languages.
6. The **ePHEM clone**, then for each instance a worktree, a config, a
   `CLAUDE.md`, an empty database, and it starts them.

The script itself never calls `sudo` and never edits a shell profile: the
scripts find Homebrew in `/opt/homebrew` by themselves.

**bash.** macOS ships bash 3.2. The native scripts run on it. `setup.sh` and the
Docker menu need bash 4, so on a Mac `setup.sh` first looks for Homebrew's bash
and offers to install it (`brew install bash`); your Terminal's own shell is not
changed.

## Moving from the Docker developer stack

A Mac that already runs the developer instances in Docker (developer or
multi-instance mode) is offered the move when `bash manage.sh` opens:

```
y       Move to native now
n       Not now: the Docker menu (asked again next time)
never   Don't ask again on this Mac (later: bash scripts/macos/from-docker.sh)
```

The same move, run by hand:

```bash
bash scripts/macos/from-docker.sh --plan    # what would move, changes nothing
bash scripts/macos/from-docker.sh           # asks where, then moves
bash scripts/macos/from-docker.sh --home ~/work/ephem --yes
```

Docker instance `odcaX/` becomes native instance N: X itself when it is 1 to 9,
otherwise the first free number (the single-instance `addons/` becomes 1).

| What | Becomes |
|---|---|
| `odcaX/ePHEM-core` | a worktree of the native `ePHEM/` clone, on the same commit. Every local branch comes over as `odcaN/<branch>` (upstreams kept), with the commits never pushed, and the working files as they are: changed, staged, new, deleted, ignored. |
| other repositories in `odcaX/` | copied as they are (remote, branch, changes) |
| stashes | stay in the Docker copy (`git -C odcaX/ePHEM-core stash list`) |
| database `ephem_X` and its filestore | restored into `ephem_N` (`dev.sh restore`). When `ephem_N` already exists on the Mac you are asked first (default: keep it). |
| every other database in Docker | copied out and kept as a backup in `backups/from-docker/<name>/`: `bash scripts/macos/dev.sh restore N backups/from-docker/<name>` |
| the containers, volumes and images | stopped, not removed; removing them is offered once everything is done |

In single-instance mode with several databases, the move asks which one becomes
`ephem_1`; the others are kept as backups.

How the databases come out: `docker compose stop` stops the stack (the instance
ports are then free for the native ones), Postgres (`ephem-db`) alone is started
again, and each database is dumped with `pg_dump -Fc` and its filestore read off
the Odoo volume, into `backups/from-docker/<name>/` in the format of `dev.sh
backup`. Docker Desktop is started when it is not running (asked first); say no
and the databases stay in Docker, where running `from-docker.sh` again later
picks them up. The last question removes the stack
(`docker compose … down -v --rmi all`); it defaults to no, and says so when a
database could not be copied.

The native `ePHEM/` clone is made from a Docker clone (no full download, same
remote URL), then fetched from origin. The Docker folders are only read: they
stay where they are as a copy until you delete them. A move that stops halfway
(a failed download, Ctrl+C) leaves `.macos-from-docker` in the deployment repo;
`bash manage.sh` then offers to carry on, and every step that was done is
skipped (a database already copied out, or already restored, is not done
again). `MACOS_NATIVE_OFFER=never` in `.env` is what "never" writes.

## Layout

The deployment repo stays where it is. Everything else lives in the *native
home*, `~/Developer/ephem` unless you chose another folder:

```
~/Developer/ephem/
├── odoo/               Odoo source, branch 18.0 (read only for you)
├── venv/               Python 3.12 virtualenv, shared by every instance
├── ePHEM/              the main clone of borse/ePHEM: the base checkout
├── odca1/              instance 1, the same layout as the Docker developer stack:
│   ├── CLAUDE.md           for the coding agent of this instance (not in any repo)
│   ├── ePHEM-core/         a git worktree of ePHEM/
│   └── ePHEM_uganda/       any other repository of this instance (dev.sh repo add)
├── odca2/              instance 2
├── odca3/              instance 3
├── extra-addons/       addon repositories every instance uses, one subfolder each
├── tools/              wkhtmltox/ (patched wkhtmltopdf), node/ (rtlcss)
├── conf/
│   ├── native.env      settings and the database password (mode 600)
│   └── odoo-N.conf     one generated config per instance
├── data/N/             filestore and sessions of instance N
├── logs/odoo-N.log     its log
├── run/odoo-N.pid      its process
└── backups/            written by dev.sh backup
```

The deployment repo keeps one file about it, `.macos-native` (not in git),
which records where the native home is. `bash manage.sh` reads it.

A repository for **one** instance goes next to its `ePHEM-core/`: see
[More repositories in an instance](#more-repositories-in-an-instance). A
repository cloned into `extra-addons/NAME/` is added to the `addons_path` of
**every** instance by `bash scripts/macos/dev.sh conf N` (then restart).

Instances made before this layout had the worktree as `odcaN/` itself.
`bash scripts/macos/dev.sh migrate all` moves them (stop them first if PyCharm
runs one); `status` points out any that are left, and `install.sh` does it on
its next run.

## Daily commands

`bash manage.sh` opens the same menu as on Windows and Linux (the Docker
developer menu): the instances and their repositories in one table, numbered
`1`, `1.1`, `1.2`, `2`, … and the same keys. `r 2` restarts instance 2 and
follows its log, `s 3.2` switches the branch of repository 3.2, `+ 3` adds a
repository to instance 3, `3` opens instance 3, `d` the databases and backups,
`m` maintenance (add or remove an instance, the office converter, the
installer), `h` the list of keys. `bash manage.sh 3` opens instance 3 straight
away. Ctrl+C stops what is running (a log, an update) and returns to the menu.
It is `scripts/macos/menu.sh`, acting through the `dev.sh` commands below;
`bash scripts/macos/dev.sh menu-plain` is the older typed-command menu.

**Adding an instance** is `m` then `a` in that menu, or
`bash scripts/macos/dev.sh new`. It asks three things, then creates the
worktree, the config, the `CLAUDE.md` and the database, and starts it:

1. **Number**: Enter takes the lowest free one (up to 9).
2. **Branch**: Enter takes `18_ephem_2`; a full name is taken as it is; part
   of a name (`uganda`) lists the branches of origin that contain it, to pick
   by number; `?` lists them all. The list is fetched first.
3. **Database**: empty (module base only), a copy of another instance's
   database and filestore (that instance keeps running), or none for now.

`create N [BRANCH]` followed by `initdb N` does the same without questions.

**Removing an instance** is `m` then `k` in the menu, or
`bash scripts/macos/dev.sh remove N`. It lists what goes, offers a backup of
the database first, and asks you to type the database name:

- deleted: the database `ephem_N`, `data/N/` (filestore, sessions), the folder
  `odcaN/`, `conf/odoo-N.conf` and the log;
- kept: the backups, and every commit. A branch `odcaN/...` that holds commits
  origin does not have stays in the `ePHEM/` clone (`git -C ePHEM log
  odcaN/18_ephem_2`); one with nothing of its own is deleted with the instance;
- it stops, changing nothing, when `odcaN/` has uncommitted changes: commit
  them (they then stay on the branch) or pass `--force` to lose them.

### Ports

The port is not chosen and not stored: it follows from the instance number.

| Instance | Port | |
|---|---|---|
| N | `80N0` | 1 → 8010, 2 → 8020, ... 9 → 8090 |

- That is why an instance is a number from 1 to 9, and why removing instance 2
  leaves 8020 free without moving the others: instance 3 stays on 8030. `new`
  proposes the lowest free number, so the gap is filled first.
- Instances listen on `127.0.0.1` only (`BIND_HOST` in `conf/native.env`).
- `start` checks the port first and says which program holds it when it is
  taken, instead of starting and failing.
- `80N2` (8012, 8022, ...) is written to the config as `gevent_port` and is
  not opened: Odoo only uses it when it runs with workers. In the threaded
  mode used here, live updates (the bus) go through `80N0` too.
- The Docker multi-instance stack uses the same numbers, but by position: its
  first instance is 8010 whatever its name. Run one stack or the other.
- PostgreSQL is one server for all of them, on `127.0.0.1:5432` (`DB_PORT`).

Every command, directly:

```bash
cd ~/Developer/ephem_deployment_docker

bash scripts/macos/dev.sh status                 # ports, databases, branches, running or not
bash scripts/macos/dev.sh start all              # or: start 2      start 1 3
bash scripts/macos/dev.sh stop all
bash scripts/macos/dev.sh restart 2
bash scripts/macos/dev.sh logs 2                 # follow the log, Ctrl+C to leave
bash scripts/macos/dev.sh install 2 eoc_base     # stop, -i eoc_base on ephem_2, start again
bash scripts/macos/dev.sh update 2 eoc_base      # the same with -u
bash scripts/macos/dev.sh update 2               # every eoc_*, ephem_* and cmp_* module of odca2/
bash scripts/macos/dev.sh update 2 --changed     # only the modules whose code changed since ephem_2 last updated them
bash scripts/macos/dev.sh changed 2              # which those are (nothing runs)
bash scripts/macos/dev.sh shell 2                # Odoo shell on ephem_2
bash scripts/macos/dev.sh fetch                  # fetch every branch from origin, once for all instances
bash scripts/macos/dev.sh switch 2 18_national_main
bash scripts/macos/dev.sh backup 2
bash scripts/macos/dev.sh restore 2              # the latest backup of ephem_2; asks first
bash scripts/macos/dev.sh new                    # add an instance: asks number, branch, database
bash scripts/macos/dev.sh remove 4               # delete an instance (asks first; commits and backups are kept)
bash scripts/macos/dev.sh create 4               # the same without questions: a fourth instance on 18_ephem_2
bash scripts/macos/dev.sh create 5 18_emt_v2     # a fifth on another branch
bash scripts/macos/dev.sh initdb 4               # its empty database
```

**Only what changed.** In the menu, Update modules (`u`) offers it first (Enter),
and shows the list before you choose. As on the server (`scripts/update-modules.sh
--changed`), each database keeps a table, `ephem_update_state`, with a
fingerprint of each module's code as it was when that database last updated
it: git's own hash of the module folder, or a hash of its files when it has
uncommitted changes. "Only what changed" updates the installed modules whose
fingerprint differs; Odoo also updates the installed modules that depend on
them. Every successful update or install records what Odoo ran, whichever
option was chosen. A database with no record yet updates every installed
module of the instance's folders once, which starts the record. The table and
the fingerprints are the same as in the Docker and server stacks, so a
database brought over from Docker keeps its record.

To type less, an alias in `~/.zshrc` (yours to add; the scripts never edit it):
`alias edev='bash ~/Developer/ephem_deployment_docker/scripts/macos/dev.sh'`,
then `edev restart 2`.

Compared with `scripts/dev-instances.sh` (Docker):

| Docker | Native | |
|---|---|---|
| `dev-instances.sh up 1 2 3` | `dev.sh create N [BRANCH]`, then `start` | creating an instance and starting it are two steps |
| `dev-instances.sh down` | `dev.sh stop all` | data is kept |
| `dev-instances.sh down -v` | `dev.sh remove N` | one instance at a time, and it asks first |
| `dev-instances.sh status`, `logs N` | the same words | |
| `dev-logs.sh N -u MODULE` | `dev.sh update N MODULE`, then `logs N` | |
| `dev-logs.sh N -i MODULE` | `dev.sh install N MODULE` | |
| `manage.sh` → switch a branch | `dev.sh switch N BRANCH` | |
| `manage.sh` → fetch | `dev.sh fetch` | also widens a single-branch refspec |

Odoo runs with `--dev=xml,reload`: saving a Python file restarts the server by
itself (the `watchdog` package), and XML views are read from disk at each
request. A new field, a changed model, a new file in a manifest or changed data
still need `update N MODULE`.

After the Mac restarts, PostgreSQL comes back by itself; the instances do not:
`bash scripts/macos/dev.sh start all`.

## Branches and worktrees

There is one clone, `ePHEM/`, and each `odcaN/ePHEM-core/` is a **git worktree** of it:
its own files and its own checked-out branch, sharing a single `.git`. One
`fetch` serves every instance, and a commit made in one instance is visible to
the others at once, with no push.

Git refuses to check the same branch out in two worktrees. So an instance never
sits on `18_ephem_2` itself: instance N on branch `B` works on **its own local
branch `odcaN/B`, which tracks `origin/B`**.

```
ePHEM/               18_ephem_2            the base checkout: where work is merged and pushed
odca1/ePHEM-core/    odca1/18_ephem_2      tracks origin/18_ephem_2
odca2/ePHEM-core/    odca2/18_ephem_2      tracks origin/18_ephem_2
odca3/ePHEM-core/    odca3/18_ephem_2      tracks origin/18_ephem_2
```

Why branches and not a detached HEAD: with one agent per instance, each
instance's commits need a name. A branch keeps them reachable when the instance
is switched elsewhere, shows them in `git branch` and in PyCharm from every
worktree, and can be merged or pushed by name. Commits on a detached HEAD have
none of that, and are easy to lose at the next switch.

Why the name carries the base (`odca2/18_ephem_2` and not `dev/odca2`):
`switch 2 18_national_main` then creates `odca2/18_national_main` and leaves
`odca2/18_ephem_2` and its commits exactly as they were. Switching back picks
them up again.

**Bring an instance up to date** with the branch it tracks:

```bash
bash scripts/macos/dev.sh fetch
bash scripts/macos/dev.sh repo pull 2        # ePHEM-core and the instance's other repos, fast-forward only
bash scripts/macos/dev.sh update 2
```

**Merge an instance's work back.** Either through the base checkout:

```bash
cd ~/Developer/ephem/ePHEM          # on 18_ephem_2
git pull
git merge odca2/18_ephem_2          # no fetch needed: same repository
git push
```

or as a branch of its own on GitHub, for a pull request:

```bash
git -C ~/Developer/ephem/odca2/ePHEM-core push origin odca2/18_ephem_2:my-feature
```

A plain `git push` inside `odcaN/ePHEM-core/` stops with "the upstream branch of your
current branch does not match the name of your current branch". That is the
intended guard: an instance (or its agent) cannot push to the shared base
branch by accident.

`switch` refuses while the worktree has uncommitted changes. Do not run
`git worktree remove`, `git gc --prune=now` or `git stash clear` casually: the
object store and the stash are shared by all instances.

## More repositories in an instance

As in the Docker developer stack (`manage.sh` → `+ N`), an instance can have
other addon repositories next to `ePHEM-core/`, a country's for example:

```bash
bash scripts/macos/dev.sh repo add 3 borse/ePHEM_uganda           # → odca3/ePHEM_uganda/
bash scripts/macos/dev.sh repo add 3 borse/ePHEM_uganda main      # a given branch
bash scripts/macos/dev.sh repo add 3 git@github.com:OCA/web.git --name oca-web
bash scripts/macos/dev.sh repo list                               # every instance's repositories
bash scripts/macos/dev.sh repo pull 3                             # ePHEM-core and the others, fast-forward only
bash scripts/macos/dev.sh repo switch 3 ePHEM_uganda BRANCH
bash scripts/macos/dev.sh repo remove 3 ePHEM_uganda              # asks first
```

- `owner/name` means GitHub over SSH, with the same key as the ePHEM clone.
  Any git URL or a local path works too.
- Without a branch, it takes the branch `ePHEM-core` follows (`18_ephem_2`)
  when the repository has one by that name, else the repository's default.
- The instance's `addons_path` becomes `ePHEM-core`, then its repositories,
  then `extra-addons/*`, then Odoo's addons. On a module name clash
  `ePHEM-core` wins (`repo add` says so). A running instance is restarted.
- `update N` without modules covers every module of these repositories as
  well, as in Docker. Install new ones with `install N MODULE` or Apps →
  Update Apps List.
- Each is an ordinary clone (one per instance, so instances can follow
  different branches of it), on the shared branch itself: unlike
  `ePHEM-core` there is no `odcaN/` branch guarding against a push.
- `repo remove` and `remove N` refuse while one has uncommitted or unpushed
  work (`--force` deletes it anyway). Uninstall its modules from the database
  before removing a repository.

## One coding agent per instance

`create`, `switch` and `repo add/remove` write a `CLAUDE.md` into each
`odcaN/` with the instance number, URL, database, its repositories and their
branches, config and log paths, the `dev.sh` commands for restart and module
update, and the rule to stay inside this folder and this database. Start the
agent in `~/Developer/ephem/odcaN` (Claude Code also reads it when started in
a repository below it).

The file sits in `odcaN/` itself, outside every repository, so nothing keeps
it out of git. A file you wrote yourself (without the first-line marker) is
never overwritten.

## PyCharm

- Open `~/Developer/ephem` to see every instance in one window (the lighter
  choice), or `~/Developer/ephem/odcaN` for one. Add each repository
  (`odcaN/ePHEM-core`, `odcaN/ePHEM_uganda`, …) under Settings → Version
  Control → Directory Mappings, so each shows its own branch.
- Interpreter: **Add Interpreter → Existing**, `~/Developer/ephem/venv/bin/python`.
- Mark `~/Developer/ephem/odoo` as a source root (or attach it as a content
  root) for code completion into Odoo.
- Run configuration to debug with breakpoints: script
  `~/Developer/ephem/odoo/odoo-bin`, parameters
  `-c ~/Developer/ephem/conf/odoo-2.conf --dev=xml`, after
  `bash scripts/macos/dev.sh stop 2` (the port must be free). Leave `reload`
  out under the debugger. PDF reports and Arabic stylesheets work from such
  a run with nothing to add: the instance's config carries `bin_path`
  (`tools/wkhtmltox/bin` and `tools/node/node_modules/.bin`), which Odoo
  searches whatever PATH PyCharm builds (it rebuilds PATH when it activates
  the virtualenv, so `conf/pycharm.env`'s PATH does not survive).
- Or a Shell Script configuration: `scripts/macos/dev.sh`, options `restart 2`.

## Databases: create, back up, restore

```bash
bash scripts/macos/dev.sh initdb 2                 # empty database: module base, no demo data (a few seconds)
bash scripts/macos/dev.sh initdb 2 eoc_base        # base plus modules
bash scripts/macos/dev.sh install 2 eoc_base       # modules into a database that exists
```

Login of a new database: `admin` / `admin`. The master password (database
manager at `/web/database/manager`) is `9090`, as in the Docker developer stack.

```bash
bash scripts/macos/dev.sh backup 2                 # → backups/ephem_2_YYYYMMDD-HHMMSS/
bash scripts/macos/dev.sh restore 2                # the latest of those
bash scripts/macos/dev.sh restore 2 PATH
bash scripts/macos/dev.sh restore 2 PATH --neutralize
```

A backup is a folder: `db.dump` (`pg_dump -Fc`), `filestore.tar.gz` and
`manifest.txt` (branch and commit at that moment). `restore` accepts such a
folder, a `.zip` from Odoo's database manager (this is how to **bring a
database over from the Windows machine**: back it up there from
`/web/database/manager`, format zip), or a `.dump`, `.sql` or `.sql.gz` file
(database only).

`restore` **replaces** the instance's database and filestore. It shows what
will be dropped and asks you to type the database name; `--yes` skips the
question. `--neutralize` runs Odoo's own `neutralize` afterwards (mail servers
and scheduled actions off): use it for a copy of a production database.

`psql` and friends are not on your PATH (the Homebrew formula is keg-only):
`/opt/homebrew/opt/postgresql@16/bin/psql -d ephem_2`.

## Settings

`conf/native.env` in the native home:

| Key | Default | |
|---|---|---|
| `DB_USER` | `odoo` | the app role |
| `DB_PASSWORD` | generated | its password; exported as `PGPASSWORD` to Odoo, never written to an `odoo-N.conf` |
| `DB_PORT` | `5432` | |
| `BIND_HOST` | `127.0.0.1` | `0.0.0.0` to reach the instances from a phone or the LAN |
| `DEV_FLAGS` | `xml,reload` | what `--dev=` gets |
| `ADMIN_PASSWD` | `9090` | Odoo master password |
| `LOG_LEVEL` | `info` | `debug` for what the Docker developer stack logs |
| `OFFICE` | `0` | set by `dev.sh office start/stop` |

After changing one: `bash scripts/macos/dev.sh conf N` (writes
`conf/odoo-N.conf` again, keeping the previous one as `.bak`), then
`restart N`. `DEV_FLAGS` and `OFFICE` only need the restart.

`create` never overwrites an existing `odoo-N.conf`; only `conf N` does.

## What matches the Docker image, and what does not

| | `borrs/ephem` image | Native |
|---|---|---|
| Odoo | 18.0, the nightly package inside `odoo:18` | 18.0, the source at the commit you cloned (`install.sh --update-odoo` moves it) |
| Python | 3.12 (Ubuntu 24.04) | 3.12 (uv) |
| PostgreSQL | 16 (`postgres:16-alpine`) | 16 (Homebrew) |
| App role | `odoo`, LOGIN CREATEDB, no superuser | the same |
| wkhtmltopdf | 0.12.6.1 with patched Qt | 0.12.6 with patched Qt (Intel build under Rosetta) |
| ePHEM's Python packages | `requirements.txt` of `borse/ephem-docker-image`, every version pinned with hashes | `scripts/macos/requirements-ephem.txt`: the same top-level list and the same three pins (pypdfium2, pypdf, openpyxl); the rest at its latest release |
| Odoo's Python packages | Ubuntu's `python3-*` packages | Odoo's `requirements.txt` (close, not identical versions) |
| Document converter | `borrs/ephem-office` container | off; optional, see below |
| Listens on | every interface (`DEV_BIND_HOST`) | `127.0.0.1` |
| `dev_mode` | `reload,qweb,werkzeug,xml,assets` | `xml,reload` |
| `log_level` | `debug` | `info` |
| Basemap files (`basemaps/`) | mounted at `/mnt/basemaps` | not set up |

When `requirements.in` changes in `borse/ephem-docker-image`, make the same
change in `scripts/macos/requirements-ephem.txt` and run `install.sh` again.

Because package versions differ slightly, the image stays the reference: before
a release, run the branch once in the Docker stack too.

**Document converter.** ePHEM AI never runs LibreOffice itself: it posts old
Office files (`.doc`, `.ppt`, `.rtf`, `.odt`) to a small HTTP service, the
`borrs/ephem-office` image. Installing LibreOffice on the Mac would therefore
change nothing, and `install.sh` does not install it. To work on that feature:

```bash
bash scripts/macos/dev.sh office start     # needs Docker Desktop; one container on 127.0.0.1:2003
bash scripts/macos/dev.sh restart all
bash scripts/macos/dev.sh office stop
```

Without it the instances run with `EPHEM_OFFICE_CONVERTER=0`, and ePHEM AI
reports the converter as switched off; `.docx`, `.pptx`, `.xlsx` and PDF files
are read either way.

## Docker next to it

Demo mode, and the Docker developer stack, still work on a Mac:

```bash
bash setup.sh                 # 2) Demo, or 3) Developer → 2) Docker (as before)
bash manage.sh --docker       # the Docker menu, while a native setup exists
```

The Docker multi-instance stack uses the same ports (8010, 8020, 8030): run one
or the other. `dev.sh start` says so when a port is taken.

## Updating

| What | How |
|---|---|
| The deployment scripts | `git pull` in the deployment repo |
| ePHEM code | `dev.sh fetch`, `dev.sh repo pull N`, `dev.sh update N` |
| Odoo source | `bash scripts/macos/install.sh --update-odoo`, then `dev.sh update N base` per instance |
| Python packages | change `requirements-ephem.txt` (or pull Odoo), run `install.sh` again |
| PostgreSQL minor version | `brew upgrade postgresql@16` |

**A Mac set up before the `ePHEM-core/` layout** (each `odcaN/` was itself the
ePHEM worktree): after `git pull` in the deployment repo, open `bash manage.sh`.
It lists the old-layout instances and offers to move them into
`odcaN/ePHEM-core/` (Enter says yes). Branches, commits and uncommitted changes
move with them, and running instances are restarted. Stop an instance that
PyCharm runs first. Without the menu: `bash scripts/macos/dev.sh migrate all`.
Afterwards, reopen editors and coding agents that were opened in `odcaN/`, and
in PyCharm point the git roots at `odcaN/ePHEM-core` (Settings → Version
Control → Directory Mappings).

## Troubleshooting

**`port 8010 is taken by another program`**: the Docker instances are running
(`bash scripts/dev-instances.sh down`), or an Odoo started from PyCharm.

**An instance stops right after starting**: `start` prints the last lines of
its log. The whole log: `logs/odoo-N.log`.

**`Postgres does not answer`**: `brew services start postgresql@16`, then
`brew services info postgresql@16`. Its log:
`/opt/homebrew/var/log/postgresql@16.log`.

**"virtual real time limit (…/120s) reached" on a cron, then "Initiating server reload", again and again**:
a transaction was left open and idle (an Odoo shell, a script that rendered a
report and never committed, a debugger left on a breakpoint) and holds row
locks the job needs. `dev.sh` sets `idle_in_transaction_session_timeout`
(30 minutes, `IDLE_TX_TIMEOUT` in `conf/native.env`, `0` to turn it off) on
the instance's database before every start, update or shell, so PostgreSQL
ends such a transaction on its own. To see who is waiting on whom:
`psql -d ephem_N -c "select pid, state, now()-xact_start, pg_blocking_pids(pid), application_name from pg_stat_activity where datname = current_database()"`;
`select pg_terminate_backend(PID)` ends the idle one (its uncommitted work is
rolled back). In a shell, end what you did with `env.cr.commit()` or
`env.cr.rollback()` before leaving it open.

**"Unable to find Wkhtmltopdf on this system", the report shown in HTML**:
the instance's config has no `bin_path` (written before it existed) and the
server was started where `tools/wkhtmltox/bin` is not on PATH (PyCharm).
Start, update or open a shell on the instance once through `dev.sh` (that
adds `bin_path` to `conf/odoo-N.conf`), or `dev.sh conf N`, then restart it.

**PDF reports fail or have no header/footer**: check
`~/Developer/ephem/tools/wkhtmltox/bin/wkhtmltopdf --version` prints
`with patched qt`. "Bad CPU type in executable" means Rosetta is missing:
`softwareupdate --install-rosetta --agree-to-license`.

**Arabic (RTL) pages unstyled**: `rtlcss` is missing; run `install.sh` again.

**`could not connect ... password authentication failed`**: run `install.sh`
again; it puts the role's password back in step with `conf/native.env`.

**A Python package is missing** (`ModuleNotFoundError` in the log): add it to
`scripts/macos/requirements-ephem.txt` (and to the image's `requirements.in`),
then run `install.sh` again.

## Removing it

One instance: `bash scripts/macos/dev.sh remove N`. The whole setup is not
done by a script; these delete data.

```bash
bash scripts/macos/dev.sh stop all

# one instance: bash scripts/macos/dev.sh remove 3   (see Daily commands)

# everything:
rm ~/Developer/ephem_deployment_docker/.macos-native       # manage.sh is the Docker menu again
rm -rf ~/Developer/ephem                                   # code not pushed is lost with it
brew services stop postgresql@16                           # and, to delete its databases too:
brew uninstall postgresql@16 && rm -rf /opt/homebrew/var/postgresql@16
```
