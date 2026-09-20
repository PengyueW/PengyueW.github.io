"""Group articles into events: TF-IDF cosine linkage within a language, entity-signature merge across languages."""
import logging
import time

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer

from . import config
from .textutil import tokenize, entity_signature

log = logging.getLogger("cluster")

class DSU:
    def __init__(self, n):
        self.p = list(range(n))
    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x
    def union(self, a, b):
        a, b = self.find(a), self.find(b)
        if a != b:
            self.p[b] = a

def _doc(a):
    return f"{a['title']} {a['title']} {(a.get('summary') or '')[:600]}"

def _link_group(articles, idxs, threshold, max_gap_h=36):
    """Single-linkage on cosine >= threshold, chunked to bound memory. Returns list of index lists."""
    if len(idxs) == 1:
        return [idxs]
    lang = articles[idxs[0]].get("lang", "en") or "en"
    docs = [_doc(articles[i]) for i in idxs]
    vec = TfidfVectorizer(analyzer=lambda d: tokenize(d, lang), min_df=1, max_df=0.4 if len(idxs) > 20 else 1.0,
                          sublinear_tf=True, ngram_range=(1, 1))
    try:
        X = vec.fit_transform(docs).tocsr()
    except ValueError:
        return [[i] for i in idxs]
    times = np.array([articles[i]["published"] for i in idxs])
    XT = X.T.tocsc()
    step = 400
    pairs = []
    for s in range(0, len(idxs), step):
        block = (X[s:s + step] @ XT).toarray()
        rows, cols = np.where(block >= threshold)
        for r, c in zip(rows, cols):
            i, j = s + r, c
            if j <= i or abs(times[i] - times[j]) > max_gap_h * 3600:
                continue
            pairs.append((float(block[r, c]), i, j))
    pairs.sort(reverse=True)
    # Agglomerate strongest pairs first, but only merge when the two clusters' centroids still agree
    # (prevents chaining "A~B, B~C" into one mega-story when A and C are unrelated).
    dsu = DSU(len(idxs))
    sums = {k: X[k] for k in range(len(idxs))}
    sizes = {k: 1 for k in range(len(idxs))}
    for sim, i, j in pairs:
        a, b = dsu.find(i), dsu.find(j)
        if a == b:
            continue
        if sizes[a] > 1 or sizes[b] > 1:
            ca, cb = sums[a], sums[b]
            na, nb = np.sqrt(ca.multiply(ca).sum()), np.sqrt(cb.multiply(cb).sum())
            cos = float(ca.multiply(cb).sum() / (na * nb)) if na and nb else 0.0
            if cos < threshold * 0.9:
                continue
        dsu.union(a, b)
        root = dsu.find(a)
        other = b if root == a else a
        sums[root] = sums[a] + sums[b]
        sizes[root] = sizes[a] + sizes[b]
        if other != root:
            sums.pop(other, None); sizes.pop(other, None)
    groups = {}
    for k in range(len(idxs)):
        groups.setdefault(dsu.find(k), []).append(idxs[k])
    out = []
    for g in groups.values():
        if len(g) > 80 and threshold < 0.75:      # over-chained mega-cluster: split with a stricter threshold
            out.extend(_link_group(articles, g, threshold + 0.12, max_gap_h))
        else:
            out.append(g)
    return out

def cluster_articles(articles):
    """Return list of clusters (lists of article indices)."""
    t0 = time.time()
    by_lang = {}
    for i, a in enumerate(articles):
        by_lang.setdefault((a.get("lang") or "en").split("-")[0], []).append(i)
    clusters = []
    for lang, idxs in by_lang.items():
        clusters.extend(_link_group(articles, idxs, config.CLUSTER_SIM_THRESHOLD))
    log.info("within-language clustering: %d articles -> %d clusters (%.1fs)", len(articles), len(clusters), time.time() - t0)
    clusters = _merge_by_entities(articles, clusters)
    log.info("after entity merge: %d clusters (%.1fs)", len(clusters), time.time() - t0)
    return clusters

