package com.sitepulse.app.domain.model

import java.math.BigDecimal

/**
 * Summary of complex-wide dues collection for Site Manager dashboard.
 * Strict BigDecimal usage for financial fields per Constitution.
 */
data class ComplexCollectionSummary(
    val siteName: String = "Begonya Sitesi",
    val period: String = "Eylül 2026",
    val totalExpected: BigDecimal = BigDecimal("120000.00"),
    val totalCollected: BigDecimal = BigDecimal("96000.00"),
    val collectionRatePercent: Int = 80,
    val paidUnitsCount: Int = 18,
    val overdueUnitsCount: Int = 6,
    val totalUnitsCount: Int = 24
)

/**
 * Flat payment status for manager flat ledger.
 */
data class FlatPaymentStatus(
    val id: String,
    val block: String,
    val unitNo: Int,
    val residentName: String,
    val amountDue: BigDecimal,
    val daysOverdue: Int = 0,
    val isPaid: Boolean = false,
    val paidDateStr: String? = null
) {
    val flatDesc: String
        get() = "$block Blok D:$unitNo"

    val fullDesc: String
        get() = "$flatDesc - $residentName"
}

/**
 * Announcement entity for broadcasting complex-wide notifications.
 */
data class SiteAnnouncement(
    val id: String,
    val title: String,
    val category: String, // e.g. "Acil", "Genel", "Aidat"
    val body: String,
    val author: String = "Site Yönetim Kurulu",
    val timestamp: String = "Bugün, 10:00"
)

/**
 * Direct message / overdue reminder sent to a specific flat.
 */
data class FlatDirectMessage(
    val id: String,
    val targetFlatDesc: String,
    val messageType: String, // e.g. "Aidat Gecikme Hatırlatması", "Özel Mesaj"
    val content: String,
    val timestamp: String = "Bugün"
)
