//! Live-Postgres integration tests for `PgFoodRepository::upsert_external_food_batch`.
//!
//! These pin behaviours that the in-memory mirror in `loseit-testing` cannot
//! exercise — they're called out as gaps in `import_plan.md`:
//!
//! - **Phase 3.1/3.2** — savepoint rollback per food. A single bad row in a
//!   chunk must not poison its siblings, and its servings must be fully gone.
//! - **Phase 3.3** — COPY-driven serving loader round-trip on a `label`
//!   value carrying every CSV escape demon (comma, newline, quote, backslash,
//!   multibyte emoji). The unit tests on `push_csv_field` exercise the
//!   encoder; this test pins the whole COPY pipeline.
//! - **Phase 4.3** — `xmax = 0` INSERT-vs-UPDATE split. A re-import of the
//!   same OFF row should bump `merged`, not `upserted`, and the second
//!   call's payload must win the update.
//!
//! ## Harness
//!
//! `#[sqlx::test(migrations = "../../migrations")]` creates a fresh per-test
//! database, runs the three production migrations against it, and hands us a
//! `PgPool`. No sqlx-cli prepare step is required because the production
//! code uses runtime `sqlx::query` everywhere — we just need `DATABASE_URL`
//! pointing at a writable Postgres so the macro can CREATE/DROP test DBs.
//!
//! All tests are `#[ignore]`d so a `DATABASE_URL`-less `cargo test --workspace`
//! still passes; run them explicitly with:
//!
//! ```sh
//! DATABASE_URL=postgres://loseit:loseit@localhost:5432/loseit \
//!     cargo test -p loseit-db --test pg_writer -- --ignored
//! ```

use chrono::Utc;
use loseit_core::domain::serving::{ServingDraft, ServingSource};
use loseit_core::domain::unit::Unit;
use loseit_core::domain::{FoodDraft, NutriscoreGrade};
use loseit_core::repo::food::FoodDraftWithServings;
use loseit_core::repo::FoodRepository;
use loseit_db::PgFoodRepository;
use rust_decimal::Decimal;
use sqlx::{PgPool, Row};
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Fixture builders
// ---------------------------------------------------------------------------

/// Insert a real `food_import_batches` row so the FK from
/// `foods.last_import_batch_id` is satisfied. Returns the batch id.
async fn seed_batch(pool: &PgPool) -> Uuid {
    let row = sqlx::query(
        "INSERT INTO food_import_batches (source_url, status) \
         VALUES ($1, 'running') RETURNING id",
    )
    .bind(format!("test://pg_writer/{}", Uuid::new_v4()))
    .fetch_one(pool)
    .await
    .expect("insert food_import_batches");
    row.try_get("id").expect("id")
}

/// Build a minimal "g, 100kcal per 100g" serving — the default OFF-style
/// payload. Override individual fields with `..` syntax at the call site.
fn good_serving() -> ServingDraft {
    ServingDraft {
        label: Some("1 serving".to_string()),
        amount: Decimal::from(100),
        unit: Unit::Gram,
        kcal: Decimal::from(100),
        protein_g: Some(Decimal::from(3)),
        carbs_g: Some(Decimal::from(20)),
        fat_g: Some(Decimal::from(1)),
        fiber_g: None,
        sugar_g: None,
        sodium_mg: None,
        saturated_fat_g: None,
        is_default: true,
        source: ServingSource::Off,
        sort_order: 0,
    }
}

/// Build an OFF `FoodDraftWithServings` with the given barcode and a single
/// vanilla serving. Suitable for "happy path" assertions.
fn off_food(barcode: &str, name: &str) -> FoodDraftWithServings {
    FoodDraftWithServings {
        draft: FoodDraft {
            name: name.to_string(),
            brands: Some("Acme".to_string()),
            barcode: Some(barcode.to_string()),
            fdc_id: None,
            data_type: None,
            categories_tags: vec!["snacks".to_string()],
            nutriscore_grade: Some(NutriscoreGrade::C),
            servings: vec![good_serving()],
        },
        quality_score: 42,
        servings: vec![good_serving()],
    }
}

// ---------------------------------------------------------------------------
// Test 1 — Phase 3.1/3.2: savepoint rollback isolates one bad food
// ---------------------------------------------------------------------------
//
// The third food in the chunk carries a serving with `amount = 0`, which
// trips the `servings.amount > 0` CHECK constraint. The savepoint must roll
// that one food back (zero food rows, zero serving rows for it) and leave
// the other four foods intact.

