//! SitePulse backend library.
#![deny(unused_must_use)]

pub mod app;
pub mod audit;
pub mod auth;
pub mod authorization;
pub mod db;
pub mod domain;
pub mod error;
pub mod finance_book;
pub mod handlers;
pub mod migrations;
pub mod models;
pub mod scheduler;
pub mod security;
pub mod services;
pub mod state;
pub mod tenancy;

pub use error::{AppError, AppResult, ErrorBody, ErrorEnvelope};
