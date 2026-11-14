//! Request and response contracts for the unified person API.

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

/// A reference to an existing person card or a draft card to create atomically.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PersonRef {
    /// Link an existing person card.
    Existing { person_id: i64 },
    /// Create a new card and use it for the requested action.
    New {
        card: NewPerson,
        #[serde(default)]
        confirm_distinct: bool,
    },
}

/// Person fields accepted when creating a role-free card.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct NewPerson {
    /// The person's display name.
    pub full_name: String,
    /// Contact phone number, if known.
    #[serde(default)]
    pub phone: Option<String>,
    /// Contact email, if known.
    #[serde(default)]
    pub email: Option<String>,
    /// National identity number, if known.
    #[serde(default)]
    pub national_id: Option<String>,
}

/// Roles currently associated with a person card.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PersonRole {
    Owner,
    OccupantOwner,
    Tenant,
    Member,
    PrimaryContact,
}

/// Login state visible to a site manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PersonLoginState {
    None,
    Pending,
    Active,
}

/// A concise person card for directory and picker results.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonCard {
    pub person_id: i64,
    pub full_name: String,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub masked_national_id: Option<String>,
    pub roles: Vec<PersonRole>,
    pub unit_labels: Vec<String>,
    pub login: PersonLoginState,
    pub version: i64,
    pub allowed_actions: Vec<String>,
}

/// Whether a person can be used for a requested role in a unit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonEligibility {
    pub allowed: bool,
    /// Stable reason code when the person is not eligible.
    pub code: Option<String>,
}

/// A card result plus its role eligibility for the supplied search context.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonSearchItem {
    pub card: PersonCard,
    pub eligibility: Option<PersonEligibility>,
}

/// Supported contexts for picker eligibility checks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum PersonSearchContext {
    Owner,
    Tenant,
    Household,
    PrimaryContact,
    Registration,
}

/// Query parameters for a scoped person picker search.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonSearchQuery {
    pub q: Option<String>,
    pub context: Option<PersonSearchContext>,
    pub unit_id: Option<String>,
    pub limit: Option<i64>,
}

/// Paged scoped person search results.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonSearchResponse {
    pub items: Vec<PersonSearchItem>,
    pub total: i64,
    pub page: i64,
    pub page_size: i64,
}

/// Create a role-free person card.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct CreatePersonRequest {
    pub card: NewPerson,
    #[serde(default)]
    pub confirm_distinct: bool,
}

/// Update contact details using optimistic version checking.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct UpdatePersonRequest {
    pub full_name: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    pub version: i64,
}

/// One historical or active role held by the person in a unit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonUnitRelation {
    pub unit_id: String,
    pub unit_label: String,
    pub relation: PersonRole,
    pub start_date: Option<NaiveDate>,
    pub end_date: Option<NaiveDate>,
    pub active: bool,
}

/// Full person card response, including the person's unit history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonCardResponse {
    pub card: PersonCard,
    pub units: Vec<PersonUnitRelation>,
}

/// Result returned after creating or editing a person card.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct PersonMutationResponse {
    pub card: PersonCard,
}
