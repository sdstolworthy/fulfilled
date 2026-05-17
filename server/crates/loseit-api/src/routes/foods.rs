//! Food + serving handlers.
//!
//! Routes:
//!
//! * `GET    /foods/:id`                    — full food detail + servings.
//! * `GET    /foods/barcode/:barcode`       — same shape, looked up by barcode.
//! * `GET    /foods/search`                 — paginated `FoodSearchHit` projection.
//! * `GET    /foods/mine`                   — user's custom foods, paginated.
//! * `POST   /foods`                        — create a user-owned custom food.
//! * `PATCH  /foods/:id`                    — partial update (owner only).
//! * `DELETE /foods/:id`                    — soft-delete (owner only).
//! * `POST   /foods/:food_id/servings`      — add a serving to a food.
//! * `PATCH  /servings/:id`                 — update a serving.
//! * `DELETE /servings/:id`                 — delete a serving.
//! * `POST   /servings/:id/default`         — atomic default-serving flip.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use loseit_core::domain::{
    Food, FoodDraft, FoodKind, FoodPatch, FoodSearchHit, FoodSource, NutriscoreGrade,
    Serving, ServingDraft, ServingPatch, ServingPreview, ServingSource,
};
use loseit_core::domain::unit::Unit;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthenticatedUser;
use crate::error::ApiError;
use crate::routes::pagination::PaginatedResponse;
use crate::server::AppState;

pub fn router() -> Router<AppState> {
    // Order note: axum (matchit) rejects ambiguous routes at construction
    // time, so `/foods/search` and `/foods/barcode/:barcode` must be
    // declared as distinct nodes from `/foods/:id`. We list the static
    // children first defensively even though matchit doesn't require it.
    // `POST /servings/:id/default` is registered *separately* from
    // `PATCH /servings/:id` because the trailing `/default` static segment
    // is what disambiguates them.
    // Order note: static segments (/search, /recent, /frequent,
    // /barcode/:barcode) MUST be declared before the catch-all /:id so
    // axum/matchit's matcher disambiguates them. Production routes:
    //   /foods/search, /foods/recent, /foods/frequent, /foods/barcode/:bc
    // all collide with /foods/:id otherwise.
    Router::new()
        .route("/foods/search", get(search))
        .route("/foods/mine", get(list_mine))
        .route("/foods/recent", get(recent_foods))
        .route("/foods/frequent", get(frequent_foods))
        .route("/foods/barcode/:barcode", get(get_by_barcode))
        .route("/foods", post(create_food))
        .route(
            "/foods/:id",
            get(get_by_id).patch(patch_food).delete(delete_food),
        )
        .route("/foods/:food_id/servings", post(create_serving))
        .route("/servings/:id", patch(patch_serving).delete(delete_serving))
        .route("/servings/:id/default", post(set_default_serving))
}

// -- Response DTOs -----------------------------------------------------------

#[derive(Serialize)]
struct ServingResponse {
    id: Uuid,
    label: Option<String>,
    amount: Decimal,
    unit: &'static str,
    kcal: Decimal,
    protein_g: Option<Decimal>,
    carbs_g: Option<Decimal>,
    fat_g: Option<Decimal>,
    fiber_g: Option<Decimal>,
    sugar_g: Option<Decimal>,
    sodium_mg: Option<Decimal>,
    saturated_fat_g: Option<Decimal>,
    is_default: bool,
    source: &'static str,
    sort_order: i32,
}

impl From<Serving> for ServingResponse {
    fn from(s: Serving) -> Self {
        Self {
            id: s.id,
            label: s.label,
            amount: s.amount,
            unit: s.unit.as_str(),
            kcal: s.kcal,
            protein_g: s.protein_g,
            carbs_g: s.carbs_g,
            fat_g: s.fat_g,
            fiber_g: s.fiber_g,
            sugar_g: s.sugar_g,
            sodium_mg: s.sodium_mg,
            saturated_fat_g: s.saturated_fat_g,
            is_default: s.is_default,
            source: serving_source_str(s.source),
            sort_order: s.sort_order,
        }
    }
}

fn serving_source_str(src: ServingSource) -> &'static str {
    src.as_str()
}

