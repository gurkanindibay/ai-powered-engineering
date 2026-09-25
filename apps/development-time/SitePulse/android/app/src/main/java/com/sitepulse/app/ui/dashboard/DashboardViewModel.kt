package com.sitepulse.app.ui.dashboard

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.sitepulse.app.domain.model.*
import com.sitepulse.app.domain.usecase.CalculateDuesUseCase
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.math.BigDecimal
import java.time.LocalDate
import java.util.UUID

import com.sitepulse.app.data.local.DuesCacheEntity
import com.sitepulse.app.data.repository.ResidentRepository
import java.time.LocalDateTime

class DashboardViewModel(
    private val calculateDuesUseCase: CalculateDuesUseCase = CalculateDuesUseCase(),
    private val residentRepository: ResidentRepository = ResidentRepository()
) : ViewModel() {

    private val _uiState = MutableStateFlow<DashboardUiState>(DashboardUiState.Loading)
    val uiState: StateFlow<DashboardUiState> = _uiState.asStateFlow()

    // Offline caching & synchronization state (STORY-01-06 / task-08)
    private val _isOffline = MutableStateFlow(false)
    val isOffline: StateFlow<Boolean> = _isOffline.asStateFlow()

    private val _lastSyncTime = MutableStateFlow("Az önce")
    val lastSyncTime: StateFlow<String> = _lastSyncTime.asStateFlow()

    // Role state: RESIDENT (default) or SITE_MANAGER
    private val _userRole = MutableStateFlow(UserRole.RESIDENT)
    val userRole: StateFlow<UserRole> = _userRole.asStateFlow()

    // Manager state: Collection summary (80% collected, 18 paid / 6 overdue)
    private val _collectionSummary = MutableStateFlow(ComplexCollectionSummary())
    val collectionSummary: StateFlow<ComplexCollectionSummary> = _collectionSummary.asStateFlow()

    // Manager state: Flat payment ledger
    private val _flatsList = MutableStateFlow<List<FlatPaymentStatus>>(emptyList())
    val flatsList: StateFlow<List<FlatPaymentStatus>> = _flatsList.asStateFlow()

    // Flat filter: "ALL", "OVERDUE", "PAID"
    private val _flatFilter = MutableStateFlow("ALL")
    val flatFilter: StateFlow<String> = _flatFilter.asStateFlow()

    // Announcements state
    private val _announcements = MutableStateFlow<List<SiteAnnouncement>>(emptyList())
    val announcements: StateFlow<List<SiteAnnouncement>> = _announcements.asStateFlow()

    // Direct messages sent
    private val _directMessages = MutableStateFlow<List<FlatDirectMessage>>(emptyList())
    val directMessages: StateFlow<List<FlatDirectMessage>> = _directMessages.asStateFlow()

    // SaaS Multi-Tenancy State
    private val _saasSites = MutableStateFlow<List<TenantSiteItem>>(emptyList())
    val saasSites: StateFlow<List<TenantSiteItem>> = _saasSites.asStateFlow()

    private val _provisionedCredentials = MutableStateFlow<ProvisionedSiteCredentials?>(null)
    val provisionedCredentials: StateFlow<ProvisionedSiteCredentials?> = _provisionedCredentials.asStateFlow()

    // Site Admin: Provisioned Home Owner State
    private val _provisionedHomeOwner = MutableStateFlow<ProvisionedHomeOwnerCredentials?>(null)
    val provisionedHomeOwner: StateFlow<ProvisionedHomeOwnerCredentials?> = _provisionedHomeOwner.asStateFlow()

    // Self-Registration via Invitation Link & Approval Queue
    private val _pendingRegistrations = MutableStateFlow<List<RegistrationRequestItem>>(emptyList())
    val pendingRegistrations: StateFlow<List<RegistrationRequestItem>> = _pendingRegistrations.asStateFlow()

    private val _approvalSuccessInfo = MutableStateFlow<ApprovalSuccessInfo?>(null)
    val approvalSuccessInfo: StateFlow<ApprovalSuccessInfo?> = _approvalSuccessInfo.asStateFlow()

    val invitationUrl: String = "https://sitepulse.app/join/begonya-sitesi?token=SP-INV-8912"

    // Home Owner: Unit-Scoped Household Residents & Invite Link
    private val _unitResidents = MutableStateFlow<List<UnitResidentMember>>(emptyList())
    val unitResidents: StateFlow<List<UnitResidentMember>> = _unitResidents.asStateFlow()

    private val _unitInviteInfo = MutableStateFlow<UnitInviteInfo?>(null)
    val unitInviteInfo: StateFlow<UnitInviteInfo?> = _unitInviteInfo.asStateFlow()

    // Authentication & Scoped Permission Model State
    private val _userSession = MutableStateFlow(createSession(UserRole.HOME_OWNER, AuthProvider.LOCAL))
    val userSession: StateFlow<UserSession> = _userSession.asStateFlow()

    private val _authMessage = MutableStateFlow<String?>(null)
    val authMessage: StateFlow<String?> = _authMessage.asStateFlow()

    init {
        loadDashboard()
        loadManagerData()
        loadSaasData()
        loadUnitResidentData()
    }


    fun registerNewSite(
        name: String,
        city: String,
        address: String,
        adminName: String,
        adminEmail: String,
        adminPhone: String,
        planType: String = "STANDARD"
    ) {
        val siteId = "site-${System.currentTimeMillis().toString().takeLast(6)}"
        val chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val p1 = (1..4).map { chars.random() }.joinToString("")
        val p2 = (1..4).map { chars.random() }.joinToString("")
        val tempPassword = "SP-$p1-$p2"

        val newSite = TenantSiteItem(
            id = siteId,
            name = name,
            city = city,
            address = address,
            status = "ACTIVE",
            planType = planType,
            totalUnits = 20,
            monthlyCollectionVolume = BigDecimal("80000.00"),
            adminName = adminName,
            adminEmail = adminEmail,
            adminPhone = adminPhone
        )

        _saasSites.value = listOf(newSite) + _saasSites.value
        _provisionedCredentials.value = ProvisionedSiteCredentials(
            siteId = siteId,
            siteName = name,
            adminName = adminName,
            adminEmail = adminEmail,
            temporaryPassword = tempPassword,
            planType = planType
        )
    }

    fun clearProvisionedCredentials() {
        _provisionedCredentials.value = null
    }

    fun registerHomeOwner(
        block: String,
        unitNo: Int,
        ownerName: String,
        email: String,
        phone: String,
        duesAmount: BigDecimal = BigDecimal("1400.00"),
        isResident: Boolean = true
    ) {
        val chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val code = (1..4).map { chars.random() }.joinToString("")
        val tempPassword = "SP-SAKIN-$code"

        val cleanBlock = block.replace("Blok", "").trim()
        val newFlat = FlatPaymentStatus(
            id = UUID.randomUUID().toString(),
            block = cleanBlock,
            unitNo = unitNo,
            residentName = ownerName,
            amountDue = duesAmount,
            daysOverdue = 0,
            isPaid = false
        )

        _flatsList.value = listOf(newFlat) + _flatsList.value

        // Dynamically increment total complex units
        val curr = _collectionSummary.value
        _collectionSummary.value = curr.copy(
            totalUnitsCount = curr.totalUnitsCount + 1,
            overdueUnitsCount = curr.overdueUnitsCount + 1,
            totalExpected = curr.totalExpected.add(duesAmount)
        )

        _provisionedHomeOwner.value = ProvisionedHomeOwnerCredentials(
            block = block,
            unitNo = unitNo,
            ownerName = ownerName,
            email = email,
            phone = phone,
            temporaryPassword = tempPassword,
            isResident = isResident,
            duesAmount = duesAmount
        )
    }

    fun clearProvisionedHomeOwner() {
        _provisionedHomeOwner.value = null
    }

    fun approveRegistration(requestId: String) {
        val target = _pendingRegistrations.value.find { it.id == requestId } ?: return
        val chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val code = (1..4).map { chars.random() }.joinToString("")
        val tempPassword = "SP-SAKIN-$code"

        _pendingRegistrations.value = _pendingRegistrations.value.filter { it.id != requestId }

        val cleanBlock = target.block.replace("Blok", "").trim()
        val newFlat = FlatPaymentStatus(
            id = UUID.randomUUID().toString(),
            block = cleanBlock,
            unitNo = target.unitNo,
            residentName = target.fullName,
            amountDue = target.duesAmount,
            daysOverdue = 0,
            isPaid = false
        )
        _flatsList.value = listOf(newFlat) + _flatsList.value

        val curr = _collectionSummary.value
        _collectionSummary.value = curr.copy(
            totalUnitsCount = curr.totalUnitsCount + 1,
            overdueUnitsCount = curr.overdueUnitsCount + 1,
            totalExpected = curr.totalExpected.add(target.duesAmount)
        )

        _approvalSuccessInfo.value = ApprovalSuccessInfo(
            fullName = target.fullName,
            flatDesc = target.flatDesc,
            email = target.email,
            temporaryPassword = tempPassword
        )
    }

    fun rejectRegistration(requestId: String) {
        _pendingRegistrations.value = _pendingRegistrations.value.filter { it.id != requestId }
    }

    fun clearApprovalSuccess() {
        _approvalSuccessInfo.value = null
    }


    private fun loadSaasData() {
        _saasSites.value = listOf(
            TenantSiteItem(
                id = "site-1",
                name = "Begonya Sitesi",
                city = "İstanbul",
                address = "Ataşehir, Begonya Sok. No:14",
                status = "ACTIVE",
                planType = "PREMIUM",
                totalUnits = 24,
                monthlyCollectionVolume = BigDecimal("96000.00"),
                adminName = "Mehmet Demir",
                adminEmail = "mehmet.demir@begonya.com",
                adminPhone = "+90 532 100 2030"
            ),
            TenantSiteItem(
                id = "site-2",
                name = "Kardelen Rezidans",
                city = "Ankara",
                address = "Çankaya, Kardelen Cad. No:8",
                status = "ACTIVE",
                planType = "STANDARD",
                totalUnits = 36,
                monthlyCollectionVolume = BigDecimal("144000.00"),
                adminName = "Selin Vural",
                adminEmail = "selin@kardelenrezidans.com",
                adminPhone = "+90 533 222 4050"
            )
        )
    }

    fun switchRole(role: UserRole) {
        _userRole.value = role
    }

    fun setFlatFilter(filter: String) {
        _flatFilter.value = filter
    }

    fun publishAnnouncement(title: String, category: String, body: String) {
        val newAnc = SiteAnnouncement(
            id = "anc-${System.currentTimeMillis()}",
            title = title,
            category = category,
            body = body,
            timestamp = "Şimdi"
        )
        _announcements.value = listOf(newAnc) + _announcements.value
    }

    fun sendDirectMessage(targetFlatDesc: String, messageType: String, content: String) {
        val newMsg = FlatDirectMessage(
            id = "msg-${System.currentTimeMillis()}",
            targetFlatDesc = targetFlatDesc,
            messageType = messageType,
            content = content,
            timestamp = "Şimdi"
        )
        _directMessages.value = listOf(newMsg) + _directMessages.value
    }

    fun loadDashboard(forceOffline: Boolean = false) {
        viewModelScope.launch {
            val daire = Daire(
                id = "d-14",
                siteAdi = "Begonya Sitesi",
                blok = "A",
                daireNo = 14,
                kat = 4,
                arsaPayi = 24,
                malikAdi = "Ahmet Yılmaz",
                kiraciAdi = "Zeynep Kaya"
            )

            // Overdue dues scenario (10 days overdue per Spec-001)
            val baseBorc = AidatBorcu(
                id = "b-101",
                daireId = "d-14",
                donem = "Eylül 2026",
                anaPara = BigDecimal("1400.00"),
                sonOdemeTarihi = LocalDate.of(2026, 9, 15),
                durum = BorcDurumu.BEKLIYOR
            )

            val evaluatedBorc = calculateDuesUseCase.execute(baseBorc, LocalDate.of(2026, 9, 25))
            val isOverdue = evaluatedBorc.durum == BorcDurumu.GECIKMEDE

            // Synchronize with offline Room cache layer (STORY-01-06)
            residentRepository.cacheOfflineStatement(
                DuesCacheEntity(
                    unitId = "d-14",
                    unitNumber = "14",
                    residentName = "Ahmet Yılmaz",
                    principalAmount = evaluatedBorc.anaPara,
                    delayPenaltyAmount = evaluatedBorc.gecikmeTazminati,
                    totalAmount = evaluatedBorc.toplamTutar.amount,
                    daysOverdue = evaluatedBorc.gecikenGunSayisi,
                    isOverdue = isOverdue,
                    cachedAt = LocalDateTime.now(),
                    isSyncedWithServer = !forceOffline
                )
            )

            _isOffline.value = forceOffline
            _lastSyncTime.value = if (forceOffline) "Çevrimdışı önbellekten yüklendi" else "Az önce"

            _uiState.value = DashboardUiState.Success(
                aktifDaire = daire,
                borclar = listOf(evaluatedBorc),
                toplamBorc = evaluatedBorc.toplamTutar,
                duyuruBasligi = "Planlı Su Kesintisi Hakkında",
                duyuruMetni = "İSKİ ana hat yenilemesi sebebiyle 18 Eylül 10:00 - 14:00 arası su kesilecektir.",
                isOverdue = isOverdue
            )
        }
    }

    fun toggleOfflineMode(offline: Boolean) {
        _isOffline.value = offline
        loadDashboard(forceOffline = offline)
    }

    private fun loadManagerData() {
        _announcements.value = listOf(
            SiteAnnouncement(
                id = "anc-1",
                title = "Planlı Su Kesintisi Hakkında",
                category = "Acil",
                body = "İSKİ ana hat yenilemesi sebebiyle 18 Eylül 10:00 - 14:00 arası su kesilecektir.",
                timestamp = "Bugün, 10:00"
            )
        )

        _flatsList.value = listOf(
            FlatPaymentStatus("1", "A", 14, "Ahmet Yılmaz", BigDecimal("1423.33"), daysOverdue = 10, isPaid = false),
            FlatPaymentStatus("2", "A", 15, "Fatma Kaya", BigDecimal("1411.67"), daysOverdue = 5, isPaid = false),
            FlatPaymentStatus("3", "B", 3, "Mehmet Öz", BigDecimal("1404.67"), daysOverdue = 2, isPaid = false),
            FlatPaymentStatus("4", "A", 1, "Selim Ak", BigDecimal("1400.00"), daysOverdue = 0, isPaid = true, paidDateStr = "12 Eyl"),
            FlatPaymentStatus("5", "B", 7, "Canan Ece", BigDecimal("1400.00"), daysOverdue = 0, isPaid = true, paidDateStr = "14 Eyl"),
            FlatPaymentStatus("6", "A", 2, "Ali Demir", BigDecimal("1400.00"), daysOverdue = 0, isPaid = true, paidDateStr = "10 Eyl")
        )

        _pendingRegistrations.value = listOf(
            RegistrationRequestItem(
                id = "req-1",
                block = "B Blok",
                unitNo = 18,
                floor = 5,
                fullName = "Kerem Yılmaz",
                email = "kerem.yilmaz@gmail.com",
                phone = "0533 111 22 33",
                isResident = true,
                duesAmount = BigDecimal("1400.00"),
                timeAgoStr = "15 dk önce"
            ),
            RegistrationRequestItem(
                id = "req-2",
                block = "A Blok",
                unitNo = 5,
                floor = 2,
                fullName = "Deniz Aydın",
                email = "deniz.aydin@hotmail.com",
                phone = "0542 333 44 55",
                isResident = false,
                duesAmount = BigDecimal("1400.00"),
                timeAgoStr = "1 saat önce"
            )
        )
    }

    private fun loadUnitResidentData() {
        _unitResidents.value = listOf(
            UnitResidentMember(
                id = "res-ahmet-14",
                fullName = "Ahmet Yılmaz",
                relationship = "Kat Maliki (Ev Sahibi)",
                phone = "0532 111 22 33",
                email = "ahmet.yilmaz@begonya.com",
                isOwner = true,
                permissionScope = "Sadece A Blok D:14"
            )
        )
    }

    fun generateUnitInviteLink(relationship: String = "Aile Üyesi / Sakin") {
        val token = "SP-HANE-" + UUID.randomUUID().toString().substring(0, 4).uppercase()
        val url = "https://sitepulse.app/join/begonya-sitesi/units/d-14?token=$token"
        _unitInviteInfo.value = UnitInviteInfo(
            inviteUrl = url,
            token = token,
            unitLabel = "A Blok D:14",
            expiresAtStr = "7 gün geçerli",
            securityNotice = "Bu link sadece A Blok D:14 için sakin kaydı açar. Başka daire veya yönetim yetkisi vermez."
        )
    }

    fun clearUnitInviteInfo() {
        _unitInviteInfo.value = null
    }

    fun addHomeResidentMember(
        fullName: String,
        phone: String,
        email: String,
        relationship: String
    ) {
        val newMember = UnitResidentMember(
            id = "res-" + UUID.randomUUID().toString().substring(0, 8),
            fullName = fullName,
            relationship = relationship,
            phone = phone,
            email = email,
            isOwner = false,
            permissionScope = "Sadece A Blok D:14"
        )
        _unitResidents.value = _unitResidents.value + newMember
    }

    fun loginWithPassword(email: String, pass: String) {
        if (email.isBlank() || pass.isBlank()) {
            _authMessage.value = "E-posta ve şifre zorunludur."
            return
        }

        // Determine user based on email or role
        val role = when {
            email.contains("admin") -> UserRole.SAAS_ADMIN
            email.contains("yonetim") || email.contains("mehmet") -> UserRole.SITE_MANAGER
            email.contains("zeynep") -> UserRole.HOME_RESIDENT
            else -> UserRole.HOME_OWNER
        }

        _userRole.value = role
        _userSession.value = createSession(
            role = role,
            provider = AuthProvider.LOCAL,
            customEmail = email
        )
        _authMessage.value = "Şifre ile başarıyla giriş yapıldı (${role.displayName})."
    }

    fun loginWithGoogle() {
        val role = UserRole.HOME_OWNER
        _userRole.value = role
        _userSession.value = createSession(
            role = role,
            provider = AuthProvider.GOOGLE,
            customName = "Ahmet Yılmaz (Google)",
            customEmail = "ahmet.yilmaz@gmail.com",
            avatarUrl = "https://lh3.googleusercontent.com/a/google-user-icon"
        )
        _authMessage.value = "Google hesabı ile tek tıkla giriş sağlandı."
    }

    fun registerWithPassword(fullName: String, email: String, phone: String, pass: String) {
        if (fullName.isBlank() || email.isBlank() || pass.isBlank()) {
            _authMessage.value = "Lütfen tüm zorunlu alanları doldurunuz."
            return
        }
        val role = UserRole.HOME_OWNER
        _userRole.value = role
        _userSession.value = createSession(
            role = role,
            provider = AuthProvider.LOCAL,
            customName = fullName,
            customEmail = email,
            customPhone = phone
        )
        _authMessage.value = "Hesabınız başarıyla oluşturuldu ve oturum açıldı."
    }

    fun switchSessionRole(role: UserRole) {
        _userRole.value = role
        _userSession.value = createSession(role, _userSession.value.authProvider)
    }

    fun clearAuthMessage() {
        _authMessage.value = null
    }

    private fun createSession(
        role: UserRole,
        provider: AuthProvider,
        customName: String? = null,
        customEmail: String? = null,
        customPhone: String? = null,
        avatarUrl: String? = null
    ): UserSession {
        val permissions = when (role) {
            UserRole.SAAS_ADMIN -> listOf(
                PermissionScope("TENANT_MANAGE", "Site & Abonelik Yönetimi", true, "Platform geneli tüm kiracılar"),
                PermissionScope("SITE_MANAGE", "Site Altyapı Denetimi", true, "Tüm siteleri yapılandırma"),
                PermissionScope("ANNOUNCEMENT_BROADCAST", "Global Duyuru", true, "Tüm platform duyuruları")
            )
            UserRole.SITE_MANAGER -> listOf(
                PermissionScope("SITE_MANAGE", "Begonya Sitesi Yönetimi", true, "Blok, daire ve personel yönetimi"),
                PermissionScope("RESIDENT_INVITE_SITE", "Site Kayıt Linki Üretme", true, "Site geneli self-registration"),
                PermissionScope("RESIDENT_APPROVE", "Sakin Başvuru Onayı", true, "Onay kuyruğu ve şifre üretimi"),
                PermissionScope("LEDGER_MANAGE_ALL", "Aidat & Finans Yönetimi", true, "Tüm dairelerin borç ve faiz takibi"),
                PermissionScope("ANNOUNCEMENT_BROADCAST", "Site Geneli Duyuru", true, "Tüm dairelere SMS/bildirim")
            )
            UserRole.HOME_OWNER, UserRole.RESIDENT -> listOf(
                PermissionScope("UNIT_READ", "Daire Aidat & Makbuz Görüntüleme", true, "Sadece A Blok D:14"),
                PermissionScope("UNIT_PAY", "Online Aidat Ödeme (Kredi Kartı)", true, "Sadece A Blok D:14"),
                PermissionScope("UNIT_TICKET_SUBMIT", "Arıza / Talep Bildirimi", true, "Sadece A Blok D:14"),
                PermissionScope("UNIT_INVITE_CO_RESIDENT", "Hane Sakini Davet Linki Üretme", true, "Sadece A Blok D:14"),
                PermissionScope("UNIT_MANAGE_HOUSEHOLD", "Hane Sakinlerini Listeleme/Ekleme", true, "Sadece A Blok D:14"),
                PermissionScope("LEDGER_MANAGE_ALL", "Site Finansını Yönetme", false, "Engelli: Kat malikleri diğer daireleri göremez")
            )
            UserRole.HOME_RESIDENT -> listOf(
                PermissionScope("UNIT_READ", "Daire Aidat & Makbuz Görüntüleme", true, "Sadece A Blok D:14"),
                PermissionScope("UNIT_PAY", "Online Aidat Ödeme", true, "Sadece A Blok D:14"),
                PermissionScope("UNIT_TICKET_SUBMIT", "Arıza / Talep Bildirimi", true, "Sadece A Blok D:14"),
                PermissionScope("UNIT_INVITE_CO_RESIDENT", "Hane Sakini Davet Linki", false, "Engelli: Sadece Kat Maliki davet linki üretebilir"),
                PermissionScope("UNIT_MANAGE_HOUSEHOLD", "Hane Sakinlerini Yönetme", false, "Engelli: Aile sakinleri üye ekleyemez"),
                PermissionScope("LEDGER_MANAGE_ALL", "Site Finansını Yönetme", false, "Engelli: Site yönetimi yetkisi yok")
            )
        }

        val name = customName ?: when (role) {
            UserRole.SAAS_ADMIN -> "SaaS Platform Admin"
            UserRole.SITE_MANAGER -> "Mehmet Demir"
            UserRole.HOME_OWNER, UserRole.RESIDENT -> "Ahmet Yılmaz"
            UserRole.HOME_RESIDENT -> "Zeynep Yılmaz"
        }

        val email = customEmail ?: when (role) {
            UserRole.SAAS_ADMIN -> "admin@sitepulse.io"
            UserRole.SITE_MANAGER -> "mehmet.demir@begonya.com"
            UserRole.HOME_OWNER, UserRole.RESIDENT -> "ahmet.yilmaz@gmail.com"
            UserRole.HOME_RESIDENT -> "zeynep.yilmaz@gmail.com"
        }

        return UserSession(
            id = "usr-" + UUID.randomUUID().toString().substring(0, 8),
            fullName = name,
            email = email,
            phone = customPhone ?: "0532 111 22 33",
            role = role,
            siteName = "Begonya Sitesi",
            unitName = if (role == UserRole.HOME_OWNER || role == UserRole.HOME_RESIDENT || role == UserRole.RESIDENT) "A Blok D:14" else "Tüm Kompleks",
            authProvider = provider,
            avatarUrl = avatarUrl,
            permissions = permissions
        )
    }

}


