package io.github.moriri.hibivo

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import io.github.moriri.hibivo.DictationController.State
import io.github.moriri.hibivo.core.CleanupMode
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowSystemClock
import java.io.File
import java.time.Duration
import kotlin.test.assertEquals

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "ja-w360dp-h740dp-xxhdpi")
class KeyboardViewTest {
    /** Stands in for the input method service, starting and stopping like DictationController does. */
    private class FakeActions : KeyboardView.Actions {
        val calls = mutableListOf<String>()
        lateinit var view: KeyboardView
        var state = State.IDLE
            set(value) {
                field = value
                view.setState(value)
            }

        override fun onMicrophonePressed() {
            calls += "pressed"
            state = if (state == State.IDLE) State.RECORDING else State.TRANSCRIBING
        }

        override fun onMicrophoneHoldReleased() {
            calls += "holdReleased"
            state = State.TRANSCRIBING
        }

        override fun onCancel() {
            calls += "cancel"
            state = State.IDLE
        }

        override fun onCycleMode() { calls += "mode" }
        override fun onUndo() { calls += "undo" }
        override fun onOpenSettings() { calls += "settings" }
        override fun onSwitchKeyboard() { calls += "switch" }
        override fun onPickKeyboard() { calls += "pick" }
        override fun onText(text: String) { calls += "text:$text" }
        override fun onKey(keyCode: Int) { calls += "key:$keyCode" }
        override fun onEnter() { calls += "enter" }
    }

    private val context = ApplicationProvider.getApplicationContext<Application>()
    private val actions = FakeActions()
    private val keyboard = KeyboardView(context, actions).also {
        actions.view = it
        it.setMode(CleanupMode.NATURAL)
        layout(it)
    }

    private fun layout(view: View) {
        val width = (360 * context.resources.displayMetrics.density).toInt()
        view.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        view.layout(0, 0, view.measuredWidth, view.measuredHeight)
    }

    private fun touch(id: Int, action: Int) {
        val view = keyboard.findViewById<View>(id)
        val now = SystemClock.uptimeMillis()
        val event = MotionEvent.obtain(now, now, action, view.width / 2f, view.height / 2f, 0)
        view.dispatchTouchEvent(event)
        event.recycle()
    }

    private val status: String get() = keyboard.findViewById<TextView>(R.id.status).text.toString()

    /** Saved for a human to look at; the layout can't be seen any other way without a device. */
    private fun snapshot(name: String) {
        layout(keyboard)
        val bitmap = Bitmap.createBitmap(keyboard.width, keyboard.height, Bitmap.Config.ARGB_8888)
        keyboard.draw(Canvas(bitmap))
        val directory = File("build/keyboard-snapshots").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun tapStartsAndSecondTapStops() {
        assertEquals("タップして話す（長押し中だけの録音もできます）", status)
        snapshot("idle")

        touch(R.id.microphone, MotionEvent.ACTION_DOWN)
        touch(R.id.microphone, MotionEvent.ACTION_UP)
        assertEquals(listOf("pressed"), actions.calls)
        assertEquals("聞いています…", status)
        assertEquals(View.VISIBLE, keyboard.findViewById<View>(R.id.cancel).visibility)

        keyboard.showPartial("明日の会議は15時からで")
        keyboard.setLevel(0.6f)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofMillis(200))
        assertEquals("明日の会議は15時からで", status)
        snapshot("recording")

        touch(R.id.microphone, MotionEvent.ACTION_DOWN)
        touch(R.id.microphone, MotionEvent.ACTION_UP)
        assertEquals(listOf("pressed", "pressed"), actions.calls)
        assertEquals("文字起こししています…", status)
        assertEquals(View.INVISIBLE, keyboard.findViewById<View>(R.id.microphone).visibility)
        snapshot("processing")
    }

    @Test fun holdingStopsOnRelease() {
        touch(R.id.microphone, MotionEvent.ACTION_DOWN)
        ShadowSystemClock.advanceBy(Duration.ofMillis(600))
        touch(R.id.microphone, MotionEvent.ACTION_UP)
        assertEquals(listOf("pressed", "holdReleased"), actions.calls)
    }

    @Test fun quickReleaseKeepsRecording() {
        touch(R.id.microphone, MotionEvent.ACTION_DOWN)
        ShadowSystemClock.advanceBy(Duration.ofMillis(150))
        touch(R.id.microphone, MotionEvent.ACTION_UP)
        assertEquals(listOf("pressed"), actions.calls)
        assertEquals(State.RECORDING, actions.state)
    }

    @Test fun noticeStaysUntilNextRecordingAndPartialsShowTheirEnd() {
        keyboard.showNotice("聞き取れませんでした。もう一度お試しください。")
        assertEquals("聞き取れませんでした。もう一度お試しください。", status)
        snapshot("notice")
        actions.state = State.RECORDING
        keyboard.showPartial("あ".repeat(200))
        assertEquals("…" + "あ".repeat(90), status)
        actions.state = State.IDLE
        assertEquals("タップして話す（長押し中だけの録音もできます）", status)
    }

    @Test fun editingKeys() {
        keyboard.findViewById<View>(R.id.switch_keyboard).performClick()
        keyboard.findViewById<View>(R.id.switch_keyboard).performLongClick()
        keyboard.findViewById<View>(R.id.comma).performClick()
        keyboard.findViewById<View>(R.id.period).performClick()
        keyboard.findViewById<View>(R.id.space).performClick()
        keyboard.findViewById<View>(R.id.enter).performClick()
        keyboard.findViewById<View>(R.id.undo).performClick()
        keyboard.findViewById<View>(R.id.mode).performClick()
        assertEquals(listOf("switch", "pick", "text:、", "text:。", "text: ", "enter", "undo", "mode"), actions.calls)
    }

    @Test fun backspaceRepeatsWhileHeld() {
        touch(R.id.backspace, MotionEvent.ACTION_DOWN)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofMillis(520))
        touch(R.id.backspace, MotionEvent.ACTION_UP)
        val count = actions.calls.count { it == "key:${KeyEvent.KEYCODE_DEL}" }
        // One on press, then repeats every 50 ms after the 400 ms delay.
        assertEquals(true, count in 3..4, "sent $count")
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofMillis(300))
        assertEquals(count, actions.calls.size)
    }

    @Test @Config(qualifiers = "+night") fun darkSnapshot() = snapshot("idle-dark")

    @Test @Config(qualifiers = "en-w360dp-h740dp-xxhdpi") fun englishSnapshot() {
        assertEquals("Tap to speak, or hold while you speak", status)
        snapshot("idle-en")
    }
}
