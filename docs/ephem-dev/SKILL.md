---
name: ephem-dev
description: The ePHEM developer framework. Standards, environment and workflow for building on ePHEM (Electronic Public Health Emergency Management, Odoo 18 Community with the custom eoc_*, ephem_* and cmp_* addons). Use for ANY task in an ePHEM clone or the ephem-deploy stack: a new module, model, field, view, menu, wizard, settings page, OWL component, SCSS, dashboard, report, controller or API, access rights, record rules, roles (ephem_ roles), translations, migrations, tests, module updates, the odca1/odca2/odca3 dev instances, dev-logs.sh, branches, merging 18_ephem_2 and pull requests. Read it before writing code, and follow its definition of done before calling work finished.
---

# ePHEM developer framework

ePHEM is a public health emergency management platform built on Odoo 18
Community. It runs in ministries of health and regional public health agencies
and holds case level health data. Everything here exists because a reviewer of
the ePHEM team will check it before your work is merged.

Follow these rules as written. When a rule cannot be met inside the task, say
so plainly in your report (file, line, why) instead of working around it.

---

## 0. First: which instance, which branch

Work in exactly one instance and one database for the whole session. Find out
which before touching anything; if the developer has not said, look, then ask.

| Layout | How to recognise it | ePHEM clone | Database | Web |
|---|---|---|---|---|
| Docker, multi instance (Linux, WSL) | `ephem-deploy/odca1/`, `odca2/`... and `.dev-instances` | `odcaN/ePHEM-core/` | `ephem_N` | `http://localhost:80N0` |
| Docker, single instance | `ephem-deploy/addons/ePHEM-core/` | `addons/ePHEM-core/` | the one the developer created | `http://localhost:8069` |
| macOS native | `ephem-deploy/.macos-native` points to `~/Developer/ephem` | `~/Developer/ephem/odcaN/` (a git worktree) | `ephem_N` | `http://localhost:80N0` |

The multi instance mapping, which never changes:

| Say | Folder | Clone | Config | Database | Container | Compose service | URL |
|---|---|---|---|---|---|---|---|
| odca1 | `odca1/` | `odca1/ePHEM-core/` | `odoo-1.conf` | `ephem_1` | `ephem-1` | `odoo_1` | http://localhost:8010 |
| odca2 | `odca2/` | `odca2/ePHEM-core/` | `odoo-2.conf` | `ephem_2` | `ephem-2` | `odoo_2` | http://localhost:8020 |
| odca3 | `odca3/` | `odca3/ePHEM-core/` | `odoo-3.conf` | `ephem_3` | `ephem-3` | `odoo_3` | http://localhost:8030 |

Instance N always means folder `odcaN`, config `odoo-N.conf`, database
`ephem_N`, web port 80N0 and live updates port 80N2. All instances share one
Postgres container, `ephem-db`. Each `odcaN/` is mounted read write into its
container, so an edit on the host is seen at once.

Then check the branch: `git -C <clone> branch --show-current`. Never edit on
`18_ephem_2` itself: work on your own branch (section 3).

Never start, stop, update, restore or edit another instance, and never point
a command at another instance's database. Other instances may belong to other
people or other agents. Full environment guide: `references/environment.md`.

---

## 1. The commands

**Docker (Linux, WSL).** One script does restart, update, install and tests:

```bash
bash scripts/dev-logs.sh 1 -u eoc_mymodule --no-follow     # update on ephem_1, restart, return
bash scripts/dev-logs.sh 1 -i eoc_mymodule --no-follow     # install
bash scripts/dev-logs.sh 1 --no-follow                     # restart only
bash scripts/dev-logs.sh -u eoc_mymodule -d mydb --no-follow   # single instance: name the database
```

Run it from the `ephem-deploy` folder. **An agent always passes
`--no-follow`**: without it the script tails the log forever. It returns 0
once Odoo answers again, 1 when Odoo stopped or keeps failing, 2 on timeout,
3 when another one shot is already running on that instance. Redirect the
output to a file and grep it:

