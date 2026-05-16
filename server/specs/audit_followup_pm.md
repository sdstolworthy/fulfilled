# PM Requirements: Custom Foods List + Log/Weights Pagination

Audit gaps surfaced 2026-05-15. Both items are v1 cleanup — closing
existing endpoints, not opening new product surface. The `foods_owner_idx`,
`weights_user_date_idx`, and `log_user_date_idx` indexes already exist; this
work makes them load-bearing at the API layer.

## Context

A user who creates a custom food via `POST /foods` today has no way to
*browse* what they've created — only `GET /foods/search?q=` by remembered
name, or `GET /foods/recent` if they've logged it. The "My Foods" tab is a
table-stakes mobile pattern and we have the index for it sitting idle.

Separately, `GET /log` and `GET /weights` are the only paged-ish endpoints
on the v1 surface that *aren't* actually paged. A power user a year in is
~1800 log rows in one response; a weight-every-morning user is ~365. Mobile
clients on flaky connections can't recover from a 2MB JSON payload mid-load
and we'll regret leaving these unbounded the first time someone goes viral.
`GET /foods/search` already returns `{ results, total, limit, offset }`; we
align the other two endpoints to that established convention.

## Feature A: List Custom Foods

### User stories

- As a user who's built up a library of home-cooked recipes as custom
  foods, I want to see all my custom foods in one list, so that I can
  re-log "Mom's Lasagna" without remembering exactly what I called it.
- As a user editing a typo in a custom food, I want to find it by
  scrolling my own list, so that I don't have to search for the broken
  name.
- As a user about to create a new custom, I want to scan my existing list
  first, so that I don't make a duplicate.
- As a user on mobile, I want my newest custom foods at the top, so that
  the one I just added is reachable without scrolling.

### Functional requirements

1. New endpoint: `GET /foods/mine`. Returns the caller's custom foods
   only (`source = 'user'`, `owner_user_id = caller`). Never OFF foods.
   Never another user's customs.
2. Response shape **matches `GET /foods/search`** —
   `{ results: [FoodSearchHit], total, limit, offset }`. Same lean
   projection (id, source, name, brand, barcode, default_serving,
   calories_per_serving). Reusing the search hit shape lets mobile share
   the row-rendering component between "Search" and "My Foods."
3. Default sort: **most recently created first** (`created_at DESC`,
   tiebreak by `id` for stable pagination). This is the only sort v1
   ships. No `?sort=` parameter.
4. Pagination: same contract as Feature B (see below). Same defaults,
   same cap, same mechanism. Treat as one decision.
5. Optional in-list filter: `?q=<substring>` does a **simple
   case-insensitive substring match on `name`** scoped to the caller's
   customs. This is *not* full-text or trigram search — it's the "filter
   my list as I type" affordance, not a search engine. The point is to
   stay cheap and predictable when a user has 200+ customs. If `q` is
   absent or blank, return all customs.
6. Empty result is a 200 with `results: []` and `total: 0`. Not a 404.
   Brand-new users hit this endpoint and we don't want it to look broken.
7. Soft-deleted customs are out (we don't have soft-deletes in v1, per
   NEXT_STEPS). A `DELETE /foods/:id` that succeeds removes the row
   entirely; it will not appear here.
8. Auth: standard authenticated endpoint, same as the rest of `/foods/*`.
9. The endpoint is read-only. No side effects, no `last_viewed_at`
   tracking.

### Out of scope

- Sorting by name, calories, last-logged, or anything else.
- Filtering by category tag, brand, has-barcode, or any other facet.
- Showing OFF foods the user has logged (`/foods/recent` already does
  that; mixing the two would muddle the mental model).
- Showing custom foods the user has *logged but not created* — that
  concept doesn't exist; customs are 1:1 with their owner.
- Aggregate stats ("you have 47 customs, 12 logged this week").
- Tags, folders, favourites, archive/unarchive. Anything that implies a
  schema change is out.
- A "deleted/trash" view. We don't soft-delete in v1.
- Sharing or export of the custom list.

### Open questions for architect

- Cursor vs offset pagination — pick one (consistency with Feature B
  matters more than which one you pick).
- Whether to expose `created_at` on `FoodSearchHit` for the client to
  display "added 3 days ago" badges, or keep the projection lean and
  let clients fetch detail. Either is fine product-side; pick whichever
  doesn't require a schema-level change to `FoodSearchHit`.
- Whether the `?q=` filter is `ILIKE '%q%'` on `name`, `name + brands`,
  or trigram-similarity-reused. Product only requires "substring on name
  is enough"; if you can cheaply include brands, do.
- Whether `GET /foods/mine` lives in `routes/foods.rs` next to the other
  food reads (recommended) or warrants its own file.

## Feature B: Log + Weights Pagination

### User stories

- As a mobile user opening today's view, I want a fast response with
  just today's entries, so that the screen renders instantly.
- As a user scrolling back through history on the timeline view, I want
  to load entries in chunks as I scroll, so that I'm not waiting on a
  full-year payload.
- As a client author, I want a predictable upper bound on response size,
  so that I can size buffers, timeouts, and progress indicators sanely.
