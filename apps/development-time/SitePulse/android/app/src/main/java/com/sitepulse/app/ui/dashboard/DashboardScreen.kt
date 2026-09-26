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
import com.sitepulse.app.domain.model.*
import com.sitepulse.app.ui.components.VirtualIbanCard
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
    val saasSites by viewModel.saasSites.collectAsState()
    val provisionedCreds by viewModel.provisionedCredentials.collectAsState()
    val provisionedHomeOwner by viewModel.provisionedHomeOwner.collectAsState()
    val pendingRegistrations by viewModel.pendingRegistrations.collectAsState()
    val approvalSuccess by viewModel.approvalSuccessInfo.collectAsState()
    val unitResidents by viewModel.unitResidents.collectAsState()
    val unitInviteInfo by viewModel.unitInviteInfo.collectAsState()
    val userSession by viewModel.userSession.collectAsState()
    val authMessage by viewModel.authMessage.collectAsState()

    var selectedTab by remember { mutableStateOf(0) }
    var showProfileSheet by remember { mutableStateOf(false) }
    var showPasswordAuthDialog by remember { mutableStateOf(false) }
    var showAnnouncementSheet by remember { mutableStateOf(false) }
    var showDirectMessageSheet by remember { mutableStateOf(false) }
    var showRegisterSiteSheet by remember { mutableStateOf(false) }
    var showAddHomeOwnerSheet by remember { mutableStateOf(false) }
    var showInviteLinkSheet by remember { mutableStateOf(false) }
    var showUnitInviteSheet by remember { mutableStateOf(false) }
    var showAddHouseholdMemberDialog by remember { mutableStateOf(false) }
    var directMessageTarget by remember { mutableStateOf("A Blok D:14 - Ahmet Yılmaz") }
    var directMessageAmount by remember { mutableStateOf("₺1.423,33") }



    Scaffold(
        containerColor = SitePulseTheme.colors.background,
        bottomBar = {
            PaparaBottomNav(
                userRole = userRole,
                selectedTab = selectedTab,
                onTabSelect = { tabIndex, tabName ->
                    selectedTab = tabIndex
                    when (tabName) {
                        "Profil", "Dairem / Profil", "Altyapı" -> showProfileSheet = true
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
                    when (userRole) {
                        UserRole.RESIDENT, UserRole.HOME_OWNER, UserRole.HOME_RESIDENT -> {
                            ResidentDashboardContent(
                                state = s,
                                userSession = userSession,
                                unitResidents = unitResidents,
                                onPayClick = onPayClick,
                                onActionClick = onActionClick,
                                onOpenUnitInviteLink = {
                                    viewModel.generateUnitInviteLink()
                                    showUnitInviteSheet = true
                                },
                                onOpenAddHouseholdMember = {
                                    showAddHouseholdMemberDialog = true
                                },
                                onProfileClick = { showProfileSheet = true },
                                onMessagesClick = { onActionClick("Mesajlaşma") }
                            )
                        }
                        UserRole.SITE_MANAGER -> {
                            ManagerDashboardContent(
                                collectionSummary = collectionSummary,
                                flats = flatsList,
                                activeFilter = flatFilter,
                                pendingRegistrations = pendingRegistrations,
                                onFilterSelect = { viewModel.setFlatFilter(it) },
                                onOpenAddHomeOwner = { showAddHomeOwnerSheet = true },
                                onOpenInviteLink = { showInviteLinkSheet = true },
                                onApproveRegistration = { viewModel.approveRegistration(it) },
                                onRejectRegistration = { viewModel.rejectRegistration(it) },
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
                        UserRole.SAAS_ADMIN -> {
                            SaasAdminDashboardContent(
                                sites = saasSites,
                                onRegisterNewSiteClick = { showRegisterSiteSheet = true },
                                onProfileClick = { showProfileSheet = true },
                                onActionClick = onActionClick
                            )
                        }
                    }

                    // Modals
                    if (showProfileSheet) {
                        ProfileModalBottomSheet(
                            userSession = userSession,
                            currentRole = userRole,
                            onRoleChange = { viewModel.switchSessionRole(it) },
                            onLoginWithGoogle = {
                                viewModel.loginWithGoogle()
                                showProfileSheet = false
                            },
                            onOpenPasswordAuth = {
                                showProfileSheet = false
                                showPasswordAuthDialog = true
                            },
                            isDarkTheme = isDarkTheme,
                            onThemeToggle = onThemeToggle,
                            onDismiss = { showProfileSheet = false }
                        )
                    }

                    if (showPasswordAuthDialog) {
                        PasswordAuthDialog(
                            onLogin = { email, pass ->
                                viewModel.loginWithPassword(email, pass)
                                showPasswordAuthDialog = false
                            },
                            onRegister = { name, email, phone, pass ->
                                viewModel.registerWithPassword(name, email, phone, pass)
                                showPasswordAuthDialog = false
                            },
                            onDismiss = { showPasswordAuthDialog = false }
                        )
                    }


                    if (showRegisterSiteSheet) {
                        RegisterSiteModalBottomSheet(
                            onRegister = { name, city, addr, admName, admEmail, admPhone, plan ->
                                viewModel.registerNewSite(name, city, addr, admName, admEmail, admPhone, plan)
                            },
                            onDismiss = { showRegisterSiteSheet = false }
                        )
                    }

                    provisionedCreds?.let { creds ->
                        ProvisionedCredentialsDialog(
                            creds = creds,
                            onDismiss = { viewModel.clearProvisionedCredentials() }
                        )
                    }

                    if (showAddHomeOwnerSheet) {
                        AddHomeOwnerModalBottomSheet(
                            onDismiss = { showAddHomeOwnerSheet = false },
                            onSubmit = { block, unitNo, ownerName, email, phone, dues, isResident ->
                                viewModel.registerHomeOwner(block, unitNo, ownerName, email, phone, dues, isResident)
                                showAddHomeOwnerSheet = false
                            }
                        )
                    }

                    provisionedHomeOwner?.let { creds ->
                        ProvisionedHomeOwnerDialog(
                            creds = creds,
                            onDismiss = { viewModel.clearProvisionedHomeOwner() }
                        )
                    }

                    if (showInviteLinkSheet) {
                        InviteLinkModalBottomSheet(
                            invitationUrl = viewModel.invitationUrl,
                            onDismiss = { showInviteLinkSheet = false }
                        )
                    }

                    approvalSuccess?.let { info ->
                        RegistrationApprovedDialog(
                            info = info,
                            onDismiss = { viewModel.clearApprovalSuccess() }
                        )
                    }

                    if (showUnitInviteSheet) {
                        HomeResidentInviteBottomSheet(
                            inviteInfo = unitInviteInfo ?: UnitInviteInfo(
                                inviteUrl = "https://sitepulse.app/join/begonya-sitesi/units/d-14?token=SP-HANE-4821",
                                token = "SP-HANE-4821",
                                unitLabel = "A Blok D:14"
                            ),
                            onDismiss = { showUnitInviteSheet = false },
                            onOpenAddMemberDemo = {
                                showUnitInviteSheet = false
                                showAddHouseholdMemberDialog = true
                            }
                        )
                    }

                    if (showAddHouseholdMemberDialog) {
                        AddHouseholdMemberDialog(
                            unitLabel = "A Blok D:14",
                            onDismiss = { showAddHouseholdMemberDialog = false },
                            onSubmit = { fullName, phone, email, relationship ->
                                viewModel.addHomeResidentMember(fullName, phone, email, relationship)
                                showAddHouseholdMemberDialog = false
                            }
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

@Composable
private fun ResidentDashboardContent(
    state: DashboardUiState.Success,
    userSession: UserSession,
    unitResidents: List<UnitResidentMember>,
    onPayClick: () -> Unit,
    onActionClick: (String) -> Unit,
    onOpenUnitInviteLink: () -> Unit,
    onOpenAddHouseholdMember: () -> Unit,
    onProfileClick: () -> Unit,
    onMessagesClick: () -> Unit
) {
    val canInvite = userSession.role == UserRole.HOME_OWNER || userSession.role == UserRole.RESIDENT

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // 1. Top Bar
        val initials = if (userSession.fullName.contains(" ")) {
            userSession.fullName.split(" ").mapNotNull { it.firstOrNull()?.toString() }.take(2).joinToString("")
        } else "AY"

        PaparaTopBar(
            name = userSession.fullName,
            subInfo = "${state.aktifDaire.siteAdi} • ${userSession.unitName} (${userSession.authProvider.iconLabel} ${userSession.authProvider.label})",
            initials = initials,
            onMenuClick = { onActionClick("Menü") },
            onMessagesClick = onMessagesClick,
            onProfileClick = onProfileClick
        )

        // 2. Release 1 Stories Row (Aidat Öde, Sakin Davet, Dekontlar, Arıza Bildir, Yönetim)
        ResidentActionsRow(
            onActionClick = onActionClick,
            onPayClick = onPayClick,
            onOpenUnitInviteLink = {
                if (canInvite) {
                    onOpenUnitInviteLink()
                } else {
                    onActionClick("Yetki Kısıtlaması: Sadece Kat Maliki davet linki üretebilir.")
                }
            }
        )

        // 3. Hero Balance Card (Single Currency: Turkish Lira Only)
        PaparaHeroBalanceCard(
            state = state,
            onPayClick = onPayClick,
            onDetailClick = { onActionClick("Aidat Detayı") }
        )

        // EPIC-07: Daireye Özel Sanal IBAN Kartı (Havale / FAST ile Otomatik Eşleşme)
        VirtualIbanCard(
            iban = "TR12 0006 2000 0000 0000 0014",
            bankName = "Garanti BBVA Kurumsal",
            recipient = "Begonya Sitesi Yönetimi",
            unitLabel = "${state.aktifDaire.blok} Blok D:${state.aktifDaire.daireNo}",
            onCopied = { onActionClick("Daireye özel Sanal IBAN panoya kopyalandı!") }
        )


        // 4. Section: Hane Sakinleri (Daire İçi İzinler & Aile Sakinleri)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "HANE SAKİNLERİ",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textSecondary,
                    letterSpacing = 0.5.sp
                )
                Surface(
                    color = Color(0xFF0284C7).copy(alpha = 0.12f),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text(
                        text = "${unitResidents.size} Sakin",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF0284C7),
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                }
            }
            TextButton(
                onClick = onOpenUnitInviteLink,
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)
            ) {
                Text(
                    text = "🔗 Davet Linki",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFF0284C7)
                )
            }
        }

        HouseholdMembersCard(
            unitLabel = "${state.aktifDaire.blok} Blok D:${state.aktifDaire.daireNo}",
            members = unitResidents,
            onInviteClick = onOpenUnitInviteLink,
            onAddMemberDemoClick = onOpenAddHouseholdMember
        )

        // 5. Section: Duyurular
        SectionHeader(title = "DUYURULAR", onMoreClick = { onActionClick("Tüm Duyurular") })
        AnnouncementCard(
            title = state.duyuruBasligi,
            message = state.duyuruMetni,
            timestamp = "Bugün, 10:00",
            onClick = { onActionClick("Duyuru Detayı") }
        )

        // 6. Section: Hesap Hareketleri
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
    pendingRegistrations: List<RegistrationRequestItem>,
    onFilterSelect: (String) -> Unit,
    onOpenAddHomeOwner: () -> Unit,
    onOpenInviteLink: () -> Unit,
    onApproveRegistration: (String) -> Unit,
    onRejectRegistration: (String) -> Unit,
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

        // 2. Manager Quick Actions Row (Malik Ekle, Davet Linki, Duyuru Yap, Mesaj Gönder, Aidat Takip, Kasa / Bütçe)
        ManagerActionsRow(
            onOpenAddHomeOwner = onOpenAddHomeOwner,
            onOpenInviteLink = onOpenInviteLink,
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

        // 4. Dual Quick Actions (Direct Add & Share Invite Link)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Card(
                modifier = Modifier
                    .weight(1f)
                    .clickable { onOpenAddHomeOwner() },
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
                border = BorderStroke(1.dp, Color(0xFF0284C7).copy(alpha = 0.35f))
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF0284C7).copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.PersonAdd,
                            contentDescription = null,
                            tint = Color(0xFF0284C7),
                            modifier = Modifier.size(20.dp)
                        )
                    }
                    Text(
                        text = "+ Malik Ekle",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Manuel daire & şifre",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            Card(
                modifier = Modifier
                    .weight(1f)
                    .clickable { onOpenInviteLink() },
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
                border = BorderStroke(1.dp, Color(0xFF10B981).copy(alpha = 0.35f))
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF10B981).copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Share,
                            contentDescription = null,
                            tint = Color(0xFF10B981),
                            modifier = Modifier.size(20.dp)
                        )
                    }
                    Text(
                        text = "🔗 Davet Linki",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Online başvuru al",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }
        }

        // 5. Pending Registrations Approval Queue
        if (pendingRegistrations.isNotEmpty()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "ONAY BEKLEYEN BAŞVURULAR",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = SitePulseTheme.colors.textSecondary,
                    letterSpacing = 0.8.sp
                )
                Surface(
                    color = Color(0xFFEF4444).copy(alpha = 0.12f),
                    shape = RoundedCornerShape(8.dp),
                    border = BorderStroke(0.6.dp, Color(0xFFEF4444).copy(alpha = 0.3f))
                ) {
                    Text(
                        text = "${pendingRegistrations.size} Bekliyor",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFFDC2626),
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                pendingRegistrations.forEach { req ->
                    PendingRegistrationCard(
                        item = req,
                        onApprove = { onApproveRegistration(req.id) },
                        onReject = { onRejectRegistration(req.id) }
                    )
                }
            }
        }


        // 5. Flat-by-Flat Payment Tracking Section Header
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
 * Resident Quick Actions (Release 1: 5 Actions with Sakin Davet)
 */
