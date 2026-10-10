package j3.voicekey

enum class Channel(
    val id: String,
    val title: String,
    val short: String,
    val desc: String,
    val logo: Int,
    val offline: Boolean = false,
) {
    Doubao("doubao", "豆包输入法", "豆包", "响应快、中英混说准确，适合日常输入。", R.drawable.logo_doubao),
    Wetype("wetype", "微信输入法", "微信", "口语化表达识别稳定，数字自动规整。", R.drawable.logo_wetype),
    Qwen("qwen", "千问输入法", "千问", "千问输入法官方云端识别，中文流式出字。", R.drawable.logo_qwen),
    Baidu("baidu", "百度输入法", "百度", "百度输入法官方云端识别，中文流式出字。", R.drawable.logo_baidu),
    Sogou("sogou", "搜狗输入法", "搜狗", "搜狗输入法官方云端识别，中文流式出字。", R.drawable.logo_sogou),
    Iflytek("iflytek", "讯飞输入法", "讯飞", "讯飞输入法官方云端识别，中文流式出字。", R.drawable.logo_iflytek),
    WetypeOffline("wetypeoffline", "微信离线", "微信离线", "微信输入法官方离线模型，本机运行，断网可用，不上传音频。", R.drawable.logo_wetype, true);

    val ready: Boolean get() = !offline || Native.wtofflineReady()

    companion object {
        fun of(id: String?) = entries.firstOrNull { it.id == id }
        val online get() = entries.filter { !it.offline }
    }
}
