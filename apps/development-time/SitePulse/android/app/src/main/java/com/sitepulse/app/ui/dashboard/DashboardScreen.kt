package com.sitepulse.app.ui.dashboard

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ReceiptLong
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sitepulse.app.domain.model.ComplexCollectionSummary
import com.sitepulse.app.domain.model.FlatPaymentStatus
import com.sitepulse.app.domain.model.UserRole
import com.sitepulse.app.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    viewModel: DashboardViewModel,
    isDarkTheme: Boolean = false,
    onThemeToggle: (Boolean) -> Unit = {},
    onPayClick: () -> Unit = {},
    onActionClick: (String) -> Unit = {}
) {
    val state by viewModel.uiState.collectAsState()
    val userRole by viewModel.userRole.collectAsState()
    val collectionSummary by viewModel.collectionSummary.collectAsState()
    val flatsList by viewModel.flatsList.collectAsState()
    val flatFilter by viewModel.flatFilter.collectAsState()

    var selectedTab by remember { mutableStateOf(0) }
    var showProfileSheet by remember { mutableStateOf(false) }
    var showAnnouncementSheet by remember { mutableStateOf(false) }
    var showDirectMessageSheet by remember { mutableStateOf(false) }
    var directMessageTarget by remember { mutableStateOf("A Blok D:14 - Ahmet Yılmaz") }
    var directMessageAmount by remember { mutableStateOf("₺1.423,33") }

    Scaffold(
        containerColor = SitePulseTheme.colors.background,
        bottomBar = {
            PaparaBottomNav(
                selectedTab = selectedTab,
                onTabSelect = { tabIndex, tabName ->
                    selectedTab = tabIndex
                    when (tabName) {
                        "Profil" -> showProfileSheet = true
                        "Duyurular" -> {
                            if (userRole == UserRole.SITE_MANAGER) {
                                showAnnouncementSheet = true
                            } else {
                                onActionClick("Duyurular")
                            }
                        }
                        else -> onActionClick(tabName)
                    }
                }
            )
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            when (val s = state) {
                is DashboardUiState.Loading -> {
                    CircularProgressIndicator(
                        color = SitePulseTheme.colors.navActive,
                        modifier = Modifier.align(Alignment.Center)
                    )
                }
                is DashboardUiState.Error -> {
                    Text(
                        text = s.message,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.align(Alignment.Center)
                    )
                }
                is DashboardUiState.Success -> {
                    if (userRole == UserRole.RESIDENT) {
                        // Resident Dashboard (Release 1 Scope: 4 core actions, Aidat tracking)
                        ResidentDashboardContent(
                            state = s,
                            onPayClick = onPayClick,
                            onActionClick = onActionClick,
                            onProfileClick = { showProfileSheet = true },
                            onMessagesClick = { onActionClick("Mesajlaşma") }
                        )
                    } else {
                        // Site Manager Dashboard
                        ManagerDashboardContent(
                            collectionSummary = collectionSummary,
                            flats = flatsList,
                            activeFilter = flatFilter,
                            onFilterSelect = { viewModel.setFlatFilter(it) },
                            onOpenAnnouncement = { showAnnouncementSheet = true },
                            onOpenDirectMessage = { flatDesc, amount ->
                                directMessageTarget = flatDesc
                                directMessageAmount = amount
                                showDirectMessageSheet = true
                            },
                            onProfileClick = { showProfileSheet = true },
                            onActionClick = onActionClick
                        )
                    }

                    // Modals
                    if (showProfileSheet) {
                        ProfileModalBottomSheet(
                            residentName = if (userRole == UserRole.RESIDENT) s.aktifDaire.malikAdi else "Mehmet Demir (Yönetici)",
                            apartmentInfo = if (userRole == UserRole.RESIDENT) "${s.aktifDaire.siteAdi} • ${s.aktifDaire.blok} Blok D:${s.aktifDaire.daireNo}" else "Begonya Sitesi Yönetim Kurulu Başkanı",
                            currentRole = userRole,
                            onRoleChange = { viewModel.switchRole(it) },
                            isDarkTheme = isDarkTheme,
                            onThemeToggle = onThemeToggle,
                            onDismiss = { showProfileSheet = false }
                        )
                    }

                    if (showAnnouncementSheet) {
                        AnnouncementModalBottomSheet(
                            onPublish = { title, category, body ->
                                viewModel.publishAnnouncement(title, category, body)
                                onActionClick("Duyuru Yayınlandı: $title")
                                showAnnouncementSheet = false
                            },
                            onDismiss = { showAnnouncementSheet = false }
                        )
                    }

                    if (showDirectMessageSheet) {
                        DirectMessageModalBottomSheet(
                            targetFlat = directMessageTarget,
                            amount = directMessageAmount,
                            onSend = { target, type, body ->
                                viewModel.sendDirectMessage(target, type, body)
                                onActionClick("Bildirim İletildi: $target")
                                showDirectMessageSheet = false
                            },
                            onDismiss = { showDirectMessageSheet = false }
                        )
                    }
                }
            }
        }
    }
}

