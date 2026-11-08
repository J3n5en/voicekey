package j3.voicekey

import android.os.TestClock
import android.content.Context
import org.json.JSONObject

/**
 * 直接驱动真实 Session 的公开操作与 Native 回调，验证状态、上屏、发送和计时边界。
 * Android、录音及 JNI 均为隔离桩，因此这些测试不证明设备交互或网络识别可用。
 *
 * Drive the real Session through public operations and Native callbacks to verify state,
 * insertion, sending, and timer boundaries. Android, recording, and JNI are isolated fakes;
 * these tests do not establish device interaction or network recognition behavior.
 */
private class Fixture(configure: () -> Unit = {}) {
    val svc = VoiceService()
    val session = Session(svc)
    val handles: Map<Channel, Long>
    val originalRows: Map<Channel, Session.Row>

    init {
        TestClock.reset()
        Native.reset()
        App.prefs = Prefs(Context()).apply {
            channel = null
            streaming = false
        }
        configure()
        session.holdStart()
        originalRows = session.rows.associateBy { it.ch }
        handles = originalRows.mapValues { it.value.handle }
    }

    fun emit(ch: Channel, kind: Int, text: String) {
        Native.listeners.getValue(handles.getValue(ch))(kind, text)
        TestClock.advance(0)
    }

    fun final(ch: Channel, text: String = ch.id) = emit(ch, Native.FINAL, text)
    fun grace(delay: Long = 2_500) = TestClock.pending().single { it.at == TestClock.now + delay }.runnable
    fun completePair() {
        session.end()
        final(Channel.A)
        final(Channel.B)
    }
    fun jev(kind: Int, text: String) {
        Native.jev.single().callback(kind, text)
        TestClock.advance(0)
    }
    fun noDuplicateFrees() {
        equal(Native.freed.distinct().size, Native.freed.size)
    }
}

private fun equal(expected: Any?, actual: Any?) {
    check(expected == actual) { "Expected <$expected>, got <$actual>" }
}

private var passed = 0
private fun test(name: String, body: () -> Unit) {
    try {
        body()
        passed++
        println("PASS $name")
    } catch (e: Throwable) {
        throw AssertionError("FAIL $name", e)
    }
}

