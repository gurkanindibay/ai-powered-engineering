package com.sitepulse.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * EPIC-07: Daireye Özel Sanal IBAN Kartı (Havale / EFT Otomatik Mutabakat)
 */
@Composable
fun VirtualIbanCard(
    iban: String = "TR12 0006 2000 0000 0000 0014",
    bankName: String = "Garanti BBVA Kurumsal",
    recipient: String = "Begonya Sitesi Yönetimi",
    unitLabel: String = "A Blok D:14",
    onCopied: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val clipboardManager = LocalClipboardManager.current

    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(
            containerColor = Color(0xFF131B2E)
        ),
        border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF1E293B))
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = "🏦",
                        fontSize = 16.sp
                    )
                    Text(
                        text = "DAİREYE ÖZEL SANAL IBAN",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF94A3B8),
                        letterSpacing = 0.5.sp
                    )
                }

                Surface(
                    color = Color(0xFF0284C7).copy(alpha = 0.15f),
                    shape = RoundedCornerShape(6.dp)
                ) {
                    Text(
                        text = "%100 Otomatik Eşleşme",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF38BDF8),
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFF0B0F19))
                    .border(1.dp, Color(0xFF1F2937), RoundedCornerShape(12.dp))
                    .padding(12.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "$unitLabel RESMİ SANAL HESABI",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color(0xFF64748B)
                        )
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(
                            text = iban,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace,
                            color = Color(0xFF60A5FA)
                        )
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(
                            text = "$bankName • Alıcı: $recipient",
                            fontSize = 10.sp,
                            color = Color(0xFF94A3B8)
                        )
                    }

                    Surface(
                        color = Color(0xFF1E293B),
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.clickable {
                            clipboardManager.setText(AnnotatedString(iban.replace(" ", "")))
                            onCopied?.invoke()
                        }
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.ContentCopy,
                                contentDescription = "Kopyala",
                                tint = Color(0xFF38BDF8),
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = "Kopyala",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = Color(0xFF38BDF8)
                            )
                        }
                    }
                }
            }

            Text(
                text = "💡 Açıklama yazmasanız dahi ödemeniz 2 saniyede dairenize otomatik işlenir.",
                fontSize = 11.sp,
                color = Color(0xFF64748B),
                lineHeight = 15.sp
            )
        }
    }
}
