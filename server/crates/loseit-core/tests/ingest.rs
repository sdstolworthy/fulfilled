//! Service-layer tests for `IngestService::run` and the quality-score
//! helper. Uses in-memory repository fakes from `loseit-testing`. A
//! local `VecSource` plays the role of `JsonlSource`/`ParquetSource`.

use std::sync::Arc;

use async_trait::async_trait;
use loseit_core::domain::{BatchStatus, FoodSource, ServingSource};
use loseit_core::repo::FoodRepository;
use loseit_core::service::ingest::{accept_and_normalize, parse_serving_size_grams, score};
use loseit_core::service::{FoodRecordSource, IngestService, OffFoodRecord};
use loseit_core::CoreResult;
use loseit_testing::{InMemoryBatchRepository, InMemoryFoodRepository, InMemoryServingRepository};
use rust_decimal::Decimal;
use uuid::Uuid;

/// In-memory `FoodRecordSource` that drains a `Vec<OffFoodRecord>`.
struct VecSource(Vec<OffFoodRecord>);

impl VecSource {
    fn new(records: Vec<OffFoodRecord>) -> Self {
        // Reverse so we can pop from the back cheaply.
        let mut records = records;
        records.reverse();
        Self(records)
    }
}

#[async_trait]
impl FoodRecordSource for VecSource {
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

fn d(n: i64) -> Decimal {
    Decimal::from(n)
}

fn rec_complete(code: &str, name: &str) -> OffFoodRecord {
    OffFoodRecord {
        code: code.to_string(),
        product_name: name.to_string(),
        brands: Some("Acme".to_string()),
        categories_tags: vec!["en:snacks".to_string()],
        nutriscore_grade: Some("a".to_string()),
        completeness: Some(1.0),
        serving_size: Some("30 g".to_string()),
        serving_quantity: Some(d(30)),
        energy_kcal_100g: Some(d(150)),
        protein_100g: Some(d(5)),
        carbs_100g: Some(d(20)),
        fat_100g: Some(d(5)),
        fiber_100g: Some(d(3)),
        sugar_100g: Some(d(8)),
        sodium_100g: Some(Decimal::new(5, 1)), // 0.5g
        saturated_fat_100g: Some(d(1)),
    }
}

fn build_service() -> (
    Arc<InMemoryFoodRepository>,
    Arc<InMemoryServingRepository>,
    Arc<InMemoryBatchRepository>,
    IngestService,
) {
    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    let batches = Arc::new(InMemoryBatchRepository::new());
    foods.set_serving_repo(servings.clone());
    let svc = IngestService::new(foods.clone(), servings.clone(), batches.clone());
    (foods, servings, batches, svc)
}

#[tokio::test]
async fn ingest_filters_records_missing_required_fields() {
    let (foods, _servings, batches, svc) = build_service();

    let records = vec![
        rec_complete("0001", "Good Food"),
        // Missing energy
        OffFoodRecord {
            code: "0002".into(),
            product_name: "No Energy".into(),
            ..Default::default()
        },
        // Missing name
        OffFoodRecord {
            code: "0003".into(),
            product_name: "".into(),
            energy_kcal_100g: Some(d(100)),
            ..Default::default()
        },
        // Missing code
        OffFoodRecord {
            code: "".into(),
            product_name: "Anon".into(),
            energy_kcal_100g: Some(d(100)),
            ..Default::default()
        },
    ];

    let source = VecSource::new(records);
    let stats = svc.run(source, "test://filter", None).await.unwrap();

    assert_eq!(stats.inserted, 1);
    assert_eq!(stats.updated, 0);
    assert_eq!(stats.skipped, 3);

    // Only the first food made it.
    let found = foods.find_by_barcode(Uuid::nil(), "0001").await.unwrap();
    assert!(found.is_some());
    let missing = foods.find_by_barcode(Uuid::nil(), "0002").await.unwrap();
    assert!(missing.is_none());

    // Batch finished with the correct skip count.
    let batch_id = batches
        .find_by_url("test://filter")
        .expect("batch row exists");
    let batch = batches.get(batch_id).expect("batch row fetchable");
    assert_eq!(batch.status, BatchStatus::Completed);
    assert_eq!(batch.records_seen, 4);
    assert_eq!(batch.records_skipped, 3);
}

#[tokio::test]
async fn ingest_synthesizes_100g_serving_for_every_food() {
    let (foods, servings, _batches, svc) = build_service();

    let mut records = Vec::new();
    for i in 0..3 {
        let mut r = rec_complete(&format!("100{i}"), &format!("Food {i}"));
        // Strip the OFF serving from one to make sure the 100g still lands.
        if i == 2 {
            r.serving_size = None;
            r.serving_quantity = None;
        }
        records.push(r);
    }

    svc.run(VecSource::new(records), "test://servings", None)
        .await
        .unwrap();

    use loseit_core::repo::ServingRepository;
    for i in 0..3 {
        let food = foods
            .find_by_barcode(Uuid::nil(), &format!("100{i}"))
            .await
            .unwrap()
            .expect("food upserted");
        let list = servings.list_for_food(food.id).await.unwrap();
        let has_100g = list
            .iter()
            .any(|s| s.source == ServingSource::System && s.label.contains("100"));
        assert!(
            has_100g,
            "food {i} must have a system 100 g serving (got {:?})",
            list.iter().map(|s| &s.label).collect::<Vec<_>>()
        );
    }
}

#[tokio::test]
async fn ingest_marks_off_derived_serving_as_default_when_present() {
    let (foods, servings, _batches, svc) = build_service();

    let r = rec_complete("2001", "With Serving");
    svc.run(VecSource::new(vec![r]), "test://default-off", None)
        .await
        .unwrap();

    use loseit_core::repo::ServingRepository;
    let food = foods
        .find_by_barcode(Uuid::nil(), "2001")
        .await
        .unwrap()
        .expect("food upserted");
    let list = servings.list_for_food(food.id).await.unwrap();
    let default = list
        .iter()
        .find(|s| s.is_default)
        .expect("there must be a default");
    assert_eq!(default.source, ServingSource::Off);
}

#[tokio::test]
async fn ingest_falls_back_to_100g_default_when_no_off_serving() {
    let (foods, servings, _batches, svc) = build_service();

    let mut r = rec_complete("2002", "No Off Serving");
    r.serving_size = None;
    r.serving_quantity = None;
    svc.run(VecSource::new(vec![r]), "test://default-system", None)
        .await
        .unwrap();

    use loseit_core::repo::ServingRepository;
    let food = foods
        .find_by_barcode(Uuid::nil(), "2002")
        .await
        .unwrap()
        .expect("food upserted");
    let list = servings.list_for_food(food.id).await.unwrap();
    let default = list
        .iter()
        .find(|s| s.is_default)
        .expect("there must be a default");
    assert_eq!(default.source, ServingSource::System);
}

#[tokio::test]
async fn ingest_warns_and_nulls_implausible_sodium() {
    let (foods, _servings, _batches, svc) = build_service();

    let mut r = rec_complete("3003", "Salty");
    r.sodium_100g = Some(d(200)); // 200 g / 100 g — obviously wrong
    svc.run(VecSource::new(vec![r]), "test://sodium", None)
        .await
        .unwrap();

    let food = foods
        .find_by_barcode(Uuid::nil(), "3003")
        .await
        .unwrap()
        .expect("food upserted");
    assert!(
        food.nutrition.sodium_g.is_none(),
        "implausible sodium must be nulled, got {:?}",
        food.nutrition.sodium_g
    );
}

#[tokio::test]
async fn ingest_records_stats_on_batch() {
    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    let batches = Arc::new(InMemoryBatchRepository::new());
    foods.set_serving_repo(servings.clone());
    let svc = IngestService::new(foods.clone(), servings.clone(), batches.clone());

    // Capture the batch by spying on start: we use the fact that
    // `InMemoryBatchRepository` is keyed by Uuid. We pre-call start so we
    // know the id, then run the ingest — but ingest also calls start
    // internally. Easier: run, then walk the repo's HashMap via a
    // brand-new probe — we just iterate by trying to look up the same
    // start call shape isn't accessible. Instead, expose total via stats.

    let r = rec_complete("4000", "Statty");
    let stats = svc
        .run(VecSource::new(vec![r]), "test://stats", None)
        .await
        .unwrap();
    assert_eq!(stats.inserted, 1);
    assert_eq!(stats.updated, 0);
    assert_eq!(stats.skipped, 0);

    // Capture the batch through the repo by searching for the row that
    // matches our source_url.
    let id = batches
        .find_by_url("test://stats")
        .expect("batch row exists");
    let batch = batches.get(id).unwrap();
    assert_eq!(batch.status, BatchStatus::Completed);
    assert_eq!(batch.source_url, "test://stats");
    assert_eq!(batch.records_seen, 1);
    assert_eq!(batch.records_skipped, 0);
    assert_eq!(batch.records_upserted, 1);
    assert!(batch.completed_at.is_some());
}

#[tokio::test]
async fn ingest_is_idempotent_when_run_twice() {
    let (foods, servings, _batches, svc) = build_service();

    let records = vec![
        rec_complete("5000", "Repeat-1"),
        rec_complete("5001", "Repeat-2"),
    ];

    let first = svc
        .run(VecSource::new(records.clone()), "test://idem", None)
        .await
        .unwrap();
    assert_eq!(first.inserted, 2);
    assert_eq!(first.updated, 0);

    let second = svc
        .run(VecSource::new(records.clone()), "test://idem", None)
        .await
        .unwrap();
    assert_eq!(second.inserted, 0);
    assert_eq!(second.updated, 2);

    // Repository should still hold exactly the two foods.
    let f1 = foods
        .find_by_barcode(Uuid::nil(), "5000")
        .await
        .unwrap()
        .unwrap();
    let f2 = foods
        .find_by_barcode(Uuid::nil(), "5001")
        .await
        .unwrap()
        .unwrap();
    assert!(f1.source == FoodSource::Off);
    assert!(f2.source == FoodSource::Off);

    use loseit_core::repo::ServingRepository;
    for id in [f1.id, f2.id] {
        let list = servings.list_for_food(id).await.unwrap();
        // Exactly one system serving + one OFF serving.
        assert_eq!(list.len(), 2, "servings rebuild should be idempotent");
        assert_eq!(list.iter().filter(|s| s.is_default).count(), 1);
    }
}

// -------- Quality score unit tests --------

#[test]
fn test_quality_score_minimum_zero_for_empty_record() {
    let r = OffFoodRecord::default();
    assert_eq!(score(&r), 0);
}

#[test]
fn test_quality_score_capped_at_100() {
    let r = OffFoodRecord {
        code: "X".into(),
        product_name: "X".into(),
        brands: Some("Brand".into()),
        categories_tags: vec!["a".into(), "b".into()],
        nutriscore_grade: Some("a".into()),
        completeness: Some(1.0),
        serving_size: Some("30 g".into()),
        serving_quantity: Some(d(30)),
        energy_kcal_100g: Some(d(100)),
        protein_100g: Some(d(1)),
        carbs_100g: Some(d(1)),
        fat_100g: Some(d(1)),
        fiber_100g: Some(d(1)),
        sugar_100g: Some(d(1)),
        sodium_100g: Some(d(1)),
        saturated_fat_100g: Some(d(1)),
    };
    let s = score(&r);
    assert!(s <= 100, "score should be capped at 100, got {s}");
    assert!(
        s >= 90,
        "fully-loaded record should score near 100, got {s}"
    );
}

#[test]
fn test_quality_score_awards_full_points_for_complete_record() {
    let r = OffFoodRecord {
        code: "X".into(),
        product_name: "X".into(),
        brands: Some("Brand".into()),
        categories_tags: vec!["en:cat".into()],
        nutriscore_grade: Some("b".into()),
        completeness: Some(1.0),
        serving_size: Some("45 g".into()),
        serving_quantity: Some(d(45)),
        energy_kcal_100g: Some(d(100)),
        protein_100g: Some(d(1)),
        carbs_100g: Some(d(1)),
        fat_100g: Some(d(1)),
        fiber_100g: Some(d(1)),
        sugar_100g: Some(d(1)),
        sodium_100g: Some(d(1)),
        saturated_fat_100g: Some(d(1)),
    };
    // 40 (nutriscore) + 15 (brand) + 15 (off serving) + 10 (>=6 nutrients)
    // + 10 (completeness) + 10 (categories) = 100
    assert_eq!(score(&r), 100);
}

#[test]
fn test_parse_serving_size_grams_handles_common_shapes() {
    assert_eq!(parse_serving_size_grams("30 g"), Some(d(30)));
    assert_eq!(parse_serving_size_grams("30g"), Some(d(30)));
    assert_eq!(
        parse_serving_size_grams("30.5 g"),
        Some(Decimal::new(305, 1))
    );
    assert_eq!(parse_serving_size_grams("1 cup (240 g)"), Some(d(240)));
    // Pure-ml is skipped.
    assert_eq!(parse_serving_size_grams("250 ml"), None);
    assert_eq!(parse_serving_size_grams(""), None);
}

#[test]
fn test_accept_and_normalize_drops_bad_inputs() {
    // Missing energy.
    let r = OffFoodRecord {
        code: "1".into(),
        product_name: "x".into(),
        ..Default::default()
    };
    assert!(accept_and_normalize(r).is_none());

    // Missing name.
    let r = OffFoodRecord {
        code: "1".into(),
        product_name: "".into(),
        energy_kcal_100g: Some(d(100)),
        ..Default::default()
    };
    assert!(accept_and_normalize(r).is_none());

    // OK.
    let r = OffFoodRecord {
        code: "1".into(),
        product_name: "Apple".into(),
        energy_kcal_100g: Some(d(50)),
        ..Default::default()
    };
    let u = accept_and_normalize(r).expect("accepts minimal record");
    assert_eq!(u.draft.name, "Apple");
    assert_eq!(u.system_100g_serving.grams, d(100));
}
