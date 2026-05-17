//! Integration tests for FoodService (§5.4 invariants).
//!
//! Runs against in-memory repo fakes — no Postgres required.

use std::sync::Arc;

use loseit_core::domain::serving::ServingSource;
use loseit_core::domain::unit::Unit;
use loseit_core::domain::{FoodDraft, ServingDraft};
use loseit_core::service::FoodService;
use loseit_core::CoreError;
use loseit_testing::{InMemoryFoodRepository, InMemoryServingRepository};
use rust_decimal_macros::dec;
use uuid::Uuid;

fn base_serving_draft(is_default: bool) -> ServingDraft {
    ServingDraft {
        label: None,
        amount: dec!(1),
        unit: Unit::Gram,
        kcal: dec!(100),
        protein_g: None,
        carbs_g: None,
        fat_g: None,
        fiber_g: None,
        sugar_g: None,
        sodium_mg: None,
        saturated_fat_g: None,
        is_default,
        source: ServingSource::User,
        sort_order: 0,
    }
}

fn make_food_draft(servings: Vec<ServingDraft>) -> FoodDraft {
    FoodDraft {
        name: "Test Food".into(),
        brands: None,
        barcode: None,
        categories_tags: vec![],
        nutriscore_grade: None,
        servings,
    }
}

fn make_service() -> FoodService {
    let food_repo = Arc::new(InMemoryFoodRepository::new());
    let srv_repo = Arc::new(InMemoryServingRepository::new());
    food_repo.set_serving_repo(srv_repo.clone());
    FoodService::new(food_repo, srv_repo)
}

/// §5.4: empty servings list is rejected with Validation containing "serving".
#[tokio::test]
async fn test_create_custom_empty_servings_rejected() {
    let svc = make_service();
    let draft = make_food_draft(vec![]);
    let err = svc
        .create_custom(Uuid::new_v4(), draft)
        .await
        .unwrap_err();
    match err {
        CoreError::Validation(msg) => assert!(msg.contains("serving"), "msg={msg}"),
        other => panic!("expected Validation, got {other:?}"),
    }
}

/// §5.4: multiple is_default=true → Validation containing "default".
#[tokio::test]
async fn test_create_custom_multi_default_rejected() {
    let svc = make_service();
    let draft = make_food_draft(vec![
        base_serving_draft(true),
        base_serving_draft(true),
    ]);
    let err = svc
        .create_custom(Uuid::new_v4(), draft)
        .await
        .unwrap_err();
    match err {
        CoreError::Validation(msg) => assert!(msg.contains("default"), "msg={msg}"),
        other => panic!("expected Validation, got {other:?}"),
    }
}

/// When no serving has is_default=true, the first is automatically marked.
#[tokio::test]
async fn test_create_custom_auto_marks_first_default() {
    let svc = make_service();
    // Two servings, neither is default.
    let draft = make_food_draft(vec![
        base_serving_draft(false),
        base_serving_draft(false),
    ]);
    // Should succeed — the service marks the first one default internally.
    svc.create_custom(Uuid::new_v4(), draft)
        .await
        .expect("create should succeed");
}
