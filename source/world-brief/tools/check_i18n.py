#!/usr/bin/env python3
"""Check the interface translations against the English master.

Reports, for every locale in frontend/i18n:
  * keys that are missing or left over,
  * keys whose {placeholders} do not match English (the usual way a translation breaks),
  * counted phrases missing the plural forms their language needs (Russian wants four, Arabic six),
  * keys that were copied from English without being translated (a hint, not an error),
  * keys used by the code but defined nowhere, and defined keys nobody uses.

Run:  .venv/bin/python tools/check_i18n.py
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
I18N = ROOT / "frontend" / "i18n"
BASE = "en"
PLACEHOLDER = re.compile(r"\{(\w+)\}")

# Keys the code builds at run time rather than writing out literally.
DYNAMIC_PREFIXES = ("cat.", "leaning.", "ownership.", "polarity.", "region.", "stage.", "lang.route")

# The CLDR plural categories each shipped language actually uses. A counted phrase must supply
# all of them, or a number will come out in the wrong grammatical form.
PLURAL_CATEGORIES = {
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "pl": {"one", "few", "many", "other"},
    "ru": {"one", "few", "many", "other"},
    "uk": {"one", "few", "many", "other"},
    "zh": {"other"}, "ja": {"other"}, "ko": {"other"},
}
DEFAULT_CATEGORIES = {"one", "other"}

def forms(value):
    """Every string in a value, whether it is a plain string or a set of plural forms."""
    return list(value.values()) if isinstance(value, dict) else [value]

# A key looks like "group.name": the code passes them as plain strings, sometimes inside a
# ternary, so every string of that shape counts as a use. Fragments the code concatenates
# ("cat." + id) end in a dot and are skipped.
KEYLIKE = re.compile(r"""["']([a-z][\w]*\.[\w][\w.\-/ ()]*)["']""")

def used_keys():
    keys = set()
    for path in [ROOT / "frontend" / "app.js", ROOT / "frontend" / "index.html"]:
        keys |= set(KEYLIKE.findall(path.read_text(encoding="utf-8")))
    return {k for k in keys if not k.endswith(".")}

def main():
    base = json.loads((I18N / f"{BASE}.json").read_text(encoding="utf-8"))
    problems = 0
    print(f"{BASE}: {len(base)} keys (master)\n")
    for path in sorted(I18N.glob("*.json")):
        code = path.stem
        if code == BASE:
            continue
        d = json.loads(path.read_text(encoding="utf-8"))
        missing = [k for k in base if k not in d]
        extra = [k for k in d if k not in base]
        want = PLURAL_CATEGORIES.get(code, DEFAULT_CATEGORIES)
        badph, same, badplural, shape = [], [], [], []
        for k, v in d.items():
            if k not in base:
                continue
            if isinstance(base[k], dict) != isinstance(v, dict):
                shape.append(k)
                continue
            if isinstance(v, dict):
                if not want <= set(v):
                    badplural.append(f"{k} (missing {', '.join(sorted(want - set(v)))})")
            if isinstance(v, dict):
                # A plural form may leave {n} out — "one article" reads better than "1 article" in
                # Arabic and Russian — but it may not invent a placeholder English does not have.
                expected = set(PLACEHOLDER.findall(base[k]["other"]))
                if any(not set(PLACEHOLDER.findall(f)) <= expected for f in v.values()):
                    badph.append(k)
            elif set(PLACEHOLDER.findall(v)) != set(PLACEHOLDER.findall(base[k])):
                badph.append(k)
            elif v == base[k] and any(ch.isalpha() for ch in v) and len(v) > 3 and not v.isupper():
                same.append(k)
        status = "ok" if not (missing or extra or badph or badplural or shape) else "PROBLEM"
        print(f"{code}: {len(d)} keys, {status}")
        for label, items in (("missing", missing), ("unknown", extra), ("placeholders differ", badph),
                             ("not a set of plural forms", shape), ("plural forms missing", badplural)):
            if items:
                problems += len(items)
                print(f"    {label}: {', '.join(items[:12])}{' …' if len(items) > 12 else ''}")
        if same:
            print(f"    same as English ({len(same)}): {', '.join(same[:8])}{' …' if len(same) > 8 else ''}")

    used = used_keys()
    unknown = sorted(k for k in used if k not in base)
    unused = sorted(k for k in base
                    if k not in used and k != "__loaded" and not k.startswith(DYNAMIC_PREFIXES))
    print()
    if unknown:
        problems += len(unknown)
        print(f"used in the code but not defined in {BASE}.json: {', '.join(unknown)}")
    if unused:
        print(f"defined but never used ({len(unused)}): {', '.join(unused)}")
    print("\nOK" if not problems else f"\n{problems} problem(s)")
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main())
