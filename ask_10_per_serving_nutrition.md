# Ask 10 — Per-serving nutrition + unit families + flatten migrations + USDA/OFF ingest normalizer

*P0 — user directive 2026-05-17. Standalone copy of Ask 10 from
`backend_tasks.md` for hand-off to the backend automation. Reply by
editing this file in place (status flip + `Backend reply:` paragraph)
**or** by editing the corresponding entry in `backend_tasks.md` — both
are watched.*

Status: `done (server)` — backend pipeline shipped (T01–T16 on `main`, `7847bd3` → `a871704`); **deploy blocked** on the `_sqlx_migrations` reset (operator action — see `COOLIFY.md` "Ask 10 deploy — resetting the migration chain"). See `backend_tasks.md` Ask 10 for the full Backend reply.

---

**User directive (2026-05-17, verbatim transcript paraphrase):**
custom-food creation today only accepts grams for serving size; users
can't enter volumetric servings. The model needs to change: trust the
user to enter a serving as
`{amount, unit, kcal-for-that-serving, macros-for-that-serving}` and
stop anchoring nutrition to per-100g mass. The system's job is to know
whether each unit is mass / volume / count so we can offer same-family
conversions at log time and at quantity entry. No densities, no
per-100g math.

User explicitly OK'd:

1. **Dropping all existing data.** No production traffic on the deploy
   — there's nothing to preserve.
2. **Flattening every migration (0001..0009) into a single new
   `0001_initial.sql`** that captures the new schema. No incremental
   migration; just rip and rewrite.
3. **Bundling the reshape with the USDA + OpenFoodFacts ingest work.**
   The ingest pipeline (`loseit-ingest`) will normalize external data
   against the new schema rather than the schema being shaped to the
   external sources.

---

## Scope (the entire backend reshape — sized as multi-week)

### 10a — Schema reshape

Replace `migrations/0001_initial.sql` (and delete 0002..0009) with a
single migration that includes:

- **`foods` table** — drop all `*_100g` columns:
  ```
  energy_kcal_100g, protein_100g, carbs_100g, fat_100g,
  fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g
  ```
  Foods are now identity + metadata only (name, brands, barcode,
  source, owner, categories, quality_score, nutriscore_grade, kind,
  created/updated). Nutrition lives on the serving.

