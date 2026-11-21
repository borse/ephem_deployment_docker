# User experience and usability standards

Who uses ePHEM: surveillance officers, EOC staff, managers and field focal
points, often during an emergency, tired, working fast, on a laptop in a
crowded room, on a wall display, or on a phone with a weak connection. In
English, French, Portuguese and Arabic (right to left). Every rule below comes
from that.

The numbers are limits for new work and for screens you change. A few older
screens exceed them; do not make them worse, and bring them within the limit
when you rework them.

---

## 1. Forms

**The sheet**
- The record's name or title first, as the heading. Then the fields people need
  to understand the record at a glance, in two column groups. Roughly twelve
  fields before the first tab; more than that is a sign some belong in a tab.
- Order fields as the work happens, not as the model declares them.
- Required fields are only those needed to save. Everything else has a safe
  default or can be filled later. Prefill the user's own area through
  `eoc.home.defaults.mixin` rather than asking.
- A field whose meaning is not obvious has `help`. A field that only matters in
  some states is `invisible` in the others.

**The notebook**
- **At most five tabs on the rendered form**, counting tabs other modules add
  to it by inheritance. A module that would push a form past five adds a
  section to an existing tab, a smart button or a separate screen instead.
- A tab holding three fields or fewer belongs on the sheet.
- The first tab is the one used every day. Tabs for configuration, history or
  technical detail come last.
- A tab that does not apply to this record is hidden, not shown empty.
- Tab names are one to three words, nouns, in the user's language
  ("Verification", "Sources", "Risk assessment").
- No notebook inside a notebook.

**The header**
- **At most three action buttons visible** at any one state, and one of them
  primary (`btn-primary` or `oe_highlight`). Rarer actions go in the action
  menu or behind a smart button.
- The status bar shows the main path only (`statusbar_visible`, at most six
  states). Side states (cancelled, discarded, on hold) appear when the record
  is in them.
- A destructive or irreversible action (discard, close, cancel, delete, send)
  asks for confirmation (`confirm=`), and the confirmation says what will
  happen ("Close this incident? Tasks still open will be cancelled."). Where
  doctrine needs a reason (discard, override, rejection), the button opens a
  wizard with a required reason instead.
- Button labels are verbs that say what happens: "Send to Signals", "Start
  Verification", "Approve Request". Never "Process", "Submit" alone, "OK".

**Smart buttons**: at most five visible, each a count and a noun ("4 Tasks"),
each opening the records it counts.

**Chatter** stays at the bottom (the theme does it, popups included). Track the
fields whose change matters operationally (status, owner, level, dates), not
every field.

**Record popups.** Open an existing record in a popup with a plain
`target: 'new'` action: the theme turns it into the house popup (Cancel, the
status bar, the buttons and the chatter) and stacks it over any open dialog.
Do not build your own record dialog.

## 2. Wizards and dialogs

- One decision per wizard, on one screen. Several decisions in a row are
  several steps the user can see, or several wizards.
- The primary button says what happens ("Discard Signal", "Send"), the other
  is Cancel.
- A wizard never creates or changes records before its button is pressed.
- A wizard's action clears the `default_` keys of its own context before
  creating records (`clean_context`), or they leak into what it creates.

## 3. Lists

- **At most eight columns shown by default.** The rest are
  `optional="hide"` so people can add them.
- The column people scan first comes first (name, reference, date), status
  near the end, as a badge.
- A sensible default order: newest first for operational records.
- Dates and times show in the user's time zone.
- Row colours through `decoration-*` attributes, which follow the theme.
- No editable lists for records with a workflow: open the form.
- No per row computation that is not stored on large lists: it loads every row.

## 4. Search, filters and grouping

- Default filters that match how people work: "My area", "Open", "This week".
  Where the module has levels, the user's own level is the default facet.
- At most ten filters, grouped by meaning with separators.
- Group by for status, area and period. Searches on names cover the fields
  people actually type (name, reference, place).

## 5. Kanban

