# Building a module: the checklist and the skeletons

Copy from a real module rather than from memory. `eoc_4w` is small and
complete (groups, roles, delegation, User Roles page, rules, tests,
translations); `eoc_surveillance` shows the area rules; `eoc_rcce` shows a
workflow module with fenced writes.

---

## 1. Decide before you write

- **New module or extension?** Extend the module that owns the model when the
  change belongs to everyone who installs it. Make a new module when the
  feature is optional, belongs to some deployments only, or bridges two
  optional modules.
- **Name.** `eoc_<thing>` for an emergency operations feature, `ephem_<thing>`
  for a platform feature, `eoc_<a>_<b>` for a bridge that exists only when both
  `eoc_<a>` and `eoc_<b>` are installed (`auto_install: True`), `eoc_<country>`
  for a country's own configuration.
- **Dependency direction.** Optional modules depend on core modules
  (`eoc_base`, `eoc_signals`, `eoc_actors`, `eoc_incident_management`), never
  the reverse. A core module never names an optional module's model, field,
  group or menu, not even in a string domain. When core needs to show
  something optional, the optional module extends core (an inherited view, a
  hook method the core calls, a card on My Desk). The theme
  (`ephem_theme_backend`) never depends on an optional application.
- **Countries.** Nothing country specific in a shared module: a country's
  names, levels, thresholds and lists go into data the deployment sets, or
  into its `eoc_<country>` module.

## 2. Layout

```
eoc_mymodule/
├── __init__.py
├── __manifest__.py
├── README.md
├── models/            one file per model, __init__.py imports them
├── views/             one file per model, plus menus.xml and user_roles_menu.xml
├── wizards/
├── controllers/       only when a route is really needed
├── security/
│   ├── security.xml   category, groups, record rules
│   └── ir.model.access.csv
├── data/
│   ├── user_roles_data.xml
│   ├── user_roles_delegation.xml
│   └── ...            sequences, stages, crons, mail templates
├── i18n/              eoc_mymodule.pot, fr.po, ar_001.po, pt.po
├── migrations/        18.0.x.y.z/pre-migrate.py, post-migrate.py
├── static/
│   ├── description/icon.png
│   └── src/           js/, xml/, scss/ (OWL components and styles)
└── tests/
    ├── __init__.py
    └── test_access.py ...
```

## 3. Manifest

```python
{
    'name': 'My Module',
    'version': '18.0.1.0.0',
    'license': 'LGPL-3',
    'summary': 'One line that says what it is for, in the user\'s words',
    'category': 'EOC',
    'author': 'ePHEM',
    'depends': ['eoc_base'],
    'data': [
        'security/security.xml',          # groups first: everything below names them
        'security/ir.model.access.csv',
        'data/sequence.xml',
        'data/user_roles_data.xml',
        'data/user_roles_delegation.xml',
        'views/thing_views.xml',
        'views/menus.xml',
        'views/user_roles_menu.xml',
    ],
    'assets': {
        'web.assets_backend': [
            'eoc_mymodule/static/src/**/*',
        ],
    },
    'application': True,                  # an app with its own root menu
    'installable': True,
}
```

Keep `depends` to what the code really uses. A Python library the image does
not carry goes into `external_dependencies` and is raised with the ePHEM team
(it has to be added to the image).

## 4. Groups

```xml
<record id="module_category_mymodule" model="ir.module.category">
    <field name="name">My Module</field>
</record>
<record id="group_mymodule_viewer" model="res.groups">
    <field name="name">Viewer</field>
    <field name="category_id" ref="module_category_mymodule"/>
    <field name="implied_ids" eval="[(4, ref('base.group_user'))]"/>
</record>
<record id="group_mymodule_user" model="res.groups">
    <field name="name">User</field>
    <field name="category_id" ref="module_category_mymodule"/>
    <field name="implied_ids" eval="[(4, ref('group_mymodule_viewer'))]"/>
</record>
<record id="group_mymodule_manager" model="res.groups">
    <field name="name">Manager</field>
    <field name="category_id" ref="module_category_mymodule"/>
    <field name="implied_ids" eval="[(4, ref('group_mymodule_user'))]"/>
</record>
```