- **`servings` table** — replace `grams: NUMERIC` with structured
  units + per-serving nutrition:
  ```sql
  CREATE TABLE servings (
      id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      food_id         UUID NOT NULL REFERENCES foods(id) ON DELETE CASCADE,

      label           TEXT,                  -- nullable; FE/user-supplied descriptor

      amount          NUMERIC(10,3) NOT NULL CHECK (amount > 0),
      unit            TEXT NOT NULL CHECK (unit IN (
                          -- mass
                          'g', 'kg', 'oz', 'lb',
                          -- volume
                          'ml', 'l', 'cup', 'fl_oz', 'tbsp', 'tsp',
                          -- count
                          'serving', 'piece'
                      )),

      kcal            NUMERIC(8,2) NOT NULL CHECK (kcal >= 0),
      protein_g       NUMERIC(8,2)         CHECK (protein_g IS NULL OR protein_g >= 0),
      carbs_g         NUMERIC(8,2)         CHECK (carbs_g   IS NULL OR carbs_g   >= 0),
      fat_g           NUMERIC(8,2)         CHECK (fat_g     IS NULL OR fat_g     >= 0),
      fiber_g         NUMERIC(8,2)         CHECK (fiber_g   IS NULL OR fiber_g   >= 0),
      sugar_g         NUMERIC(8,2)         CHECK (sugar_g   IS NULL OR sugar_g   >= 0),
      sodium_mg       NUMERIC(8,2)         CHECK (sodium_mg IS NULL OR sodium_mg >= 0),
      saturated_fat_g NUMERIC(8,2)         CHECK (saturated_fat_g IS NULL OR saturated_fat_g >= 0),

      is_default      BOOLEAN NOT NULL DEFAULT false,
      source          TEXT    NOT NULL CHECK (source IN ('off','usda','user','system')),
      sort_order      INT     NOT NULL DEFAULT 0,

      created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
  Keep the partial-unique `servings_one_default_per_food` index.

  Architect's call: `kcal` is the only **required** nutrient field on a
  serving — protein/carbs/fat/etc are nullable because user-entered
  data is often incomplete and we don't want to force the FE to invent
  zeros. The FE renders missing macros as "—", not "0 g."

- **`food_log_entries` table** — keep the snapshot pattern (nutrition
  columns stay on log rows, recorded at write time), but **drop
  `grams_total`** and **add `entered_amount: NUMERIC` +
  `entered_unit: TEXT`** so the log row preserves *exactly what the
  user typed at entry time* even if they later edit or delete the
  serving. Snapshot semantics: nutrition is computed as
  `quantity * serving.<nutrient>` at write time (no gram-anchor math).

  ```sql
  CREATE TABLE food_log_entries (
      ...
      quantity        NUMERIC(8,3) NOT NULL CHECK (quantity > 0),

      -- What the user picked at entry time (denormalized for editing).
      entered_amount  NUMERIC(10,3) NOT NULL CHECK (entered_amount > 0),
      entered_unit    TEXT NOT NULL,         -- same enum as servings.unit

      -- Snapshot: quantity * serving.<nutrient> at write time.
      calories_kcal   NUMERIC(8,2) NOT NULL,
      protein_g       NUMERIC(8,2),
      carbs_g         NUMERIC(8,2),
      fat_g           NUMERIC(8,2),
      fiber_g         NUMERIC(8,2),
      sugar_g         NUMERIC(8,2),
      sodium_mg       NUMERIC(8,2),
      saturated_fat_g NUMERIC(8,2),
      ...
  );
  ```

- **Unit families** — declared in the Rust code
  (`loseit-core::domain::serving::UnitFamily { Mass, Volume, Count }`),
  not in the database. The CHECK constraint above is the only DB-level
  guard. Conversion ratios within a family live in code as constants.
  **No cross-family conversion ever** — a "1 cup" serving cannot be
  entered as grams unless the user adds a separate gram-based serving
  themselves.

  Canonical within-family ratios (architect: confirm or amend):
  - **Mass** (canonical: `g`): `kg=1000`, `oz=28.349523125`,
    `lb=453.59237`.
  - **Volume** (canonical: `ml`): `l=1000`, `cup=236.5882365`,
    `fl_oz=29.5735295625`, `tbsp=14.78676478125`,
    `tsp=4.92892159375`.
  - **Count** (canonical: itself): no cross-unit conversion;
    `serving` ↔ `piece` cannot be converted automatically — they're
    treated as separate units within the same family for display
    purposes only.

- **Quick-add sentinel** — re-implement on top of the new schema.
  **Architect, please pick:**
  - **Option (i)** add `'kcal'` as a thirteenth unit (its own `Energy`
    family), only valid on the quick-add sentinel food.
  - **Option (ii)** model quick-add as
    `{amount: 1, unit: 'serving', kcal: <user-entered>}`. Cleaner —
    avoids a new family. **FE recommendation.**

- **Preserve `users`, `users_local_auth`, `auth_tokens` (or
  `local_auth_tokens` — match current naming), `oidc_handoff_codes`,
  `food_import_batches`, `weights`, `goals`** verbatim from current
  migrations. The reshape is scoped to `foods` + `servings` +
  `food_log_entries`.

### 10b — Domain + repo + API DTO reshape (Rust)

- `loseit-core::domain::food::Food` — drop `nutrition_per_100g`, drop
  the `NutritionPer100g` struct entirely.
- `loseit-core::domain::serving::Serving` — gains `amount`,
  `unit: Unit`, `kcal`, `protein_g`, etc. Drops `grams`.
- New `loseit-core::domain::unit::{Unit, UnitFamily}` enums with
  `family()` accessor and `ratio_to_canonical()` for within-family
  conversions (canonical = grams for mass, ml for volume, 1 for
  count).
- `FoodCreate` body:
  `{name, brand?, barcode?, servings: [ServingCreate]}` where
  `ServingCreate = {label?, amount, unit, kcal, protein_g?, carbs_g?,
  fat_g?, fiber_g?, sugar_g?, sodium_mg?, saturated_fat_g?,
  is_default?}`. **At least one serving required.** No top-level
  nutrition.
- `FoodPatch`: same shape; `nutrition_per_100g` field removed;
  `servings` patch list works as today (full-list replace).
- `LogEntryCreate` / `LogEntryPatch`: drop `grams_total`; add
  `entered_amount`, `entered_unit`. `serving_id` stays required (every
  log entry references a serving). Cross-family entries are rejected
  with a 400 (e.g. mass-only serving + `entered_unit='cup'`).
- Pg repo + in-memory fake: full rewrite of the foods + servings + log
  paths against the new schema. **`loseit-db/src/{food,serving,log}_repo.rs`
  are getting redrawn.**

### 10c — OpenAPI delta

- Remove `NutritionPer100g` schema.
- `Food` schema: drop `nutrition_per_100g`; `servings: [Serving]`
  becomes required (was already there).
- `Serving` schema: gains `amount: number`, `unit: string-enum`,
  `kcal: number`, `protein_g: number | null`, etc.; loses `grams`.
- `LogEntry` schema: drops `grams_total`; adds `entered_amount:
  number`, `entered_unit: string-enum`.
- `FoodCreate` / `FoodPatch` / `ServingCreate` / `LogEntryCreate` /
  `LogEntryPatch` — all updated.
- Add a `Unit` enum schema referenced from `Serving.unit`,
  `LogEntry.entered_unit`, `ServingCreate.unit`, etc.

### 10d — Ingest pipeline (`loseit-ingest`)

- **OpenFoodFacts** — for each OFF row:
  - Parse `serving_size` (string like `"30 g"`, `"100 ml"`, `"1 cup
    (240 ml)"`) into `{amount, unit}`. Maintain a parser table for the
    canonical units list above. Drop rows where:
    1. `serving_size` is unparseable AND no `energy-kcal_100g` field
       is present, OR
    2. all per-100g nutrition fields are missing.
  - **Synthesize at least one serving per food:**
    - If `serving_size` parsed → emit a serving with that amount +
      unit + the OFF per-serving nutrition (computed from per-100g ×
      serving-grams when OFF provides only per-100g).
    - Always also emit a `{100, 'g'}` serving when OFF provides
      per-100g nutrition — gives users the "by weight" entry point
      even when the product's listed serving is volumetric.
    - Mark the canonical / parsed-from-OFF serving as
      `is_default = true` (the `{100, 'g'}` companion is non-default).
  - Drop OFF rows where the per-100g nutrition AND serving-level
    nutrition are both unavailable — they aren't useful in the new
    model.