@Composable
private fun ResidentActionsRow(
    onActionClick: (String) -> Unit,
    onPayClick: () -> Unit,
    onOpenUnitInviteLink: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        CircularActionItem(Icons.Outlined.CreditCard, "Aidat Öde", onPayClick)
        CircularActionItem(Icons.Outlined.AccountBalance, "Sanal IBAN") { onActionClick("Sanal IBAN") }
        CircularActionItem(Icons.AutoMirrored.Outlined.ReceiptLong, "Dekontlar") { onActionClick("Dekontlar") }
        CircularActionItem(Icons.Outlined.GroupAdd, "Sakin Davet", onOpenUnitInviteLink)
    }
}

/**
 * Manager Quick Actions (Malik Ekle, Duyuru Yap, Mesaj Gönder, Aidat Takip, Kasa / Bütçe)
 */
@Composable
private fun ManagerActionsRow(
    onOpenAddHomeOwner: () -> Unit,
    onOpenInviteLink: () -> Unit,
    onOpenAnnouncement: () -> Unit,
    onOpenDirectMessage: () -> Unit,
    onActionClick: (String) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        CircularActionItem(Icons.Outlined.PersonAdd, "Malik Ekle", onOpenAddHomeOwner)
        CircularActionItem(Icons.Outlined.Share, "Davet Linki", onOpenInviteLink)
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
    userRole: UserRole,
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
            when (userRole) {
                UserRole.SITE_MANAGER -> {
                    BottomNavItem(
                        icon = if (selectedTab == 0) Icons.Filled.Dashboard else Icons.Outlined.Dashboard,
                        label = "Kokpit",
                        isSelected = selectedTab == 0,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(0, "Kokpit") }

                    BottomNavItem(
                        icon = if (selectedTab == 1) Icons.Filled.People else Icons.Outlined.People,
                        label = "Borçlular",
                        isSelected = selectedTab == 1,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(1, "Borçlular") }

                    BottomNavItem(
                        icon = if (selectedTab == 2) Icons.Filled.AccountBalance else Icons.Outlined.AccountBalance,
                        label = "Banka & Mutabakat",
                        isSelected = selectedTab == 2,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(2, "Banka & Mutabakat") }
                }
                UserRole.SAAS_ADMIN -> {
                    BottomNavItem(
                        icon = if (selectedTab == 0) Icons.Filled.Public else Icons.Outlined.Public,
                        label = "Platform",
                        isSelected = selectedTab == 0,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(0, "Platform") }

                    BottomNavItem(
                        icon = if (selectedTab == 1) Icons.Filled.Apartment else Icons.Outlined.Apartment,
                        label = "Siteler",
                        isSelected = selectedTab == 1,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(1, "Siteler") }

                    BottomNavItem(
                        icon = if (selectedTab == 2) Icons.Filled.Dns else Icons.Outlined.Dns,
                        label = "Altyapı",
                        isSelected = selectedTab == 2,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(2, "Altyapı") }
                }
                else -> {
                    BottomNavItem(
                        icon = if (selectedTab == 0) Icons.Filled.Home else Icons.Outlined.Home,
                        label = "Ana Sayfa",
                        isSelected = selectedTab == 0,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(0, "Ana Sayfa") }

                    BottomNavItem(
                        icon = Icons.AutoMirrored.Outlined.ReceiptLong,
                        label = "Dekontlar",
                        isSelected = selectedTab == 1,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(1, "Dekontlar") }

                    BottomNavItem(
                        icon = if (selectedTab == 2) Icons.Filled.Person else Icons.Outlined.PersonOutline,
                        label = "Dairem / Profil",
                        isSelected = selectedTab == 2,
                        modifier = Modifier.weight(1f)
                    ) { onTabSelect(2, "Dairem / Profil") }
                }
            }
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
 * Profile, Authentication & Scoped Permission Bottom Sheet
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProfileModalBottomSheet(
    userSession: UserSession,
    currentRole: UserRole,
    onRoleChange: (UserRole) -> Unit,
    onLoginWithGoogle: () -> Unit,
    onOpenPasswordAuth: () -> Unit,
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
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            // 1. User Header & Provider Badge
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(52.dp)
                        .clip(CircleShape)
                        .background(
                            when (currentRole) {
                                UserRole.SAAS_ADMIN -> Color(0xFF6366F1)
                                UserRole.SITE_MANAGER -> Color(0xFF0284C7)
                                UserRole.HOME_RESIDENT -> Color(0xFF16A34A)
                                else -> Color(0xFF0D9488)
                            }
                        )
                        .border(1.5.dp, SitePulseTheme.colors.avatarBorder, CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = when (currentRole) {
                            UserRole.SAAS_ADMIN -> "SA"
                            UserRole.SITE_MANAGER -> "MD"
                            UserRole.HOME_RESIDENT -> "ZY"
                            else -> "AY"
                        },
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                }

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = userSession.fullName,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "${userSession.siteName} • ${userSession.unitName}",
                        fontSize = 12.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = if (userSession.authProvider == AuthProvider.GOOGLE) Color(0xFFE8F0FE) else SitePulseTheme.colors.surfaceMuted,
                        border = BorderStroke(1.dp, if (userSession.authProvider == AuthProvider.GOOGLE) Color(0xFF4285F4) else SitePulseTheme.colors.surfaceBorder)
                    ) {
                        Text(
                            text = "${userSession.authProvider.iconLabel} ${userSession.authProvider.label} (${userSession.email})",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            color = if (userSession.authProvider == AuthProvider.GOOGLE) Color(0xFF1A73E8) else SitePulseTheme.colors.textSecondary,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                        )
                    }
                }
            }

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)

            // 2. Section: Dual Login Methods
            Text(
                text = "GİRİŞ METODLARI (ŞİFRE & GOOGLE CREDENTIALS)",
                fontSize = 11.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textMuted,
                letterSpacing = 0.6.sp
            )

            // Google Sign-In Button
            Surface(
                onClick = onLoginWithGoogle,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                color = SitePulseTheme.colors.surfaceMuted,
                border = BorderStroke(1.dp, Color(0xFF4285F4).copy(alpha = 0.6f))
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(Color.White),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("🌐", fontSize = 20.sp)
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Google ile Giriş Yap",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "Tek tıkla Google hesabı ile şifresiz giriş & hesap eşleme",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                    }
                    Text("→", fontSize = 16.sp, color = Color(0xFF4285F4), fontWeight = FontWeight.Bold)
                }
            }

            // Password Login Button
            Surface(
                onClick = onOpenPasswordAuth,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                color = SitePulseTheme.colors.surfaceMuted,
                border = BorderStroke(1.dp, SitePulseTheme.colors.surfaceBorder)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(SitePulseTheme.colors.avatarBg),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("🔑", fontSize = 18.sp)
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Şifre ile Giriş & Yeni Kayıt",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "E-posta ve şifrenizle giriş yapın veya yeni hesap oluşturun",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                    }
                    Text("→", fontSize = 16.sp, color = SitePulseTheme.colors.textMuted, fontWeight = FontWeight.Bold)
                }
            }

            // 3. Section: Scoped Permissions Breakdown (RBAC + Scoped ABAC)
            Text(
                text = "AKTİF YETKİLER & İZİN KAPSAMI (RBAC + SCOPED ABAC)",
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
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text("🛡️", fontSize = 16.sp)
                        Text(
                            text = "Rol: ${userSession.role.displayName}",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                    }
                    HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.5.dp)

                    userSession.permissions.forEach { perm ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text(
                                text = if (perm.isGranted) "✓" else "🔒",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                color = if (perm.isGranted) Color(0xFF16A34A) else Color(0xFFDC2626)
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = perm.title,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = if (perm.isGranted) SitePulseTheme.colors.textPrimary else SitePulseTheme.colors.textMuted
                                )
                                Text(
                                    text = perm.isolationNote,
                                    fontSize = 10.sp,
                                    color = if (perm.isGranted) SitePulseTheme.colors.textSecondary else Color(0xFFDC2626).copy(alpha = 0.8f)
                                )
                            }
                        }
                    }
                }
            }

            // 4. Section: Demo Role Switcher
            Text(
                text = "KULLANICI ROLÜ GEÇİŞİ (DEMO / TEST)",
                fontSize = 11.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textMuted,
                letterSpacing = 0.6.sp
            )

            ThemeOptionItem(
                icon = "👤",
                title = "Kat Maliki (Ev Sahibi)",
                subtitle = "Ahmet Yılmaz • A Blok D:14 (Tam Daire Yetkisi & Sakin Davet)",
                isSelected = currentRole == UserRole.HOME_OWNER || currentRole == UserRole.RESIDENT,
                onClick = { onRoleChange(UserRole.HOME_OWNER) }
            )

            ThemeOptionItem(
                icon = "🏠",
                title = "Ev Sakini (Aile / Kiracı)",
                subtitle = "Zeynep Yılmaz • A Blok D:14 (Sadece Dairesine Yetkili, Davet Edemez)",
                isSelected = currentRole == UserRole.HOME_RESIDENT,
                onClick = { onRoleChange(UserRole.HOME_RESIDENT) }
            )

            ThemeOptionItem(
                icon = "🏢",
                title = "Site Yöneticisi",
                subtitle = "Mehmet Demir • Begonya Sitesi (Tüm Kompleks & Onay Kuyruğu)",
                isSelected = currentRole == UserRole.SITE_MANAGER,
                onClick = { onRoleChange(UserRole.SITE_MANAGER) }
            )

            ThemeOptionItem(
                icon = "⚡",
                title = "SaaS Süper Yönetici",
                subtitle = "SaaS Platform Admin (Tüm Siteler & Altyapı Yönetimi)",
                isSelected = currentRole == UserRole.SAAS_ADMIN,
                onClick = { onRoleChange(UserRole.SAAS_ADMIN) }
            )

            // 5. Section: Theme Toggle
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
 * Password-Based Authentication Dialog (Login & Register)
 */
