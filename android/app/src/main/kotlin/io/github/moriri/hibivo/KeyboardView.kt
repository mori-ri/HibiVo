package io.github.moriri.hibivo

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ProgressBar
import android.widget.TextView
import io.github.moriri.hibivo.core.CleanupMode

/** The keyboard's view: the microphone, the live transcript, and a row of editing keys. */
@SuppressLint("ViewConstructor")
class KeyboardView(context: Context, private val actions: Actions) : FrameLayout(context) {
    interface Actions {
        /** The microphone went down: start, or stop when already recording. */
        fun onMicrophonePressed()

        /** The microphone was held down from the start of recording and has now been released. */
        fun onMicrophoneHoldReleased()
        fun onCancel()
        fun onCycleMode()
        fun onUndo()
        fun onOpenSettings()
        fun onSwitchKeyboard()
        fun onPickKeyboard()
        fun onText(text: String)
        fun onKey(keyCode: Int)
        fun onEnter()
    }

    private val mode: TextView
    private val status: TextView
    private val microphone: ImageButton
    private val halo: View
    private val progress: ProgressBar
    private val cancel: ImageButton

    private var state = DictationController.State.IDLE
    private var haptics = true
    private var notice: String? = null
    private val handler = Handler(Looper.getMainLooper())

    /** Set when a press started the recording; cleared once we know whether it was a tap or a hold. */
    private var pressStartedRecordingAt: Long? = null

    init {
        LayoutInflater.from(context).inflate(R.layout.keyboard, this, true)
        mode = findViewById(R.id.mode)
        status = findViewById(R.id.status)
        microphone = findViewById(R.id.microphone)
        halo = findViewById(R.id.halo)
        progress = findViewById(R.id.progress)
        cancel = findViewById(R.id.cancel)

        mode.setOnClickListener { tap(); actions.onCycleMode() }
        cancel.setOnClickListener { tap(); actions.onCancel() }
        findViewById<View>(R.id.undo).setOnClickListener { tap(); actions.onUndo() }
        findViewById<View>(R.id.settings).setOnClickListener { actions.onOpenSettings() }
        findViewById<View>(R.id.switch_keyboard).apply {
            setOnClickListener { tap(); actions.onSwitchKeyboard() }
            setOnLongClickListener { actions.onPickKeyboard(); true }
        }
        findViewById<View>(R.id.comma).setOnClickListener { tap(); actions.onText(context.getString(R.string.key_comma)) }
        findViewById<View>(R.id.period).setOnClickListener { tap(); actions.onText(context.getString(R.string.key_period)) }
        findViewById<View>(R.id.space).setOnClickListener { tap(); actions.onText(" ") }
        findViewById<View>(R.id.enter).setOnClickListener { tap(); actions.onEnter() }
        repeating(R.id.backspace, KeyEvent.KEYCODE_DEL)
        repeating(R.id.cursor_left, KeyEvent.KEYCODE_DPAD_LEFT)
        repeating(R.id.cursor_right, KeyEvent.KEYCODE_DPAD_RIGHT)
        setUpMicrophone()
        render()
    }

    fun setMode(value: CleanupMode) {
        mode.text = context.getString(
            when (value) {
                CleanupMode.RAW -> R.string.mode_raw
                CleanupMode.NATURAL -> R.string.mode_natural
                CleanupMode.BUSINESS -> R.string.mode_business
                CleanupMode.PROMPT -> R.string.mode_prompt
                CleanupMode.CUSTOM -> R.string.mode_custom
            },
        )
    }

    fun setHaptics(enabled: Boolean) {
        haptics = enabled
    }

    fun setState(value: DictationController.State) {
        if (state == value) return
        state = value
        if (value != DictationController.State.RECORDING) pressStartedRecordingAt = null
        if (value == DictationController.State.RECORDING) notice = null
        render()
    }

    /** The running transcript while recording. */
    fun showPartial(text: String) {
        if (state != DictationController.State.RECORDING || text.isBlank()) return
        // Only the end fits; that is the part still changing.
        status.text = if (text.length > PARTIAL_TAIL) "…" + text.takeLast(PARTIAL_TAIL) else text
    }

