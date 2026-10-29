package com.helm.rode

import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import com.helm.rode.databinding.ActivityMainBinding
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class ReadinessPresentationTest {
    private lateinit var activity: MainActivity
    private lateinit var binding: ActivityMainBinding
    @Before fun prepare() {
        // Do not start CXRServiceBridge/native Bluetooth or run the real onCreate.
        activity = Robolectric.buildActivity(MainActivity::class.java).get()
        activity.setTheme(R.style.Theme_RokidOpenAIRealtimeExample)
        binding = ActivityMainBinding.inflate(LayoutInflater.from(activity))
        MainActivity::class.java.getDeclaredField("binding").apply { isAccessible = true }.set(activity, binding)
        binding.waveform.idleHint = ""
    }
    private fun status(): TextView = MainActivity::class.java.getDeclaredField("tottiHudStatus")
        .apply { isAccessible = true }.get(activity) as TextView
    private fun texts(view: View): List<String> {
        val own = if (view is TextView) listOf(view.text.toString()) else emptyList()
        return own + if (view is ViewGroup) (0 until view.childCount).flatMap { texts(view.getChildAt(it)) } else emptyList()
    }
    @Test fun preparationDoesNotAdvertiseReady() {
        activity.onPresentation(RodePresentation(RodeState.PREPARING, "音声入力を準備しています…"))
        assertEquals(WaveformView.Mode.IDLE, binding.waveform.mode)
        assertEquals("音声入力を準備しています…", status().text.toString())
        assertEquals(View.VISIBLE, status().visibility)
    }
    @Test fun readyLabelAndModeArriveInSameMainLooperDelivery() {
        activity.onPresentation(RodePresentation(RodeState.PREPARING, "準備中"))
        val thread = Thread { activity.onPresentation(RodePresentation(RodeState.LISTENING, "話しかけてください")) }
        thread.start(); thread.join()
        assertEquals(WaveformView.Mode.IDLE, binding.waveform.mode)
        assertEquals("準備中", status().text.toString())
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(WaveformView.Mode.LISTENING, binding.waveform.mode)
        assertEquals("話しかけてください", status().text.toString())
    }
    @Test fun previousAnswerRemainsThroughPreparationAndNextReady() {
        activity.onUserTurn("previous", "前の質問")
        activity.onAnswerTurn("previous", "前の回答全文")
        shadowOf(Looper.getMainLooper()).idle()
        val before = texts(binding.conversation)
        assertTrue(before.any { it.contains("前の回答全文") })
        activity.onPresentation(RodePresentation(RodeState.PREPARING, "準備中"))
        activity.onPresentation(RodePresentation(RodeState.LISTENING, "話しかけてください"))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(before, texts(binding.conversation))
    }
    @Test fun endingClearsReadyModeAndLabelTogether() {
        activity.onPresentation(RodePresentation(RodeState.LISTENING, "話しかけてください"))
        activity.onPresentation(RodePresentation(RodeState.IDLE, ""))
        assertEquals(WaveformView.Mode.IDLE, binding.waveform.mode)
        assertEquals("", status().text.toString())
        assertEquals(View.INVISIBLE, status().visibility)
    }
}