/**
 * Resident Dashboard Content (Release 1: 4 Core Actions, Single Currency Aidat Tracking)
 */
@Composable
private fun ResidentDashboardContent(
    state: DashboardUiState.Success,
    onPayClick: () -> Unit,
    onActionClick: (String) -> Unit,
    onProfileClick: () -> Unit,
    onMessagesClick: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // 1. Top Bar
        PaparaTopBar(
            name = state.aktifDaire.malikAdi,
            subInfo = "${state.aktifDaire.siteAdi} • ${state.aktifDaire.blok} Blok D:${state.aktifDaire.daireNo}",
            initials = "AY",
            onMenuClick = { onActionClick("Menü") },
            onMessagesClick = onMessagesClick,
            onProfileClick = onProfileClick
        )

        // 2. Release 1 Stories Row (Aidat Öde, Dekontlar, Arıza Bildir, Yönetim)
        ResidentActionsRow(onActionClick = onActionClick, onPayClick = onPayClick)

        // 3. Hero Balance Card (Single Currency: Turkish Lira Only)
        PaparaHeroBalanceCard(
            state = state,
            onPayClick = onPayClick,
            onDetailClick = { onActionClick("Aidat Detayı") }
        )

        // 4. Section: Duyurular
        SectionHeader(title = "DUYURULAR", onMoreClick = { onActionClick("Tüm Duyurular") })
        AnnouncementCard(
            title = state.duyuruBasligi,
            message = state.duyuruMetni,
            timestamp = "Bugün, 10:00",
            onClick = { onActionClick("Duyuru Detayı") }
        )

        // 5. Section: Hesap Hareketleri
        SectionHeader(title = "HESAP HAREKETLERİ", onMoreClick = { onActionClick("Tüm Hareketler") })
        RecentTransactionsFeed(onActionClick = onActionClick)

        Spacer(modifier = Modifier.height(16.dp))
    }
}

/**
 * Site Manager Dashboard Content (Collection Tracking, Stats Grid, Flat Ledger)
 */
@Composable
private fun ManagerDashboardContent(
    collectionSummary: ComplexCollectionSummary,
    flats: List<FlatPaymentStatus>,
    activeFilter: String,
    onFilterSelect: (String) -> Unit,
    onOpenAnnouncement: () -> Unit,
    onOpenDirectMessage: (String, String) -> Unit,
    onProfileClick: () -> Unit,
    onActionClick: (String) -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // 1. Top Bar for Manager
        PaparaTopBar(
            name = "Mehmet Demir (Yönetici)",
            subInfo = "Begonya Sitesi Yönetim Kurulu",
            initials = "MD",
            isManager = true,
            onMenuClick = { onActionClick("Yönetim Menüsü") },
            onMessagesClick = { onOpenDirectMessage("A Blok D:14 - Ahmet Yılmaz", "₺1.423,33") },
            onProfileClick = onProfileClick
        )

        // 2. Manager Quick Actions Row (Duyuru Yap, Mesaj Gönder, Aidat Takip, Kasa / Bütçe)
        ManagerActionsRow(
            onOpenAnnouncement = onOpenAnnouncement,
            onOpenDirectMessage = { onOpenDirectMessage("A Blok D:14 - Ahmet Yılmaz", "₺1.423,33") },
            onActionClick = onActionClick
        )

        // 3. Manager Hero Collection Card (80% Progress Bar, ₺96.000 / ₺120.000)
        ManagerCollectionHeroCard(
            summary = collectionSummary,
            onRemindAll = { onActionClick("Toplu Hatırlatma Gönderildi") },
            onReport = { onActionClick("Tahsilat Raporu PDF İndiriliyor") }
        )

        // 4. Flat-by-Flat Payment Tracking Section Header
        SectionHeader(
            title = "DAİRE AİDAT TAKİBİ",
            subtitle = "${collectionSummary.totalUnitsCount} Daire",
            onMoreClick = { onActionClick("Tüm Daireler") }
        )

        // 5. Filter Pills (Tümü, Gecikmede, Ödeyenler)
        FilterPillsRow(
            activeFilter = activeFilter,
            totalCount = flats.size,
            overdueCount = flats.count { !it.isPaid },
            paidCount = flats.count { it.isPaid },
            onFilterSelect = onFilterSelect
        )

        // 6. Flats List
        val filteredFlats = when (activeFilter) {
            "OVERDUE" -> flats.filter { !it.isPaid }
            "PAID" -> flats.filter { it.isPaid }
            else -> flats
        }

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            filteredFlats.forEach { flat ->
                FlatLedgerItem(
                    flat = flat,
                    onRemindClick = {
                        onOpenDirectMessage(flat.fullDesc, "₺${flat.amountDue}")
                    }
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))
    }
}