#[sqlx::test(migrations = "../../migrations")]
#[ignore = "needs live Postgres; run with DATABASE_URL set and -- --ignored"]
async fn savepoint_rollback_isolates_one_bad_food(pool: PgPool) {
    let batch_id = seed_batch(&pool).await;
    let repo = PgFoodRepository::new(pool.clone());

    // Five foods, food index 2 is poisoned with a 0-amount serving. The
    // CHECK on `servings.amount` is `amount > 0`, so the COPY phase of the
    // third food will fail and the savepoint should roll back that food
    // alone.
    let mut foods = vec![
        off_food("1000000000001", "Apple"),
        off_food("1000000000002", "Banana"),
        off_food("1000000000003", "Cherry — POISON"),
        off_food("1000000000004", "Date"),
        off_food("1000000000005", "Elderberry"),
    ];
    foods[2].servings[0].amount = Decimal::ZERO;

    let outcome = repo
        .upsert_external_food_batch(batch_id, foods)
        .await
        .expect("batch write");

    assert_eq!(outcome.upserted, 4, "four good foods should INSERT cleanly");
    assert_eq!(outcome.skipped, 1, "poisoned food should be skipped");
    assert_eq!(outcome.merged, 0);

    // The four valid barcodes must be present; the poisoned one must NOT.
    let surviving: Vec<String> =
        sqlx::query_scalar("SELECT barcode FROM foods WHERE barcode = ANY($1) ORDER BY barcode")
            .bind(vec![
                "1000000000001".to_string(),
                "1000000000002".to_string(),
                "1000000000003".to_string(),
                "1000000000004".to_string(),
                "1000000000005".to_string(),
            ])
            .fetch_all(&pool)
            .await
            .expect("select surviving barcodes");
    assert_eq!(
        surviving,
        vec![
            "1000000000001".to_string(),
            "1000000000002".to_string(),
            "1000000000004".to_string(),
            "1000000000005".to_string(),
        ],
        "exactly the four good barcodes should exist; the poisoned one is rolled back"
    );

    // No servings for the poisoned barcode (the food row never made it, so
    // its serving rows can't exist either).
    let poison_servings: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM servings s \
         JOIN foods f ON f.id = s.food_id \
         WHERE f.barcode = $1",
    )
    .bind("1000000000003")
    .fetch_one(&pool)
    .await
    .expect("count poison servings");
    assert_eq!(poison_servings, 0, "poisoned food's servings rolled back");

    // The four good foods each have exactly one serving.
    let good_servings: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM servings s \
         JOIN foods f ON f.id = s.food_id \
         WHERE f.barcode = ANY($1)",
    )
    .bind(vec![
        "1000000000001".to_string(),
        "1000000000002".to_string(),
        "1000000000004".to_string(),
        "1000000000005".to_string(),
    ])
    .fetch_one(&pool)
    .await
    .expect("count good servings");
    assert_eq!(good_servings, 4, "each surviving food has its one serving");
}

// ---------------------------------------------------------------------------
// Test 2 — Phase 3.3: COPY round-trip with CSV escape demons
// ---------------------------------------------------------------------------
//
// The `push_csv_field` unit tests cover the encoder in isolation, but the
// only way to know that Postgres parses our COPY payload back into the same
// bytes is a live round-trip. The label below contains every demon: comma,
// newline, double-quote, backslash, plus a multibyte emoji.

#[sqlx::test(migrations = "../../migrations")]
#[ignore = "needs live Postgres; run with DATABASE_URL set and -- --ignored"]
async fn copy_round_trips_csv_escape_demons_in_label(pool: PgPool) {
    let batch_id = seed_batch(&pool).await;
    let repo = PgFoodRepository::new(pool.clone());

    let demon_label = "comma, newline\nemoji \u{1F355} \"quoted\" \\backslash";

    let mut food = off_food("2000000000001", "Demon food");
    food.servings[0].label = Some(demon_label.to_string());

    let outcome = repo
        .upsert_external_food_batch(batch_id, vec![food])
        .await
        .expect("batch write");
    assert_eq!(outcome.upserted, 1);
    assert_eq!(outcome.skipped, 0);

    let stored: String = sqlx::query_scalar(
        "SELECT label FROM servings s \
         JOIN foods f ON f.id = s.food_id \
         WHERE f.barcode = $1",
    )
    .bind("2000000000001")
    .fetch_one(&pool)
    .await
    .expect("select label");

    assert_eq!(
        stored, demon_label,
        "every CSV escape demon must round-trip byte-for-byte"
    );
}

// ---------------------------------------------------------------------------
// Test 3 — Phase 4.3: xmax = 0 INSERT vs UPDATE split
// ---------------------------------------------------------------------------
//
// First import = fresh INSERT, counted as `upserted`. Second import of the
// same barcode = ON CONFLICT branch, counted as `merged`. The UPDATE's
// payload (new name) must overwrite the prior row.

