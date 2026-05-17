# Backend ticket ledger

Backend (Rust API + Postgres) tickets flagged across the Fulfilled
client-pack work. The Rust service in this repository (`crates/`,
`migrations/`, `specs/openapi.yaml`) is owned by a separate team; this
file is the consolidated hand-off so that team can pick tickets up in
priority order without re-reading five pack docs.

## Numbering note

The per-pack docs each opened their own `BE-NNN` namespace, which
caused collisions: `BE-002` and `BE-003` mean one thing in
`dev_tickets_barcode.md` and a different thing in `dev_tickets_ux_pack.md`.
This file renumbers in chronological pack order:

| Canonical ID | Source pack | Source ID in pack |
|---|---|---|
| BE-001 | log edit + units (LU-) | BE-001 (unchanged) |
| BE-002 | barcode (SC-) | BE-002 (unchanged) |
| BE-003 | barcode (SC-) | BE-003 (unchanged) |
| BE-004 | quality of life (QL-) | QL-110 (was mis-classified as a client ticket) |
| BE-005 | UX pack (UX-) | BE-002 (renumbered to break collision) |
| BE-006 | UX pack (UX-) | BE-003 (renumbered to break collision) |
| BE-007 | UX pack (UX-) | BE-004 (renumbered to break collision) |

Future packs use the canonical IDs going forward. Legacy mentions in
the source docs are preserved as-is with a pointer line back to this
file.

## Status legend

- `pending` — proposed, not started; awaiting backend-team prioritisation.
- `in flight` — accepted by the backend team; work-in-progress.
- `shipped` — landed on `main` with the migration, the handler, and
  the OpenAPI shape updated.
- `client workaround in place` — the client has a v1 fallback so the
  feature ships before the backend lands. The wire change is upside,
  not a blocker.

All seven tickets below are currently `pending`. No backend BE-NNN
work has landed on `main` as of the last audit (no `weight_unit` /
`height_unit` columns in `migrations/`; no `weekly-logging` /
`scan-history` / `goal_status` paths in `specs/openapi.yaml`).

## Tickets

### BE-001  `User.weight_unit` migration

**Status**: pending
**Source pack**: log edit + units (LU-)
**Source spec**: `dev_tickets_log_edit_and_units.md` §BE-001; `pm_log_edit_and_units.md` §3 ("Decision: where the preference lives" + "Backend implication"); `architect_log_edit_and_units.md` §3.1, §4.2.

**Goal**: add `users.weight_unit` column (`text` with check
constraint `IN ('kg', 'lb', 'st')`, default `'kg'`); add `WeightUnit`
schema to OpenAPI; expose the field on `User` (required) and
`UserPatch` / `ProfilePatch` (optional). `GET /me` returns it;
`PATCH /me` accepts and persists it.

**Client workaround**: in place. `User.fromJson` tolerates a missing
key and defaults to `WeightUnit.kg`; the client's
`weightUnitProvider` is fully wired and writes are mock-backed in v1
per LU-004 / LU-006. The Flutter sweep shipped via LU pack Waves 1–7
(`81ff22e`..`3e832fa`).

**Blocking impact**: client UI works today. Cross-device parity
("my unit preference survives re-login on a new device") unlocks
once this lands. Until then, the preference is local-only.

**Acceptance**: a migrated user with no explicit preference returns
`weight_unit: 'kg'` on `GET /me`; `PATCH /me { weight_unit: 'lb' }`
persists and round-trips; `PATCH /me { weight_unit: 'unknown' }`
returns 400 with an explicit message.

**Open question carried over**: does the current Rust API ignore
unknown JSON keys on `PATCH /me`, or 400? Architect's expectation is
"ignore" (and BE-004 inherits the same assumption). Confirm before
or alongside this ticket.

---

### BE-002  Server-side OFF live fallback on barcode cache miss

**Status**: pending
**Source pack**: barcode (SC-)
**Source spec**: `pm_barcode.md` §8 ¶1 ("OFF cache-miss fallback");
`architect_barcode.md` §risks; `dev_tickets_barcode.md` "Pre-backend
window" + footer.

**Goal**: on `GET /foods/barcode/{barcode}` cache miss against our
Rust-side OFF mirror, the server falls back to
`https://world.openfoodfacts.org/api/v2/product/{barcode}` and, on a
hit, returns the live record as if it had been ours. Optionally
cache the live result for subsequent calls; cache a short-TTL
negative result on OFF's 404 (e.g. 24 h "we asked OFF, they 404'd
too") so we don't hot-loop the upstream.

