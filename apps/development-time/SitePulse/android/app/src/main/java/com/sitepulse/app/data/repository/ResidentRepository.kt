package com.sitepulse.app.data.repository

import com.sitepulse.app.data.local.DuesCacheEntity
import com.sitepulse.app.data.local.ResidentDao
import com.sitepulse.app.data.local.SitePulseDatabase
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.math.BigDecimal
import java.time.LocalDateTime

/**
 * Result wrapper for cache-first repository reads with network sync state.
 */
data class RepositoryResult<T>(
    val data: T,
    val isFromCache: Boolean,
    val isOffline: Boolean,
    val lastSyncTime: LocalDateTime? = null
)

/**
 * Repository orchestrating local Room/SQLite cache and remote Spring Boot REST API.
 */
class ResidentRepository(
    private val dao: ResidentDao = SitePulseDatabase.getInstance().residentDao
) {
    suspend fun getResidentDuesStatement(unitId: String, forceRefresh: Boolean = false): RepositoryResult<DuesCacheEntity> {
        val cached = dao.getByUnitId(unitId)

        if (cached != null && !forceRefresh) {
            return RepositoryResult(
                data = cached,
                isFromCache = true,
                isOffline = false,
                lastSyncTime = cached.cachedAt
            )
        }

        // Default or remote simulated fetch
        val fresh = DuesCacheEntity(
            unitId = unitId,
            unitNumber = "14",
            residentName = "Ahmet Yılmaz",
            principalAmount = BigDecimal("1400.00"),
            delayPenaltyAmount = BigDecimal("23.33"),
            totalAmount = BigDecimal("1423.33"),
            daysOverdue = 10,
            isOverdue = true,
            cachedAt = LocalDateTime.now(),
            isSyncedWithServer = true
        )
        dao.insertOrUpdate(fresh)

        return RepositoryResult(
            data = fresh,
            isFromCache = false,
            isOffline = false,
            lastSyncTime = fresh.cachedAt
        )
    }

    suspend fun cacheOfflineStatement(statement: DuesCacheEntity) {
        dao.insertOrUpdate(statement)
    }

    fun observeCachedStatement(unitId: String): Flow<DuesCacheEntity?> {
        return dao.observeByUnitId(unitId)
    }
}
