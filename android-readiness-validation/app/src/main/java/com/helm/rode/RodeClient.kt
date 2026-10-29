package com.helm.rode

import android.content.Context
import android.os.PowerManager
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

enum class RodeState { IDLE, PREPARING, LISTENING, THINKING, SPEAKING }
data class RodePresentation(val state: RodeState, val status: String) {
    val inputReady: Boolean get() = state == RodeState.LISTENING
}

/** iPhone owns official CXR microphone capture, VAD, HTTP and TTS. */
@Suppress("UNUSED_PARAMETER")
class RodeClient(
    context: Context,
    chatUrl: String,
    token: String,
    private val listener: Listener,
    ttsEnabled: Boolean = true,
) {
    interface Listener {
        fun onState(state: RodeState)
        fun onPresentation(value: RodePresentation) { onState(value.state); onStatus(value.status) }
        fun onUserText(text: String)
        fun onAssistantDelta(text: String)
        fun onAssistantText(text: String)
        fun onError(message: String)
        fun onStatus(text: String)
        fun onMeta(model: String, usage5h: String, usage7d: String)
        fun onSessionEnded()
        fun onSpeechStarted(turnID: String) {}
        fun onUserTurn(turnID: String, text: String) { onUserText(text) }
        fun onAnswerTurn(turnID: String, text: String) { onAssistantText(text) }
        fun onTurnError(turnID: String, text: String) { onError(text) }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val wakeLock = (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "totti-ai:cxr-turn")
    private var turnJob: Job? = null
    private var sessionActive = false
    private var captureReadyOnce = false
    private var generation = 0
    @Volatile private var state = RodeState.IDLE
    val currentState get() = state
    // PCM stays on the phone. No artificial amplitude is displayed on the glasses.
    fun currentAmplitude(): Float = 0f
    fun start() { Log.i("TottiClient", "BUILD audio-rollback-20261019.1"); if (state == RodeState.IDLE) setState(RodeState.IDLE) }

    fun onTap() {
        when (state) {
            RodeState.IDLE -> { captureReadyOnce = false; TottiVoiceRelay.beginSession(); sessionActive = true; startListening() }
            RodeState.PREPARING -> cancel()
            RodeState.LISTENING -> {
                TottiVoiceRelay.stopListening()
                setState(RodeState.THINKING)
                listener.onStatus("音声取得を終了しています…")
            }
            RodeState.THINKING -> cancel()
            RodeState.SPEAKING -> {
                // Cancel phone speech and the old turn before starting another microphone turn.
                stopTurn()
                if (sessionActive) startListening() else setState(RodeState.IDLE)
            }
        }
    }

    fun onAnswerRendered() {
        // HUD completion does not mean that iPhone speech has finished.
        // Wait for totti_turn_done from the actual phone speech callback.
    }

    private fun startListening() {
        if (!sessionActive) { setState(RodeState.IDLE); return }
        val previous = turnJob
        previous?.cancel()
        val turn = ++generation
        setState(RodeState.PREPARING, "音声入力を準備しています…")
        runCatching { if (!wakeLock.isHeld) wakeLock.acquire(245_000L) }
        // Schedule, rather than run immediately, so turnJob is installed before callbacks.
        turnJob = scope.launch(Dispatchers.Main) {
            try {
                previous?.join()
                if (previous != null) delay(350L)
                if (generation != turn || !sessionActive) return@launch
                val connected = kotlinx.coroutines.withTimeoutOrNull(30_000L) {
                    while (!CxrProbe.isReady) delay(100L)
                    true
                } ?: false
                if (!connected) throw IllegalStateException("iPhoneとの接続準備が30秒以内に完了しませんでした。")
                var inputEpoch = 0L
                TottiVoiceRelay.listen { event ->
                    if (generation == turn && sessionActive) {
                        val text = event.optString("message")
                        when (event.optString("type")) {
                            "totti_listening" -> {
                                val epoch = event.optString("input_epoch").toLongOrNull() ?: 0L
                                if (epoch >= inputEpoch) {
                                    inputEpoch = epoch
                                    captureReadyOnce = true; setState(RodeState.LISTENING, "話しかけてください")
                                }
                            }
                            "totti_input_preparing" -> {
                                val epoch = event.optString("input_epoch").toLongOrNull() ?: -1L
                                if (epoch > inputEpoch) {
                                    inputEpoch = epoch
                                    setState(RodeState.PREPARING, "音声入力を準備しています…")
                                }
                            }
                            "totti_thinking" -> {
                                setState(RodeState.THINKING)
                                listener.onStatus("考えています…")
                                listener.onUserTurn(event.optString("request_id"), event.optString("text"))
                            }
                            "totti_processing" -> {
                                setState(RodeState.THINKING); listener.onStatus(text)
                            }
                            "totti_status" -> if (state == RodeState.PREPARING) listener.onStatus(text)
                            "totti_user" -> listener.onUserTurn(event.optString("request_id"), text)
                            "totti_answer" -> {
                                setState(RodeState.SPEAKING); listener.onAnswerTurn(event.optString("request_id"), text)
                            }
                            "totti_audio_status" -> Log.i("TottiClient", "PHONE_TTS: $text")
                            "totti_audio_error" -> listener.onError(text)
                            "totti_session_end" -> {
                                sessionActive = false
                                setState(RodeState.IDLE)
                                listener.onSessionEnded()
                            }
                        }
                    }
                }
                if (generation == turn) {
                    turnJob = null
                    releaseLock()
                    if (sessionActive) startListening() else setState(RodeState.IDLE)
                }
            } catch (cancelled: CancellationException) {
                // An owned withTimeout (including relay.listen) leaves this Job active.
                // Parent/manual cancellation must remain cancellation, never a user error.
                if (cancelled is kotlinx.coroutines.TimeoutCancellationException &&
                    kotlinx.coroutines.currentCoroutineContext()[Job]?.isActive == true) {
                    failTurn(turn, IllegalStateException("iPhone音声処理がタイムアウトしました。", cancelled))
                } else throw cancelled
            } catch (error: Throwable) {
                failTurn(turn, error)
            }
        }
    }

    private fun failTurn(turn: Int, error: Throwable) {
                if (generation == turn) {
                    Log.e("TottiClient", "Official CXR microphone turn failed", error)
                    // Do not loop endlessly on a broken microphone/network path.
                    sessionActive = false
                    turnJob = null
                    listener.onError(error.message ?: "iPhone音声処理に失敗しました。")
                    setState(RodeState.IDLE)
                    releaseLock()
                }
    }

    private fun stopTurn() {
        generation += 1
        // Keep the cancelled Job until startListening joins it; its finally sends cancel first.
        turnJob?.cancel()
        releaseLock()
    }
    fun cancel() { sessionActive = false; stopTurn(); setState(RodeState.IDLE) }
    fun pause() { cancel() }
    fun release() { cancel(); scope.cancel() }
    private fun releaseLock() { runCatching { if (wakeLock.isHeld) wakeLock.release() } }
    private fun setState(value: RodeState, status: String = "") {
        state = value; Log.d("TottiClient", "state->$value")
        listener.onPresentation(RodePresentation(value, status))
    }
}