- **USDA Foundation Foods** — for each USDA food:
  - Iterate `foodPortions[]`. Each has `gramWeight` + a `measureUnit`
    (text like `"cup"`, `"tablespoon"`, `"piece"`). Map measureUnit to
    our `Unit` enum where possible (`tablespoon` → `tbsp`, `fluid
    ounce` → `fl_oz`, etc.); fall back to a `{<gramWeight>, 'g'}`
    serving when the measureUnit doesn't map.
  - Compute per-serving nutrition by `nutrient_per_100g × gramWeight /
    100`.
  - Emit one `servings` row per USDA portion. Mark the first portion
    (lowest `sequenceNumber`) as `is_default`.

- Both pipelines respect the FK invariant that **every food has ≥ 1
  serving**. A food with zero parseable portions is dropped, not
  stored with an empty serving list.

### 10e — Tests

Workspace test count today: 245 (per Ask 8). The reshape will rewrite
~all foods/servings/log tests. Acceptance:

- `loseit-core` unit tests cover unit-family classification,
  within-family conversion ratios, and the "no cross-family
  conversion" guard.
- `loseit-db` integration tests cover round-trip of `Food` + `Serving`
  + `FoodLogEntry` against pg + in-memory.
- HTTP-level tests cover `POST /foods` with `{name, servings:
  [{amount: 1, unit: 'cup', kcal: 200}]}`, `POST /log` referencing a
  volumetric serving, `GET /log` returning the new `entered_amount` +
  `entered_unit` keys, **and** `POST /log` with `entered_unit`
  cross-family to the serving returns 400.
