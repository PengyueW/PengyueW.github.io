"""
Preprocessing pipeline: scan a dataset directory, convert MIDI files to
event token sequences, and save them as .npy arrays.

Expected input layout:
  raw_dir/
    <ComposerName>/
      piece1.mid
      piece2.mid
      ...

Output layout (mirrors input):
  processed_dir/
    <ComposerName>/
      piece1.npy
      piece2.npy
      ...

Also writes:
  processed_dir/composer_map.json  — {"Bach": 0, "Chopin": 1, ...}
"""

import os
import json
import numpy as np
from tqdm import tqdm

from src.data.midi_parser import midi_to_events


def build_composer_map(raw_dir: str) -> dict:
    composers = sorted(
        d for d in os.listdir(raw_dir)
        if os.path.isdir(os.path.join(raw_dir, d))
    )
    return {name: idx for idx, name in enumerate(composers)}


def preprocess_dataset(raw_dir: str, processed_dir: str) -> dict:
    """
    Convert all MIDI files under raw_dir into .npy token arrays.

    Returns the composer_map dict.
    """
    composer_map = build_composer_map(raw_dir)
    os.makedirs(processed_dir, exist_ok=True)

    # Persist the composer map
    map_path = os.path.join(processed_dir, 'composer_map.json')
    with open(map_path, 'w') as f:
        json.dump(composer_map, f, indent=2)

    total_files  = 0
    failed_files = 0

    for composer_name in tqdm(composer_map, desc='Composers'):
        src_dir = os.path.join(raw_dir, composer_name)
        dst_dir = os.path.join(processed_dir, composer_name)
        os.makedirs(dst_dir, exist_ok=True)

        midi_files = [f for f in os.listdir(src_dir) if f.lower().endswith(('.mid', '.midi'))]

        for fname in tqdm(midi_files, desc=composer_name, leave=False):
            total_files += 1
            src_path = os.path.join(src_dir, fname)
            dst_path = os.path.join(dst_dir, os.path.splitext(fname)[0] + '.npy')

            if os.path.exists(dst_path):
                continue  # skip already processed files

            try:
                tokens = midi_to_events(src_path)
                np.save(dst_path, np.array(tokens, dtype=np.int64))
            except Exception as e:
                failed_files += 1
                print(f"  [WARN] Failed to process {src_path}: {e}")

    print(f"\nPreprocessing complete. {total_files - failed_files}/{total_files} files succeeded.")
    return composer_map
