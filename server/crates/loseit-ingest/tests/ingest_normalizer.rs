//! Integration tests for the OFF + USDA normalizer fixtures.
//!
//! Per §8 (ingest layer): fixture-based tests covering the parser corner
//! cases and round-trip normalizer paths not already exercised by the
//! inline unit tests in `loseit-core/src/service/ingest.rs`.
//!
//! These live in `loseit-ingest/tests/` so they can exercise the public
//! API surface that callers of the crate use.

use std::sync::Arc;

use async_trait::async_trait;
use loseit_core::domain::unit::Unit;
use loseit_core::domain::{FoodSource, ServingSource};
use loseit_core::repo::FoodRepository;
use loseit_core::service::ingest::{
    accept_and_normalize_off, accept_and_normalize_usda, parse_serving_size, IngestService,
    OffFoodRecord, UsdaFoodPortion, UsdaFoodRecord,
};
use loseit_core::service::{FoodRecordSource, UsdaSource};
use loseit_core::CoreResult;
use loseit_testing::{InMemoryBatchRepository, InMemoryFoodRepository, InMemoryServingRepository};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Parse corner-case tests  (§8 — "2 tsp", "1 pouch (90 g)")
// ---------------------------------------------------------------------------

/// §8 parser corner-case: "2 tsp" → {2, Teaspoon}.
#[test]
fn parse_2_tsp() {
    let (amt, unit) = parse_serving_size("2 tsp").expect("should parse");
    assert_eq!(amt, dec!(2));
    assert_eq!(unit, Unit::Teaspoon);
}

/// §8 parser corner-case: "1 pouch (90 g)" → first pair wins = {1, ?}.
/// The outer "1 pouch" has no mapped unit, so the parser falls through to the
/// parenthetical "(90 g)" → {90, Gram}.
#[test]
fn parse_1_pouch_90g() {
    // "1 pouch" has no known unit mapping; the parser should fall back to "90 g".
    let result = parse_serving_size("1 pouch (90 g)");
    // The first number+unit pair scanned is "1 pouch" — "pouch" is unknown, so it
    // yields no result for that token. The next scanned pair is "90 g".
    assert!(
        result.is_some(),
        "should parse via the parenthetical gram value"
    );
    let (amt, unit) = result.unwrap();
    assert_eq!(amt, dec!(90));
    assert_eq!(unit, Unit::Gram);
}

/// §8 parser corner-case: "100 ml" → {100, Milliliter}.
#[test]
fn parse_100_ml() {
    let (amt, unit) = parse_serving_size("100 ml").expect("should parse");
    assert_eq!(amt, dec!(100));
    assert_eq!(unit, Unit::Milliliter);
}

/// §8 parser corner-case: "1.5 tbsp" → {1.5, Tablespoon}.
#[test]
fn parse_1_5_tbsp() {
    let (amt, unit) = parse_serving_size("1.5 tbsp").expect("should parse");
    assert_eq!(amt, dec!(1.5));
    assert_eq!(unit, Unit::Tablespoon);
}

/// §8 parser: "4 fl oz" → {4, FluidOunce}.
#[test]
fn parse_4_fl_oz() {
    let (amt, unit) = parse_serving_size("4 fl oz").expect("should parse");
    assert_eq!(amt, dec!(4));
    assert_eq!(unit, Unit::FluidOunce);
}

// ---------------------------------------------------------------------------
// OFF normalizer drop-row predicate tests  (§8 / §7.1)
// ---------------------------------------------------------------------------

/// §7.1 rule 1a: empty barcode → dropped.
#[test]
fn off_drop_empty_barcode() {
    let r = OffFoodRecord {
        code: "".into(),
        product_name: "Visible".into(),
        energy_kcal_100g: Some(dec!(100)),
        ..Default::default()
    };
    assert!(
        accept_and_normalize_off(r).is_none(),
        "empty barcode must be dropped"
    );
}

/// §7.1 rule 1b: empty product_name → dropped.
#[test]
fn off_drop_empty_product_name() {
    let r = OffFoodRecord {
        code: "BC999".into(),
        product_name: "   ".into(), // whitespace-only
        energy_kcal_100g: Some(dec!(100)),
        ..Default::default()
    };
    assert!(
        accept_and_normalize_off(r).is_none(),
        "whitespace-only name must be dropped"
    );
}

