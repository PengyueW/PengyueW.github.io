"""
Preprocess the MAESTRO v3.0.0 dataset into the project's processed format.

MAESTRO stores MIDIs under year subdirs with composer info in a JSON metadata file.
This script reads that metadata and writes .npy token arrays directly into
data/processed/<ComposerName>/, merging with any existing composer_map.json.

Usage:
  python scripts/prepare_maestro.py \
      --maestro_dir data/raw/maestro-v3.0.0 \
      --out_dir     data/processed

Optional flags:
  --split train        Only process a specific split (train / validation / test / all)
  --skip_existing      Skip files already present in out_dir (default: True)
"""

import argparse
import json
import os
import sys

import numpy as np
from tqdm import tqdm

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from src.data.midi_parser import midi_to_events


def sanitize_name(name: str) -> str:
    """Replace filesystem-unsafe characters in composer names."""
    return name.replace('/', '_').replace('\\', '_').replace(':', '-')


def load_maestro_metadata(maestro_dir: str) -> list[dict]:
    json_path = os.path.join(maestro_dir, 'maestro-v3.0.0.json')
    if not os.path.exists(json_path):
        raise FileNotFoundError(f'maestro-v3.0.0.json not found in {maestro_dir}')
    with open(json_path) as f:
        raw = json.load(f)
    # JSON is column-oriented: {field: {str(idx): value, ...}}
    n = len(raw['midi_filename'])
    entries = []
    for i in range(n):
        key = str(i)
        entries.append({
            'composer':  raw['canonical_composer'][key],
            'midi_path': os.path.join(maestro_dir, raw['midi_filename'][key]),
            'split':     raw['split'][key],
        })
    return entries


def load_or_create_composer_map(out_dir: str) -> dict:
    map_path = os.path.join(out_dir, 'composer_map.json')
    if os.path.exists(map_path):
        with open(map_path) as f:
            return json.load(f)
    return {}


def save_composer_map(out_dir: str, composer_map: dict) -> None:
    with open(os.path.join(out_dir, 'composer_map.json'), 'w') as f:
        json.dump(composer_map, f, indent=2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--maestro_dir', default='data/raw/maestro-v3.0.0')
    parser.add_argument('--out_dir',     default='data/processed')
    parser.add_argument('--split',       default='all',
                        choices=['train', 'validation', 'test', 'all'])
    parser.add_argument('--no_skip_existing', action='store_true')
    args = parser.parse_args()

    skip_existing = not args.no_skip_existing

    os.makedirs(args.out_dir, exist_ok=True)

    entries = load_maestro_metadata(args.maestro_dir)
    if args.split != 'all':
        entries = [e for e in entries if e['split'] == args.split]
    print(f'Entries to process: {len(entries)} (split={args.split})')

    # Build the full set of composer names from this batch
    raw_composers = sorted({e['composer'] for e in entries})
    composer_map  = load_or_create_composer_map(args.out_dir)

    # Assign IDs to any new composers not already in the map
    next_id = max(composer_map.values(), default=-1) + 1
    for name in raw_composers:
        safe = sanitize_name(name)
        if safe not in composer_map:
            composer_map[safe] = next_id
            next_id += 1

    save_composer_map(args.out_dir, composer_map)

    total = len(entries)
    skipped = failed = succeeded = 0

    for entry in tqdm(entries, desc='MAESTRO'):
        composer_safe = sanitize_name(entry['composer'])
        dst_dir  = os.path.join(args.out_dir, composer_safe)
        os.makedirs(dst_dir, exist_ok=True)

        basename = os.path.splitext(os.path.basename(entry['midi_path']))[0]
        dst_path = os.path.join(dst_dir, basename + '.npy')

        if skip_existing and os.path.exists(dst_path):
            skipped += 1
            continue

        if not os.path.exists(entry['midi_path']):
            print(f'  [WARN] Missing: {entry["midi_path"]}')
            failed += 1
            continue

        try:
            tokens = midi_to_events(entry['midi_path'])
            np.save(dst_path, np.array(tokens, dtype=np.int64))
            succeeded += 1
        except Exception as e:
            print(f'  [WARN] Failed {entry["midi_path"]}: {e}')
            failed += 1

    print(f'\nDone. succeeded={succeeded}  skipped={skipped}  failed={failed}  total={total}')
    print(f'Composer map now has {len(composer_map)} composers.')
    print(f'Output: {args.out_dir}')


if __name__ == '__main__':
    main()
