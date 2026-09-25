package com.sitepulse.app.data.local

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import java.util.concurrent.ConcurrentHashMap

/**
 * SitePulse Local Database implementation providing Room/SQLite caching semantics.
 */
class SitePulseDatabase private constructor() {

    private val cacheMap = ConcurrentHashMap<String, DuesCacheEntity>()
    private val cacheFlow = MutableStateFlow<Map<String, DuesCacheEntity>>(emptyMap())

    val residentDao: ResidentDao = object : ResidentDao {
        override suspend fun insertOrUpdate(statement: DuesCacheEntity) {
            cacheMap[statement.unitId] = statement
            cacheFlow.value = HashMap(cacheMap)
        }

        override suspend fun getByUnitId(unitId: String): DuesCacheEntity? {
            return cacheMap[unitId]
        }

        override fun observeByUnitId(unitId: String): Flow<DuesCacheEntity?> {
            return cacheFlow.map { it[unitId] }
        }

        override suspend fun clearCacheForUnit(unitId: String) {
            cacheMap.remove(unitId)
            cacheFlow.value = HashMap(cacheMap)
        }

        override suspend fun markDirty(unitId: String) {
            val current = cacheMap[unitId]
            if (current != null) {
                cacheMap[unitId] = current.copy(isSyncedWithServer = false)
                cacheFlow.value = HashMap(cacheMap)
            }
        }
    }

    companion object {
        @Volatile
        private var INSTANCE: SitePulseDatabase? = null

        fun getInstance(): SitePulseDatabase {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: SitePulseDatabase().also { INSTANCE = it }
            }
        }
    }
}
