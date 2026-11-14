package io.github.moriri.hibivo

import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.ListView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import io.github.moriri.hibivo.core.VocabularyEntry

/** The user dictionary: spellings to prefer, and how speech recognition tends to mishear them. */
class VocabularyActivity : AppCompatActivity() {
    private lateinit var store: VocabularyStore
    private lateinit var adapter: ArrayAdapter<VocabularyEntry>
    private val entries = mutableListOf<VocabularyEntry>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_vocabulary)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        store = VocabularyStore(this)
        entries += store.load()

        adapter = object : ArrayAdapter<VocabularyEntry>(this, android.R.layout.simple_list_item_2, android.R.id.text1, entries) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val view = super.getView(position, convertView, parent)
                val entry = entries[position]
                view.findViewById<TextView>(android.R.id.text1).text = entry.preferred
                view.findViewById<TextView>(android.R.id.text2).text = entry.spoken.joinToString(SEPARATOR)
                return view
            }
        }
        findViewById<ListView>(R.id.list).apply {
            this.adapter = this@VocabularyActivity.adapter
            setOnItemClickListener { _, _, position, _ -> edit(position) }
        }
        findViewById<View>(R.id.add).setOnClickListener { edit(null) }
        refresh()
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    /** @param position The entry to edit, or null to add one. */
    private fun edit(position: Int?) {
        val entry = position?.let(entries::get)
        val view = layoutInflater.inflate(R.layout.dialog_vocabulary, null)
        val preferred = view.findViewById<EditText>(R.id.preferred).apply { setText(entry?.preferred.orEmpty()) }
        val spoken = view.findViewById<EditText>(R.id.spoken).apply { setText(entry?.spoken?.joinToString(SEPARATOR).orEmpty()) }
        val dialog = MaterialAlertDialogBuilder(this)
            .setTitle(if (entry == null) R.string.vocabulary_add else R.string.vocabulary_edit)
            .setView(view)
            .setPositiveButton(R.string.vocabulary_save) { _, _ ->
                val spelling = preferred.text.toString().trim()
                if (spelling.isEmpty()) return@setPositiveButton
                val updated = VocabularyEntry(
                    preferred = spelling,
                    spoken = spoken.text.toString().split(',', '、', '，').map { it.trim() }.filter { it.isNotEmpty() }.distinct(),
                    isEnabled = entry?.isEnabled ?: true,
                )
                if (position == null) entries += updated else entries[position] = updated
                save()
            }
            .setNegativeButton(android.R.string.cancel, null)
        if (position != null) {
            dialog.setNeutralButton(R.string.vocabulary_delete) { _, _ ->
                entries.removeAt(position)
                save()
            }
        }
        dialog.show()
    }

    private fun save() {
        store.save(entries)
        refresh()
    }

    private fun refresh() {
        adapter.notifyDataSetChanged()
        findViewById<View>(R.id.list).visibility = if (entries.isEmpty()) View.GONE else View.VISIBLE
        findViewById<View>(R.id.empty).visibility = if (entries.isEmpty()) View.VISIBLE else View.GONE
    }

    private companion object {
        const val SEPARATOR = ", "
    }
}