/// §7.1 rule 7: no per-100g, no parseable serving → dropped.
#[test]
fn off_drop_no_nutrition_no_serving() {
    let r = OffFoodRecord {
        code: "BC777".into(),
        product_name: "Ghost".into(),
        energy_kcal_100g: None,
        protein_100g: None,
        carbs_100g: None,
        fat_100g: None,
        serving_size: None,
        ..Default::default()
    };
    assert!(
        accept_and_normalize_off(r).is_none(),
        "no nutrition + no serving must be dropped"
    );
}

/// §7.1 rule 7 variant: kcal absent even though serving_size is set → dropped
/// (can't compute serving nutrition without kcal_100g).
#[test]
fn off_drop_no_kcal_with_serving() {
    let r = OffFoodRecord {
        code: "BC778".into(),
        product_name: "Phantom".into(),
        energy_kcal_100g: None,
        protein_100g: None,
        carbs_100g: None,
        fat_100g: None,
        serving_size: Some("30 g".into()),
        ..Default::default()
    };
    assert!(
        accept_and_normalize_off(r).is_none(),
        "no kcal + no per-100g macros must be dropped"
    );
}

// ---------------------------------------------------------------------------
// OFF round-trip integration tests  (§8)
// ---------------------------------------------------------------------------

/// §8 OFF round-trip: 4-row fixture through `accept_and_normalize_off`;
/// assert count of accepted `FoodDraftWithServings` outputs and key fields.
#[test]
fn off_round_trip_fixture_4_rows() {
    let rows = vec![
        // Row A: full record with serving — should produce 2 servings (Off + System).
        OffFoodRecord {
            code: "FIX001".into(),
            product_name: "Granola Bar".into(),
            brands: Some("SnackCo".into()),
            categories_tags: vec!["en:snacks".into()],
            nutriscore_grade: Some("c".into()),
            completeness: Some(0.8),
            serving_size: Some("45 g".into()),
            serving_quantity: Some(dec!(45)),
            energy_kcal_100g: Some(dec!(400)),
            protein_100g: Some(dec!(8)),
            carbs_100g: Some(dec!(60)),
            fat_100g: Some(dec!(14)),
            fiber_100g: Some(dec!(3)),
            sugar_100g: Some(dec!(25)),
            sodium_100g: Some(dec!(0.3)),
            saturated_fat_100g: Some(dec!(5)),
            ..Default::default()
        },
        // Row B: no serving_size, per-100g only → 1 serving (100g system).
        OffFoodRecord {
            code: "FIX002".into(),
            product_name: "Plain Flour".into(),
            energy_kcal_100g: Some(dec!(364)),
            protein_100g: Some(dec!(10)),
            carbs_100g: Some(dec!(76)),
            fat_100g: Some(dec!(1)),
            ..Default::default()
        },
        // Row C: volumetric serving (no density) + per-100g → drops Cup, emits 100g.
        OffFoodRecord {
            code: "FIX003".into(),
            product_name: "Orange Juice".into(),
            serving_size: Some("1 cup (240 ml)".into()),
            energy_kcal_100g: Some(dec!(45)),
            protein_100g: Some(dec!(0.7)),
            carbs_100g: Some(dec!(10)),
            fat_100g: Some(Decimal::ZERO),
            ..Default::default()
        },
        // Row D: empty name → dropped.
        OffFoodRecord {
            code: "FIX004".into(),
            product_name: "".into(),
            energy_kcal_100g: Some(dec!(100)),
            ..Default::default()
        },
    ];

    let accepted: Vec<_> = rows
        .into_iter()
        .filter_map(accept_and_normalize_off)
        .collect();

    // Row D is dropped; A, B, C are accepted.
    assert_eq!(accepted.len(), 3, "3 of 4 rows must be accepted");

    // Row A: barcode FIX001, 2 servings (Off is_default + System companion).
    let a = accepted
        .iter()
        .find(|r| r.draft.barcode.as_deref() == Some("FIX001"))
        .unwrap();
    assert_eq!(a.draft.name, "Granola Bar");
    assert_eq!(a.servings.len(), 2, "FIX001 must have 2 servings");
    let default_a = a.servings.iter().find(|s| s.is_default).unwrap();
    assert_eq!(default_a.source, ServingSource::Off);
    assert_eq!(default_a.unit, Unit::Gram);
    assert_eq!(default_a.amount, dec!(45));
    // kcal = 400 * 45 / 100 = 180
    assert_eq!(default_a.kcal, dec!(180));

    // Row B: barcode FIX002, 1 serving (100g system, is_default=true).
    let b = accepted
        .iter()
        .find(|r| r.draft.barcode.as_deref() == Some("FIX002"))
        .unwrap();
    assert_eq!(b.servings.len(), 1);
    let s_b = &b.servings[0];
    assert_eq!(s_b.source, ServingSource::System);
    assert!(s_b.is_default);
    assert_eq!(s_b.amount, dec!(100));
    assert_eq!(s_b.unit, Unit::Gram);

    // Row C: volumetric Cup dropped; only the 100g companion.
    let c = accepted
        .iter()
        .find(|r| r.draft.barcode.as_deref() == Some("FIX003"))
        .unwrap();
    assert!(
        !c.servings.iter().any(|s| s.unit == Unit::Cup),
        "Cup must be dropped"
    );
    assert!(c
        .servings
        .iter()
        .any(|s| s.unit == Unit::Gram && s.amount == dec!(100)));
}