#[sqlx::test(migrations = "../../migrations")]
#[ignore = "needs live Postgres; run with DATABASE_URL set and -- --ignored"]
async fn xmax_split_separates_inserts_from_merges(pool: PgPool) {
    let batch_id_1 = seed_batch(&pool).await;
    let batch_id_2 = seed_batch(&pool).await;
    let repo = PgFoodRepository::new(pool.clone());

    let barcode = "0049000028911";

    // 1st call — should be a clean INSERT.
    let mut first = off_food(barcode, "Coca-Cola Classic");
    first.draft.brands = Some("Coca-Cola".to_string());
    let outcome1 = repo
        .upsert_external_food_batch(batch_id_1, vec![first])
        .await
        .expect("first batch");
    assert_eq!(outcome1.upserted, 1, "first import is a fresh INSERT");
    assert_eq!(outcome1.merged, 0);
    assert_eq!(outcome1.skipped, 0);

    // 2nd call — same barcode, different name. Should be an UPDATE.
    let mut second = off_food(barcode, "Coca-Cola Classic (12 fl oz can)");
    second.draft.brands = Some("Coca-Cola".to_string());
    let outcome2 = repo
        .upsert_external_food_batch(batch_id_2, vec![second])
        .await
        .expect("second batch");
    assert_eq!(outcome2.upserted, 0, "re-import is NOT a fresh INSERT");
    assert_eq!(outcome2.merged, 1, "re-import is counted as merged");
    assert_eq!(outcome2.skipped, 0);

    // Exactly one row in foods for this barcode.
    let cnt: i64 = sqlx::query_scalar("SELECT count(*) FROM foods WHERE barcode = $1")
        .bind(barcode)
        .fetch_one(&pool)
        .await
        .expect("count by barcode");
    assert_eq!(cnt, 1, "no duplicate foods rows from the re-import");

    // The second call's payload wins.
    let name: String = sqlx::query_scalar("SELECT name FROM foods WHERE barcode = $1")
        .bind(barcode)
        .fetch_one(&pool)
        .await
        .expect("select name");
    assert_eq!(
        name, "Coca-Cola Classic (12 fl oz can)",
        "UPDATE branch must overwrite the prior name"
    );
}

// ---------------------------------------------------------------------------
// Test 3b — Phase 4.1 cross-source dedup: USDA Branded merges into OFF row
// ---------------------------------------------------------------------------
//
// Per the Phase 4.1 "USDA wins" contract: when a USDA Branded row arrives
// carrying a `gtinUpc` (stamped onto `draft.barcode` upstream) that matches a
// previously-imported OFF row, the writer must:
//
//   - count the second import as `merged`, not `upserted`;
//   - upgrade `foods.source` from `'off'` to `'usda'`;
//   - stamp `fdc_id` and `data_type` from the incoming USDA payload.

#[sqlx::test(migrations = "../../migrations")]
#[ignore = "needs live Postgres; run with DATABASE_URL set and -- --ignored"]
async fn cross_source_dedup_usda_wins_over_off(pool: PgPool) {
    let batch_id_1 = seed_batch(&pool).await;
    let batch_id_2 = seed_batch(&pool).await;
    let repo = PgFoodRepository::new(pool.clone());

    let barcode = "0049000099999";

    // 1st: OFF row.
    let off = off_food(barcode, "Some snack (OFF)");
    let r1 = repo
        .upsert_external_food_batch(batch_id_1, vec![off])
        .await
        .expect("OFF import");
    assert_eq!(r1.upserted, 1);

    // 2nd: USDA Branded row with the same barcode + an fdc_id + data_type.
    let mut usda = off_food(barcode, "USDA-branded snack");
    usda.draft.fdc_id = Some(987_654_321);
    usda.draft.data_type = Some("branded_food".to_string());
    // USDA-source serving for realism — not load-bearing.
    usda.servings[0].source = ServingSource::Usda;

    let r2 = repo
        .upsert_external_food_batch(batch_id_2, vec![usda])
        .await
        .expect("USDA import");
    assert_eq!(
        r2.upserted, 0,
        "USDA-over-OFF is a merge, not a fresh insert"
    );
    assert_eq!(r2.merged, 1);
    assert_eq!(r2.skipped, 0);

    // Single row, now USDA-flavoured.
    let row = sqlx::query("SELECT source, fdc_id, data_type, name FROM foods WHERE barcode = $1")
        .bind(barcode)
        .fetch_one(&pool)
        .await
        .expect("select merged row");
    let source: String = row.try_get("source").expect("source");
    let fdc_id: Option<i64> = row.try_get("fdc_id").expect("fdc_id");
    let data_type: Option<String> = row.try_get("data_type").expect("data_type");
    let name: String = row.try_get("name").expect("name");

    assert_eq!(
        source, "usda",
        "USDA wins: source upgrades from 'off' to 'usda'"
    );
    assert_eq!(
        fdc_id,
        Some(987_654_321),
        "fdc_id stamped from USDA payload"
    );
    assert_eq!(
        data_type.as_deref(),
        Some("branded_food"),
        "data_type stamped from USDA payload"
    );
    assert_eq!(name, "USDA-branded snack", "USDA payload's name wins");

    // Sanity: today's date is still today after both writes.
    let _ = Utc::now();
}
