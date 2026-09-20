package com.worldbrief.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.worldbrief.app.databinding.ActivityMainBinding
import kotlinx.coroutines.launch

/**
 * The brief itself.
 *
 * When the machine running World Brief is reachable, this is its own interface — the same map,
 * the same fifteen-minute timer, the same translations. When it is not, the last brief the
 * background worker saved is rendered locally so there is still something to read.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: Prefs
    private lateinit var cache: BriefCache
    private var showingOffline = false

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* either way */ }

    private val setupLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (prefs.isConfigured) {
                RefreshWorker.schedule(this)
                load()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)

        prefs = Prefs(this)
        cache = BriefCache(this)

        configureWebView()
        binding.swipe.setOnRefreshListener { refresh() }
        binding.setupButton.setOnClickListener { openSetup() }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (!showingOffline && binding.web.canGoBack()) binding.web.goBack() else finish()
            }
        })

        askForNotificationPermission()

        if (!prefs.isConfigured) openSetup() else load()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        with(binding.web.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true          // the interface keeps the daily timer in localStorage
            databaseEnabled = true
            cacheMode = WebSettings.LOAD_DEFAULT
            useWideViewPort = true
            loadWithOverviewMode = true
            mediaPlaybackRequiresUserGesture = true
            // The page comes from the user's own machine; nothing else may be loaded into it.
            allowFileAccess = false
            allowContentAccess = false
            setSupportMultipleWindows(false)
        }
        binding.web.webViewClient = object : WebViewClient() {

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val url = request.url.toString()
                if (prefs.isConfigured && url.startsWith(prefs.serverUrl)) return false
                // Article links belong to the outlets that published them: hand them to the browser.
                startActivity(Intent(Intent.ACTION_VIEW, request.url))
                return true
            }

            override fun onPageFinished(view: WebView, url: String) {
                binding.swipe.isRefreshing = false
                binding.setupButton.visibility = if (showingOffline) android.view.View.VISIBLE
                                                 else android.view.View.GONE
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) showOffline(getString(R.string.offline_unreachable))
            }
        }
    }

    private fun askForNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
        if (granted != PackageManager.PERMISSION_GRANTED && prefs.notify) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun openSetup() {
        setupLauncher.launch(Intent(this, SetupActivity::class.java))
    }

    /** Try the live server; fall back to the saved brief the moment it does not answer. */
    private fun load() {
        if (!prefs.isConfigured) {
            showOffline(getString(R.string.offline_not_configured))
            return
        }
        binding.swipe.isRefreshing = true
        lifecycleScope.launch {
            if (Api.probe(prefs.serverUrl)) {
                showingOffline = false
                binding.web.loadUrl(prefs.serverUrl)
            } else {
                showOffline(getString(R.string.offline_unreachable))
            }
        }
    }

    private fun refresh() {
        if (showingOffline) {
            load()
            return
        }
        lifecycleScope.launch {
            Api.requestRefresh(prefs.serverUrl)
            binding.web.reload()
        }
    }

    private fun showOffline(reason: String) {
        showingOffline = true
        binding.swipe.isRefreshing = false
        val html = OfflineBrief.render(cache.load(), prefs.serverUrl, reason)
        binding.web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.main, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        R.id.action_refresh -> { refresh(); true }
        R.id.action_setup -> { openSetup(); true }
        else -> super.onOptionsItemSelected(item)
    }

    override fun onResume() {
        super.onResume()
        // Coming back after the desktop woke up should show the live brief, not the saved one.
        if (showingOffline && prefs.isConfigured) load()
    }

    override fun onDestroy() {
        binding.web.destroy()
        super.onDestroy()
    }
}
