package dev.parla.android

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal interface StateStorage {
    fun read(): String?
    fun write(value: String)
    fun preserveOriginal()
}
/** Real production persistence gate, with injectable atomic storage for focused failure tests. */
internal class LocalState(private val storage: StateStorage) {
    private val mutableError = MutableStateFlow<String?>(null)
    val error = mutableError.asStateFlow()
    var blocked = false; private set
    private val mutableData = MutableStateFlow(read())
    val data = mutableData.asStateFlow()
    private fun read(): LocalData = try {
        val result = storage.read()?.let(LocalDataCodec::decode) ?: LocalData()
        blocked = false; mutableError.value = null; result
    } catch(_: Exception) {
        blocked = true; mutableError.value = "Local data could not be read. Writes and provider work blocked. Use Data recovery; originals remain on disk."; LocalData()
    }
    @Synchronized fun update(transform: (LocalData) -> LocalData): Boolean {
        if(blocked) { mutableError.value = "Reload or repair local data before saving or using a provider."; return false }
        return try {
            val next = transform(data.value).let { it.copy(history = it.history.take(it.settings.historyLimit.coerceIn(1,1000))) }
            storage.write(LocalDataCodec.encode(next)); mutableData.value = next; mutableError.value = null; true
        } catch(_: Exception) { mutableError.value = "Changes were not saved. Free storage and retry; pending results remain available."; false }
    }
    @Synchronized fun reload(): Boolean {
        val next = read(); if(blocked) return false
        mutableData.value = next; return true
    }
    @Synchronized fun original() = storage.read().orEmpty()
    @Synchronized fun repair(source: String): Boolean = try {
        val next = LocalDataCodec.decode(source)
        storage.preserveOriginal(); storage.write(LocalDataCodec.encode(next))
        mutableData.value = next; blocked = false; mutableError.value = null; true
    } catch(_: Exception) { mutableError.value = "Repair failed. Check JSON/schema and storage. Original retained."; false }
}
