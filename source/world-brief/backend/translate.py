"""Local machine translation.

Runs open-source Argos/OpenNMT models with CTranslate2 + SentencePiece, entirely on this machine:
no API key, no external AI service, no text ever leaves the computer. Language packages
(`.argosmodel`, CC0/MIT, from the Argos package index) are downloaded once on request and then work
offline forever.

Layers, in order of preference:
  1. a directly installed <from>-<to> model;
  2. a pivot through English (<from>-en, then en-<to>) when no direct model exists;
  3. a self-hosted LibreTranslate instance, if the user configured NEWS_TRANSLATE_ENDPOINT;
  4. nothing — the original text is returned, tagged so the interface can say why.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import shutil
import threading
import time
import unicodedata
import zipfile
from collections import OrderedDict
from pathlib import Path

import httpx

from . import config, store

log = logging.getLogger("translate")

# -------------------------------------------------------------------------------------------------
# Language codes
#
# Feeds label themselves with all sorts of tags ("pt-BR", "nb", "zh-Hant", "iw"). Argos packages use
# a small set of plain codes, with two private extensions: `pb` = Brazilian Portuguese and
# `zt` = Traditional Chinese.
ALIASES = {
    "iw": "he", "in": "id", "ji": "yi", "jw": "jv", "mo": "ro", "sh": "sr", "tw": "ak",
    "no": "nb", "nn": "nb", "nb-no": "nb", "nn-no": "nb",
    "zh-cn": "zh", "zh-hans": "zh", "zh-sg": "zh", "zh-tw": "zt", "zh-hant": "zt", "zh-hk": "zt", "zh-mo": "zt",
    "pt-br": "pb", "pt-pt": "pt",
    "pb": "pb", "zt": "zt",
}

def norm(code: str | None) -> str:
    """Normalise a feed/browser language tag to the code the models use."""
    if not code:
        return ""
    c = str(code).strip().lower().replace("_", "-")
    if c in ALIASES:
        return ALIASES[c]
    base = c.split("-")[0]
    return ALIASES.get(base, base)

# Endonyms: a language menu should show each language the way its own readers write it.
LANGUAGE_NAMES = {
    "af": "Afrikaans", "ak": "Akan", "am": "አማርኛ", "ar": "العربية", "az": "Azərbaycanca", "be": "Беларуская",
    "bg": "Български", "bn": "বাংলা", "bs": "Bosanski", "ca": "Català", "cs": "Čeština", "cy": "Cymraeg",
    "da": "Dansk", "de": "Deutsch", "el": "Ελληνικά", "en": "English", "eo": "Esperanto", "es": "Español",
    "et": "Eesti", "eu": "Euskara", "fa": "فارسی", "fi": "Suomi", "fr": "Français", "ga": "Gaeilge",
    "gl": "Galego", "he": "עברית", "hi": "हिन्दी", "hr": "Hrvatski", "hu": "Magyar", "hy": "Հայերեն",
    "id": "Bahasa Indonesia", "is": "Íslenska", "it": "Italiano", "ja": "日本語", "ka": "ქართული",
    "kk": "Қазақша", "km": "ខ្មែរ", "ko": "한국어", "ky": "Кыргызча", "lt": "Lietuvių", "lv": "Latviešu",
    "mk": "Македонски", "ms": "Bahasa Melayu", "mt": "Malti", "my": "မြန်မာ", "nb": "Norsk", "ne": "नेपाली",
    "nl": "Nederlands", "pb": "Português (Brasil)", "pl": "Polski", "pt": "Português", "ro": "Română",
    "ru": "Русский", "sk": "Slovenčina", "sl": "Slovenščina", "sq": "Shqip", "sr": "Српски", "sv": "Svenska",
    "sw": "Kiswahili", "ta": "தமிழ்", "te": "తెలుగు", "th": "ไทย", "tl": "Tagalog", "tr": "Türkçe",
    "uk": "Українська", "ur": "اردو", "vi": "Tiếng Việt", "zh": "中文 (简体)", "zt": "中文 (繁體)",
}
ENGLISH_NAMES = {
    "af": "Afrikaans", "ak": "Akan", "am": "Amharic", "ar": "Arabic", "az": "Azerbaijani", "be": "Belarusian",
    "bg": "Bulgarian", "bn": "Bengali", "bs": "Bosnian", "ca": "Catalan", "cs": "Czech", "cy": "Welsh",
    "da": "Danish", "de": "German", "el": "Greek", "en": "English", "eo": "Esperanto", "es": "Spanish",
    "et": "Estonian", "eu": "Basque", "fa": "Persian", "fi": "Finnish", "fr": "French", "ga": "Irish",
    "gl": "Galician", "he": "Hebrew", "hi": "Hindi", "hr": "Croatian", "hu": "Hungarian", "hy": "Armenian",
    "id": "Indonesian", "is": "Icelandic", "it": "Italian", "ja": "Japanese", "ka": "Georgian",
    "kk": "Kazakh", "km": "Khmer", "ko": "Korean", "ky": "Kyrgyz", "lt": "Lithuanian", "lv": "Latvian",
    "mk": "Macedonian", "ms": "Malay", "mt": "Maltese", "my": "Burmese", "nb": "Norwegian", "ne": "Nepali",
    "nl": "Dutch", "pb": "Portuguese (Brazil)", "pl": "Polish", "pt": "Portuguese", "ro": "Romanian",
    "ru": "Russian", "sk": "Slovak", "sl": "Slovenian", "sq": "Albanian", "sr": "Serbian", "sv": "Swedish",
    "sw": "Swahili", "ta": "Tamil", "te": "Telugu", "th": "Thai", "tl": "Tagalog", "tr": "Turkish",
    "uk": "Ukrainian", "ur": "Urdu", "vi": "Vietnamese", "zh": "Chinese (Simplified)", "zt": "Chinese (Traditional)",
}
RTL = {"ar", "fa", "he", "ur", "yi", "ps", "sd", "dv"}

def language_name(code: str) -> str:
    c = norm(code)
    return LANGUAGE_NAMES.get(c, ENGLISH_NAMES.get(c, code or ""))

def language_info(code: str) -> dict:
    c = norm(code)
    return {"code": c, "name": LANGUAGE_NAMES.get(c, c), "english_name": ENGLISH_NAMES.get(c, c),
            "dir": "rtl" if c in RTL else "ltr"}

# -------------------------------------------------------------------------------------------------
# Language detection: only a fallback. Articles normally carry the language of the feed that
# published them; this catches the ones that do not, and anything typed into the search box.
_SCRIPTS = [
    ("ko", re.compile(r"[가-힯ᄀ-ᇿ]")),
    ("ja", re.compile(r"[぀-ゟ゠-ヿ]")),
    ("th", re.compile(r"[฀-๿]")),
    ("el", re.compile(r"[Ͱ-Ͽἀ-῿]")),
    ("he", re.compile(r"[֐-׿]")),
    ("hy", re.compile(r"[԰-֏]")),
    ("ka", re.compile(r"[Ⴀ-ჿ]")),
    ("am", re.compile(r"[ሀ-፿]")),
    ("hi", re.compile(r"[ऀ-ॿ]")),
    ("bn", re.compile(r"[ঀ-৿]")),
    ("ta", re.compile(r"[஀-௿]")),
    ("te", re.compile(r"[ఀ-౿]")),
    ("km", re.compile(r"[ក-៿]")),
    ("my", re.compile(r"[က-႟]")),
    ("zh", re.compile(r"[一-鿿㐀-䶿]")),
]
_ARABIC = re.compile(r"[؀-ۿ]")
_CYRILLIC = re.compile(r"[Ѐ-ӿ]")
# Function words that separate languages sharing a script. A word shared by many languages ("de",
# "en", "la") says almost nothing, so every word is weighted by how few languages use it.
_MARKERS = {
    "ru": "и в не что это как для был была были они него его при или также ещё уже сообщает заявил россии году который которая которые после между собой очень однако",
    "uk": "і в не що це як для був була були вони його при або також вже заявив україни року який яка які після між дуже проте та до на",
    "bg": "и в не което това как за беше бяха те него при или също вече съобщава заяви българия година който която които след между много обаче",
    "sr": "и у не што ово како за био била били они његов при или такође већ саопштио изјавио србије године који која које после између врло међутим",
    "mk": "и во не што ова како за беше биле тие неговиот при или исто така веќе изјави македонија година кој која кои по меѓу многу меѓутоа",
    "be": "і ў не што гэта як для быў была былі яны яго пры або таксама ўжо заявіў беларусі года які якая якія пасля паміж вельмі аднак",
    "kk": "және бұл үшін болды олар оның немесе сондай-ақ қазақстан мәлімдеді жылы кейін арасында өте алайда деп бар",
    "ky": "жана бул үчүн болду алар анын же ошондой эле кыргызстан билдирди жылы кийин ортосунда абдан бирок деп бар",
    "fa": "این که برای است شده های کرد می را با از در بود خود ایران گفت نیز باید پس اما هم دیگر شود کند",
    "ur": "کیا اور میں سے کو ہے ہیں نے پر کہ گیا پاکستان کہا بھی تھا تھی کے لیے ایک جو اس ان",
    "ar": "في من على أن إلى عن التي الذي هذا هذه مع بعد قال وقد كما لكن حيث خلال كان كانت أيضا الى ان",
    "he": "של את לא הוא היא זה עם על כי גם אבל אשר היה היתה אחרי בין מאוד אולם כך כאשר",
    "es": "que por con para los las una del al como pero más sobre entre este esta sus ha han fue era son está están donde también según hasta ello cuando muy ya sin",
    "pt": "que para com não uma dos das por mais são foi ser pelo pela até onde também segundo quando muito já sem seu sua isso está estão ainda",
    "it": "che per con non una del della dei delle sono stato più anche dopo tra come questo questa gli negli nella alla dalla secondo quando molto già senza",
    "fr": "que les des une dans pour avec pas sur est ont été plus par aux selon après cette leur nous vous mais qui aussi été très sans entre lors depuis ainsi dont",
    "ca": "que els les una amb per no ha del dels més també després entre aquest aquesta seva seu però quan molt sense segons fins",
    "gl": "que os as unha con non máis tamén despois entre este pola polo seu súa pero cando moito sen segundo ata",
    "ro": "care din pentru este sunt nu mai după între acest această fost să şi său sa dar când foarte fără potrivit până cu pe",
    "de": "der die das und ist für mit nicht auch noch nach über werden wurde sich eine einen dem den des aber wenn oder bei sind war hat haben sein seine ihre",
    "nl": "het een van en is voor met niet ook nog naar over werd worden zijn maar dat deze die als door bij uit heeft hebben was waren volgens",
    "af": "die en is vir met nie ook nog na oor word wees maar dat hulle het se van om te sal was",
    "sv": "och att det som för med inte har den till av men om enligt efter har blev vara sig detta denna där när mycket utan",
    "da": "og at det som for med ikke har den til af men om efter ifølge blev være sig dette denne der når meget uden",
    "nb": "og at det som for med ikke har den til av men om etter ifølge ble være seg dette denne der når mye uten",
    "is": "og að það sem fyrir með ekki hefur til af en um eftir segir var voru sig þetta þessi þar þegar mjög án",
    "fi": "ja on ei että se mutta kun sekä myös jälkeen mukaan hän ovat oli olivat sen tämä nämä siitä hyvin ilman",
    "et": "ja on ei et see kuid kui ning ka pärast järgi ta olid oli selle need sellest väga ilma",
    "lv": "un ir nav ka tas bet kad arī pēc viņš bija tika par no ar šis šī ļoti bez kurš kura",
    "lt": "ir yra nėra kad tai bet kai taip pat po jis buvo apie su šis ši labai be kuris kuri",
    "pl": "że nie jest oraz przez dla tego który która które będzie zostało bardzo także jak się na do we przy oraz jego ich już",
    "cs": "že není je pro podle který která které byl byla bylo také velmi však se na do ve při jeho jejich již ale",
    "sk": "že nie je pre podľa ktorý ktorá ktoré bol bola bolo tiež veľmi však sa na do vo pri jeho ich už ale",
    "sl": "da ni je za po kateri katera katero bil bila bilo tudi zelo vendar se na do ve pri njegov njihov že ampak",
    "hr": "da nije je za prema koji koja koje bio bila bilo također vrlo ali se na do te pri njegov njihov već",
    "bs": "da nije je za prema koji koja koje bio bila bilo takođe vrlo ali se na do te pri njegov njihov već",
    "hu": "hogy nem az egy meg volt lesz szerint után között ezt már csak és de ha mint van vannak nagyon ezek",
    "tr": "ve bir bu için ile olarak olan daha sonra ancak ise dedi göre olduğu çok da de ki kadar bütün",
    "az": "və bir bu üçün ilə olaraq olan daha sonra ancaq isə dedi görə olduğu çox da də ki qədər bütün",
    "sq": "dhe një për me nga që janë është pas sipas por edhe duke tek shumë pa kur ky kjo",
    "vi": "và của các cho với không được người này những đã là trong sau theo rất khi nhưng cũng đến",
    "id": "dan yang untuk dengan tidak akan dari pada ini itu adalah telah oleh setelah menurut sangat ketika tetapi juga ke",
    "ms": "dan yang untuk dengan tidak akan dari pada ini itu adalah telah oleh selepas menurut sangat ketika tetapi juga ke",
    "tl": "ang mga sa ng na at ay para hindi ito niya kanya rin din pati upang kung dahil",
    "sw": "na ya wa kwa katika hiyo huo alisema kuwa ili baada kwamba lakini pia hata hivyo",
    "eu": "eta bat du dira zen ziren baina ere buruz arabera bere hau horiek oso gabe",
    "en": "the and for with that from this have has been will not are was said after about their which were would could they",
}
_MARKER_SETS = {k: set(v.split()) for k, v in _MARKERS.items()}
_MARKER_WEIGHT = {}
for _c, _ws in _MARKER_SETS.items():
    for _w in _ws:
        _MARKER_WEIGHT[_w] = _MARKER_WEIGHT.get(_w, 0) + 1
_MARKER_WEIGHT = {w: 1.0 / n for w, n in _MARKER_WEIGHT.items()}
_CYRILLIC_LANGS = ("ru", "uk", "bg", "sr", "mk", "be", "kk", "ky")
_ARABIC_LANGS = ("ar", "fa", "ur")

# Letters only a few languages use. A single "ł" or "ї" settles a question that a dozen function
# words cannot, which matters for headlines: they are short and mostly proper nouns. Only letters
# close to unique are listed; a shared accent is worse evidence than none.
_CHAR_HINTS = {
    "pl": "łńśżźęą", "cs": "ěřůďťň", "sk": "ľĺŕô", "hu": "őű", "ro": "șțăâ", "tr": "ğış",
    "az": "ə", "sq": "ë", "hr": "đć", "bs": "đć", "is": "þð", "et": "õ", "lv": "āēīūģķļņ",
    "lt": "ųėįą", "de": "ß", "es": "ñ¿¡", "pt": "ãõ", "ca": "·ï", "vi": "ơư", "fr": "œ",
    "da": "øæ", "nb": "øæ", "sv": "å",
}
_CHAR_HINTS = {k: set(v) for k, v in _CHAR_HINTS.items()}
_EMPTY: set = set()
_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)

# Cyrillic is a script, not a language: eight corpus languages share it. Their alphabets differ by a
# handful of letters, and that is the most reliable signal a headline offers.
_CYR_MARKS = (
    ("uk", set("їєґ")), ("be", set("ў")), ("mk", set("ѓќѕ")), ("sr", set("ђћџ")),
    ("kk", set("әғқңұһ")), ("ky", set("өүң")), ("ru", set("ыэё")),
)
_ARABIC_MARKS = (("fa", set("پچژگ")), ("ur", set("ٹڈڑںے")))

def _detect_cyrillic(sample: str) -> str:
    low = sample.lower()
    for code, marks in _CYR_MARKS:
        if any(ch in low for ch in marks):
            return code
    if any(ch in low for ch in "љњ"):       # Serbian and Macedonian share these; the marks above split them
        return "sr"
    letters = sum(1 for ch in low if ch.isalpha()) or 1
    if low.count("і") / letters > 0.005:
        return "uk"
    if low.count("ъ") / letters > 0.008:
        # Bulgarian writes ъ as an ordinary vowel; Russian uses it as a rare hard sign, so a single
        # "объявил" in a short headline is not enough. Let the function words decide.
        seen = {w.lower() for w in _WORD_RE.findall(low)}
        bg = sum(_MARKER_WEIGHT[w] for w in seen if w in _MARKER_SETS["bg"])
        ru = sum(_MARKER_WEIGHT[w] for w in seen if w in _MARKER_SETS["ru"])
        return "bg" if bg >= ru else "ru"
    return "ru"

def detect(text: str, default: str = "en") -> str:
    """Best-effort language guess: script first, then alphabet, then function-word overlap.

    Only a fallback — articles normally carry the language of the feed that published them. When the
    evidence is thin it says so by returning `default` rather than guessing and mistranslating.
    """
    if not text or not text.strip():
        return default
    sample = text[:600]
    for code, rx in _SCRIPTS:
        if len(rx.findall(sample)) >= 2:
            return code
    if _CYRILLIC.search(sample):
        return _detect_cyrillic(sample)
    if _ARABIC.search(sample):
        low = sample.lower()
        for code, marks in _ARABIC_MARKS:
            if any(ch in low for ch in marks):
                return code
        return "ar"
    words = [w.lower() for w in _WORD_RE.findall(sample)]
    if not words:
        return default
    pool = tuple(k for k in _MARKER_SETS if k not in _CYRILLIC_LANGS + _ARABIC_LANGS + ("he",))
    seen, chars = set(words), set(sample.lower())
    scores = {}
    for c in pool:
        sc = sum(_MARKER_WEIGHT[w] for w in seen if w in _MARKER_SETS[c])
        sc += 1.1 * len(chars & _CHAR_HINTS.get(c, _EMPTY))
        scores[c] = sc
    best = max(scores, key=lambda c: scores[c])
    return best if scores[best] >= 0.5 else default


# -------------------------------------------------------------------------------------------------
# Splitting text into translation units. Neural models degrade badly past a few dozen words, so a
# paragraph is translated sentence by sentence and reassembled.
_SENT_END = re.compile(r"(?<=[.!?。！？؟۔…])[\s　]+")
_HARD_WRAP = re.compile(r"[,;:、，；]\s+")
MAX_UNIT = 320   # characters

def split_units(text: str):
    """Return [(unit, separator)] so the translated units can be glued back together."""
    text = (text or "").strip()
    if not text:
        return []
    raw = [p for p in re.split(r"\n{1,}", text) if p.strip()]
    units = []
    for para in raw:
        parts = _SENT_END.split(para.strip())
        for p in parts:
            p = p.strip()
            if not p:
                continue
            while len(p) > MAX_UNIT:
                cut = None
                for m in _HARD_WRAP.finditer(p[:MAX_UNIT]):
                    cut = m.end()
                if cut is None:
                    cut = p.rfind(" ", 0, MAX_UNIT)
                if cut is None or cut <= 0:
                    cut = MAX_UNIT
                units.append(p[:cut].strip())
                p = p[cut:].strip()
            if p:
                units.append(p)
        units.append("\n")
    if units and units[-1] == "\n":
        units.pop()
    return units

def join_units(units):
    out = ""
    for u in units:
        if u == "\n":
            out = out.rstrip() + "\n"
        else:
            if out and not out.endswith(("\n", " ")):
                out += " "
            out += u
    return out.strip()

# -------------------------------------------------------------------------------------------------
# Package index

BUNDLED_INDEX_LANGS = [
    "ar", "az", "bg", "bn", "ca", "cs", "da", "de", "el", "eo", "es", "et", "eu", "fa", "fi", "fr",
    "ga", "gl", "he", "hi", "hu", "id", "it", "ja", "ko", "ky", "lt", "lv", "ms", "nb", "nl", "pb",
    "pl", "pt", "ro", "ru", "sk", "sl", "sq", "sv", "sw", "th", "tl", "tr", "uk", "ur", "vi", "zh", "zt",
]

def _bundled_index():
    """Used when the package index cannot be fetched: every language above pairs with English."""
    out = []
    for c in BUNDLED_INDEX_LANGS:
        for a, b in ((c, "en"), ("en", c)):
            out.append({"from_code": a, "to_code": b, "package_version": "1.9",
                        "links": [f"https://argos-net.com/v1/translate-{a}_{b}-1_9.argosmodel"],
                        "code": f"translate-{a}_{b}"})
    return out

class PackageIndex:
    """The catalogue of downloadable language packages, cached on disk."""

    def __init__(self):
        self.path = config.TRANSLATE_DIR / "index.json"
        self._items = None
        self._lock = threading.Lock()

    def items(self, refresh=False):
        with self._lock:
            if self._items is not None and not refresh:
                return self._items
            data = None
            if not refresh:
                try:
                    data = json.loads(self.path.read_text())
                except Exception:  # noqa: BLE001
                    data = None
            if data is None:
                data = self._fetch()
            self._items = data or _bundled_index()
            return self._items

    def _fetch(self):
        try:
            r = httpx.get(config.TRANSLATE_INDEX_URL, timeout=20,
                          headers={"user-agent": config.USER_AGENT}, follow_redirects=True)
            r.raise_for_status()
            data = r.json()
            if isinstance(data, list) and data:
                self.path.write_text(json.dumps(data))
                log.info("translation package index: %d packages", len(data))
                return data
        except Exception as ex:  # noqa: BLE001
            log.warning("could not fetch translation package index (%s); using the bundled list", ex)
        return None

    def find(self, from_code, to_code):
        for p in self.items():
            if p.get("from_code") == from_code and p.get("to_code") == to_code:
                return p
        return None

INDEX = PackageIndex()

# -------------------------------------------------------------------------------------------------

def _pkg_dir(from_code, to_code) -> Path:
    return config.TRANSLATE_DIR / f"{from_code}-{to_code}"

def _dir_size(p: Path) -> int:
    try:
        return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    except OSError:
        return 0

class Engine:
    """Loads, runs and manages the local translation models."""

    def __init__(self):
        self._models = OrderedDict()        # (from,to) -> (Translator, SentencePieceProcessor)
        self._model_lock = threading.Lock()
        self._run_lock = threading.Lock()   # CTranslate2 is fast; one batch at a time keeps RAM flat
        self.downloads = {}                 # "fr-en" -> {state, pct, bytes, total, error}
        self._dl_lock = threading.Lock()
        self._backend_error = None
        self._mem = OrderedDict()           # small hot cache in front of SQLite
        self._mem_lock = threading.Lock()

    # ---- backend availability -------------------------------------------------------------
    def _ct2(self):
        try:
            import ctranslate2  # noqa: PLC0415
            import sentencepiece  # noqa: PLC0415
            return ctranslate2, sentencepiece
        except Exception as ex:  # noqa: BLE001
            self._backend_error = str(ex)
            return None, None

    @property
    def local_available(self) -> bool:
        return self._ct2()[0] is not None

    # ---- installed packages ---------------------------------------------------------------
    def installed(self) -> dict:
        out = {}
        if not config.TRANSLATE_DIR.exists():
            return out
        for d in sorted(config.TRANSLATE_DIR.iterdir()):
            if not d.is_dir() or "-" not in d.name:
                continue
            if not (d / "model").is_dir() or not (d / "sentencepiece.model").exists():
                continue
            a, _, b = d.name.partition("-")
            out[(a, b)] = {"from": a, "to": b, "size": _dir_size(d), "path": str(d)}
        return out

    def route(self, from_code, to_code):
        """How (if at all) this pair can be translated: direct, pivot through English, or not."""
        f, t = norm(from_code), norm(to_code)
        if not f or not t or f == t:
            return ("same", [])
        inst = self.installed()
        if (f, t) in inst:
            return ("direct", [(f, t)])
        if f != "en" and t != "en" and (f, "en") in inst and ("en", t) in inst:
            return ("pivot", [(f, "en"), ("en", t)])
        if config.TRANSLATE_ENDPOINT:
            return ("endpoint", [])
        return ("missing", [])

    def missing_packages(self, from_code, to_code):
        """Which packages would have to be installed for this pair to work."""
        f, t = norm(from_code), norm(to_code)
        if not f or not t or f == t:
            return []
        inst = self.installed()
        if (f, t) in inst:
            return []
        if INDEX.find(f, t):
            return [(f, t)]
        need = []
        for pair in ((f, "en"), ("en", t)):
            if pair[0] != pair[1] and pair not in inst:
                need.append(pair)
        return need if all(INDEX.find(*p) for p in need) else []

    # ---- downloading ----------------------------------------------------------------------
    def install(self, from_code, to_code):
        f, t = norm(from_code), norm(to_code)
        key = f"{f}-{t}"
        pkg = INDEX.find(f, t)
        if not pkg:
            raise ValueError(f"no package available for {f} -> {t}")
        with self._dl_lock:
            cur = self.downloads.get(key)
            if cur and cur.get("state") in ("downloading", "installing"):
                return cur
            self.downloads[key] = {"from": f, "to": t, "state": "downloading", "pct": 0,
                                   "bytes": 0, "total": 0, "error": None, "started": time.time()}
        threading.Thread(target=self._install_worker, args=(f, t, pkg), daemon=True,
                         name=f"translate-install-{key}").start()
        return self.downloads[key]

    def _install_worker(self, f, t, pkg):
        key = f"{f}-{t}"
        prog = self.downloads[key]
        tmp = config.TRANSLATE_DIR / f".{key}.download"
        target = _pkg_dir(f, t)
        try:
            url = (pkg.get("links") or [None])[0]
            if not url:
                raise ValueError("package has no download link")
            with httpx.stream("GET", url, timeout=60, follow_redirects=True,
                              headers={"user-agent": config.USER_AGENT}) as r:
                r.raise_for_status()
                total = int(r.headers.get("content-length") or 0)
                prog["total"] = total
                got = 0
                with open(tmp, "wb") as fh:
                    for chunk in r.iter_bytes(1 << 18):
                        fh.write(chunk)
                        got += len(chunk)
                        prog["bytes"] = got
                        if total:
                            prog["pct"] = round(100 * got / total, 1)
            prog.update(state="installing", pct=100)
            staging = config.TRANSLATE_DIR / f".{key}.unpack"
            shutil.rmtree(staging, ignore_errors=True)
            with zipfile.ZipFile(tmp) as z:
                for member in z.namelist():
                    # Skip the bundled stanza sentence splitter: we split sentences ourselves, and it
                    # would pull in a deep-learning stack just to find full stops.
                    rel = member.split("/", 1)[1] if "/" in member else member
                    if not rel or rel.startswith("stanza/"):
                        continue
                    if member.endswith("/"):
                        continue
                    dest = staging / rel
                    if not str(dest.resolve()).startswith(str(staging.resolve())):
                        continue    # zip-slip guard
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(member) as src, open(dest, "wb") as out:
                        shutil.copyfileobj(src, out)
            if not (staging / "model").is_dir() or not (staging / "sentencepiece.model").exists():
                raise ValueError("package does not contain a CTranslate2 model")
            self.unload(f, t)
            shutil.rmtree(target, ignore_errors=True)
            staging.replace(target)
            prog.update(state="ready", pct=100, size=_dir_size(target))
            log.info("installed translation package %s (%.0f MB)", key, _dir_size(target) / 1e6)
        except Exception as ex:  # noqa: BLE001
            log.warning("translation package %s failed: %s", key, ex)
            prog.update(state="error", error=f"{type(ex).__name__}: {ex}")
        finally:
            tmp.unlink(missing_ok=True)
            shutil.rmtree(config.TRANSLATE_DIR / f".{key}.unpack", ignore_errors=True)

    def unload(self, from_code, to_code):
        with self._model_lock:
            self._models.pop((norm(from_code), norm(to_code)), None)

    def remove(self, from_code, to_code):
        f, t = norm(from_code), norm(to_code)
        self.unload(f, t)
        shutil.rmtree(_pkg_dir(f, t), ignore_errors=True)
        with self._dl_lock:
            self.downloads.pop(f"{f}-{t}", None)
        return True

    # ---- model loading --------------------------------------------------------------------
    def _model(self, f, t):
        with self._model_lock:
            m = self._models.get((f, t))
            if m is not None:
                self._models.move_to_end((f, t))
                return m
        ct2, spm = self._ct2()
        if ct2 is None:
            return None
        d = _pkg_dir(f, t)
        if not (d / "model").is_dir():
            return None
        t0 = time.time()
        translator = ct2.Translator(str(d / "model"), device="cpu", compute_type="int8",
                                    inter_threads=1, intra_threads=max(1, config.TRANSLATE_THREADS))
        sp = spm.SentencePieceProcessor(model_file=str(d / "sentencepiece.model"))
        log.info("loaded translation model %s-%s in %.2fs", f, t, time.time() - t0)
        with self._model_lock:
            self._models[(f, t)] = (translator, sp)
            self._models.move_to_end((f, t))
            while len(self._models) > max(1, config.TRANSLATE_MODELS_IN_MEMORY):
                self._models.popitem(last=False)
        return (translator, sp)

    def _run_hop(self, texts, f, t):
        """Translate a list of already-short units through one model."""
        m = self._model(f, t)
        if m is None:
            return None
        translator, sp = m
        with self._run_lock:
            tokens = [sp.encode(x, out_type=str) for x in texts]
            results = translator.translate_batch(
                tokens, beam_size=max(1, config.TRANSLATE_BEAM), max_batch_size=24,
                max_decoding_length=512, replace_unknowns=True)
        out = []
        for r in results:
            pieces = r.hypotheses[0] if r.hypotheses else []
            out.append("".join(pieces).replace("▁", " ").strip())
        return out

    # ---- the public entry point ------------------------------------------------------------
    def translate(self, texts, to_code, from_code=None):
        """Translate a list of strings into `to_code`.

        Returns a list of {text, source_lang, translated, engine} in the same order. Anything that
        cannot be translated comes back with the original text and translated=False, so the
        interface can show the original and say why.
        """
        target = norm(to_code)
        results = [{"text": (x or ""), "source_lang": norm(from_code) or "", "translated": False,
                    "engine": None} for x in texts]
        if not target:
            return results
        # Group the work by source language, because each language uses a different model.
        groups = {}
        for i, x in enumerate(texts):
            s = (x or "").strip()
            if not s:
                continue
            if len(s) > config.TRANSLATE_MAX_CHARS:
                s = s[:config.TRANSLATE_MAX_CHARS]
            src = norm(from_code) or detect(s)
            results[i]["source_lang"] = src
            if src == target:
                continue
            groups.setdefault(src, []).append((i, s))

        for src, items in groups.items():
            keys = [_cache_key(src, target, s) for _, s in items]
            cached = store.get_translations(keys)
            todo = []
            for (i, s), k in zip(items, keys):
                hit = self._mem_get(k) or cached.get(k)
                if hit is not None:
                    results[i].update(text=hit, translated=True, engine="cache")
                    self._mem_put(k, hit)
                else:
                    todo.append((i, s, k))
            if not todo:
                continue
            kind, hops = self.route(src, target)
            if kind == "same":
                continue
            if kind == "missing":
                for i, _, _ in todo:
                    results[i]["engine"] = "unavailable"
                continue
            try:
                if kind == "endpoint":
                    outs = self._endpoint_translate([s for _, s, _ in todo], src, target)
                    engine = "libretranslate"
                else:
                    outs = self._translate_local([s for _, s, _ in todo], hops)
                    engine = "argos" + ("-pivot" if kind == "pivot" else "")
            except Exception as ex:  # noqa: BLE001
                log.warning("translation %s->%s failed: %s", src, target, ex)
                for i, _, _ in todo:
                    results[i]["engine"] = "error"
                continue
            if outs is None:
                for i, _, _ in todo:
                    results[i]["engine"] = "unavailable"
                continue
            rows = []
            for (i, s, k), o in zip(todo, outs):
                if not o:
                    results[i]["engine"] = "error"
                    continue
                results[i].update(text=o, translated=True, engine=engine)
                self._mem_put(k, o)
                rows.append((k, src, target, o, engine))
            store.put_translations(rows)
        return results

    def _translate_local(self, texts, hops):
        """Split every text into units, translate all units of all texts in one batch, reassemble."""
        spans, flat = [], []
        for s in texts:
            units = split_units(s)
            start = len(flat)
            flat.extend(units)
            spans.append((start, len(flat)))
        if not flat:
            return ["" for _ in texts]
        translatable = [i for i, u in enumerate(flat) if u != "\n"]
        payload = [flat[i] for i in translatable]
        for f, t in hops:
            out = self._run_hop(payload, f, t)
            if out is None:
                return None
            payload = out
        merged = list(flat)
        for i, o in zip(translatable, payload):
            merged[i] = o
        return [join_units(merged[a:b]) for a, b in spans]

    def _endpoint_translate(self, texts, src, target):
        """Optional: a LibreTranslate server the user runs themselves."""
        body = {"q": texts, "source": src, "target": target, "format": "text"}
        if config.TRANSLATE_ENDPOINT_KEY:
            body["api_key"] = config.TRANSLATE_ENDPOINT_KEY
        r = httpx.post(f"{config.TRANSLATE_ENDPOINT}/translate", json=body, timeout=60)
        r.raise_for_status()
        data = r.json().get("translatedText")
        if isinstance(data, str):
            return [data]
        return list(data or [])

    # ---- small in-process cache -------------------------------------------------------------
    def _mem_get(self, k):
        with self._mem_lock:
            v = self._mem.get(k)
            if v is not None:
                self._mem.move_to_end(k)
            return v

    def _mem_put(self, k, v):
        with self._mem_lock:
            self._mem[k] = v
            self._mem.move_to_end(k)
            while len(self._mem) > 20000:
                self._mem.popitem(last=False)

    # ---- status for the interface ------------------------------------------------------------
    def status(self):
        inst = self.installed()
        avail = {}
        for p in INDEX.items():
            f, t = p.get("from_code"), p.get("to_code")
            if not f or not t:
                continue
            avail[(f, t)] = p
        langs = sorted({c for pair in avail for c in pair})
        with self._dl_lock:
            downloads = {k: dict(v) for k, v in self.downloads.items()}
        return {
            "enabled": config.TRANSLATE_ENABLED,
            "engine": "argos-ctranslate2" if self.local_available else ("libretranslate" if config.TRANSLATE_ENDPOINT else None),
            "local_available": self.local_available,
            "backend_error": None if self.local_available else self._backend_error,
            "endpoint": config.TRANSLATE_ENDPOINT or None,
            "languages": [language_info(c) for c in langs],
            "packages": [
                {"from": f, "to": t,
                 "from_name": language_name(f), "to_name": language_name(t),
                 "from_english": ENGLISH_NAMES.get(f, f), "to_english": ENGLISH_NAMES.get(t, t),
                 "installed": (f, t) in inst,
                 "size": inst.get((f, t), {}).get("size", 0),
                 "download": downloads.get(f"{f}-{t}")}
                for (f, t) in sorted(avail)
            ],
            "installed_count": len(inst),
            "installed_bytes": sum(v["size"] for v in inst.values()),
            "downloads": downloads,
            "cache": store.translation_stats(),
        }

def _cache_key(src, dst, text):
    return hashlib.sha1(f"{src}|{dst}|{text}".encode()).hexdigest()

ENGINE = Engine()

# -------------------------------------------------------------------------------------------------
# Event translation: which parts of an event need translating, and how to put them back.

def translate_event(ev: dict, to_code: str, deep: bool = True) -> dict:
    """Return a copy of the event with its human-readable text translated into `to_code`.

    Only the fields a reader reads are touched; ids, codes, counts and outlet names are left alone.
    An outlet's name is its name in any language, and a URL must stay a URL.
    """
    target = norm(to_code)
    if not target or not config.TRANSLATE_ENABLED:
        return ev
    ev = json.loads(json.dumps(ev))     # never mutate the cached events.json
    default_lang = norm(ev.get("lang")) or (norm(ev["languages"][0]) if ev.get("languages") else "")
    jobs = []      # (setter, text, lang)

    def add(container, key, lang=None):
        val = container.get(key)
        if isinstance(val, str) and val.strip():
            jobs.append((container, key, val, norm(lang) or default_lang))

    add(ev, "title")
    for s in ev.get("summary") or []:
        add(s, "sentence", s.get("lang"))
    if deep:
        for s in ev.get("sides") or []:
            add(s, "headline", s.get("lang"))
            add(s, "extract", s.get("lang"))
        for x in ev.get("extracts") or []:
            add(x, "text", x.get("lang"))
        for a in ev.get("articles") or []:
            add(a, "title", a.get("lang"))
            add(a, "extract", a.get("lang"))
    by_lang = {}
    for idx, (_, _, text, lang) in enumerate(jobs):
        by_lang.setdefault(lang, []).append(idx)
    meta = {"target": target, "translated": 0, "untranslated": 0, "missing": []}
    for lang, idxs in by_lang.items():
        res = ENGINE.translate([jobs[i][2] for i in idxs], target, from_code=lang)
        for i, r in zip(idxs, res):
            container, key, original, _ = jobs[i]
            if r["translated"]:
                container[key] = r["text"]
                container.setdefault("_original", {})[key] = original
                meta["translated"] += 1
            elif r["engine"] == "unavailable" and lang and lang != target:
                meta["untranslated"] += 1
                if lang not in meta["missing"]:
                    meta["missing"].append(lang)
    ev["translation"] = meta
    return ev