@Composable
private fun PasswordAuthDialog(
    onLogin: (String, String) -> Unit,
    onRegister: (String, String, String, String) -> Unit,
    onDismiss: () -> Unit
) {
    var isRegisterMode by remember { mutableStateOf(false) }
    var fullName by remember { mutableStateOf("Ahmet Yılmaz") }
    var email by remember { mutableStateOf("ahmet.yilmaz@gmail.com") }
    var phone by remember { mutableStateOf("0532 111 22 33") }
    var password by remember { mutableStateOf("GucluSifre2026!") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Column {
                Text(
                    text = if (isRegisterMode) "Yeni Hesap Oluştur" else "Şifre ile Giriş Yap",
                    fontWeight = FontWeight.Bold,
                    fontSize = 18.sp
                )
                Text(
                    text = if (isRegisterMode) "SitePulse hesabı oluşturun" else "Kayıtlı e-posta ve şifrenizle oturum açın",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                // Segmented Toggle: Giriş vs Kayıt
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(4.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (!isRegisterMode) MaterialTheme.colorScheme.primary else Color.Transparent)
                            .clickable { isRegisterMode = false }
                            .padding(vertical = 8.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "Giriş Yap",
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp,
                            color = if (!isRegisterMode) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (isRegisterMode) MaterialTheme.colorScheme.primary else Color.Transparent)
                            .clickable { isRegisterMode = true }
                            .padding(vertical = 8.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "Hesap Oluştur",
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp,
                            color = if (isRegisterMode) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                if (isRegisterMode) {
                    OutlinedTextField(
                        value = fullName,
                        onValueChange = { fullName = it },
                        label = { Text("Ad Soyad", fontSize = 12.sp) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true
                    )
                    OutlinedTextField(
                        value = phone,
                        onValueChange = { phone = it },
                        label = { Text("Telefon", fontSize = 12.sp) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true
                    )
                }

                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("E-Posta", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )

                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Şifre", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    if (isRegisterMode) {
                        onRegister(fullName, email, phone, password)
                    } else {
                        onLogin(email, password)
                    }
                },
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary)
            ) {
                Text(if (isRegisterMode) "Kaydet & Oturum Aç" else "Giriş Yap")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Vazgeç")
            }
        }
    )
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

// =========================================================================
// SAAS SUPER ADMIN DASHBOARD & ONBOARDING COMPONENTS
// =========================================================================

@Composable
private fun SaasAdminDashboardContent(
    sites: List<TenantSiteItem>,
    onRegisterNewSiteClick: () -> Unit,
    onProfileClick: () -> Unit,
    onActionClick: (String) -> Unit
) {
    val scrollState = rememberScrollState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp)
    ) {
        // 1. SaaS Top Bar
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                    onClick = { onActionClick("SaaS Menü") },
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(SitePulseTheme.colors.surface)
                        .border(1.dp, SitePulseTheme.colors.surfaceBorder, CircleShape)
                ) {
                    Icon(
                        imageVector = Icons.Default.Menu,
                        contentDescription = "Menü",
                        tint = SitePulseTheme.colors.textPrimary
                    )
                }
                Column {
                    Text(
                        text = "SitePulse SaaS Cloud",
                        fontSize = 17.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Çoklu Site Yönetim Merkezi",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.clickable(onClick = onProfileClick)
            ) {
                Column(horizontalAlignment = Alignment.End) {
                    Text(
                        text = "SaaS Admin",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Platform Yetkilisi",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF6366F1))
                        .border(1.5.dp, Color(0xFF818CF8), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "SA",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                }
            }
        }

        // 2. SaaS Hero KPI Card
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
                verticalArrangement = Arrangement.spacedBy(16.dp)
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
                        Text("⚡", fontSize = 16.sp)
                        Text(
                            text = "SitePulse SaaS Çoklu Tenant",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                    }
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .background(SitePulseTheme.colors.successGreenBg)
                            .padding(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Text(
                            text = "Canlı Sistem",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.successGreen
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column {
                        Text(
                            text = "Kayıtlı Siteler",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                        Text(
                            text = "${sites.size} Site",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                    }
                    Column {
                        Text(
                            text = "Toplam Daire",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                        val totalUnits = sites.sumOf { it.totalUnits }
                        Text(
                            text = "$totalUnits Daire",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                    }
                    Column {
                        Text(
                            text = "Aylık Hacim",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                        Text(
                            text = "₺${sites.size * 80}.000",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                    }
                }

                Button(
                    onClick = onRegisterNewSiteClick,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(48.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF6366F1),
                        contentColor = Color.White
                    )
                ) {
                    Icon(imageVector = Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Yeni Site Kaydet & Yönetici Tanımla", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                }
            }
        }

        // 3. Registered Sites Ledger Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "KAYITLI SİTELER & YÖNETİCİLER",
                fontSize = 12.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textMuted,
                letterSpacing = 0.6.sp
            )
            Text(
                text = "${sites.size} Aktif Site",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = SitePulseTheme.colors.navActive
            )
        }

        // 4. Sites List
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            sites.forEach { site ->
                TenantSiteCard(site = site, onActionClick = onActionClick)
            }
        }
    }
}

@Composable
private fun TenantSiteCard(
    site: TenantSiteItem,
    onActionClick: (String) -> Unit
) {
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
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
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
                            imageVector = Icons.Outlined.LocationCity,
                            contentDescription = null,
                            tint = SitePulseTheme.colors.textPrimary,
                            modifier = Modifier.size(20.dp)
                        )
                    }
                    Column {
                        Text(
                            text = site.name,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "${site.city} • ${site.totalUnits} Daire",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                    }
                }

                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (site.planType == "PREMIUM") Color(0xFFFEF3C7) else SitePulseTheme.colors.surfaceMuted)
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                ) {
                    Text(
                        text = site.planType,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (site.planType == "PREMIUM") Color(0xFFD97706) else SitePulseTheme.colors.textPrimary
                    )
                }
            }

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.6.dp)

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "Site Yöneticisi:",
                        fontSize = 10.sp,
                        color = SitePulseTheme.colors.textMuted
                    )
                    Text(
                        text = site.adminName,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = site.adminEmail,
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }

                OutlinedButton(
                    onClick = { onActionClick("Yöneticiyi Ara: ${site.adminPhone}") },
                    shape = RoundedCornerShape(10.dp),
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
                    border = BorderStroke(1.dp, SitePulseTheme.colors.surfaceBorder)
                ) {
                    Icon(imageVector = Icons.Outlined.Phone, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("İletişim", fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RegisterSiteModalBottomSheet(
    onRegister: (name: String, city: String, address: String, adminName: String, adminEmail: String, adminPhone: String, plan: String) -> Unit,
    onDismiss: () -> Unit
) {
    var siteName by remember { mutableStateOf("Palmiye Evleri Sitesi") }
    var city by remember { mutableStateOf("İstanbul") }
    var address by remember { mutableStateOf("Atatürk Mah. Orkide Sok. No:12") }
    var adminName by remember { mutableStateOf("Ahmet Can") }
    var adminEmail by remember { mutableStateOf("ahmet.can@palmiyesitesi.com") }
    var adminPhone by remember { mutableStateOf("+90 532 555 0199") }
    var planType by remember { mutableStateOf("PREMIUM") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SitePulseTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SitePulseTheme.colors.textMuted.copy(alpha = 0.4f)) },
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF6366F1)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(imageVector = Icons.Default.Add, contentDescription = null, tint = Color.White)
                }
                Column {
                    Text(
                        text = "Yeni Site & Yönetici Kaydı",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Satış sonrası yeni site tanımlama ve yönetici hesabı oluşturma",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            OutlinedTextField(
                value = siteName,
                onValueChange = { siteName = it },
                label = { Text("Site Adı") },
                placeholder = { Text("Örn: Palmiye Evleri Sitesi") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = city,
                    onValueChange = { city = it },
                    label = { Text("Şehir") },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp)
                )
                OutlinedTextField(
                    value = planType,
                    onValueChange = { planType = it },
                    label = { Text("Paket (STANDARD/PREMIUM)") },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp)
                )
            }

            OutlinedTextField(
                value = address,
                onValueChange = { address = it },
                label = { Text("Açık Adres") },
                placeholder = { Text("Örn: Atatürk Mah. Orkide Sok. No:12") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)

            Text(
                text = "İLK SİTE YÖNETİCİSİ BİLGİLERİ",
                fontSize = 11.sp,
                fontWeight = FontWeight.ExtraBold,
                color = SitePulseTheme.colors.textMuted
            )

            OutlinedTextField(
                value = adminName,
                onValueChange = { adminName = it },
                label = { Text("Yönetici Adı Soyadı") },
                placeholder = { Text("Örn: Ayşe Çelik") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )

            OutlinedTextField(
                value = adminEmail,
                onValueChange = { adminEmail = it },
                label = { Text("Yönetici E-Posta") },
                placeholder = { Text("Örn: ayse@palmiyeevleri.com") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )

            OutlinedTextField(
                value = adminPhone,
                onValueChange = { adminPhone = it },
                label = { Text("Yönetici Telefon") },
                placeholder = { Text("+90 532 555 0100") },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            )

            Button(
                onClick = {
                    if (siteName.isNotBlank() && adminName.isNotBlank() && adminEmail.isNotBlank()) {
                        onRegister(siteName, city, address, adminName, adminEmail, adminPhone, planType)
                        onDismiss()
                    }
                },
                enabled = siteName.isNotBlank() && adminName.isNotBlank() && adminEmail.isNotBlank(),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color(0xFF6366F1),
                    contentColor = Color.White
                )
            ) {
                Text("Siteyi Kaydet & Şifre Üret ⚡", fontWeight = FontWeight.Bold, fontSize = 14.sp)
            }
        }
    }
}