fn food_source_str(src: FoodSource) -> &'static str {
    src.as_str()
}

fn food_kind_str(kind: FoodKind) -> &'static str {
    kind.as_str()
}

fn nutriscore_str(g: NutriscoreGrade) -> &'static str {
    g.as_str()
}

#[derive(Serialize)]
struct FoodDetailResponse {
    id: Uuid,
    source: &'static str,
    kind: &'static str,
    owner_user_id: Option<Uuid>,
    barcode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fdc_id: Option<i64>,
    name: String,
    brands: Option<String>,
    categories_tags: Vec<String>,
    nutriscore: Option<&'static str>,
    quality_score: i16,
    #[serde(skip_serializing_if = "Option::is_none")]
    extra_nutrients: Option<serde_json::Value>,
    servings: Vec<ServingResponse>,
}

impl FoodDetailResponse {
    fn from_pair(food: Food, servings: Vec<Serving>) -> Self {
        Self {
            id: food.id,
            source: food_source_str(food.source),
            kind: food_kind_str(food.kind),
            owner_user_id: food.owner_user_id,
            barcode: food.barcode,
            fdc_id: food.fdc_id,
            name: food.name,
            brands: food.brands,
            categories_tags: food.categories_tags,
            nutriscore: food.nutriscore_grade.map(nutriscore_str),
            quality_score: food.quality_score,
            extra_nutrients: food.extra_nutrients,
            servings: servings.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Serialize)]
struct ServingPreviewResponse {
    id: Uuid,
    label: Option<String>,
    amount: Decimal,
    unit: &'static str,
    kcal: Decimal,
}

impl From<ServingPreview> for ServingPreviewResponse {
    fn from(p: ServingPreview) -> Self {
        Self {
            id: p.id,
            label: p.label,
            amount: p.amount,
            unit: p.unit.as_str(),
            kcal: p.kcal,
        }
    }
}

#[derive(Serialize)]
struct FoodSearchHitResponse {
    id: Uuid,
    source: &'static str,
    name: String,
    brand: Option<String>,
    barcode: Option<String>,
    default_serving: Option<ServingPreviewResponse>,
}

impl From<FoodSearchHit> for FoodSearchHitResponse {
    fn from(h: FoodSearchHit) -> Self {
        Self {
            id: h.id,
            source: food_source_str(h.source),
            name: h.name,
            brand: h.brand,
            barcode: h.barcode,
            default_serving: h.default_serving.map(Into::into),
        }
    }
}

// -- Query params ------------------------------------------------------------

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
    limit: Option<i64>,
    offset: Option<i64>,
}

#[derive(Deserialize)]
struct MineQuery {
    q: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
}

#[derive(Deserialize)]
struct LimitOnlyQuery {
    /// Cap/default applied service-side in `LogService::recent_foods` /
    /// `frequent_foods`. The handler just forwards.
    limit: Option<i64>,
}

// -- Request DTOs ------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct ServingBody {
    label: Option<String>,
    amount: Decimal,
    unit: String,  // parsed to Unit at handler entry via Unit::parse
    kcal: Decimal,
    protein_g: Option<Decimal>,
    carbs_g: Option<Decimal>,
    fat_g: Option<Decimal>,
    fiber_g: Option<Decimal>,
    sugar_g: Option<Decimal>,
    sodium_mg: Option<Decimal>,
    saturated_fat_g: Option<Decimal>,
    is_default: Option<bool>,
    source: Option<String>,
    sort_order: Option<i32>,
}

fn parse_unit(raw: &str) -> Result<Unit, ApiError> {
    Unit::parse(raw).ok_or_else(|| {
        ApiError::new(
            axum::http::StatusCode::BAD_REQUEST,
            "invalid_unit",
            format!("unknown unit '{raw}' (expected one of g, kg, oz, lb, ml, l, cup, fl_oz, tbsp, tsp, serving, piece)"),
        )
    })
}

