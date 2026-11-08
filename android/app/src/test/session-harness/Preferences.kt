package android.content

open class Context {
    private val preferences = SharedPreferences()
    fun getSharedPreferences(name: String, mode: Int) = preferences
    companion object { const val MODE_PRIVATE = 0 }
}

class SharedPreferences {
    private val values = mutableMapOf<String, Any?>()
    fun getString(key: String, default: String?) = values[key] as? String ?: default
    @Suppress("UNCHECKED_CAST")
    fun getStringSet(key: String, default: Set<String>?) = values[key] as? Set<String> ?: default
    fun getInt(key: String, default: Int) = values[key] as? Int ?: default
    fun getLong(key: String, default: Long) = values[key] as? Long ?: default
    fun getFloat(key: String, default: Float) = values[key] as? Float ?: default
    fun getBoolean(key: String, default: Boolean) = values[key] as? Boolean ?: default
    fun contains(key: String) = values.containsKey(key)
    fun edit() = Editor()

    inner class Editor {
        private val pending = mutableMapOf<String, Any?>()
        fun putString(key: String, value: String?) = apply { pending[key] = value }
        fun putStringSet(key: String, value: Set<String>) = apply { pending[key] = value.toSet() }
        fun putInt(key: String, value: Int) = apply { pending[key] = value }
        fun putLong(key: String, value: Long) = apply { pending[key] = value }
        fun putFloat(key: String, value: Float) = apply { pending[key] = value }
        fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
        fun apply() { values.putAll(pending) }
    }
}
