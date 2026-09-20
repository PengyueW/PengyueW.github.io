"""
Hyperparameters and paths for training.
Edit this file to tune the model without touching any other source file.
"""

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class TrainConfig:
    # ── Paths ────────────────────────────────────────────────────────────────
    raw_data_dir:       str = "data/raw"
    processed_data_dir: str = "data/processed"
    checkpoint_dir:     str = "checkpoints"

    # ── Data ─────────────────────────────────────────────────────────────────
    seq_len:            int   = 512       # context window (tokens)
    stride:             int   = 256       # window stride for dataset construction
    train_split:        float = 0.9       # fraction of data used for training

    # ── Model ────────────────────────────────────────────────────────────────
    vocab_size:         int   = 392       # fixed by midi_parser.VOCAB_SIZE
    d_model:            int   = 512       # transformer embedding dimension
    n_heads:            int   = 8         # number of attention heads
    n_layers:           int   = 6         # number of transformer decoder layers
    d_ff:               int   = 2048      # feed-forward inner dimension
    dropout:            float = 0.1
    max_seq_len:        int   = 1024      # positional encoding max length

    # ── Composer conditioning ─────────────────────────────────────────────────
    num_composers:      int   = 10        # overridden from composer_map at runtime
    composer_embed_dim: int   = 64        # size of learnable composer embedding

    # ── Training ─────────────────────────────────────────────────────────────
    batch_size:         int   = 32
    num_epochs:         int   = 100
    learning_rate:      float = 1e-4
    weight_decay:       float = 1e-2
    warmup_steps:       int   = 4000
    grad_clip:          float = 1.0
    log_every:          int   = 100       # steps between console log lines
    save_every:         int   = 5         # epochs between periodic saves

    # ── Era conditioning (Phase 1.5) ──────────────────────────────────────────
    use_era:            bool  = False     # add era embedding alongside composer embedding

    # ── Theory fine-tuning (Phase 1.5) ───────────────────────────────────────
    use_theory:         bool  = False     # enable theory conditioning + aux losses
    theory_loss_weight: float = 0.1       # weight applied to chord + key aux losses
    freeze_base_embed:  bool  = True      # freeze token embed rows 0-391 when fine-tuning

    # ── Inference defaults ────────────────────────────────────────────────────
    max_gen_tokens:     int   = 1024
    temperature:        float = 1.0
    top_k:              int   = 50
    top_p:              float = 0.95
