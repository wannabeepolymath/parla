package dev.parla.android

/** Invalidating pending work cancels it once; our own consumed write never does. Main-thread only. */
internal class InsertionLease(private val onInvalidated: () -> Unit) {
    var valid = true
        private set

    fun invalidate() {
        if (!valid) return
        valid = false
        onInvalidated()
    }

    fun consume(): Boolean {
        if (!valid) return false
        valid = false
        return true
    }

    fun release() { valid = false }
}