/**
 * Top Profile Bar
 */
@Composable
private fun PaparaTopBar(
    name: String,
    subInfo: String,
    initials: String,
    isManager: Boolean = false,
    onMenuClick: () -> Unit,
    onMessagesClick: () -> Unit,
    onProfileClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            BadgedIconButton(icon = Icons.Outlined.Menu, badgeCount = 1, onClick = onMenuClick)
            BadgedIconButton(icon = Icons.Outlined.ChatBubbleOutline, badgeCount = 2, onClick = onMessagesClick)
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.clickable(onClick = onProfileClick)
        ) {
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = name,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textPrimary
                )
                Text(
                    text = subInfo,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = SitePulseTheme.colors.textSecondary,
                    textDecoration = TextDecoration.Underline
                )
            }
            Box(
                modifier = Modifier
                    .size(42.dp)
                    .clip(CircleShape)
                    .background(if (isManager) Color(0xFF0284C7) else SitePulseTheme.colors.avatarBg)
                    .border(1.5.dp, SitePulseTheme.colors.avatarBorder, CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = initials,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (isManager) Color.White else SitePulseTheme.colors.textPrimary
                )
            }
        }
    }
}

@Composable
private fun BadgedIconButton(icon: ImageVector, badgeCount: Int, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(SitePulseTheme.colors.surface)
            .border(1.dp, SitePulseTheme.colors.surfaceBorder, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(20.dp),
            tint = SitePulseTheme.colors.textPrimary
        )
        if (badgeCount > 0) {
            Box(
                modifier = Modifier
                    .size(16.dp)
                    .align(Alignment.TopEnd)
                    .offset(x = 3.dp, y = (-3).dp)
                    .clip(CircleShape)
                    .background(SitePulseTheme.colors.accentRed),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = badgeCount.toString(),
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
            }
        }
    }
}

/**
 * Resident Quick Actions (Release 1: No meter, no reservation. 4 Core Actions)
 */
@Composable
private fun ResidentActionsRow(onActionClick: (String) -> Unit, onPayClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        CircularActionItem(Icons.Outlined.CreditCard, "Aidat Öde", onPayClick)
        CircularActionItem(Icons.AutoMirrored.Outlined.ReceiptLong, "Dekontlar") { onActionClick("Dekontlar") }
        CircularActionItem(Icons.Outlined.Build, "Arıza Bildir") { onActionClick("Arıza Bildir") }
        CircularActionItem(Icons.Outlined.SupportAgent, "Yönetim") { onActionClick("Yönetim") }
    }
}

/**
 * Manager Quick Actions (Duyuru Yap, Mesaj Gönder, Aidat Takip, Kasa / Bütçe)
 */
@Composable
private fun ManagerActionsRow(
    onOpenAnnouncement: () -> Unit,
    onOpenDirectMessage: () -> Unit,
    onActionClick: (String) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        CircularActionItem(Icons.Outlined.Campaign, "Duyuru Yap", onOpenAnnouncement)
        CircularActionItem(Icons.Outlined.MailOutline, "Mesaj Gönder", onOpenDirectMessage)
        CircularActionItem(Icons.Outlined.TableChart, "Aidat Takip") { onActionClick("Aidat Takip") }
        CircularActionItem(Icons.Outlined.AccountBalance, "Kasa / Bütçe") { onActionClick("Kasa / Bütçe") }
    }
}

@Composable
private fun CircularActionItem(icon: ImageVector, label: String, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.clickable(onClick = onClick)
    ) {
        Box(
            modifier = Modifier
                .size(60.dp)
                .clip(CircleShape)
                .background(SitePulseTheme.colors.surface)
                .border(1.dp, SitePulseTheme.colors.surfaceBorder, CircleShape)
                .shadow(2.dp, CircleShape, spotColor = Color.Black.copy(alpha = 0.08f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = label,
                modifier = Modifier.size(24.dp),
                tint = SitePulseTheme.colors.textPrimary
            )
        }
        Text(
            text = label,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = SitePulseTheme.colors.textPrimary
        )
    }
}

/**
 * Manager Collection Hero Card (80% Progress, ₺96.000 / ₺120.000)
 */
