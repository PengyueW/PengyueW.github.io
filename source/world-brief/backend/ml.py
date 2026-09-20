"""Lightweight local models. No external AI services.

* TopicModel     – multi-label linear classifier over hashed word + char n-grams. Bootstrapped from
                   hand-written seed headlines plus weak keyword labels on the live corpus, then
                   retrained on every refresh (self-training). Thousands of articles/second on CPU.
* SalienceModel  – ridge regression predicting how widely a story will be covered (log #outlets) from
                   its text alone, trained on the app's own clustering results and on user feedback.
* Summarizer     – unsupervised extractive summariser (centroid + MMR) over an event's sentences.
* perspectives() – picks the most representative headline per side and measures framing divergence.
"""
import logging
import math
import os
import pickle
import time
import warnings

from joblib import Parallel, delayed

import numpy as np
from scipy.sparse import hstack, csr_matrix
from sklearn.feature_extraction.text import HashingVectorizer, TfidfVectorizer
from sklearn.linear_model import SGDClassifier, SGDRegressor
from sklearn.preprocessing import MultiLabelBinarizer

from . import config
from .classify import CATEGORY_IDS, SEED, article_hits
from .textutil import tokenize, sentences, strip_accents

log = logging.getLogger("ml")

def _word_analyzer(doc):
    toks = tokenize(doc, "en")
    return toks + [toks[i] + "_" + toks[i + 1] for i in range(len(toks) - 1)]

class Features:
    """Shared hashed feature space: word uni/bigrams on title+summary, character 3-5grams on the title only
    (script agnostic, catches morphology in languages the tokenizer does not know)."""
    def __init__(self):
        self.words = HashingVectorizer(analyzer=_word_analyzer, n_features=2 ** 18, alternate_sign=False, norm="l2", binary=True)
        self.chars = HashingVectorizer(analyzer="char_wb", ngram_range=(3, 5), n_features=2 ** 18, alternate_sign=False, norm="l2",
                                       preprocessor=lambda s: strip_accents(s.lower()))
    def transform(self, articles):
        """articles: list of article dicts (or plain strings, treated as titles)."""
        titles, bodies = [], []
        for a in articles:
            if isinstance(a, str):
                titles.append(a); bodies.append(a)
            else:
                t = a.get("title", "") or ""
                titles.append(t); bodies.append(f"{t} {t} {(a.get('summary') or '')[:400]}")
        return hstack([self.words.transform(bodies), 0.7 * self.chars.transform(titles)]).tocsr()

FEATURES = Features()

def article_text(a):
    return f"{a.get('title','')} {a.get('title','')} {a.get('summary','')}"

# ----------------------------------------------------------------------------------------------
class TopicModel:
    def __init__(self):
        self.clf = None
        self.mlb = MultiLabelBinarizer(classes=CATEGORY_IDS)
        self.trained_at = None
        self.n_train = 0

    def weak_labels(self, a):
        """Weak label = categories with >=2 rule hits, or >=1 hit inside the title."""
        h = article_hits(a)
        return sorted(c for c, n in h["all"].items() if n >= 2 or h["title"].get(c, 0) >= 1)

    def train(self, articles, X_all=None, max_samples=8000):
        """articles: full corpus; X_all: its precomputed feature matrix (rows aligned)."""
        if X_all is None:
            X_all = FEATURES.transform(articles)
        seed_texts, seed_labels = [], []
        for cat, seeds in SEED.items():
            for st in seeds:
                seed_texts.append(st); seed_labels.append([cat])
        rng = np.random.default_rng(0)
        idx = rng.permutation(len(articles))[:max_samples]
        labels = list(seed_labels) + [self.weak_labels(articles[i]) for i in idx]
        weights = [3.0] * len(seed_texts) + [1.0 if labels[len(seed_texts) + k] else 0.5 for k in range(len(idx))]
        from scipy.sparse import vstack
        X = vstack([FEATURES.transform(seed_texts), X_all[idx]]).tocsr()
        Y = self.mlb.fit_transform(labels)
        w = np.array(weights)
        t0 = time.time()
        def fit_one(j):
            y = Y[:, j]
            if y.sum() < 5:
                return None
            m = SGDClassifier(loss="log_loss", alpha=2e-5, max_iter=12, tol=1e-3, class_weight="balanced", random_state=0)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                m.fit(X, y, sample_weight=w)
            return m
        self.clf = Parallel(n_jobs=min(8, os.cpu_count() or 2))(delayed(fit_one)(j) for j in range(len(CATEGORY_IDS)))
        self.active = [m is not None for m in self.clf]
        self.trained_at = time.time()
        self.n_train = X.shape[0]
        log.info("topic model trained on %d samples, %d active classes, in %.1fs", X.shape[0], sum(self.active), time.time() - t0)

    def _proba(self, X):
        out = np.zeros((X.shape[0], len(CATEGORY_IDS)))
        for j, m in enumerate(self.clf):
            if m is not None:
                out[:, j] = m.predict_proba(X)[:, 1]
        return out

    def predict(self, articles, X_all=None):
        """Return list of {category: score in [0,1]} combining model probability and rule evidence."""
        if not articles:
            return []
        probs = None
        if self.clf:
            try:
                probs = self._proba(X_all if X_all is not None else FEATURES.transform(articles))
            except Exception as ex:  # noqa: BLE001
                log.warning("topic predict failed: %s", ex)
        out = []
        for i, a in enumerate(articles):
            scores = {}
            h = article_hits(a)
            hits, title_hits = h["all"], h["title"]
            for c, n in hits.items():
                scores[c] = min(1.0, 0.45 + 0.15 * n + 0.2 * title_hits.get(c, 0))
            if probs is not None:
                for j, c in enumerate(CATEGORY_IDS):
                    if not self.active[j]:
                        continue
                    p = float(probs[i, j])
                    if p >= config.TOPIC_MODEL_THRESHOLD:
                        scores[c] = max(scores.get(c, 0.0), p)
                    elif c in scores:
                        scores[c] = 0.5 * scores[c] + 0.5 * max(p, scores[c] * 0.6)
            out.append(scores)
        return out