impl ServingBody {
    fn into_draft(self) -> Result<ServingDraft, ApiError> {
        let unit = parse_unit(&self.unit)?;
        let source = match self.source.as_deref() {
            Some(s) => parse_serving_source(s)?,
            None => ServingSource::User,
        };
        Ok(ServingDraft {
            label: self.label,
            amount: self.amount,
            unit,
            kcal: self.kcal,
            protein_g: self.protein_g,
            carbs_g: self.carbs_g,
            fat_g: self.fat_g,
            fiber_g: self.fiber_g,
            sugar_g: self.sugar_g,
            sodium_mg: self.sodium_mg,
            saturated_fat_g: self.saturated_fat_g,
            is_default: self.is_default.unwrap_or(false),
            source,
            sort_order: self.sort_order.unwrap_or(0),
        })
    }
}

#[derive(Debug, Deserialize)]
struct CreateFoodBody {
    name: String,
    brands: Option<String>,
    barcode: Option<String>,
    #[serde(default)]
    categories_tags: Vec<String>,
    nutriscore_grade: Option<String>,
    #[serde(default)]
    servings: Vec<ServingBody>,
}

#[derive(Debug, Deserialize, Default)]
struct PatchFoodBody {
    name: Option<String>,
    brands: Option<String>,
    barcode: Option<String>,
    categories_tags: Option<Vec<String>>,
    nutriscore_grade: Option<String>,
    servings: Option<Vec<ServingBody>>,
}

fn parse_nutriscore(raw: &str) -> Result<NutriscoreGrade, ApiError> {
    NutriscoreGrade::parse(&raw.to_lowercase()).ok_or_else(|| {
        ApiError::bad_request(format!(
            "unknown nutriscore_grade '{raw}' (expected one of a, b, c, d, e)"
        ))
    })
}

fn parse_serving_source(raw: &str) -> Result<ServingSource, ApiError> {
    ServingSource::parse(&raw.to_lowercase()).ok_or_else(|| {
        ApiError::bad_request(format!(
            "unknown serving source '{raw}' (expected one of off, user, system)"
        ))
    })
}

#[derive(Debug, Deserialize)]
struct PatchServingBody {
    label: Option<Option<String>>,
    amount: Option<Decimal>,
    unit: Option<String>,
    kcal: Option<Decimal>,
    protein_g: Option<Option<Decimal>>,
    carbs_g: Option<Option<Decimal>>,
    fat_g: Option<Option<Decimal>>,
    fiber_g: Option<Option<Decimal>>,
    sugar_g: Option<Option<Decimal>>,
    sodium_mg: Option<Option<Decimal>>,
    saturated_fat_g: Option<Option<Decimal>>,
    sort_order: Option<i32>,
}

// -- Handlers ----------------------------------------------------------------

async fn get_by_id(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
) -> Result<Json<FoodDetailResponse>, ApiError> {
    let (food, servings) = state.foods.detail(user.id, id).await?;
    Ok(Json(FoodDetailResponse::from_pair(food, servings)))
}

async fn get_by_barcode(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(barcode): Path<String>,
) -> Result<Json<FoodDetailResponse>, ApiError> {
    let (food, servings) = state.foods.by_barcode(user.id, &barcode).await?;
    Ok(Json(FoodDetailResponse::from_pair(food, servings)))
}

async fn search(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<SearchQuery>,
) -> Result<Json<PaginatedResponse<FoodSearchHitResponse>>, ApiError> {
    // Service is the source of truth for validation rules: blank query →
    // `Validation`, limit cap, default offset. The handler just translates
    // the result via the generic `From<Paginated<T>>` adapter.
    let page = state.foods.search(user.id, &q.q, q.limit, q.offset).await?;
    Ok(Json(page.into()))
}

async fn list_mine(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<MineQuery>,
) -> Result<Json<PaginatedResponse<FoodSearchHitResponse>>, ApiError> {
    let page = state
        .foods
        .list_mine(user.id, q.q.as_deref(), q.limit, q.offset)
        .await?;
    Ok(Json(page.into()))
}

// -- /foods/recent + /foods/frequent -----------------------------------------

async fn recent_foods(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<LimitOnlyQuery>,
) -> Result<Json<Vec<FoodSearchHitResponse>>, ApiError> {
    let limit = q.limit.unwrap_or(0);
    let hits = state.logs.recent_foods(user.id, limit).await?;
    Ok(Json(hits.into_iter().map(Into::into).collect()))
}

