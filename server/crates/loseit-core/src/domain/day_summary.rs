use chrono::NaiveDate;
use rust_decimal::Decimal;

use crate::domain::goal::Goal;
use crate::domain::log_entry::NutritionSnapshot;
use crate::domain::meal::Meal;

#[derive(Debug, Clone)]
pub struct MealSubtotal {
    pub meal: Meal,
    pub calories_kcal: Decimal,
    pub protein_g: Decimal,
    pub carbs_g: Decimal,
    pub fat_g: Decimal,
    pub entry_count: u32,
}

#[derive(Debug, Clone)]
pub struct DaySummary {
    pub date: NaiveDate,
    pub total: NutritionSnapshot,
    pub by_meal: Vec<MealSubtotal>,
    pub active_goal: Option<Goal>,
}