// ---------------------------------------------------------------------------
// USDA round-trip integration tests  (§8)
// ---------------------------------------------------------------------------

/// §8 USDA round-trip: 3-record fixture through `accept_and_normalize_usda`;
/// assert count of outputs and key fields.
#[test]
fn usda_round_trip_fixture_3_records() {
    let records = vec![
        // Record A: 2 portions with different measureUnit names, both with
        // pre-composed labels (F4-T1).
        UsdaFoodRecord {
            fdc_id: 9001,
            data_type: "sr_legacy_food".into(),
            description: "Olive Oil".into(),
            brand_owner: None,
            food_portions: vec![
                UsdaFoodPortion {
                    gram_weight: dec!(13.5),
                    measure_unit_name: "tablespoon".into(),
                    sequence_number: 1,
                    label: Some("1 tablespoon".into()),
                },
                UsdaFoodPortion {
                    gram_weight: dec!(216),
                    measure_unit_name: "cup".into(),
                    sequence_number: 2,
                    label: Some("1 cup".into()),
                },
            ],
            energy_kcal_100g: Some(dec!(884)),
            fat_100g: Some(dec!(100)),
            ..Default::default()
        },
        // Record B: unmapped unit → fallback {gramWeight, Gram}. No label.
        // 1.2: Branded carries serving_size; test treats the input as
        // already-per-100g so the rescale is a no-op (factor = 1).
        UsdaFoodRecord {
            fdc_id: 9002,
            data_type: "branded_food".into(),
            description: "Mystery Powder".into(),
            brand_owner: Some("FoodCo".into()),
            food_portions: vec![UsdaFoodPortion {
                gram_weight: dec!(28),
                measure_unit_name: "scoop".into(),
                sequence_number: 1,
                label: None,
            }],
            energy_kcal_100g: Some(dec!(370)),
            protein_100g: Some(dec!(80)),
            serving_size: Some(dec!(100)),
            serving_size_unit: Some("g".into()),
            ..Default::default()
        },
        // Record C: empty portions + no kcal → dropped.
        UsdaFoodRecord {
            fdc_id: 9003,
            data_type: "foundation_food".into(),
            description: "Void".into(),
            food_portions: vec![],
            energy_kcal_100g: None,
            ..Default::default()
        },
    ];

    let accepted: Vec<_> = records
        .into_iter()
        .filter_map(accept_and_normalize_usda)
        .collect();

    // Record C dropped.
    assert_eq!(accepted.len(), 2, "2 of 3 records must be accepted");

    // Record A: Olive Oil — 2 FDC portions + 1 system 100 g companion (F4-T1).
    let a = accepted
        .iter()
        .find(|r| r.draft.name == "Olive Oil")
        .unwrap();
    assert_eq!(a.servings.len(), 3);
    let tbsp = &a.servings[0];
    assert_eq!(tbsp.unit, Unit::Tablespoon);
    assert_eq!(tbsp.amount, Decimal::ONE);
    assert!(tbsp.is_default);
    // F4-T1: label round-trips through accept_and_normalize_usda.
    assert_eq!(tbsp.label.as_deref(), Some("1 tablespoon"));
    // kcal = 884 * 13.5 / 100 = 119.34
    let expected_kcal = dec!(884) * dec!(13.5) / dec!(100);
    assert_eq!(tbsp.kcal, expected_kcal);

    let cup = &a.servings[1];
    assert_eq!(cup.unit, Unit::Cup);
    assert!(!cup.is_default);
    assert_eq!(cup.label.as_deref(), Some("1 cup"));

    // F4-T1: 100 g system companion — labelless, non-default.
    let companion = &a.servings[2];
    assert_eq!(companion.unit, Unit::Gram);
    assert_eq!(companion.amount, dec!(100));
    assert!(!companion.is_default);
    assert!(companion.label.is_none());
    assert_eq!(companion.source, ServingSource::System);
    // Exactly one default per food.
    assert_eq!(a.servings.iter().filter(|s| s.is_default).count(), 1);

    // Record B: Mystery Powder — unmapped "scoop" → {28, Gram}, no label.
    // FDC portion + 100 g companion = 2 servings.
    let b = accepted
        .iter()
        .find(|r| r.draft.name == "Mystery Powder")
        .unwrap();
    assert_eq!(b.servings.len(), 2);
    let s_b = &b.servings[0];
    assert_eq!(s_b.unit, Unit::Gram);
    assert_eq!(s_b.amount, dec!(28));
    assert!(s_b.is_default);
    assert!(s_b.label.is_none());
    // Companion 100 g — labelless, non-default.
    let b_companion = &b.servings[1];
    assert_eq!(b_companion.unit, Unit::Gram);
    assert_eq!(b_companion.amount, dec!(100));
    assert!(!b_companion.is_default);
    assert!(b_companion.label.is_none());
}

