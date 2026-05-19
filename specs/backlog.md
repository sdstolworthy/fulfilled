# Active backlog

Tracked record of what's in flight or queued. Tickets close by deletion
from this file once both the code lands and any deploy step finishes.

Done work is not preserved here — git history is the audit trail.
Reference shipped tickets by their commit (or by their original ID
in commit messages) if you need the rationale.

Done as of 2026-05-19 (this commit clears the slate):

- F1 — search-row kcal contract drift (BE + FE)
- F2 — `/foods/new` crash + DioException leakage (BE + FE; route
  ordering replaces the rejected regex approach)
- F3 — onboarding gate (BE + FE)
- F4-T1 — USDA serving-label composer + RACC drop + 100 g companion
- F4-T3 — `Serving.name` unit tests
- F5 — search result enrichment (`last_serving*` end-to-end)
- F6 BE prereq — `last_meal` + `last_quantity` on `FoodSearchHitResponse`

---

## F4-T2 — Re-ingest USDA against prod  (in progress)

**Stack:** Ops / BE

Operator-run sequence against the deployed Postgres at `10.0.0.86`,
container `e7t5cd5eqc7m6p0iuiwz4375`.

1. **Precheck — block if non-zero:**
   ```sql
   SELECT COUNT(*) FROM food_log_entries fle
   JOIN foods f ON f.id = fle.food_id
   WHERE f.source = 'usda';
   ```
   Expected: `0`. If non-zero, **stop**, file a per-row UPDATE migration
   covering the affected rows, and only DELETE the unreferenced subset.

2. Pause any ingest cron (manual-only today per F4-BE §5 — verify in
   `crates/loseit-ingest/src/main.rs`).

3. `DELETE FROM foods WHERE source = 'usda';` — cascades to `servings`
   via the `ON DELETE CASCADE` FK at `migrations/0001_initial.sql:152`.

4. Run the ingest binary against the deployed data file:
   ```sh
   ./target/release/loseit-ingest usda --path data/usda_foundation.jsonl
   ```
   Confirm exact CLI shape in `crates/loseit-ingest/src/main.rs` before
   running — the loseit-ingest CLI gained `--force`/`--source-url` flags
   in the phase-2 ingest work.

5. **Verify post-ingest:**
   ```sql
   SELECT COUNT(*) FROM foods WHERE source = 'usda';                                          -- expect ~363
   SELECT COUNT(*) FROM servings s JOIN foods f ON f.id = s.food_id
     WHERE f.source = 'usda' AND s.label IS NOT NULL;                                         -- expect hundreds
   SELECT s.label FROM servings s JOIN foods f ON f.id = s.food_id
     WHERE f.source = 'usda' AND s.is_default = true LIMIT 20;                                -- spot-check labels
   ```

**Acceptance:**

- Precheck returned `0` (or the per-row migration path was taken).
- USDA row count post-ingest is ~363.
- ≥ 80 % of USDA foods have a non-null `label` on at least one serving.
- Manual visual QA on staging client: search `chicken drumstick` → row
  meta reads `'1 drumstick · X kcal'` (not `'94.7 g'`). Spot-check 3
  more FDC-portion foods (bagel, banana, slice of bread) end-to-end:
  search row → detail card → log sheet → Today meal row.

---

## F6 FE — "Log again" CTA on food detail  (queued)

**Stack:** FE

BE prereq already shipped — `last_meal` + `last_quantity` are present
on `FoodSearchHitResponse` and on the projected `Food` from search /
recent / frequent / mine hits.

### Decode

`Food.fromJson` and `FoodSearchHit.fromJson` in
`client/lib/domain/food.dart` gain `lastMeal: Meal?` and
`lastQuantity: Decimal?` decoded from the new top-level wire fields.
`copyWith`, `==`, `hashCode`, `toJson` round-trip both. Mock fixture
decoder in `food_repository.dart` (`_hitToFood`) forwards them the same
way the existing `lastServing*` mapping does.

### Detail-screen CTA

`client/lib/features/food_detail/food_detail_screen.dart` renders an
"Add to log" button today. F6 adds a SECOND button above/before it
that only renders when `food.wasLoggedByCaller`:

- **Label** — `"Log again as <qty>× <serving-label> · <meal>"`,
  e.g. `"Log again as 2× 1 slice · Breakfast"`. When `lastQuantity ==
  1`, drop the `"<qty>× "` prefix. Fall back to bare `"Log again"` if
  the composed label would overflow.
- **Subline** — `"<kcal> kcal"` using `lastServingKcal × lastQuantity`.
- **On tap** — `logRepository.create(LogCreate(food_id: food.id,
  serving_id: food.lastServingId!, quantity: food.lastQuantity!,
  meal: food.lastMeal!, consumed_on: today))`.
- **On success** — pop back to the route that opened detail; show the
  existing log-create snackbar with an Undo action that hits
  `LogRepository.delete(id)` on the just-created entry.
- **On error** — existing `FriendlyError.from(DioException)` snackbar;
  do not pop.

Style: visually distinct from the existing "Add to log" — secondary
emphasis (filled-tonal / outlined-accent, design system pick is the
FE team's). The existing "Add to log" button stays for callers who
want to change serving / quantity / meal.

### Edge cases

- `wasLoggedByCaller == false` → hide the CTA entirely.
- `lastServing == null` with `wasLoggedByCaller == true` (caller logged
  the food but the serving was later deleted; FK is `ON DELETE SET
  NULL`) → hide the CTA. No deepened repeat without a known serving.
- `lastMeal == null` or `lastQuantity == null` with a non-null
  `lastServing` → only possible for log entries that pre-date the F6
  BE roll-out. Hide the CTA. Goes away on its own after a few days of
  fresh logs from active users.
- A second tap while the first request is in flight is a no-op
  (debounce / disable). Match the existing "Add to log" pattern.

### Acceptance

- New decode round-trips both fields; equality / hash include them.
- CTA renders + functions on a previously-logged food; tap creates a
  log entry that matches the caller's last `(meal, quantity)` pair
  exactly; success path pops and shows the Undo snackbar; error path
  shows the friendly snackbar and stays put.
- CTA hidden on every edge-case path above.
- `flutter analyze --fatal-infos --fatal-warnings` clean; new widget /
  unit tests for the decode + CTA visibility logic pass.