- A group is a **capability** (what an action requires). Add one only when an
  access line, a rule, a menu, a button or a `has_group` check needs it.
- Never a group for a place or a clearance: those are fields on the user.
- An extra capability that does not fit the ladder (a confidential note, an
  approval) is its own group with its own role.

## 5. Roles: the part every module must do

People get roles, never groups. A group without a role cannot be held: the
role sync removes it.

**`data/user_roles_data.xml`**, created once, so a deployment's later edits
survive updates:

```xml
<odoo>
    <data noupdate="1">
        <record id="role_ephem_mymodule_viewer" model="res.users.role">
            <field name="name">ephem_mymodule_viewer</field>
            <field name="comment">Read the things of your area and their reports. ePHEM default role.</field>
            <field name="implied_ids" eval="[(6, 0, [ref('group_mymodule_viewer')])]"/>
        </record>
        <record id="role_ephem_mymodule_user" model="res.users.role">
            <field name="name">ephem_mymodule_user</field>
            <field name="comment">Record and update the things of your area. Includes viewer. ePHEM default role.</field>
            <field name="implied_ids" eval="[(6, 0, [ref('group_mymodule_user')])]"/>
        </record>
        <record id="role_ephem_mymodule_manager" model="res.users.role">
            <field name="name">ephem_mymodule_manager</field>
            <field name="comment">Keep the configuration of My Module and give its roles. Includes user. ePHEM default role.</field>
            <field name="implied_ids" eval="[(6, 0, [ref('group_mymodule_manager')])]"/>
        </record>
    </data>
</odoo>
```

- Name `ephem_<module>_<function>`, XML id `role_ephem_<slug>`. Roles are
  functions ("can enter signals"), not job titles ("surveillance officer"):
  deployments compose job roles from them.
- The `comment` is shown as the role's **Purpose** on the User Roles page.
  Write it for a manager deciding who gets the role, and keep it true: check
  it against the access lines when you finish.

**`data/user_roles_delegation.xml`**, applied again on every update:

```xml
<odoo>
    <data noupdate="0">
        <function model="res.users.role" name="_ephem_set_delegation" eval="[[
            ('eoc_mymodule.role_ephem_mymodule_viewer', 'mymodule', 'eoc_mymodule.group_mymodule_manager', 10),
            ('eoc_mymodule.role_ephem_mymodule_user', 'mymodule', 'eoc_mymodule.group_mymodule_manager', 20),
            ('eoc_mymodule.role_ephem_mymodule_manager', 'mymodule', 'eoc_mymodule.group_mymodule_manager', 30),
        ]]"/>
    </data>
</odoo>
```

Each line: the role, the key of the User Roles page that lists it, the group
whose members manage it (or `False`), the order. A role that carries
administration (`base.group_system`, `base.group_erp_manager`,
`eoc_base.group_eoc_super_admin`), official communications or an API group
(`group_api_*`) is never delegable: give it `False`.

**`views/user_roles_menu.xml`**: the page itself. Copy
`eoc_4w/views/user_roles_menu.xml`, change the key in the domain, the parent
menu (your Configuration menu) and the groups (your manager group plus
`eoc_base.group_eoc_super_admin`). Sequence 999 keeps it last. A role whose
module has no such page can only be given by an administrator: do not ship
roles without it.

**The staff baseline.** `eoc_base.role_ephem_staff_baseline` is held by every
internal user. Add your viewer group to it only when every member of staff
should read your module, with an additive link that survives on every update:

```xml
<data noupdate="0">
    <record id="eoc_base.role_ephem_staff_baseline" model="res.users.role">
        <field name="implied_ids" eval="[(4, ref('group_mymodule_viewer'))]"/>
    </record>
</data>
```

A module that should stay invisible by default adds nothing.

**Seats and building blocks.** When a job needs rights across several
modules (a clinic nurse, a hospital reporter), ship one raw role per
capability (`ephem_<module>_<capability>_access`) and a **seat** named for the
job that bundles what it needs. A bridge module adds its group to an existing
seat with the same additive `(4, ref(...))` link. People are given seats.

**Roles the platform sets.** If a role must follow something else (a function
in a response, a duty roster), set it from code and give it no manager; say in
its comment that it is never given by hand.

**Demo Mode.** Every module that ships roles has a seeder in
`eoc_demo_mode/seeders/` (see `seed_4w.py`) so demonstrations and trainings
show it with data, and lists its models for the nightly reset. Agree it with
the ePHEM team; it usually comes after the module itself is reviewed.

## 6. Access lines

```
id,name,model_id:id,group_id:id,perm_read,perm_write,perm_create,perm_unlink
access_thing_viewer,eoc.thing viewer,model_eoc_thing,group_mymodule_viewer,1,0,0,0
access_thing_user,eoc.thing user,model_eoc_thing,group_mymodule_user,1,1,1,0
access_thing_manager,eoc.thing manager,model_eoc_thing,group_mymodule_manager,1,1,1,0
```

- Every model, including wizards (transient models) and lines, gets lines in
  the same commit as the model.
- **Never an empty group column**: it gives every user, portal and public
  included, those rights, and it overrides the scoped lines.
- `base.group_user` lines give every internal user the right whatever their
  roles: only for read on harmless vocabularies (types, tags).
- `perm_unlink` stays 0 on operational records (signals, incidents, cases,
  reports, logs): they are closed or cancelled with a reason, not deleted.

## 7. Record rules

**Place.** Use the platform helper, never a hand written geography domain:

```xml
<record id="rule_eoc_thing_area_read" model="ir.rule">
    <field name="name">Thing: read within the user's area</field>
    <field name="model_id" ref="model_eoc_thing"/>
    <field name="global" eval="True"/>
    <field name="domain_force">user.area_domain('state_id', 'district_id')</field>
    <field name="perm_read" eval="True"/>
    <field name="perm_write" eval="False"/>
    <field name="perm_create" eval="False"/>
    <field name="perm_unlink" eval="False"/>
</record>
<record id="rule_eoc_thing_area_change" model="ir.rule">
    <field name="name">Thing: change within the user's area</field>
    <field name="model_id" ref="model_eoc_thing"/>
    <field name="global" eval="True"/>
    <field name="domain_force">user.area_domain('state_id', 'district_id', national=False)</field>
    <field name="perm_read" eval="False"/>
    <field name="perm_write" eval="True"/>
    <field name="perm_create" eval="True"/>
    <field name="perm_unlink" eval="True"/>
</record>
```

`area_domain` handles national users, administrators, the organization scope
(Region and Country) and records with no geography. Its arguments name your
model's fields; `also=[...]` adds leaves that open a record anyway (its
creator, its followers). For records attached to health facilities,
`user.facility_area_domain(...)` does the same.

**Clearance.** A model that can hold sensitive content mixes in
`eoc.confidentiality.mixin` and gets the global rule, with no bypass for any
group:

```xml
<record id="rule_eoc_thing_confidentiality" model="ir.rule">
    <field name="name">Thing: confidentiality clearance</field>
    <field name="model_id" ref="model_eoc_thing"/>
    <field name="global" eval="True"/>
    <field name="domain_force">['|', '|',
        ('confidentiality_rank', '&lt;=', user.confidentiality_level),
        ('create_uid', '=', user.id),
        ('message_partner_ids', 'in', [user.partner_id.id])]</field>
</record>
```