@Composable
private fun ProvisionedCredentialsDialog(
    creds: ProvisionedSiteCredentials,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            Button(
                onClick = onDismiss,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SitePulseTheme.colors.primaryDark,
                    contentColor = SitePulseTheme.colors.buttonPrimaryText
                )
            ) {
                Text("Tamam (Kopyalandı & Kaydedildi)", fontWeight = FontWeight.Bold)
            }
        },
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("🎉", fontSize = 20.sp)
                Text(
                    text = "Site & Yönetici Oluşturuldu",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textPrimary
                )
            }
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "${creds.siteName} başarıyla SaaS platformuna kaydedildi. İlk yönetici hesabı oluşturuldu.",
                    fontSize = 12.sp,
                    color = SitePulseTheme.colors.textSecondary
                )

                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .border(1.dp, Color(0xFF818CF8), RoundedCornerShape(14.dp)),
                    colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surfaceMuted),
                    shape = RoundedCornerShape(14.dp)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = "YÖNETİCİ GİRİŞ BİLGİLERİ",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = Color(0xFF6366F1)
                        )
                        Text(
                            text = "Yönetici: ${creds.adminName}",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "E-Posta: ${creds.adminEmail}",
                            fontSize = 12.sp,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.6.dp)
                        Text(
                            text = "Geçici Giriş Şifresi:",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                        Text(
                            text = creds.temporaryPassword,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = Color(0xFF0284C7),
                            letterSpacing = 1.sp
                        )
                    }
                }

                Text(
                    text = "⚠ Not: Yönetici bu geçici şifre ile ilk girişinde yeni şifre belirleyecektir.",
                    fontSize = 11.sp,
                    color = SitePulseTheme.colors.textMuted
                )
            }
        },
        containerColor = SitePulseTheme.colors.surface,
        shape = RoundedCornerShape(20.dp)
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddHomeOwnerModalBottomSheet(
    onDismiss: () -> Unit,
    onSubmit: (String, Int, String, String, String, java.math.BigDecimal, Boolean) -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var block by remember { mutableStateOf("B Blok") }
    var unitNoText by remember { mutableStateOf("16") }
    var floorText by remember { mutableStateOf("4") }
    var ownerName by remember { mutableStateOf("Zeynep Çelik") }
    var email by remember { mutableStateOf("zeynep.celik@gmail.com") }
    var phone by remember { mutableStateOf("0532 987 65 43") }
    var isResident by remember { mutableStateOf(true) }
    var duesAmountText by remember { mutableStateOf("1400.00") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SitePulseTheme.colors.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF0284C7).copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Outlined.PersonAdd,
                        contentDescription = null,
                        tint = Color(0xFF0284C7),
                        modifier = Modifier.size(22.dp)
                    )
                }
                Column {
                    Text(
                        text = "Yeni Kat Maliki (Ev Sahibi) Ekle",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Begonya Sitesi kütüğüne daire & malik kaydı",
                        fontSize = 12.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)

            // Blok Seçimi
            Text(
                text = "BLOK SEÇİMİ",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = SitePulseTheme.colors.textSecondary
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                listOf("A Blok", "B Blok", "C Blok").forEach { b ->
                    FilterChip(
                        selected = block == b,
                        onClick = { block = b },
                        label = { Text(b) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = Color(0xFF0284C7),
                            selectedLabelColor = Color.White
                        )
                    )
                }
            }

            // Daire No & Kat
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedTextField(
                    value = unitNoText,
                    onValueChange = { unitNoText = it },
                    label = { Text("Daire No") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color(0xFF0284C7),
                        unfocusedBorderColor = SitePulseTheme.colors.surfaceBorder
                    )
                )
                OutlinedTextField(
                    value = floorText,
                    onValueChange = { floorText = it },
                    label = { Text("Bulunduğu Kat") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color(0xFF0284C7),
                        unfocusedBorderColor = SitePulseTheme.colors.surfaceBorder
                    )
                )
            }

            // Kat Maliki Ad Soyad
            OutlinedTextField(
                value = ownerName,
                onValueChange = { ownerName = it },
                label = { Text("Kat Maliki Adı Soyadı") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color(0xFF0284C7),
                    unfocusedBorderColor = SitePulseTheme.colors.surfaceBorder
                )
            )

            // İletişim E-Posta
            OutlinedTextField(
                value = email,
                onValueChange = { email = it },
                label = { Text("İletişim E-Posta (Sakin Girişi)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color(0xFF0284C7),
                    unfocusedBorderColor = SitePulseTheme.colors.surfaceBorder
                )
            )

            // Telefon
            OutlinedTextField(
                value = phone,
                onValueChange = { phone = it },
                label = { Text("Telefon Numarası") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color(0xFF0284C7),
                    unfocusedBorderColor = SitePulseTheme.colors.surfaceBorder
                )
            )

            // İkamet Durumu
            Text(
                text = "İKAMET DURUMU",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = SitePulseTheme.colors.textSecondary
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                FilterChip(
                    selected = isResident,
                    onClick = { isResident = true },
                    label = { Text("Malik Kendisi Oturuyor") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color(0xFF0284C7),
                        selectedLabelColor = Color.White
                    )
                )
                FilterChip(
                    selected = !isResident,
                    onClick = { isResident = false },
                    label = { Text("Kiracıda") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color(0xFF0284C7),
                        selectedLabelColor = Color.White
                    )
                )
            }

            // Aylık Aidat Tutarı
            OutlinedTextField(
                value = duesAmountText,
                onValueChange = { duesAmountText = it },
                label = { Text("Aylık Aidat Tutarı (TL)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color(0xFF0284C7),
                    unfocusedBorderColor = SitePulseTheme.colors.surfaceBorder
                )
            )

            Spacer(modifier = Modifier.height(6.dp))

            // Actions
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedButton(
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text("İptal")
                }
                Button(
                    onClick = {
                        val parsedUnit = unitNoText.toIntOrNull() ?: 16
                        val parsedDues = duesAmountText.toBigDecimalOrNull() ?: java.math.BigDecimal("1400.00")
                        onSubmit(block, parsedUnit, ownerName, email, phone, parsedDues, isResident)
                    },
                    modifier = Modifier.weight(1.5f),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF0284C7),
                        contentColor = Color.White
                    )
                ) {
                    Text("Kaydet & Şifre Üret ⚡", fontWeight = FontWeight.Bold)
                }
            }

            Spacer(modifier = Modifier.height(24.dp))
        }
    }
}