- `loseit-ingest` tests cover OFF + USDA normalizers on fixtures from
  each source.

---

## Non-goals (out of scope for Ask 10)

- **Refresh tokens / token rotation** — still v1.1.
- **Idempotency keys** — still v1.1.
- **Mobile OIDC** — still v1.1.
- **Density-based cross-family conversion** ("user typed cups but I
  want to display grams") — explicitly rejected by user. Not
  happening.
- **Multi-unit serving display** (a serving simultaneously showing "1
  cup / 240 ml / 8 fl oz") — that's the **FE's** job at render time,
  using `UnitFamily` + the in-code ratio table. Backend just stores
  `{amount, unit}` as the user / source recorded it.

---

## Acceptance (against `https://api.coolify.stolworthy.co`)

```bash
# 1. POST a custom food with a volumetric serving + per-serving nutrition.
curl -X POST -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test smoothie",
    "servings": [
      {"label": "1 cup", "amount": "1", "unit": "cup", "kcal": "180",
       "protein_g": "5", "carbs_g": "30", "fat_g": "4", "is_default": true}
    ]
  }' \
  https://api.coolify.stolworthy.co/api/v1/foods
# → 201 { food with one serving, amount=1, unit='cup', kcal=180 }

# 2. POST a log entry referencing the volumetric serving with a different
#    same-family unit (system scales within volume family).
curl -X POST ... -d '{
  "food_id": "<id>",
  "serving_id": "<serving_id>",
  "consumed_on": "2026-05-17",
  "meal": "snack",
  "quantity": "0.5",                       # 0.5 × 1 cup = 0.5 cup
  "entered_amount": "4",
  "entered_unit": "fl_oz"                  # 4 fl oz = 0.5 cup (within volume family)
}' .../log
# → 201 { entry with calories_kcal=90 (0.5 × 180) }

# 3. POST a cross-family log entry — rejected.
curl -X POST ... -d '{
  "food_id": "<id>",
  "serving_id": "<volumetric serving_id>",
  ...
  "entered_unit": "g"                      # mass unit on a volume-family serving
}' .../log
# → 400 { code: "unit_family_mismatch", ... }

# 4. GET /foods/{id} no longer carries `nutrition_per_100g`; carries servings only.
curl ... /foods/<id> | jq 'has("nutrition_per_100g")'
# → false
curl ... /foods/<id> | jq '.servings[0] | has("amount") and has("unit") and has("kcal")'
# → true

# 5. /log row carries `entered_amount` + `entered_unit`.
curl ... "/log?from=2026-05-17&to=2026-05-17" | jq '.results[0] | has("entered_amount") and has("entered_unit")'
# → true
```

---

## FE deliverables (queued — kicks off when 10c lands)

- `Serving` domain: drop `grams`, add `amount: Decimal`, `unit: Unit`,
  per-serving nutrition fields.
- `Food` domain: drop `nutritionPer100g`.
- `CustomFoodScreen` / `servings_section.dart`: replace the single
  "Grams" stepper with `{amount stepper + unit dropdown + kcal stepper
  + macros}`. Per-serving nutrition entry per row. Drops the top-level
  `NutritionSection` entirely.
- `LogEntrySheet`: unit toggle within the selected serving's family
  (mass-only servings show g/oz/lb/kg; volume-only show
  ml/l/cup/fl_oz/tbsp/tsp; count shows just the count unit).
- `UnitFamily` enum + within-family conversion table (mirror of the
  Rust side).
- All decoders updated for new wire shape.
- Drop the `FoodRepository._byIdCache` + `prefetchByIds` stopgap
  shipped under Ask 9 — names already denormalized; the new shape
  doesn't re-introduce missing-data issues.

---

## Notify

Please notify FE (status flip + `Backend reply:` paragraph in this
file **or** in `backend_tasks.md`) when:

- 10a + 10b + 10c are landed on `main` and the deploy serves the new
  shape.
- 10d (ingest) is wired and OFF + USDA fixtures pass.
- The OpenAPI spec at `server/specs/openapi.yaml` reflects the new
  shape (FE regenerates DTOs from it).

FE will then start the corresponding client-side reshape; expect ~3-5
days of FE rewrites to track the new server shape.
