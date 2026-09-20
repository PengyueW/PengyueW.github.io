"""
v4 pipeline — a structure-aware rewrite of the Music-ML generator.

The design and rationale are documented in the repository-root IMPROVEMENTS.md.
Key differences from the Phase-1/1.5 pipeline (src/model, src/data):

  * REMI-style tokenizer (Bar / Position / Pitch / Duration / Velocity / Tempo)
    with sustain-pedal-aware note durations           -> src/v4/tokenizer.py
  * RoPE decoder-only Transformer, longer context     -> src/v4/model.py
  * Per-piece train/val split dataset                 -> src/v4/data.py
  * Trainer with grad-accum + cosine LR + AMP         -> src/v4/train.py
  * Bar-aware sampling with repetition penalty        -> src/v4/generate.py

Nothing here imports the old src/ model, so the two coexist.
"""