async fn frequent_foods(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<LimitOnlyQuery>,
) -> Result<Json<Vec<FoodSearchHitResponse>>, ApiError> {
    let limit = q.limit.unwrap_or(0);
    let hits = state.logs.frequent_foods(user.id, limit).await?;
    Ok(Json(hits.into_iter().map(Into::into).collect()))
}

// -- Custom food write handlers -----------------------------------------------

async fn create_food(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<CreateFoodBody>,
) -> Result<(StatusCode, Json<FoodDetailResponse>), ApiError> {
    let nutriscore_grade = body
        .nutriscore_grade
        .as_deref()
        .map(parse_nutriscore)
        .transpose()?;
    let servings: Result<Vec<ServingDraft>, ApiError> = body
        .servings
        .into_iter()
        .map(|s| s.into_draft())
        .collect();
    let draft = FoodDraft {
        name: body.name,
        brands: body.brands,
        barcode: body.barcode,
        fdc_id: None,
        data_type: None,
        categories_tags: body.categories_tags,
        nutriscore_grade,
        servings: servings?,
    };
    let food = state.foods.create_custom(user.id, draft).await?;
    // Re-hydrate so the response reflects the persisted servings.
    let (food, servings) = state.foods.detail(user.id, food.id).await?;
    Ok((
        StatusCode::CREATED,
        Json(FoodDetailResponse::from_pair(food, servings)),
    ))
}

async fn patch_food(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchFoodBody>,
) -> Result<Json<FoodDetailResponse>, ApiError> {
    let nutriscore_grade = body
        .nutriscore_grade
        .as_deref()
        .map(parse_nutriscore)
        .transpose()?;
    let servings = match body.servings {
        Some(sv) => {
            let drafts: Result<Vec<ServingDraft>, ApiError> =
                sv.into_iter().map(|s| s.into_draft()).collect();
            Some(drafts?)
        }
        None => None,
    };
    let patch = FoodPatch {
        name: body.name,
        brands: body.brands,
        barcode: body.barcode,
        categories_tags: body.categories_tags,
        nutriscore_grade,
        servings,
    };
    state.foods.update_custom(user.id, id, patch).await?;
    let (food, servings) = state.foods.detail(user.id, id).await?;
    Ok(Json(FoodDetailResponse::from_pair(food, servings)))
}

async fn delete_food(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    state.foods.delete_custom(user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

// -- Serving write handlers ---------------------------------------------------

async fn create_serving(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(food_id): Path<Uuid>,
    Json(body): Json<ServingBody>,
) -> Result<(StatusCode, Json<ServingResponse>), ApiError> {
    let draft = body.into_draft()?;
    let serving = state.servings.create(user.id, food_id, draft).await?;
    Ok((StatusCode::CREATED, Json(serving.into())))
}

async fn patch_serving(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchServingBody>,
) -> Result<Json<ServingResponse>, ApiError> {
    let unit = match &body.unit {
        Some(u) => Some(parse_unit(u)?),
        None => None,
    };
    let patch = ServingPatch {
        label: body.label,
        amount: body.amount,
        unit,
        kcal: body.kcal,
        protein_g: body.protein_g,
        carbs_g: body.carbs_g,
        fat_g: body.fat_g,
        fiber_g: body.fiber_g,
        sugar_g: body.sugar_g,
        sodium_mg: body.sodium_mg,
        saturated_fat_g: body.saturated_fat_g,
        sort_order: body.sort_order,
    };
    let serving = state.servings.update(user.id, id, patch).await?;
    Ok(Json(serving.into()))
}

async fn delete_serving(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    state.servings.delete(user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn set_default_serving(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
) -> Result<Json<ServingResponse>, ApiError> {
    // `set_default` needs the food id; resolve it from the serving so the
    // route stays single-id (clients don't have to pass food_id again).
    let serving = state
        .servings
        .servings()
        .find_by_id(id)
        .await?
        .ok_or_else(ApiError::not_found)?;
    state
        .servings
        .set_default(user.id, serving.food_id, id)
        .await?;
    // Re-read so the response reflects the post-flip state.
    let updated = state
        .servings
        .servings()
        .find_by_id(id)
        .await?
        .ok_or_else(ApiError::not_found)?;
    Ok(Json(updated.into()))
}
