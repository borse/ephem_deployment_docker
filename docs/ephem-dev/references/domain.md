# The domain: what the models mean

ePHEM implements public health emergency management doctrine. Field names,
defaults and workflow states carry operational meaning: a change that looks
harmless in code can break how an emergency operations centre (EOC) works.
Read this before designing a feature, naming a field or changing a state.

## 1. Vocabulary that changes code

- **Signal.** Raw information that might indicate a health threat: a
  surveillance report, a media item, a hotline call, a rumour, a laboratory
  flag. Not yet true. Most signals are discarded, and the discard keeps its
  reason.
- **Verification.** Turns a signal into a confirmed event, against the clock.
  The verification timestamps are a performance indicator: never overwrite or
  backdate them, never let a state change skip writing one.
- **Risk assessment.** Hazard, exposure and context give a risk level. ePHEM
  keeps the computed level and the level the team decided, with the
  justification of any override. Never merge the two.
- **Grading and activation.** How much response an event needs, which sets the
  EOC activation level: staffing, reporting rhythm, authority. An operational
  commitment, not a label.
- **Event and incident.** The event happens in the world; the incident is the
  organisation's managed response to it. One event can produce several
  incidents.
- **Case and line list.** A case is one person meeting a case definition; the
  line list is the working table of cases. Both are personal health data:
  every exposure of them is a data protection decision.
- **Dates.** Onset, specimen, report and entry are four different dates.
  Analysis goes by onset, operations by report. Never reuse `create_date` as an
  epidemiological date.
- **Epidemiological week.** Its first day varies by country. Say which
  convention a weekly figure uses.
- **Rates need denominators.** Never show a rate whose denominator the user
  cannot see.

## 2. The operational cycle and its models

| Step | What happens | Models |
|---|---|---|
| Detect | signals arrive from surveillance, media, hotline, partners, connectors | `eoc.signal`, `eoc.signal.sources`, `eoc_call_center`, connectors |
| Triage | duplicates, relevance, assignment | signal stages and definitions |
| Verify | contact the source, confirm or discard, record why | verification fields, `eoc.justification.mixin` |
| Assess risk | likelihood and consequence, computed and decided level | `eoc.emergency.risk.assessment` |
| Grade and activate | response scale, activation level | activation level models |
| Command | stand up the incident management system | `eoc.ims`, sections, units, functions, `eoc.command.handoff` |
| Plan | objectives for one operational period, the action plan | `eoc.incident.iap`, objectives, response plans, pillars |
| Task and coordinate | work for actors and partners, acknowledgements | `incident.task`, coordination actions, reporting requests |
| Deploy | responders, rapid response teams, medical teams | `eoc_actors`, `eoc_rrt`, `eoc_emt` |
| Monitor | common operating picture, indicators, situation reports | COP, indicators, `eoc.sitrep`, dashboards |
| Review | early action review, lessons | early action review models, timelines |

## 3. The incident management system (IMS)

The command structure of a response: one incident manager, then sections
(operations, planning, logistics, finance and administration, plus risk
communication and partner coordination). Functions are held by named people
for a period, and handover is a formal act. In code: a function is a time
bounded assignment, not an attribute of the person, and the log is append
only in spirit. People holding an IMS function get the IMS member role
automatically.

The **EOC manager** (a role, who runs the Incidents application) is not the
**incident manager** (a function in one response's IMS).

## 4. Operational periods

A response runs in operational periods (24 hours in an acute phase, longer
later). Each gets an incident action plan; indicators are measured per period;
a closed period is a record, not a draft to edit.

## 5. Two deployment shapes, one set of keys

A database is a **country deployment** (a ministry: National, then the first
level such as state, governorate, province or region, then the second level
such as district) or an **organization deployment** (a regional body: HQ, then
Region, then Country), the latter when `eoc_regional_level` is installed.

Both use the same keys: response levels `national`, `state`, `district`; user
levels `all`, `state`, `district`. Only the labels and the geography model
change: under the organization shape, `state` means a region (`res.region`)
and `district` means a country (`res.country`).

So:
1. Never hardcode a level name in a label, a help, a report or a message.
2. Never assume `state` means `res.country.state`.
3. Store keys, never labels.
4. Geography fields keep the platform names (`country_ids`, `state_ids`,
   `district_ids`, `sub_district_ids`) so the label mechanism finds them.
5. Use `user.area_domain(...)` in record rules: it handles both shapes.
6. Test anything geographic under both shapes (on a copy, install
   `eoc_regional_level`).

## 6. Place and clearance: two independent axes

- **Place**: `res.users.geo_admin_level` (`all`, `state`, `district`) says at
  which level the person works; `country_ids`, `state_ids`, `district_ids`
  (and `region_id` on organization deployments) say where.
- **Clearance**: `res.users.confidentiality_level`, 1 to 5 (everyone,
  partners, ministries, EOC, leadership). Records carry `confidentiality` and
  a stored `confidentiality_rank`, compared by a global record rule. Whoever
  created a record keeps it whatever its level. Level 4 and above may change a
  record's classification.

A district officer can hold clearance 5; a national user can hold clearance 1.
Never infer one from the other, never fold them into one "access level", and
never turn either into a security group: role sync would strip it.

## 7. Design rules the domain imposes

- **Nothing is deleted, everything is justified.** Discarded signals,
  overridden risk levels, closed incidents, rejected actions keep their reason.
- **Timeliness is a metric.** Detection to verification to notification to
  response: a state change that matters stamps who and when.
- **Offline and low bandwidth are normal.** Wall displays run for days;
  trainings run without internet.
- **Several countries and languages.** Never hardcode a country, a level name
  or a left to right layout.
- **People under stress.** Safe defaults, destructive actions hard to hit by
  accident, labels that say what will happen.
- **Reports are the product.** Situation reports and bulletins reach ministers
  and partners: reproducible from the data, dated, attributed, and free of
  anything the recipient is not cleared to see. Once issued, frozen.
- **Official communications** go out from the organisation's address with the
  sender as Reply To, only from people holding the official communications
  role.

## 8. Acronyms

| Acronym | Meaning |
|---|---|
| EOC | Emergency operations centre |
| EBS / IBS | Event based / indicator based surveillance |
| IHR | International Health Regulations |
| IMS | Incident management system |
| IAP | Incident action plan |
| COP | Common operating picture |
| RRA | Rapid risk assessment |
| RRT | Rapid response team |
| EMT | Emergency medical team |
| RCCE | Risk communication and community engagement |
| PHSM | Public health and social measures |
| SitRep | Situation report |
