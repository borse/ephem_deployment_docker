# Merge review

`merge_review.py` tells you what a developer's branch changes before you merge
it, measured against who owns what (`owners.ini`). It reads git only: no
checkout, no merge, no fetch, nothing written to the repository. A run takes a
few seconds.

```bash
cd ~/ephem-deploy
python3 scripts/merge-review/merge_review.py -i 1 origin/18_emt_v2 --db ephem_1
python3 scripts/merge-review/merge_review.py -i 1 origin/18_ephem_2_cmp_budget --target 18_ephem_2
python3 scripts/merge-review/merge_review.py --repo odca3/ephem_uganda --target main origin/main
python3 scripts/merge-review/merge_review.py -i 1 --target <merge>^1 <merge>^2   # a merge already made
```

Fetch first (`git -C odca1/ePHEM-core fetch origin`): the script works on the
refs the clone already has and prints how old the last fetch is.

## The report

Two verdicts on top:

* **SCOPE**: did the branch stay in the developer's area? GREEN when every
  changed folder is theirs (or documentation), AMBER when it touches shared or
  unassigned modules, scripts or new modules with unusual names, or a file
  changed on both sides, RED when it changes a platform module, another
  developer's module, or deletes a module.
* **RISK**: what the code does, from the findings. RED with any high finding,
  AMBER with any medium one.

Then seven parts:

1. Where the changes are, by owner class, with every file listed for the
   classes that need a reading.
2. Findings, grouped by rule, high first. Each rule says why it matters.
3. New modules: application, installed by hand, or a bridge that installs
   itself with one of the developer's modules. An auto install module whose
   dependencies are all someone else's is a high finding: it lands on every
   database that has them.
4. Hooks into other modules: classes extending a model another module (or
   Odoo) defines, with the methods and fields they add or override. This is
   what changes on a database once the developer's modules are installed.
5. The merge: files changed on both sides since the merge base, and which of
   them conflict.
6. After the merge: the existing modules to update (and which are installed
   on each `--db`), and the test tags to run.
7. Commits, with each author labelled (the developer, the ePHEM team, an AI
   session, another developer, unknown).

`--json FILE` writes everything as JSON. `--max N` and `--all` control how
many items each list shows. `--dev KEY` forces a profile.

## What the rules look at

| Area | Rules |
|---|---|
| Ownership | platform, another developer, shared, unassigned, new, deleted module |
| Manifest | auto install not gated by the developer's modules, new dependencies of an existing module, auto install switched on, version going down, version bumped on both sides, migration folder above the manifest version, new external Python libraries, install hooks, asset `replace`/`remove`, global SCSS variables |
| Python | routes with `auth='public'` or `'none'`, `csrf=False`, `cors`, SQL built by string formatting, `eval`/`exec`, `subprocess`, outbound HTTP, `set_param` on another module's key, `env.ref(other).write()`, monkey patching Odoo, debugger calls, destructive SQL, `sudo().search(...)` |
| Python structure | overrides of access methods (`_search`, `read`, `check_access`, ...) or save methods (`create`, `write`, `unlink`) on another module's model, overrides of Odoo plumbing (`ir.http`, `ir.rule`, `ir.ui.menu`, `res.users`, ...), `super()` calls to a method nothing on the target defines any more (checked against Odoo's own source in a running instance container), files that do not parse |
| XML | records of another module written (`id="other_module.xyz"`), `<delete>`, `<function>`, top menus without groups, record rules on another module's model (global ones are high), groups listing users, `ephem_staff_baseline` links, OWL template extensions of another module |
| Access CSV | lines with no group, portal or public groups, write access for every internal user, access to another module's model |
| JavaScript | `patch()` of another module's or Odoo's component, registry `force: true` and `remove` |
| SCSS | mixed unit `min()`/`max()` (kills the CSS bundle), top level selectors on Odoo's own classes |
| Anywhere | keys and tokens, CDN links (ePHEM must work offline), junk files, files over 2 MB |

Test files skip most rules; documentation paths are scanned for secrets only.

## owners.ini

Shell glob patterns. A pattern without a slash matches the top level folder
(the module), a pattern with a slash matches the whole path. Sections:

* `[core]`: `protected` (platform modules and deployment files), `shared`,
  `quiet_paths` (documentation), `team_authors`, `ai_authors`.
* `[dev:<key>]`: `name`, `authors` (git author names), `branches` (globs on
  the branch name, used to pick the profile), `focus` (a line of text),
  `owns` (the focus area), `also` (the developer's other modules),
  `own_repos` (repositories that are entirely theirs, matched on the origin
  URL's last part).

A folder nobody lists comes out as "unassigned". Decide whose it is and add it.