fun main() {
    test("legacy preferences use compatible timing defaults and shared JSON keys") {
        val p = Prefs(Context())
        equal(JevSelectionThreshold.TwoThirds, p.jevSelectionThreshold)
        equal(2_500, p.jevSelectionWaitMs)
        check(!p.sp.contains("jevSelectionThreshold") && !p.sp.contains("jevSelectionWaitMs"))
        val json = JSONObject(p.jevConfig())
        equal("twoThirds", json.getString("selectionThreshold"))
        equal(2_500, json.getInt("selectionWaitMs"))
        p.sp.edit().putString("jevSelectionThreshold", "future-value").apply()
        equal(JevSelectionThreshold.TwoThirds, p.jevSelectionThreshold)
        equal("twoThirds", JSONObject(p.jevConfig()).getString("selectionThreshold"))
    }

    test("timing reset touches only its two preferences") {
        val p = Prefs(Context())
        p.jevMode = "official"
        p.jevKey = "fake-key"
        p.jevEndpoint = "https://example.invalid"
        p.jevModel = "test-model"
        p.jevPool = "fake|fake-key|"
        p.pickSend = true
        p.jevSelectionThreshold = JevSelectionThreshold.All
        p.jevSelectionWaitMs = 5_000
        p.resetJevSelectionTiming()
        equal(JevSelectionTiming(), p.jevSelectionTiming())
        equal("official", p.jevMode)
        equal("fake-key", p.jevKey)
        equal("https://example.invalid", p.jevEndpoint)
        equal("test-model", p.jevModel)
        equal("fake|fake-key|", p.jevPool)
        check(p.pickSend)
    }

    for ((input, expected) in listOf(Int.MIN_VALUE to 500, 499 to 500, 500 to 500, 5_000 to 5_000, 5_001 to 5_000, Int.MAX_VALUE to 5_000)) {
        test("wait preference clamps $input to $expected on read, write and JSON") {
            val p = Prefs(Context())
            p.sp.edit().putInt("jevSelectionWaitMs", input).apply()
            equal(expected, p.jevSelectionWaitMs)
            equal(expected, JSONObject(p.jevConfig()).getInt("selectionWaitMs"))
            p.jevSelectionWaitMs = input
            equal(expected, p.sp.getInt("jevSelectionWaitMs", -1))
        }
    }

    test("seconds input rejects empty invalid nonfinite out-of-range and non-half-step values") {
        for (text in listOf(
            "", " ", "not-a-number", "1,5", "NaN", "Infinity", "+Infinity", "-Infinity",
            "-1", "0", "0.4999999999", "5.0000000001", "1000000", "1.7976931348623157E308", "1e309",
            "0.6", "1.25", "2.5000000001", "4.9",
        )) {
            equal(null, JevSelectionTiming.parseWaitSeconds(text))
        }
    }

    test("seconds input accepts every half-second step and trimmed numeric equivalents") {
        for (halfSeconds in 1..10) {
            equal(halfSeconds * 500, JevSelectionTiming.parseWaitSeconds((halfSeconds / 2.0).toString()))
        }
        for ((text, ms) in listOf(" 0.5 " to 500, "1" to 1_000, "2.50" to 2_500, "5" to 5_000)) {
            equal(ms, JevSelectionTiming.parseWaitSeconds(text))
        }
    }

    for (threshold in JevSelectionThreshold.entries) {
        for (participants in 2..9) {
            val required = when (threshold) {
                JevSelectionThreshold.Half -> (participants + 1) / 2
                JevSelectionThreshold.TwoThirds -> (participants * 2 + 2) / 3
                JevSelectionThreshold.All -> participants
            }
            test("${threshold.id}: $participants participants need $required usable finals") {
                equal(required, threshold.required(participants))
                val f = Fixture {
                    App.prefs.multi = Channel.entries.take(participants)
                    App.prefs.jevSelectionThreshold = threshold
                    Native.jevError = null
                }
                f.session.end()
                for (ch in Channel.entries.take(required - 1)) f.final(ch)
                check(!f.session.jevBusy && Native.jev.isEmpty())
                f.final(Channel.entries[required - 1])
                if (required == 1) {
                    check(f.session.active && !f.session.jevBusy)
                    equal(0, f.session.sel)
                } else {
                    check(f.session.jevBusy)
                    equal(required, Native.jev.single().texts.size)
                }
                check(f.session.rows.drop(required).all { it.state == Session.State.Error && it.handle == 0L })
                f.session.abort(null)
                f.noDuplicateFrees()
            }
        }
    }

    for (delay in listOf(500, 5_000)) {
        test("all threshold still respects the $delay ms wait cap from a late first final") {
            val f = Fixture {
                App.prefs.jevSelectionThreshold = JevSelectionThreshold.All
                App.prefs.jevSelectionWaitMs = delay
                App.prefs.pickSend = true
                Native.jevError = null
            }
            f.session.end()
            TestClock.advance(14_900)
            f.final(Channel.A)
            f.grace(delay.toLong())
            TestClock.advance(delay.toLong() - 1)
            check(f.session.active && f.svc.inserted.isEmpty() && f.svc.hud.errors.isEmpty())
            TestClock.advance(1)
            equal(listOf("a"), f.svc.inserted)
            equal(1, f.svc.sends)
        }
    }

    test("existing Error states retain their participant denominator but are not finals") {
        val f = Fixture {
            App.prefs.multi = Channel.entries.take(4)
            App.prefs.jevSelectionThreshold = JevSelectionThreshold.Half
            Native.jevError = null
        }
        f.session.end()
        f.emit(Channel.A, Native.ERROR, "failed")
        equal(Session.State.Error, f.session.rows[0].state)
        check(TestClock.pending().none { it.at == 2_500L })
        f.final(Channel.B)
        check(!f.session.jevBusy)
        f.final(Channel.C)
        equal(listOf("b", "c"), Native.jev.single().texts)
    }

    test("threshold and wait changes during recording apply only to the next recording") {
        val f = Fixture {
            App.prefs.jevSelectionThreshold = JevSelectionThreshold.All
            App.prefs.jevSelectionWaitMs = 5_000
            Native.jevError = null
        }
        App.prefs.jevSelectionThreshold = JevSelectionThreshold.Half
        App.prefs.jevSelectionWaitMs = 500
        f.session.end()
        f.final(Channel.A)
        val timer = f.grace(5_000)
        f.final(Channel.B)
        TestClock.advance(500)
        check(!f.session.jevBusy)
        equal(Session.State.Wait, f.session.rows[2].state)
        check(TestClock.pending().any { it.runnable === timer })
        TestClock.advance(4_500)
        check(f.session.jevBusy)
        equal("all", JSONObject(Native.jev.single().config).getString("selectionThreshold"))
        equal(5_000, JSONObject(Native.jev.single().config).getInt("selectionWaitMs"))
        f.session.abort(null)

        f.session.holdStart()
        val handles = f.session.rows.map { it.handle }
        f.session.end()
        Native.listeners.getValue(handles[0])(Native.FINAL, "new a")
        TestClock.advance(0)
        TestClock.advance(499)
        check(!f.session.jevBusy)
        Native.listeners.getValue(handles[1])(Native.FINAL, "new b")
        TestClock.advance(0)
        check(f.session.jevBusy)
        equal(listOf("new a", "new b"), Native.jev.last().texts)
        equal("half", JSONObject(Native.jev.last().config).getString("selectionThreshold"))
        equal(500, JSONObject(Native.jev.last().config).getInt("selectionWaitMs"))
        f.session.abort(null)

        f.session.holdStart()
        val first = f.session.rows[0].handle
        f.session.end()
        Native.listeners.getValue(first)(Native.FINAL, "new first")
        TestClock.advance(0)
        f.grace(500)
        TestClock.advance(499)
        equal(Session.State.Wait, f.session.rows[1].state)
        TestClock.advance(1)
        equal(Session.State.Error, f.session.rows[1].state)
    }

    test("grace starts on first final and is not reset by partial or later final") {
        val f = Fixture {
            App.prefs.multi = Channel.entries.take(4)
            App.prefs.pickSend = true
            Native.jevError = null
        }
        f.session.end()
        TestClock.advance(1_000)
        f.final(Channel.A)
        val timer = f.grace()
        TestClock.advance(1_000)
        f.emit(Channel.C, Native.PARTIAL, "slow partial")
        f.final(Channel.B)
        check(TestClock.pending().any { it.runnable === timer && it.at == 3_500L })
        TestClock.advance(1_499)
        check(f.session.active)
        TestClock.advance(1)
        check(f.session.jevBusy && f.svc.inserted.isEmpty())
        equal(listOf("a", "b"), Native.jev.single().texts)
        equal(Session.State.Error, f.originalRows.getValue(Channel.C).state)
        equal("slow partial", f.originalRows.getValue(Channel.C).text)
        equal(0L, f.originalRows.getValue(Channel.C).handle)
        f.jev(Native.FINAL, "{\"index\":1}")
        equal(listOf("b"), f.svc.inserted)
        equal(1, f.svc.sends)
        f.noDuplicateFrees()
    }

    test("recording never starts automatic grace or inserts a final") {
        val f = Fixture {
            App.prefs.multi = listOf(Channel.A, Channel.B)
            App.prefs.pickSend = true
            Native.jevError = null
        }
        f.final(Channel.A)
        TestClock.advance(10_000)
        check(f.session.recording)
        check(TestClock.pending().isEmpty())
        check(f.svc.inserted.isEmpty())
        f.session.end()
        f.grace()
        TestClock.advance(2_499)
        check(f.svc.inserted.isEmpty())
        TestClock.advance(1)
        equal(listOf("a"), f.svc.inserted)
    }

    test("end advances when all finals arrived during recording") {
        val f = Fixture {
            App.prefs.multi = listOf(Channel.A, Channel.B)
            Native.jevError = null
        }
        f.final(Channel.B)
        f.final(Channel.A)
        check(f.svc.inserted.isEmpty())
        f.session.end()
        check(f.session.jevBusy)
        equal(listOf("a", "b"), Native.jev.single().texts)
        f.jev(Native.FINAL, "{\"index\":1}")
        equal(1, f.session.sel)
        check(f.session.active && f.svc.inserted.isEmpty())
    }

    test("last waiting result cancels grace and immediately requests Jev") {
        val f = Fixture {
            App.prefs.multi = Channel.entries.take(4)
            Native.jevError = null
        }
        f.session.end()
        f.final(Channel.A)
        val timer = f.grace()
        f.final(Channel.B)
        f.emit(Channel.C, Native.ERROR, "unavailable")
        check(!f.session.jevBusy)
        f.emit(Channel.D, Native.ERROR, "unavailable")
        check(f.session.jevBusy)
        equal(listOf("a", "b"), Native.jev.single().texts)
        check(TestClock.pending().none { it.runnable === timer })
        timer.run()
        check(f.session.jevBusy)
        equal(1, Native.jev.size)
        check(Native.freed.isEmpty())
        check(f.svc.inserted.isEmpty())
    }

    test("a first final at 14.9 seconds receives the full 2.5 seconds") {
        val f = Fixture {
            App.prefs.pickSend = true
            Native.jevError = null
        }
        f.session.end()
        TestClock.advance(14_900)
        f.final(Channel.A)
        val timer = f.grace()
        TestClock.advance(100)
        check(f.session.active)
        check(f.svc.hud.errors.isEmpty())
        check(TestClock.pending().any { it.runnable === timer && it.at == 17_400L })
        TestClock.advance(2_399)
        check(f.svc.inserted.isEmpty())
        TestClock.advance(1)
        equal(listOf("a"), f.svc.inserted)
    }

    test("no final retains the 15 second timeout") {
        val f = Fixture()
        f.session.end()
        TestClock.advance(14_999)
        check(f.session.active)
        TestClock.advance(1)
        check(!f.session.active)
        equal(listOf("识别超时"), f.svc.hud.errors)
        check(f.svc.inserted.isEmpty())
        f.noDuplicateFrees()
    }

    for (configError in listOf("disabled", "invalid configuration")) {
        for (send in listOf(false, true)) {
            test("$configError with pickSend=$send preserves a single final for manual choice") {
                val f = Fixture {
                    App.prefs.multi = listOf(Channel.A, Channel.B)
                    App.prefs.pickSend = send
                    Native.jevError = configError
                }
                f.session.end()
                f.final(Channel.B)
                for (delay in listOf(2_500L, 12_500L)) {
                    TestClock.advance(delay)
                    check(f.session.active && f.session.picking && !f.session.jevBusy)
                    equal(Session.State.Wait, f.originalRows.getValue(Channel.A).state)
                    check(f.svc.inserted.isEmpty() && Native.jev.isEmpty() && Native.freed.isEmpty())
                    equal(0, f.svc.sends)
                }
                f.emit(Channel.A, Native.ERROR, "unavailable")
                TestClock.advance(15_000)
                check(f.session.active && f.svc.inserted.isEmpty())
                equal(0, f.svc.sends)
                f.session.choose(1, send)
                equal(listOf("b"), f.svc.inserted)
                equal(if (send) 1 else 0, f.svc.sends)
                f.noDuplicateFrees()
            }

            test("$configError with pickSend=$send preserves multiple finals and late callbacks") {
                val f = Fixture {
                    App.prefs.pickSend = send
                    Native.jevError = configError
                }
                f.completePair()
                for (delay in listOf(2_500L, 12_500L)) {
                    TestClock.advance(delay)
                    check(f.session.active && f.session.picking && !f.session.jevBusy)
                    equal(Session.State.Wait, f.originalRows.getValue(Channel.C).state)
                    check(f.originalRows.getValue(Channel.C).handle != 0L)
                    check(f.svc.inserted.isEmpty() && Native.jev.isEmpty() && Native.freed.isEmpty())
                    equal(0, f.svc.sends)
                }
                f.emit(Channel.C, Native.PARTIAL, "late partial")
                equal("late partial", f.originalRows.getValue(Channel.C).text)
                f.final(Channel.C, "late final")
                equal(Session.State.Final, f.originalRows.getValue(Channel.C).state)
                TestClock.advance(15_000)
                check(f.session.active && f.svc.inserted.isEmpty() && Native.jev.isEmpty())
                equal(0, f.svc.sends)
                f.session.choose(2, send)
                equal(listOf("late final"), f.svc.inserted)
                equal(if (send) 1 else 0, f.svc.sends)
                f.noDuplicateFrees()
            }
        }
    }

    for (send in listOf(false, true)) {
        for (finish in listOf("error", "grace")) {
            test("valid Jev single final after $finish retains pickSend=$send semantics") {
                val f = Fixture {
                    App.prefs.multi = listOf(Channel.A, Channel.B)
                    App.prefs.pickSend = send
                    Native.jevError = null
                }
                f.session.end()
                f.final(Channel.B)
                if (finish == "error") f.emit(Channel.A, Native.ERROR, "unavailable")
                else TestClock.advance(2_500)
                check(Native.jev.isEmpty())
                if (send) {
                    equal(listOf("b"), f.svc.inserted)
                    equal(1, f.svc.sends)
                    check(!f.session.active)
                } else {
                    equal(1, f.session.sel)
                    check(f.session.active && f.svc.inserted.isEmpty())
                    equal(0, f.svc.sends)
                    TestClock.advance(15_000)
                    check(f.session.active && f.svc.inserted.isEmpty())
                    f.session.choose(1)
                    equal(listOf("b"), f.svc.inserted)
                }
                f.noDuplicateFrees()
            }
        }
    }

    test("failed insertion never sends") {
        val f = Fixture {
            App.prefs.multi = listOf(Channel.A, Channel.B)
            App.prefs.pickSend = true
            Native.jevError = null
        }
        f.svc.insertOk = false
        f.completePair()
        f.jev(Native.FINAL, "{\"index\":0}")
        equal(0, f.svc.sends)
        check(!f.session.active)
    }

    for (send in listOf(false, true)) {
        test("Jev success retains existing pickSend=$send semantics") {
            val f = Fixture {
                App.prefs.multi = listOf(Channel.A, Channel.B)
                App.prefs.pickSend = send
                Native.jevError = null
            }
            f.completePair()
            check(f.session.jevBusy)
            f.jev(Native.FINAL, "{\"index\":1}")
            if (send) {
                equal(listOf("b"), f.svc.inserted)
                equal(1, f.svc.sends)
                check(!f.session.active)
            } else {
                equal(1, f.session.sel)
                check(f.session.active && !f.session.jevBusy)
                check(f.svc.inserted.isEmpty())
                equal(0, f.svc.sends)
            }
        }
    }

    for (result in listOf(Native.ERROR to "network failed", Native.FINAL to "{\"index\":99}")) {
        test("Jev failure $result leaves manual fallback without insertion") {
            val f = Fixture {
                App.prefs.multi = listOf(Channel.A, Channel.B)
                Native.jevError = null
            }
            f.completePair()
            f.jev(result.first, result.second)
            check(f.session.jevFailed && f.session.active && !f.session.jevBusy)
            equal(listOf("智能选择失败，请手动选择"), f.svc.hud.errors)
            TestClock.advance(20_000)
            check(f.svc.inserted.isEmpty())
            equal(1, Native.jev.size)
            f.session.choose(1)
            equal(listOf("b"), f.svc.inserted)
        }
    }

    test("manual next preserves its highlight and accepts later candidates") {
        val f = Fixture { Native.jevError = null }
        f.final(Channel.A)
        f.final(Channel.B)
        f.session.next()
        equal(1, f.session.sel)
        f.session.end()
        TestClock.advance(2_500)
        equal(1, f.session.sel)
        check(f.session.active)
        equal(Session.State.Wait, f.originalRows.getValue(Channel.C).state)
        check(f.svc.inserted.isEmpty())
        check(Native.jev.isEmpty())
        TestClock.advance(12_500)
        check(f.session.active && f.svc.inserted.isEmpty() && Native.freed.isEmpty())
        f.emit(Channel.C, Native.FINAL, "late final")
        equal(Session.State.Final, f.originalRows.getValue(Channel.C).state)
        equal(1, f.session.sel)
        check(f.svc.inserted.isEmpty())
        f.session.abort(null)
        f.noDuplicateFrees()
    }

    test("manual next during grace prevents sealing and accepts the selected late final") {
        val f = Fixture {
            App.prefs.multi = listOf(Channel.A, Channel.B)
            App.prefs.pickSend = true
            Native.jevError = null
        }
        f.session.end()
        f.final(Channel.A)
        val timer = f.grace()
        f.session.next()
        TestClock.advance(2_500)
        equal(1, f.session.sel)
        equal(Session.State.Wait, f.session.rows[1].state)
        check(f.session.active)
        check(f.svc.inserted.isEmpty() && Native.freed.isEmpty())
        timer.run()
        TestClock.advance(12_500)
        equal(Session.State.Wait, f.session.rows[1].state)
        check(f.session.active && f.svc.inserted.isEmpty())
        f.final(Channel.B, "late selected final")
        equal(1, f.session.sel)
        check(f.session.active && f.svc.inserted.isEmpty() && Native.jev.isEmpty())
        f.session.choose(1)
        equal(listOf("late selected final"), f.svc.inserted)
        equal(0, f.svc.sends)
        f.noDuplicateFrees()
    }

    for (configError in listOf("disabled", "invalid configuration")) {
        test("grace rechecks $configError and retains late callbacks after expiry") {
            val f = Fixture {
                App.prefs.pickSend = true
                Native.jevError = null
            }
            f.session.end()
            f.final(Channel.A)
            val timer = f.grace()
            Native.jevError = configError
            TestClock.advance(2_500)
            check(f.session.rows.drop(1).all { it.state == Session.State.Wait && it.handle != 0L })
            timer.run()
            TestClock.advance(12_500)
            check(f.session.active && f.svc.inserted.isEmpty() && Native.freed.isEmpty())
            equal(0, f.svc.sends)
            f.final(Channel.B)
            check(f.session.rows[2].state == Session.State.Wait)
            f.final(Channel.C, "late final")
            check(f.session.active && f.svc.inserted.isEmpty() && Native.jev.isEmpty())
            f.session.choose(2)
            equal(listOf("late final"), f.svc.inserted)
            f.noDuplicateFrees()
        }
    }

    for (send in listOf(false, true)) {
        for (configError in listOf(null, "disabled", "invalid configuration")) {
            test("pending manual choice with Jev=$configError falls back and honors chooseSend=$send") {
                val f = Fixture {
                    App.prefs.multi = listOf(Channel.A, Channel.B)
                    App.prefs.pickSend = !send
                    Native.jevError = configError
                }
                f.final(Channel.A)
                f.session.choose(1, send)
                check(!f.session.recording)
                TestClock.advance(2_500)
                equal(listOf("a"), f.svc.inserted)
                equal(if (send) 1 else 0, f.svc.sends)
                check(Native.jev.isEmpty())
                f.noDuplicateFrees()
            }
        }
    }

    test("pending choice falls back immediately when selected row reports error") {
        val f = Fixture { App.prefs.multi = listOf(Channel.A, Channel.B) }
        f.final(Channel.A)
        f.session.choose(1, true)
        val timer = f.grace()
        f.emit(Channel.B, Native.ERROR, "failed")
        equal(listOf("a"), f.svc.inserted)
        equal(1, f.svc.sends)
        check(TestClock.pending().none { it.runnable === timer })
        timer.run()
        equal(listOf("a"), f.svc.inserted)
        f.noDuplicateFrees()
    }

    test("next invalidates in-flight Jev and ignores its late callback") {
        val f = Fixture {
            App.prefs.multi = listOf(Channel.A, Channel.B)
            Native.jevError = null
            App.prefs.pickSend = true
        }
        f.completePair()
        f.session.next()
        equal(1, f.session.sel)
        f.jev(Native.FINAL, "{\"index\":0}")
        equal(1, f.session.sel)
        check(!f.session.jevBusy && f.session.active)
        check(f.svc.inserted.isEmpty())
        equal(0, f.svc.sends)
    }

    test("close cancels grace and old timer/native events cannot affect a new session") {
        val f = Fixture { Native.jevError = null }
        f.session.end()
        f.final(Channel.A)
        val timer = f.grace()
        f.session.abort(null)
        check(TestClock.pending().none { it.runnable === timer })
        check(f.originalRows.values.all { it.handle == 0L })
        f.session.holdStart()
        timer.run()
        for (kind in listOf(Native.PARTIAL, Native.FINAL, Native.RECONNECT, Native.ERROR)) {
            f.emit(Channel.B, kind, "stale")
        }
        check(f.session.recording)
        check(f.session.rows.all { it.state == Session.State.Listen && it.text.isEmpty() })
        check(f.svc.inserted.isEmpty())
        check(f.svc.hud.infos.isEmpty())
        check(f.svc.hud.errors.isEmpty())
        equal(3, Native.freed.size)
        f.noDuplicateFrees()
    }

    test("closed-session Jev callback cannot select in a new session") {
        val f = Fixture {
            App.prefs.multi = listOf(Channel.A, Channel.B)
            Native.jevError = null
            App.prefs.pickSend = true
        }
        f.completePair()
        f.session.abort(null)
        f.session.holdStart()
        f.jev(Native.FINAL, "{\"index\":1}")
        check(f.session.recording && !f.session.jevBusy)
        check(f.session.rows.all { it.state == Session.State.Listen })
        check(f.svc.inserted.isEmpty())
        equal(0, f.svc.sends)
    }

    test("single mode still inserts a final during recording immediately") {
        val f = Fixture {
            App.prefs.channel = Channel.A
            App.prefs.pickSend = true
            Native.jevError = null
        }
        f.final(Channel.A)
        equal(listOf("a"), f.svc.inserted)
        check(!f.session.active && !f.session.recording)
        equal(0, f.svc.sends)
        equal(0, App.prefs.pickCount(Channel.A))
        check(Native.jev.isEmpty())
        check(TestClock.pending().isEmpty())
    }

    test("single mode retains the 15 second timeout") {
        val f = Fixture { App.prefs.channel = Channel.A }
        f.session.end()
        TestClock.advance(15_000)
        check(!f.session.active)
        equal(listOf("识别超时"), f.svc.hud.errors)
        check(f.svc.inserted.isEmpty())
        check(Native.jev.isEmpty())
    }

    for ((participants, required) in listOf(2 to 2, 3 to 2, 4 to 3, 5 to 4, 6 to 4, 7 to 5, 8 to 6, 9 to 6)) {
        test("$participants participating channels advance at $required finals with upward rounding") {
            val f = Fixture {
                App.prefs.multi = Channel.entries.take(participants)
                Native.jevError = null
            }
            f.session.end()
            for (ch in Channel.entries.take(required - 1)) f.final(ch)
            check(!f.session.jevBusy)
            val timer = f.grace()
            f.final(Channel.entries[required - 1])
            check(f.session.jevBusy)
            equal(required, Native.jev.single().texts.size)
            check(TestClock.pending().none { it.runnable === timer })
            check(f.session.rows.drop(required).all { it.state == Session.State.Error && it.handle == 0L })
            timer.run()
            TestClock.advance(15_000)
            equal(1, Native.jev.size)
            check(f.session.jevBusy && f.svc.hud.errors.isEmpty())
            f.jev(Native.FINAL, "{\"index\":0}")
            check(f.session.active && !f.session.jevBusy && f.svc.inserted.isEmpty())
            for (ch in Channel.entries.take(participants).drop(required)) f.final(ch, "late")
            TestClock.advance(20_000)
            equal(1, Native.jev.size)
            check(f.svc.inserted.isEmpty())
            f.session.abort(null)
            f.noDuplicateFrees()
        }
    }

    test("recording-time threshold advances only at stop and preserves slow text") {
        val f = Fixture { Native.jevError = null }
        f.final(Channel.B)
        f.final(Channel.A)
        f.emit(Channel.C, Native.PARTIAL, "unfinished")
        check(!f.session.jevBusy && TestClock.pending().isEmpty())
        f.session.end()
        check(f.session.jevBusy)
        equal("unfinished", f.originalRows.getValue(Channel.C).text)
        equal(Session.State.Error, f.originalRows.getValue(Channel.C).state)
        f.noDuplicateFrees()
    }

    test("threshold cannot preempt an explicit pending slow channel") {
        val f = Fixture { Native.jevError = null }
        f.final(Channel.A)
        f.session.choose(2, true)
        val timer = f.grace()
        f.final(Channel.B)
        check(!f.session.jevBusy && f.session.active)
        equal(Session.State.Wait, f.originalRows.getValue(Channel.C).state)
        f.final(Channel.C)
        equal(listOf("c"), f.svc.inserted)
        equal(1, f.svc.sends)
        timer.run()
        equal(listOf("c"), f.svc.inserted)
        f.noDuplicateFrees()
    }

    println("$passed deterministic Session tests passed (real Session.kt; Android/Native fakes).")
}