@Composable
private fun ManagerCollectionHeroCard(
    summary: ComplexCollectionSummary,
    onRemindAll: () -> Unit,
    onReport: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, SitePulseTheme.colors.surfaceBorder, RoundedCornerShape(22.dp)),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
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
                    Text("🇹🇷", fontSize = 14.sp)
                    Text(
                        text = "${summary.siteName} • ${summary.period} Tahsilat",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }

                Surface(
                    shape = CircleShape,
                    color = SitePulseTheme.colors.successGreenBg
                ) {
                    Text(
                        text = "%${summary.collectionRatePercent} Tahsilat",
                        color = SitePulseTheme.colors.successGreen,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                    )
                }
            }

            // Amounts
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    text = "₺${summary.totalCollected}",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = SitePulseTheme.colors.textPrimary
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = "/ ₺${summary.totalExpected}",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textSecondary,
                    modifier = Modifier.padding(bottom = 2.dp)
                )
            }

            // Progress Bar
            LinearProgressIndicator(
                progress = { summary.collectionRatePercent / 100f },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(8.dp)
                    .clip(CircleShape),
                color = Color(0xFF10B981),
                trackColor = SitePulseTheme.colors.surfaceMuted
            )

            // Two stats boxes (Paid vs Overdue)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = SitePulseTheme.colors.surfaceMuted,
                    modifier = Modifier.weight(1f)
                ) {
                    Column(modifier = Modifier.padding(10.dp)) {
                        Text(
                            text = "${summary.paidUnitsCount} Daire",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = SitePulseTheme.colors.successGreen
                        )
                        Text(
                            text = "Tam Ödendi (₺96.000)",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            color = SitePulseTheme.colors.textMuted
                        )
                    }
                }

                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = SitePulseTheme.colors.surfaceMuted,
                    modifier = Modifier.weight(1f)
                ) {
                    Column(modifier = Modifier.padding(10.dp)) {
                        Text(
                            text = "${summary.overdueUnitsCount} Daire",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = SitePulseTheme.colors.accentRed
                        )
                        Text(
                            text = "Gecikmede (₺24.000 + Faiz)",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            color = SitePulseTheme.colors.textMuted
                        )
                    }
                }
            }

            // Action Buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Button(
                    onClick = onRemindAll,
                    modifier = Modifier
                        .weight(1f)
                        .height(44.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SitePulseTheme.colors.buttonPrimaryBg,
                        contentColor = SitePulseTheme.colors.buttonPrimaryText
                    )
                ) {
                    Text("Toplu Hatırlat", fontWeight = FontWeight.Bold, fontSize = 12.sp)
                    Spacer(modifier = Modifier.width(4.dp))
                    Icon(Icons.Outlined.NotificationsActive, contentDescription = null, modifier = Modifier.size(16.dp))
                }

                Button(
                    onClick = onReport,
                    modifier = Modifier
                        .weight(1f)
                        .height(44.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SitePulseTheme.colors.buttonSecondaryBg,
                        contentColor = SitePulseTheme.colors.buttonSecondaryText
                    )
                ) {
                    Text("Rapor Al", fontWeight = FontWeight.Bold, fontSize = 12.sp)
                    Spacer(modifier = Modifier.width(4.dp))
                    Icon(Icons.AutoMirrored.Outlined.ReceiptLong, contentDescription = null, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

/**
 * Filter Pills Row (Tümü, Gecikmede, Ödeyenler)
 */
@Composable
private fun FilterPillsRow(
    activeFilter: String,
    totalCount: Int,
    overdueCount: Int,
    paidCount: Int,
    onFilterSelect: (String) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        FilterPillItem(
            label = "Tümü ($totalCount)",
            isSelected = activeFilter == "ALL",
            onClick = { onFilterSelect("ALL") }
        )
        FilterPillItem(
            label = "Gecikmede ($overdueCount)",
            isSelected = activeFilter == "OVERDUE",
            onClick = { onFilterSelect("OVERDUE") }
        )
        FilterPillItem(
            label = "Ödeyenler ($paidCount)",
            isSelected = activeFilter == "PAID",
            onClick = { onFilterSelect("PAID") }
        )
    }
}

@Composable
private fun FilterPillItem(
    label: String,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    Surface(
        shape = CircleShape,
        color = if (isSelected) SitePulseTheme.colors.textPrimary else SitePulseTheme.colors.surface,
        border = BorderStroke(1.dp, if (isSelected) SitePulseTheme.colors.textPrimary else SitePulseTheme.colors.surfaceBorder),
        modifier = Modifier.clickable(onClick = onClick)
    ) {
        Text(
            text = label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = if (isSelected) SitePulseTheme.colors.background else SitePulseTheme.colors.textSecondary,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp)
        )
    }
}

