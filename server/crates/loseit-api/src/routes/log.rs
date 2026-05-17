//! Food-log + day-summary handlers.
//!
//! Routes:
//!
//! * `POST   /log`               — create a log entry.
//! * `POST   /log/quick_add`     — log raw calories without choosing a food.
//! * `POST   /log/copy`          — copy all (or one meal's) entries to another date.
//! * `GET    /log`               — list entries; optional from/to/limit/offset.
//! * `PATCH  /log/:id`           — partial update; `food_id` is immutable.
//! * `DELETE /log/:id`           — remove an entry.
//! * `GET    /days/:date/summary` — per-day rollup with active goal.
//!
//! The day-summary handler lives here (rather than in a sibling
//! `routes/days.rs`) because it is wired entirely through `LogService` and
//! shares this module's nutrition-snapshot DTO — a separate file would
//! duplicate that flatten boilerplate.
//!
//! Wire shape: every endpoint that returns nutrition flattens
//! `NutritionSnapshot` into top-level fields whose names match the
//! `food_log_entries` columns in `migrations/0001_initial.sql`. This
//! preserves the "snapshot of nutrition for this exact entry" semantics on
//! the wire without forcing clients to nest into `snapshot.*`.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, NaiveDate, Utc};
use loseit_core::domain::{
    unit::Unit, DaySummary, FoodLogEntry, LogDraft, LogPatch, Meal, MealSubtotal, NutritionSnapshot,
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthenticatedUser;
use crate::error::ApiError;
use crate::routes::goals::GoalResponse;
use crate::routes::pagination::PaginatedResponse;
use crate::server::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/log", post(create).get(list))
        .route("/log/quick_add", post(quick_add))
        // `/log/copy` must register *before* `/log/:id` — axum's matchit-based
        // router treats `copy` as a path param under the wildcard otherwise,
        // and DELETE /log/copy would silently reach the entry handler.
        .route("/log/copy", post(copy_day))
        .route("/log/:id", axum::routing::patch(patch).delete(remove))
        .route("/days/:date/summary", get(day_summary))
}

// -- Wire shapes -------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct CreateLogBody {
    food_id: Uuid,
    serving_id: Uuid,
    consumed_on: NaiveDate,
    meal: String,
    entered_amount: Decimal,
    entered_unit: String,
    #[serde(default)]
    note: Option<String>,
}

#[derive(Debug, Deserialize)]
struct QuickAddBody {
    calories_kcal: Decimal,
    meal: String,
    consumed_on: NaiveDate,
    #[serde(default)]
    note: Option<String>,
}

/// PATCH body. `food_id` is intentionally accepted-and-rejected: clients
/// occasionally send the full original entry back; we surface a clear 400
/// rather than silently ignoring the field.
#[derive(Debug, Deserialize, Default)]
struct PatchLogBody {
    #[serde(default)]
    food_id: Option<Uuid>,
    #[serde(default)]
    serving_id: Option<Uuid>,
    #[serde(default)]
    consumed_on: Option<NaiveDate>,
    #[serde(default)]
    meal: Option<String>,
    #[serde(default)]
    entered_amount: Option<Decimal>,
    #[serde(default)]
    entered_unit: Option<String>,
    // Double-Option so the wire `"note": null` can clear, but a missing key
    // leaves the existing value untouched.
    #[serde(default, deserialize_with = "deserialize_optional_optional_string")]
    note: Option<Option<String>>,
}

fn deserialize_optional_optional_string<'de, D>(
    deserializer: D,
) -> Result<Option<Option<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    // `null` deserializes to `Some(None)`; an actual string deserializes to
    // `Some(Some(...))`. A missing key never reaches this fn (serde uses the
    // `default` attribute).
    let v: Option<String> = Option::deserialize(deserializer)?;
    Ok(Some(v))
}

/// Body for `POST /log/copy`. `meal` is optional — when present, only entries
/// matching that meal are copied. `from_date > to_date` is intentionally
/// permitted (backward copy is legitimate), unlike the GET-list range filter.
#[derive(Debug, Deserialize)]
struct CopyDayBody {
    from_date: NaiveDate,
    to_date: NaiveDate,
    #[serde(default)]
    meal: Option<String>,
}

