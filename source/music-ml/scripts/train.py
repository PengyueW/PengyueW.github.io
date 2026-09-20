"""
CLI script: train the MusicTransformer.

Usage:
  python scripts/train.py \
      --processed_dir data/processed \
      --checkpoint_dir checkpoints \
      --epochs 100 \
      --batch_size 32 \
      --d_model 512 \
      --n_layers 6
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.training.config import TrainConfig
from src.training.trainer import Trainer


def main():
    parser = argparse.ArgumentParser(description='Train MusicTransformer')
    parser.add_argument('--processed_dir',  default='data/processed')
    parser.add_argument('--checkpoint_dir', default='checkpoints')
    parser.add_argument('--epochs',     type=int,   default=100)
    parser.add_argument('--batch_size', type=int,   default=32)
    parser.add_argument('--d_model',    type=int,   default=512)
    parser.add_argument('--n_layers',   type=int,   default=6)
    parser.add_argument('--n_heads',    type=int,   default=8)
    parser.add_argument('--lr',         type=float, default=1e-4)
    parser.add_argument('--seq_len',    type=int,   default=512)
    args = parser.parse_args()

    # Load composer map produced by preprocess_data.py
    map_path = os.path.join(args.processed_dir, 'composer_map.json')
    if not os.path.exists(map_path):
        print(f"[ERROR] composer_map.json not found in {args.processed_dir}. "
              "Run scripts/preprocess_data.py first.")
        sys.exit(1)
    with open(map_path) as f:
        composer_map = json.load(f)

    cfg = TrainConfig(
        processed_data_dir=args.processed_dir,
        checkpoint_dir=args.checkpoint_dir,
        num_epochs=args.epochs,
        batch_size=args.batch_size,
        d_model=args.d_model,
        n_layers=args.n_layers,
        n_heads=args.n_heads,
        learning_rate=args.lr,
        seq_len=args.seq_len,
        num_composers=len(composer_map),
    )

    trainer = Trainer(cfg, composer_map)
    trainer.train()


if __name__ == '__main__':
    main()