/**
 * Flat Ledger Item Card
 */
@Composable
private fun FlatLedgerItem(
    flat: FlatPaymentStatus,
    onRemindClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, SitePulseTheme.colors.surfaceBorder, RoundedCornerShape(16.dp)),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (flat.isPaid) SitePulseTheme.colors.successGreenBg else SitePulseTheme.colors.accentRedBg),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = flat.unitNo.toString(),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = if (flat.isPaid) SitePulseTheme.colors.successGreen else SitePulseTheme.colors.accentRed
                    )
                }

                Column {
                    Text(
                        text = flat.residentName,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = if (flat.isPaid) "${flat.flatDesc} • ${flat.paidDateStr} Ödendi" else "${flat.flatDesc} • ${flat.daysOverdue} Gün Gecikme",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textMuted
                    )
                }
            }

            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = "₺${flat.amountDue}",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (flat.isPaid) SitePulseTheme.colors.textPrimary else SitePulseTheme.colors.accentRed
                )
                Spacer(modifier = Modifier.height(4.dp))
                if (flat.isPaid) {
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = SitePulseTheme.colors.successGreenBg
                    ) {
                        Text(
                            text = "✔ Ödendi",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.successGreen,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                        )
                    }
                } else {
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = SitePulseTheme.colors.accentRedBg,
                        modifier = Modifier.clickable(onClick = onRemindClick)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                        ) {
                            Icon(
                                Icons.Outlined.ChatBubbleOutline,
                                contentDescription = null,
                                modifier = Modifier.size(11.dp),
                                tint = SitePulseTheme.colors.accentRed
                            )
                            Text(
                                text = "Hatırlat",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = SitePulseTheme.colors.accentRed
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Resident Hero Balance Card
 */
@Composable
private fun PaparaHeroBalanceCard(
    state: DashboardUiState.Success,
    onPayClick: () -> Unit,
    onDetailClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, SitePulseTheme.colors.surfaceBorder, RoundedCornerShape(22.dp)),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
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
                    Text("🇹🇷", fontSize = 14.sp)
                    Text(
                        text = "Türk Lirası Aidat Hesabı",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }

                if (state.isOverdue) {
                    Surface(
                        shape = CircleShape,
                        color = SitePulseTheme.colors.accentRedBg
                    ) {
                        Text(
                            text = "10 Gün Gecikme",
                            color = SitePulseTheme.colors.accentRed,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                        )
                    }
                } else {
                    Surface(
                        shape = CircleShape,
                        color = SitePulseTheme.colors.successGreenBg
                    ) {
                        Text(
                            text = "Borçsuz",
                            color = SitePulseTheme.colors.successGreen,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                        )
                    }
                }
            }

            Text(
                text = "₺${state.toplamBorc}",
                fontSize = 32.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textPrimary
            )

            Text(
                text = "Son Ödeme: 15 Eylül 2026 (%5 yasal faiz dahil)",
                fontSize = 12.sp,
                color = SitePulseTheme.colors.textMuted
            )

            Spacer(modifier = Modifier.height(4.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Button(
                    onClick = onPayClick,
                    modifier = Modifier
                        .weight(1f)
                        .height(46.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SitePulseTheme.colors.buttonPrimaryBg,
                        contentColor = SitePulseTheme.colors.buttonPrimaryText
                    )
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text("Hemen Öde", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                        Icon(Icons.Outlined.CreditCard, contentDescription = null, modifier = Modifier.size(16.dp))
                    }
                }

                Button(
                    onClick = onDetailClick,
                    modifier = Modifier
                        .weight(1f)
                        .height(46.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SitePulseTheme.colors.buttonSecondaryBg,
                        contentColor = SitePulseTheme.colors.buttonSecondaryText
                    )
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text("Detay Gör", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                        Icon(Icons.AutoMirrored.Outlined.ReceiptLong, contentDescription = null, modifier = Modifier.size(16.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String, subtitle: String? = null, onMoreClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onMoreClick)
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = "$title →",
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            color = SitePulseTheme.colors.textSecondary,
            letterSpacing = 0.5.sp
        )
        if (subtitle != null) {
            Text(
                text = subtitle,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = SitePulseTheme.colors.navActive
            )
        }
    }
}

@Composable
private fun AnnouncementCard(
    title: String,
    message: String,
    timestamp: String,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, SitePulseTheme.colors.surfaceBorder, RoundedCornerShape(18.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(SitePulseTheme.colors.warningAmberBg),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Outlined.Campaign,
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                    tint = WarningAmber
                )
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                Text(
                    text = "Site Yönetim Kurulu • $timestamp",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = SitePulseTheme.colors.textMuted
                )
                Text(
                    text = title,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textPrimary
                )
                Text(
                    text = message,
                    fontSize = 12.sp,
                    color = SitePulseTheme.colors.textSecondary,
                    maxLines = 2
                )
            }

            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(SitePulseTheme.colors.accentRed)
            )
        }
    }
}