// ---------------------------------------------------------------------------
// IngestService + loseit-ingest sources integration  (§8)
// ---------------------------------------------------------------------------

/// §8 IngestService OFF round-trip: VecSource of 3 records → foods repo
/// holds 3 OFF foods, each with the correct serving count.
struct VecOffSource(Vec<OffFoodRecord>);

impl VecOffSource {
    fn new(mut records: Vec<OffFoodRecord>) -> Self {
        records.reverse();
        Self(records)
    }
}

#[async_trait]
impl FoodRecordSource for VecOffSource {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<OffFoodRecord>>> {
        if self.0.is_empty() {
            return Ok(None);
        }
        let take = n.min(self.0.len());
        let mut out = Vec::with_capacity(take);
        for _ in 0..take {
            out.push(self.0.pop().unwrap());
        }
        Ok(Some(out))
    }
}

struct VecUsdaSource(Vec<UsdaFoodRecord>);

impl VecUsdaSource {
    fn new(mut records: Vec<UsdaFoodRecord>) -> Self {
        records.reverse();
        Self(records)
    }
}

#[async_trait]
impl UsdaSource for VecUsdaSource {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<UsdaFoodRecord>>> {
        if self.0.is_empty() {
            return Ok(None);
        }
        let take = n.min(self.0.len());
        let mut out = Vec::with_capacity(take);
        for _ in 0..take {
            out.push(self.0.pop().unwrap());
        }
        Ok(Some(out))
    }
}

fn build_ingest_service() -> (
    Arc<InMemoryFoodRepository>,
    Arc<InMemoryServingRepository>,
    Arc<InMemoryBatchRepository>,
    IngestService,
) {
    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    let batches = Arc::new(InMemoryBatchRepository::new());
    foods.set_serving_repo(servings.clone());
    let svc = IngestService::new(foods.clone(), batches.clone());
    (foods, servings, batches, svc)
}

