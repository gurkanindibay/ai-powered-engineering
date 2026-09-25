package com.sitepulse.app.data.local

import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object (DAO) for local resident dues statement cache.
 */
interface ResidentDao {
    suspend fun insertOrUpdate(statement: DuesCacheEntity)
    suspend fun getByUnitId(unitId: String): DuesCacheEntity?
    fun observeByUnitId(unitId: String): Flow<DuesCacheEntity?>
    suspend fun clearCacheForUnit(unitId: String)
    suspend fun markDirty(unitId: String)
}
