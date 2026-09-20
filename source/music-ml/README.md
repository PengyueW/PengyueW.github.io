# Composer-Conditioned Music Generation

A decoder-only transformer trained from scratch on solo piano MIDI from 68 classical
composers, conditioned on the composer, the musical era, and music theory — not a fine-tune
of an existing model, and not a generic "AI piano".

The goal is music shaped by the same theory a human composer works with: the model is
supervised on real harmonic analysis, and sampling is constrained per composer (strict
dominant resolution for Bach, permitted parallel fifths for Debussy) from a from-scratch
theory reference covering every composer in the dataset.

## Status

| Phase | What | State |
|---|---|---|
| 1 | Composer-conditioned foundation — decoder-only transformer over a 392-token event vocabulary, learnable composer embedding | Done |
| 1.5 | Music theory & era conditioning — auxiliary key/chord heads, a 6-era embedding (Baroque → Modern), per-composer sampling constraints | In progress |
| 2 | Natural-language prompting — a text encoder so "a melancholic waltz in the style of Chopin" steers generation | Planned |
| 3 | Multi-instrument — beyond solo piano to small ensembles | Planned |

## Layout

```
src/data/          MIDI parsing, tokenisation, dataset windows, composer metadata,
                   music21-based theory (key/chord) extraction
src/model/         The decoder-only transformer: pre-norm attention, tied embeddings,
                   composer (and optionally era + theory) conditioning
src/training/      Training loop and the single hyperparameter file (config.py)
src/inference/     Sampling, and the per-composer constraint layer
src/v4/            The current iteration of the tokenizer / model / training path
tests/             Unit tests for the parser, the dataset windows and the model
scripts/           Command-line entry points
notebooks/         Colab and Kaggle training notebooks
```

Datasets and checkpoints are deliberately not in this repository.

## Running it

```bash
pip install -r requirements.txt

python scripts/prepare_maestro.py                       # fetch and prepare the corpus
python scripts/preprocess_data.py                       # MIDI -> token windows
python scripts/train.py --epochs 100 --batch_size 32    # defaults mirror src/training/config.py
python scripts/generate.py --checkpoint <path>.pt --composer "Chopin" --output output/generated.mid
python -m pytest tests/
```

Every hyperparameter lives in `src/training/config.py` — context window 512, `d_model` 512,
6 layers, 8 heads, a 64-dimensional composer embedding — and the training script's flags
override it without touching any other file.

## How this was built

This project is architected and directed by **Pengyue Wang**, with **Claude** used as an
implementation assistant.

Claude generated boilerplate, scaffolded the unit tests, and accelerated the routine
implementation work. The engineering and musical judgement is mine:

- **Architecture.** I designed the tokenisation scheme, decided what composer, era and theory
  conditioning should mean as model inputs, and set the staged roadmap above — including the
  decision to train from scratch rather than fine-tune, so that the conditioning is learned
  rather than bolted on.
- **Review.** I peer-reviewed the code and the training runs, and rejected approaches whose
  musical output did not justify them.
- **Debugging.** I found and fixed the inconsistencies and functional flaws — MIDI parsing
  edge cases, tokenizer round-trip mismatches, loss curves that flattened for the wrong
  reasons, and conditioning signals the model was quietly ignoring.
- **Direction.** I decided which experiment came next and how to judge whether it had worked.

---

*Architected and directed by Pengyue Wang; implemented with Claude as an assistant.*
