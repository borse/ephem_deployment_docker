# Dashboards: loaded on the server, cached in one place

Every ePHEM dashboard, wall display and analytics page is computed on the
server and drawn in the browser, and its answer is kept for a short time by
one shared cache in `eoc_base`. This file is how to build one that way, and
what a reviewer checks. The look of a dashboard is in `ux-standards.md`
section 10.

---

## 1. Server side loading

**One request returns the page.** The browser asks once, with the filters; the
server reads, counts and aggregates; the browser draws what comes back.

| Kind of page | Where the data method lives | Called from the browser with |
|---|---|---|
| A dashboard in the backend | `get_data(self, filters=None)` on an `AbstractModel` named `eoc.<thing>.dashboard`, `@api.model` | `this.orm.call('eoc.<thing>.dashboard', 'get_data', [filters])` |
| A wall display, an analytics page shared with mobile | a JSON route, `type='json', auth='user'` | `rpc('/eoc_<thing>/wall/data', {...})` |

Copy `eoc_signals_dashboard/models/dashboard.py` (model) or
`eoc_signals/controllers/ebs_analytics_controller.py` (route).

The rules:

- **Count on the server.** `_read_group`, `search_count` or one query. The
  browser never calls `searchRead` or `readGroup` to count, and never one
  request per card. The only reads the browser may do itself are lookups for
  the filter lists (hazards, regions); better, return them in the payload
  (`options`).
- **Return what is shown, not the records.** Totals are counted over the full
  set; lists in the payload are capped (the twelve most recent, the fifteen
  longest waiting). A Gantt or a table that draws one row per record caps its
  rows and says so.
- **Run as the user.** Call `dashboard_read()` first (it lets a dashboards
  viewer count within their record rules), check the user may open the page,
  then read with the user's environment so the record rules apply. `sudo()`
  only for lookups (names of areas, source types), never for the records
  counted.
- **Guard the volume.** Count before reading; above the limit return
  `{'error': 'too_many_...', 'matched': n, 'limit': max}` and let the page ask
  for a shorter period. A refusal must be cheap.
- **One engine per measure.** Two pages that show the same figure call the
  same code, so they agree. The signals dashboard grades signals with the EBS
  Analytics engine (`_metrics_for`, `_tally`), and both leave out the copies
  through `eoc.signal._ebs_copy_domain()`. A country widens a rule by
  overriding the hook, never by editing one page.
