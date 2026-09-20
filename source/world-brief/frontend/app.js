/* World Brief frontend: Brief list + detail, world map, sources, languages.
   Vanilla JS, no build step. Two independent language settings:
     - the interface language (strings from /static/i18n/<code>.json);
     - the language articles are translated into (local models, /api/translate). */
(function () {
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const GROUP = {
    war: "conflict", military: "conflict", instability: "conflict", "conflict-live": "conflict", disaster: "conflict",
    "political-change": "politics", "politics-law": "politics", international: "politics", "state-visit": "politics", regulation: "politics", opinion: "politics",
  };
  const groupOf = (cat) => GROUP[cat] || "society";
  const GROUP_COLOR = { conflict: "--g-conflict", politics: "--g-politics", society: "--g-society" };
  const cssVar = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  const POL_CLASS = { left: "left", right: "right", centre: "centre", "state/government": "state", "independent/opposition": "indep", other: "" };

  const state = {
    view: "brief", mode: "brief", filters: {}, events: [], meta: null, selected: null,
    countries: [], categories: [], countryName: {}, catLabel: {},
    ui: "en", tr: "", locales: [], trStatus: null, showOriginal: false, detail: null,
  };

  const api = async (path, opts) => { const r = await fetch(path, opts); if (!r.ok) throw new Error(`${r.status} ${path}`); return r.json(); };

  // ================================================================================================
  // Interface language
  // ================================================================================================
  const i18n = {
    code: "en", dir: "ltr", dict: {}, base: {},
    raw(key) {
      const v = this.dict[key];
      return (v === undefined || v === "") ? this.base[key] : v;
    },
    t(key, vars) {
      let s = this.raw(key);
      // A counted phrase is stored as {one: …, other: …}: pick the form this language uses for
      // this number. Russian needs four, Arabic six, Chinese one — Intl knows which.
      if (s && typeof s === "object") s = pickPlural(s, vars && vars.count);
      if (s === undefined) return key;
      if (vars) for (const k of Object.keys(vars)) s = s.split("{" + k + "}").join(String(vars[k]));
      return s;
    },
    has(key) { return this.raw(key) !== undefined; },
  };
  const t = (k, v) => i18n.t(k, v);

  function pickPlural(forms, count) {
    const n = Number(count);
    let cat = "other";
    if (Number.isFinite(n)) {
      try { cat = pluralRules ? pluralRules.select(n) : (n === 1 ? "one" : "other"); }
      catch (e) { cat = n === 1 ? "one" : "other"; }
    }
    return forms[cat] !== undefined ? forms[cat] : forms.other;
  }

  /** A counted noun: "3 articles", "3 статьи", "٣ مقالات". */
  const plural = (key, n, vars) => t(key, Object.assign({ count: n, n: num(n) }, vars));

  async function loadLocale(code) {
    if (!i18n.base.__loaded) {
      try { i18n.base = await api("/static/i18n/en.json"); } catch (e) { i18n.base = {}; }
      i18n.base.__loaded = true;
    }
    let dict = i18n.base;
    if (code !== "en") {
      try { dict = await api(`/static/i18n/${code}.json`); }
      catch (e) { code = "en"; dict = i18n.base; }
    }
    i18n.code = code; i18n.dict = dict;
    const loc = state.locales.find((l) => l.code === code);
    i18n.dir = loc ? loc.dir : "ltr";
    document.documentElement.lang = code;
    document.documentElement.dir = i18n.dir;
    buildFormatters();
  }

  // Names of countries and languages come from the browser's own CLDR data: correct in every
  // locale, and nothing for this project to translate or keep up to date.
  let dnRegion = null, dnLang = null, rtf = null, nf = null, pluralRules = null;
  function buildFormatters() {
    const loc = i18n.code;
    try { dnRegion = new Intl.DisplayNames([loc, "en"], { type: "region" }); } catch (e) { dnRegion = null; }
    try { dnLang = new Intl.DisplayNames([loc, "en"], { type: "language" }); } catch (e) { dnLang = null; }
    try { rtf = new Intl.RelativeTimeFormat(loc, { numeric: "always" }); } catch (e) { rtf = null; }
    try { nf = new Intl.NumberFormat(loc); } catch (e) { nf = null; }
    try { pluralRules = new Intl.PluralRules(loc); } catch (e) { pluralRules = null; }
  }
  // A place from the gazetteer: countries have a localised name, cities and regions do not.
  const placeName = (l) => (l && l.kind === "country" && l.country ? cname(l.country) : (l ? l.name : ""));
  const cname = (c) => {
    if (!c) return "";
    if (dnRegion) { try { const n = dnRegion.of(c); if (n && n !== c) return n; } catch (e) { /* not a region code */ } }
    return state.countryName[c] || c;
  };
  const lname = (code) => {
    if (!code) return "";
    const known = (state.trStatus?.languages || []).find((l) => l.code === code);
    if (dnLang) {
      try { const n = dnLang.of(code); if (n && n.toLowerCase() !== code.toLowerCase()) return n; } catch (e) { /* not a language code */ }
    }
    return known ? known.name : code;
  };
  const num = (n) => (nf ? nf.format(n) : String(n));

  function applyStatic(root = document) {
    $$("[data-i18n]", root).forEach((el) => { el.textContent = t(el.dataset.i18n); });
    $$("[data-i18n-ph]", root).forEach((el) => { el.placeholder = t(el.dataset.i18nPh); });
    $$("[data-i18n-title]", root).forEach((el) => { el.title = t(el.dataset.i18nTitle); });
    $$("[data-i18n-aria]", root).forEach((el) => { el.setAttribute("aria-label", t(el.dataset.i18nAria)); });
    $$("[data-i18n-content]", root).forEach((el) => { el.setAttribute("content", t(el.dataset.i18nContent)); });
    document.title = t("app.title");
  }

  // ---------- labels that come from the backend as English ids or free text ----------
  const catLabel = (id) => (i18n.has("cat." + id) ? t("cat." + id) : (state.catLabel[id] || id));
  const polLabel = (p) => (i18n.has("polarity." + p) ? t("polarity." + p) : p);
  const ownLabel = (o) => (i18n.has("ownership." + o) ? t("ownership." + o) : o);
  const stageLabel = (s) => (i18n.has("stage." + s) ? t("stage." + s) : s);
  const regionLabel = (r) => (i18n.has("region." + r) ? t("region." + r) : r);

  // Editorial leanings are free text written by hand in backend/outlets.py ("centre-left",
  // "liberal/independent (exiled)"). Known phrases come from the locale file; the rest is split on
  // the separators the labels use and translated piece by piece, so "liberal/independent" works
  // even though only its two halves are in the glossary. Anything still unknown goes to the
  // translation engine when the reader has it switched on.
  function leaningLabel(s) {
    if (!s) return "";
    const whole = "leaning." + s;
    if (i18n.has(whole)) return t(whole);
    let out = s.replace(/[^/(]+/g, (part) => {
      const key = "leaning." + part.trim().toLowerCase();
      if (!i18n.has(key)) return part;
      return part.replace(part.trim(), t(key));
    });
    if (out === s && i18n.code !== "en" && state.tr) out = trNow(s, "en");
    return out;
  }

  // ================================================================================================
  // Article translation
  // ================================================================================================
  const TRCACHE = new Map();                 // "srcLang|target|text" -> translated text
  const trKey = (text, lang) => `${lang || ""}|${state.tr}|${text}`;
  const needsTr = (text, lang) => !!(state.tr && text && lang && lang !== state.tr);

  /** The translation if we already have it, otherwise the original. Never blocks rendering. */
  function trNow(text, lang) {
    if (!needsTr(text, lang)) return text;
    const v = TRCACHE.get(trKey(text, lang));
    return v === undefined ? text : v;
  }
  const trMissing = (text, lang) => needsTr(text, lang) && !TRCACHE.has(trKey(text, lang));

  let trInFlight = 0;
  function setTranslatingFlag() {
    document.body.classList.toggle("translating", trInFlight > 0);
  }

  /** Translate a list of {text, lang}, in chunks, calling back after each chunk lands. */
  async function fillTranslations(jobs, onChunk) {
    if (!state.tr || !jobs.length) return;
    const seen = new Set(), todo = [];
    for (const j of jobs) {
      if (!trMissing(j.text, j.lang)) continue;
      const k = trKey(j.text, j.lang);
      if (seen.has(k)) continue;
      seen.add(k); todo.push(j);
    }
    if (!todo.length) return;
    const CHUNK = 120;
    for (let i = 0; i < todo.length; i += CHUNK) {
      const part = todo.slice(i, i + CHUNK);
      const target = state.tr;
      trInFlight++; setTranslatingFlag();
      try {
        const r = await api("/api/translate", {
          method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify({ texts: part.map((j) => j.text), langs: part.map((j) => j.lang), to: target }),
        });
        if (target !== state.tr) return;      // the reader changed language mid-flight
        r.results.forEach((res, k) => {
          const j = part[k];
          TRCACHE.set(trKey(j.text, j.lang), res.translated ? res.text : j.text);
        });
      } catch (e) {
        part.forEach((j) => TRCACHE.set(trKey(j.text, j.lang), j.text));
      } finally {
        trInFlight--; setTranslatingFlag();
      }
      if (onChunk) onChunk();
    }
  }

  /** Every string a brief card shows, with the language it is written in. */
  function cardJobs(e) {
    const jobs = [{ text: e.title, lang: e.lang }];
    if (e.summary && e.summary[0]) jobs.push({ text: e.summary[0].sentence, lang: e.summary[0].lang || e.lang });
    else if (e.extracts && e.extracts[0]) jobs.push({ text: e.extracts[0].text, lang: e.extracts[0].lang || e.lang });
    return jobs.filter((j) => j.text);
  }

  async function translateList() {
    if (!state.tr) return;
    const jobs = [];
    state.events.forEach((e) => jobs.push(...cardJobs(e)));
    await fillTranslations(jobs, patchList);
  }

  /** Update the headline and lede of cards already on screen, without losing scroll or focus. */
  function patchList() {
    const byId = new Map(state.events.map((e) => [e.id, e]));
    $$("#list .card").forEach((card) => {
      const e = byId.get(card.dataset.id);
      if (!e) return;
      const h = $("h3", card);
      if (h) h.textContent = trNow(e.title, e.lang);
      const badge = $(".tr-badge", card);
      if (badge) badge.classList.toggle("pending", trMissing(e.title, e.lang));
      const lede = $(".lede", card);
      if (lede) {
        const s = e.summary && e.summary[0];
        if (s) lede.textContent = trNow(s.sentence, s.lang || e.lang);
        else if (e.extracts && e.extracts[0]) lede.textContent = trNow(e.extracts[0].text, e.extracts[0].lang || e.lang).slice(0, 220) + "…";
      }
    });
  }

  // ================================================================================================
  // helpers
  // ================================================================================================
  const fmtAgo = (ts) => {
    const m = Math.max(0, Math.round((Date.now() / 1000 - ts) / 60));
    if (rtf) {
      if (m < 60) return rtf.format(-m, "minute");
      const h = Math.round(m / 60);
      if (h < 48) return rtf.format(-h, "hour");
      return rtf.format(-Math.round(h / 24), "day");
    }
    if (m < 60) return t("time.minAgo", { n: m });
    const h = Math.round(m / 60);
    return h < 48 ? t("time.hourAgo", { n: h }) : t("time.dayAgo", { n: Math.round(h / 24) });
  };
  const fmtTime = (ts) => new Date(ts * 1000).toLocaleString(i18n.code, { weekday: "short", hour: "2-digit", minute: "2-digit", day: "numeric", month: "short" });
  const fmtDur = (s) => plural("n.minutes", Math.max(1, Math.round(s / 60)));
  const fmtBytes = (b) => (b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : Math.round(b / 1e6) + " MB");

  // ---------- timer (15-minute daily budget, persisted per day in localStorage) ----------
  const BUDGET = 15 * 60;
  const timer = { left: BUDGET, running: false, tick: null };
  function timerKey() { return "wb-timer-" + new Date().toISOString().slice(0, 10); }
  function loadTimer() { try { const v = localStorage.getItem(timerKey()); if (v !== null) timer.left = Math.max(0, +v); } catch (e) {} }
  function saveTimer() { try { localStorage.setItem(timerKey(), String(timer.left)); } catch (e) {} }
  function renderTimer() {
    const m = Math.floor(timer.left / 60), s = timer.left % 60;
    $("#timer-num").textContent = `${m}:${String(s).padStart(2, "0")}`;
    $("#ring").style.strokeDashoffset = String(97.4 * (1 - timer.left / BUDGET));
    $("#timer-toggle").textContent = timer.running ? t("timer.pause") : (timer.left === BUDGET ? t("timer.start") : t("timer.resume"));
    $("#timer-label").textContent = timer.left === 0 ? t("timer.done") : t("timer.left");
  }
  function toggleTimer() {
    timer.running = !timer.running;
    clearInterval(timer.tick);
    if (timer.running) timer.tick = setInterval(() => { if (timer.left > 0) { timer.left--; saveTimer(); renderTimer(); } else { toggleTimer(); } }, 1000);
    renderTimer();
  }
  document.addEventListener("visibilitychange", () => { if (document.hidden && timer.running) toggleTimer(); });

  // The pipeline reports its progress as short English phrases; give the few shapes it uses a
  // translation and pass anything else through unchanged.
  function progressLabel(raw) {
    const p = (raw || "").trim();
    let m;
    if ((m = /^(\d+)\/(\d+) feeds$/.exec(p))) return t("stage.feeds", { done: num(+m[1]), total: num(+m[2]) });
    if ((m = /^(\d+) articles$/.exec(p))) return t("stage.nArticles", { n: num(+m[1]) });
    if ((m = /^(\d+) clusters$/.exec(p))) return t("stage.nClusters", { n: num(+m[1]) });
    if ((m = /^top (\d+)$/.exec(p))) return t("stage.topN", { n: num(+m[1]) });
    if ((m = /^fallback feeds for (\d+) uncovered countries$/.exec(p))) return t("stage.fallbackFeeds", { n: num(+m[1]) });
    if (p === "rules + locations for new articles") return t("stage.rulesLocations");
    return p;
  }

  // ---------- status ----------
  async function pollStatus() {
    try {
      const s = await api("/api/status");
      const box = $("#status");
      if (s.pipeline.running) {
        box.hidden = false;
        const progress = progressLabel(s.pipeline.progress);
        box.innerHTML = `<span class="spin"></span> ${esc(t("status.refreshing", { stage: stageLabel(s.pipeline.stage), progress }))}`;
      } else if (!s.meta) {
        box.hidden = false;
        box.innerHTML = s.pipeline.last_error
          ? `${esc(t("status.failed", { error: s.pipeline.last_error }))} <button class="ghost" id="retry">${esc(t("status.retry"))}</button>`
          : esc(t("status.first"));
        $("#retry")?.addEventListener("click", () => api("/api/refresh", { method: "POST" }));
      } else {
        box.hidden = true;
        if (state.meta && s.meta.generated_at !== state.meta.generated_at) loadEvents();
      }
      if (s.meta && !state.meta) loadEvents();
    } catch (e) { /* ignore */ }
    setTimeout(pollStatus, 5000);
  }

  // ================================================================================================
  // brief
  // ================================================================================================
  function chips(e) {
    const cats = e.categories.slice(0, 3).map((c) => `<span class="chip cat ${groupOf(c.id)}">${esc(catLabel(c.id))}</span>`).join("");
    const sides = e.sides && e.sides.length >= 2
      ? `<span class="chip sides">${esc(t("chip.sides", { sides: plural("n.sides", e.sides.length), basis: t(e.side_basis === "country" ? "basis.country" : "basis.leaning") }))}</span>` : "";
    const polKinds = Object.keys(e.polarities || {}).filter((p) => p !== "other");
    const st = polKinds.includes("state/government") ? `<span class="chip">${esc(t("chip.stateMedia"))}</span>` : "";
    return `<div class="chips">${cats}${sides}${st}</div>`;
  }
  const coverageLine = (e) => t("card.coverage", {
    outlets: plural("n.outlets", e.outlet_count),
    countries: plural("n.countries", e.country_count),
    articles: plural("n.articles", e.article_count),
  });
  function renderStats() {
    const m = state.meta; if (!m) return;
    const items = [
      [num(m.brief_events), t("stats.briefEvents")],
      [fmtDur(m.brief_seconds), t("stats.estReading")],
      [num(m.event_count), t("stats.eventsDetected")],
      [num(m.article_count), t("stats.articlesWindow", { hours: m.window_hours })],
      [`${num(m.countries_covered)}/${num(m.countries_total)}`, t("stats.nationsCovered")],
      [num(m.feeds_ok), t("stats.feedsLive", { failed: num(m.feeds_failed) })],
    ];
    $("#stats").innerHTML = items.map(([v, l]) => `<div class="stat"><div class="v">${esc(v)}</div><div class="l">${esc(l)}</div></div>`).join("");
  }
  function trBadge(text, lang) {
    if (!state.tr || !lang || lang === state.tr) return "";
    const pending = trMissing(text, lang);
    const tip = pending ? t("lang.translating") : t("lang.translatedFrom", { language: lname(lang) });
    return `<span class="tr-badge${pending ? " pending" : ""}" title="${esc(tip)}">${esc(lname(lang))} →</span>`;
  }
  function renderList() {
    const list = $("#list");
    if (!state.events.length) {
      list.innerHTML = `<div class="empty">${esc(t("list.empty"))} ${state.meta ? "" : esc(t("list.waiting"))}</div>`;
      return;
    }
    list.innerHTML = state.events.map((e, i) => {
      const loc = e.primary_location ? esc(placeName(e.primary_location)) : "";
      const ctry = e.countries_mentioned.slice(0, 3).map(cname).join(", ");
      const s0 = e.summary && e.summary[0];
      const lede = s0 ? `<div class="lede">${esc(trNow(s0.sentence, s0.lang || e.lang))}</div>`
        : (e.extracts[0] ? `<div class="lede">${esc(trNow(e.extracts[0].text, e.extracts[0].lang || e.lang).slice(0, 220))}…</div>` : "");
      return `<article class="card ${state.selected === e.id ? "active" : ""}" data-id="${e.id}" tabindex="0">
        <div class="rank"><span class="n">${e.in_brief && state.mode === "brief" ? num(e.brief_rank) : num(i + 1)}</span><div class="meter" title="${esc(t("detail.relevance", { n: e.relevance }))}"><i style="height:${Math.max(6, e.relevance)}%"></i></div></div>
        <div>
          <h3>${esc(trNow(e.title, e.lang))}</h3>
          <div class="meta"><span>${esc(fmtAgo(e.time_last))}</span>${loc ? `<span>📍 ${loc}${ctry && ctry !== loc ? " · " + esc(ctry) : ""}</span>` : ""}<span>${esc(coverageLine(e))}</span><span>⏱ ${esc(plural("n.minutes", Math.round(e.reading_seconds / 60 * 10) / 10))}</span>${trBadge(e.title, e.lang)}</div>
          ${lede}
          ${chips(e)}
        </div></article>`;
    }).join("");
    $$(".card", list).forEach((c) => { c.addEventListener("click", () => select(c.dataset.id)); c.addEventListener("keydown", (ev) => { if (ev.key === "Enter") select(c.dataset.id); }); });
  }
  function polbar(e) {
    const tot = Object.values(e.polarities).reduce((a, b) => a + b, 0) || 1;
    const bars = Object.entries(e.polarities).map(([p, n]) => `<i class="${POL_CLASS[p] ?? ""}" style="width:${(100 * n / tot).toFixed(1)}%" title="${esc(polLabel(p))}: ${num(n)}"></i>`).join("");
    const leg = Object.entries(e.polarities).map(([p, n]) => `<span><i class="dot" style="background:var(${{ left: "--g-conflict", right: "--g-politics", centre: "--g-society" }[p] || (p === "state/government" ? "--warning" : p === "independent/opposition" ? "--accent" : "--muted")})"></i> ${esc(polLabel(p))} ${num(n)}</span>`).join("");
    return `<div class="polbar">${bars}</div><div class="pollegend">${leg}</div>`;
  }

  // Keep the original next to every translated passage: one click swaps the whole panel back.
  function orig(e, obj, key) {
    return (obj && obj._original && obj._original[key]) || null;
  }
  function field(e, obj, key) {
    const o = orig(e, obj, key);
    if (state.showOriginal && o) return o;
    return obj[key];
  }

  async function select(id) {
    state.selected = id;
    state.showOriginal = false;
    $$(".card").forEach((c) => c.classList.toggle("active", c.dataset.id === id));
    const d = $("#detail"); d.classList.add("open");
    d.innerHTML = `<div class="empty">${esc(t("detail.loading"))}</div>`;
    let e;
    try { e = await api(`/api/events/${id}${state.tr ? `?lang=${encodeURIComponent(state.tr)}` : ""}`); }
    catch (err) { d.innerHTML = `<div class="empty">${esc(t("detail.loadError"))}</div>`; return; }
    if (state.selected !== id) return;
    state.detail = e;
    renderDetail();
  }

  function renderDetail() {
    const e = state.detail; if (!e) return;
    const d = $("#detail");
    const id = e.id;
    const sum = e.summary.length
      ? e.summary.map((s) => `<p>${esc(field(e, s, "sentence"))}<span class="src">— ${esc(s.source)}</span></p>`).join("")
      : `<p class="empty">${esc(t("detail.noSummary"))}</p>`;
    const sideCount = (n) => plural("n.articles", n);
    const sides = e.sides && e.sides.length >= 2
      ? `<h4>${esc(t("detail.perspectives", { basis: t(e.side_basis === "country" ? "basisLong.country" : "basisLong.leaning"), pct: (e.divergence * 100).toFixed(0) }))}</h4>` +
        e.sides.map((s) => `<div class="side"><div class="who">${esc(sideName(e, s))} · ${esc(sideCount(s.n))}</div>
          <div class="h"><a href="${esc(s.url)}" target="_blank" rel="noopener">${esc(field(e, s, "headline"))}</a></div>
          <div class="x">${esc(field(e, s, "extract"))}</div>
          <div class="who">${esc(s.outlet)} (${esc(cname(s.country))}) · ${esc(leaningLabel(s.leaning))}</div></div>`).join("")
      : "";
    const extracts = e.extracts.length
      ? `<details class="more"><summary><h4>${esc(t("detail.extracts", { n: num(e.extracts.length) }))}</h4></summary>` +
        e.extracts.map((x) => `<blockquote class="extract">${esc(field(e, x, "text"))}<span class="who">${esc(x.outlet)} · ${esc(cname(x.country))} · ${esc(leaningLabel(x.leaning))} · <a href="${esc(x.url)}" target="_blank" rel="noopener">${esc(t("detail.open"))}</a></span></blockquote>`).join("") + `</details>`
      : "";
    const arts = e.articles.map((a) => `<li><a href="${esc(a.url)}" target="_blank" rel="noopener">${esc(field(e, a, "title"))}</a><div class="who">${esc(a.outlet)} · ${esc(cname(a.country))} · ${esc(fmtAgo(a.published))}<span class="tag ${a.ownership === "state" || a.ownership === "party" ? "state" : ""}">${esc(leaningLabel(a.leaning))}</span>${a.ownership && a.ownership !== "unknown" ? `<span class="tag">${esc(ownLabel(a.ownership))}</span>` : ""}</div></li>`).join("");
    const locs = e.locations.map((l) => `${esc(placeName(l))}${l.country && l.kind !== "country" ? " (" + esc(cname(l.country)) + ")" : ""}`).join(", ");
    const tr = e.translation;
    let trNotice = "";
    if (tr && (tr.translated || tr.untranslated)) {
      const bits = [];
      if (tr.translated) bits.push(`<button class="ghost small" id="toggle-original">${esc(t(state.showOriginal ? "lang.showTranslation" : "lang.showOriginal"))}</button>`);
      if (tr.untranslated) bits.push(`<span>${esc(t("lang.untranslatedNotice", { passages: plural("n.passages", tr.untranslated), languages: tr.missing.map(lname).join(", ") }))}</span>`);
      trNotice = `<div class="tr-notice"><span>${esc(t("lang.machineNotice"))}</span>${bits.join("")}</div>`;
    }
    d.innerHTML = `<button class="ghost close" id="close">${esc(t("detail.close"))}</button>
      <div class="meta"><span>${esc(e.in_brief ? t("detail.inBrief", { rank: num(e.brief_rank) }) : t("detail.notInBrief"))}</span><span>${esc(t("detail.relevance", { n: num(e.relevance) }))}</span><span>⏱ ${esc(plural("n.minutes", Math.round(e.reading_seconds / 60 * 10) / 10))}</span></div>
      <h2>${esc(field(e, e, "title"))}</h2>
      ${chips(e)}
      ${trNotice}
      <div class="kv" style="margin-top:8px"><span>${esc(t("detail.when"))}</span><span>${esc(fmtTime(e.time_first))} → ${esc(fmtTime(e.time_last))}</span><span>${esc(t("detail.where"))}</span><span>${locs || "—"}</span><span>${esc(t("detail.coverage"))}</span><span>${esc(t("detail.coverageValue", { outlets: plural("n.outlets", e.outlet_count), countries: plural("n.countries", e.country_count), list: e.countries_covering.slice(0, 8).map(cname).join(", ") + (e.countries_covering.length > 8 ? "…" : "") }))}</span><span>${esc(t("detail.languages"))}</span><span>${esc(e.languages.map(lname).join(", "))}</span></div>
      ${polbar(e)}
      <h4>${esc(t("detail.summary"))}</h4><div class="summary">${sum}</div>
      ${sides}
      ${extracts}
      <details class="more" ${e.article_count <= 6 ? "open" : ""}><summary><h4>${esc(t("detail.articles", { articles: plural("n.articles", e.article_count), outlets: plural("n.outlets", e.outlet_count) }))}</h4></summary><ul class="arts">${arts}</ul></details>
      <div class="fb"><span class="src">${esc(t("detail.teach"))}</span><button class="ghost ${e.feedback === 1 ? "on" : ""}" data-fb="1">${esc(t("detail.important"))}</button><button class="ghost ${e.feedback === -1 ? "on" : ""}" data-fb="-1">${esc(t("detail.notImportant"))}</button></div>`;
    $("#close").addEventListener("click", () => d.classList.remove("open"));
    $("#toggle-original")?.addEventListener("click", () => { state.showOriginal = !state.showOriginal; renderDetail(); d.scrollTop = 0; });
    $$("[data-fb]", d).forEach((b) => b.addEventListener("click", async () => {
      await api("/api/feedback", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ event_id: id, label: +b.dataset.fb }) });
      $$("[data-fb]", d).forEach((x) => x.classList.toggle("on", x === b));
    }));
  }

  // A side is either a country code (when the story spans countries) or an editorial polarity.
  function sideName(e, s) {
    return e.side_basis === "country" ? t("detail.countryOutlets", { country: cname(s.side) }) : polLabel(s.side);
  }

  async function loadEvents() {
    const f = state.filters;
    const p = new URLSearchParams();
    if (state.mode === "brief") p.set("brief", "1");
    else if (state.mode !== "all") p.set("sort", state.mode);
    if (state.mode === "discussed") p.set("min_articles", "2");
    for (const k of ["category", "region", "country", "hours", "q"]) if (f[k]) p.set(k, f[k]);
    p.set("limit", "300");
    try {
      const d = await api(`/api/events?${p}`);
      state.meta = d.meta; state.events = d.events;
      renderStats(); renderList();
      translateList();
    } catch (e) { $("#list").innerHTML = `<div class="empty">${esc(t("list.loadError"))}</div>`; }
  }

  // ================================================================================================
  // map
  // ================================================================================================
  let map, layers = { events: null, hotspots: null, edges: null }, mapData = null, mapAttribution = "";
  const layerOn = { events: true, hotspots: true, edges: true };
  function initMap() {
    if (map) return;
    map = L.map("map", { worldCopyJump: true, minZoom: 1.5, maxZoom: 8, attributionControl: true }).setView([22, 10], 2);
    mapAttribution = t("map.attribution");
    map.attributionControl.setPrefix("").addAttribution(mapAttribution);
    // Country outlines from a local GeoJSON: no tile server, no API key, works offline.
    fetch("/static/world.geojson").then((r) => r.json()).then((gj) => {
      const land = cssVar("--surface-2"), border = cssVar("--border");
      L.geoJSON(gj, { style: () => ({ color: border, weight: 0.8, fillColor: land, fillOpacity: 1 }), interactive: false, pane: "tilePane" }).addTo(map);
    }).catch(() => {});
    layers.edges = L.layerGroup().addTo(map); layers.hotspots = L.layerGroup().addTo(map); layers.events = L.layerGroup().addTo(map);
  }
  async function loadMap() {
    initMap();
    const p = new URLSearchParams();
    if ($("#m-category").value) p.set("category", $("#m-category").value);
    if ($("#m-hours").value) p.set("hours", $("#m-hours").value);
    p.set("min_relevance", $("#m-rel").value);
    p.set("min_articles", $("#m-single").checked ? "1" : "2");
    mapData = await api(`/api/map?${p}`);
    drawMap();
    if (state.tr) {
      const byId = new Map(state.events.map((e) => [e.id, e]));
      const jobs = [];
      mapData.nodes.forEach((n) => jobs.push({ text: n.title, lang: byId.get(n.id)?.lang || "" }));
      mapData.hotspots.forEach((h) => h.events.forEach((ev) => jobs.push({ text: ev.title, lang: byId.get(ev.id)?.lang || "" })));
      await fillTranslations(jobs.filter((j) => j.lang), drawMap);
    }
  }
  function nodeLang(id) {
    const e = state.events.find((x) => x.id === id);
    return e ? e.lang : "";
  }
  function drawMap() {
    Object.values(layers).forEach((l) => l.clearLayers());
    if (!mapData) return;
    const fg = cssVar("--text");
    if (layerOn.edges) {
      const max = Math.max(1, ...mapData.edges.map((e) => e.weight));
      mapData.edges.forEach((e) => {
        L.polyline([e.from, e.to], { color: cssVar("--accent"), weight: 1 + 3 * e.weight / max, opacity: 0.35 + 0.4 * e.weight / max, dashArray: "4 6" })
          .bindTooltip(esc(t("map.linked", { a: cname(e.a), b: cname(e.b), weight: num(e.weight) }))).addTo(layers.edges);
      });
    }
    if (layerOn.hotspots) {
      const max = Math.max(1, ...mapData.hotspots.map((h) => h.relevance));
      mapData.hotspots.forEach((h) => {
        const r = 6 + 34 * Math.sqrt(h.relevance / max);
        L.circleMarker([h.lat, h.lon], { radius: r, color: cssVar(GROUP_COLOR[groupOf(h.top_category)]), weight: 1, opacity: .5, fillOpacity: .12, interactive: true })
          .on("click", () => sidePanel(`<h3>${esc(cname(h.country) || h.name)}</h3><div class="meta"><span>${esc(plural("n.events", h.count))}</span><span>${esc(t("map.hotspotScore", { n: num(h.relevance) }))}</span><span>${esc(t("map.mostly", { category: catLabel(h.top_category) }))}</span></div><ul>${h.events.map((e) => `<li><a href="#" data-ev="${e.id}">${esc(trNow(e.title, nodeLang(e.id)))}</a></li>`).join("")}</ul>`))
          .addTo(layers.hotspots);
      });
    }
    if (layerOn.events) {
      mapData.nodes.forEach((n) => {
        const col = cssVar(GROUP_COLOR[groupOf(n.category)]);
        const r = 4 + 9 * Math.sqrt(n.relevance / 100);
        const title = trNow(n.title, nodeLang(n.id));
        const m = L.circleMarker([n.lat, n.lon], { radius: r, color: n.in_brief ? fg : col, weight: n.in_brief ? 2.5 : 1.5, fillColor: col, fillOpacity: .85 });
        m.bindTooltip(`<b>${esc(title)}</b><br>${esc(n.place)} · ${esc(catLabel(n.category))} · ${esc(t("map.outletsArticles", { outlets: plural("n.outlets", n.outlets), articles: plural("n.articles", n.articles) }))} · ${esc(fmtAgo(n.time_last))}`, { direction: "top", offset: [0, -r] });
        m.on("click", () => sidePanel(`<h3>${esc(title)}</h3><div class="meta"><span>📍 ${esc(n.place)}</span><span>${esc(catLabel(n.category))}</span><span>${esc(t("detail.relevance", { n: num(n.relevance) }))}</span><span>${esc(t("map.outletsArticles", { outlets: plural("n.outlets", n.outlets), articles: plural("n.articles", n.articles) }))}</span><span>${esc(fmtAgo(n.time_last))}</span>${n.divergence > 0.5 ? `<span>${esc(t("map.contested", { pct: (n.divergence * 100).toFixed(0) }))}</span>` : ""}</div><p>${esc(t("map.countries", { list: n.countries.map(cname).join(", ") || "—" }))}</p><p><a href="#" data-ev="${n.id}">${esc(t("map.readInBrief"))}</a></p>`));
        m.addTo(layers.events);
      });
    }
  }
  function sidePanel(html) {
    const s = $("#map-side"); s.innerHTML = html;
    $$("[data-ev]", s).forEach((a) => a.addEventListener("click", (ev) => { ev.preventDefault(); showView("brief"); state.mode = "all"; $$("#mode button").forEach((b) => b.classList.toggle("active", b.dataset.mode === "all")); loadEvents().then(() => select(a.dataset.ev)); }));
  }

  // ================================================================================================
  // sources
  // ================================================================================================
  let sourcesData = null;
  async function loadSources() {
    if (!sourcesData) sourcesData = await api("/api/sources");
    renderSources();
    if (state.tr && i18n.code !== "en") {
      const jobs = [];
      allSources().forEach((s) => { if (s.leaning && !i18n.has("leaning." + s.leaning)) jobs.push({ text: s.leaning, lang: "en" }); });
      fillTranslations(jobs, renderSources);
    }
  }
  function allSources() {
    if (!sourcesData) return [];
    return [...sourcesData.direct, ...sourcesData.google_news.map((g) => ({
      ...g,
      leaning: g.kind === "gnews-national" ? t("sources.nationalEdition") : t("sources.searchFeed"),
      ownership: "aggregator", _agg: true,
    }))];
  }
  function renderSources() {
    if (!sourcesData) return;
    const q = ($("#s-q").value || "").toLowerCase(); const failing = $("#s-failing").checked;
    const isOk = (s) => s.last_ok && s.last_try && s.last_ok >= s.last_try - 1;
    const byC = {};
    allSources().forEach((s) => {
      if (failing && (isOk(s) || !s.last_try)) return;
      const name = cname(s.country) || s.country_name;
      const hay = `${s.name} ${s.country_name} ${name} ${s.leaning} ${leaningLabel(s.leaning)} ${s.ownership || ""}`.toLowerCase();
      if (q && !hay.includes(q)) return;
      (byC[name] ||= []).push(s);
    });
    const names = Object.keys(byC).sort((a, b) => a.localeCompare(b, i18n.code));
    $("#sources").innerHTML = names.map((n) => `<div class="src-country">${esc(n)} · ${num(byC[n].length)}</div><div class="src-grid">` +
      byC[n].map((s) => `<div class="src"><span class="n">${esc(s.name)}</span><span class="h ${!s.last_try ? "na" : isOk(s) ? "ok" : "bad"}" title="${esc(s.last_error || "")}">${!s.last_try ? esc(t("sources.notTried")) : isOk(s) ? esc(plural("n.items", s.items)) : esc(t("sources.failing"))}</span><span class="l">${esc(s._agg ? s.leaning : leaningLabel(s.leaning))}${s.ownership && s.ownership !== "aggregator" ? " · " + esc(ownLabel(s.ownership)) : ""}${s.tier ? " · " + esc(t("sources.tier", { n: s.tier })) : ""}</span></div>`).join("") + `</div>`).join("")
      || `<div class="empty">${esc(t("sources.empty"))}</div>`;
  }

  // ================================================================================================
  // languages
  // ================================================================================================
  let langPoll = null, showAllPackages = false, pkgQuery = "";
  const ROUTE_KEY = { direct: "lang.routeDirect", pivot: "lang.routePivot", same: "lang.routeSame",
                      missing: "lang.routeMissing", endpoint: "lang.routeEndpoint" };
  async function loadLanguages() {
    const before = state.trStatus?.installed_count;
    try { state.trStatus = await api(`/api/translate/status${state.tr ? `?lang=${encodeURIComponent(state.tr)}` : ""}`); }
    catch (e) { state.trStatus = null; }
    // A newly installed package changes what can be translated. Passages that came back as
    // originals are cached as such, so forget them and let the brief ask again.
    if (before !== undefined && state.trStatus && state.trStatus.installed_count !== before) {
      TRCACHE.clear();
      renderList();
      translateList();
      if (state.selected) select(state.selected);
    }
    renderLanguages();
    schedulePoll();
  }
  function schedulePoll() {
    clearTimeout(langPoll);
    const busy = Object.values(state.trStatus?.downloads || {}).some((d) => d.state === "downloading" || d.state === "installing");
    if (busy && state.view === "languages") langPoll = setTimeout(loadLanguages, 1200);
  }
  /** The download / progress / remove control for one package. */
  function downloadButton(from, to, dl, installed, size) {
    if (dl && dl.state === "downloading") {
      return `<span class="pk-prog"><i style="width:${dl.pct || 0}%"></i></span>` +
             `<span class="pk-state">${esc(t("lang.downloading", { pct: dl.pct || 0 }))}</span>`;
    }
    if (dl && dl.state === "installing") return `<span class="pk-state">${esc(t("lang.installing"))}</span>`;
    if (dl && dl.state === "error") {
      return `<span class="pk-state bad" title="${esc(dl.error || "")}">${esc(t("lang.installFailed", { error: (dl.error || "").slice(0, 60) }))}</span>` +
             `<button class="ghost small" data-install="${from}/${to}">${esc(t("lang.retryInstall"))}</button>`;
    }
    if (installed) {
      return `<span class="pk-state ok">${esc(t("lang.installed"))} · ${esc(fmtBytes(size || 0))}</span>` +
             `<button class="ghost small" data-remove="${from}/${to}">${esc(t("lang.remove"))}</button>`;
    }
    return `<button class="ghost small" data-install="${from}/${to}">${esc(t("lang.install"))}</button>`;
  }
  function pkgRow(p) {
    return `<div class="pk"><span class="pk-name">${esc(lname(p.from))} → ${esc(lname(p.to))}</span>` +
           `${downloadButton(p.from, p.to, p.download, p.installed, p.size)}</div>`;
  }
  function renderLanguages() {
    const box = $("#languages");
    const st = state.trStatus;
    if (!st) { box.innerHTML = `<div class="empty">${esc(t("list.loadError"))}</div>`; return; }
    if (!st.enabled) { box.innerHTML = `<div class="empty">${esc(t("lang.disabled"))}</div>`; return; }

    const engine = st.local_available
      ? `<div class="note ok">${esc(t("lang.engineReady"))}</div>`
      : (st.endpoint ? `<div class="note ok">${esc(t("lang.engineEndpoint", { endpoint: st.endpoint }))}</div>`
        : `<div class="note bad">${t("lang.engineMissing", { command: "<code>pip install ctranslate2 sentencepiece</code>" })}</div>`);

    // What today's news is written in, and whether it can be read in the chosen language.
    const need = [];
    const corpus = (st.corpus || []).filter((c) => c.articles > 0).map((c) => {
      const counts = `<span class="pk-sub">${esc(t("lang.articlesShare", { articles: plural("n.articles", c.articles), share: num(c.share) }))}</span>`;
      if (!st.target) return `<div class="pk"><span class="pk-name">${esc(lname(c.code))}</span>${counts}</div>`;
      const route = c.route || (c.code === st.target ? "same" : "missing");
      (c.needs || []).forEach((n) => { if (n.available && !need.some((x) => x.from === n.from && x.to === n.to)) need.push(n); });
      // "missing" with nothing downloadable means no open-source model exists for that language at all.
      const unavailable = route === "missing" && (!c.needs || !c.needs.length || c.needs.some((n) => !n.available));
      const label = unavailable ? t("lang.unavailable", { language: lname(c.code) }) : t(ROUTE_KEY[route] || "lang.routeMissing");
      // A language that only needs a download gets the button right here, next to the reason to want it.
      const dl = (c.needs || []).filter((n) => n.available)
        .map((n) => downloadButton(n.from, n.to, st.downloads[`${n.from}-${n.to}`])).join("");
      return `<div class="pk"><span class="pk-name">${esc(lname(c.code))}</span>${counts}
        <span class="pk-state ${route === "missing" ? (unavailable ? "bad" : "") : "ok"}">${esc(label)}</span>${dl}</div>`;
    }).join("");
    const bulk = !st.target
      ? `<div class="note">${esc(t("lang.pickTarget"))}</div>`
      : (need.length
        ? `<button class="ghost" id="install-needed">${esc(t("lang.installAllNeeded", { packages: plural("n.packages", need.length), size: fmtBytes(need.length * 90e6) }))}</button>`
        : `<div class="note">${esc(t("lang.noneNeeded"))}</div>`);

    const q = pkgQuery.toLowerCase();
    const shown = st.packages.filter((p) => !q || `${lname(p.from)} ${lname(p.to)} ${p.from_english} ${p.to_english} ${p.from} ${p.to}`.toLowerCase().includes(q));
    const installedFirst = [...shown].sort((a, b) => (b.installed - a.installed) || a.from_english.localeCompare(b.from_english, i18n.code));
    const list = (showAllPackages || q ? installedFirst : installedFirst.filter((p) => p.installed)).map(pkgRow).join("");

    box.innerHTML = `
      ${engine}
      <section class="lang-block">
        <h3>${esc(t("lang.interface"))}</h3>
        <p class="note">${esc(t("lang.interfaceHelp"))}</p>
        <select id="ui-lang-2"></select>
      </section>
      <section class="lang-block">
        <h3>${esc(t("lang.translation"))}</h3>
        <p class="note">${esc(t("lang.translateHelp"))}</p>
        <select id="tr-lang-2"></select>
      </section>
      <section class="lang-block">
        <h3>${esc(t("lang.inYourNews"))}</h3>
        <p class="note">${esc(t("lang.inYourNewsHelp"))}</p>
        <div class="pk-list">${corpus || `<div class="empty">${esc(t("list.waiting"))}</div>`}</div>
        ${bulk}
      </section>
      <section class="lang-block">
        <h3>${esc(t("lang.packages"))}</h3>
        <p class="note">${esc(t("lang.packagesHelp"))}</p>
        <div class="pk-tools">
          <input id="pk-q" type="search" data-i18n-ph="lang.searchPackages" placeholder="${esc(t("lang.searchPackages"))}" value="${esc(pkgQuery)}">
          <button class="ghost small" id="pk-toggle">${esc(showAllPackages ? t("lang.hidePackages") : t("lang.showAllPackages", { n: st.packages.length }))}</button>
          <button class="ghost small" id="pk-refresh">${esc(t("lang.refreshIndex"))}</button>
        </div>
        <div class="pk-list">${list || `<div class="empty">${esc(t("sources.empty"))}</div>`}</div>
        <p class="note">${esc(t("lang.storageUsed", { packages: plural("n.packages", st.installed_count), size: fmtBytes(st.installed_bytes) }))} · ${esc(plural("n.translations", st.cache.cached))}
          <button class="ghost small" id="tr-clear">${esc(t("lang.clearCache"))}</button></p>
      </section>`;

    fillLanguageSelects();
    $("#ui-lang-2").addEventListener("change", (ev) => setUiLang(ev.target.value));
    $("#tr-lang-2").addEventListener("change", (ev) => setTrLang(ev.target.value));
    $("#pk-toggle").addEventListener("click", () => { showAllPackages = !showAllPackages; renderLanguages(); });
    $("#pk-refresh").addEventListener("click", async () => { await api("/api/translate/index/refresh", { method: "POST" }); loadLanguages(); });
    $("#tr-clear").addEventListener("click", async () => { await api("/api/translate/cache", { method: "DELETE" }); TRCACHE.clear(); loadLanguages(); renderList(); translateList(); });
    let pq; $("#pk-q").addEventListener("input", (ev) => { pkgQuery = ev.target.value; clearTimeout(pq); pq = setTimeout(renderLanguages, 200); });
    $("#install-needed")?.addEventListener("click", async () => { for (const n of need) await installPackage(n.from, n.to); loadLanguages(); });
    $$("[data-install]", box).forEach((b) => b.addEventListener("click", async () => {
      const [f, to] = b.dataset.install.split("/"); await installPackage(f, to); loadLanguages();
    }));
    $$("[data-remove]", box).forEach((b) => b.addEventListener("click", async () => {
      const [f, to] = b.dataset.remove.split("/");
      await api(`/api/translate/packages/${f}/${to}`, { method: "DELETE" });
      loadLanguages();
    }));
  }
  async function installPackage(from, to) {
    try { await api("/api/translate/packages", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ from_code: from, to_code: to }) }); }
    catch (e) { /* surfaced by the next status poll */ }
  }

  // ================================================================================================
  // language selectors
  // ================================================================================================
  function fillLanguageSelects() {
    const uiOpts = state.locales.map((l) => `<option value="${l.code}"${l.code === state.ui ? " selected" : ""}>${esc(l.name)}${l.complete < 100 ? ` (${l.complete}%)` : ""}</option>`).join("");
    // Articles can be translated into any language a package exists for, not just the interface ones.
    const targets = (state.trStatus?.languages || state.locales).slice().sort((a, b) => (a.english_name || a.name).localeCompare(b.english_name || b.name, i18n.code));
    const trOpts = `<option value="">${esc(t("lang.translateOff"))}</option>` +
      targets.map((l) => `<option value="${l.code}"${l.code === state.tr ? " selected" : ""}>${esc(lname(l.code))}</option>`).join("");
    ["#ui-lang", "#ui-lang-2"].forEach((s) => { const el = $(s); if (el) el.innerHTML = uiOpts; });
    ["#tr-lang", "#tr-lang-2"].forEach((s) => { const el = $(s); if (el) el.innerHTML = trOpts; });
    const cur = state.locales.find((l) => l.code === state.ui);
    $("#lang-btn-label").textContent = cur ? cur.name : state.ui;
  }

  async function setUiLang(code) {
    state.ui = code;
    try { localStorage.setItem("wb-ui-lang", code); } catch (e) {}
    await loadLocale(code);
    applyStatic();
    rebuildDynamicOptions();
    fillLanguageSelects();
    renderTimer(); renderStats(); renderList();
    if (state.detail) renderDetail();
    if (map) {
      map.attributionControl.removeAttribution(mapAttribution);
      mapAttribution = t("map.attribution");
      map.attributionControl.addAttribution(mapAttribution);
      drawMap();
    }
    if (state.view === "sources") renderSources();
    if (state.view === "languages") renderLanguages();
  }

  async function setTrLang(code) {
    state.tr = code || "";
    try { localStorage.setItem("wb-tr-lang", state.tr); } catch (e) {}
    TRCACHE.clear();
    fillLanguageSelects();
    renderList();
    translateList();
    if (state.selected) select(state.selected);
    if (state.view === "map") loadMap();
    if (state.view === "sources") loadSources();
    if (state.view === "languages") loadLanguages();
  }

  function rebuildDynamicOptions() {
    const catOpts = state.categories.map((c) => `<option value="${c.id}">${esc(catLabel(c.id))}</option>`).join("");
    const mk = (sel, first, opts, value) => {
      const el = $(sel);
      el.innerHTML = `<option value="">${esc(first)}</option>` + opts;
      el.value = value || "";
    };
    mk("#f-category", t("filter.allTopics"), catOpts, state.filters.category);
    mk("#m-category", t("filter.allTopics"), catOpts, $("#m-category")?.dataset.value);
    mk("#f-region", t("filter.allRegions"),
      ["Europe", "Asia", "Africa", "Americas", "Oceania"].map((r) => `<option value="${r}">${esc(regionLabel(r))}</option>`).join(""), state.filters.region);
    mk("#f-country", t("filter.anyCountry"),
      state.countries.map((c) => ({ code: c.code, name: cname(c.code) })).sort((a, b) => a.name.localeCompare(b.name, i18n.code))
        .map((c) => `<option value="${c.code}">${esc(c.name)}</option>`).join(""), state.filters.country);
    const hours = [["", "filter.hours48"], ["6", "filter.hours6"], ["12", "filter.hours12"], ["24", "filter.hours24"]];
    ["#f-hours", "#m-hours"].forEach((sel) => {
      const el = $(sel), v = el.value;
      el.innerHTML = hours.map(([val, key]) => `<option value="${val}">${esc(t(key))}</option>`).join("");
      el.value = v;
    });
  }

  // ================================================================================================
  // views & wiring
  // ================================================================================================
  function showView(v) {
    state.view = v;
    $$(".tab").forEach((t2) => t2.classList.toggle("active", t2.dataset.view === v));
    $$(".view").forEach((s) => (s.hidden = s.id !== `view-${v}`));
    if (v === "map") { loadMap().then(() => map.invalidateSize()); }
    if (v === "sources") loadSources();
    if (v === "languages") loadLanguages();
  }

  function wireLangMenu() {
    const btn = $("#lang-btn"), menu = $("#lang-menu");
    const close = () => { menu.hidden = true; btn.setAttribute("aria-expanded", "false"); };
    btn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      menu.hidden = !menu.hidden;
      btn.setAttribute("aria-expanded", String(!menu.hidden));
    });
    document.addEventListener("click", (ev) => { if (!menu.hidden && !menu.contains(ev.target)) close(); });
    document.addEventListener("keydown", (ev) => { if (ev.key === "Escape") close(); });
    $("#ui-lang").addEventListener("change", (ev) => setUiLang(ev.target.value));
    $("#tr-lang").addEventListener("change", (ev) => setTrLang(ev.target.value));
    $("#lm-manage").addEventListener("click", () => { close(); showView("languages"); });
  }

  async function init() {
    // --- interface language: what was chosen last, else what the browser asks for
    let stored = null, storedTr = null;
    try { stored = localStorage.getItem("wb-ui-lang"); storedTr = localStorage.getItem("wb-tr-lang"); } catch (e) {}
    let localeInfo = { default: "en", locales: [{ code: "en", name: "English", english_name: "English", dir: "ltr", complete: 100 }] };
    try { localeInfo = await api("/api/i18n/locales"); } catch (e) {}
    state.locales = localeInfo.locales;
    const have = new Set(state.locales.map((l) => l.code));
    const fromBrowser = (navigator.languages || [navigator.language || "en"])
      .map((x) => String(x).toLowerCase())
      .flatMap((x) => [x, x.split("-")[0]])
      .find((x) => have.has(x));
    state.ui = (stored && have.has(stored) && stored) || fromBrowser || localeInfo.default || "en";
    state.tr = storedTr || "";
    await loadLocale(state.ui);
    applyStatic();

    loadTimer(); renderTimer();
    $("#timer-toggle").addEventListener("click", toggleTimer);
    $$(".tab").forEach((tb) => tb.addEventListener("click", () => showView(tb.dataset.view)));

    const [cats, countries] = await Promise.all([api("/api/categories"), api("/api/countries")]);
    state.categories = cats; state.countries = countries;
    cats.forEach((c) => (state.catLabel[c.id] = c.label));
    countries.forEach((c) => (state.countryName[c.code] = c.name));
    rebuildDynamicOptions();

    try { state.trStatus = await api("/api/translate/status"); } catch (e) {}
    fillLanguageSelects();
    wireLangMenu();

    $$("#mode button").forEach((b) => b.addEventListener("click", () => { state.mode = b.dataset.mode; $$("#mode button").forEach((x) => x.classList.toggle("active", x === b)); loadEvents(); }));
    const bind = (id, key) => $(id).addEventListener("input", () => { state.filters[key] = $(id).value; loadEvents(); });
    bind("#f-category", "category"); bind("#f-region", "region"); bind("#f-country", "country"); bind("#f-hours", "hours");
    let qt; $("#f-q").addEventListener("input", () => { clearTimeout(qt); qt = setTimeout(() => { state.filters.q = $("#f-q").value; loadEvents(); }, 250); });
    $$("#map-layers button").forEach((b) => b.addEventListener("click", () => { layerOn[b.dataset.layer] = !layerOn[b.dataset.layer]; b.classList.toggle("active", layerOn[b.dataset.layer]); drawMap(); }));
    $("#m-category").addEventListener("change", (ev) => { ev.target.dataset.value = ev.target.value; loadMap(); });
    $("#m-hours").addEventListener("change", loadMap); $("#m-single").addEventListener("change", loadMap);
    $("#m-rel").addEventListener("input", () => { $("#m-rel-v").textContent = $("#m-rel").value; }); $("#m-rel").addEventListener("change", loadMap);
    $("#s-q").addEventListener("input", renderSources); $("#s-failing").addEventListener("change", renderSources);
    document.addEventListener("keydown", (ev) => {
      if (state.view !== "brief" || ev.target.tagName === "INPUT" || ev.target.tagName === "SELECT") return;
      if (ev.key === "j" || ev.key === "k") {
        const ids = state.events.map((e) => e.id); let i = ids.indexOf(state.selected); i = ev.key === "j" ? Math.min(ids.length - 1, i + 1) : Math.max(0, i - 1);
        if (ids[i]) { select(ids[i]); $(`.card[data-id="${ids[i]}"]`)?.scrollIntoView({ block: "nearest" }); }
      }
    });
    await loadEvents();
    pollStatus();
  }
  init();
})();