```bash
bash scripts/dev-logs.sh 1 -u eoc_mymodule --no-follow > /tmp/u.log 2>&1; echo "exit=$?"
grep -nE "Modules loaded|Registry loaded|CRITICAL|Traceback|ERROR" /tmp/u.log
```

Success is exit 0 plus `Modules loaded.` or `Registry loaded`, not the absence
of the word ERROR: the stack logs known noise (view error context for a few
old views, docstring indentation warnings, missing translation language).

**macOS native.** `bash scripts/macos/dev.sh update N eoc_mymodule`,
`restart N`, `install N eoc_mymodule`, `shell N`, `status`; read the log with
`tail -n 200 ~/Developer/ephem/logs/odoo-N.log` (not `dev.sh logs`, which
follows forever). The instance's own `CLAUDE.md` lists the exact paths.

**Tests** run only for the modules updated in the same run:

```bash
bash scripts/dev-logs.sh 1 -u eoc_mymodule --no-follow --test-enable \
  --test-tags /eoc_mymodule --http-port=8099 --gevent-port=8098 --max-cron-threads=0
```

Before pushing, run what the pull request check runs, from inside the clone:
`bash scripts/ci/run_module_tests.sh origin/18_ephem_2` (fresh database, no
demo data, the changed modules and their tests; it needs Docker).

What needs what: a Python change needs a restart; a new field, a changed
model, view, data file or manifest needs `-u` of the module; JS, SCSS or OWL
that does not show after a reload needs `-u` and a restart; translations need
`-u` with `--i18n-overwrite`.

---

## 2. Working agreement for a coding agent

1. **Stay in your instance**, your clone and your database (section 0).
2. **Never commit or push unless the developer asks.** They review the
   uncommitted diff. When asked, stage explicit paths (`git add path/one
   path/two`), never `git add -A` or `git add .`: other tools and people leave
   files in the same tree.
3. **Never push to `18_ephem_2`, `18_national_main` or anyone else's branch,**
   never force push, never push tags. You push your own branch only.
4. **Destructive commands need an explicit instruction**: `docker compose down
   -v` (wipes every database), `dropdb`, `git reset --hard`, `git clean`,
   `git stash drop`, deleting a filestore. Before deleting or overwriting, look
   at the target.
5. **Never `-u all`** on a database that carries real geography, and never call
   `set_groups_from_roles(force=True)` (it strips every user without a role).
6. **Risky data work happens on a copy** of the database (`createdb` plus
   `pg_dump | psql`, and `--db-filter=^copy$` when serving it), never on the
   shared one.
7. **Credentials stay out of everything**: no password, token or key in code,
   XML data, a manifest, a commit message, a log line, a screenshot or a
   document. Never `select *` on a table holding credentials (API keys,
   provider settings, `res_users`): name the columns.
8. **Keep verification proportionate**: `-u` the modules you changed, run their
   tests, report. Do not seed data or write browser scripts unless asked.
9. **Report code and data separately.** Code travels with git; records,
   settings and imports do not, and must be redone on every database.
10. **Run the security gate** (section 6) before showing any diff it covers.

---

## 3. Git: your branch, kept current with 18_ephem_2

- `18_ephem_2` is the integration branch everybody builds on. `18_national_main`
  is the stable line. Nobody outside the ePHEM team commits to either.
- Create your own branch from `origin/18_ephem_2`, named
  `18_ephem_2_<team>_<feature>` (lowercase, underscores).
- **Merge `origin/18_ephem_2` into your branch** at least once a day and always
  before you push: `git fetch origin && git merge origin/18_ephem_2`. Merge, do
  not rebase, once the branch is pushed. After a merge, update the modules that
  changed and run their tests.
- Push your branch only: `git push -u origin 18_ephem_2_<team>_<feature>`.
- Open a pull request against `18_ephem_2`. The ePHEM team reviews it and does
  the final merge. Fix review comments on your branch and push again.

Commit size, messages, versions, migrations, conflicts and the pull request
template: `references/git-workflow.md`.

---

## 4. Access: roles, level and area, clearance

Three independent things decide what a person sees and does:

