//! OpenAPI 3.1.0 specification generator and interactive Swagger/Scalar documentation UI.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use crate::app::{RouteSpec, ROUTES};
use crate::authorization::RoutePolicy;

static SPEC_JSON: OnceLock<String> = OnceLock::new();

/// Returns the formatted JSON string of the complete OpenAPI 3.1 specification.
pub fn get_openapi_spec_json() -> &'static str {
    SPEC_JSON.get_or_init(|| {
        let spec = build_openapi_spec();
        serde_json::to_string_pretty(&spec).unwrap_or_else(|_| "{}".to_string())
    })
}

/// Builds the complete OpenAPI 3.1 specification document for all SitePulse routes.
pub fn build_openapi_spec() -> serde_json::Value {
    let mut paths_map: BTreeMap<String, serde_json::Value> = BTreeMap::new();

    for route in ROUTES {
        add_route_to_paths(&mut paths_map, route);
    }

    serde_json::json!({
        "openapi": "3.1.0",
        "info": {
            "title": "SitePulse Residential Management Platform API",
            "version": "1.0.0",
            "description": "High-performance multi-tenant residential and community management API built with Rust, Axum, and PostgreSQL. Complies with statutory Turkish Condominium Law (KMK - Kat Mülkiyeti Kanunu), Personal Data Protection Law (KVKK), virtual IBAN automated reconciliation, and double-entry financial ledger standards.",
            "contact": {
                "name": "SitePulse Engineering",
                "email": "engineering@sitepulse.local"
            },
            "license": {
                "name": "MIT",
                "url": "https://opensource.org/licenses/MIT"
            }
        },
        "servers": [
            {
                "url": "http://localhost:3000",
                "description": "Local Development Server"
            },
            {
                "url": "/",
                "description": "Current Origin"
            }
        ],
        "tags": api_tags(),
        "paths": paths_map,
        "components": {
            "securitySchemes": {
                "bearerAuth": {
                    "type": "http",
                    "scheme": "bearer",
                    "bearerFormat": "JWT",
                    "description": "JWT Access Token obtained from `/api/v1/auth/login`. Pass as `Authorization: Bearer <token>`."
                },
                "supportGrant": {
                    "type": "apiKey",
                    "in": "header",
                    "name": "x-sitepulse-support-grant",
                    "description": "Emergency or privileged support grant session token."
                },
                "idempotencyKey": {
                    "type": "apiKey",
                    "in": "header",
                    "name": "idempotency-key",
                    "description": "Unique UUID to safely retry non-idempotent write operations without duplicate effects."
                },
                "requestId": {
                    "type": "apiKey",
                    "in": "header",
                    "name": "x-request-id",
                    "description": "Distributed tracing and request correlation identifier."
                }
            },
            "schemas": component_schemas()
        }
    })
}

fn add_route_to_paths(paths_map: &mut BTreeMap<String, serde_json::Value>, route: &RouteSpec) {
    let openapi_path = convert_axum_path_to_openapi(route.path);
    let method = route.method.to_ascii_lowercase();

    let path_item = paths_map
        .entry(openapi_path.clone())
        .or_insert_with(|| serde_json::json!({}));

    let parameters = extract_path_parameters(route.path);
    let tag = determine_tag(route.path);
    let summary = generate_summary(route.method, route.path);
    let (security, policy_description) = security_for_policy(route.policy);

    let mut operation = serde_json::json!({
        "tags": [tag],
        "summary": summary,
        "description": format!("{}\n\n**Authorization Policy**: {}", summary, policy_description),
        "parameters": parameters,
        "security": security,
        "responses": standard_responses(&method, route.path, route.policy)
    });

    if method == "post" || method == "put" || method == "patch" {
        if let Some(req_body) = request_body_for_route(route.path) {
            if let Some(op_map) = operation.as_object_mut() {
                op_map.insert("requestBody".to_string(), req_body);
            }
        }
    }

    if let Some(path_obj) = path_item.as_object_mut() {
        path_obj.insert(method, operation);
    }
}

