"""
PyTorch Dataset for composer-conditioned music generation.

Each sample is a fixed-length window of event tokens drawn from a
preprocessed sequence, paired with a composer label.

When use_theory=True, a parallel _theory.npy file is loaded alongside each
.npy file. If the theory file does not yet exist for a given piece the window
is filled with unknown-sentinel values so that the training loop can safely
ignore it via the ignore_index mechanism in the auxiliary losses.
"""

import os
import numpy as np
import torch
from torch.utils.data import Dataset
from typing import Dict, List, Optional, Tuple

from src.data.midi_parser import PAD_TOKEN
from src.data.theory_extractor import KEY_UNKNOWN, CHORD_UNKNOWN, BEAT_UNKNOWN, CADENCE_NONE


# Sentinel row written when a theory file is absent for a piece
_THEORY_UNKNOWN_ROW = np.array(
    [KEY_UNKNOWN, CHORD_UNKNOWN, BEAT_UNKNOWN, CADENCE_NONE], dtype=np.int16
)


class MusicDataset(Dataset):
    """
    Loads preprocessed .npy token sequences and yields either
      (x, y, composer_id)                           when use_theory=False
      (x, y, composer_id, theory_x)                 when use_theory=True

    theory_x has shape (seq_len, 4) int16:
      col 0 — key_id, col 1 — chord_id, col 2 — beat_id, col 3 — cadence_id

    Args:
        data_dir     : Directory with per-composer sub-dirs of .npy files.
        composer_map : Dict mapping composer name → integer ID.
        seq_len      : Context window length (tokens). Default 512.
        stride       : Step between windows from a single piece. Default 256.
        use_theory   : Whether to load _theory.npy parallel files.
    """

    def __init__(
        self,
        data_dir:     str,
        composer_map: Dict[str, int],
        seq_len:      int  = 512,
        stride:       int  = 256,
        use_theory:   bool = False,
    ):
        self.seq_len    = seq_len
        self.use_theory = use_theory

        # Each entry: (token_window, composer_id)          when use_theory=False
        #             (token_window, theory_window, composer_id)  when True
        self._items: list = []

        for composer_name, composer_id in composer_map.items():
            composer_dir = os.path.join(data_dir, composer_name)
            if not os.path.isdir(composer_dir):
                continue

            for fname in sorted(os.listdir(composer_dir)):
                if not fname.endswith('.npy') or fname.endswith('_theory.npy'):
                    continue

                token_path  = os.path.join(composer_dir, fname)
                theory_path = token_path.replace('.npy', '_theory.npy')

                tokens = np.load(token_path)

                theory_arr: Optional[np.ndarray] = None
                if use_theory:
                    if os.path.exists(theory_path):
                        theory_arr = np.load(theory_path).astype(np.int16)
                        # Guard: theory and token arrays must have same length
                        if len(theory_arr) != len(tokens):
                            theory_arr = None
                    if theory_arr is None:
                        # Fill unknowns so the piece is still usable
                        theory_arr = np.tile(
                            _THEORY_UNKNOWN_ROW, (len(tokens), 1)
                        )

                # Build sliding windows
                starts = list(range(0, max(1, len(tokens) - seq_len), stride))
                # Include a window anchored to the very end
                if len(tokens) > seq_len + 1:
                    last_start = len(tokens) - seq_len - 1
                    if not starts or starts[-1] < last_start:
                        starts.append(last_start)

                for start in starts:
                    end    = start + seq_len + 1
                    window = tokens[start:end]

                    # Pad if shorter than seq_len+1
                    if len(window) < seq_len + 1:
                        pad    = np.full(seq_len + 1 - len(window), PAD_TOKEN, dtype=np.int64)
                        window = np.concatenate([window, pad])
                    window = window.astype(np.int64)

                    if use_theory:
                        tw = theory_arr[start:end]
                        if len(tw) < seq_len + 1:
                            pad_rows = np.tile(
                                _THEORY_UNKNOWN_ROW, (seq_len + 1 - len(tw), 1)
                            )
                            tw = np.concatenate([tw, pad_rows], axis=0)
                        self._items.append((window, tw.astype(np.int16), composer_id))
                    else:
                        self._items.append((window, composer_id))

    def __len__(self) -> int:
        return len(self._items)

    def __getitem__(self, idx: int):
        if self.use_theory:
            window, tw, composer_id = self._items[idx]
            x  = torch.from_numpy(window[:-1])       # (seq_len,)
            y  = torch.from_numpy(window[1:])        # (seq_len,)
            c  = torch.tensor(composer_id, dtype=torch.long)
            tx = torch.from_numpy(tw[:-1])           # (seq_len, 4)
            return x, y, c, tx
        else:
            window, composer_id = self._items[idx]
            x = torch.from_numpy(window[:-1])
            y = torch.from_numpy(window[1:])
            c = torch.tensor(composer_id, dtype=torch.long)
            return x, y, c
