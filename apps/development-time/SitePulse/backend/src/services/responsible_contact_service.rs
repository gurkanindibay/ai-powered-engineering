//! Select a communication contact without editing anybody's identity or occupancy.
use crate::models::{
    HomeOwnerResponse, PrimaryResponsibleContact, SelectResponsibleContactRequest,
};
use crate::state::AppState;

#[derive(Debug, thiserror::Error)]
pub enum ResponsibleContactError {
    #[error("Unit not found.")]
    NotFound,
    #[error("Select an existing owner, tenant or household member of this unit.")]
    InvalidSelection,
    #[error("The contact could not be saved. Please retry.")]
    Storage,
}

pub fn resolve_contact(
    unit: &HomeOwnerResponse,
    request: &SelectResponsibleContactRequest,
) -> Result<PrimaryResponsibleContact, ResponsibleContactError> {
    let (name, phone, email, member_id) = match request.role.as_str() {
        "OWNER" if !unit.owner_full_name.is_empty() => (
            unit.owner_full_name.clone(),
            unit.phone.clone(),
            unit.email.clone(),
            None,
        ),
        "TENANT"
            if unit
                .tenant_full_name
                .as_ref()
                .is_some_and(|name| !name.is_empty()) =>
        {
            (
                unit.tenant_full_name.clone().unwrap_or_default(),
                unit.tenant_phone.clone().unwrap_or_default(),
                unit.tenant_email.clone().unwrap_or_default(),
                None,
            )
        }
        "RESIDENT" => {
            let members: Vec<_> = unit
                .household_residents
                .iter()
                .filter(|member| {
                    if let Some(id) = request.member_id.as_deref() {
                        member.resident_id == id
                    } else {
                        member.full_name == request.resident_name
                    }
                })
                .collect();
            let [member] = members.as_slice() else {
                return Err(ResponsibleContactError::InvalidSelection);
            };
            (
                member.full_name.clone(),
                member.phone.clone(),
                member.email.clone(),
                Some(member.resident_id.clone()),
            )
        }
        _ => return Err(ResponsibleContactError::InvalidSelection),
    };
    Ok(PrimaryResponsibleContact {
        primary_responsible_name: name,
        primary_responsible_role: request.role.clone(),
        primary_responsible_phone: phone,
        primary_responsible_email: email,
        primary_responsible_member_id: member_id,
    })
}

pub async fn select(
    state: AppState,
    site_id: &str,
    unit_id: &str,
    request: SelectResponsibleContactRequest,
) -> Result<PrimaryResponsibleContact, ResponsibleContactError> {
    let owners = super::SiteAdminService::new(state.clone())
        .get_home_owners_for_site(site_id)
        .await;
    let unit = owners
        .iter()
        .find(|unit| crate::auth::same_id(&unit.unit_id, unit_id))
        .ok_or(ResponsibleContactError::NotFound)?;
    let contact = resolve_contact(unit, &request)?;
    if let Some(pool) = &state.pool {
        let site = crate::db::parse_id_to_i64(site_id).ok_or(ResponsibleContactError::NotFound)?;
        let id =
            crate::db::parse_id_to_i64(&unit.unit_id).ok_or(ResponsibleContactError::NotFound)?;
        let saved = crate::db::responsible_contact_repository::save(pool, site, id, &contact)
            .await
            .map_err(|error| {
                tracing::error!(%error, site_id, unit_id, "Could not persist responsible contact");
                ResponsibleContactError::Storage
            })?;
        if !saved {
            return Err(ResponsibleContactError::NotFound);
        }
    } else {
        state
            .inner
            .write()
            .await
            .unit_primary_contacts
            .insert(unit.unit_id.clone(), contact.clone());
    }
    Ok(contact)
}
