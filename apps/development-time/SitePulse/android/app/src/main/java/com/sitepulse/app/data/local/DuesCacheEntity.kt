package com.sitepulse.app.data.local

import java.math.BigDecimal
import java.time.LocalDateTime

/**
 * Entity representing cached resident dues statement in local SQLite/Room storage.
 */
data class DuesCacheEntity(
    val unitId: String,
    val unitNumber: String,
    val residentName: String,
    val principalAmount: BigDecimal,
    val delayPenaltyAmount: BigDecimal,
    val totalAmount: BigDecimal,
    val daysOverdue: Int,
    val isOverdue: Boolean,
    val cachedAt: LocalDateTime = LocalDateTime.now(),
    val isSyncedWithServer: Boolean = true
)