@Composable
private fun RecentTransactionsFeed(onActionClick: (String) -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, SitePulseTheme.colors.surfaceBorder, RoundedCornerShape(18.dp)),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            TransactionItem(
                icon = Icons.Outlined.Apartment,
                iconTint = SitePulseTheme.colors.textPrimary,
                title = "Eylül 2026 Aidatı",
                subtitle = "A Blok Ortak Alan",
                amount = "₺1.400,00",
                date = "15 Eyl",
                isNegative = false,
                onClick = { onActionClick("İşlem: Eylül Aidatı") }
            )
            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)
            TransactionItem(
                icon = Icons.Outlined.Gavel,
                iconTint = SitePulseTheme.colors.accentRed,
                title = "KMK Gecikme Tazminatı",
                subtitle = "10 Gün Pro-rata (%5/ay)",
                amount = "+₺23,33",
                date = "Bugün",
                isNegative = true,
                onClick = { onActionClick("İşlem: Gecikme Faizi") }
            )
            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)
            TransactionItem(
                icon = Icons.Outlined.CheckCircleOutline,
                iconTint = SitePulseTheme.colors.successGreen,
                title = "Ağustos 2026 Aidatı",
                subtitle = "3D Secure ile Ödendi",
                amount = "₺1.350,00",
                date = "14 Ağu",
                isNegative = false,
                onClick = { onActionClick("İşlem: Ağustos Dekont") }
            )
        }
    }
}

@Composable
private fun TransactionItem(
    icon: ImageVector,
    iconTint: Color,
    title: String,
    subtitle: String,
    amount: String,
    date: String,
    isNegative: Boolean,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(SitePulseTheme.colors.surfaceMuted),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = iconTint
                )
            }
            Column {
                Text(
                    text = title,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textPrimary
                )
                Text(
                    text = "$subtitle • $date",
                    fontSize = 11.sp,
                    color = SitePulseTheme.colors.textSecondary
                )
            }
        }

        Text(
            text = amount,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            color = if (isNegative) SitePulseTheme.colors.accentRed else SitePulseTheme.colors.textPrimary
        )
    }
}

@Composable
private fun PaparaBottomNav(
    selectedTab: Int,
    onTabSelect: (Int, String) -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding(),
        color = SitePulseTheme.colors.surface,
        shadowElevation = 8.dp,
        border = BorderStroke(1.dp, SitePulseTheme.colors.surfaceBorder)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(66.dp)
                .padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            BottomNavItem(
                icon = if (selectedTab == 0) Icons.Filled.Home else Icons.Outlined.Home,
                label = "Ana Sayfa",
                isSelected = selectedTab == 0,
                modifier = Modifier.weight(1f)
            ) { onTabSelect(0, "Ana Sayfa") }

            BottomNavItem(
                icon = if (selectedTab == 1) Icons.Filled.AccountBalanceWallet else Icons.Outlined.AccountBalanceWallet,
                label = "Aidatlar",
                isSelected = selectedTab == 1,
                modifier = Modifier.weight(1f)
            ) { onTabSelect(1, "Aidatlar") }

            BottomNavItem(
                icon = if (selectedTab == 2) Icons.Filled.Handyman else Icons.Outlined.Handyman,
                label = "Talepler",
                isSelected = selectedTab == 2,
                modifier = Modifier.weight(1f)
            ) { onTabSelect(2, "Talepler") }

            BottomNavItem(
                icon = if (selectedTab == 3) Icons.Filled.Notifications else Icons.Outlined.NotificationsNone,
                label = "Duyurular",
                isSelected = selectedTab == 3,
                badgeCount = 1,
                modifier = Modifier.weight(1f)
            ) { onTabSelect(3, "Duyurular") }

            BottomNavItem(
                icon = if (selectedTab == 4) Icons.Filled.Person else Icons.Outlined.PersonOutline,
                label = "Profil",
                isSelected = selectedTab == 4,
                modifier = Modifier.weight(1f)
            ) { onTabSelect(4, "Profil") }
        }
    }
}

