package com.sitepulse.app.ui.dashboard

import com.sitepulse.app.domain.model.AuthProvider
import com.sitepulse.app.domain.model.UserRole
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.math.BigDecimal

@OptIn(ExperimentalCoroutinesApi::class)
class DashboardViewModelTest {

    private val testDispatcher = StandardTestDispatcher()
    private lateinit var viewModel: DashboardViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
        viewModel = DashboardViewModel()
        testDispatcher.scheduler.advanceUntilIdle()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `when initialized, then default role is HOME_OWNER with Begonya Sitesi unit scope`() {
        val session = viewModel.userSession.value
        assertEquals(UserRole.HOME_OWNER, session.role)
        assertEquals("A Blok D:14", session.unitName)
        assertEquals("Begonya Sitesi", session.siteName)
        assertTrue(session.permissions.any { it.code == "UNIT_PAY" && it.isGranted })
        assertFalse(session.permissions.any { it.code == "LEDGER_MANAGE_ALL" && it.isGranted })
    }

    @Test
    fun `when login as site manager, then sets SITE_MANAGER role and complex scope permissions`() {
        viewModel.loginWithPassword("mehmet.demir@begonya.com", "password123")

        val session = viewModel.userSession.value
        assertEquals(UserRole.SITE_MANAGER, session.role)
        assertEquals("Tüm Kompleks", session.unitName)
        assertTrue(session.permissions.any { it.code == "LEDGER_MANAGE_ALL" && it.isGranted })
        assertTrue(session.permissions.any { it.code == "RESIDENT_INVITE_SITE" && it.isGranted })
        assertTrue(session.permissions.any { it.code == "RESIDENT_APPROVE" && it.isGranted })
    }

    @Test
    fun `when login as saas admin, then sets SAAS_ADMIN role and tenant management permissions`() {
        viewModel.loginWithPassword("admin@sitepulse.io", "adminpass")

        val session = viewModel.userSession.value
        assertEquals(UserRole.SAAS_ADMIN, session.role)
        assertTrue(session.permissions.any { it.code == "TENANT_MANAGE" && it.isGranted })
        assertTrue(session.permissions.any { it.code == "SITE_MANAGE" && it.isGranted })
    }

    @Test
    fun `when login with Google, then authenticates as HOME_OWNER with Google provider`() {
        viewModel.loginWithGoogle()

        val session = viewModel.userSession.value
        assertEquals(UserRole.HOME_OWNER, session.role)
        assertEquals(AuthProvider.GOOGLE, session.authProvider)
        assertEquals("Ahmet Yılmaz (Google)", session.fullName)
    }

    @Test
    fun `when register new site, then provisions credentials and adds site to tenant list`() {
        val initialCount = viewModel.saasSites.value.size
        viewModel.registerNewSite(
            name = "Nilüfer Vadisi",
            city = "Bursa",
            address = "Nilüfer, Çamlık Cad. No:12",
            adminName = "Serdar Akın",
            adminEmail = "serdar@nilufervadisi.com",
            adminPhone = "0532 999 88 77",
            planType = "PREMIUM"
        )

        assertEquals(initialCount + 1, viewModel.saasSites.value.size)
        val creds = viewModel.provisionedCredentials.value
        assertNotNull(creds)
        assertEquals("Nilüfer Vadisi", creds?.siteName)
        assertEquals("serdar@nilufervadisi.com", creds?.adminEmail)
        assertTrue(creds!!.temporaryPassword.startsWith("SP-"))
    }

    @Test
    fun `when register home owner by manager, then adds flat and issues resident password`() {
        val initialFlatsCount = viewModel.flatsList.value.size
        viewModel.registerHomeOwner(
            block = "B Blok",
            unitNo = 12,
            ownerName = "Caner Yurt",
            email = "caner@example.com",
            phone = "0543 222 33 44",
            duesAmount = BigDecimal("1400.00"),
            isResident = true
        )

        assertEquals(initialFlatsCount + 1, viewModel.flatsList.value.size)
        val creds = viewModel.provisionedHomeOwner.value
        assertNotNull(creds)
        assertEquals("Caner Yurt", creds?.ownerName)
        assertTrue(creds!!.temporaryPassword.startsWith("SP-SAKIN-"))
    }

    @Test
    fun `when approve registration request, then removes from pending queue and generates credentials`() {
        val pending = viewModel.pendingRegistrations.value
        assertTrue("Pending queue should not be empty", pending.isNotEmpty())
        val targetReq = pending.first()

        viewModel.approveRegistration(targetReq.id)

        assertFalse(viewModel.pendingRegistrations.value.any { it.id == targetReq.id })
        val success = viewModel.approvalSuccessInfo.value
        assertNotNull(success)
        assertEquals(targetReq.fullName, success?.fullName)
        assertTrue(success!!.temporaryPassword.startsWith("SP-SAKIN-"))
    }

    @Test
    fun `when generate unit invite link, then produces unit-scoped URL`() {
        viewModel.generateUnitInviteLink()

        val invite = viewModel.unitInviteInfo.value
        assertNotNull(invite)
        assertTrue(invite!!.inviteUrl.contains("begonya-sitesi/units/d-14"))
        assertTrue(invite.token.startsWith("SP-HANE-"))
    }

    @Test
    fun `when switch session role, then role and session update immediately`() {
        viewModel.switchSessionRole(UserRole.SITE_MANAGER)
        assertEquals(UserRole.SITE_MANAGER, viewModel.userRole.value)
        assertEquals(UserRole.SITE_MANAGER, viewModel.userSession.value.role)

        viewModel.switchSessionRole(UserRole.SAAS_ADMIN)
        assertEquals(UserRole.SAAS_ADMIN, viewModel.userRole.value)
        assertEquals(UserRole.SAAS_ADMIN, viewModel.userSession.value.role)

        viewModel.switchSessionRole(UserRole.HOME_OWNER)
        assertEquals(UserRole.HOME_OWNER, viewModel.userRole.value)
        assertEquals(UserRole.HOME_OWNER, viewModel.userSession.value.role)
    }
}
