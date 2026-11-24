use sitepulse_backend::{
    auth,
    models::{AuthProvider, Role, User},
    security,
    state::AppState,
};

/// Real sessions for HTTP tests. Credentials without a stored session are invalid.
pub async fn token(
    state: &AppState,
    id: &str,
    role: Role,
    site: &str,
    unit: Option<&str>,
) -> String {
    let mut inner = state.inner.write().await;
    let user = if let Some(user) = inner.users.iter_mut().find(|u| u.id == id) {
        user.role = role;
        user.site_id = if role == Role::SaasAdmin {
            String::new()
        } else {
            site.to_string()
        };
        user.must_change_password = false;
        user.clone()
    } else {
        let user = User {
            id: id.to_string(),
            site_id: if role == Role::SaasAdmin {
                String::new()
            } else {
                site.to_string()
            },
            full_name: "Security test user".to_string(),
            email: format!("{}@test.example", id),
            phone: String::new(),
            password_hash: None,
            role,
            must_change_password: false,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: chrono::Utc::now(),
            person_id: None,
        };
        inner.users.push(user.clone());
        user
    };
    if let Some(id) = unit {
        if let Some(u) = inner.units.iter_mut().find(|u| auth::same_id(&u.id, id)) {
            u.owner_user_id = Some(user.id.clone());
        }
    }
    drop(inner);
    security::create(state, &user, unit)
        .await
        .expect("session stored")
        .access_token
}