@Composable
private fun ProvisionedHomeOwnerDialog(
    creds: ProvisionedHomeOwnerCredentials,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            Button(
                onClick = onDismiss,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color(0xFF0284C7),
                    contentColor = Color.White
                )
            ) {
                Text("Tamam (Kopyalandı & Bildirildi)", fontWeight = FontWeight.Bold)
            }
        },
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("🎉", fontSize = 20.sp)
                Text(
                    text = "Kat Maliki & Daire Kaydedildi",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textPrimary
                )
            }
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "${creds.block} D:${creds.unitNo} başarıyla site kütüğüne kaydedildi. Sakin mobil portal hesabı oluşturuldu.",
                    fontSize = 12.sp,
                    color = SitePulseTheme.colors.textSecondary
                )

                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .border(1.dp, Color(0xFF38BDF8), RoundedCornerShape(14.dp)),
                    colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surfaceMuted),
                    shape = RoundedCornerShape(14.dp)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = "SAKİN GİRİŞ BİLGİLERİ",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = Color(0xFF0284C7)
                        )
                        Text(
                            text = "Kat Maliki: ${creds.ownerName}",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "Daire: ${creds.block} No:${creds.unitNo} (${if (creds.isResident) "Malik Oturuyor" else "Kiracıda"})",
                            fontSize = 12.sp,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "E-Posta: ${creds.email}",
                            fontSize = 12.sp,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "Aylık Aidat: ₺${creds.duesAmount}",
                            fontSize = 12.sp,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.6.dp)
                        Text(
                            text = "Geçici Sakin Giriş Şifresi:",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                        Text(
                            text = creds.temporaryPassword,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = Color(0xFF0284C7),
                            letterSpacing = 1.sp
                        )
                    }
                }

                Text(
                    text = "⚠️ Not: Sakin bu geçici şifre ile ilk girişinde kendi kalıcı şifresini belirleyecektir.",
                    fontSize = 11.sp,
                    color = SitePulseTheme.colors.textMuted
                )
            }
        },
        containerColor = SitePulseTheme.colors.surface,
        shape = RoundedCornerShape(20.dp)
    )
}