#[tokio::test]
async fn off_ingest_service_round_trip_3_records() {
    let (foods, servings, _batches, svc) = build_ingest_service();

    let records = vec![
        // All three have per-100g kcal + mass serving → 2 servings each.
        OffFoodRecord {
            code: "RT001".into(),
            product_name: "Apple Juice".into(),
            energy_kcal_100g: Some(dec!(46)),
            protein_100g: Some(dec!(0.1)),
            carbs_100g: Some(dec!(11)),
            fat_100g: Some(dec!(0.1)),
            serving_size: Some("250 g".into()),
            ..Default::default()
        },
        OffFoodRecord {
            code: "RT002".into(),
            product_name: "Peanut Butter".into(),
            energy_kcal_100g: Some(dec!(588)),
            protein_100g: Some(dec!(25)),
            carbs_100g: Some(dec!(20)),
            fat_100g: Some(dec!(50)),
            serving_size: Some("32 g".into()),
            ..Default::default()
        },
        OffFoodRecord {
            code: "RT003".into(),
            product_name: "Rice Crackers".into(),
            energy_kcal_100g: Some(dec!(380)),
            protein_100g: Some(dec!(8)),
            carbs_100g: Some(dec!(80)),
            fat_100g: Some(dec!(2)),
            serving_size: Some("14 g".into()),
            ..Default::default()
        },
    ];

    let stats = svc
        .run_off(VecOffSource::new(records), "test://off-rt3", None)
        .await
        .unwrap();

    assert_eq!(stats.inserted, 3, "all 3 records should be inserted");
    assert_eq!(stats.skipped, 0);

    use loseit_core::repo::ServingRepository;

    for (barcode, expected_servings) in [("RT001", 2usize), ("RT002", 2), ("RT003", 2)] {
        let food = foods
            .find_by_barcode(Uuid::nil(), barcode)
            .await
            .unwrap()
            .unwrap_or_else(|| panic!("{barcode} must be in repo"));
        assert_eq!(food.source, FoodSource::Off);
        let srv_list = servings.list_for_food(food.id).await.unwrap();
        assert_eq!(
            srv_list.len(),
            expected_servings,
            "{barcode} must have {expected_servings} servings"
        );
        // Default serving is the OFF-derived one.
        let default = srv_list.iter().find(|s| s.is_default).unwrap();
        assert_eq!(default.source, ServingSource::Off);
    }
}

#[tokio::test]
async fn usda_ingest_service_round_trip_2_records() {
    let (foods, servings, _batches, svc) = build_ingest_service();

    let records = vec![
        UsdaFoodRecord {
            fdc_id: 88001,
            data_type: "sr_legacy_food".into(),
            description: "Whole Milk".into(),
            brand_owner: None,
            food_portions: vec![UsdaFoodPortion {
                gram_weight: dec!(244),
                measure_unit_name: "cup".into(),
                sequence_number: 1,
                label: Some("1 cup".into()),
            }],
            energy_kcal_100g: Some(dec!(61)),
            protein_100g: Some(dec!(3.2)),
            fat_100g: Some(dec!(3.3)),
            carbs_100g: Some(dec!(4.8)),
            ..Default::default()
        },
        UsdaFoodRecord {
            fdc_id: 88002,
            data_type: "branded_food".into(),
            description: "Cheddar Cheese".into(),
            brand_owner: Some("DairyCo".into()),
            food_portions: vec![UsdaFoodPortion {
                gram_weight: dec!(28),
                measure_unit_name: "oz".into(),
                sequence_number: 1,
                label: Some("1 oz".into()),
            }],
            energy_kcal_100g: Some(dec!(403)),
            protein_100g: Some(dec!(25)),
            fat_100g: Some(dec!(33)),
            carbs_100g: Some(dec!(1.3)),
            // 1.2: Branded must carry a real serving_size; this test treats
            // its input as already-per-100g so the rescale is a no-op.
            serving_size: Some(dec!(100)),
            serving_size_unit: Some("g".into()),
            ..Default::default()
        },
    ];

    let stats = svc
        .run_usda(VecUsdaSource::new(records), "test://usda-rt2", None)
        .await
        .unwrap();

    assert_eq!(stats.inserted, 2);

    use loseit_core::repo::ServingRepository;

    let milk = foods
        .find_by_barcode(Uuid::nil(), "__no_barcode__")
        .await
        .unwrap();
    // USDA foods have no barcode; search by name instead.
    // Use find_by_id approach: list all foods via search.
    // We check via servings: find all foods, look for the one with "Whole Milk" / "Cheddar".
    // The in-memory repo doesn't directly expose list-all, so we check via stats.
    assert!(milk.is_none(), "USDA foods have no barcode");

    // Verify via search.
    let milk_list = foods
        .search(Uuid::nil(), "Whole Milk", 10, 0)
        .await
        .unwrap();
    assert_eq!(milk_list.len(), 1);
    let milk_food = &milk_list[0];
    assert_eq!(milk_food.name, "Whole Milk");

    let milk_servings = servings.list_for_food(milk_food.id).await.unwrap();
    // F4-T1: 1 FDC portion + 1 system 100 g companion = 2 servings.
    assert_eq!(milk_servings.len(), 2);
    let ms = milk_servings
        .iter()
        .find(|s| s.unit == Unit::Cup)
        .expect("cup serving present");
    assert_eq!(ms.amount, Decimal::ONE);
    assert!(ms.is_default);
    // F4-T1: USDA-imported portion servings ride the OpenAPI `system` enum
    // variant (the `Usda` Rust variant broke the FE decoder when shipped).
    assert_eq!(ms.source, ServingSource::System);
    // F4-T1: label survives end-to-end through IngestService::run_usda.
    assert_eq!(ms.label.as_deref(), Some("1 cup"));
    // kcal = 61 * 244 / 100 = 148.84
    let expected_milk_kcal = dec!(61) * dec!(244) / dec!(100);
    assert_eq!(ms.kcal, expected_milk_kcal);

    // 100 g companion: labelless, non-default.
    let milk_companion = milk_servings
        .iter()
        .find(|s| s.unit == Unit::Gram && s.amount == dec!(100))
        .expect("100 g companion present");
    assert!(!milk_companion.is_default);
    assert!(milk_companion.label.is_none());
    assert_eq!(milk_companion.source, ServingSource::System);

    // Exactly one default per food (matches partial unique index).
    assert_eq!(milk_servings.iter().filter(|s| s.is_default).count(), 1);
}