- As a user with a year of data, I want the server to *not* try to
  return all 1800 of my log rows in one response, so that the request
  doesn't fail on a bad connection.

### Functional requirements

1. Applies to **both** `GET /log` and `GET /weights`. Identical
   pagination semantics on both — defaults, cap, parameter names, and
   response envelope. One contract.
2. Pagination is **optional with a server-enforced cap**. Existing
   clients that send only `from`/`to` continue to work; the server
   silently applies the default page size. **Not** a breaking change.
3. **Default page size: 100.** Covers a heavy logger's full day with
   headroom (5 meals × ~6 entries is the high end), covers most
   weekly-view cases for `/log`, and trivially covers any realistic
   weights window.
4. **Max page size: 500.** A request asking for more is clamped down
   silently to 500 (matches how `GET /foods/search` already handles its
   cap; aligns the surface). The architect picks the exact "silent clamp
   vs 400" rule but it must be consistent across `/log`, `/weights`, and
   `/foods/search`.
5. Response envelope mirrors `GET /foods/search`:
   `{ results: [...], total, limit, offset }` (or the cursor-equivalent
   shape if the architect picks cursors — see open questions). Both
   endpoints currently return a bare array; this **is a wire-shape
   change**. Acceptable: there is no production client today; v1 has
   not shipped. Document it as a v1-pre-release breaking change in the
   commit message.
6. **`total` is required in the response.** Clients need it to render
   "showing 100 of 1247" and to know when to stop paging. Worth one
   extra count query per list call.
7. `from` and `to` remain supported and remain **optional** on both
   endpoints. Existing semantics preserved: when both are present,
   filter to that inclusive range; when absent, no date filter.
8. New: when no `from`/`to` is provided, the endpoint returns "the most
   recent N entries" (sorted newest-first by `consumed_on` / `recorded_on`,
   then by `created_at` desc as the existing `/log` handler already
   does). This is the "give me the latest" affordance — no special
   parameter needed, it falls out of "no date filter + default sort +
   default page size."
9. Sort order, both endpoints: **newest first** by the date column,
   tiebreak by `created_at DESC`, then `id` for stability. `/log`
   already sorts this way in the handler; `/weights` must adopt the
   same. This is non-negotiable because pagination on a non-stable sort
   produces duplicate/missing rows across pages.
10. Bad inputs return 400 with a clear message (e.g. `from > to`, negative
    limit, non-integer limit). `/log` already does the `from > to`
    check; mirror it on `/weights`.
11. Auth and per-user scoping unchanged. A user only ever sees their own
    log entries / weights.

### Out of scope

- Streaming / chunked-transfer responses. JSON page is enough.
- Aggregation in the list response (no per-day totals on `/log` — that's
  `/days/:date/summary`'s job).
- Filtering by meal, food, has-note, etc. on `/log`. Date range +
  pagination only.
- Filtering weights by range thresholds (above/below X kg).
- Server-side "infinite scroll session" tokens that expire. Stateless
  pagination only.
- CSV export of either endpoint (NEXT_STEPS Priority 3; defer).
- Changing the *shape* of individual log/weight rows. Only the envelope
  around them.

### Open questions for architect

- **Cursor vs offset.** Offset is simpler and matches `/foods/search`.
  Cursor is more correct under concurrent writes and is cheaper at deep
  offsets. Product is indifferent as long as (a) the choice is the same
  for `/log`, `/weights`, and `/foods/mine`, and (b) `total` is still
  available on the response. If you go cursor, find a way to surface
  total — clients need it.
- **Should the server send `next` / `prev` links** (HATEOAS-lite) or
  let clients construct the next request themselves? Product is fine
  either way; pick what's idiomatic in our axum patterns.
- Whether `limit=0` is "zero rows" or "use default." Pick one, document
  it, apply consistently across all three paged endpoints.
- Whether to backfill the same envelope into `/foods/search` retro-
  actively if cursors win (i.e. align all three on cursors). Acceptable
  scope creep; mention in your design doc if you go that way.

## Success criteria

**Feature A is done when:**
- A user with zero customs hits `GET /foods/mine` and gets a clean empty
  page (200, `results: []`, `total: 0`).
- A user creates a custom via `POST /foods` and it appears at the top of
  `GET /foods/mine` on the next request.
- A user with 50+ customs can fetch their list paginated, and `?q=foo`
  narrows the list to entries whose name contains "foo" (case-
  insensitive).
- An OFF food the user has logged but not created does **not** appear.
- A second user's customs are **never** returned.

**Feature B is done when:**
- A request to `GET /log` or `GET /weights` with no params returns at
  most the default page size, newest first, with an accurate `total`.
- A request with `limit=10000` returns at most the max page size (500),
  not an error, not the full row count.
- Paging through a stable dataset with `offset` (or cursor) never
  duplicates or skips a row across page boundaries.
- A request with `from`/`to` filters correctly *and* paginates within
  that range.
- A request with `from > to` returns 400 on both endpoints with the same
  message style.
- `/log`, `/weights`, and `/foods/search` use the same pagination contract
  — same parameter names, same envelope, same default + cap, same
  out-of-range behaviour.
