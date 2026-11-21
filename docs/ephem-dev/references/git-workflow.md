# Git workflow: your branch, kept current, reviewed, merged by the ePHEM team

## 1. The branches

| Branch | What it is | Who writes to it |
|---|---|---|
| `18_ephem_2` | the integration branch: everything new lands here | the ePHEM team, by merging reviewed branches |
| `18_national_main` | the stable line deployments run | the ePHEM team |
| `18_ephem_2_<team>_<feature>` | your work | you |

Odoo 18 only. Other long lived branches exist for specific deployments; build
on `18_ephem_2` unless the ePHEM team tells you otherwise.

## 2. Start a branch

Docker layouts (inside the clone, `odcaN/ePHEM-core/` or `addons/ePHEM-core/`):

```bash
git fetch origin
git switch -c 18_ephem_2_<team>_<feature> origin/18_ephem_2
```

Developer mode clones one branch only. If `origin/18_ephem_2` or a colleague's
branch is missing, let the clone see every branch once:

```bash
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git fetch origin
```

(`bash manage.sh` offers the same as a menu entry.)

macOS native: the instance already sits on `odcaN/18_ephem_2`, a local branch
of its own. Work there; the feature name is given when you push (section 5).
Changing what an instance tracks is `dev.sh switch N BRANCH`, a decision for
the developer, not the agent.

One feature per branch. A fix found on the way that has nothing to do with the
feature goes on its own branch, or into the pull request description as a note.

## 3. Keep it current

Merge `origin/18_ephem_2` into your branch at least once a day, and always
before you push:

```bash
git fetch origin
git merge origin/18_ephem_2
```

macOS native: `bash scripts/macos/dev.sh fetch`, then `git -C
~/Developer/ephem/odcaN pull` (it merges `origin/18_ephem_2`).

- **Merge, do not rebase** a branch that has been pushed: rewriting published
  history breaks everyone who fetched it.
- After the merge, update every module that changed and run their tests. The
  list: `python3 scripts/ci/changed_modules.py ORIG_HEAD --with-dependents`
  (the modules the merge brought in, and those that depend on them).
- A branch that has not merged `18_ephem_2` for weeks will not be reviewed
  until it has.

**Conflicts that recur and how to resolve them:**

| File | Resolution |
|---|---|
| `__manifest__.py` version | keep the higher version, then bump yours above it if your branch carries a migration |
| `migrations/<version>/` | if `18_ephem_2` already used your version number, move your scripts to a new, higher version and bump the manifest to match |
| `i18n/*.pot`, `*.po` | keep both sides' entries; a `.po` entry missing from the `.pot` is never loaded, so the two must stay in step |
| `ir.model.access.csv` | keep every line from both sides; check no id appears twice |
| views | keep both changes; check the result renders (`-u` the module) |

Never resolve a conflict by taking your side wholesale on a file you did not
write.

## 4. Commits

- Small and complete: one reviewable change per commit, which installs and
  passes its tests on its own.
- The message says what changed and why, in plain words. First line under 72
  characters, then a body when the why is not obvious. No dash punctuation.
- Stage explicit paths: `git add eoc_x/models/thing.py eoc_x/views/thing.xml`.
  Never `git add -A` or `git add .`.
- Never commit: credentials, `.env`, `odoo*.conf`, `docker-compose.override.yml`,
  `.claude/`, a generated `CLAUDE.md`, `__pycache__/`, `*.pyc`, database dumps,
  filestores, editor and lock files (`~$*`), scratch scripts, screenshots taken
  for yourself.
- Anything a script of yours generated that the product needs (an icon, a
  converted data file) is committed, or production never gets it.

## 5. Push

```bash
git push -u origin 18_ephem_2_<team>_<feature>
```

macOS native, from the instance's worktree:

```bash
git -C ~/Developer/ephem/odcaN push origin odcaN/18_ephem_2:18_ephem_2_<team>_<feature>
```

(A plain `git push` there stops on purpose: the local branch tracks the shared
base branch.)

Never push to `18_ephem_2`, `18_national_main` or a colleague's branch. Never
`--force` on a branch someone else may have fetched. Never push tags.

## 6. Versions and migrations

The manifest version is `18.0.MAJOR.MINOR.PATCH`. Bump it whenever an existing
database must change when the module updates: a new or changed field, model,
view, data record, access line, rule or menu. Odoo runs a module's
`migrations/<version>/` scripts only when the version goes up.

- `pre-migrate.py` runs before the module's models load: rename columns, move
  data the new schema would drop. **Guard every statement** against a table or
  column that an older database never had
  (`SELECT to_regclass('public.<table>')`, or a check on
  `information_schema.columns`).
- `post-migrate.py` runs after the module loaded: fill new fields, fix data.
  It sees only its own module and what it depends on, so check
  `field in env[model]._fields` before touching a field another module owns.
- `end-migrate.py` runs after every module of the update loaded.
- **Data in a `noupdate="1"` block is never rewritten by an update.** Changing
  it on existing databases takes a migration. Turning a block into
  `noupdate="1"` does nothing for existing databases either: the flag on each
  `ir.model.data` row decides, so that needs a one line migration too.
- Test a migration on a copy of a database that has real data (environment
  reference, section 6), then on a fresh install.

## 7. The pull request

Open it against `18_ephem_2`. The automatic checks run the tests of every
changed module on a fresh database, plus static guards that keep core modules
independent of optional ones. Both must pass.

Description template:

```
What and why
  One paragraph: the problem, the change, who it is for.

Modules
  Changed: eoc_x (18.0.1.4.0 to 18.0.1.5.0), eoc_y
  New: eoc_z (needs a line in ephem-deploy scripts/update-modules.sh)

Access
  New groups and their ephem_ roles, who manages them, record rules added.
  Security gate: run, findings and how they were handled.

Database changes
  Migrations (version, what they do, tested on which copy).
  Data steps each database needs that git does not carry (settings, imports).

Screens
  Screenshots: light, dark, and right to left for anything a user sees.

Tests
  Commands run and their result (module tests, run_module_tests.sh).
  What was not tested.
```

The ePHEM team reviews, may ask for changes, and does the final merge. Address
comments with new commits on the same branch; do not merge your branch into
`18_ephem_2` yourself, and do not open a second pull request for the same work.

## 8. A new module

Besides the module itself (`module-checklist.md`): every server updates
modules from an ordered list in ephem-deploy's `scripts/update-modules.sh`. A
new module needs a line there (a new `eoc_` module after the last `eoc_` entry,
anything else at the bottom). Say so in the pull request; the ePHEM team adds
it.