// ---------------------------------------------------------------------------
// 1.5: skip-and-log per-row write failures
// ---------------------------------------------------------------------------

/// 1.5: when a single OFF row fails at the write layer, the rest of the
/// batch still lands and the batch finishes with `status='completed'`.
/// `records_skipped` reflects the failed row.
#[tokio::test]
async fn off_ingest_skip_and_log_on_row_failure() {
    let (foods, _servings, batches, svc) = build_ingest_service();
    // Inject a write failure for barcode RT002.
    foods.fail_on_external_id("RT002");

    let records = vec![
        OffFoodRecord {
            code: "RT001".into(),
            product_name: "Apple Juice".into(),
            energy_kcal_100g: Some(dec!(46)),
            protein_100g: Some(dec!(0.1)),
            carbs_100g: Some(dec!(11)),
            fat_100g: Some(dec!(0.1)),
            serving_size: Some("250 g".into()),
            ..Default::default()
        },
        OffFoodRecord {
            code: "RT002".into(),
            product_name: "Peanut Butter".into(),
            energy_kcal_100g: Some(dec!(588)),
            protein_100g: Some(dec!(25)),
            carbs_100g: Some(dec!(20)),
            fat_100g: Some(dec!(50)),
            serving_size: Some("32 g".into()),
            ..Default::default()
        },
        OffFoodRecord {
            code: "RT003".into(),
            product_name: "Rice Crackers".into(),
            energy_kcal_100g: Some(dec!(380)),
            protein_100g: Some(dec!(8)),
            carbs_100g: Some(dec!(80)),
            fat_100g: Some(dec!(2)),
            serving_size: Some("14 g".into()),
            ..Default::default()
        },
    ];

    let stats = svc
        .run_off(VecOffSource::new(records), "test://off-skip-log", None)
        .await
        .expect("pipeline must finish, not abort, on per-row failure");

    // 2 of 3 land; the failed RT002 is counted as skipped.
    assert_eq!(stats.inserted, 2);
    assert_eq!(stats.skipped, 1);

    // The good rows are queryable; the bad one is not.
    assert!(foods
        .find_by_barcode(Uuid::nil(), "RT001")
        .await
        .unwrap()
        .is_some());
    assert!(foods
        .find_by_barcode(Uuid::nil(), "RT002")
        .await
        .unwrap()
        .is_none());
    assert!(foods
        .find_by_barcode(Uuid::nil(), "RT003")
        .await
        .unwrap()
        .is_some());

    // Batch repo state: exactly one batch, completed, with the skip counted.
    use loseit_core::domain::BatchStatus;
    let batch_id = batches
        .find_by_url("test://off-skip-log")
        .expect("batch must exist");
    let summary = batches.get(batch_id).expect("batch present");
    assert_eq!(summary.status, BatchStatus::Completed);
    assert_eq!(summary.records_seen, 3);
    assert_eq!(summary.records_upserted, 2);
    assert_eq!(summary.records_skipped, 1);
}