# ----------------------------------------------------------------------------------------------
class SalienceModel:
    """Predicts log(1 + number of distinct outlets covering the story) from text alone."""
    def __init__(self):
        self.reg = None
        self.trained_at = None
        self.n_train = 0

    def train(self, articles, targets, feedback=None, X_all=None, max_samples=8000):
        if X_all is None:
            X_all = FEATURES.transform(articles)
        rng = np.random.default_rng(1)
        idx = rng.permutation(len(articles))[:max_samples]
        y = [float(targets[i]) for i in idx]
        w = [1.0] * len(idx)
        parts = [X_all[idx]]
        if feedback:
            from scipy.sparse import vstack
            parts.append(FEATURES.transform([fb["text"] for fb in feedback]))
            y += [3.5 if fb["label"] > 0 else 0.0 for fb in feedback]
            w += [6.0] * len(feedback)
            X = vstack(parts).tocsr()
        else:
            X = parts[0]
        if X.shape[0] < 50:
            return
        self.reg = SGDRegressor(alpha=1e-4, max_iter=30, tol=1e-4, random_state=0)
        self.reg.fit(X, np.array(y), sample_weight=np.array(w))
        self.trained_at = time.time()
        self.n_train = X.shape[0]

    def predict(self, articles, X_all=None):
        if self.reg is None or not articles:
            return [0.0] * len(articles)
        X = X_all if X_all is not None else FEATURES.transform(articles)
        return [max(0.0, float(v)) for v in self.reg.predict(X)]

# ----------------------------------------------------------------------------------------------
class Summarizer:
    def summarize(self, docs, k=3, lang="en"):
        """docs: list of (text, source_label). Returns list of {'sentence','source'} in reading order."""
        cands = []
        for di, (text, src) in enumerate(docs):
            for si, s in enumerate(sentences(text)):
                cands.append((s, src, di, si))
        if not cands:
            return []
        # de-duplicate near-identical sentences (common across wires)
        seen, uniq = set(), []
        for c in cands:
            key = strip_accents(c[0].lower())[:80]
            if key in seen:
                continue
            seen.add(key); uniq.append(c)
        if len(uniq) <= k:
            return [{"sentence": s, "source": src} for s, src, _, _ in uniq]
        vec = TfidfVectorizer(analyzer=lambda d: tokenize(d, lang), sublinear_tf=True, min_df=1)
        try:
            X = vec.fit_transform([c[0] for c in uniq])
        except ValueError:
            return [{"sentence": s, "source": src} for s, src, _, _ in uniq[:k]]
        centroid = np.asarray(X.mean(axis=0)).ravel()
        norm = np.linalg.norm(centroid) or 1.0
        rel = X.dot(centroid) / norm
        pos_bonus = np.array([1.0 / (1.0 + 0.35 * si) for _, _, _, si in uniq])
        len_pen = np.array([1.0 if 40 <= len(s) <= 320 else 0.7 for s, _, _, _ in uniq])
        score = rel * pos_bonus * len_pen
        chosen = []
        sims = (X @ X.T).toarray()
        while len(chosen) < k and len(chosen) < len(uniq):
            best, best_val = None, -1e9
            for i in range(len(uniq)):
                if i in chosen:
                    continue
                red = max((sims[i, j] for j in chosen), default=0.0)
                val = 0.72 * score[i] - 0.28 * red
                if val > best_val:
                    best, best_val = i, val
            if best is None or (chosen and sims[best, chosen].max() > 0.8):
                break
            chosen.append(best)
        chosen.sort(key=lambda i: (uniq[i][2], uniq[i][3]))
        return [{"sentence": uniq[i][0], "source": uniq[i][1]} for i in chosen]

