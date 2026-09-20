"""
Sort the MAESTRO dataset into per-composer directories.

Reads maestro-v3.0.0.json, creates symlinks in data/raw/<ComposerName>/
so the preprocessing pipeline can find them.

For "Composer A / Composer B" entries (arrangements), only the primary
composer (before the "/") is used as the folder name.

Usage:
  python scripts/sort_maestro.py \
      --maestro_dir data/raw/maestro-v3.0.0 \
      --out_dir     data/raw/by_composer
"""

import argparse
import json
import os
import re
import sys


def sanitize(name: str) -> str:
    """Make a string safe for use as a directory name."""
    name = name.split('/')[0].strip()          # keep primary composer only
    name = re.sub(r'[\\:*?"<>|]', '', name)   # strip Windows-illegal chars
    name = name.strip()
    return name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--maestro_dir', default='data/raw/maestro-v3.0.0',
                        help='Root of the extracted MAESTRO dataset')
    parser.add_argument('--out_dir', default='data/raw/by_composer',
                        help='Output directory for per-composer symlink trees')
    args = parser.parse_args()

    json_path = os.path.join(args.maestro_dir, 'maestro-v3.0.0.json')
    if not os.path.exists(json_path):
        print(f"[ERROR] JSON not found: {json_path}")
        sys.exit(1)

    with open(json_path) as f:
        data = json.load(f)

    # data is a dict of lists keyed by field name — zip into rows
    n = len(data['canonical_composer'])
    rows = [
        {k: data[k][str(i)] for k in data}
        for i in range(n)
    ]

    os.makedirs(args.out_dir, exist_ok=True)

    created   = 0
    skipped   = 0
    composers_seen = set()

    for row in rows:
        composer_raw  = row['canonical_composer']
        midi_rel_path = row['midi_filename']          # e.g. "2018/somefile.midi"

        composer_dir_name = sanitize(composer_raw)
        composers_seen.add(composer_dir_name)

        src = os.path.abspath(os.path.join(args.maestro_dir, midi_rel_path))
        if not os.path.exists(src):
            print(f"  [WARN] Source not found, skipping: {src}")
            skipped += 1
            continue

        dst_dir = os.path.join(args.out_dir, composer_dir_name)
        os.makedirs(dst_dir, exist_ok=True)

        dst = os.path.join(dst_dir, os.path.basename(midi_rel_path))
        if os.path.exists(dst) or os.path.islink(dst):
            skipped += 1
            continue

        os.symlink(src, dst)
        created += 1

    print(f"\nDone.")
    print(f"  Composers: {len(composers_seen)}")
    print(f"  Symlinks created: {created}")
    print(f"  Skipped (already exist or missing): {skipped}")
    print(f"  Output: {os.path.abspath(args.out_dir)}")

    # Print composer summary
    print(f"\nComposers sorted into {args.out_dir}/:")
    for name in sorted(composers_seen):
        d = os.path.join(args.out_dir, name)
        count = len(os.listdir(d)) if os.path.isdir(d) else 0
        print(f"  {count:3d} files  {name}")


if __name__ == '__main__':
    main()
