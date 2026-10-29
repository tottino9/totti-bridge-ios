package com.helm.rode

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.helm.rode.databinding.ActivityMainBinding
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class MainActivity :
    AppCompatActivity(),
    RodeClient.Listener {

    private lateinit var binding:
        ActivityMainBinding

    private var client:
        RodeClient? = null

    /*
     * 3連タップから起動された場合だけtrue。
     *
     * trueなら最初の物理タップを省略して
     * 自動的にtotti-ai会話を開始する。
     */
    private var autoStartRequested =
        false

    private val uiHandler =
        android.os.Handler(
            android.os.Looper.getMainLooper()
        )

    private var previousState:
        RodeState =
        RodeState.IDLE

    private var streamingView:
        TextView? = null

    private val streamTarget =
        StringBuilder()

    private var revealedLen =
        0

    private var streamEnded =
        false

    private var streamFinal:
        String? = null

    private var ticking =
        false

    companion object {

        private const val TAG =
            "TottiActivity"

        private const val REQ_PERMISSIONS =
            1001

        private const val GREEN =
            0xFF45F068.toInt()

        private const val GREEN_DIM =
            0xFF7FC99A.toInt()

        private const val SCROLL_STEP =
            200

        private const val HUD_CLEAR_DELAY_MS =
            1500L
    }

    private val chatUrl:
        String by lazy {

        RodeConfig.chatUrl(
            this
        )
    }

    private val clearHudRunnable =
        Runnable {

            clearConversation()
        }


    private val cxrPongListener: (String) -> Unit = { message ->
        runOnUiThread {
            if (!isFinishing && !isDestroyed &&
                (client?.currentState ?: RodeState.IDLE) == RodeState.IDLE && hudTurns.isEmpty()) {
                uiHandler.removeCallbacks(clearHudRunnable)
                clearConversation()
                addTurn(
                    "totti ai\n$message",
                    isTotti = true
                )
                Log.d(TAG, "CXR_HUD_UPDATED message=$message")
            }
        }
    }

    override fun onCreate(
        savedInstanceState: Bundle?
    ) {

        super.onCreate(
            savedInstanceState
        )

        /*
         * AccessibilityServiceから
         * AUTO_START_SESSION=trueで来たか確認。
         */
        autoStartRequested =
            intent?.getBooleanExtra(
                "AUTO_START_SESSION",
                false
            ) ?: false

        Log.d(
            TAG,
            "onCreate autoStart=$autoStartRequested"
        )

        binding =
            ActivityMainBinding.inflate(
                layoutInflater
            )

        setContentView(
            binding.root
        )

        window.addFlags(
            WindowManager.LayoutParams
                .FLAG_KEEP_SCREEN_ON
        )

        binding.header.text =
            "totti-ai"

        /*
         * 旧RODEのタップ説明は表示しない。
         */
        binding.waveform.idleHint =
            ""

        binding.waveform.mode =
            WaveformView.Mode.IDLE

        binding.waveform.amplitudeProvider = {

            client?.currentAmplitude()
                ?: 0f
        }

        clearConversation()

        setupStatusBar()

        CxrProbe.onPong = cxrPongListener
        CxrProbe.start()

        ensureUsableNetwork()

        ensurePermissions()
    }


    /*
     * FLAG_ACTIVITY_SINGLE_TOPで
     * 既存Activityに3連タップIntentが届いた場合。
     */
    override fun onNewIntent(
        intent: Intent
    ) {

        super.onNewIntent(
            intent
        )

        setIntent(
            intent
        )

        val requested =
            intent.getBooleanExtra(
                "AUTO_START_SESSION",
                false
            )

        Log.d(
            TAG,
            "onNewIntent autoStart=$requested"
        )

        if (
            requested
        ) {

            autoStartRequested =
                true

            startAutoSessionIfReady()
        }
    }


    /*
     * 3連タップ起動だった場合、
     * 最初の1タップを自動実行する。
     */
    private fun startAutoSessionIfReady() {

        if (
            !autoStartRequested
        ) {
            return
        }

        val currentClient =
            client
                ?: return

        if (
            currentClient.currentState !=
            RodeState.IDLE
        ) {
            return
        }

        autoStartRequested =
            false

        clearConversation()

        /*
         * RodeClientのIDLE時onTap()が
         * sessionActive=true
         * ↓
         * startListening()
         * を実行する。
         */
        currentClient.onTap()

        Log.d(
            TAG,
            "auto session started"
        )
    }



    /*
     * 通信自動復旧。
     *
     * 有効なインターネット回線がある場合は何もしない。
     * 無い場合だけWi-FiをONにする。
     */
    private fun ensureUsableNetwork() {
        // Internet requests run on the iPhone. Do not turn on glasses Wi-Fi.
    }

    private val statusReceiver =
        object :
            android.content.BroadcastReceiver() {

            override fun onReceive(
                context:
                    android.content.Context?,
                intent:
                    android.content.Intent?
            ) {

                updateStatusBar()
            }
        }


    private val pingScope =
        kotlinx.coroutines.CoroutineScope(
            kotlinx.coroutines.SupervisorJob() +
                kotlinx.coroutines.Dispatchers.Main
        )


    private var pingJob:
        kotlinx.coroutines.Job? =
        null


    private val backendRoot:
        String by lazy {

        chatUrl
            .substringBefore(
                "/glasses"
            )
            .ifEmpty {
                chatUrl
            } + "/"
    }


    private fun startPing() {

        if (
            pingJob?.isActive ==
            true
        ) {
            return
        }

        pingJob =
            pingScope.launch {

                while (
                    isActive
                ) {

                    val ok = CxrProbe.isReady

                    val level =
                        if (ok) 3 else -1


                    binding.sbConn
                        .setImageResource(

                            when (
                                level
                            ) {

                                -1 ->
                                    R.drawable
                                        .ic_sb_wifi_off

                                0 ->
                                    R.drawable
                                        .ic_sb_wifi_0

                                1 ->
                                    R.drawable
                                        .ic_sb_wifi_1

                                2 ->
                                    R.drawable
                                        .ic_sb_wifi_2

                                else ->
                                    R.drawable
                                        .ic_sb_wifi_3
                            }
                        )


                    binding.sbConn.alpha =

                        if (
                            level ==
                            -1
                        ) {

                            1f

                        } else if (
                            ok
                        ) {

                            1f

                        } else {

                            0.28f
                        }


                    kotlinx.coroutines
                        .delay(
                            4000
                        )
                }
            }
    }


    private fun wifiLevel():
        Int {

        return try {

            val cm =
                getSystemService(
                    android.content.Context
                        .CONNECTIVITY_SERVICE
                ) as
                    android.net
                        .ConnectivityManager


            val capabilities =
                cm.getNetworkCapabilities(
                    cm.activeNetwork
                )


            if (
                capabilities !=
                null &&
                capabilities
                    .hasTransport(
                        android.net
                            .NetworkCapabilities
                            .TRANSPORT_WIFI
                    )
            ) {

                val rssi =
                    capabilities
                        .signalStrength


                if (
                    rssi ==
                    Int.MIN_VALUE
                ) {

                    3

                } else {

                    android.net
                        .wifi
                        .WifiManager
                        .calculateSignalLevel(
                            rssi,
                            4
                        )
                        .coerceIn(
                            0,
                            3
                        )
                }

            } else {

                -1
            }

        } catch (
            _: Throwable
        ) {

            -1
        }
    }


    private fun setupStatusBar() {

        val filter =
            android.content
                .IntentFilter()
                .apply {

                    addAction(
                        android.content
                            .Intent
                            .ACTION_TIME_TICK
                    )

                    addAction(
                        android.content
                            .Intent
                            .ACTION_BATTERY_CHANGED
                    )
                }


        registerReceiver(
            statusReceiver,
            filter
        )

        updateStatusBar()
    }


    private fun updateStatusBar() {

        val now =
            java.util.Calendar
                .getInstance()


        binding.sbTime.text =
            String.format(
                "%02d:%02d",

                now.get(
                    java.util.Calendar
                        .HOUR_OF_DAY
                ),

                now.get(
                    java.util.Calendar
                        .MINUTE
                )
            )


        val battery =
            registerReceiver(
                null,

                android.content
                    .IntentFilter(
                        android.content
                            .Intent
                            .ACTION_BATTERY_CHANGED
                    )
            )


        val level =
            battery
                ?.getIntExtra(
                    android.os
                        .BatteryManager
                        .EXTRA_LEVEL,
                    -1
                )
                ?: -1


        val scale =
            battery
                ?.getIntExtra(
                    android.os
                        .BatteryManager
                        .EXTRA_SCALE,
                    100
                )
                ?: 100


        val percent =

            if (
                level >= 0
            ) {

                level *
                    100 /
                    scale

            } else {

                -1
            }


        binding.sbBatteryPct.text =

            if (
                percent >= 0
            ) {

                "$percent"

            } else {

                "--"
            }


        val status =
            battery
                ?.getIntExtra(
                    android.os
                        .BatteryManager
                        .EXTRA_STATUS,
                    -1
                )
                ?: -1


        val plugged =
            battery
                ?.getIntExtra(
                    android.os
                        .BatteryManager
                        .EXTRA_PLUGGED,
                    0
                )
                ?: 0


        val charging =

            plugged != 0 ||

            status ==
                android.os
                    .BatteryManager
                    .BATTERY_STATUS_CHARGING ||

            status ==
                android.os
                    .BatteryManager
                    .BATTERY_STATUS_FULL


        binding.sbBattery
            .setImageResource(

                if (
                    charging
                ) {

                    R.drawable
                        .ic_sb_battery_charging

                } else {

                    R.drawable
                        .ic_sb_battery
                }
            )
    }


    private fun ensurePermissions() {

        val needed =
            listOf(
                Manifest.permission
                    .RECORD_AUDIO,
                Manifest.permission
                    .CAMERA
            )
                .filter {

                    ContextCompat
                        .checkSelfPermission(
                            this,
                            it
                        ) !=
                        PackageManager
                            .PERMISSION_GRANTED
                }


        if (
            needed.isEmpty()
        ) {

            startClient()

        } else {

            ActivityCompat
                .requestPermissions(
                    this,
                    needed.toTypedArray(),
                    REQ_PERMISSIONS
                )
        }
    }


    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions:
            Array<out String>,
        grantResults:
            IntArray
    ) {

        super
            .onRequestPermissionsResult(
                requestCode,
                permissions,
                grantResults
            )


        if (
            requestCode ==
            REQ_PERMISSIONS
        ) {

            if (
                ContextCompat
                    .checkSelfPermission(
                        this,
                        Manifest.permission
                            .RECORD_AUDIO
                    ) ==
                PackageManager
                    .PERMISSION_GRANTED
            ) {

                startClient()

            } else {

                appendSystem(
                    getString(
                        R.string
                            .err_mic_denied
                    )
                )
            }
        }
    }


    private fun startClient() {

        if (
            client ==
            null
        ) {

            client =
                RodeClient(
                    applicationContext,
                    chatUrl,
                    RodeConfig.token(
                        this
                    ),
                    this,
                    RodeConfig.ttsEnabled(
                        this
                    )
                )
        }

        client?.start()

        /*
         * AccessibilityServiceから来た場合、
         * client生成完了後に自動会話開始。
         */
        startAutoSessionIfReady()
    }


    override fun onResume() {

        super.onResume()

        startPing()

        if (
            client !=
            null &&
            ContextCompat
                .checkSelfPermission(
                    this,
                    Manifest.permission
                        .RECORD_AUDIO
                ) ==
            PackageManager
                .PERMISSION_GRANTED
        ) {

            client?.start()

            startAutoSessionIfReady()
        }
    }


    override fun onPause() {

        pingJob?.cancel()

        uiHandler.removeCallbacks(
            clearHudRunnable
        )

        client?.pause()

        super.onPause()
    }


    /*
     * 従来の物理タップ起動も
     * 非常用として残す。
     */
    override fun onKeyDown(
        keyCode: Int,
        event: KeyEvent?
    ): Boolean {

        Log.d(
            TAG,
            "onKeyDown code=$keyCode"
        )


        when (
            keyCode
        ) {

            KeyEvent.KEYCODE_ENTER -> {

                if (
                    event?.repeatCount ==
                    0
                ) {

                    if (
                        client
                            ?.currentState ==
                        RodeState.IDLE
                    ) {

                        clearConversation()
                    }

                    client?.onTap()
                }

                return true
            }


            KeyEvent.KEYCODE_DPAD_DOWN -> {

                binding.scrollView
                    .smoothScrollBy(
                        0,
                        -SCROLL_STEP
                    )

                return true
            }


            KeyEvent.KEYCODE_DPAD_UP -> {

                binding.scrollView
                    .smoothScrollBy(
                        0,
                        SCROLL_STEP
                    )

                return true
            }


            KeyEvent.KEYCODE_BACK -> {

                client?.cancel()

                clearConversation()

                finish()

                return true
            }
        }


        return super.onKeyDown(
            keyCode,
            event
        )
    }


    override fun onDestroy() {
        if (CxrProbe.onPong === cxrPongListener) {
            CxrProbe.onPong = null
        }

        window.clearFlags(
            WindowManager.LayoutParams
                .FLAG_KEEP_SCREEN_ON
        )

        try {

            unregisterReceiver(
                statusReceiver
            )

        } catch (
            _: Throwable
        ) {
        }


        uiHandler.removeCallbacks(
            tickRunnable
        )

        uiHandler.removeCallbacks(
            clearHudRunnable
        )

        pingScope.cancel()

        client?.release()

        client =
            null

        super.onDestroy()
    }


    // =========================================================
    // RodeClient.Listener
    // =========================================================

    override fun onState(
        state: RodeState
    ) =
        runOnUiThread {

            setTottiHudStatus("")
            val oldState = previousState

            previousState =
                state


            binding.waveform.mode =

                when (
                    state
                ) {

                    RodeState.IDLE ->
                        WaveformView
                            .Mode.IDLE

                    RodeState.LISTENING ->
                        WaveformView
                            .Mode.LISTENING

                    RodeState.THINKING ->
                        WaveformView
                            .Mode.THINKING

                    RodeState.SPEAKING ->
                        WaveformView
                            .Mode.ANSWER
                }


            /*
             * 1ラリー終了後、
             * 次のLISTENINGへ戻ったら
             * HUD本文を消す。
             */
            if (
                state ==
                RodeState.LISTENING &&
                (
                    oldState ==
                        RodeState.SPEAKING ||
                    oldState ==
                        RodeState.THINKING
                )
            ) {

                uiHandler.removeCallbacks(
                    clearHudRunnable
                )

                // Keep the answer visible until the next recognized user turn.
            }
        }


    // TOTTI_KEYED_TURNS_V1: late answers update their own question, never another turn.
    private data class HudTurn(var user: String = "", var answer: String = "", var accepted: Boolean = false,
        var userView: TextView? = null, var answerView: TextView? = null)
    private val hudTurns = linkedMapOf<String, HudTurn>()
    private val hudVisible = mutableListOf<String>()
    private fun hudTurn(id: String): HudTurn = hudTurns.getOrPut(id) { HudTurn() }
    private fun showHudTurn(id: String, type: String) {
        val started = android.os.SystemClock.elapsedRealtime()
        val row = hudTurn(id)
        // Retain all session text; only the last eight touched pairs stay attached.
        // Existing views are updated in place instead of rebuilding the whole HUD.
        if (!hudVisible.contains(id)) {
            while (hudVisible.size >= 8) {
                val old = hudTurns[hudVisible.removeAt(0)] ?: continue
                old.userView?.let { binding.conversation.removeView(it) }
                old.answerView?.let { binding.conversation.removeView(it) }
                old.userView = null; old.answerView = null
            }
            row.userView = newLineView(false)
            row.answerView = newLineView(true)
        }
        hudVisible.remove(id); hudVisible.add(id)
        row.userView?.let { if (it.text.toString() != row.user) it.text = row.user
            it.visibility = if (row.user.isBlank()) android.view.View.GONE else android.view.View.VISIBLE }
        row.answerView?.let { if (it.text.toString() != row.answer) it.text = row.answer
            it.visibility = if (row.answer.isBlank()) android.view.View.GONE else android.view.View.VISIBLE }
        uiHandler.removeCallbacks(tickRunnable); ticking = false
        binding.scrollView.post {
            // Show the corresponding question even when this is an old, late answer.
            row.userView?.let { binding.scrollView.scrollTo(0, it.top) }
            Log.i(TAG, "HUD_APPLIED turn=$id type=$type render_ms=${android.os.SystemClock.elapsedRealtime() - started}")
        }
    }
    override fun onSpeechStarted(turnID: String) = Unit
    override fun onUserTurn(turnID: String, text: String) = runOnUiThread {
        if (turnID.isBlank() || text.isBlank()) return@runOnUiThread
        val row = hudTurn(turnID)
        row.user = text
        if (!row.accepted) { row.accepted = true; binding.waveform.flashAccepted() }
        showHudTurn(turnID, "user")
    }
    override fun onAnswerTurn(turnID: String, text: String) = runOnUiThread {
        if (turnID.isBlank() || text.isBlank()) return@runOnUiThread
        hudTurn(turnID).answer = text
        showHudTurn(turnID, "answer")
    }
    override fun onTurnError(turnID: String, text: String) = runOnUiThread {
        if (turnID.isNotBlank()) { hudTurn(turnID).answer = text; showHudTurn(turnID, "error") }
        else appendSystem(text)
    }

    override fun onUserText(
        text: String
    ) =
        runOnUiThread {

            uiHandler.removeCallbacks(
                clearHudRunnable
            )

            clearConversation()

            addTurn(
                text,
                isTotti =
                    false
            )
        }


    override fun onAssistantDelta(
        text: String
    ) =
        runOnUiThread {

            if (
                text.isEmpty()
            ) {
                return@runOnUiThread
            }


            uiHandler.removeCallbacks(
                clearHudRunnable
            )


            if (
                streamingView ==
                null
            ) {

                streamingView =
                    newLineView(
                        isTotti =
                            true
                    )

                streamTarget.setLength(
                    0
                )

                revealedLen =
                    0

                streamEnded =
                    false

                streamFinal =
                    null
            }


            streamTarget.append(
                text
            )

            startTicker()
        }


    override fun onAssistantText(
        text: String
    ) =
        runOnUiThread {

            uiHandler.removeCallbacks(
                clearHudRunnable
            )


            if (
                streamingView !=
                null
            ) {

                streamFinal =

                    if (
                        text.isNotBlank()
                    ) {

                        text

                    } else {

                        streamTarget.toString()
                    }


                streamTarget.setLength(
                    0
                )

                streamTarget.append(
                    streamFinal
                )

                streamEnded =
                    true

                startTicker()

            } else {

                addTurn(
                    text,
                    isTotti =
                        true
                )
            }
        }


    override fun onError(
        message: String
    ) =
        runOnUiThread {

            resetStreaming()

            appendSystem(
                message
            )
        }


    // TOTTI_PERSISTENT_HUD_V1
    private var tottiHudStatus: TextView? = null

    private fun setTottiHudStatus(text: String) {
        val label = tottiHudStatus ?: TextView(this).apply {
            setTextColor(GREEN_DIM)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            gravity = Gravity.CENTER
            maxLines = 2
            val container = binding.waveform.parent as LinearLayout
            container.addView(
                this,
                container.indexOfChild(binding.waveform),
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            )
            tottiHudStatus = this
        }
        if (label.text.toString() == text) return
        label.text = text
        label.visibility = if (text.isBlank()) android.view.View.INVISIBLE else android.view.View.VISIBLE
    }

    override fun onStatus(text: String) = runOnUiThread {
        binding.waveform.showThinking = previousState == RodeState.THINKING
        uiHandler.removeCallbacks(clearHudRunnable)
        setTottiHudStatus(text)
    }



    override fun onMeta(
        model: String,
        usage5h: String,
        usage7d: String
    ) =
        runOnUiThread {

            val parts =
                mutableListOf<String>()


            if (
                model.isNotBlank()
            ) {

                parts +=
                    model
            }


            if (
                usage5h.isNotBlank()
            ) {

                parts +=
                    "5h $usage5h"
            }


            if (
                usage7d.isNotBlank()
            ) {

                parts +=
                    "7d $usage7d"
            }


            binding.sbUsage.text =
                parts.joinToString(
                    " · "
                )
        }


    /*
     * 「バイバイ」でここに来る。
     *
     * totti-aiを閉じて
     * Rokid通常画面へ戻る。
     */
    override fun onSessionEnded() =
        runOnUiThread {

            autoStartRequested =
                false

            uiHandler.removeCallbacks(
                clearHudRunnable
            )

            clearConversation()

            finish()
        }


    // =========================================================
    // HUD
    // =========================================================

    private fun clearConversation() {
        hudTurns.clear()
        hudVisible.clear()

        uiHandler.removeCallbacks(
            tickRunnable
        )

        ticking =
            false

        resetStreaming()

        binding.conversation
            .removeAllViews()
    }


    private fun resetStreaming() {

        streamingView =
            null

        streamTarget.setLength(
            0
        )

        revealedLen =
            0

        streamEnded =
            false

        streamFinal =
            null
    }


    private fun addTurn(
        text: String,
        isTotti: Boolean
    ) {

        if (
            text.isBlank()
        ) {
            return
        }


        renderTurn(
            text,
            isTotti
        )


        binding.scrollView.post {

            binding.scrollView
                .fullScroll(
                    android.view.View
                        .FOCUS_DOWN
                )
        }
    }


    private fun newLineView(
        isTotti: Boolean
    ): TextView {

        val tv =
            TextView(
                this
            ).apply {

                setTextColor(

                    if (
                        isTotti
                    ) {

                        GREEN

                    } else {

                        GREEN_DIM
                    }
                )

                setTextSize(
                    TypedValue
                        .COMPLEX_UNIT_SP,
                    12f
                )

                gravity =

                    if (
                        isTotti
                    ) {

                        Gravity.START

                    } else {

                        Gravity.END
                    }

                setLineSpacing(
                    0f,
                    1.1f
                )
            }


        val params =
            LinearLayout
                .LayoutParams(
                    LinearLayout
                        .LayoutParams
                        .MATCH_PARENT,

                    LinearLayout
                        .LayoutParams
                        .WRAP_CONTENT
                )
                .apply {

                    topMargin =
                        10
                }


        binding.conversation.addView(
            tv,
            params
        )


        return tv
    }


    private fun renderTurn(
        text: String,
        isTotti: Boolean
    ) {

        if (
            text.isBlank()
        ) {
            return
        }


        newLineView(
            isTotti
        ).text =
            text
    }


    private fun appendSystem(
        text: String
    ) {

        if (
            text.isBlank()
        ) {
            return
        }


        val tv =
            TextView(
                this
            ).apply {

                this.text =
                    text

                setTextColor(
                    0xFF3E7E55
                        .toInt()
                )

                setTextSize(
                    TypedValue
                        .COMPLEX_UNIT_SP,
                    12f
                )

                gravity =
                    Gravity.CENTER
            }


        val params =
            LinearLayout
                .LayoutParams(
                    LinearLayout
                        .LayoutParams
                        .MATCH_PARENT,

                    LinearLayout
                        .LayoutParams
                        .WRAP_CONTENT
                )
                .apply {

                    topMargin =
                        12
                }


        binding.conversation.addView(
            tv,
            params
        )
    }


    // =========================================================
    // Typewriter
    // =========================================================

    private fun startTicker() {

        if (
            ticking
        ) {
            return
        }

        ticking =
            true

        uiHandler.post(
            tickRunnable
        )
    }


    private val tickRunnable =
        object :
            Runnable {

            override fun run() {

                val tv =
                    streamingView
                        ?: run {

                            ticking =
                                false

                            return
                        }


                val count =
                    Typewriter.step(
                        revealedLen,
                        streamTarget.length
                    )


                if (
                    count > 0
                ) {

                    revealedLen =
                        minOf(
                            revealedLen +
                                count,
                            streamTarget.length
                        )


                    tv.text =
                        streamTarget.substring(
                            0,
                            revealedLen
                        )


                    binding.scrollView.post {

                        binding.scrollView
                            .fullScroll(
                                android.view.View
                                    .FOCUS_DOWN
                            )
                    }
                }


                if (
                    revealedLen <
                    streamTarget.length ||
                    !streamEnded
                ) {

                    uiHandler.postDelayed(
                        this,
                        Typewriter.TICK_MS
                    )

                } else {

                    finalizeStream()
                }
            }
        }


    private fun finalizeStream() {

        ticking =
            false


        val tv =
            streamingView


        val full =
            streamFinal


        if (
            tv != null &&
            !full.isNullOrBlank()
        ) {

            tv.text =
                full
        }


        resetStreaming()
    }
}