    /** A message that stays until the next dictation. Null clears it. */
    fun showNotice(message: String?) {
        notice = message
        if (state == DictationController.State.IDLE) render()
    }

    /** @param level 0…1 */
    fun setLevel(level: Float) {
        if (state != DictationController.State.RECORDING) return
        val scale = 1f + level * HALO_GROWTH
        halo.animate().scaleX(scale).scaleY(scale).setDuration(90).start()
    }

    private fun render() {
        val recording = state == DictationController.State.RECORDING
        val busy = state == DictationController.State.TRANSCRIBING || state == DictationController.State.CLEANING_UP
        microphone.visibility = if (busy) INVISIBLE else VISIBLE
        microphone.isActivated = recording
        microphone.setImageResource(if (recording) R.drawable.ic_stop else R.drawable.ic_mic)
        microphone.contentDescription =
            context.getString(if (recording) R.string.action_stop else R.string.action_start)
        progress.visibility = if (busy) VISIBLE else GONE
        cancel.visibility = if (recording || busy) VISIBLE else INVISIBLE
        halo.visibility = if (recording) VISIBLE else INVISIBLE
        if (!recording) {
            halo.animate().cancel()
            halo.scaleX = 1f
            halo.scaleY = 1f
        }
        status.text = when (state) {
            DictationController.State.IDLE -> notice ?: context.getString(R.string.status_idle)
            DictationController.State.RECORDING -> context.getString(R.string.status_listening)
            DictationController.State.TRANSCRIBING -> context.getString(R.string.status_transcribing)
            DictationController.State.CLEANING_UP -> context.getString(R.string.status_cleaning_up)
        }
    }

    /**
     * Tap to start and tap again to stop, or hold while speaking and let go to stop: the same two ways as the
     * macOS hotkey. Acting on the press rather than the click keeps the first syllable from being cut off.
     */
    @SuppressLint("ClickableViewAccessibility")
    private fun setUpMicrophone() {
        microphone.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    view.isPressed = true
                    tap()
                    val wasIdle = state == DictationController.State.IDLE
                    actions.onMicrophonePressed()
                    pressStartedRecordingAt =
                        if (wasIdle && state == DictationController.State.RECORDING) SystemClock.elapsedRealtime() else null
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    view.isPressed = false
                    val startedAt = pressStartedRecordingAt
                    pressStartedRecordingAt = null
                    if (startedAt != null && SystemClock.elapsedRealtime() - startedAt >= HOLD_THRESHOLD_MS) {
                        actions.onMicrophoneHoldReleased()
                    }
                }
            }
            true
        }
        // Switch access and TalkBack activate the view without touch events.
        microphone.setOnClickListener { actions.onMicrophonePressed() }
    }

    /** Sends `keyCode` on press and keeps sending it while the key is held. */
    @SuppressLint("ClickableViewAccessibility")
    private fun repeating(id: Int, keyCode: Int) {
        val view = findViewById<View>(id)
        val repeat = object : Runnable {
            override fun run() {
                actions.onKey(keyCode)
                handler.postDelayed(this, REPEAT_INTERVAL_MS)
            }
        }
        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    view.isPressed = true
                    tap()
                    actions.onKey(keyCode)
                    handler.postDelayed(repeat, REPEAT_DELAY_MS)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    view.isPressed = false
                    handler.removeCallbacks(repeat)
                }
            }
            true
        }
        view.setOnClickListener { actions.onKey(keyCode) }
    }

    private fun tap() {
        if (haptics) performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
    }

    override fun onDetachedFromWindow() {
        // A key held while the keyboard goes away must not keep repeating.
        handler.removeCallbacksAndMessages(null)
        super.onDetachedFromWindow()
    }

    private companion object {
        /** Holding the microphone at least this long makes releasing it stop the recording. As on macOS. */
        const val HOLD_THRESHOLD_MS = 400L
        const val REPEAT_DELAY_MS = 400L
        const val REPEAT_INTERVAL_MS = 50L
        const val PARTIAL_TAIL = 90
        const val HALO_GROWTH = 0.45f
    }
}
