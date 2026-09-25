package com.sitepulse.app.data

import com.sitepulse.app.data.local.DuesCacheEntity
import com.sitepulse.app.data.local.SitePulseDatabase
import com.sitepulse.app.data.repository.ResidentRepository
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.math.BigDecimal
import java.time.LocalDateTime

class RoomCacheTests {

    private lateinit var repository: ResidentRepository
    private val database = SitePulseDatabase.getInstance()

    @Before
    fun setUp() {
        repository = ResidentRepository(database.residentDao)
    }

    @Test
    fun Should_Return_Cached_Statement_On_Network_Timeout() = runBlocking {
        val testUnitId = "d-test-101"
        val cachedStatement = DuesCacheEntity(
            unitId = testUnitId,
            unitNumber = "101",
            residentName = "Mehmet Demir",
            principalAmount = BigDecimal("1500.00"),
            delayPenaltyAmount = BigDecimal("25.00"),
            totalAmount = BigDecimal("1525.00"),
            daysOverdue = 10,
            isOverdue = true,
            cachedAt = LocalDateTime.now().minusHours(2),
            isSyncedWithServer = true
        )

        // Seed cache
        repository.cacheOfflineStatement(cachedStatement)

        // Retrieve with cache-first policy
        val result = repository.getResidentDuesStatement(testUnitId, forceRefresh = false)

        assertTrue("Expected data from cache", result.isFromCache)
        assertEquals(BigDecimal("1525.00"), result.data.totalAmount)
        assertEquals("Mehmet Demir", result.data.residentName)
        assertEquals(10, result.data.daysOverdue)
    }

    @Test
    fun Should_Mark_Cache_Dirty_When_Modified_Offline() = runBlocking {
        val testUnitId = "d-test-102"
        val statement = DuesCacheEntity(
            unitId = testUnitId,
            unitNumber = "102",
            residentName = "Ayşe Kaya",
            principalAmount = BigDecimal("1200.00"),
            delayPenaltyAmount = BigDecimal("0.00"),
            totalAmount = BigDecimal("1200.00"),
            daysOverdue = 0,
            isOverdue = false,
            cachedAt = LocalDateTime.now(),
            isSyncedWithServer = true
        )

        database.residentDao.insertOrUpdate(statement)
        database.residentDao.markDirty(testUnitId)

        val retrieved = database.residentDao.getByUnitId(testUnitId)
        assertNotNull(retrieved)
        assertFalse("Expected cached statement to be marked dirty (unsynced)", retrieved!!.isSyncedWithServer)
    }
}
