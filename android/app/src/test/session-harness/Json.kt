package org.json

class JSONObject(private val text: String = "") {
    private val values = linkedMapOf<String, Any?>()
    fun put(key: String, value: Any?) = apply { values[key] = value }
    fun getString(key: String): String = values[key] as? String
        ?: Regex("\"$key\"\\s*:\\s*\"([^\"]*)\"").find(text)?.groupValues?.get(1)
        ?: error("Missing string: $key")
    fun getInt(key: String): Int = Regex("\"$key\"\\s*:\\s*(-?\\d+)")
        .find(text)?.groupValues?.get(1)?.toInt() ?: error("Missing integer: $key")
    override fun toString() = values.entries.joinToString(prefix = "{", postfix = "}") { (key, value) ->
        "\"$key\":" + if (value is String) "\"${value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")}\"" else value.toString()
    }
}