Use the signal board's card: `oe_kanban_card oe_kanban_global_click
o_ephem_kcard` on a classic `kanban-box` template, a title, one chip for the
state, two or three meta lines, counts in the footer. A card is read in one
glance: no more than five pieces of information.

## 6. Menus

- **At most seven top level entries** in an app's menu.
- Order of the work: daily work first, then dashboards and reports,
  Configuration last; User Roles last inside Configuration.
- Entry names are short nouns ("Signals", "Daily Reports"), not verbs and not
  module names.
- One action, one menu entry: no two entries opening the same screen.
- Every root menu carries `groups=`.

## 7. Words on the screen

- **In the user's words, not the model's.** "Date of onset", not
  "onset_dt". "Responses", not "Incidents records".
- **Say what will happen** on buttons and in confirmations.
- **No dash punctuation** in anything a person reads: labels, help, selection
  values, messages, emails, reports, PDF documents. Use a comma, a colon,
  parentheses, or rewrite the sentence.
- **Never hardcode a level name or a country.** "State", "District",
  "Governorate", "Region" depend on the deployment: read the level label.
  Never write a country's name into shared code.
- **Never name an internal team** in a report or an email ("the surveillance
  team"): reports speak for the organisation and carry the sender's signature.
- **Capitalisation**: buttons and menu entries in Title Case, as Odoo does;
  help texts and messages as sentences.
- **Errors say what to do next**: "Add a verification source before marking
  this signal verified." not "Validation error".
- **Empty lists explain themselves**: what the list holds, how to add the first
  record, and why it may be empty for this user (their area, their level).

## 8. Colour, theme and dark mode

- **Never write a colour literal** in a component, a view or SCSS. Use
  `var(--ephem-accent)`, `var(--ephem-accent-2)`, the `ephem-` utility classes
  (`ephem-btn-brand`, `ephem-bg-navy`, `ephem-text-danger`,
  `ephem-alert-warning`, `ephem-tint-pale-sky`...) and, on dashboards, the
  `--cmp-dash-*` tokens. An administrator can recolour the platform at
  runtime; a literal stays the old colour.
- **Bad news is red, never the brand colour.** A decline, a value below target
  or a failed state uses the negative red (`--cmp-dash-negative`). The brand
  colour is for brand, neutral and positive accents.
- Text on a coloured fill uses `--ephem-NAME-text` or `--ephem-on-accent`,
  never a hardcoded white.
- Radius, shadow, transitions, hairlines and surfaces are tokens of the theme:
  do not invent new ones.
- **Check dark mode** (toggle it from the top bar) before calling UI work done.
  White on white or grey on grey means a hardcoded colour somewhere.
- **Do not rely on colour alone**: a state also has a word or an icon, for
  people who do not see the difference and for black and white printouts.

## 9. Right to left

- Check every new screen in Arabic. In the web client Odoo flips left and right
  in your SCSS for you. PDF reports (QWeb through wkhtmltopdf) are not flipped,
  and logical properties (`padding-inline-start`, `text-align: start`) are
  ignored there: write explicit `body[dir="rtl"]` rules in report styles.
- Wrap what must never flip (maps, charts drawn in a fixed direction) in
  `/*rtl:begin:ignore*/ ... /*rtl:end:ignore*/`.
- Never set letter spacing on Arabic text, and never build a sentence by
  joining translated fragments: translate the whole sentence with
  placeholders.

## 10. Dashboards

- **One request** returns the page: the server aggregates (`_read_group` or one
  query) and the client draws. Never a request per card.
- It **runs as the user**, so the record rules apply. Any cache key holds the
  user, the companies, the language and a data stamp.
- **Nothing from a CDN**. Chart.js through Odoo's own `web.chartjs_lib`; other
  libraries ship in the addons.
- First paint is a skeleton; a cached payload is painted while the fresh one
  loads; filters are debounced and stale answers dropped.
- Every figure opens the records behind it, with the same domain the server
  used.
- **Designed from its subject.** A page of identical cards, percentage rings
  and doughnuts says nothing about the work. Start from one idea taken from
  the subject (a muster of responders, the steps of the workflow as columns)
  and keep the rest quiet. The shared board look is
  `eoc_base/static/src/scss/ephem_board.scss` (`o_eb_page`, the `o_eb_`
  classes): use it rather than a new design language.
- Wall displays run for days with nobody logged in nearby: no memory that
  grows, charts and maps destroyed on unmount, failures caught and retried
  quietly.
- Rates show their denominator; weekly figures say which week convention they
  use.

## 11. Offline and low bandwidth

- No script, stylesheet, font or map tile from the internet that the page
  needs to work. A failed external load must not break the view.
- Maps use keyless basemaps, and each overlay catches its own failure and
  warns once.
- Large pages load in parts: the form first, heavy tabs on demand.

## 12. Settings pages

An `<app>` block with the module's `logo`, titled blocks (`title`, `help`)
grouping related settings, each setting with a short help. Group by what the
administrator is trying to do (features, notifications, data entry), not by
model.

## 13. Before you call a screen done

- [ ] Within the limits: five tabs, three header buttons, eight list columns,
      seven menu entries, five smart buttons.
- [ ] Labels in the user's words, buttons say what happens, no dashes, no
      hardcoded level names.
- [ ] Opened as a user holding only the lowest role, at district level: no
      error, nothing they should not see.
- [ ] Light and dark mode; English and Arabic.
- [ ] Narrow window and wide wall display.
- [ ] Nothing loaded from the internet.
