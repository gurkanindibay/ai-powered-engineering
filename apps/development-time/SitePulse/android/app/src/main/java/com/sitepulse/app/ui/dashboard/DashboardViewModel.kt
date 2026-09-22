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

class DashboardViewModel(
    private val calculateDuesUseCase: CalculateDuesUseCase = CalculateDuesUseCase()
) : ViewModel() {

    private val _uiState = MutableStateFlow<DashboardUiState>(DashboardUiState.Loading)
    val uiState: StateFlow<DashboardUiState> = _uiState.asStateFlow()

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

    init {
        loadDashboard()
        loadManagerData()
        loadSaasData()
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

    fun loadDashboard() {
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

}