@Composable
private fun PendingRegistrationCard(
    item: RegistrationRequestItem,
    onApprove: () -> Unit,
    onReject: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
        border = BorderStroke(1.dp, Color(0xFFEF4444).copy(alpha = 0.25f))
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
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
                            .background(Color(0xFFEF4444).copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = item.block.take(1) + item.unitNo,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color(0xFFDC2626)
                        )
                    }
                    Column {
                        Text(
                            text = item.fullName,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "${item.flatDesc} • Kat ${item.floor} (${if (item.isResident) "Ev Sahibi" else "Kiracı"})",
                            fontSize = 12.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                    }
                }
                Surface(
                    color = Color(0xFFF59E0B).copy(alpha = 0.15f),
                    shape = RoundedCornerShape(6.dp)
                ) {
                    Text(
                        text = item.timeAgoStr,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color(0xFFD97706),
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
            }

            Text(
                text = "İletişim: ${item.email} • ${item.phone}",
                fontSize = 11.sp,
                color = SitePulseTheme.colors.textMuted
            )

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.6.dp)

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedButton(
                    onClick = onReject,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Color(0xFFDC2626)),
                    border = BorderStroke(1.dp, Color(0xFFDC2626).copy(alpha = 0.4f))
                ) {
                    Text("Reddet", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                Button(
                    onClick = onApprove,
                    modifier = Modifier.weight(1.5f),
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF10B981),
                        contentColor = Color.White
                    )
                ) {
                    Icon(
                        imageVector = Icons.Default.Check,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Onayla & Şifre Üret", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InviteLinkModalBottomSheet(
    invitationUrl: String,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var copied by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SitePulseTheme.colors.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF10B981).copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Share,
                        contentDescription = null,
                        tint = Color(0xFF10B981),
                        modifier = Modifier.size(22.dp)
                    )
                }
                Column {
                    Text(
                        text = "Site Sakini Davet Linki",
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "Kat malikleri ve sakinlerin online başvuru bağlantısı",
                        fontSize = 12.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)

            Text(
                text = "Bu bağlantıyı WhatsApp site grubunda veya SMS ile kat maliklerine gönderin. Kat malikleri linke tıklayarak daire ve iletişim bilgilerini ilettiklerinde başvuruları doğrudan Yönetici Onay Kuyruğuna iletilecektir.",
                fontSize = 12.sp,
                color = SitePulseTheme.colors.textSecondary,
                lineHeight = 18.sp
            )

            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surfaceMuted),
                border = BorderStroke(1.dp, Color(0xFF10B981).copy(alpha = 0.35f))
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = "ÖZEL KAYIT BAĞLANTISI",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = Color(0xFF10B981)
                    )
                    Text(
                        text = invitationUrl,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "⏳ Bağlantı 7 gün boyunca geçerlidir (Güvenli Tokenli)",
                        fontSize = 10.sp,
                        color = SitePulseTheme.colors.textMuted
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedButton(
                    onClick = { copied = true },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = if (copied) Color(0xFF10B981) else SitePulseTheme.colors.textPrimary
                    )
                ) {
                    Text(if (copied) "✓ Kopyalandı!" else "Linki Kopyala", fontWeight = FontWeight.Bold)
                }
                Button(
                    onClick = { copied = true },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF25D366),
                        contentColor = Color.White
                    )
                ) {
                    Text("WhatsApp Paylaş", fontWeight = FontWeight.Bold)
                }
            }

            Button(
                onClick = onDismiss,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SitePulseTheme.colors.primaryDark,
                    contentColor = SitePulseTheme.colors.buttonPrimaryText
                )
            ) {
                Text("Kapat", fontWeight = FontWeight.Bold)
            }

            Spacer(modifier = Modifier.height(20.dp))
        }
    }
}

