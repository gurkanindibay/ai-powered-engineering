package com.sitepulse.app.domain.model

import java.math.BigDecimal

data class TenantSiteItem(
    val id: String,
    val name: String,
    val city: String,
    val address: String,
    val status: String = "ACTIVE",
    val planType: String = "STANDARD",
    val totalUnits: Int = 24,
    val monthlyCollectionVolume: BigDecimal = BigDecimal("96000.00"),
    val adminName: String,
    val adminEmail: String,
    val adminPhone: String
)

data class ProvisionedSiteCredentials(
    val siteId: String,
    val siteName: String,
    val adminName: String,
    val adminEmail: String,
    val temporaryPassword: String,
    val planType: String = "STANDARD"
)