**Client workaround**: not needed. The client already handles the
404 path (route to `/foods/new?barcode=…` per SC-001's resolver);
this ticket is pure unknown-barcode hit-rate upside without any
client change.

**Blocking impact**: none. The barcode scanner shipped in SC pack
Waves 1–2 (`f5bf7b4`, `7999c1c`) and works against the endpoint as
it stands. This is a v1.1 quality lift.

**Acceptance**: a barcode known to OFF but not yet mirrored locally
returns a populated `Food` instead of a 404 on the second call (the
first call may 404 if the live fallback is async-cached behind a
write). OFF's public-v2 rate limit (1 req/s/IP) is not violated
under realistic concurrent load — server-side de-duplication or a
short request coalescer covers the hot path.

**Risk**: OFF public-v2 rate limit (1 req/s/IP) on a hot path; an
external call on every cache miss. Mitigate with de-dup +
negative-cache TTL.

---

### BE-003  Server-side EAN-13 normalization (UPC-A → EAN-13)

**Status**: pending
**Source pack**: barcode (SC-)
**Source spec**: `pm_barcode.md` §8 ¶2 ("Barcode normalization on
the wire"); `architect_barcode.md` §risks.

**Goal**: `GET /foods/barcode/{barcode}` normalizes the input to
EAN-13 (left-pad UPC-A's 12 digits with a leading `0` to 13 digits)
before lookup. Backfill the existing mirror rows so stored barcodes
are uniformly EAN-13; downstream search and barcode-equality checks
become unambiguous.

**Client workaround**: not needed. The client emits whatever the
camera decoded (`mobile_scanner` produces both UPC-A and EAN-13 in
their native widths). Server-side normalization removes the
"client scanned UPC-A 12-digit, mirror has the EAN-13 13-digit"
miss class without a client change.

**Blocking impact**: none. The scanner ships against the endpoint
as-is; this lifts the known-barcode hit rate when our mirror and
the camera disagree on width.

**Acceptance**: scanning a UPC-A barcode whose corresponding EAN-13
exists in the mirror returns the mirrored `Food` (not a 404).
Mirror backfill complete: every `foods.barcode` row that was 12
digits is now 13 digits with a leading `0`; barcode uniqueness
constraint still holds.

**Risk**: low. Small migration; the only sharp edge is making sure
the backfill doesn't collide with rows that already stored
both-widths under different food rows (none expected but worth a
pre-flight count).

---

### BE-004  `User.height_unit` migration

**Status**: pending
**Source pack**: quality of life (QL-)
**Source spec**: `dev_tickets_qol.md` §QL-110 ("Backend —
`users.height_unit` migration"); `pm_qol_audit.md` §2.1 ("Backend
implication — flag for the user"); `architect_qol.md` §5.1
("Pre-backend window tolerance"), §10.3 (open question on unknown
JSON keys).

**Note on numbering**: was tracked as `QL-110` in the QoL client
pack but is unambiguously backend-team work (Rust migration,
OpenAPI schema, `GET /me` / `PATCH /me` handler changes — same
shape as BE-001). Lifted here as BE-004.

**Goal**: same shape as BE-001 but for height. Add
`users.height_unit` column (`text` with check constraint `IN
('cm', 'ft_in')`, default `'cm'`); add `HeightUnit` schema to
OpenAPI; expose on `User` (required) and `UserPatch` (optional).
`GET /me` returns it; `PATCH /me` accepts and persists it.

**Client workaround**: in place. `User.fromJson` tolerates the
missing key and defaults to `HeightUnit.cm` (or locale-default per
QL-102's `defaultUnitsForLocale`). The Flutter height sweep shipped
in QL pack Waves 1–3 (`9fdb695`..`2caa3bd`).

**Blocking impact**: identical to BE-001. The client renders and
edits the height-unit preference today; cross-device parity unlocks
once this lands.

**Acceptance**: a migrated user with no explicit preference returns
`height_unit: 'cm'` on `GET /me`; `PATCH /me { height_unit:
'ft_in' }` persists and round-trips; `PATCH /me { height_unit:
'unknown' }` returns 400.

**Dependency**: the architect's "does PATCH /me ignore unknown
keys?" question is the same one BE-001 inherits. Answer once,
apply to both.

---

### BE-005  Weekly logging count endpoint (`GET /me/weekly-logging`)

**Status**: pending
**Source pack**: UX pack (UX-)
**Source spec**: `dev_tickets_ux_pack.md` §"Backend coordination" /
"BE-002 — Weekly logging count endpoint"; `pm_ux_pack.md` §9
(backend tickets named by the PM doc); `architect_ux_pack.md` §7.4.

**Note on numbering**: this was tracked as `BE-002` inside the UX
pack docs (colliding with the barcode pack's BE-002). Renumbered
here as BE-005.

**Goal**: new endpoint `GET /me/weekly-logging` returning
`{ week_start: <ISO date>, days_logged: <int 0..7> }` for the
caller-anchored week. Existing log rows are the source of truth;
`days_logged` is the count of distinct `consumed_on` values in
`[week_start, week_start + 7d)` for the calling user. Anchor week
on Monday per existing client locale convention.

**Client workaround**: in place. UX-110's client provider
(`weeklyLogDaysProvider` / `LogRepository.weeklyLogDayCount()`) is
implemented as an in-memory fold over already-loaded `/log` rows
per architect §7.2. When BE-005 lands, the repository method swaps
to a single `GET /me/weekly-logging` call and the provider's
behavior is unchanged — no client surface change required at the
swap-over.

**Blocking impact**: none. UX-110 shipped client-side in UX pack
Wave 2a (`f9c1983`); the streak pill renders correctly today. The
backend endpoint replaces a client-side fold with one network call
— a perf and bandwidth lift, not a feature unlock.

**Acceptance**: `GET /me/weekly-logging` returns the current
caller-week's start date and `days_logged` count; returns 0 for a
user with no log rows in the window; week boundary matches the
client's Monday anchor.

---

### BE-006  Barcode scan history (`GET /scan-history` / `scans` table)

**Status**: pending
**Source pack**: UX pack (UX-)
**Source spec**: `dev_tickets_ux_pack.md` §"Backend coordination" /
"BE-003 — Barcode scan history"; `pm_ux_pack.md` §9 (named for the
deferred scan-history v1.1 affordance).

**Note on numbering**: this was tracked as `BE-003` inside the UX
pack docs (colliding with the barcode pack's BE-003). Renumbered
here as BE-006.

**Goal**: persist the user's barcode-scan history (the codes they
scanned, the timestamp, and what we resolved them to: food id,
404-then-create, abandoned). New `scans` table + `GET
/scan-history` endpoint returning a paged list. Powers a v1.1
"recent scans" affordance on the scanner route's empty state and
on the My Foods screen.

**Client workaround**: not applicable — there is no v1 client
surface for this. The feature is deferred to v1.1 per the PM doc.
Listed here so the backend team has the full backlog visible.

**Blocking impact**: blocks the v1.1 scan-history affordance only.
v1 ships without it.

**Acceptance**: scanning a barcode (resolved or not) writes a row
to `scans`; `GET /scan-history` returns the caller's recent scans
paged newest-first; per-user scoping enforced.

**Risk**: PII / privacy review on storing scan history (it reveals
food choices). Confirm retention policy before shipping.

---

### BE-007  Goal achievement status (`goals.status` field or derived)

**Status**: pending
**Source pack**: UX pack (UX-)
**Source spec**: `dev_tickets_ux_pack.md` §"Backend coordination" /
"BE-004 — Goal achievement status"; `pm_ux_pack.md` §9 (named for
the deferred goal-history "achieved" badges).

**Note on numbering**: this was tracked as `BE-004` inside the UX
pack docs (colliding with the QoL pack's QL-110 → BE-004 lift).
Renumbered here as BE-007.

**Goal**: every historical goal carries an "achieved" / "missed" /
"abandoned" status — either stored on `goals.status` directly or
derived from the goal's date range vs. the user's
weights/log-calories within it. Pick the cheaper option; product
only requires that the v1.1 client can render a badge per past
goal.

**Client workaround**: not applicable — there is no v1 client
surface for the badge. Deferred to v1.1.

**Blocking impact**: blocks the v1.1 goal-history "achieved"
badges only. v1 ships without it; the goals list is presence-only
today.

**Acceptance**: every goal record exposes a status the client can
render without ambiguity (a state machine, not a free-form
string). Derivation logic, if chosen, runs in <50 ms for a typical
year-of-history user.

---

## Cross-reference back to source packs

For convenience, each canonical BE-NNN above is also pointer-linked
from the originating pack doc:

- `dev_tickets_log_edit_and_units.md` §BE-001 → BE-001 (same ID).
- `dev_tickets_barcode.md` footer "Pre-backend window" → BE-002, BE-003 (same IDs).
- `dev_tickets_qol.md` §QL-110 → BE-004 (relabel; backend work, not client).
- `dev_tickets_ux_pack.md` "Backend coordination" → UX-pack BE-002 = BE-005, BE-003 = BE-006, BE-004 = BE-007.
