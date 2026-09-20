package com.worldbrief.app

import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

/**
 * Turns a cached brief into a page the WebView can show when the server cannot be reached.
 *
 * It is deliberately the same shape as the real brief — headline, three-sentence summary, how
 * many outlets in how many countries carried it — so the offline copy reads like the app, not
 * like an error message.
 */
object OfflineBrief {

    fun render(cached: BriefCache.Cached?, serverUrl: String, reason: String): String {
        val body = if (cached == null) emptyState(serverUrl, reason) else briefBody(cached, reason)
        return page(body)
    }

    private fun briefBody(cached: BriefCache.Cached, reason: String): String {
        val events: JSONArray = cached.payload.optJSONArray("events") ?: JSONArray()
        val when_ = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
            .format(Date(cached.fetchedAt))
        val sb = StringBuilder()
        sb.append("""<div class="banner">$reason Showing the brief saved on $when_.</div>""")
        sb.append("""<h1>Your brief</h1>""")
        val minutes = cached.payload.optJSONObject("meta")?.optInt("brief_minutes", 0) ?: 0
        val sub = buildString {
            append(events.length()).append(if (events.length() == 1) " event" else " events")
            if (minutes > 0) append(" · about ").append(minutes).append(" minutes")
        }
        sb.append("""<p class="sub">${esc(sub)}</p>""")

        for (i in 0 until events.length()) {
            val e = events.optJSONObject(i) ?: continue
            sb.append(card(i + 1, e))
        }
        if (events.length() == 0) {
            sb.append("""<p class="sub">The saved brief is empty — the server had not built one yet.</p>""")
        }
        return sb.toString()
    }

    private fun card(rank: Int, e: JSONObject): String {
        val title = esc(e.optString("title"))
        val category = e.optJSONArray("categories")?.optJSONObject(0)?.optString("label").orEmpty()
        val sentences = e.optJSONArray("summary") ?: JSONArray()
        val lines = StringBuilder()
        for (i in 0 until sentences.length()) {
            val s = sentences.optJSONObject(i) ?: continue
            val source = s.optString("source")
            lines.append("<p>").append(esc(s.optString("sentence")))
            if (source.isNotEmpty()) lines.append(""" <span class="src">${esc(source)}</span>""")
            lines.append("</p>")
        }
        val outlets = e.optInt("outlet_count")
        val countries = e.optInt("country_count", e.optJSONArray("countries_mentioned")?.length() ?: 0)
        val place = e.optJSONObject("primary_location")?.optString("name").orEmpty()
        val facts = buildList {
            if (place.isNotEmpty()) add(place)
            if (outlets > 0) add("$outlets outlets")
            if (countries > 0) add("$countries countries")
            if (e.optDouble("divergence", 0.0) >= 0.5) add("contested framing")
        }.joinToString(" · ")

        return """
            <article>
              <div class="rank">$rank${if (category.isNotEmpty()) " · " + esc(category) else ""}</div>
              <h2>$title</h2>
              $lines
              <div class="facts">${esc(facts)}</div>
            </article>
        """.trimIndent()
    }

    private fun emptyState(serverUrl: String, reason: String): String = """
        <h1>Nothing saved yet</h1>
        <p class="sub">$reason</p>
        <p class="sub">World Brief reads from the copy running on your own computer, at
        ${esc(serverUrl.ifEmpty { "an address you have not set yet" })}. Start it there, make sure
        both devices are on the same network, then pull down to try again.</p>
    """.trimIndent()

    private fun page(body: String): String = """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
          :root {
            --bg:#fcfcfb; --surface:#fff; --border:#e3e2dc; --text:#1a1a19; --text-2:#55554f;
            --muted:#8a8a82; --accent:#2a78d6; --accent-soft:#e6f0fb;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg:#1a1a19; --surface:#222221; --border:#383835; --text:#fff; --text-2:#c3c2b7;
              --muted:#8f8e85; --accent:#3987e5; --accent-soft:#1c2f47;
            }
          }
          * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
          body {
            margin:0; padding:16px 16px 40px; background:var(--bg); color:var(--text);
            font:15px/1.55 -apple-system, Roboto, "Segoe UI", sans-serif;
          }
          .banner {
            background:var(--accent-soft); color:var(--accent); border-radius:10px;
            padding:10px 12px; font-size:13px; margin-bottom:18px;
          }
          h1 { font-size:24px; margin:0 0 4px; }
          .sub { color:var(--muted); font-size:13px; margin:0 0 18px; }
          article {
            background:var(--surface); border:1px solid var(--border); border-radius:12px;
            padding:14px 15px; margin-bottom:12px;
          }
          .rank { color:var(--muted); font-size:11px; letter-spacing:.04em; text-transform:uppercase; }
          h2 { font-size:17px; line-height:1.35; margin:4px 0 8px; }
          article p { margin:0 0 7px; color:var(--text-2); }
          .src { color:var(--muted); font-size:12px; }
          .facts { color:var(--muted); font-size:12px; margin-top:8px; }
        </style></head>
        <body>$body</body></html>
    """.trimIndent()

    private fun esc(s: String): String = s
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\"", "&quot;")
}
