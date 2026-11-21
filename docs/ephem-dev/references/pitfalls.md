# Pitfalls that recur, and their fixes

Every item here was found more than once in ePHEM code reviews. Check your
diff against this list before asking for a review; reviewers check it too.

## Access and data reach

1. **`sudo()` for convenience drops every record rule.** A controller or method
   runs `.sudo()` and hands back the result: a district user reads the
   country, a clearance 2 user reads a clearance 4 note.
   *Fix:* check access as the user first; `sudo()` only for the one thing they
   may not do, on the records the check returned, with a comment.

2. **A child model with an access line and no record rule.** Lines, updates,
   actions and acknowledgements that reach their incident only through a
   parent escape the incident's rules: any incident user reads and writes them
   across every incident. It happens on both axes: a child can have the
   involvement rule and still miss the clearance rule.
   *Fix:* route both rules through the parent relation; classify the model in
   `eoc_incident_management/tests/test_rule_coverage.py`. When adding a
   clearance rule, give it no bypass for managers.

3. **An access line with an empty group.** Gives every user, portal and public
   included, those rights, and overrides the scoped lines. Same on a shared
   model another module owns: one empty group line there bypasses every guard
   built on it.
   *Fix:* a group on every line.

4. **A geography rule that ORs every area field.** A district user who also
   has their state on their record reads the whole state.
   *Fix:* `user.area_domain(...)`: the area that counts is the one of the
   user's level.

5. **A page reads a linked record as the user.** A dashboard, a computed card
   or a controller walks from a record the user may read to one they may not,
   and one such row raises an access error for the whole page. It works for
   administrators and national users, and is dead for everyone else.
   *Fix:* store what the page needs on the readable record; or
   `records._filtered_access('read')` and degrade; `sudo()` only for a count or
   a yes or no about a record the user may already read.

6. **A relational field with no fence.** A task's many2one to a request, with
   no domain, lets a user pick another incident's record.
   *Fix:* a `domain` on the field and an `@api.constrains` that refuses it.

7. **A follower grant that is never pruned.** Raising a record's
   classification leaves every earlier follower able to read it.
   *Fix:* when the level goes up, remove followers below it.

8. **Discuss channels are public by default.** A channel of type `channel`
   with no group is listed and joinable by every internal user.
   *Fix:* member only channels are type `group`.

## Data and computation

9. **A stored computed field that depends on "now".** `store=True` with a
   compute reading `fields.Datetime.now()` runs at create and never again:
   "expired", "overdue", "today" flags stay wrong forever, and so do the
   counts, badges and searches built on them.
   *Fix:* `store=False` with a `search=` method, or compare the timestamp at
   read time.

10. **Data records in `noupdate="0"`.** Stages, sequences, roles, templates:
    every update rewrites what an administrator renamed.
    *Fix:* `noupdate="1"`. Flipping an existing block does nothing on existing
    databases (the flag on each `ir.model.data` row decides): add a migration.

11. **A stored writable related field on a shared parent.** Every sibling gets
    the same value: closing one branch of a response closed all of them.
    *Fix:* a real field on the child.

12. **A policy guard lost when a field moves.** Splitting a related field into
    a real column drops the check that lived on the old owner.
    *Fix:* move the guard with the field; grep every writer of the old field.

13. **A migration touching a table an older database never had.** Fails the
    update for every older database.
    *Fix:* guard each `pre-migrate.py` statement with `to_regclass` or an
    `information_schema` check; in `post-migrate.py` check
    `field in env[model]._fields` before touching another module's field.

14. **A module scoped to the company's country fails silently** when the
    company country differs from the users' geography: a correctly scoped user
    sees an empty list and no error.
    *Fix:* show the scoping country on the settings page and in the empty
    list's help.

15. **Integer settings read as 0 when missing.** `int(get_param(...))` on a
    missing parameter gives 0, not your default. A Boolean setting with
    `config_parameter=` deletes the parameter when unticked, so a setting meant
    to default to on reads as off.
    *Fix:* test for a missing value first; store explicit 'True' or 'False'.

## Views and client code

16. **A view modifier on a field the view does not load.** `invisible`,
    `readonly` or `required` naming a field absent from the view misbehaves
    silently in Odoo 18.
    *Fix:* add `<field name="x" invisible="1"/>`.

17. **An onchange compares a new record's relations with real records.** In an
    onchange the record is new: its many2many values wrap the real records and
    never equal them, so "is this partner already there" is always false.
    *Fix:* compare on `._origin`.

18. **A wizard's `default_` context leaks into what it creates.** Opened with
    `default_signal_ids`, its action creates a record that takes those
    defaults.
    *Fix:* `self.with_context(clean_context(self.env.context))` before
    creating.

19. **An OWL template calls a JavaScript global.** `String(x)`, `Number(x)`,
    `JSON.stringify`, `parseInt` in a template expression become `ctx.String`
    and crash the whole client action, only when that branch renders. A loop
    variable named `window` reads the browser's window.
    *Fix:* a component method.

20. **A button whose method does not exist** is refused when the view loads in
    Odoo 18 ("is not a valid action"): the module fails to install.
    *Fix:* name the method exactly.

21. **A library or font from a CDN.** Breaks every offline training and field
    site; a failing load inside `onWillStart` kills the view.
    *Fix:* ship it in the addons.

22. **A mixed unit `min()` or `max()` in SCSS** kills the whole stylesheet
    bundle.
    *Fix:* a media query.

23. **A hardcoded colour, level name or country.** Stops following the theme,
    the deployment's labels, the organization shape.
    *Fix:* tokens, level labels, data.

## Communication

24. **Official email sent from the user's personal address.**
    *Fix:* From is the company address, Reply To the sender's; refuse when
    either is missing; only the official communications role sends.

25. **Case details in an email body.** Names, diagnoses or restricted notes in
    a message that leaves the system.
    *Fix:* a tokenized link to the record instead.

26. **Find and replace artifacts in produced text.** An empty value placeholder
    became a lone comma inside frozen official documents.
    *Fix:* read the rendered document, with empty values too.

## Process

27. **Tests only as administrator.** Most access bugs live in what lower users
    cannot do.
    *Fix:* test as a user with only the lowest role, at district level, with a
    low clearance; read every menu's records through each view's fields.

28. **Spot fixing one instance of a class.** Fixing the one place a reviewer
    pointed at leaves the others: the same class keeps returning.
    *Fix:* enumerate every instance (every model, every rule, every route)
    once, fix them all, and pin it with a test that fails for the next one.

29. **A large mechanical change without its own review.** Tightening many rules
    at once newly blocks legitimate users (a missing parent makes a record
    invisible; a new rule silently drops branches the old one granted).
    *Fix:* after a sweeping change, test each role again, not only the cases
    you changed.

30. **Verifying a claim from memory.** "This method was removed in Odoo 18",
    "these files are tests": automated review is often wrong about this
    codebase.
    *Fix:* check in the code or a shell before changing anything.