**Children.** A model reached through a parent (lines, updates, actions,
acknowledgements) gets the parent's rules routed through the relation
(`('parent_id.incident_id', ...)`), on both axes. A child with an access line
and no rule is readable across every incident. Incident children are covered
by `eoc_incident_management/tests/test_rule_coverage.py`: a new model there
must classify itself in that test.

Rules cover write as well as read. Global rules narrow everyone; group rules
widen within the global ones.

## 8. Models and fields

- `_description` on every model, `_order` that makes sense to a reader,
  `mail.thread` and `mail.activity.mixin` on operational records, `tracking`
  on fields whose change matters operationally.
- **Mixins to reuse, not rewrite:**
  - `eoc.confidentiality.mixin`: the five level classification and its rank;
  - `eoc.geo.label.mixin`: level labels that follow the database on geography
    fields named `country_ids`, `state_ids`, `district_ids`,
    `sub_district_ids` (or the singular `_id` fields);
  - `eoc.geo.admin.mixin`: the write fence by place used by signals and
    incidents;
  - `eoc.justification.mixin`: the reason kept for a discard, an override, a
    rejection;
  - `eoc.home.defaults.mixin`: prefill the user's own area on a new record's
    form, opted in per model by naming the fields.
- Store keys, never labels. Never hardcode a level name or a country.
- A state change that matters stamps who and when, and those stamps are never
  backdated or overwritten.
- Identity, contact and health status fields get `groups=` or live on a model
  fenced by clearance.
- Dates: onset, specimen, report and entry are different dates. Never reuse
  `create_date` as an epidemiological date.

## 9. Menus

- The app root carries `groups=` (a root without it is shown to every internal
  user) and a `web_icon`.
- Entries in the order of the work: daily work first, dashboards and reports,
  Configuration last; User Roles last inside Configuration.
- An existing restriction is only removed with an explicit
  `groups_id (5, 0, 0)` record: a menuitem only adds groups.

## 10. Settings page

Settings go in an `<app>` block of `res.config.settings` with a `logo`, and
titled blocks (`<block title=... help=...>`) grouping related settings. A
Boolean setting that should default to on does not use `config_parameter=`
(unticking deletes the parameter, and a missing parameter reads as off): store
an explicit 'True' or 'False' in `get_values` and `set_values`. Read integer
parameters with a default for a missing value (`int(False)` is 0, not your
default).

## 11. My Desk

My Desk is every user's own page. A module whose users have daily work can add
a card through `_extra_cards` on `eoc.field.desk` (see
`eoc_casualty_surveillance/models/my_desk.py`).

## 12. Translations

- Every user facing string is translatable: `_()` in Python code that runs per
  request, `_lt()` for strings defined at import time (selection labels in
  Python, tables of labels).
- Ship `i18n/<module>.pot` and `fr.po`, `ar_001.po`, `pt.po`. The ePHEM repo's
  `scripts/i18n/README.md` describes the export and the merge. A `.po` entry
  missing from the `.pot` is never loaded.
- Arabic is right to left: check every screen in Arabic, never set letter
  spacing on Arabic text (it breaks the joined letters).

## 13. Tests

- One test class per concern: access per role, record rules, the workflow,
  the computations.
- **Test as the people who will use it**, not as administrator: a user holding
  only the lowest role of the module, at district level, with a low clearance.
  Read every menu's records through each view's fields as that user.
- Users created in a test get roles, a level and areas explicitly; set
  `eoc_demo_mode.active` to `'False'` in `setUpClass` first.
- Tag tests that need every module loaded `@tagged('post_install', '-at_install')`.

## 14. Icon and README

- `static/description/icon.png`: the Apps page reads it from there. The ePHEM
  team generates the house icons (app artwork with the ePHEM badge); ask for
  one in the pull request.
- `README.md`: what the module is for, its roles and who manages them, its
  settings, and any data step a deployment must do after installing it.
