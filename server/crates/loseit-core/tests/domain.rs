//! Phase 0 acceptance tests: round-trip parsing of the small enum types
//! we added in T01. Real behaviour tests live with the services.

use loseit_core::domain::{FoodSource, Meal, NutriscoreGrade, ServingSource};

#[test]
fn meal_from_str_round_trip() {
    for m in Meal::all() {
        let s = m.to_string();
        assert_eq!(s.parse::<Meal>().unwrap(), m, "round trip for {s}");
    }
    assert!("brunch".parse::<Meal>().is_err());
}

#[test]
fn food_source_parse_rejects_unknown() {
    assert_eq!(FoodSource::parse("off"), Some(FoodSource::Off));
    assert_eq!(FoodSource::parse("user"), Some(FoodSource::User));
    assert_eq!(FoodSource::parse("admin"), None);
}

#[test]
fn nutriscore_grade_round_trip() {
    for g in [
        NutriscoreGrade::A,
        NutriscoreGrade::B,
        NutriscoreGrade::C,
        NutriscoreGrade::D,
        NutriscoreGrade::E,
    ] {
        assert_eq!(NutriscoreGrade::parse(g.as_str()), Some(g));
    }
    assert_eq!(NutriscoreGrade::parse("z"), None);
}

#[test]
fn serving_source_parse_rejects_unknown() {
    assert_eq!(ServingSource::parse("off"), Some(ServingSource::Off));
    assert_eq!(ServingSource::parse("user"), Some(ServingSource::User));
    assert_eq!(ServingSource::parse("system"), Some(ServingSource::System));
    assert_eq!(ServingSource::parse("auto"), None);
}
