# Why the current model sounds like "a mesh of notes" — and how v4 fixes it

This document is the overview you asked for: what the existing model does, why it
produces locally-plausible-but-globally-random output, and the concrete design of
the v4 replacement in `src/v4/` + `notebooks/music-ml-v4.ipynb`.

---

## Part A — How the current model works (Phase 1 / 1.5)

| Component | Current design |
|---|---|
| Tokenizer | Absolute events: `NOTE_ON(p)`, `NOTE_OFF(p)`, chained `TIME_SHIFT(n×10ms)`, `SET_VELOCITY`. 392-token vocab. |
| Context | `seq_len = 512` tokens. |
| Positions | Fixed sinusoidal positional encoding. |
| Model | Decoder-only Transformer, `d_model=512`, 6 layers, 8 heads → ~19M params. |
| Conditioning | Composer embedding (+ optional era/theory embeddings) **added to every position**. |
| Style control | A large hand-written layer of sampler hacks: per-composer logit biases (`composer_constraints.py`), a "note-drought rescue", and a "cadential landing" boost near the end (`generate.py`). |
| Sampling | `temperature=1.0`, `top_k=50`, `top_p=0.95`. |
| Train/val split | `random_split` over **overlapping** sliding windows. |

The architecture itself is sound and idiomatic. The problem is not bugs — it is a
set of representational choices that make musical *structure* almost impossible for
the model to learn, so it only ever learns local note-to-note plausibility.

---

## Part B — The flaws, ranked by how much they cause "mesh of notes"

### 1. The context window is only a few seconds long *(biggest cause)*
In the current tokenization a single note costs roughly:
`TIME_SHIFT × k` + `SET_VELOCITY` + `NOTE_ON` … later `TIME_SHIFT × k` + `NOTE_OFF`
— often 4–8 tokens per note, and gaps longer than 1 s become **chains** of
`TIME_SHIFT` tokens. So 512 tokens ≈ 30–60 notes ≈ **a few seconds** of piano.

A phrase is 4–8 bars; a theme-and-variation or ABA form spans minutes. The model
literally cannot see far enough to have a phrase, a repeat, or a return of a theme.
Given only a few seconds of context, the *optimal* thing for it to learn is exactly
what you hear: plausible local texture with no long-range plan. This one fact
explains most of the "mesh of notes in a pattern" character.

### 2. The tokenization has no metrical grid
`TIME_SHIFT(n×10ms)` encodes *elapsed wall-clock time*, not *musical time*. There is
no representation of "beat 1", "the downbeat", "the 'and' of 2". Human music is
built on a repeating metrical grid — that grid is where repetition, syncopation and
phrasing live. Without it, the model can't align events to a pulse, so its output
has no steady sense of meter even when the notes are individually fine.

### 3. Note-offs are the model's responsibility, and it forgets them
Every `NOTE_ON` must be matched by a later `NOTE_OFF`, but they can be dozens of
tokens apart. The model routinely under- or over-emits note-offs, which is why the
generator needs `_finalize_tokens()` to force-close hung notes. Wrong durations =
muddy, smeared, or clipped sound — a big part of the "mush".

### 4. The sustain pedal is thrown away
`midi_parser.py` reads only `note_on`/`note_off`. MAESTRO is pedal-heavy
performance data; the actual sounding length of most notes is governed by CC64.
Dropping the pedal means the *durations the model trains on are wrong*, and the
model can never reproduce the legato/resonance that makes piano sound like piano.

### 5. Fixed sinusoidal positions don't suit music
Music is highly translation-invariant (a motif sounds "the same" whether it starts
in bar 3 or bar 7). Absolute sinusoidal encodings give the model no notion of
*relative* distance and generalize poorly past the trained length. Relative /
rotary positions are the standard fix and matter a lot for long musical structure.

