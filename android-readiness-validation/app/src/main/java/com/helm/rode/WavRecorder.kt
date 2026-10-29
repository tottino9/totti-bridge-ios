package com.helm.rode

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * PCMデータ用WAVヘッダーを生成
 */
fun wavHeader(
    dataLen: Int,
    sampleRate: Int,
    channels: Int,
    bitsPerSample: Int
): ByteArray {

    val byteRate =
        sampleRate * channels * bitsPerSample / 8

    val blockAlign =
        channels * bitsPerSample / 8

    val bb =
        ByteBuffer.allocate(44)
            .order(ByteOrder.LITTLE_ENDIAN)

    bb.put("RIFF".toByteArray(Charsets.US_ASCII))
    bb.putInt(36 + dataLen)

    bb.put("WAVE".toByteArray(Charsets.US_ASCII))

    bb.put("fmt ".toByteArray(Charsets.US_ASCII))
    bb.putInt(16)

    // PCM
    bb.putShort(1)

    bb.putShort(channels.toShort())
    bb.putInt(sampleRate)
    bb.putInt(byteRate)
    bb.putShort(blockAlign.toShort())
    bb.putShort(bitsPerSample.toShort())

    bb.put("data".toByteArray(Charsets.US_ASCII))
    bb.putInt(dataLen)

    return bb.array()
}


/**
 * totti-ai 音声録音
 *
 * ・16kHz
 * ・mono
 * ・PCM16
 * ・発話後3秒無音で自動終了判定
 */
class WavRecorder {

    companion object {

        private const val TAG =
            "TottiRecorder"

        const val SAMPLE_RATE =
            16000

        /**
         * 約0.4秒以下の録音は無効
         */
        const val MIN_PCM_BYTES =
            12800

        /**
         * この値より小さければ無音候補
         *
         * 実機環境によって後から微調整可能
         */
        private const val SILENCE_THRESHOLD =
            0.025f

        /**
         * 最後の発話から3秒で
         * 発話終了と判断
         */
        private const val SILENCE_TIMEOUT_MS =
            3000L
    }


    @Volatile
    private var recording =
        false


    private var thread:
        Thread? = null


    private val pcm =
        ByteArrayOutputStream()


    /**
     * HUD波形等で使うリアルタイム音量
     * 0.0 ～ 1.0
     */
    @Volatile
    var amplitude: Float =
        0f
        private set


    /**
     * その録音で一度でも
     * 人の声らしい音を検知したか
     */
    @Volatile
    var speechDetected:
        Boolean = false
        private set


    /**
     * 3秒無音によって
     * 自動停止条件になったか
     */
    @Volatile
    var silenceTimedOut:
        Boolean = false
        private set


    /**
     * 最後に音声を検出した時間
     */
    private var lastSpeechAt =
        0L


    /**
     * 外部から録音状態を確認
     */
    fun isRecording():
        Boolean {

        return recording
    }


    @SuppressLint("MissingPermission")
    fun start() {

        if (recording) {
            return
        }

        pcm.reset()

        amplitude = 0f

        speechDetected =
            false

        silenceTimedOut =
            false

        lastSpeechAt =
            0L


        val minBuf =
            AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(
                SAMPLE_RATE
            )


        val record =
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf
            )


        if (
            record.state !=
            AudioRecord.STATE_INITIALIZED
        ) {

            Log.e(
                TAG,
                "AudioRecord init failed"
            )

            record.release()

            return
        }


        recording =
            true


        record.startRecording()


        thread =
            Thread {

                val buf =
                    ByteArray(minBuf)


                while (recording) {

                    val n =
                        record.read(
                            buf,
                            0,
                            buf.size
                        )


                    if (n <= 0) {
                        continue
                    }


                    /*
                     * 音量ピーク計算
                     * PCM16 Little Endian
                     */
                    var peak =
                        0

                    var i =
                        0


                    while (
                        i + 1 < n
                    ) {

                        val sample =
                            (buf[i].toInt() and 0xff) or
                            (buf[i + 1].toInt() shl 8)


                        val absSample =
                            if (sample < 0) {
                                -sample
                            } else {
                                sample
                            }


                        if (
                            absSample > peak
                        ) {
                            peak =
                                absSample
                        }


                        i += 2
                    }


                    val target =
                        (
                            peak /
                            32768f
                        ).coerceIn(
                            0f,
                            1f
                        )


                    amplitude =
                        if (
                            target >
                            amplitude
                        ) {

                            target

                        } else {

                            amplitude *
                                0.6f +
                                target *
                                0.4f
                        }


                    val now =
                        System.currentTimeMillis()


                    /*
                     * 音声検出
                     */
                    if (
                        target >=
                        SILENCE_THRESHOLD
                    ) {

                        /*
                         * 最初の発話を検出
                         */
                        if (
                            !speechDetected
                        ) {

                            speechDetected =
                                true

                            Log.d(
                                TAG,
                                "Speech started"
                            )
                        }


                        /*
                         * 現在のバッファを保存
                         */
                        pcm.write(
                            buf,
                            0,
                            n
                        )


                        lastSpeechAt =
                            now

                    } else if (
                        speechDetected
                    ) {

                        /*
                         * 発話開始後の無音部分も
                         * WAVには含める
                         */
                        pcm.write(
                            buf,
                            0,
                            n
                        )


                        /*
                         * 最後の声から3秒
                         */
                        if (
                            lastSpeechAt > 0 &&
                            now -
                            lastSpeechAt >=
                            SILENCE_TIMEOUT_MS
                        ) {

                            Log.d(
                                TAG,
                                "3 sec silence detected"
                            )


                            silenceTimedOut =
                                true


                            /*
                             * 読み込みループだけ終了
                             *
                             * WAV生成は
                             * stop() で行う
                             */
                            recording =
                                false
                        }
                    }

                    /*
                     * speechDetected == false の間は
                     * 無音PCMを保存しない。
                     *
                     * これによりtotti-aiが
                     * 長時間待機しても
                     * メモリを食い続けない。
                     */
                }


                amplitude =
                    0f


                try {

                    record.stop()

                } catch (
                    _: Throwable
                ) {
                }


                record.release()


                Log.d(
                    TAG,
                    "AudioRecord released"
                )

            }.also {

                it.start()
            }
    }


    /**
     * 録音停止
     *
     * 手動停止でも、
     * 3秒無音による自動停止後でも、
     * WAVを返せるようにしてある。
     */
    fun stop():
        ByteArray {

        recording =
            false


        /*
         * 録音スレッド自身から
         * joinしない
         */
        val currentThread =
            Thread.currentThread()

        val recorderThread =
            thread


        if (
            recorderThread != null &&
            recorderThread !=
            currentThread
        ) {

            try {

                recorderThread.join(
                    2000
                )

            } catch (
                _: InterruptedException
            ) {

                Thread.currentThread()
                    .interrupt()
            }
        }


        thread =
            null


        amplitude =
            0f


        val data =
            pcm.toByteArray()


        /*
         * 人の声を一度も検出していない
         */
        if (
            !speechDetected
        ) {

            Log.d(
                TAG,
                "No speech detected"
            )

            return ByteArray(0)
        }


        /*
         * 録音時間が短すぎる
         */
        if (
            data.size <
            MIN_PCM_BYTES
        ) {

            Log.d(
                TAG,
                "Audio too short"
            )

            return ByteArray(0)
        }


        val header =
            wavHeader(
                data.size,
                SAMPLE_RATE,
                1,
                16
            )


        return header +
            data
    }
}