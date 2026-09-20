"""
CLI script: convert raw MIDI files into preprocessed .npy token arrays.

Usage:
  python scripts/preprocess_data.py \
      --raw_dir  data/raw \
      --out_dir  data/processed
"""

import argparse
import sys
import os

# Allow running from project root
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.data.preprocess import preprocess_dataset


def main():
    parser = argparse.ArgumentParser(description='Preprocess MIDI dataset')
    parser.add_argument('--raw_dir', default='data/raw',       help='Root of raw MIDI data')
    parser.add_argument('--out_dir', default='data/processed', help='Output directory')
    args = parser.parse_args()

    composer_map = preprocess_dataset(args.raw_dir, args.out_dir)
    print(f"Composer map ({len(composer_map)} composers):")
    for name, idx in sorted(composer_map.items(), key=lambda x: x[1]):
        print(f"  {idx:2d}: {name}")


if __name__ == '__main__':
    main()