@Composable
private fun RegistrationApprovedDialog(
    info: ApprovalSuccessInfo,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            Button(
                onClick = onDismiss,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color(0xFF10B981),
                    contentColor = Color.White
                )
            ) {
                Text("Tamam (Kütüğe Eklendi)", fontWeight = FontWeight.Bold)
            }
        },
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text("🎉", fontSize = 20.sp)
                Text(
                    text = "Başvuru Onaylandı & Hesap Açıldı",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = SitePulseTheme.colors.textPrimary
                )
            }
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "${info.fullName} (${info.flatDesc}) başvurusu başarıyla onaylandı ve site aidat kütüğüne işlendi.",
                    fontSize = 12.sp,
                    color = SitePulseTheme.colors.textSecondary
                )

                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .border(1.dp, Color(0xFF34D399), RoundedCornerShape(14.dp)),
                    colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surfaceMuted),
                    shape = RoundedCornerShape(14.dp)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = "SAKİN GİRİŞ HESAP BİLGİLERİ",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = Color(0xFF10B981)
                        )
                        Text(
                            text = "Kat Maliki: ${info.fullName}",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "Daire: ${info.flatDesc}",
                            fontSize = 12.sp,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        Text(
                            text = "E-Posta: ${info.email}",
                            fontSize = 12.sp,
                            color = SitePulseTheme.colors.textPrimary
                        )
                        HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.6.dp)
                        Text(
                            text = "Üretilen Giriş Şifresi:",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                        Text(
                            text = info.temporaryPassword,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = Color(0xFF0284C7),
                            letterSpacing = 1.sp
                        )
                    }
                }

                Text(
                    text = "✓ Sakine SMS ve E-posta ile giriş aktivasyon şifresi otomatik olarak iletilmiştir.",
                    fontSize = 11.sp,
                    color = Color(0xFF059669)
                )
            }
        },
        containerColor = SitePulseTheme.colors.surface,
        shape = RoundedCornerShape(20.dp)
    )
}

/**
 * Household members living in this specific flat with unit-scoped access.
 */
@Composable
private fun HouseholdMembersCard(
    unitLabel: String,
    members: List<UnitResidentMember>,
    onInviteClick: () -> Unit,
    onAddMemberDemoClick: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = SitePulseTheme.colors.surface),
        border = BorderStroke(1.dp, SitePulseTheme.colors.surfaceBorder)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Security badge
            Surface(
                color = Color(0xFF0284C7).copy(alpha = 0.08f),
                shape = RoundedCornerShape(8.dp),
                border = BorderStroke(0.8.dp, Color(0xFF0284C7).copy(alpha = 0.25f))
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Lock,
                        contentDescription = "Yetki Kapsamı",
                        tint = Color(0xFF0284C7),
                        modifier = Modifier.size(14.dp)
                    )
                    Text(
                        text = "Yetki Sınırı: Sadece $unitLabel (İzole Daire Erişimi)",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color(0xFF0284C7)
                    )
                }
            }

            // Member list
            members.forEach { member ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .background(
                                if (member.isOwner) Color(0xFF3B82F6).copy(alpha = 0.15f)
                                else Color(0xFF10B981).copy(alpha = 0.15f)
                            ),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = member.fullName.split(" ").mapNotNull { it.firstOrNull()?.toString() }.take(2).joinToString(""),
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = if (member.isOwner) Color(0xFF2563EB) else Color(0xFF059669)
                        )
                    }

                    Column(modifier = Modifier.weight(1f)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Text(
                                text = member.fullName,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Bold,
                                color = SitePulseTheme.colors.textPrimary
                            )
                            Surface(
                                color = if (member.isOwner) Color(0xFF2563EB).copy(alpha = 0.1f) else Color(0xFF10B981).copy(alpha = 0.1f),
                                shape = RoundedCornerShape(6.dp)
                            ) {
                                Text(
                                    text = member.relationship,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = if (member.isOwner) Color(0xFF2563EB) else Color(0xFF059669),
                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                )
                            }
                        }
                        Text(
                            text = "Yetki: ${member.permissionScope} • ${member.phone}",
                            fontSize = 11.sp,
                            color = SitePulseTheme.colors.textSecondary
                        )
                    }
                }
            }

            HorizontalDivider(color = SitePulseTheme.colors.surfaceBorder, thickness = 0.8.dp)

            // Action row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Button(
                    onClick = onInviteClick,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF0284C7)),
                    shape = RoundedCornerShape(10.dp),
                    contentPadding = PaddingValues(vertical = 10.dp)
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Share,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(text = "Davet Linki", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }

                OutlinedButton(
                    onClick = onAddMemberDemoClick,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(10.dp),
                    border = BorderStroke(1.dp, Color(0xFF0284C7)),
                    contentPadding = PaddingValues(vertical = 10.dp)
                ) {
                    Icon(
                        imageVector = Icons.Outlined.PersonAdd,
                        contentDescription = null,
                        tint = Color(0xFF0284C7),
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(text = "Hızlı Ekle", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color(0xFF0284C7))
                }
            }
        }
    }
}

