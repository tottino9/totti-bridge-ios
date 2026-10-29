package com.helm.rode

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

class TottiAccessibilityService : AccessibilityService() {

    companion object {

        private const val TAG =
            "TottiAccessibility"

        /*
         * Rokid実機ログで確認した
         * Dashboard系入力のAndroid keyCode。
         *
         * Linux側では KEY_DASHBOARD と表示されるが、
         * Android SDKには KEYCODE_DASHBOARD 定数が無いため
         * 実機値83を使用する。
         */
        private const val ROKID_DASHBOARD_KEYCODE =
            83

        /*
         * 3連タップ判定時間
         */
        private const val TRIPLE_TAP_WINDOW_MS =
            1800L

        /*
         * 連続誤起動防止
         */
        private const val LAUNCH_COOLDOWN_MS =
            2500L
    }

    private val tapTimes =
        ArrayDeque<Long>()

    private var lastLaunchAt =
        0L

    override fun onServiceConnected() {

        super.onServiceConnected()

        Log.d(
            TAG,
            "Accessibility service connected"
        )
    }

    override fun onAccessibilityEvent(
        event: AccessibilityEvent?
    ) {
        /*
         * 今回は画面内容を取得しない。
         *
         * キーイベント監視専用。
         */
    }

    override fun onInterrupt() {
        /*
         * 特別な処理なし
         */
    }

    override fun onKeyEvent(
        event: KeyEvent
    ): Boolean {

        /*
         * DOWNだけ数える。
         *
         * UPまで数えると
         * 1タップが2回扱いになる。
         */
        if (
            event.action !=
            KeyEvent.ACTION_DOWN
        ) {
            return false
        }

        Log.d(
            TAG,
            "keyCode=${event.keyCode}"
        )

        /*
         * Rokid実機で確認した
         * dashboard系キーだけ監視。
         */
        if (
            event.keyCode !=
            ROKID_DASHBOARD_KEYCODE
        ) {
            return false
        }

        val now =
            SystemClock.elapsedRealtime()

        /*
         * 判定時間より古いタップを除外
         */
        while (
            tapTimes.isNotEmpty() &&
            now - tapTimes.first() >
            TRIPLE_TAP_WINDOW_MS
        ) {

            tapTimes.removeFirst()
        }

        tapTimes.addLast(
            now
        )

        Log.d(
            TAG,
            "dashboard tap count=${tapTimes.size}"
        )

        /*
         * 3回到達
         */
        if (
            tapTimes.size >= 3
        ) {

            tapTimes.clear()

            if (
                now - lastLaunchAt >=
                LAUNCH_COOLDOWN_MS
            ) {

                lastLaunchAt =
                    now

                launchTotti()
            }
        }

        /*
         * Rokid本来のキー処理を奪わない。
         */
        return false
    }

    private fun launchTotti() {

        Log.d(
            TAG,
            "triple tap -> launch totti-ai"
        )

        try {

            val intent =
                Intent(
                    this,
                    MainActivity::class.java
                ).apply {

                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK
                    )

                    addFlags(
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                    )

                    addFlags(
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )

                    putExtra(
                        "AUTO_START_SESSION",
                        true
                    )
                }

            startActivity(
                intent
            )

        } catch (
            t: Throwable
        ) {

            Log.e(
                TAG,
                "launch failed",
                t
            )
        }
    }
}