fn convert_axum_path_to_openapi(path: &str) -> String {
    path.split('/')
        .map(|segment| {
            if let Some(param) = segment.strip_prefix(':') {
                format!("{{{}}}", param)
            } else {
                segment.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn extract_path_parameters(path: &str) -> Vec<serde_json::Value> {
    let mut params = Vec::new();
    for segment in path.split('/') {
        if let Some(param) = segment.strip_prefix(':') {
            params.push(serde_json::json!({
                "name": param,
                "in": "path",
                "required": true,
                "description": format!("Identifier parameter `{}`", param),
                "schema": {
                    "type": "string"
                }
            }));
        }
    }
    params
}

fn determine_tag(path: &str) -> &'static str {
    if path.starts_with("/api/v1/auth") {
        "Authentication & Profile"
    } else if path.starts_with("/api/v1/saas") || path.starts_with("/api/v1/portfolio") {
        "SaaS Administration"
    } else if path.starts_with("/api/v1/site-admin") {
        "Site Administration"
    } else if path.starts_with("/api/v1/residents") || path.starts_with("/api/v1/home-residents") {
        "Resident Portal"
    } else if path.starts_with("/api/v1/registration") {
        "Registration & Onboarding"
    } else if path.starts_with("/api/v1/bank")
        || (path.starts_with("/api/v1/units") && path.ends_with("virtual-iban"))
    {
        "Banking & Reconciliation"
    } else if path.starts_with("/api/v1/dues") {
        "Dues & Ledger"
    } else if path.starts_with("/api/v1/payments")
        || path.starts_with("/api/v1/payment-provider")
        || path.starts_with("/api/v1/public/receipts")
    {
        "Payments & Receipts"
    } else if path.starts_with("/api/v1/capital-projects") {
        "Capital Expenditures"
    } else if path.starts_with("/api/v1/operating-budgets")
        || path.starts_with("/api/v1/revaluation-rates")
    {
        "Operating Budgets"
    } else if path.starts_with("/api/v1/kvkk") {
        "KVKK & Privacy"
    } else if path.starts_with("/api/v1/leases") {
        "Leases & KMK 22"
    } else if path.starts_with("/api/v1/notifications") || path.starts_with("/api/v1/dunning") {
        "Notifications & Dunning"
    } else if path.starts_with("/api/v1/resident-requests") {
        "Resident Requests"
    } else if path.starts_with("/api/v1/autopay") {
        "Autopay"
    } else if path.starts_with("/api/v1/accounting") {
        "Accounting & General Ledger"
    } else if path.starts_with("/api/v1/collections")
        || path.starts_with("/api/v1/public/collection-cases")
    {
        "Collections & Legal"
    } else if path.starts_with("/api/v1/heat-share") {
        "Heat-Share Billing"
    } else if path.starts_with("/api/v1/assembly") {
        "Assembly & Governance"
    } else if path.starts_with("/api/v1/analytics") {
        "Analytics"
    } else if path.starts_with("/api/v1/audit") || path.starts_with("/api/v1/support") {
        "Audit & Support"
    } else {
        "System & Diagnostics"
    }
}

fn generate_summary(method: &str, path: &str) -> String {
    let clean_path = path.replace("/api/v1/", "").replace('/', " ");
    let m = method.to_ascii_uppercase();
    format!("{} {}", m, clean_path)
}

fn security_for_policy(policy: RoutePolicy) -> (serde_json::Value, String) {
    match policy {
        RoutePolicy::Public => (
            serde_json::json!([]),
            "Public endpoint (no credentials required).".to_string(),
        ),
        RoutePolicy::SelfOnly => (
            serde_json::json!([{"bearerAuth": []}]),
            "Caller-bound session (SelfOnly). Access limited to the authenticated user's own profile and resources.".to_string(),
        ),
        RoutePolicy::Require(perm) => (
            serde_json::json!([{"bearerAuth": []}]),
            format!("Requires explicit permission `{:?}`.", perm),
        ),
        RoutePolicy::RequireAny(perms) => {
            let names: Vec<String> = perms.iter().map(|p| format!("{:?}", p)).collect();
            (
                serde_json::json!([{"bearerAuth": []}]),
                format!("Requires any of the permissions: `{}`.", names.join(", ")),
            )
        }
        RoutePolicy::Development => (
            serde_json::json!([]),
            "Development / diagnostic utility (disabled in production).".to_string(),
        ),
    }
}

fn standard_responses(method: &str, path: &str, policy: RoutePolicy) -> serde_json::Value {
    let success_code = if method == "post" { "201" } else { "200" };
    let success_desc = match method {
        "post" => "Resource created or action processed successfully.",
        "delete" => "Resource deleted or removed successfully.",
        _ => "Successful request.",
    };

    let schema_ref = success_schema_for_route(path);
    let success_body = match schema_ref {
        Some(name) => serde_json::json!({
            "description": success_desc,
            "content": {
                "application/json": {
                    "schema": {
                        "$ref": format!("#/components/schemas/{}", name)
                    }
                }
            }
        }),
        None => serde_json::json!({
            "description": success_desc,
            "content": {
                "application/json": {
                    "schema": {
                        "type": "object"
                    }
                }
            }
        }),
    };

    let mut responses = serde_json::json!({
        success_code: success_body,
        "400": {
            "description": "Invalid input, syntax, or validation error.",
            "content": {
                "application/json": {
                    "schema": {
                        "$ref": "#/components/schemas/ErrorEnvelope"
                    }
                }
            }
        },
        "500": {
            "description": "Internal server or database error.",
            "content": {
                "application/json": {
                    "schema": {
                        "$ref": "#/components/schemas/ErrorEnvelope"
                    }
                }
            }
        }
    });

    if !matches!(policy, RoutePolicy::Public | RoutePolicy::Development) {
        if let Some(r_map) = responses.as_object_mut() {
            r_map.insert(
                "401".to_string(),
                serde_json::json!({
                    "description": "Authentication required or JWT expired.",
                    "content": {
                        "application/json": {
                            "schema": {
                                "$ref": "#/components/schemas/ErrorEnvelope"
                            }
                        }
                    }
                }),
            );
            r_map.insert(
                "403".to_string(),
                serde_json::json!({
                    "description": "Forbidden - caller lacks the required role or permission, or accesses another tenant's site.",
                    "content": {
                        "application/json": {
                            "schema": {
                                "$ref": "#/components/schemas/ErrorEnvelope"
                            }
                        }
                    }
                }),
            );
        }
    }

    responses
}

fn request_body_for_route(path: &str) -> Option<serde_json::Value> {
    let schema_name = if path == "/api/v1/auth/login" {
        "LoginRequest"
    } else if path == "/api/v1/auth/register" {
        "RegisterRequest"
    } else if path == "/api/v1/auth/change-password" {
        "ChangePasswordRequest"
    } else if path == "/api/v1/saas/sites" {
        "RegisterSiteRequest"
    } else if path == "/api/v1/site-admin/home-owners" {
        "RegisterHomeOwnerRequest"
    } else if path == "/api/v1/site-admin/persons/import" {
        "PersonImportPayload"
    } else if path == "/api/v1/site-admin/persons" {
        "CreatePersonRequest"
    } else if path == "/api/v1/site-admin/persons/:person_id" {
        "UpdatePersonRequest"
    } else if path == "/api/v1/bank/statements/parse" {
        "BankStatementParseRequest"
    } else if path == "/api/v1/payments/record" || path == "/api/v1/payments/record-manual" {
        "RecordPaymentRequest"
    } else if path == "/api/v1/capital-projects" {
        "CreateCapitalProjectRequest"
    } else if path == "/api/v1/operating-budgets" {
        "CreateOperatingBudgetRequest"
    } else {
        return Some(serde_json::json!({
            "required": true,
            "content": {
                "application/json": {
                    "schema": {
                        "type": "object"
                    }
                }
            }
        }));
    };

    Some(serde_json::json!({
        "required": true,
        "content": {
            "application/json": {
                "schema": {
                    "$ref": format!("#/components/schemas/{}", schema_name)
                }
            }
        }
    }))
}

fn success_schema_for_route(path: &str) -> Option<&'static str> {
    if path == "/health" || path == "/api/v1/health" {
        Some("HealthResponse")
    } else if path == "/api/v1/auth/login" {
        Some("LoginResponse")
    } else if path == "/api/v1/auth/me" {
        Some("ProfileResponse")
    } else if path == "/api/v1/saas/sites" {
        Some("SiteList")
    } else if path == "/api/v1/saas/stats" {
        Some("SaasStats")
    } else if path == "/api/v1/residents/:unit_id/dashboard" {
        Some("ResidentDashboard")
    } else if path.ends_with("/virtual-iban") {
        Some("VirtualIbanAllocation")
    } else if path == "/api/v1/bank/statements/parse" {
        Some("BankStatementParseResponse")
    } else if path.starts_with("/api/v1/payments/receipts/") && !path.ends_with("/pdf") {
        Some("PaymentReceipt")
    } else if path == "/api/v1/payments/debt-aging" {
        Some("DebtAgingReport")
    } else {
        None
    }
}

fn api_tags() -> Vec<serde_json::Value> {
    vec![
        serde_json::json!({
            "name": "Authentication & Profile",
            "description": "User registration, password & Google OAuth login, token refresh, and profile inspection."
        }),
        serde_json::json!({
            "name": "SaaS Administration",
            "description": "Multi-tenant platform oversight, site registration, management companies, and portfolio summaries."
        }),
        serde_json::json!({
            "name": "Site Administration",
            "description": "Residential property administration: homeowners, persons directory, house types, blocks, and bank accounts."
        }),
        serde_json::json!({
            "name": "Resident Portal",
            "description": "Resident dashboards, household co-resident management, matching criteria, and virtual IBAN allocations."
        }),
        serde_json::json!({
            "name": "Registration & Onboarding",
            "description": "Public resident self-registration, invitation links, and administrative approval workflows."
        }),
        serde_json::json!({
            "name": "Banking & Reconciliation",
            "description": "Statement parsing (MT940/CSV), Kuveyt Türk API integration, matching feeds, and daily reconciliation runs."
        }),
        serde_json::json!({
            "name": "Dues & Ledger",
            "description": "Monthly dues periods, statutory KMK interest accrual, payment streams, and aged debt tracking."
        }),
        serde_json::json!({
            "name": "Payments & Receipts",
            "description": "Payment ingestion, manual payment recording, advance offset settlements, PDF receipts, and verification."
        }),
        serde_json::json!({
            "name": "Capital Expenditures",
            "description": "Long-term investment projects, installment apportionments, contractor disbursements, and unit share calculations."
        }),
        serde_json::json!({
            "name": "Operating Budgets",
            "description": "Annual operating budgets, interim budgets, assembly approvals, objections, and legal basis enforcement."
        }),
        serde_json::json!({
            "name": "KVKK & Privacy",
            "description": "Turkish Personal Data Protection Law (KVKK) consent tracking, access logs, data retention, and ledger retention policies."
        }),
        serde_json::json!({
            "name": "Leases & KMK 22",
            "description": "Tenant lease contracts, joint-exposure debt tracking, and rent deduction certificates."
        }),
        serde_json::json!({
            "name": "Notifications & Dunning",
            "description": "Multi-channel announcement broadcasts, automated dunning runs, and statutory notice letters."
        }),
        serde_json::json!({
            "name": "Resident Requests",
            "description": "Virman balance transfers between units/debtors, resident billing disputes, and structured payment plans."
        }),
        serde_json::json!({
            "name": "Autopay",
            "description": "Automated recurring payment mandates, card tokenization, and batch charge execution."
        }),
        serde_json::json!({
            "name": "Accounting & General Ledger",
            "description": "Double-entry chart of accounts, vendor management, expenses, journal entries, trial balance, and reserve funds."
        }),
        serde_json::json!({
            "name": "Collections & Legal",
            "description": "Overdue debt collection cases, evidence pack compilation, and lawyer access delegation."
        }),
        serde_json::json!({
            "name": "Heat-Share Billing",
            "description": "Central heating period readings, statutory share apportionment, and occupant billing."
        }),
        serde_json::json!({
            "name": "Assembly & Governance",
            "description": "General assembly meetings, attendance tracking, agenda voting, and official decision books."
        }),
        serde_json::json!({
            "name": "Analytics",
            "description": "Collection performance forecasting, payment channel breakdowns, and delinquency risk analytics."
        }),
        serde_json::json!({
            "name": "Audit & Support",
            "description": "Security audit logs, event export, and privileged support grant workflows."
        }),
        serde_json::json!({
            "name": "System & Diagnostics",
            "description": "Health probes, schema status, and development-only test fixture utilities."
        }),
    ]
}

fn component_schemas() -> serde_json::Value {
    let mut schemas = serde_json::json!({
        "ErrorEnvelope": {
            "type": "object",
            "required": ["error"],
            "properties": {
                "error": {
                    "$ref": "#/components/schemas/ErrorBody"
                }
            }
        },
        "ErrorBody": {
            "type": "object",
            "required": ["code", "message", "trace_id", "timestamp"],
            "properties": {
                "code": {
                    "type": "string",
                    "example": "AUTHENTICATION_REQUIRED"
                },
                "message": {
                    "type": "string",
                    "example": "Authentication token missing or invalid."
                },
                "details": {
                    "type": "object",
                    "nullable": true
                },
                "trace_id": {
                    "type": "string",
                    "example": "req-9c3f4e12-32a1-432a-a92c-cfa123456789"
                },
                "timestamp": {
                    "type": "string",
                    "format": "date-time",
                    "example": "2026-11-10T12:00:00Z"
                }
            }
        },
        "HealthResponse": {
            "type": "object",
            "required": ["status", "service", "version", "mode"],
            "properties": {
                "status": {
                    "type": "string",
                    "example": "ok"
                },
                "service": {
                    "type": "string",
                    "example": "sitepulse-backend"
                },
                "version": {
                    "type": "string",
                    "example": "1.0.0"
                },
                "mode": {
                    "type": "string",
                    "example": "postgresql"
                }
            }
        },
        "LoginRequest": {
            "type": "object",
            "required": ["email", "password"],
            "properties": {
                "email": {
                    "type": "string",
                    "format": "email",
                    "example": "admin@sitepulse.local"
                },
                "password": {
                    "type": "string",
                    "format": "password",
                    "minLength": 10,
                    "example": "SitePulseAdmin2026!"
                }
            }
        },
        "LoginResponse": {
            "type": "object",
            "required": ["access_token", "token_type", "expires_in", "refresh_token", "user"],
            "properties": {
                "access_token": {
                    "type": "string",
                    "description": "JWT Access Token (TTL 10 minutes)"
                },
                "token_type": {
                    "type": "string",
                    "example": "Bearer"
                },
                "expires_in": {
                    "type": "integer",
                    "example": 600
                },
                "refresh_token": {
                    "type": "string",
                    "description": "Opaque Refresh Token"
                },
                "user": {
                    "$ref": "#/components/schemas/ProfileResponse"
                }
            }
        },
        "RegisterRequest": {
            "type": "object",
            "required": ["email", "password", "name", "site_id"],
            "properties": {
                "email": {
                    "type": "string",
                    "format": "email"
                },
                "password": {
                    "type": "string",
                    "format": "password",
                    "minLength": 10
                },
                "name": {
                    "type": "string",
                    "example": "Ahmet Yılmaz"
                },
                "phone": {
                    "type": "string",
                    "example": "+905321234567"
                },
                "site_id": {
                    "type": "string",
                    "example": "site-1"
                }
            }
        },
        "ChangePasswordRequest": {
            "type": "object",
            "required": ["current_password", "new_password"],
            "properties": {
                "current_password": {
                    "type": "string",
                    "format": "password"
                },
                "new_password": {
                    "type": "string",
                    "format": "password",
                    "minLength": 10
                }
            }
        },
        "ProfileResponse": {
            "type": "object",
            "required": ["id", "email", "name", "role", "site_id"],
            "properties": {
                "id": {
                    "type": "string"
                },
                "email": {
                    "type": "string",
                    "format": "email"
                },
                "name": {
                    "type": "string"
                },
                "role": {
                    "type": "string",
                    "enum": ["SAAS_ADMIN", "SITE_MANAGER", "HOME_OWNER", "HOME_RESIDENT", "AUDITOR"]
                },
                "site_id": {
                    "type": "string"
                },
                "unit_id": {
                    "type": "string",
                    "nullable": true
                }
            }
        },
        "RegisterSiteRequest": {
            "type": "object",
            "required": ["name", "code"],
            "properties": {
                "name": {
                    "type": "string",
                    "example": "Gökkuşağı Konutları"
                },
                "code": {
                    "type": "string",
                    "example": "GOKKUSAGI"
                },
                "address": {
                    "type": "string",
                    "example": "Kadıköy, İstanbul"
                },
                "iban": {
                    "type": "string",
                    "example": "TR330006100511123456789012"
                }
            }
        },
        "RegisterHomeOwnerRequest": {
            "type": "object",
            "required": ["site_id", "unit_id", "name", "email"],
            "properties": {
                "site_id": {
                    "type": "string"
                },
                "unit_id": {
                    "type": "string"
                },
                "name": {
                    "type": "string"
                },
                "email": {
                    "type": "string",
                    "format": "email"
                },
                "phone": {
                    "type": "string"
                },
                "land_share": {
                    "type": "string",
                    "example": "10/100"
                }
            }
        },
        "PersonImportPayload": {
            "type": "object",
            "required": ["site_id", "rows"],
            "properties": {
                "site_id": {
                    "type": "string"
                },
                "dry_run": {
                    "type": "boolean",
                    "default": false
                },
                "rows": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["full_name"],
                        "properties": {
                            "full_name": { "type": "string" },
                            "email": { "type": "string" },
                            "phone": { "type": "string" },
                            "block": { "type": "string" },
                            "unit_number": { "type": "string" },
                            "role": { "type": "string" }
                        }
                    }
                }
            }
        },
        "ResidentDashboard": {
            "type": "object",
            "required": ["unit_id", "balance", "open_dues"],
            "properties": {
                "unit_id": { "type": "string" },
                "unit_label": { "type": "string" },
                "balance": { "type": "string", "example": "-450.00" },
                "advance_balance": { "type": "string", "example": "0.00" },
                "virtual_iban": { "type": "string" },
                "open_dues": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "due_id": { "type": "string" },
                            "period": { "type": "string" },
                            "amount": { "type": "string" },
                            "penalty": { "type": "string" },
                            "due_date": { "type": "string", "format": "date" }
                        }
                    }
                }
            }
        },
        "VirtualIbanAllocation": {
            "type": "object",
            "required": ["unit_id", "virtual_iban", "status"],
            "properties": {
                "unit_id": { "type": "string" },
                "virtual_iban": { "type": "string", "example": "TR120020500000000001000042" },
                "bank_name": { "type": "string", "example": "Kuveyt Türk" },
                "status": { "type": "string", "example": "ACTIVE" }
            }
        },
        "BankStatementParseRequest": {
            "type": "object",
            "required": ["site_id", "content", "format"],
            "properties": {
                "site_id": { "type": "string" },
                "format": { "type": "string", "enum": ["MT940", "CSV", "EXCEL"] },
                "content": { "type": "string" }
            }
        },
        "BankStatementParseResponse": {
            "type": "object",
            "required": ["accepted_count", "skipped_count", "transactions"],
            "properties": {
                "accepted_count": { "type": "integer" },
                "skipped_count": { "type": "integer" },
                "skipped_reasons": {
                    "type": "array",
                    "items": { "type": "string" }
                },
                "transactions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "date": { "type": "string", "format": "date" },
                            "amount": { "type": "string" },
                            "sender_name": { "type": "string" },
                            "sender_iban": { "type": "string" },
                            "narrative": { "type": "string" }
                        }
                    }
                }
            }
        },
        "RecordPaymentRequest": {
            "type": "object",
            "required": ["site_id", "unit_id", "amount", "payment_date"],
            "properties": {
                "site_id": { "type": "string" },
                "unit_id": { "type": "string" },
                "amount": { "type": "string", "example": "750.00" },
                "payment_date": { "type": "string", "format": "date" },
                "payment_channel": { "type": "string", "enum": ["BANK_TRANSFER", "CARD", "CASH", "VIRTUAL_IBAN"] },
                "channel_reference": { "type": "string" },
                "notes": { "type": "string" }
            }
        },
        "PaymentReceipt": {
            "type": "object",
            "required": ["receipt_id", "receipt_number", "site_id", "unit_id", "amount", "verification_token"],
            "properties": {
                "receipt_id": { "type": "string" },
                "receipt_number": { "type": "string", "example": "RCP-2026-0042" },
                "site_id": { "type": "string" },
                "unit_id": { "type": "string" },
                "amount": { "type": "string" },
                "payment_date": { "type": "string", "format": "date" },
                "fingerprint": { "type": "string" },
                "verification_token": { "type": "string" },
                "pdf_url": { "type": "string" }
            }
        },
        "DebtAgingReport": {
            "type": "object",
            "required": ["site_id", "total_outstanding", "buckets"],
            "properties": {
                "site_id": { "type": "string" },
                "as_of_date": { "type": "string", "format": "date" },
                "total_outstanding": { "type": "string" },
                "buckets": {
                    "type": "object",
                    "properties": {
                        "current": { "type": "string" },
                        "days_30": { "type": "string" },
                        "days_60": { "type": "string" },
                        "days_90_plus": { "type": "string" }
                    }
                }
            }
        },
        "CreateCapitalProjectRequest": {
            "type": "object",
            "required": ["site_id", "title", "total_budget", "apportionment_method"],
            "properties": {
                "site_id": { "type": "string" },
                "title": { "type": "string", "example": "Asansör Revizyonu ve Bakımı" },
                "description": { "type": "string" },
                "total_budget": { "type": "string", "example": "120000.00" },
                "apportionment_method": { "type": "string", "enum": ["LAND_SHARE", "EQUAL", "CUSTOM"] }
            }
        },
        "CreateOperatingBudgetRequest": {
            "type": "object",
            "required": ["site_id", "year", "title", "total_amount"],
            "properties": {
                "site_id": { "type": "string" },
                "year": { "type": "integer", "example": 2026 },
                "title": { "type": "string", "example": "2026 Yıllık İşletme Projesi" },
                "total_amount": { "type": "string", "example": "480000.00" }
            }
        },
        "SaasStats": {
            "type": "object",
            "required": ["site_count", "unit_count", "resident_count", "active_session_count"],
            "properties": {
                "site_count": { "type": "integer" },
                "unit_count": { "type": "integer" },
                "resident_count": { "type": "integer" },
                "active_session_count": { "type": "integer" }
            }
        },
        "SiteList": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "name": { "type": "string" },
                    "code": { "type": "string" }
                }
            }
        }
    });

    let person_schemas = utoipa::openapi::schema::ComponentsBuilder::new()
        .schema_from::<crate::models::PersonRef>()
        .schema_from::<crate::models::NewPerson>()
        .schema_from::<crate::models::PersonRole>()
        .schema_from::<crate::models::PersonLoginState>()
        .schema_from::<crate::models::PersonCard>()
        .schema_from::<crate::models::PersonEligibility>()
        .schema_from::<crate::models::PersonSearchItem>()
        .schema_from::<crate::models::PersonSearchContext>()
        .schema_from::<crate::models::PersonSearchQuery>()
        .schema_from::<crate::models::PersonSearchResponse>()
        .schema_from::<crate::models::CreatePersonRequest>()
        .schema_from::<crate::models::UpdatePersonRequest>()
        .schema_from::<crate::models::PersonUnitRelation>()
        .schema_from::<crate::models::PersonCardResponse>()
        .schema_from::<crate::models::PersonMutationResponse>()
        .build()
        .schemas;

    if let (Some(schema_map), Ok(generated_schemas)) = (
        schemas.as_object_mut(),
        serde_json::to_value(person_schemas),
    ) {
        if let Some(generated_schemas) = generated_schemas.as_object() {
            schema_map.extend(generated_schemas.clone());
        }
    }

    schemas
}