/// Wrapped response so future fields (e.g. `skipped`) can be added without
/// breaking the wire shape.
#[derive(Serialize)]
struct CopyDayResponse {
    copied: Vec<LogEntryResponse>,
}

#[derive(Debug, Deserialize)]
struct ListLogQuery {
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: Option<i64>,
    offset: Option<i64>,
}

#[derive(Serialize)]
struct LogEntryResponse {
    id: Uuid,
    food_id: Uuid,
    food_name: String,
    serving_id: Option<Uuid>,
    serving_name: Option<String>,
    consumed_on: NaiveDate,
    meal: &'static str,
    quantity: Decimal,
    entered_amount: Decimal,
    entered_unit: &'static str,
    // Flattened nutrition snapshot. Field names match the SQL column names
    // in `food_log_entries`.
    calories_kcal: Decimal,
    protein_g: Option<Decimal>,
    carbs_g: Option<Decimal>,
    fat_g: Option<Decimal>,
    fiber_g: Option<Decimal>,
    sugar_g: Option<Decimal>,
    sodium_mg: Option<Decimal>,
    saturated_fat_g: Option<Decimal>,
    note: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<FoodLogEntry> for LogEntryResponse {
    fn from(e: FoodLogEntry) -> Self {
        Self {
            id: e.id,
            food_id: e.food_id,
            food_name: e.food_name,
            serving_id: e.serving_id,
            serving_name: e.serving_name,
            consumed_on: e.consumed_on,
            meal: e.meal.as_str(),
            quantity: e.quantity,
            entered_amount: e.entered_amount,
            entered_unit: e.entered_unit.as_str(),
            calories_kcal: e.snapshot.calories_kcal,
            protein_g: e.snapshot.protein_g,
            carbs_g: e.snapshot.carbs_g,
            fat_g: e.snapshot.fat_g,
            fiber_g: e.snapshot.fiber_g,
            sugar_g: e.snapshot.sugar_g,
            sodium_mg: e.snapshot.sodium_mg,
            saturated_fat_g: e.snapshot.saturated_fat_g,
            note: e.note,
            created_at: e.created_at,
            updated_at: e.updated_at,
        }
    }
}

// -- Day summary DTOs --------------------------------------------------------

#[derive(Serialize)]
struct NutritionTotalResponse {
    calories_kcal: Decimal,
    protein_g: Option<Decimal>,
    carbs_g: Option<Decimal>,
    fat_g: Option<Decimal>,
    fiber_g: Option<Decimal>,
    sugar_g: Option<Decimal>,
    sodium_mg: Option<Decimal>,
    saturated_fat_g: Option<Decimal>,
}

impl From<NutritionSnapshot> for NutritionTotalResponse {
    fn from(n: NutritionSnapshot) -> Self {
        Self {
            calories_kcal: n.calories_kcal,
            protein_g: n.protein_g,
            carbs_g: n.carbs_g,
            fat_g: n.fat_g,
            fiber_g: n.fiber_g,
            sugar_g: n.sugar_g,
            sodium_mg: n.sodium_mg,
            saturated_fat_g: n.saturated_fat_g,
        }
    }
}

#[derive(Serialize)]
struct MealSubtotalResponse {
    meal: &'static str,
    calories_kcal: Decimal,
    protein_g: Decimal,
    carbs_g: Decimal,
    fat_g: Decimal,
    entry_count: u32,
}

impl From<MealSubtotal> for MealSubtotalResponse {
    fn from(m: MealSubtotal) -> Self {
        Self {
            meal: m.meal.as_str(),
            calories_kcal: m.calories_kcal,
            protein_g: m.protein_g,
            carbs_g: m.carbs_g,
            fat_g: m.fat_g,
            entry_count: m.entry_count,
        }
    }
}

#[derive(Serialize)]
struct DaySummaryResponse {
    date: NaiveDate,
    total: NutritionTotalResponse,
    by_meal: Vec<MealSubtotalResponse>,
    active_goal: Option<GoalResponse>,
}

impl From<DaySummary> for DaySummaryResponse {
    fn from(s: DaySummary) -> Self {
        Self {
            date: s.date,
            total: s.total.into(),
            by_meal: s.by_meal.into_iter().map(Into::into).collect(),
            active_goal: s.active_goal.map(Into::into),
        }
    }
}

// -- Helpers -----------------------------------------------------------------

fn parse_meal(raw: &str) -> Result<Meal, ApiError> {
    raw.parse::<Meal>().map_err(|_| {
        ApiError::bad_request(format!(
            "unknown meal '{raw}' (expected one of breakfast, lunch, dinner, snack)"
        ))
    })
}

// -- Handlers ----------------------------------------------------------------

fn parse_unit(raw: &str) -> Result<Unit, ApiError> {
    Unit::parse(raw).ok_or_else(|| {
        ApiError::bad_request(format!(
            "unknown unit '{raw}' (expected one of g, kg, oz, lb, ml, l, cup, fl_oz, tbsp, tsp, serving, piece)"
        ))
    })
}

async fn create(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<CreateLogBody>,
) -> Result<(StatusCode, Json<LogEntryResponse>), ApiError> {
    let meal = parse_meal(&body.meal)?;
    let entered_unit = parse_unit(&body.entered_unit)?;
    let draft = LogDraft {
        food_id: body.food_id,
        serving_id: body.serving_id,
        consumed_on: body.consumed_on,
        meal,
        entered_amount: body.entered_amount,
        entered_unit,
        note: body.note,
    };
    let entry = state.logs.create(user.id, draft).await?;
    Ok((StatusCode::CREATED, Json(entry.into())))
}

async fn quick_add(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<QuickAddBody>,
) -> Result<(StatusCode, Json<LogEntryResponse>), ApiError> {
    let meal = parse_meal(&body.meal)?;
    let entry = state
        .logs
        .quick_add(
            user.id,
            body.calories_kcal,
            meal,
            body.consumed_on,
            body.note,
        )
        .await?;
    Ok((StatusCode::CREATED, Json(entry.into())))
}

async fn list(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<ListLogQuery>,
) -> Result<Json<PaginatedResponse<LogEntryResponse>>, ApiError> {
    let page = state
        .logs
        .list(user.id, q.from, q.to, q.limit, q.offset)
        .await?;
    Ok(Json(page.into()))
}

async fn patch(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchLogBody>,
) -> Result<Json<LogEntryResponse>, ApiError> {
    if body.food_id.is_some() {
        return Err(ApiError::bad_request(
            "food_id is immutable; create a new entry to log a different food",
        ));
    }
    let meal = body.meal.as_deref().map(parse_meal).transpose()?;
    let entered_unit = body
        .entered_unit
        .as_deref()
        .map(parse_unit)
        .transpose()?;
    let patch = LogPatch {
        serving_id: body.serving_id,
        consumed_on: body.consumed_on,
        meal,
        entered_amount: body.entered_amount,
        entered_unit,
        note: body.note,
    };
    let entry = state.logs.update(user.id, id, patch).await?;
    Ok(Json(entry.into()))
}

async fn remove(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    state.logs.delete(user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn day_summary(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(date): Path<NaiveDate>,
) -> Result<Json<DaySummaryResponse>, ApiError> {
    let summary = state.logs.day_summary(user.id, date).await?;
    Ok(Json(summary.into()))
}

async fn copy_day(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<CopyDayBody>,
) -> Result<(StatusCode, Json<CopyDayResponse>), ApiError> {
    // Parse the optional meal *eagerly* — an unknown value becomes 400 rather
    // than being silently dropped, which would otherwise look like a
    // successful no-filter copy.
    let meal = body.meal.as_deref().map(parse_meal).transpose()?;
    let copied = state
        .logs
        .copy_day(user.id, body.from_date, body.to_date, meal)
        .await?;
    Ok((
        StatusCode::CREATED,
        Json(CopyDayResponse {
            copied: copied.into_iter().map(Into::into).collect(),
        }),
    ))
}