def _cluster_profile(articles, cluster):
    names, geos, langs = set(), set(), set()
    weights = {}
    for i in cluster[:12]:
        a = articles[i]
        names |= entity_signature(a["title"])
        langs.add((a.get("lang") or "en").split("-")[0])
        g = a.get("_geo") or {}
        for code, w in (g.get("countries") or {}).items():
            geos.add("c:" + code)
            weights[code] = weights.get(code, 0.0) + w
        for l in (g.get("locs") or [])[:3]:
            if l.get("kind") == "city":
                geos.add("g:" + l["name"])
    top = max(weights, key=weights.get) if weights else None
    return names, geos, langs, top

def _merge_by_entities(articles, clusters):
    """Merge clusters that report the same event.

    Two paths: (1) strong overlap of named entities (same language or shared spellings), and
    (2) a cross-language path, where a story written in different languages shares almost no
    tokens but does share resolved places (the gazetteer knows "Dinamarca" is Denmark) plus at
    least one name that survives translation (people, organisations, numbers).
    """
    names, geos, langs, tops, spans, name_index, geo_index = [], [], [], [], [], {}, {}
    for ci, c in enumerate(clusters):
        n, g, l, t = _cluster_profile(articles, c)
        names.append(n); geos.append(g); langs.append(l); tops.append(t)
        ts = [articles[i]["published"] for i in c]
        spans.append((min(ts), max(ts)))
        for e in n:
            name_index.setdefault(e, []).append(ci)
        for e in g:
            geo_index.setdefault(e, []).append(ci)
    dsu = DSU(len(clusters))
    seen = set()
    comp_articles = {i: len(c) for i, c in enumerate(clusters)}
    MAX_MERGED_ARTICLES = 160      # a real single event rarely exceeds this; beyond it, chaining is likelier

    def union(a, b):
        ra, rb = dsu.find(a), dsu.find(b)
        if ra == rb:
            return
        if comp_articles[ra] + comp_articles[rb] > MAX_MERGED_ARTICLES:
            return
        dsu.union(ra, rb)
        root = dsu.find(ra)
        total = comp_articles[ra] + comp_articles[rb]
        comp_articles[root] = total

    def consider(a, b):
        if a == b or (a, b) in seen:
            return
        seen.add((a, b))
        if abs(spans[a][0] - spans[b][0]) > 36 * 3600:
            return
        na, nb = names[a], names[b]
        inter = len(na & nb)
        if len(na) >= 3 and len(nb) >= 3 and inter >= 3:
            if inter / len(na | nb) >= config.CLUSTER_ENTITY_JACCARD:
                union(a, b)
                return
        # cross-language path. Skip only when both sides are the same single language: TF-IDF
        # already handled that case, and a mixed-language cluster must stay able to absorb more.
        if (langs[a] == langs[b] and len(langs[a]) == 1) or abs(spans[a][0] - spans[b][0]) > 24 * 3600:
            return
        ga, gb = geos[a], geos[b]
        shared = ga & gb
        if len(shared) < 2 or inter < 1:
            return
        # A shared *specific* place (city, territory, strait) is the discriminating signal: every
        # Trump story shares the country US and the name "Trump", but only the Greenland ones
        # share Greenland/Groenlandia/Grönland. Without this, translations chain into one blob.
        shared_specific = any(k.startswith("g:") for k in shared)
        if not shared_specific or inter < 2:
            return
        # Both sides must also agree on what the story is *about*: same shared place, at least two
        # names in common (people, organisations, numbers survive translation), and close in time.
        if abs(spans[a][1] - spans[b][1]) > 18 * 3600:
            return
        if inter / min(len(na), len(nb)) < 0.3:
            return
        union(a, b)

    for e, cis in name_index.items():
        if len(cis) > 40:
            continue
        for x in range(len(cis)):
            for y in range(x + 1, len(cis)):
                consider(cis[x], cis[y])
    for e, cis in geo_index.items():
        if len(cis) > 60:
            continue
        for x in range(len(cis)):
            for y in range(x + 1, len(cis)):
                consider(cis[x], cis[y])
    merged = {}
    for ci in range(len(clusters)):
        merged.setdefault(dsu.find(ci), []).extend(clusters[ci])
    return list(merged.values())
