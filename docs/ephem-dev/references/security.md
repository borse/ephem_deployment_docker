# Security: the gate every relevant diff passes

ePHEM holds case level health data for ministries and regional agencies. A
leak here exposes patients, contacts and confidential assessments. Treat every
change that touches who can reach data, or anything an outside caller can
call, as a security change.

## 1. When to run the checklist

Before showing a diff that adds or changes any of these: a model, a controller
or route, an `ir.model.access.csv` line, an `ir.rule`, a `sudo()`, SQL, a token,
an email template carrying a link, an export, a report, a dashboard data
source, an API resource, a cron that calls an outside service, or a field that
stores who someone is or what they have.

It is a code read, two minutes on a small diff. Report it in three or four
lines with the rest of your report:

```
Security: new model eoc.thing has access lines for 3 groups and the area and
clearance rules. One sudo in models/thing.py:88, reading a system parameter
only. No new routes. Nothing exported.
```

If something fails and cannot be fixed inside the task, say so, with file and
line. Do not widen the task quietly, and do not ship it quietly.

## 2. The checklist

**Reach**
1. Every new model has `ir.model.access.csv` lines, per group, in this commit.
2. `perm_unlink` is 0 unless deletion is genuinely intended (signals,
   incidents, cases, reports and logs keep their history).
3. Data scoped by place, incident or clearance has a matching `ir.rule`, and
   the rule covers write as well as read.
4. Any new field holding a person's identity, contact or health status has
   `groups=` or sits on a model fenced by clearance.
5. A model that can hold sensitive content mixes in
   `eoc.confidentiality.mixin`, and its default level is not more open than
   the content justifies.
6. A new one2many or related field does not make a child more visible than its
   parent.

**sudo**
7. Every new `sudo()` has a one line reason above it.
8. No `sudo()` wraps a whole method or controller body.
9. No `sudo()` on a search domain or a browse of ids that came from the caller.
10. Where an access check exists, `sudo()` comes after it and applies only to
    the records that check returned.

**Routes**
11. Every route states its `auth` deliberately; a public route authenticates
    inside the handler and denies by default.
12. `csrf=False` only for a machine caller, never on a route a browser session
    reaches.
13. Tokens, keys and signatures are compared with `hmac.compare_digest` or
    `odoo.tools.consteq`, never `==`.
14. Records reached from an id and a token are resolved through the portal
    access check, never from the id alone.
15. Writable fields are an explicit list. Never `write(kwargs)` or
    `create(vals)` with a dict from the request.
16. Incoming values are validated: type, range, length, allowed selection
    values, payload size.
17. Errors returned to an anonymous caller are generic; the detail goes to the
    log.

**Injection**
18. No f string, `%` or `.format()` around a value inside `cr.execute`: pass
    parameters, or use `odoo.tools.SQL`.
19. No domain built or evaluated from text a user typed. Dashboard measures and
    group bys come from a declared list.
20. Output is escaped: `t-out`, never `t-raw`; `Markup()` only around strings
    your own code built.

**Data leaving the system**
21. Email bodies carry no case names, diagnoses or content restricted by
    clearance.
22. Links in email are tokenized, expire, and are built from `web.base.url`.
23. A new export, report, dashboard source or API resource checks the same
    fences the form view path applies (it runs as the user, or checks them again).
24. No secret in code, XML data, a manifest, a commit message or a log line.
25. Outbound calls have timeouts, verify TLS, and target a host from
    configuration, never from input.

**Trail**
26. State changes that matter operationally stamp who and when and cannot be
    silently overwritten.
27. Nothing deletes a justification, an override reason or a log row.

## 3. sudo, in one paragraph

Odoo's record rules are what keep a district officer inside their district and
a clearance 2 user away from a clearance 4 note. `sudo()` switches all of that
off. So: check access as the user first (`check_access`, a search as the user,
`_filtered_access('read')`), then use `sudo()` only for the one thing the user
may not do themselves (reading a system parameter, writing a log, counting
records they are allowed to know exist), on the records that check returned,
with a comment saying why. A page that fails for some users because a linked
record is out of their reach is fixed by degrading for them (skip, count,
show a placeholder), not by `sudo()` over the whole page.

## 4. House patterns to copy

Do not invent a new mechanism for these: copy the reviewed one.

| You need | Copy |
|---|---|
| a tokenized link sent by email (reply without logging in) | `eoc_incident_management/models/reporting_request.py`, `coordination_action.py`, `controllers/portal_ear.py` |
| an endpoint a device or another system posts to | `eoc_emt/controllers/main.py` |
| an API resource for another system | `ephem_api_base/` (native hashed API keys, the request runs as the key's user, a group per resource, a logged call, a common envelope, a declared registry of resources) |
| official email from the organisation | `eoc_mass_mailing_tailoring`: From is the company address, Reply To is the sender's own, only `group_official_communications` may send, refuse when either address is missing |
| a connector that holds credentials | credentials in `ir.config_parameter` or a fenced model with `groups=` on the secret; timeouts; TLS verified; host from configuration; the fetch runs as a technical user with minimum groups |
| fetching a link a user or a feed gave you | `eoc_ai/models/safe_fetch.py` (never `requests.get` on a URL from input) |
| parsing a file from outside | `eoc_base/models/document_compression.py` |

An API account is a technical user holding one `ephem_*_api_*` role, never a
person's account.

## 5. Stop and discuss

Any of these in a diff is not a detail to fix later:

- `auth='public'` with no authentication inside the handler
- `cors='*'` on anything that is not a deliberately public read
- `csrf=False` on a route a browser session can reach
- a URL or host taken from the caller and fetched by the server
- writing a file to disk from a request handler
- `==` on a token, a key or a signature
- `.browse(int(request.params['id']))` followed by `.sudo()`
- `write(kwargs)` or `create(vals)` where the dict came from the request
- an f string or `%` inside `cr.execute` around a value
- a secret in code, XML data, a manifest or a log line
- a new model with no access line
- an access line with an empty group
- a new sensitive field with no `groups=` and no clearance on its model
- an email body containing a case name, a diagnosis or a restricted note
- a new security group for a place or a clearance level

## 6. Reviewing a module you did not write

Orient yourself fast, then read in this order: routes, models with no access
file, `sudo()` calls.

```bash
M=eoc_mymodule
grep -rn "auth=['\"]\(public\|none\)['\"]\|csrf\s*=\s*False\|cors=" --include=*.py $M
grep -rn "\.sudo()" --include=*.py $M | wc -l
grep -rn "cr\.execute" --include=*.py $M | grep -E "%|format\(|f\"|f'"
ls $M/security/
grep -rn ",,1\|,,0" $M/security/ir.model.access.csv     # an empty group column
```