/// Returns the self-contained HTML page rendering interactive Swagger UI.
pub fn swagger_ui_html() -> &'static str {
    r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>SitePulse API Documentation - Swagger UI</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.18.2/swagger-ui.css" integrity="sha384-rcbEi6xgdPk0iWkAQzT2F3FeBJXdG+ydrawGlfHAFIZG7wU6aKbQaRewysYpmrlW" crossorigin="anonymous" />
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🏢</text></svg>">
  <style>
    body {
      margin: 0;
      background: #fafafa;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }
    .topbar-sitepulse {
      background: #0f172a;
      color: white;
      padding: 12px 24px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      border-bottom: 3px solid #0284c7;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .topbar-sitepulse h1 {
      margin: 0;
      font-size: 1.2rem;
      font-weight: 600;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .topbar-sitepulse .badge {
      background: #0284c7;
      color: white;
      font-size: 0.75rem;
      padding: 2px 8px;
      border-radius: 9999px;
      font-weight: 500;
    }
    .topbar-links a {
      color: #cbd5e1;
      text-decoration: none;
      margin-left: 18px;
      font-size: 0.875rem;
      font-weight: 500;
      transition: color 0.15s;
    }
    .topbar-links a:hover {
      color: #38bdf8;
    }
    .swagger-ui .topbar {
      display: none;
    }
    .swagger-ui .info {
      margin: 25px 0;
    }
  </style>
</head>
<body>
  <div class="topbar-sitepulse">
    <h1>
      <span>🏢 SitePulse Residential API</span>
      <span class="badge">OpenAPI 3.1</span>
    </h1>
    <div class="topbar-links">
      <a href="/api-docs/openapi.json" target="_blank">Raw JSON</a>
      <a href="/scalar">Scalar Reference</a>
      <a href="/health" target="_blank">Health Status</a>
    </div>
  </div>
  <div id="swagger-ui"></div>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.18.2/swagger-ui-bundle.js" integrity="sha384-NXtFPpN61oWCuN4D42K6Zd5Rt2+uxeIT36R7kpXBuY9tLnZorzrJ4ykpqwJfgjpZ" crossorigin="anonymous"></script>
  <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.18.2/swagger-ui-standalone-preset.js" integrity="sha384-qr68CD0cvHa88PmVu7e1a58Ego4qvKtcvcLdS2a8Mo5zILI01gyIV9jVwJk7X2NU" crossorigin="anonymous"></script>
  <script>
    window.onload = function() {
      SwaggerUIBundle({
        url: "/api-docs/openapi.json",
        dom_id: '#swagger-ui',
        deepLinking: true,
        presets: [
          SwaggerUIBundle.presets.apis,
          SwaggerUIStandalonePreset
        ],
        plugins: [
          SwaggerUIBundle.plugins.DownloadUrl
        ],
        layout: "StandaloneLayout",
        persistAuthorization: true,
        displayRequestDuration: true,
        filter: true,
        tryItOutEnabled: true
      });
    };
  </script>
</body>
</html>
"#
}

/// Returns the self-contained HTML page rendering modern Scalar API reference UI.
pub fn scalar_ui_html() -> &'static str {
    r#"<!doctype html>
<html lang="en">
  <head>
    <title>SitePulse API Reference</title>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🏢</text></svg>">
    <style>
      body { margin: 0; padding: 0; }
    </style>
  </head>
  <body>
    <script
      id="api-reference"
      data-url="/api-docs/openapi.json"
      data-configuration='{"theme": "kepler", "showSidebar": true}'
      src="https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.78.1" integrity="sha384-uxI3m9J8tBk0lNYsd1UTuIxSyitPtjvVvQyFEvql1RH5lVGxkFt6wEQtjGTDBw13" crossorigin="anonymous"></script>
  </body>
</html>
"#
}

#[cfg(test)]
mod tests {
    use super::build_openapi_spec;

    #[test]
    fn person_api_schemas_are_registered_in_openapi_components() {
        let spec = build_openapi_spec();
        for schema_name in [
            "PersonRef",
            "NewPerson",
            "PersonRole",
            "PersonLoginState",
            "PersonCard",
            "PersonEligibility",
            "PersonSearchItem",
            "PersonSearchContext",
            "PersonSearchQuery",
            "PersonSearchResponse",
            "CreatePersonRequest",
            "UpdatePersonRequest",
            "PersonUnitRelation",
            "PersonCardResponse",
            "PersonMutationResponse",
        ] {
            assert!(
                spec.pointer(&format!("/components/schemas/{schema_name}"))
                    .is_some(),
                "missing OpenAPI component schema {schema_name}"
            );
        }
    }
}
