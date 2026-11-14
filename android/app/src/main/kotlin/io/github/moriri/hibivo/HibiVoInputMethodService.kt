package io.github.moriri.hibivo

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import io.github.moriri.hibivo.core.CleanupMode
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * The HibiVo keyboard: a microphone instead of letter keys. Press, speak, press again, and the (optionally
 * cleaned up) text is entered at the cursor. A key switches to the user's regular keyboard for corrections.
 */
class HibiVoInputMethodService : InputMethodService(), KeyboardView.Actions, DictationController.Listener {
    private val scope = MainScope()
    private lateinit var settings: Settings
    private lateinit var controller: DictationController
    private var keyboard: KeyboardView? = null

    /** What the last dictation entered, so it can be taken back with one key. */
    private var lastEntered: String? = null

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        val client = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            // CleanupCoordinator's own deadline (30 s at most) is what bounds a request.
            .readTimeout(60, TimeUnit.SECONDS)
            .build()
        controller = DictationController(this, scope, settings, SecretStore(this), VocabularyStore(this), client, this)
    }

    override fun onCreateInputView(): View = KeyboardView(this, this).also { keyboard = it }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        keyboard?.run {
            setMode(settings.mode)
            setHaptics(settings.haptics)
            setState(controller.state)
            if (controller.state == DictationController.State.IDLE) {
                showNotice(if (isPasswordField(info)) getString(R.string.notice_password_field) else null)
            }
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        // The keyboard is gone, so nobody can see that the microphone is on. Never record unseen.
        if (controller.state == DictationController.State.RECORDING) controller.cancel()
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        controller.cancel()
        scope.cancel()
        super.onDestroy()
    }

    /** The keyboard is short, so it never needs the fullscreen (extract) mode, even in landscape. */
    override fun onEvaluateFullscreenMode(): Boolean = false

    // MARK: KeyboardView.Actions

    override fun onMicrophonePressed() {
        when (controller.state) {
            DictationController.State.IDLE -> {
                if (isPasswordField(currentInputEditorInfo)) {
                    keyboard?.showNotice(getString(R.string.notice_password_field))
                    return
                }
                keyboard?.showNotice(null)
                controller.start(targetAppName())
            }
            DictationController.State.RECORDING -> controller.stop()
            else -> Unit
        }
    }

    override fun onMicrophoneHoldReleased() {
        if (controller.state == DictationController.State.RECORDING) controller.stop()
    }

    override fun onCancel() = controller.cancel()

    override fun onCycleMode() {
        val modes = CleanupMode.entries
        val next = modes[(modes.indexOf(settings.mode) + 1) % modes.size]
        settings.mode = next
        keyboard?.setMode(next)
    }

    override fun onUndo() {
        val text = lastEntered ?: return
        val connection = currentInputConnection ?: return
        // Only take back exactly what was entered; if the user has typed since, leave their text alone.
        if (connection.getTextBeforeCursor(text.length, 0)?.toString() == text) {
            connection.deleteSurroundingText(text.length, 0)
            lastEntered = null
            keyboard?.showNotice(null)
        } else {
            keyboard?.showNotice(getString(R.string.notice_cannot_undo))
        }
    }

    override fun onOpenSettings() = openSettings(requestMicrophone = false)

    override fun onSwitchKeyboard() {
        // Back to the keyboard used before this one; the picker when there is none.
        if (!switchToPreviousInputMethod()) onPickKeyboard()
    }

    override fun onPickKeyboard() {
        getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
    }

    override fun onText(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    override fun onKey(keyCode: Int) = sendDownUpKeyEvents(keyCode)

    override fun onEnter() {
        val info = currentInputEditorInfo
        val action = (info?.imeOptions ?: 0) and EditorInfo.IME_MASK_ACTION
        val hasAction = info != null && (info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION) == 0 &&
            action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED
        // Search, Send, Go… when the field asks for it; otherwise a line break.
        if (hasAction) currentInputConnection?.performEditorAction(action) else sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
    }

    // MARK: DictationController.Listener

    override fun onStateChanged(state: DictationController.State) {
        keyboard?.setState(state)
    }

    override fun onPartial(text: String) {
        keyboard?.showPartial(text)
    }

    override fun onLevel(level: Float) {
        keyboard?.setLevel(level)
    }

    override fun onNotice(message: String) {
        keyboard?.showNotice(message)
    }

    override fun onMicrophonePermissionNeeded() = openSettings(requestMicrophone = true)

    override fun onResult(text: String, language: String): Boolean {
        val connection = currentInputConnection
        if (connection == null) {
            // The field went away while we were working. Don't lose the utterance: leave it on the clipboard.
            getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("HibiVo", text))
            return false
        }
        // English needs a space after the previous word; Japanese doesn't.
        val before = connection.getTextBeforeCursor(1, 0)
        val needsSpace = language == "en" && !before.isNullOrEmpty() && !before.last().isWhitespace()
        val entered = if (needsSpace) " $text" else text
        connection.commitText(entered, 1)
        lastEntered = entered
        return true
    }

    // MARK: Private

    private fun openSettings(requestMicrophone: Boolean) {
        startActivity(
            Intent(this, SettingsActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(SettingsActivity.EXTRA_REQUEST_MICROPHONE, requestMicrophone),
        )
    }

    /** The name of the app being typed into, which tells cleanup what the text is for. Null when unknown. */
    private fun targetAppName(): String? {
        val packageName = currentInputEditorInfo?.packageName ?: return null
        if (packageName == this.packageName) return null
        return try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0)).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            // Android 11 and later hide most other apps; cleanup then works without the hint.
            null
        }
    }

    /** Passwords are never dictated: they would be sent to speech recognition and to the LLM. */
    private fun isPasswordField(info: EditorInfo?): Boolean {
        val type = info?.inputType ?: return false
        val variation = type and InputType.TYPE_MASK_VARIATION
        return when (type and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }
}
