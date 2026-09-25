package com.sitepulse.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sitepulse.app.domain.model.Daire
import com.sitepulse.app.domain.model.Money
import java.math.BigDecimal

/**
 * Modern Material 3 Hero Balance Card displaying resident dues and statutory delay fee breakdown.
 */
@Composable
fun HeroBalanceCard(
    unit: Daire,
    totalDues: Money,
    delayPenalty: Money,
    isOverdue: Boolean,
    overdueDays: Int,
    isOffline: Boolean = false,
    onPayClick: () -> Unit,
    onReceiptClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .padding(16.dp),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent),
        elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
    ) {
        Box(
            modifier = Modifier
                .background(
                    Brush.linearGradient(
                        colors = listOf(Color(0xFF1E3A8A), Color(0xFF2563EB))
                    )
                )
                .padding(20.dp)
        ) {
            Column {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "${unit.blok.ad} - Daire ${unit.kapiNo}",
                        color = Color(0xFF93C5FD),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium
                    )

                    if (isOffline) {
                        Text(
                            text = "Önbellek ⚡",
                            color = Color(0xFFFDE68A),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier
                                .clip(RoundedCornerShape(4.dp))
                                .background(Color(0x33000000))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        )
                    } else if (isOverdue) {
                        Text(
                            text = "$overdueDays Gün Gecikme",
                            color = Color(0xFFFECACA),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier
                                .clip(RoundedCornerShape(4.dp))
                                .background(Color(0x33DC2626))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        )
                    }
                }

                Spacer(modifier = Modifier.height(10.dp))

                Text(
                    text = "Toplam Ödenecek Tutar",
                    color = Color(0xFFBFDBFE),
                    fontSize = 13.sp
                )

                Text(
                    text = totalDues.format(),
                    color = Color.White,
                    fontSize = 32.sp,
                    fontWeight = FontWeight.ExtraBold
                )

                Spacer(modifier = Modifier.height(12.dp))

                // KMK Statutory Delay Fee Breakdown Box
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color(0x22FFFFFF))
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "KMK Gecikme Tazminatı:",
                            color = Color(0xFFE2E8F0),
                            fontSize = 12.sp
                        )
                        Text(
                            text = "+${delayPenalty.format()}",
                            color = Color(0xFFFCA5A5),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }

                Spacer(modifier = Modifier.height(16.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Button(
                        onClick = onPayClick,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFF10B981),
                            contentColor = Color.White
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier
                            .weight(1f)
                            .height(48.dp)
                    ) {
                        Text("Aidat Öde", fontWeight = FontWeight.Bold)
                    }

                    OutlinedButton(
                        onClick = onReceiptClick,
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = Color.White
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier
                            .weight(1f)
                            .height(48.dp)
                    ) {
                        Text("Dekontlar", fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}
