package com.cashu.mickey

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class AssistantSpeechBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "cashew/assistant_speech")
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var pending: MethodChannel.Result? = null
    private var language: String = "en"
    private val timeout = Runnable { finish(null, "timeout") }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(available())
                "listen" -> listen(call.argument<String>("language"), result)
                "cancel" -> {
                    finish(null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun available(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)

    private fun listen(requestedLanguage: String?, result: MethodChannel.Result) {
        if (!available()) {
            result.error("unavailable", null, null)
            return
        }
        if (pending != null) {
            result.error("busy", null, null)
            return
        }
        language = if (requestedLanguage == "ar") "ar-EG" else "en-US"
        pending = result
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MIC)
        } else {
            start()
        }
    }

    fun onPermissions(requestCode: Int, grants: IntArray) {
        if (requestCode != REQUEST_MIC || pending == null) return
        if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) start()
        else finish(null, "permission")
    }

    private fun start() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || pending == null) {
            finish(null, "unavailable")
            return
        }
        try {
            val session = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            recognizer = session
            session.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}

                override fun onError(error: Int) {
                    if (recognizer !== session) return
                    finish(null, when (error) {
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "language"
                        SpeechRecognizer.ERROR_NO_MATCH,
                        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "no_speech"
                        else -> "recognition"
                    })
                }

                override fun onResults(results: Bundle?) {
                    if (recognizer !== session) return
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                    if (text.isNullOrBlank()) finish(null, "no_speech")
                    else finish(text)
                }
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            handler.postDelayed(timeout, 15_000)
            session.startListening(intent)
        } catch (_: RuntimeException) {
            finish(null, "recognition")
        }
    }

    fun stopActiveRecognition() {
        if (recognizer != null) finish(null)
    }

    fun dispose() {
        finish(null)
        channel.setMethodCallHandler(null)
    }

    private fun finish(text: String?, error: String? = null) {
        handler.removeCallbacks(timeout)
        val result = pending
        pending = null
        val session = recognizer
        recognizer = null
        session?.destroy()
        if (error == null) result?.success(text)
        else result?.error(error, null, null)
    }

    private companion object {
        const val REQUEST_MIC = 8192
    }
}