| What | Mechanism | Rule |
|---|---|---|
| What they do | **roles** (`res.users.role`), each bundling groups | people get roles, never raw groups |
| Where | `res.users.geo_admin_level` plus the user's areas | a field, never a group |
| How sensitive | `res.users.confidentiality_level` 1 to 5 against the record's `confidentiality_rank` | a field, never a group |

Once a user holds any role, their groups are recomputed from their roles on
every change and every three hours, so **a group given any other way
disappears**. Hence the rule every module follows:

**Every module that adds a capability group ships an `ephem_` role for it,
says who manages its members, and gives them a User Roles page.** A group
with no role cannot be held. Concretely:

- groups as a ladder, `group_<x>_viewer < group_<x>_user < group_<x>_manager`;
- `data/user_roles_data.xml` (`noupdate="1"`): one role per function, named
  `ephem_<module>_<function>`, XML id `role_ephem_<slug>`, a `comment` that
  states the purpose in plain words (it is shown to managers on the User Roles
  page, so it must be true);
- `data/user_roles_delegation.xml` (`noupdate="0"`): one
  `_ephem_set_delegation` line per role (role, page key, manager group,
  sequence); roles that carry administration, official communications or API
  groups get no manager;
- `views/user_roles_menu.xml`: the User Roles page of the module, sequence 999,
  under its Configuration menu;
- only if every internal user should read something: add the viewer group to
  `eoc_base.role_ephem_staff_baseline` with an additive `(4, ref(...))` link.

Copy the pattern from `eoc_4w` (small and complete). Details, seats and
building blocks: `references/module-checklist.md`.

---

## 5. Building or changing a module

The short version of `references/module-checklist.md`:

1. **Name and place.** `eoc_<thing>` for an emergency operations feature,
   `ephem_<thing>` for a platform feature, `eoc_<a>_<b>` for a bridge between
   two optional modules (`auto_install`). Optional modules depend on core,
   never the reverse: a core module never names an optional module's model,
   field or group (CI checks some of this).
2. **Manifest.** `version` `18.0.1.0.0`, `license` `LGPL-3`, `category` `EOC`,
   `author` `ePHEM`, a one line `summary`, minimal `depends`, data in load
   order: groups, access CSV, rules, data, roles, delegation, views, menus.
3. **Security in the same commit as the model**: an access line per group,
   record rules for place and clearance, `perm_unlink` 0 for operational
   records.
4. **Roles** (section 4), menus with `groups=` on the root.
5. **Views that meet the UX standards** (section 7).
6. **Translations**: every string translatable; `i18n/<module>.pot` plus
   `fr.po`, `ar_001.po`, `pt.po`; check the screens right to left.
7. **Tests**: access per role as a non admin user at the lowest level, the
   workflow, the rules.
8. **A version bump and a migration** whenever an existing database must
   change (section 3 reference).
9. **README.md** in the module: purpose, roles, settings, data steps.

---

## 6. Security gate

ePHEM holds case level health data. Before showing a diff that adds or changes
a model, a controller or route, an access line, a record rule, a `sudo()`, a
cron that calls out, an email template with a link, an API resource, an export,
or a field holding a person's identity or health status, run the checklist in
`references/security.md`. The rules that matter most:

1. A new model ships its `ir.model.access.csv` lines in the same commit, and an
   `ir.rule` if it is scoped by place, incident or clearance. Never an access
   line with an empty group: that is every user, portal and public included.
2. `sudo()` only after an access check passed, on the one record it returned,
   with a one line reason above it. Never around a whole method, never on ids
   or a domain from the caller.
3. Public routes deny by default and authenticate inside the handler; compare
   tokens with `hmac.compare_digest` or `consteq`; never look a record up by a
   bare id.
4. Never build SQL or a domain by string formatting from input.
5. Never log, email or export a person's name, contact or health status without
   a stated reason and a clearance check.

---

## 7. User experience and usability standards

People use ePHEM during emergencies, tired and in a hurry, in several languages
including Arabic. The full standard is `references/ux-standards.md`; the rules
reviewers check first:

- **At most five tabs** in a form's notebook, counting tabs other modules add.
  A tab with three fields or fewer belongs on the sheet. Hide tabs that do not
  apply rather than showing them empty. No notebook inside a notebook.