SUMMARIZER = Summarizer()

# ----------------------------------------------------------------------------------------------
def central_title(articles, lang_pref="en"):
    """Pick the headline most similar to all others (prefers English, tier-1)."""
    if len(articles) == 1:
        return articles[0]["title"]
    titles = [a["title"] for a in articles]
    try:
        X = TfidfVectorizer(analyzer=lambda d: tokenize(d, "en"), min_df=1).fit_transform(titles)
        sims = (X @ X.T).toarray()
        cen = sims.mean(axis=1)
    except ValueError:
        cen = np.ones(len(titles))
    best, best_v = 0, -1
    for i, a in enumerate(articles):
        v = cen[i] + (0.7 if a.get("lang") == lang_pref else 0) + (0.15 if a.get("tier") == 1 else 0) \
            + (0.1 if 40 <= len(a["title"]) <= 110 else 0) - (0.2 if a.get("kind", "").startswith("gnews") else 0)
        if v > best_v:
            best, best_v = i, v
    return articles[best]["title"]

def perspectives(articles, group_key):
    """Group articles by group_key(a); return sides with representative headline + divergence score."""
    groups = {}
    for a in articles:
        groups.setdefault(group_key(a), []).append(a)
    groups = {g: v for g, v in groups.items() if g}
    if len(groups) < 2:
        return [], 0.0
    titles = [a["title"] + " " + (a.get("summary") or "")[:300] for g in groups for a in groups[g]]
    try:
        vec = TfidfVectorizer(analyzer=lambda d: tokenize(d, "en"), min_df=1, sublinear_tf=True)
        X = vec.fit_transform(titles)
    except ValueError:
        return [], 0.0
    sides, cents, i = [], [], 0
    for g, arts in groups.items():
        Xi = X[i:i + len(arts)]
        c = np.asarray(Xi.mean(axis=0)).ravel()
        cents.append(c / (np.linalg.norm(c) or 1.0))
        sim = Xi.dot(cents[-1])
        rep = arts[int(np.argmax(sim))]
        sides.append({"side": g, "n": len(arts), "headline": rep["title"], "outlet": rep["outlet_name"], "url": rep["url"],
                      "leaning": rep["leaning"], "country": rep["outlet_country"], "lang": rep.get("lang") or "en",
                      "extract": (rep.get("summary") or "")[:300]})
        i += len(arts)
    div = 0.0
    for a in range(len(cents)):
        for b in range(a + 1, len(cents)):
            div = max(div, 1.0 - float(np.dot(cents[a], cents[b])))
    sides.sort(key=lambda s: -s["n"])
    return sides[:4], round(div, 3)

# ----------------------------------------------------------------------------------------------
class ModelStore:
    def __init__(self):
        self.topic = TopicModel()
        self.salience = SalienceModel()
        self.path = config.MODEL_DIR / "models.pkl"

    def load(self):
        try:
            with open(self.path, "rb") as f:
                d = pickle.load(f)
            self.topic, self.salience = d["topic"], d["salience"]
            log.info("models loaded from %s", self.path)
        except FileNotFoundError:
            pass
        except Exception as ex:  # noqa: BLE001
            log.warning("could not load models: %s", ex)

    def save(self):
        with open(self.path, "wb") as f:
            pickle.dump({"topic": self.topic, "salience": self.salience}, f)

    def info(self):
        return {
            "topic": {"trained_at": self.topic.trained_at, "n_train": self.topic.n_train, "type": "22 one-vs-rest logistic regressions (SGD) on hashed word+char n-grams, weak supervision + seeds"},
            "salience": {"trained_at": self.salience.trained_at, "n_train": self.salience.n_train, "type": "SGD ridge regression on hashed n-grams (self-supervised from coverage breadth + user feedback)"},
            "summarizer": "extractive centroid + MMR (unsupervised)",
        }

MODELS = ModelStore()
