package com.helm.rode

import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Only control messages cross custom-command channels. No WAV/base64 audio. */
object TottiVoiceRelay {
    private var sessionID = UUID.randomUUID().toString()
    fun beginSession() { sessionID = UUID.randomUUID().toString() }
    private class Turn(val onEvent: (JSONObject) -> Unit) {
        val started = CompletableDeferred<Unit>()
        val done = CompletableDeferred<Unit>()
    }
    private val turns = ConcurrentHashMap<String, Turn>()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var activeID: String? = null

    fun receive(event: JSONObject): Boolean {
        val id = event.optString("request_id")
        val turn = turns[id] ?: return false
        main.post {
            if (turns[id] !== turn) return@post
            when (event.optString("type")) {
                "totti_listening" -> {
                    turn.started.complete(Unit)
                    turn.onEvent(event)
                }
                "totti_session_end" -> {
                    turn.onEvent(event)
                    turn.done.complete(Unit)
                }
                "totti_mic_ack" -> if (event.optString("message") == "start") turn.started.complete(Unit)
                "totti_turn_done" -> turn.done.complete(Unit)
                "totti_error" -> {
                    val error = IllegalStateException(event.optString("message", "iPhone音声処理エラー"))
                    turn.started.completeExceptionally(error)
                    turn.done.completeExceptionally(error)
                }
                else -> turn.onEvent(event)
            }
        }
        return true
    }

    suspend fun listen(onEvent: (JSONObject) -> Unit) {
        check(activeID == null) { "前の音声処理が終了していません。" }
        val id = UUID.randomUUID().toString()
        val turn = Turn(onEvent)
        turns[id] = turn
        activeID = id
        var completed = false
        try {
            withTimeout(240_000L) {
                var accepted = false
                for (attempt in 0 until 3) {
                    val rc = send("totti_mic_start", id)
                    Log.i("TottiCXR", "MIC_START id=$id attempt=$attempt rc=$rc")
                    if (withTimeoutOrNull(20_000L) { turn.started.await(); true } == true) {
                        accepted = true; break
                    }
                }
                check(accepted) { "iPhoneから音声開始の応答がありません。アプリの接続を確認してください。" }
                turn.done.await()
                completed = true
            }
        } finally {
            turns.remove(id)
            if (activeID == id) activeID = null
            if (!completed) runCatching { send("totti_mic_cancel", id) }
        }
    }

    fun stopListening() {
        val id = activeID ?: return
        // Same UUID makes duplicate requests harmless, including the retry below.
        send("totti_mic_stop", id)
        main.postDelayed({
            if (activeID == id) send("totti_mic_stop", id)
        }, 1_000L)
    }

    private fun send(type: String, id: String): Int = CxrProbe.sendCommand(
        JSONObject().put("type", type).put("request_id", id).put("session_id", sessionID)
    )
}