- **At most three action buttons** visible in a form header at a time, one of
  them primary. Anything destructive or irreversible asks for confirmation and
  says what will happen.
- **At most eight columns** shown by default in a list; the rest
  `optional="hide"`.
- **At most seven entries** in an app's top menu, Configuration last, User
  Roles at the end of Configuration.
- **Labels say what will happen** ("Send to Signals", not "Process"), in the
  user's words. No dash punctuation in any user facing text. Never hardcode a
  level name ("State", "District") or a country: read the level label.
- **Never write a colour literal.** Use the theme tokens and `ephem-` classes;
  check dark mode and right to left before calling UI work done.
- **Nothing from a CDN.** ePHEM runs offline in trainings and field sites:
  libraries ship inside the addons, maps use keyless basemaps.
- **Dashboards cost one request** and are designed from their subject, not
  assembled from generic cards and doughnuts.

---

## 8. The domain, in brief

The models follow international public health emergency doctrine: a
**signal** is reported, triaged and verified; the **event** is risk assessed
and graded; an **incident** is the managed response, with an incident
management system (**IMS**), incident action plans per operational period,
tasks, a common operating picture, situation reports and an early action
review. Field names and states carry operational meaning.

Design rules that follow: nothing is deleted, everything is justified (discards
and overrides keep their reason); state changes that matter stamp who and when;
offline and low bandwidth are normal; one database can be a **country**
deployment (levels National, first level, second level) or an **organization**
deployment (HQ, Region, Country, when `eoc_regional_level` is installed), on
the same three level keys. Read `references/domain.md` before designing a
feature or naming a field.

---

## 9. Pitfalls that recur

The catalogue with fixes is `references/pitfalls.md`. The ones met most often:

1. `sudo()` added for convenience, which drops every record rule.
2. A child model of an incident with an access line but no record rule routed
   through its parent.
3. A stored computed field that depends on "now": computed once, stale forever.
4. A view modifier (`invisible`, `readonly`, `required`) on a field the view
   does not load.
5. Data records (stages, roles, sequences) in `noupdate="0"`, so every update
   wipes what an administrator changed.
6. A page that reads a linked record as the user: one row they may not read
   breaks the page for everyone below national level.
7. An onchange comparing a new record's relations with real records (compare
   `._origin`).
8. An OWL template calling `String()`, `Number()` or `JSON` (not visible in
   templates: use a component method).
9. A dashboard or library loaded from a CDN.
10. Tests run only as administrator.

---

## 10. Definition of done

Before saying a task is finished, and before a pull request:

- [ ] The module installs on a fresh database and updates an existing one,
      exit 0 and `Modules loaded`.
- [ ] Its tests pass, and `scripts/ci/run_module_tests.sh origin/18_ephem_2`
      passes.
- [ ] New groups have `ephem_` roles, delegation lines and a User Roles page.
- [ ] Access lines and record rules for every new model; the security gate run.
- [ ] Screens meet the UX limits, work in dark mode and right to left, use
      tokens, load nothing from a CDN.
- [ ] Every user facing string translatable; `.pot` and the three catalogues
      updated.
- [ ] Version bumped and migration written where an existing database changes.
- [ ] No credentials, no machine files, no unrelated changes in the diff.
- [ ] Branch merged with the latest `origin/18_ephem_2`.
- [ ] The report says what changed, how it was tested, what was not, and which
      data steps each database needs.

---

## 11. Reference files

| File | Open it when |
|---|---|
| `references/environment.md` | setting up, finding your instance, the commands in depth, the database, tests, a stack that misbehaves |
| `references/git-workflow.md` | branching, merging 18_ephem_2, commits, versions and migrations, conflicts, the pull request |
| `references/module-checklist.md` | creating a module or adding models, groups, roles, menus, settings, tests |
| `references/security.md` | any change covered by section 6 |
| `references/ux-standards.md` | any form, list, search, menu, wizard, settings page, dashboard, label, colour or SCSS |
| `references/domain.md` | designing a feature, naming a field, changing a workflow, anything scoped by place or clearance |
| `references/pitfalls.md` | reviewing code, debugging something that works for admin only, before a pull request |
