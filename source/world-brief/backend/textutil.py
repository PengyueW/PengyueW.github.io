"""Language-agnostic tokenisation, stopwords, sentence splitting and entity signatures."""
import re
import unicodedata

STOPWORDS = {
 "en": "a an the and or but if of to in on at by for with from as is are was were be been being this that these those it its he she they them his her their we you i our your not no yes do does did have has had will would can could should may might than then there here who whom which what when where why how also into over under after before about more most some any all such very just only up out so said says say new says's mr ms per amid".split(),
 "fr": "le la les un une des du de et ou mais si en dans sur au aux par pour avec sans ce cet cette ces il elle ils elles nous vous je tu on ne pas plus que qui quoi dont où est sont été être a ont avait après avant selon entre aussi son sa ses leur leurs mon ma mes notre nos votre vos y d l s n c j qu".split(),
 "es": "el la los las un una unos unas de del al a y o pero si en con por para sin sobre es son fue fueron ser está están este esta estos estas ese esa eso que quien como cuando donde más muy también ya no sí su sus mi mis tu tus nuestro nuestra lo le les se ha han había hay entre tras según".split(),
 "de": "der die das ein eine einer eines einem einen und oder aber wenn in im am an auf für mit von vom zu zum zur bei nach über unter ist sind war waren sein wird werden wurde hat haben hatte nicht kein keine auch noch nur schon sich es er sie wir ihr ich du dass als wie aus bis um den dem des".split(),
 "pt": "o a os as um uma uns umas de do da dos das e ou mas se em no na nos nas por para com sem sobre é são foi foram ser está estão este esta isto esse essa isso que quem como quando onde mais muito também já não sim seu sua seus suas ao aos à às há entre após segundo".split(),
 "it": "il lo la i gli le un uno una di del della dei delle e o ma se in nel nella nei nelle su sul sulla con per da dal dalla è sono era erano essere sta stanno questo questa questi queste che chi come quando dove più molto anche già non sì suo sua suoi sue al allo alla ai agli alle tra fra dopo secondo ha hanno".split(),
 "ru": "и в во не что он на я с со как а то все она так его но да ты к у же вы за бы по только ее мне было вот от меня еще нет о из ему теперь когда даже ну вдруг ли если уже или ни быть был него до вас нибудь опять уж вам ведь там потом себя ничего ей может они тут где есть надо ней для мы тебя их чем была сам чтоб без будто чего раз тоже себе под будет ж тогда кто этот того потому этого какой совсем ним здесь этом один почти мой тем чтобы нее сейчас были куда зачем всех никогда можно при наконец два об другой хоть после над больше тот через эти нас про всего них какая много разве три эту моя впрочем хорошо свою этой перед иногда лучше чуть том нельзя такой им более всегда конечно всю между заявил заявила сообщает сообщил".split(),
}
ALL_STOP = set()
for _v in STOPWORDS.values():
    ALL_STOP.update(_v)

PUNCT = "\u201c\u201d\"'\u2018\u2019(),;:!?[]\u00ab\u00bb\u2026"
TOKEN_RE = re.compile(r"[^\W\d_]{2,}|\d{2,}", re.UNICODE)
CJK_RE = re.compile(r"[぀-ヿ㐀-䶿一-鿿가-힯]")
SENT_RE = re.compile(r"(?<=[.!?。！？])\s+(?=[\"'“‘(\[]?[^\s])")

def strip_accents(s: str) -> str:
    return "".join(ch for ch in unicodedata.normalize("NFKD", s) if not unicodedata.combining(ch))

def tokenize(text: str, lang: str = "en"):
    if not text:
        return []
    if CJK_RE.search(text):
        # character bigrams for CJK scripts
        chars = [ch for ch in text if not ch.isspace()]
        toks = [chars[i] + chars[i + 1] for i in range(len(chars) - 1)]
        toks += TOKEN_RE.findall(text.lower())
        return toks
    low = strip_accents(text.lower())
    stop = set(STOPWORDS.get(lang.split("-")[0], STOPWORDS["en"])) | set(STOPWORDS["en"])
    return [t for t in TOKEN_RE.findall(low) if t not in stop]

RUNON_RE = re.compile(r"(?<=[a-z\)\]”\"])\s+(?=[A-Z][a-z]+\s)")
# A capitalised word after one of these is part of the same clause, not a new sentence.
GLUE_WORDS = set("""of in on at to for and or the a an with from by as that than into over under near across against
between including said says told after before during about amid despite while when where which who whose but so it's
its his her their our your my this these those new former late top chief president prime minister king queen""".split())

def _split_runon(p: str):
    """RSS descriptions often glue two sentences without a period; split long ones at the best boundary."""
    if len(p) <= 140 or "." in p[:-1]:
        return [p]
    cuts = []
    for m in RUNON_RE.finditer(p):
        prev = p[:m.start()].rstrip()
        prev_word = prev.rsplit(" ", 1)[-1].strip(PUNCT).lower() if prev else ""
        if prev_word in GLUE_WORDS or len(prev_word) < 2:
            continue
        cuts.append(m.start())
    if not cuts:
        return [p]
    mid = len(p) / 2
    c = min(cuts, key=lambda x: abs(x - mid))
    if c < 45 or len(p) - c < 45:
        return [p]
    return [p[:c].strip(), p[c:].strip()]

QUOTED_RE = re.compile(r"[\"“”'‘’«»]([^\"“”«»\n]{2,80})[\"“”'‘’«»]")

def strip_quoted(text: str) -> str:
    """Remove short quoted spans: they are usually titles of works, which otherwise trip topic keywords
    ("World War Z" -> war, "The Crown" -> politics)."""
    return QUOTED_RE.sub(" ", text or "")

def sentences(text: str):
    if not text:
        return []
    parts = SENT_RE.split(text.strip())
    out = []
    for p in parts:
        for q in _split_runon(p.strip()):
            if 25 <= len(q) <= 600:
                out.append(q)
    return out

ENTITY_RE = re.compile(r"(?<![.!?]\s)(?<!^)\b([A-ZÀ-Ý][\w'’-]{2,}(?:\s+[A-ZÀ-Ý][\w'’-]{2,}){0,2})\b")
NUM_RE = re.compile(r"\b\d{2,}(?:[.,]\d+)?\b")

def entity_signature(text: str):
    """Capitalised phrases (not sentence-initial) + numbers: a cheap cross-language 'who/what' fingerprint."""
    ents = set()
    for m in ENTITY_RE.finditer(text or ""):
        e = strip_accents(m.group(1).lower())
        if e not in ALL_STOP:
            ents.add(e)
    ents.update(NUM_RE.findall(text or ""))
    return ents

def word_count(text: str) -> int:
    return len((text or "").split())
