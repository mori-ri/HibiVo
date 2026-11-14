package io.github.moriri.hibivo

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings as SystemSettings
import android.text.InputFilter
import android.text.InputType
import android.view.inputmethod.InputMethodManager
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceFragmentCompat
import io.github.moriri.hibivo.core.CleanupMode
import io.github.moriri.hibivo.core.CleanupProviderKind

/** The app's only screen besides the dictionary: setup steps, a field to try the keyboard in, and settings. */
class SettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)
        if (savedInstanceState == null) {
            val fragment = SettingsFragment().apply {
                arguments = Bundle().apply {
                    putBoolean(EXTRA_REQUEST_MICROPHONE, intent.getBooleanExtra(EXTRA_REQUEST_MICROPHONE, false))
                }
            }
            supportFragmentManager.beginTransaction().replace(R.id.settings, fragment).commit()
        }
    }

    companion object {
        /** Set by the keyboard when the microphone permission is missing, to ask for it right away. */
        const val EXTRA_REQUEST_MICROPHONE = "request_microphone"
    }
}

class SettingsFragment : PreferenceFragmentCompat() {
    private val microphonePermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        // Denied twice, Android stops showing the dialog; the app's system page is then the only way.
        if (!granted && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
            startActivity(
                Intent(SystemSettings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", requireContext().packageName, null)),
            )
        }
        updateSetup()
    }

    override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
        val context = requireContext()
        preferenceManager.preferenceDataStore = AppPreferenceDataStore(Settings(context), SecretStore(context))
        setPreferencesFromResource(R.xml.preferences, rootKey)

        click("setup_enable") { startActivity(Intent(SystemSettings.ACTION_INPUT_METHOD_SETTINGS)) }
        click("setup_select") { context.getSystemService(InputMethodManager::class.java)?.showInputMethodPicker() }
        click("setup_microphone") { microphonePermission.launch(Manifest.permission.RECORD_AUDIO) }
        click("vocabulary") { startActivity(Intent(context, VocabularyActivity::class.java)) }

        for (account in listOf(Settings.SECRET_SONIOX) + CleanupProviderKind.entries.map { it.id }) {
            secret(Settings.secretKey(account))
        }
        for (kind in CleanupProviderKind.entries) {
            text(Settings.cleanupModelKey(kind)) { value ->
                when {
                    !value.isNullOrBlank() -> value
                    kind.defaultModel.isEmpty() -> getString(R.string.cleanup_model_missing)
                    else -> getString(R.string.cleanup_model_default, kind.defaultModel)
                }
            }
        }
        text(Settings.OPENAI_BASE_URL, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI) { value ->
            value?.takeIf { it.isNotBlank() } ?: getString(R.string.cleanup_model_default, CleanupProviderKind.DEFAULT_OPENAI_BASE_URL)
        }
        text(
            Settings.CUSTOM_INSTRUCTIONS, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE,
            CleanupMode.CUSTOM_INSTRUCTIONS_LIMIT,
        ) { value -> value?.takeIf { it.isNotBlank() } ?: getString(R.string.custom_instructions_empty) }

        findPreference<ListPreference>(Settings.STT_PROVIDER)?.setOnPreferenceChangeListener { _, value ->
            showProviderFields(stt = value as String)
            true
        }
        findPreference<ListPreference>(Settings.CLEANUP_PROVIDER)?.setOnPreferenceChangeListener { _, value ->
            showProviderFields(cleanup = value as String)
            true
        }
        showProviderFields()

        if (savedInstanceState == null && arguments?.getBoolean(SettingsActivity.EXTRA_REQUEST_MICROPHONE) == true) {
            microphonePermission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    override fun onResume() {
        super.onResume()
        updateSetup()
    }

    /** Shows where each setup step stands; the user comes back here from the system screens. */
    private fun updateSetup() {
        val context = context ?: return
        val manager = context.getSystemService(InputMethodManager::class.java)
        val enabled = manager?.enabledInputMethodList.orEmpty().any { it.packageName == context.packageName }
        val current = SystemSettings.Secure.getString(context.contentResolver, SystemSettings.Secure.DEFAULT_INPUT_METHOD)
        val selected = current?.startsWith(context.packageName + "/") == true
        val microphone = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        summary("setup_enable", if (enabled) R.string.setup_enable_done else R.string.setup_enable_todo)
        summary("setup_select", if (selected) R.string.setup_select_done else R.string.setup_select_todo)
        summary("setup_microphone", if (microphone) R.string.setup_microphone_done else R.string.setup_microphone_todo)
    }

    /** Only the selected providers' fields are shown, so the screen never asks for keys that aren't used. */
    private fun showProviderFields(
        stt: String = findPreference<ListPreference>(Settings.STT_PROVIDER)?.value ?: Settings.STT_ANDROID,
        cleanup: String = findPreference<ListPreference>(Settings.CLEANUP_PROVIDER)?.value ?: CleanupProviderKind.ANTHROPIC.id,
    ) {
        findPreference<Preference>(Settings.secretKey(Settings.SECRET_SONIOX))?.isVisible = stt == Settings.STT_SONIOX
        for (kind in CleanupProviderKind.entries) {
            val visible = kind.id == cleanup
            findPreference<Preference>(Settings.secretKey(kind.id))?.isVisible = visible
            findPreference<Preference>(Settings.cleanupModelKey(kind))?.isVisible = visible
        }
        findPreference<Preference>(Settings.OPENAI_BASE_URL)?.isVisible = cleanup == CleanupProviderKind.OPENAI_COMPATIBLE.id
    }

    private fun click(key: String, action: () -> Unit) {
        findPreference<Preference>(key)?.setOnPreferenceClickListener {
            action()
            true
        }
    }

    private fun summary(key: String, text: Int) {
        findPreference<Preference>(key)?.setSummary(text)
    }

    /** An API key field: masked while typing, and the summary only says whether one is saved. */
    private fun secret(key: String) {
        val preference = findPreference<EditTextPreference>(key) ?: return
        preference.setOnBindEditTextListener { field ->
            field.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            field.setSingleLine()
            field.setSelection(field.text.length)
        }
        preference.summaryProvider = Preference.SummaryProvider<EditTextPreference> {
            getString(if (it.text.isNullOrBlank()) R.string.secret_missing else R.string.secret_saved)
        }
    }

    private fun text(
        key: String,
        inputType: Int = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS,
        limit: Int? = null,
        summary: (String?) -> String,
    ) {
        val preference = findPreference<EditTextPreference>(key) ?: return
        preference.setOnBindEditTextListener { field ->
            field.inputType = inputType
            if (limit != null) field.filters = arrayOf(InputFilter.LengthFilter(limit))
            field.setSelection(field.text.length)
        }
        preference.summaryProvider = Preference.SummaryProvider<EditTextPreference> { summary(it.text) }
    }
}