### 6. The model is small for the job
~19M parameters, 6 layers. Structured long-form generation needs more depth and a
longer effective context. On a Kaggle T4 you can comfortably run a materially
larger model if the sequence is tokenized efficiently (see #1).

### 7. The style system fights the model instead of teaching it
`composer_constraints.py` and the drought/cadence hacks are ~700 lines of
sample-time logit surgery. They can nudge pitch classes, but they cannot manufacture
phrase structure that the model never learned. They are band-aids over flaws #1–#2.
Better representation makes almost all of it unnecessary.

### 8. Evaluation is optimistic
`random_split` splits **windows**, and windows overlap (`stride=256 < seq_len=512`)
and come from the same pieces. Train and val therefore share material, so val loss
understates how badly the model generalizes to unseen music. The split must be
**by piece**.

### 9. High-entropy sampling defaults
`temp=1.0`, `top_k=50`, `top_p=0.95` add a lot of randomness on top of an already
structure-poor model. Reasonable for a strong model; here it amplifies the noise.

---

## Part C — What v4 changes (and why it produces real pieces)

v4 is a clean, self-contained pipeline in `src/v4/`. It is **not** a fine-tune of the
150 epochs — the vocabulary and context length change, so the old checkpoint shape
is incompatible. It trains from scratch but is far more sample-efficient per note.

| Flaw | v4 fix |
|---|---|
| 1 context | REMI-style tokens (~3–4 tokens/note, no time-shift chains) **and** `max_seq_len` raised to 2048 → **~30–60 seconds** of context instead of a few seconds. |
| 2 no meter | Explicit `Bar` and `Position(1/48 of a bar)` tokens give the model a metrical coordinate system. Beat structure, downbeats and phrasing become learnable. |
| 3 note-offs | Notes are `Pitch` + `Duration(quantized)` — duration is emitted *with* the note, so notes can never hang and durations are a first-class learned quantity. |
| 4 pedal | The tokenizer applies CC64 sustain at parse time, extending each note to its true sounding length before quantization. |
| 5 positions | Rotary position embeddings (RoPE) in every attention layer → relative timing, better long-range generalization. |
| 6 size | Config scales to `d_model=640`, 10 layers, 10 heads (~55M) — tunable down for smaller GPUs; fits a T4 at seq 2048 with grad-accum. |
| 7 style hacks | Composer is a **prepended control token**, not a per-position bias, and there are no sampler constraints — style comes from the data + a longer context. |
| 8 eval | Split is **by piece**: no window from a validation piece is ever seen in training. |
| 9 sampling | Defaults `temp=0.95`, `top_p=0.92`, plus a light repetition penalty; a `Bar`-aware generation loop. |

### v4 token vocabulary (built in `src/v4/tokenizer.py`)

```
PAD, BOS, EOS                          (3 control tokens)
COMPOSER<id>                           (one per composer — prepended after BOS)
BAR                                    (start of every new bar)
POSITION_0 … POSITION_47               (48 grid slots per bar: 1/16ths + triplets)
TEMPO_0 … TEMPO_31                     (32 tempo bins, 40–220 BPM)
PITCH_0 … PITCH_127                    (note onset)
DURATION_0 … DURATION_(D-1)            (quantized note lengths in grid steps)
VELOCITY_0 … VELOCITY_31               (32 dynamics bins)
```

A note is emitted as the group `Position, (Tempo?), Pitch, Duration, Velocity`,
which round-trips back to MIDI in `tokenizer.detokenize()`. The round-trip is unit-
tested in the notebook so you can hear that encode→decode is faithful before training.

### Why this yields "real pieces"
The two changes that matter most are **(a)** giving the model an explicit bar/beat
grid and **(b)** making its context reach tens of seconds instead of a few. Together
they let self-attention discover phrase boundaries, repetition, and the return of
material — the ingredients that make output sound *composed* rather than *sampled*.
This is the same representational recipe behind REMI / Pop-Music-Transformer and the
Music Transformer's relative attention; it is the established way to get long-form
musical coherence out of a decoder-only model.

---

## Part D — How to run it

`notebooks/music-ml-v4.ipynb` is standalone (does not import the old `src/` model):

1. **Step 1–2** — locate the Kaggle dataset, install `mido`, check the GPU, and
   auto-pick a size **preset** for the detected VRAM (T4/P100 → d_model 512 / seq
   1024; A100/L4 → d_model 640 / seq 2048).
2. **Step 3** — re-tokenize the raw MAESTRO/GiantMIDI MIDIs into v4 `.npy` token
   files (REMI + pedal). Cached to `/kaggle/working`; re-runs skip existing files.
3. **Step 4** — dataset health check: token-length distribution + composer coverage.
4. **Step 5** — round-trip sanity: tokenize→detokenize a file, confirm note counts.
5. **Step 6** — build the **by-piece** dataset (with ±3-semitone transposition
   augmentation on train, none on val) + the RoPE model from the preset.
6. **Step 7** — *(optional)* 60-second smoke test: a few hundred steps on a subset
   to confirm the loss falls before committing to the full run.
7. **Step 8** — train: mixed precision, grad-accum, cosine LR, label smoothing.
   **Kaggle-safe** — mid-epoch `v4_last.pt` checkpoints, a wall-clock `TIME_BUDGET_H`
   that stops cleanly before the session cap, resume-on-rerun, and a short preview
   MIDI written every few epochs so you can hear progress.
8. **Step 9** — generate several candidate pieces at different temperatures and keep
   the best; **Step 10** *(optional)* renders a `.mid` to audio in-notebook.

The old Phase-1/1.5 files are left untouched; v4 lives beside them so you can compare.
