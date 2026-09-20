package com.worldbrief.app

import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.worldbrief.app.databinding.ActivitySetupBinding
import kotlinx.coroutines.launch

/**
 * Points the app at the copy of World Brief running on the user's own computer — by searching
 * the network for it, or by typing its address.
 */
class SetupActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySetupBinding
    private lateinit var prefs: Prefs
    private var found: List<Discovery.Found> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySetupBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        prefs = Prefs(this)
        binding.address.setText(prefs.serverUrl)
        binding.background.isChecked = prefs.backgroundRefresh
        binding.notify.isChecked = prefs.notify
        binding.interval.setText(prefs.refreshMinutes.toString())

        binding.scanButton.setOnClickListener { scan() }
        binding.saveButton.setOnClickListener { save() }
        binding.results.setOnItemClickListener { _, _, position, _ ->
            binding.address.setText(found[position].url)
        }
    }

    private fun scan() {
        binding.scanButton.isEnabled = false
        binding.progress.visibility = View.VISIBLE
        binding.status.text = getString(R.string.setup_scanning)
        lifecycleScope.launch {
            val results = Discovery.scan(this@SetupActivity) { checked, total ->
                runOnUiThread {
                    binding.progress.isIndeterminate = false
                    binding.progress.max = total
                    binding.progress.progress = checked
                }
            }
            found = results
            binding.progress.visibility = View.GONE
            binding.scanButton.isEnabled = true
            if (results.isEmpty()) {
                binding.status.text = getString(R.string.setup_none_found)
                binding.results.adapter = null
            } else {
                binding.status.text = resources.getQuantityString(
                    R.plurals.setup_found, results.size, results.size,
                )
                binding.results.adapter = ArrayAdapter(
                    this@SetupActivity,
                    android.R.layout.simple_list_item_1,
                    results.map { it.url },
                )
                binding.address.setText(results.first().url)
            }
        }
    }

    private fun save() {
        val address = Prefs.normalise(binding.address.text.toString())
        if (address.isEmpty()) {
            binding.status.text = getString(R.string.setup_needs_address)
            return
        }
        binding.saveButton.isEnabled = false
        binding.status.text = getString(R.string.setup_checking)
        lifecycleScope.launch {
            val reachable = Api.probe(address)
            binding.saveButton.isEnabled = true
            // An address that does not answer right now is still worth keeping: the computer may
            // simply be asleep. Say so rather than refusing to save it.
            prefs.serverUrl = address
            prefs.backgroundRefresh = binding.background.isChecked
            prefs.notify = binding.notify.isChecked
            prefs.refreshMinutes = binding.interval.text.toString().toIntOrNull() ?: 60
            RefreshWorker.schedule(this@SetupActivity)
            if (reachable) {
                setResult(RESULT_OK)
                finish()
            } else {
                binding.status.text = getString(R.string.setup_saved_unreachable)
                setResult(RESULT_OK)
            }
        }
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }
}
