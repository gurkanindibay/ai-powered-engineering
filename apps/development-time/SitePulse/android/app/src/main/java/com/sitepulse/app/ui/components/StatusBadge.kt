package com.sitepulse.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

enum class DuesStatusType {
    PAID, OVERDUE, PENDING
}

/**
 * High-contrast accessible status pill badge.
 */
@Composable
fun StatusBadge(
    status: DuesStatusType,
    modifier: Modifier = Modifier
) {
    val (bgColor, textColor, label) = when (status) {
        DuesStatusType.PAID -> Triple(Color(0xFFDCFCE7), Color(0xFF15803D), "ÖDENDİ")
        DuesStatusType.OVERDUE -> Triple(Color(0xFFFEE2E2), Color(0xFFB91C1C), "GECİKTİ")
        DuesStatusType.PENDING -> Triple(Color(0xFFFEF3C7), Color(0xFFB45309), "BEKLEMEDE")
    }

    Text(
        text = label,
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = textColor,
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(bgColor)
            .padding(horizontal = 8.dp, vertical = 4.dp)
    )
}