- **Settings, not constants.** A clock, a target or a threshold a country may
  set is read from settings in the data method (see `process_clocks` in
  `ebs_analytics_controller.py`), and the labels name the value read ("within
  %s hours"), never a number written in a string.

---

## 2. The cache: `@dashboard_cached`

`eoc_base/models/dashboard_cache.py`. Put it on the data method, under
`@api.model` or under `@http.route`:

```python
from odoo.addons.eoc_base.models.dashboard_cache import dashboard_cached


class ThingDashboard(models.AbstractModel):
    _name = 'eoc.thing.dashboard'

    @api.model
    @dashboard_cached('eoc.thing', 'eoc.thing.line')
    def get_data(self, filters=None):
        dashboard_read()
        ...
        return {...}
```

```python
class ThingWall(http.Controller):

    @http.route(['/eoc_thing/wall/data', '/<lang>/eoc_thing/wall/data'],
                type='json', auth='user', website=False, methods=['POST'])
    @dashboard_cached('eoc.thing')
    def wall_data(self, period=None, lang=None):
        return request.env['eoc.thing']._wall_picture(period_days=period or 30)
```

Inside `eoc_base` itself import it relatively (`from .dashboard_cache import
dashboard_cached` in a model, `from ..models.dashboard_cache import ...` in a
controller).

**What it does.** The same question asked again within the TTL is answered
from memory, without touching the data. The answer is kept in each worker
process (at most 128 answers and 96 MB per worker, 12 MB per answer); nothing
is written to the database; a restart or an update empties it.

**What the key holds**, so an answer is only ever given back to the same
question from the same person:

- the user, their groups, the last change to their user record (an area or a
  clearance), the active companies, the whole context (language, time zone),
  whether the request counts as a dashboards viewer;
- the method, the records it was called on, every argument;
- for each model named in the decorator, and always for the system parameters:
  a change counter raised on every ORM create, write and unlink in this worker
  (it sees a change made in the same transaction), and the table's row count
  and newest `write_date` (it sees the changes of the other workers).

So a record created, edited or deleted in a named model, or a setting changed,
shows on the next load. **The TTL bounds the rest**: what neither can see (a
renamed hazard, a team membership, a raw SQL update, another worker's long
transaction). Default 120 seconds; the system parameter
`eoc_base.dashboard_cache_ttl` changes it for every dashboard, and `0`
switches the cache off (to measure, or to rule it out while debugging).

**Which models to name.** The ones whose rows the dashboard counts: the
records it searches, and the ones whose state decides a figure (the signals
dashboard names `eoc.signal`, `eoc.emergency.base`,
`eoc.emergency.risk.assessment`, `eoc.signal.sources`). Leave out lookups that
rarely change (areas, hazards, types): the TTL covers them. Every model named
costs one small count per request.

---

## 3. Rules for a cached method

1. **It returns plain data**: dicts, lists, numbers, strings, dates. Never a
   recordset, an action or a report action (`action_print` is not cached; a
   report's `_get_report_values` that calls `get_data` profits from it).
2. **It has no side effect.** On a hit the body does not run: no write, no
   email, no "last seen" stamp, no log line that matters.
3. **Everything the answer depends on is in the key.** The user, their groups,
   the context and the arguments are. Something else (a record the user
   follows, a value read from the request, a browser cookie) is not: pass it
   as an argument, or keep the check outside the cached method.
4. **A refusal is a dict with `error`, or an exception.** Neither is kept, so
   the next request checks again.
5. **The caller may change what it gets.** Answers are copied in and out; an
   override that calls `super()` and adds a key never changes the cached one.
6. **Cache the base method, not an override.** An inheriting module's
   `get_data` that calls `super()` gets the cached base and adds its part
   fresh. Do not decorate both.
7. **Figures relative to "now"** (ages, "waiting since") may be up to the TTL
   old. That is fine for a dashboard; a countdown to the second is computed in
   the browser.
8. **Do not write another cache.** Four pages predate this one and keep their
   own: ePHEM Analytics (`cmp.dashboard.cache`, with a floor on live polling),
   RRT analytics (`rrt.analytics.cache`), the incident dashboard (in memory in
   `incident_dashboard_controller.py`) and the facility overview. New code
   uses `@dashboard_cached`.

---

## 4. Tests

The cache is live in tests. The change counters make a change made through
the ORM on a named model visible in the same test, so a test that reads the
dashboard, creates a record and reads again sees the new record. Two cases
need care:

- A test that changes something the decorator does not name (a lookup, or a
  raw SQL update) and reads again: call
  `odoo.addons.eoc_base.models.dashboard_cache.clear()` first, or set
  `eoc_base.dashboard_cache_ttl` to `'0'` in `setUp`.
- A test of the cache itself: see `eoc_base/tests/test_dashboard_cache.py`.

Test the payload as the people who will use it (a district user with the
lowest role), and assert a figure against a count of the same records
(`search_count` with the dashboard's own `_domain`).

---

## 5. What is cached today

| Module | Data methods |
|---|---|
| `eoc_signals` | EBS Analytics (desk, wall, mobile), signal report, source analytics, signal dashboard |
| `eoc_signals_dashboard` | `get_data` |
| `eoc_incident_management` | EAR analytics and wall, acute incidents (the incident dashboard has its own cache) |
| `eoc_dashboard` | CIR |
| `eoc_regional_level` | the regional signal, signal report and incident dashboards |
| `eoc_casualty_surveillance`, `eoc_referral` | casualty dashboard and wall, referral wall |
| `eoc_daily_sitrep`, `eoc_phsm`, `eoc_4w`, `eoc_base` | sitrep dashboard, PHSM (both), 4W board, STAR counts and map |
| `eoc_campaign_dashboard`, `eoc_ambulance_reports`, `eoc_emt_dashboard`, `eoc_emt_activation`, `eoc_incident_dashboard` | their `get_data` / activation dashboard |
| `eoc_medequip_reports`, `eoc_stores_reports`, `eoc_supply_chain` | equipment and inventory, stores, stock readiness, inbound finance, national issues |
| `eoc_workforce_dashboard`, `eoc_actors`, `eoc_rrt`, `eoc_facility_services_dashboard` | workforce (both), RRT programme and member pages, facility services overview and detail |

A new dashboard is added to this table in the same pull request.

---

## 6. Review checklist

- [ ] One request per page; counted on the server; the browser reads only
      lookups.
- [ ] `dashboard_read()`, an access check, then the user's environment;
      `sudo()` only for lookups.
- [ ] A volume guard that refuses cheaply with an `error` payload.
- [ ] A figure shown on two pages comes from one engine.
- [ ] Country values read from settings, and named in the labels.
- [ ] `@dashboard_cached(...)` on the data method, naming the models it
      counts; no side effect; plain data; no second cache.
- [ ] Tests as a low user; a figure checked against a count.
