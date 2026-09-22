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

    init {
        loadDashboard()
        loadManagerData()
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
    }
}
