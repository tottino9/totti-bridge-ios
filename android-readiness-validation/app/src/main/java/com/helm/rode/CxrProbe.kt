package com.helm.rode
import android.util.Log
import android.os.Handler
import android.os.Looper
import com.rokid.cxr.CXRServiceBridge
import com.rokid.cxr.Caps
import org.json.JSONObject

object CxrProbe {
    @Volatile var onPong: ((String) -> Unit)? = null
    @Volatile var isReady = false
        private set
    private var started = false
    private val bridge = CXRServiceBridge()
    private val main = Handler(Looper.getMainLooper())
    private var attempts = 0
    private val ping = object : Runnable {
        override fun run() {
            if (isReady) return
            if (++attempts > 18) {
                onPong?.invoke("iPhoneから確認応答が届きませんでした。")
                return
            }
            sendCommand(JSONObject().put("type", "totti_ping").put("message", "TOTTI_PING"))
            main.postDelayed(this, 5000L)
        }
    }
    fun sendCommand(message: JSONObject): Int =
        bridge.sendMessage("rk_custom_key", Caps().apply { write(message.toString()) })

    @Synchronized fun start() {
        if (started) return
        started = true
        bridge.setStatusListener(object : CXRServiceBridge.StatusListener {
            override fun onConnected(deviceName: String, deviceType: Int) {
                main.post {
                    isReady = false
                    main.removeCallbacks(ping)
                    attempts = 0
                    main.post(ping)
                }
            }
            override fun onDisconnected() {
                isReady = false
                main.post { main.removeCallbacks(ping) }
                Log.d("TottiCXR", "DISCONNECTED")
            }
            override fun onARTCStatus(value: Float, active: Boolean) {}
        })
        val callback = object : CXRServiceBridge.MsgCallback {
            override fun onReceive(key: String, caps: Caps?, data: ByteArray?) {
                if (key != "rk_custom_client") return
                try {
                    val texts = linkedSetOf<String>()
                    if (data != null && data.isNotEmpty()) texts.add(data.toString(Charsets.UTF_8))
                    if (caps != null) for (i in 0 until caps.size()) {
                        val value = caps.at(i)
                        when (value.type()) {
                            'S' -> texts.add(value.getString())
                            'B' -> {
                                val b = value.getBinary()
                                texts.add(b.data.copyOfRange(b.offset, b.offset + b.length).toString(Charsets.UTF_8))
                            }
                        }
                    }
                    for (text in texts) {
                        val event = runCatching { JSONObject(text) }.getOrNull() ?: continue
                        main.post {
                            if (event.optString("type") == "totti_pong") {
                                isReady = true
                                main.removeCallbacks(ping)
                                Log.d("TottiCXR", "TOTTI_PONG RECEIVED: ROUND_TRIP_OK")
                                onPong?.invoke("iPhone接続成功")
                            } else {
                                TottiVoiceRelay.receive(event)
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e("TottiCXR", "RX decode failed", e)
                }
            }
        }
        val rc = bridge.subscribe("rk_custom_client", callback)
        Log.d("TottiCXR", "subscribe phone rc=$rc")
    }
}
