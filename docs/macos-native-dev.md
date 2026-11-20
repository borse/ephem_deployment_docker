# Native developer setup on macOS

On a Mac, developer mode can run Odoo straight on macOS instead of in Docker.
Docker Desktop runs containers in a Linux VM, and every file Odoo reads from
your addons folder crosses into that VM; natively the files are read at full
speed and a restart takes a couple of seconds.

This applies to **macOS only**. On Linux and under WSL nothing here is used and
developer mode is the Docker stack described in the [README](../README.md#mode-3--developer).

- [What you get](#what-you-get)
- [Install](#install)
- [Layout](#layout)
- [Daily commands](#daily-commands)
- [Branches and worktrees](#branches-and-worktrees)
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

| Instance | URL | Database | Addons folder | Config | Log |
|---|---|---|---|---|---|
| 1 | `http://localhost:8010` | `ephem_1` | `odca1/` | `conf/odoo-1.conf` | `logs/odoo-1.log` |
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

## Layout

The deployment repo stays where it is. Everything else lives in the *native
home*, `~/Developer/ephem` unless you chose another folder:

```
~/Developer/ephem/
├── odoo/               Odoo source, branch 18.0 (read only for you)
├── venv/               Python 3.12 virtualenv, shared by every instance
├── ePHEM/              the main clone of borse/ePHEM: the base checkout
├── odca1/              instance 1: a git worktree of ePHEM/
├── odca2/              instance 2
├── odca3/              instance 3
├── extra-addons/       other addon repositories, one subfolder each
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

A repository cloned into `extra-addons/NAME/` is added to the `addons_path` of
every instance by `bash scripts/macos/dev.sh conf N` (then restart). The
`borrs/ephem` image itself contains no addon repository: the only one is
`borse/ePHEM`.

## Daily commands

`bash manage.sh` opens a menu of the same commands: it shows every instance,
then you type a command (`restart 2`, `new`, ...).

**Adding an instance** is `new`, in that menu or as
`bash scripts/macos/dev.sh new`. It asks three things, then creates the
worktree, the config, the `CLAUDE.md` and the database, and starts it:

1. **Number**: Enter takes the lowest free one (up to 9).
2. **Branch**: Enter takes `18_ephem_2`; a full name is taken as it is; part
   of a name (`uganda`) lists the branches of origin that contain it, to pick
   by number; `?` lists them all. The list is fetched first.
3. **Database**: empty (module base only), a copy of another instance's
   database and filestore (that instance keeps running), or none for now.

`create N [BRANCH]` followed by `initdb N` does the same without questions.

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
bash scripts/macos/dev.sh shell 2                # Odoo shell on ephem_2
bash scripts/macos/dev.sh fetch                  # fetch every branch from origin, once for all instances
bash scripts/macos/dev.sh switch 2 18_national_main
bash scripts/macos/dev.sh backup 2
bash scripts/macos/dev.sh restore 2              # the latest backup of ephem_2; asks first
bash scripts/macos/dev.sh new                    # add an instance: asks number, branch, database
bash scripts/macos/dev.sh create 4               # the same without questions: a fourth instance on 18_ephem_2
bash scripts/macos/dev.sh create 5 18_emt_v2     # a fifth on another branch
bash scripts/macos/dev.sh initdb 4               # its empty database
```

To type less, an alias in `~/.zshrc` (yours to add; the scripts never edit it):
`alias edev='bash ~/Developer/ephem_deployment_docker/scripts/macos/dev.sh'`,
then `edev restart 2`.

Compared with `scripts/dev-instances.sh` (Docker):

| Docker | Native | |
|---|---|---|
| `dev-instances.sh up 1 2 3` | `dev.sh create N [BRANCH]`, then `start` | creating an instance and starting it are two steps |
| `dev-instances.sh down` | `dev.sh stop all` | data is kept |
| `dev-instances.sh down -v` | none | see [Removing it](#removing-it) |
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

There is one clone, `ePHEM/`, and each `odcaN/` is a **git worktree** of it:
its own files and its own checked-out branch, sharing a single `.git`. One
`fetch` serves every instance, and a commit made in one instance is visible to
the others at once, with no push.

Git refuses to check the same branch out in two worktrees. So an instance never
sits on `18_ephem_2` itself: instance N on branch `B` works on **its own local
branch `odcaN/B`, which tracks `origin/B`**.

```
ePHEM/    18_ephem_2            the base checkout: where work is merged and pushed
odca1/    odca1/18_ephem_2      tracks origin/18_ephem_2
odca2/    odca2/18_ephem_2      tracks origin/18_ephem_2
odca3/    odca3/18_ephem_2      tracks origin/18_ephem_2
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
git -C ~/Developer/ephem/odca2 pull          # merges origin/18_ephem_2 into odca2/18_ephem_2
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
git -C ~/Developer/ephem/odca2 push origin odca2/18_ephem_2:my-feature
```

A plain `git push` inside `odcaN/` stops with "the upstream branch of your
current branch does not match the name of your current branch". That is the
intended guard: an instance (or its agent) cannot push to the shared base
branch by accident.

`switch` refuses while the worktree has uncommitted changes. Do not run
`git worktree remove`, `git gc --prune=now` or `git stash clear` casually: the
object store and the stash are shared by all instances.

## One coding agent per instance

`create` and `switch` write a `CLAUDE.md` into each `odcaN/` with the instance
number, URL, database, branch, config and log paths, the `dev.sh` commands for
restart and module update, and the rule to stay inside this worktree and this
database. Start the agent in `~/Developer/ephem/odcaN`.

The file is not tracked: it is listed in the clone's `.git/info/exclude`, which
all worktrees share. If the ePHEM repository ever tracks a `CLAUDE.md` of its
own, that one is left alone and the instance file is written as
`CLAUDE.local.md` instead. A file you wrote yourself (without the first-line
marker) is never overwritten.

## PyCharm

- Open `~/Developer/ephem/odcaN` (one window per instance), or
  `~/Developer/ephem` to see all of them.
- Interpreter: **Add Interpreter → Existing**, `~/Developer/ephem/venv/bin/python`.
- Mark `~/Developer/ephem/odoo` as a source root (or attach it as a content
  root) for code completion into Odoo.
- Run configuration to debug with breakpoints: script
  `~/Developer/ephem/odoo/odoo-bin`, parameters
  `-c ~/Developer/ephem/conf/odoo-2.conf --dev=xml`, after
  `bash scripts/macos/dev.sh stop 2` (the port must be free). Leave `reload`
  out under the debugger. For PDF reports from such a run, add
  `~/Developer/ephem/tools/wkhtmltox/bin` to the configuration's `PATH`.
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
| ePHEM code | `dev.sh fetch`, `git -C odcaN pull`, `dev.sh update N` |
| Odoo source | `bash scripts/macos/install.sh --update-odoo`, then `dev.sh update N base` per instance |
| Python packages | change `requirements-ephem.txt` (or pull Odoo), run `install.sh` again |
| PostgreSQL minor version | `brew upgrade postgresql@16` |

## Troubleshooting

**`port 8010 is taken by another program`**: the Docker instances are running
(`bash scripts/dev-instances.sh down`), or an Odoo started from PyCharm.

**An instance stops right after starting**: `start` prints the last lines of
its log. The whole log: `logs/odoo-N.log`.

**`Postgres does not answer`**: `brew services start postgresql@16`, then
`brew services info postgresql@16`. Its log:
`/opt/homebrew/var/log/postgresql@16.log`.

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

Nothing here is done by a script; these delete data.

```bash
bash scripts/macos/dev.sh stop all

# one instance (N = 3):
/opt/homebrew/opt/postgresql@16/bin/dropdb ephem_3
git -C ~/Developer/ephem/ePHEM worktree remove ../odca3      # refuses if it has uncommitted changes
rm -rf ~/Developer/ephem/data/3 ~/Developer/ephem/conf/odoo-3.conf* ~/Developer/ephem/logs/odoo-3.log

# everything:
rm ~/Developer/ephem_deployment_docker/.macos-native       # manage.sh is the Docker menu again
rm -rf ~/Developer/ephem                                   # code not pushed is lost with it
brew services stop postgresql@16                           # and, to delete its databases too:
brew uninstall postgresql@16 && rm -rf /opt/homebrew/var/postgresql@16
```
