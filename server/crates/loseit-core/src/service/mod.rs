//! Application services. These are the "plain English" business layer —
//! they orchestrate repositories and enforce invariants. Concrete services
//! are constructed at the composition root with the repository
//! implementations they need.

pub mod auth;
pub mod food;
pub mod goal;
pub mod ingest;
pub mod log;
pub mod page;
pub mod serving;
pub mod user;
pub mod user_food_summary;
pub mod weight;

pub use auth::{AuthService, TOKEN_TTL};
pub use food::FoodService;
pub use goal::GoalService;
pub use ingest::{
    accept_and_normalize_off, accept_and_normalize_usda,
    FoodRecordSource, IngestService, OffFoodRecord, OffSource,
    UsdaFoodRecord, UsdaFoodPortion, UsdaSource,
};
pub use log::{LogService, FREQUENT_WINDOW_DAYS};
pub use page::{resolve_page_params, PageParams, Paginated, DEFAULT_PAGE_LIMIT, MAX_PAGE_LIMIT};
pub use serving::ServingService;
pub use user::UserService;
pub use user_food_summary::{enrich_hits, wrap_hits, UserFoodSummaryReader};
pub use weight::WeightService;
