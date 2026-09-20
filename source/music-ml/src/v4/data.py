"""
v4 dataset + corpus tokenization.

Two responsibilities:

  1. `tokenize_corpus()` — turn (midi_path, composer_id) pairs into cached v4
     token `.npy` files, one per piece (the token stream already contains the
     BOS/COMPOSER/EOS framing from the tokenizer).

  2. `V4Dataset` — window the cached streams for training. Crucially the split
     into train/val happens at the *piece* level (`split_files`), so no window
     from a validation piece is ever seen during training — fixing the
     optimistic overlap of the old `random_split` approach.

Every training window is re-framed as `[BOS, COMPOSER<id>] + body_slice` so the
composer conditioning is present at the start of *every* window, not just the
first one in each piece.
"""

from __future__ import annotations

import os
import random
import numpy as np
import torch
from torch.utils.data import Dataset
from typing import List, Tuple, Optional

from src.v4.tokenizer import REMITokenizer


# ── Corpus tokenization (run once, cached) ───────────────────────────────────

def tokenize_corpus(
    pairs:     List[Tuple[str, int, str]],   # (midi_path, composer_id, out_name)
    tokenizer: REMITokenizer,
    out_dir:   str,
    min_tokens: int = 64,
    verbose:    bool = True,
) -> List[str]:
    """
    Tokenize every MIDI in `pairs` and cache to `out_dir/<out_name>.npy`.
    Skips files already cached. Returns the list of written/existing paths.
    """
    os.makedirs(out_dir, exist_ok=True)
    written: List[str] = []
    n_fail = 0
    for i, (midi_path, composer_id, out_name) in enumerate(pairs):
        out_path = os.path.join(out_dir, out_name + '.npy')
        if os.path.exists(out_path):
            written.append(out_path)
            continue
        try:
            toks = tokenizer.tokenize(midi_path, composer_id=composer_id)
        except Exception:
            toks = []
        if len(toks) < min_tokens:
            n_fail += 1
            continue
        np.save(out_path, np.asarray(toks, dtype=np.int32))
        written.append(out_path)
        if verbose and (i + 1) % 200 == 0:
            print(f"  tokenized {i + 1}/{len(pairs)}  (kept {len(written)}, skipped {n_fail})")
    if verbose:
        print(f"Corpus: {len(written)} pieces cached, {n_fail} skipped (empty/too short/error).")
    return written


def split_files(files: List[str], val_frac: float = 0.05, seed: int = 1234
                ) -> Tuple[List[str], List[str]]:
    """Deterministic per-piece train/val split."""
    files = sorted(files)
    rng = random.Random(seed)
    rng.shuffle(files)
    n_val = max(1, int(len(files) * val_frac))
    return files[n_val:], files[:n_val]


# ── Windowed dataset ─────────────────────────────────────────────────────────

class V4Dataset(Dataset):
    """
    Yields (x, y) where x, y are (seq_len,) long tensors and y is x shifted by 1.

    Each item is [BOS, COMPOSER<id>] + a contiguous slice of one piece's musical
    body, padded with PAD to seq_len+1.
    """

    def __init__(
        self,
        files:     List[str],
        tokenizer: REMITokenizer,
        seq_len:   int = 2048,
        stride:    Optional[int] = None,
        transpose_range: Tuple[int, int] = (-3, 3),   # random semitone shift; (0,0) = off
    ):
        self.tok     = tokenizer
        self.seq_len = seq_len
        stride = stride or seq_len // 2

        self.BOS = tokenizer.BOS
        self.PAD = tokenizer.PAD
        self.PITCH_BASE = tokenizer.PITCH_BASE
        self.transpose_lo, self.transpose_hi = transpose_range
        cbase, cend = tokenizer.COMPOSER_BASE, tokenizer.COMPOSER_BASE + tokenizer.num_composers

        # Each entry: (body_ndarray, composer_token). Windows index into `body`.
        self._bodies: List[Tuple[np.ndarray, int]] = []
        self._index:  List[Tuple[int, int]] = []      # (body_idx, start)

        body_budget = seq_len - 2                       # room for [BOS, COMPOSER]
        for f in files:
            toks = np.load(f)
            composer_tok = int(toks[1]) if (len(toks) > 1 and cbase <= toks[1] < cend) else self.BOS
            # strip BOS, COMPOSER (front) and EOS (back) to get the pure body
            start_body = 2 if composer_tok != self.BOS else 1
            body = toks[start_body:]
            if len(body) and body[-1] == tokenizer.EOS:
                body = body[:-1]
            if len(body) == 0:
                continue
            bi = len(self._bodies)
            self._bodies.append((body.astype(np.int64), composer_tok))
            for s in range(0, max(1, len(body) - body_budget), stride):
                self._index.append((bi, s))
            # ensure a window anchored at the end for long pieces
            if len(body) > body_budget:
                last = len(body) - body_budget
                if not self._index or self._index[-1] != (bi, last):
                    self._index.append((bi, last))

    def __len__(self) -> int:
        return len(self._index)

    def _transpose(self, seq: np.ndarray, k: int) -> np.ndarray:
        """Shift every PITCH token by k semitones (clamped to 0-127). Other
        token families (position/duration/velocity/tempo/bar) are untouched."""
        lo, hi = self.PITCH_BASE, self.PITCH_BASE + 128
        is_pitch = (seq >= lo) & (seq < hi)
        if is_pitch.any():
            shifted = np.clip(seq[is_pitch] - lo + k, 0, 127) + lo
            seq[is_pitch] = shifted
        return seq

    def __getitem__(self, idx: int):
        bi, s = self._index[idx]
        body, composer_tok = self._bodies[bi]
        budget = self.seq_len - 2
        slice_ = body[s:s + budget]

        seq = np.empty(len(slice_) + 2, dtype=np.int64)
        seq[0] = self.BOS
        seq[1] = composer_tok
        seq[2:] = slice_

        # Data augmentation: random transposition (whole window, keys stay coherent)
        if self.transpose_lo != 0 or self.transpose_hi != 0:
            k = random.randint(self.transpose_lo, self.transpose_hi)
            if k != 0:
                seq = self._transpose(seq, k)

        # pad to seq_len + 1 so x and y are both seq_len
        target = self.seq_len + 1
        if len(seq) < target:
            pad = np.full(target - len(seq), self.PAD, dtype=np.int64)
            seq = np.concatenate([seq, pad])
        else:
            seq = seq[:target]

        x = torch.from_numpy(seq[:-1])
        y = torch.from_numpy(seq[1:])
        return x, y
