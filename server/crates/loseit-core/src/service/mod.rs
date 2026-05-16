//! Application services. These are the "plain English" business layer —
//! they orchestrate repositories and enforce invariants. Concrete services
//! are constructed at the composition root with the repository
//! implementations they need.

pub mod food;
pub mod goal;
pub mod ingest;
pub mod log;
pub mod page;
pub mod serving;
pub mod user;
pub mod weight;

pub use food::FoodService;
pub use goal::GoalService;
pub use ingest::{FoodRecordSource, IngestService, OffFoodRecord};
pub use log::{LogService, FREQUENT_WINDOW_DAYS};
pub use page::{
    resolve_page_params, PageParams, Paginated, DEFAULT_PAGE_LIMIT, MAX_PAGE_LIMIT,
};
pub use serving::ServingService;
pub use user::UserService;
pub use weight::WeightService;