@Composable
private fun BottomNavItem(
    icon: ImageVector,
    label: String,
    isSelected: Boolean,
    modifier: Modifier = Modifier,
    badgeCount: Int = 0,
    onClick: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = modifier
            .fillMaxHeight()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 2.dp)
    ) {
        Box(contentAlignment = Alignment.TopEnd) {
            Icon(
                imageVector = icon,
                contentDescription = label,
                modifier = Modifier.size(24.dp),
                tint = if (isSelected) SitePulseTheme.colors.navActive else SitePulseTheme.colors.navInactive
            )
            if (badgeCount > 0) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .offset(x = 3.dp, y = (-2).dp)
                        .clip(CircleShape)
                        .background(SitePulseTheme.colors.accentRed)
                )
            }
        }
        Spacer(modifier = Modifier.height(3.dp))
        Text(
            text = label,
            fontSize = 11.sp,
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
            color = if (isSelected) SitePulseTheme.colors.navActive else SitePulseTheme.colors.navInactive
        )
    }
}

/**
 * Profile Bottom Sheet Modal with Role Switcher & Theme Selector
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProfileModalBottomSheet(
    residentName: String,
    apartmentInfo: String,
    currentRole: UserRole,
    onRoleChange: (UserRole) -> Unit,
    isDarkTheme: Boolean,
    onThemeToggle: (Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SitePulseTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SitePulseTheme.colors.textMuted.copy(alpha = 0.4f)) },
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(if (currentRole == UserRole.SITE_MANAGER) Color(0xFF0284C7) else SitePulseTheme.colors.avatarBg)
                        .border(1.5.dp, SitePulseTheme.colors.avatarBorder, CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = if (currentRole == UserRole.SITE_MANAGER) "MD" else "AY",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (currentRole == UserRole.SITE_MANAGER) Color.White else SitePulseTheme.colors.textPrimary
                    )
                }

                Column {
                    Text(
                        text = residentName,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = apartmentInfo,
                        fontSize = 12.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)

            // Section: Role Switcher
            Text(
                text = "KULLANICI ROLÜ & GİRİŞ TÜRÜ",
                fontSize = 11.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textMuted,
                letterSpacing = 0.6.sp
            )

            ThemeOptionItem(
                icon = "👤",
                title = "Site Sakini",
                subtitle = "Ahmet Yılmaz • A Blok D:14 (Aidat Ödeme & Bildirim)",
                isSelected = currentRole == UserRole.RESIDENT,
                onClick = { onRoleChange(UserRole.RESIDENT) }
            )

            ThemeOptionItem(
                icon = "🏢",
                title = "Site Yöneticisi",
                subtitle = "Mehmet Demir • Yönetim (Aidat Takip & Duyuru)",
                isSelected = currentRole == UserRole.SITE_MANAGER,
                onClick = { onRoleChange(UserRole.SITE_MANAGER) }
            )

            // Section: Theme Toggle
            Text(
                text = "GÖRÜNÜM & PARAMETRİK TEMA",
                fontSize = 11.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textMuted,
                letterSpacing = 0.6.sp
            )

            ThemeOptionItem(
                icon = "☀️",
                title = "Açık Tema",
                subtitle = "Papara Aydınlık Klasik Tasarım",
                isSelected = !isDarkTheme,
                onClick = { onThemeToggle(false) }
            )

            ThemeOptionItem(
                icon = "🌙",
                title = "Koyu Tema",
                subtitle = "Papara Gece / Midnight Mat Siyah",
                isSelected = isDarkTheme,
                onClick = { onThemeToggle(true) }
            )

            // Section: Currency Note
            Text(
                text = "PARA BİRİMİ TANIMI",
                fontSize = 11.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textMuted,
                letterSpacing = 0.6.sp
            )

            Surface(
                shape = RoundedCornerShape(14.dp),
                color = SitePulseTheme.colors.surfaceMuted,
                border = BorderStroke(1.dp, SitePulseTheme.colors.surfaceBorder)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text("🇹🇷", fontSize = 22.sp)
                    Column {
                        Text(
                            text = "Türk Lirası (₺)",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "Tüm aidat ve yasal KMK gecikme hesaplamaları yalnızca TL cinsindendir.",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                    }
                }
            }

            Button(
                onClick = onDismiss,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SitePulseTheme.colors.buttonPrimaryBg,
                    contentColor = SitePulseTheme.colors.buttonPrimaryText
                )
            ) {
                Text("Kapat", fontWeight = FontWeight.Bold, fontSize = 13.sp)
            }
        }
    }
}

/**
 * Announcement Modal Bottom Sheet for Manager
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AnnouncementModalBottomSheet(
    onPublish: (String, String, String) -> Unit,
    onDismiss: () -> Unit
) {
    var title by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("Genel Bilgilendirme") }
    var body by remember { mutableStateOf("") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SitePulseTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SitePulseTheme.colors.textMuted.copy(alpha = 0.4f)) },
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF0284C7).copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Outlined.Campaign, contentDescription = null, tint = Color(0xFF0284C7))
                }
                Column {
                    Text(
                        text = "Yeni Duyuru Yayınla",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Tüm Begonya Sitesi sakinlerine anlık push bildirimi",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Duyuru Başlığı") },
                placeholder = { Text("Örn: Asansör Bakımı Hakkında") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )

            OutlinedTextField(
                value = body,
                onValueChange = { body = it },
                label = { Text("Duyuru Metni") },
                placeholder = { Text("Sakinlere iletilecek detayları yazınız...") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(110.dp),
                shape = RoundedCornerShape(12.dp)
            )

            Surface(
                shape = RoundedCornerShape(12.dp),
                color = SitePulseTheme.colors.surfaceMuted,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier.padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("📲", fontSize = 14.sp)
                    Text(
                        text = "Bu duyuru 24 dairenin tüm sakinlerine anlık push bildirimi olarak iletilecektir.",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Button(
                    onClick = onDismiss,
                    modifier = Modifier
                        .weight(1f)
                        .height(46.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SitePulseTheme.colors.surfaceMuted,
                        contentColor = SitePulseTheme.colors.textPrimary
                    )
                ) {
                    Text("Vazgeç", fontWeight = FontWeight.Bold)
                }

                Button(
                    onClick = {
                        val finalTitle = if (title.isBlank()) "Site Duyurusu" else title
                        onPublish(finalTitle, category, body)
                    },
                    modifier = Modifier
                        .weight(1.5f)
                        .height(46.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF0284C7),
                        contentColor = Color.White
                    )
                ) {
                    Text("Tüm Sakinlere Yayınla", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

/**
 * Direct Message / Overdue Reminder Bottom Sheet for Manager
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DirectMessageModalBottomSheet(
    targetFlat: String,
    amount: String,
    onSend: (String, String, String) -> Unit,
    onDismiss: () -> Unit
) {
    var messageText by remember {
        mutableStateOf("Sayın Kat Maliki ($targetFlat), Eylül 2026 dönemi aidat bakiyeniz ($amount) 10 gün gecikmededir. KMK gecikme faizi işlememesi adına mobil uygulamamızdan 3D Secure ile ödeme yapabilirsiniz.")
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SitePulseTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SitePulseTheme.colors.textMuted.copy(alpha = 0.4f)) },
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(SitePulseTheme.colors.accentRedBg),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Outlined.MailOutline, contentDescription = null, tint = SitePulseTheme.colors.accentRed)
                }
                Column {
                    Text(
                        text = "Daireye Özel Bildirim / Hatırlatma",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Hedef: $targetFlat",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = SitePulseTheme.colors.accentRed
                    )
                }
            }

            OutlinedTextField(
                value = messageText,
                onValueChange = { messageText = it },
                label = { Text("Mesaj İçeriği") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(130.dp),
                shape = RoundedCornerShape(12.dp)
            )

            Surface(
                shape = RoundedCornerShape(12.dp),
                color = SitePulseTheme.colors.surfaceMuted,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier.padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("✉️", fontSize = 14.sp)
                    Text(
                        text = "Bu bildirim seçilen kat malikine push bildirimi ve SMS olarak iletilecektir.",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Button(
                    onClick = onDismiss,
                    modifier = Modifier
                        .weight(1f)
                        .height(46.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SitePulseTheme.colors.surfaceMuted,
                        contentColor = SitePulseTheme.colors.textPrimary
                    )
                ) {
                    Text("Vazgeç", fontWeight = FontWeight.Bold)
                }

                Button(
                    onClick = {
                        onSend(targetFlat, "Aidat Gecikme Hatırlatması", messageText)
                    },
                    modifier = Modifier
                        .weight(1.5f)
                        .height(46.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SitePulseTheme.colors.buttonPrimaryBg,
                        contentColor = SitePulseTheme.colors.buttonPrimaryText
                    )
                ) {
                    Text("Bildirimi Gönder", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
private fun ThemeOptionItem(
    icon: String,
    title: String,
    subtitle: String,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = if (isSelected) SitePulseTheme.colors.surface else SitePulseTheme.colors.surfaceMuted,
        border = BorderStroke(
            width = if (isSelected) 1.5.dp else 1.dp,
            color = if (isSelected) SitePulseTheme.colors.navActive else SitePulseTheme.colors.surfaceBorder
        ),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(icon, fontSize = 20.sp)
                Column {
                    Text(
                        text = title,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = subtitle,
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            RadioButton(
                selected = isSelected,
                onClick = onClick,
                colors = RadioButtonDefaults.colors(
                    selectedColor = SitePulseTheme.colors.navActive,
                    unselectedColor = SitePulseTheme.colors.textMuted
                )
            )
        }
    }
}
