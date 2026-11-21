# ePHEM developer framework (`ephem-dev`)

The standards, environment and workflow every contribution to ePHEM follows,
written so that both people and AI coding assistants can use them. The ePHEM
team reviews pull requests against these rules.

| File | What it covers |
|---|---|
| `SKILL.md` | the rules for every task: instance, commands, working agreement, Git, roles, security, user experience, definition of done |
| `references/environment.md` | the three developer layouts, dev-logs.sh, shell, database, tests, working on a copy |
| `references/git-workflow.md` | your branch, merging 18_ephem_2, commits, versions and migrations, the pull request |
| `references/module-checklist.md` | building a module, with skeletons: groups, `ephem_` roles, delegation, rules, menus, translations, tests |
| `references/security.md` | the security gate and the house patterns to copy |
| `references/ux-standards.md` | forms, lists, menus, wording, colour, dark mode, right to left, dashboards |
| `references/domain.md` | what the models mean: signals, incidents, IMS, levels, clearance |
| `references/pitfalls.md` | the mistakes reviews keep finding, and their fixes |

## Install it for Claude Code

The folder is a Claude Code skill. Link it into your personal skills, from the
`ephem-deploy` folder, so that every `git pull` keeps it current:

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/docs/ephem-dev" ~/.claude/skills/ephem-dev
```

(Copy it instead with `cp -r docs/ephem-dev ~/.claude/skills/` if you prefer,
and copy it again after each update.)

Claude Code then loads it on its own for ePHEM work, or on request with
`/ephem-dev`. Start it inside your clone (`odca1/ePHEM-core`,
`addons/ePHEM-core`, or `~/Developer/ephem/odca1` on a native Mac), and check
that it knows where it is: ask "which instance and branch are we on?".

On the native macOS setup each instance also has a generated `CLAUDE.md`
with its own paths; the two work together.

## Other assistants

For an assistant without skills, give it `SKILL.md` as its project
instructions and the `references/` files as documents it can open, or paste
the reference that matches the task.

## Changing the standard

The rules change through the ePHEM team, like the code. Propose a change in a
pull request with the reason; do not edit your local copy to make a rule go
away.