/**
 * Modal bottom sheet for home owner unit-scoped invitation link.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeResidentInviteBottomSheet(
    inviteInfo: UnitInviteInfo,
    onDismiss: () -> Unit,
    onOpenAddMemberDemo: () -> Unit
) {
    var copied by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SitePulseTheme.colors.surface,
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(46.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF0284C7).copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Outlined.GroupAdd,
                        contentDescription = "Davet Linki",
                        tint = Color(0xFF0284C7),
                        modifier = Modifier.size(24.dp)
                    )
                }
                Column {
                    Text(
                        text = "Ev Sakini Davet Linki",
                        fontSize = 17.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "${inviteInfo.unitLabel} için aile veya sakin davet bağlantısı",
                        fontSize = 12.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            // Security isolation notice
            Surface(
                color = Color(0xFF0284C7).copy(alpha = 0.08f),
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(1.dp, Color(0xFF0284C7).copy(alpha = 0.3f))
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Lock,
                            contentDescription = "Güvenlik İzolasyonu",
                            tint = Color(0xFF0284C7),
                            modifier = Modifier.size(16.dp)
                        )
                        Text(
                            text = "İZOLASYON & YETKİ KAPSAMI",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = Color(0xFF0284C7)
                        )
                    }
                    Text(
                        text = "Bu link sadece ${inviteInfo.unitLabel} bağımsız bölümüne erişim yetkisi verir. Kaydolan kişi yalnızca bu dairenin aidatlarını görebilir ve talep açabilir. Diğer daire veya yönetim yetkileri kapalıdır.",
                        fontSize = 12.sp,
                        color = SitePulseTheme.colors.textPrimary,
                        lineHeight = 17.sp
                    )
                }
            }

            // Invite link box
            Surface(
                color = SitePulseTheme.colors.background,
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(1.dp, SitePulseTheme.colors.surfaceBorder)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = "DAİREYE ÖZEL KAYIT BAĞLANTISI",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color(0xFF0284C7),
                        letterSpacing = 0.5.sp
                    )
                    Text(
                        text = inviteInfo.inviteUrl,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary,
                        maxLines = 2
                    )
                    Text(
                        text = "⌛ ${inviteInfo.expiresAtStr} (Daire Tokeni: ${inviteInfo.token})",
                        fontSize = 11.sp,
                        color = SitePulseTheme.colors.textSecondary
                    )
                }
            }

            // Copy & WhatsApp buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedButton(
                    onClick = { copied = true },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, if (copied) Color(0xFF10B981) else Color(0xFF0284C7))
                ) {
                    Icon(
                        imageVector = if (copied) Icons.Default.Check else Icons.Outlined.ContentCopy,
                        contentDescription = null,
                        tint = if (copied) Color(0xFF10B981) else Color(0xFF0284C7),
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = if (copied) "Kopyalandı!" else "Linki Kopyala",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (copied) Color(0xFF10B981) else Color(0xFF0284C7)
                    )
                }

                Button(
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF25D366)),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Share,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(text = "WhatsApp Paylaş", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.White)
                }
            }

            // Quick add member demo button
            OutlinedButton(
                onClick = onOpenAddMemberDemo,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(1.dp, SitePulseTheme.colors.surfaceBorder)
            ) {
                Icon(
                    imageVector = Icons.Outlined.PersonAdd,
                    contentDescription = null,
                    tint = SitePulseTheme.colors.textPrimary,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = "Hızlı Sakin Ekle (Test Formu)",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = SitePulseTheme.colors.textPrimary
                )
            }

            Button(
                onClick = onDismiss,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = SitePulseTheme.colors.surfaceBorder),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text(text = "Kapat", color = SitePulseTheme.colors.textPrimary, fontWeight = FontWeight.Bold)
            }

            Spacer(modifier = Modifier.height(8.dp))
        }
    }
}

/**
 * Dialog to simulate adding a household resident for this unit.
 */
@Composable
private fun AddHouseholdMemberDialog(
    unitLabel: String,
    onDismiss: () -> Unit,
    onSubmit: (String, String, String, String) -> Unit
) {
    var name by remember { mutableStateOf("Zeynep Yılmaz") }
    var phone by remember { mutableStateOf("0532 999 88 77") }
    var email by remember { mutableStateOf("zeynep.yilmaz@gmail.com") }
    var relationship by remember { mutableStateOf("Eş / Sakin") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(text = "👨‍👩‍👧", fontSize = 22.sp)
                Column {
                    Text(
                        text = "Yeni Ev Sakini Tanımla",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = SitePulseTheme.colors.textPrimary
                    )
                    Text(
                        text = "$unitLabel Hanesine Bağlanıyor",
                        fontSize = 11.sp,
                        color = Color(0xFF0284C7)
                    )
                }
            }
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "🔒 Yetki Kapsamı: Bu kullanıcı sadece $unitLabel dairesinin aidat ve duyurularına erişebilir.",
                    fontSize = 11.sp,
                    color = Color(0xFF0284C7)
                )

                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Ad Soyad") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )

                OutlinedTextField(
                    value = relationship,
                    onValueChange = { relationship = it },
                    label = { Text("Yakınlık (Eş, Çocuk, Kiracı vb.)") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )

                OutlinedTextField(
                    value = phone,
                    onValueChange = { phone = it },
                    label = { Text("Telefon") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )

                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("E-Posta") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { onSubmit(name, phone, email, relationship) },
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF0284C7)),
                shape = RoundedCornerShape(10.dp)
            ) {
                Text("Kaydet & Daireye Bağla", fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Vazgeç", color = SitePulseTheme.colors.textSecondary)
            }
        },
        containerColor = SitePulseTheme.colors.surface,
        shape = RoundedCornerShape(18.dp)
    )
}




