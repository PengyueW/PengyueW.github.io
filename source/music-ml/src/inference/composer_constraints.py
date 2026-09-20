"""
Per-composer logit constraints for autoregressive sampling.

build_constraint_fn(composer_name) returns a stateful closure:
    fn(logits: Tensor[V], history: List[int]) → Tensor[V]

Called once per generation step in generate.py BEFORE top-k / nucleus filtering.
The closure adjusts log-probabilities (not probabilities) so the effects compose
additively with temperature scaling and top-k/p filtering.

All five constraint magnitudes are derived from ComposerMeta fields
defined in src/data/composer_meta.py, which were themselves derived from
theory_reference.md Parts 3–8.

Constraint summary:
  1. In-key bias                — in_key_bias
  2. Parallel fifth penalty     — allow_parallel_fifths
  3. Augmented second handling  — augmented_second_ok
  4. Modal cadence preference   — prefer_modal_cadence
  5. Dominant resolution        — dominant_res_strictness
"""

from __future__ import annotations

import torch
from typing import Callable, Dict, FrozenSet, List, Optional

from src.data.composer_meta import COMPOSER_META, ComposerMeta
from src.data.midi_parser import SOS_TOKEN, EOS_TOKEN, PAD_TOKEN

# ── Vocabulary ranges (must mirror midi_parser.py) ────────────────────────────
_NOTE_ON_MIN  = 0
_NOTE_ON_MAX  = 127
_NOTE_OFF_MIN = 128
_NOTE_OFF_MAX = 255
_TIME_SHIFT_MIN = 257
_TIME_SHIFT_MAX = 356
# Extended-vocabulary KEY tokens (only present when use_theory=True)
_KEY_TOKEN_MIN = 392
_KEY_TOKEN_MAX = 415   # 24 keys (key_id 0-23 → tokens 392-415)


# ── 1. Diatonic pitch-class sets for all 24 keys ─────────────────────────────

_MAJOR_INTERVALS = frozenset([0, 2, 4, 5, 7, 9, 11])
_MINOR_INTERVALS = frozenset([0, 2, 3, 5, 7, 8, 10])  # natural minor

def _build_diatonic_sets() -> Dict[int, FrozenSet[int]]:
    """
    Returns dict: key_id (0-23) → frozenset of 7 diatonic pitch classes (0-11).
    key_id = root * 2 + mode  (root: C=0..B=11, mode: major=0, minor=1)
    """
    sets = {}
    for root in range(12):
        for mode in range(2):
            intervals = _MAJOR_INTERVALS if mode == 0 else _MINOR_INTERVALS
            pcs = frozenset((root + i) % 12 for i in intervals)
            sets[root * 2 + mode] = pcs
    return sets

DIATONIC_SETS: Dict[int, FrozenSet[int]] = _build_diatonic_sets()

# Tonic, third, fifth pitch classes for each key (for dominant resolution boost)
_MAJOR_TRIAD = [0, 4, 7]
_MINOR_TRIAD = [0, 3, 7]

def _tonic_triad_pcs(key_id: int) -> FrozenSet[int]:
    root = key_id // 2
    mode = key_id %  2
    triad = _MAJOR_TRIAD if mode == 0 else _MINOR_TRIAD
    return frozenset((root + i) % 12 for i in triad)

def _dominant_root_pc(key_id: int) -> int:
    """Return the pitch class of the dominant root (scale degree 5)."""
    return (key_id // 2 + 7) % 12

def _leading_tone_pc(key_id: int) -> int:
    """Return the pitch class of the leading tone (scale degree 7)."""
    root = key_id // 2
    mode = key_id % 2
    # Major: leading tone = root + 11; minor (harmonic): root + 11
    return (root + 11) % 12

def _subtonic_root_pc(key_id: int) -> int:
    """Return the pitch class of ♭VII root (a whole step below tonic)."""
    return (key_id // 2 - 2) % 12


# ── 2. History parsing helpers ────────────────────────────────────────────────

def _recent_note_on_pitches(history: List[int], n: int = 24) -> List[int]:
    """Return pitches of the last n NOTE_ON tokens (most recent first)."""
    pitches = []
    for tok in reversed(history):
        if _NOTE_ON_MIN <= tok <= _NOTE_ON_MAX:
            pitches.append(tok)
            if len(pitches) >= n:
                break
    return pitches


def _last_note_on_pitch(history: List[int]) -> Optional[int]:
    """Return pitch of the single most recent NOTE_ON token, or None."""
    for tok in reversed(history):
        if _NOTE_ON_MIN <= tok <= _NOTE_ON_MAX:
            return tok
    return None


def _last_two_note_on_pitches(history: List[int]) -> tuple[Optional[int], Optional[int]]:
    """
    Return (most_recent_pitch, second_most_recent_pitch) as a pair.
    Either may be None if fewer than 2 NOTE_ON tokens exist in history.
    """
    found = []
    for tok in reversed(history):
        if _NOTE_ON_MIN <= tok <= _NOTE_ON_MAX:
            found.append(tok)
            if len(found) == 2:
                break
    p0 = found[0] if len(found) > 0 else None
    p1 = found[1] if len(found) > 1 else None
    return p0, p1


def _last_simultaneity(history: List[int], lookback: int = 40) -> List[int]:
    """
    Return pitches of the most recent simultaneity group — all NOTE_ON tokens
    between the most recent TIME_SHIFT and the one before it.
    Uses the last `lookback` tokens to bound the search.
    """
    window = history[-lookback:]
    # Find all TIME_SHIFT positions
    shift_positions = [
        i for i, t in enumerate(window)
        if _TIME_SHIFT_MIN <= t <= _TIME_SHIFT_MAX
    ]
    if len(shift_positions) < 1:
        # No time shifts found — return all NOTE_ON tokens
        return [t for t in window if _NOTE_ON_MIN <= t <= _NOTE_ON_MAX]

    last_shift = shift_positions[-1]
    if len(shift_positions) >= 2:
        prev_shift = shift_positions[-2]
    else:
        prev_shift = -1

    group = [
        t for t in window[prev_shift + 1: last_shift]
        if _NOTE_ON_MIN <= t <= _NOTE_ON_MAX
    ]
    return group


def _second_last_simultaneity(history: List[int], lookback: int = 80) -> List[int]:
    """Return pitches of the simultaneity group before the most recent one."""
    window = history[-lookback:]
    shift_positions = [
        i for i, t in enumerate(window)
        if _TIME_SHIFT_MIN <= t <= _TIME_SHIFT_MAX
    ]
    if len(shift_positions) < 2:
        return []
    last_shift = shift_positions[-1]
    prev_shift = shift_positions[-2]
    if len(shift_positions) >= 3:
        pprev_shift = shift_positions[-3]
    else:
        pprev_shift = -1

    group = [
        t for t in window[pprev_shift + 1: prev_shift]
        if _NOTE_ON_MIN <= t <= _NOTE_ON_MAX
    ]
    return group


# ── 3. Key estimation ─────────────────────────────────────────────────────────

def _estimate_key(history: List[int], n_notes: int = 24) -> Optional[int]:
    """
    Estimate the current key_id (0-23) from history.

    Strategy:
      1. Scan the last 60 tokens for explicit KEY tokens (extended vocab 392-415).
         If found, return the most recent one directly.
      2. Fall back to pitch-class frequency: count pitch classes among the last
         n_notes NOTE_ON tokens, return the key_id whose diatonic set covers
         the most weight.  Returns None if fewer than 4 NOTE_ON tokens seen.
    """
    # Strategy 1: explicit KEY token from theory fine-tuned model
    for tok in reversed(history[-60:]):
        if _KEY_TOKEN_MIN <= tok <= _KEY_TOKEN_MAX:
            return tok - _KEY_TOKEN_MIN   # 0-23

    # Strategy 2: pitch-class frequency
    pitches = _recent_note_on_pitches(history, n_notes)
    if len(pitches) < 4:
        return None

    pc_weight = [0.0] * 12
    for i, p in enumerate(pitches):
        # Weight recent notes more heavily
        w = 1.0 / (1.0 + i * 0.1)
        pc_weight[p % 12] += w

    best_key   = 0
    best_score = -1.0
    for key_id in range(24):
        score = sum(pc_weight[pc] for pc in DIATONIC_SETS[key_id])
        if score > best_score:
            best_score = score
            best_key   = key_id

    return best_key


# ── Constraint 1: In-key bias ─────────────────────────────────────────────────

def _apply_in_key_bias(
    logits: torch.Tensor,
    key_id: int,
    bias:   float,
) -> torch.Tensor:
    """
    Add +bias to diatonic NOTE_ON tokens, -bias to chromatic NOTE_ON tokens.
    Only NOTE_ON tokens (indices 0-127) are affected; all other tokens unchanged.
    """
    diatonic = DIATONIC_SETS[key_id]
    for pitch in range(128):
        pc = pitch % 12
        if pc in diatonic:
            logits[pitch] += bias
        else:
            logits[pitch] -= bias
    return logits


# ── Constraint 2: Parallel fifth handling ─────────────────────────────────────

def _penalise_parallel_fifths(
    logits:  torch.Tensor,
    history: List[int],
    penalty: float = 1.5,
) -> torch.Tensor:
    """
    Penalise NOTE_ON candidates that would create a parallel perfect fifth
    with a recent voice pair.

    Heuristic: compare the last two simultaneity groups.  For every pair of
    pitches in the previous group whose interval = 7 semitones (P5), find
    the transposition delta to the most recent group's pitches, then penalise
    NOTE_ON candidates whose combination with a recent pitch would form
    another P5 at the same transposition delta.
    """
    prev_group  = _last_simultaneity(history)
    pprev_group = _second_last_simultaneity(history)

    if not prev_group or not pprev_group:
        return logits

    # Collect (delta, prev_pitch) pairs where pprev pair was a P5
    dangerous_deltas = set()
    for p1 in pprev_group:
        for p2 in pprev_group:
            if p1 == p2:
                continue
            if abs(p1 - p2) == 7:          # P5
                # For each voice in prev_group, note the transposition delta
                for q in prev_group:
                    delta = q - p1
                    dangerous_deltas.add((delta, q))

    # Penalise candidate pitches that would form another P5 with dangerous notes
    for pitch in range(128):
        for (delta, prev_pitch) in dangerous_deltas:
            if abs(pitch - prev_pitch) == 7:    # would create a new P5
                logits[pitch] -= penalty
                break
    return logits


def _encourage_parallel_motion(
    logits:  torch.Tensor,
    history: List[int],
    bonus:   float = 0.15,
) -> torch.Tensor:
    """
    For Debussy / Mussorgsky / Grieg: small bonus for maintaining the most
    recent chord's interval structure (encourages parallel chord planing).
    """
    prev_group = _last_simultaneity(history)
    if len(prev_group) < 2:
        return logits

    # Encourage the same internal intervals in the next simultaneity
    intervals = sorted(set(abs(a - b) for a in prev_group for b in prev_group if a != b))
    for pitch in range(128):
        for ref in prev_group:
            if abs(pitch - ref) in intervals:
                logits[pitch] += bonus
                break
    return logits


# ── Constraint 3: Augmented second handling ───────────────────────────────────

def _handle_augmented_second(
    logits:  torch.Tensor,
    history: List[int],
    ok:      bool,
    penalty: float = 0.8,
    bonus:   float = 0.2,
) -> torch.Tensor:
    """
    Penalise or encourage NOTE_ON tokens that form a ±3 semitone melodic
    step from the last melody note.

    A ±3 semitone step is the pitch distance of an augmented second
    (spelled as a 2nd but sounding like a minor third).  We use pitch
    distance as a proxy because distinguishing A2 from m3 requires
    spelled-note tracking that is beyond token-level analysis.

    When ok=False (Classical, strict Baroque): apply `penalty`.
    When ok=True  (Russian, Spanish, Polish mazurka, Hungarian): apply `bonus`.
    """
    prev_pitch = _last_note_on_pitch(history)
    if prev_pitch is None:
        return logits

    for pitch in range(128):
        dist = abs(pitch - prev_pitch)
        if dist == 3:
            if ok:
                logits[pitch] += bonus
            else:
                logits[pitch] -= penalty
    return logits


# ── Constraint 4: Modal cadence preference ────────────────────────────────────

def _boost_modal_cadence(
    logits: torch.Tensor,
    key_id: int,
    meta:   ComposerMeta,
    bonus:  float = 0.30,
) -> torch.Tensor:
    """
    For nationalist composers (prefer_modal_cadence=True):
    boost NOTE_ON tokens whose pitch class matches the ♭VII root (a whole
    step below the tonic), reinforcing ♭VII→I cadences over V→I cadences.

    The dominant root is simultaneously penalised by a small amount to
    discourage the Classical authentic cadence in favour of the modal one.
    """
    flat7_pc   = _subtonic_root_pc(key_id)   # ♭VII root pitch class
    dom_pc     = _dominant_root_pc(key_id)   # V root pitch class

    for pitch in range(128):
        pc = pitch % 12
        if pc == flat7_pc:
            logits[pitch] += bonus
        elif pc == dom_pc:
            # Gently de-emphasise the dominant root (not fully muted)
            logits[pitch] -= bonus * 0.4

    return logits


# ── Constraint 5: Dominant resolution strictness ──────────────────────────────

def _apply_dominant_resolution(
    logits:    torch.Tensor,
    history:   List[int],
    key_id:    int,
    strictness: float,
) -> torch.Tensor:
    """
    After detecting dominant-context tokens in recent history, boost
    NOTE_ON tokens belonging to the tonic triad.

    Dominant context is detected by checking whether the last 12 NOTE_ON
    pitches are predominantly scale degrees 5, 7, and 2 of the current key
    (the components of the dominant seventh chord V7).

    The boost magnitude = strictness × 0.5 log-prob units on tonic triad pitches.
    At strictness ≥ 0.8 (Baroque / Classical) this creates a strong pull toward
    I.  At strictness < 0.2 (Wagner / Debussy) the boost is negligible.
    """
    if strictness < 0.02:
        return logits   # fast path — essentially no enforcement

    pitches = _recent_note_on_pitches(history, 12)
    if len(pitches) < 3:
        return logits

    root   = key_id // 2
    mode   = key_id %  2

    # Dominant seventh pitch classes: V-root (5), leading tone (7), 2, chord-7th (4)
    dom_pcs = frozenset([
        _dominant_root_pc(key_id),             # scale degree 5
        _leading_tone_pc(key_id),              # scale degree 7
        (root + 2) % 12,                       # scale degree 2 (ninth of V)
    ])

    # Count how many recent notes are "dominant flavoured"
    dom_count = sum(1 for p in pitches if p % 12 in dom_pcs)
    dom_ratio = dom_count / len(pitches)

    if dom_ratio < 0.35:
        return logits   # not in a dominant context — no resolution push

    # Apply boost to tonic triad pitch classes
    tonic_pcs = _tonic_triad_pcs(key_id)
    boost     = strictness * 0.5 * dom_ratio   # scales with how dominant the context is

    for pitch in range(128):
        if pitch % 12 in tonic_pcs:
            logits[pitch] += boost

    return logits


# ── Public API ────────────────────────────────────────────────────────────────

def build_constraint_fn(
    composer_name: str,
) -> Optional[Callable[[torch.Tensor, List[int]], torch.Tensor]]:
    """
    Return a stateful constraint closure for `composer_name`, or None if the
    composer is not in COMPOSER_META.

    The returned closure has signature:
        fn(logits: Tensor[V], history: List[int]) -> Tensor[V]

    It is called once per generation step and adjusts logits before top-k/p
    filtering.  The function is stateless between calls; all context is derived
    from `history` at each invocation.

    Args:
        composer_name : Exact key from composer_map.json / COMPOSER_META.

    Returns:
        Callable, or None if composer_name is unknown.
    """
    meta = COMPOSER_META.get(composer_name)
    if meta is None:
        return None

    # Cache values that don't change between calls
    in_key_bias             = meta.in_key_bias
    allow_p5                = meta.allow_parallel_fifths
    aug2_ok                 = meta.augmented_second_ok
    prefer_modal            = meta.prefer_modal_cadence
    dom_strict              = meta.dominant_res_strictness

    def constraint_fn(logits: torch.Tensor, history: List[int]) -> torch.Tensor:
        logits = logits.clone()

        # Estimate current key — shared by several constraints below
        key_id = _estimate_key(history) if (in_key_bias > 0 or prefer_modal or dom_strict > 0) else None

        # ── 1. In-key bias ────────────────────────────────────────────────────
        if key_id is not None and in_key_bias > 0.01:
            logits = _apply_in_key_bias(logits, key_id, in_key_bias)

        # ── 2. Parallel fifth handling ────────────────────────────────────────
        if allow_p5:
            logits = _encourage_parallel_motion(logits, history)
        else:
            logits = _penalise_parallel_fifths(logits, history)

        # ── 3. Augmented second handling ──────────────────────────────────────
        logits = _handle_augmented_second(logits, history, aug2_ok)

        # ── 4. Modal cadence preference ───────────────────────────────────────
        if prefer_modal and key_id is not None:
            logits = _boost_modal_cadence(logits, key_id, meta)

        # ── 5. Dominant resolution strictness ────────────────────────────────
        if dom_strict > 0.02 and key_id is not None:
            logits = _apply_dominant_resolution(logits, history, key_id, dom_strict)

        return logits

    return constraint_fn


# ─────────────────────────────────────────────────────────────────────────────
# CONTINUATION NOTES FOR PART 3
# ─────────────────────────────────────────────────────────────────────────────
#
# Part 3 is entirely in src/training/trainer.py.
# No new files are needed — only trainer.py changes.
#
# ── What Part 3 must do ───────────────────────────────────────────────────────
#
# Currently the auxiliary chord and key losses are computed with a single
# scalar weight (cfg.theory_loss_weight) applied identically to all samples
# in every batch.  This means Bach and Debussy receive the same chord-label
# supervision weight, which is wrong:
#   - Bach's chord labels are reliable and informative (strict tonal harmony)
#   - Debussy's chord labels are noise (parallel chords, whole-tone harmony)
#   - Giving both the same weight 0.1 wastes Bach capacity and corrupts Debussy.
#
# Part 3 must replace the scalar with a per-sample tensor derived from
# ComposerMeta.chord_aux_weight and ComposerMeta.key_aux_weight.
#
# ── Exact implementation steps ────────────────────────────────────────────────
#
# STEP A — In Trainer.__init__(), after building _era_lookup, build two more
#          lookup tensors indexed by composer_id:
#
#   from src.data.composer_meta import COMPOSER_META
#
#   n = len(composer_map)
#   self._chord_weight_lookup = torch.ones(n)
#   self._key_weight_lookup   = torch.ones(n)
#   for name, cid in composer_map.items():
#       m = COMPOSER_META.get(name)
#       if m is not None:
#           self._chord_weight_lookup[cid] = m.chord_aux_weight
#           self._key_weight_lookup[cid]   = m.key_aux_weight
#
# STEP B — Modify _loss() to accept composer_ids and apply per-sample weights.
#          Signature change:
#
#   def _loss(self, logits, targets,
#             chord_logits=None, chord_labels=None,
#             key_logits=None,   key_labels=None,
#             composer_ids=None):           ← ADD THIS ARGUMENT
#
#   Inside the auxiliary-loss block:
#
#   B, T, V = logits.shape
#   w = self.cfg.theory_loss_weight
#
#   # Per-sample chord weights: shape (B,)
#   if composer_ids is not None:
#       chord_w = self._chord_weight_lookup[composer_ids.cpu()].to(logits.device)
#       key_w   = self._key_weight_lookup[composer_ids.cpu()].to(logits.device)
#   else:
#       chord_w = torch.ones(B, device=logits.device)
#       key_w   = torch.ones(B, device=logits.device)
#
#   # Compute per-TOKEN losses with reduction='none', shape (B*T,)
#   chord_loss_flat = nn.functional.cross_entropy(
#       chord_logits.reshape(B * T, chord_logits.size(-1)),
#       chord_labels.reshape(B * T).long(),
#       ignore_index=CHORD_UNKNOWN,
#       reduction='none',
#   )                                           # shape (B*T,)
#   chord_loss_per_sample = chord_loss_flat.reshape(B, T).mean(dim=1)  # (B,)
#   chord_loss = (chord_loss_per_sample * chord_w).mean()
#
#   key_loss_flat = nn.functional.cross_entropy(
#       key_logits.reshape(B * T, key_logits.size(-1)),
#       key_labels.reshape(B * T).long(),
#       ignore_index=KEY_UNKNOWN,
#       reduction='none',
#   )
#   key_loss_per_sample = key_loss_flat.reshape(B, T).mean(dim=1)
#   key_loss = (key_loss_per_sample * key_w).mean()
#
#   return main_loss + w * chord_loss + w * 0.5 * key_loss
#
# STEP C — In _run_epoch(), pass composer_ids to _loss():
#
#   loss = self._loss(
#       logits, y,
#       chord_logits, chord_ids,
#       key_logits,   key_ids,
#       composer_ids=composer,       ← ADD THIS
#   )
#
# ── Why this matters ──────────────────────────────────────────────────────────
#
# The per-sample weighting means:
#   - A Bach batch contributes chord_loss × 1.0  and key_loss × 1.0
#   - A Debussy batch contributes chord_loss × 0.15 and key_loss × 0.10
#   - A Berg batch contributes chord_loss × 0.05 and key_loss × 0.02
#   - A mixed batch computes the weighted mean across samples automatically.
#
# This directly implements the theory_reference.md §26 ML training map:
# "the 68×12 constraint weight matrix" (here simplified to the two most
# impactful dimensions: chord supervision and key supervision).
#
# ── Test plan for Part 3 ─────────────────────────────────────────────────────
# After the three steps above, verify with:
#
#   python -c "
#   import torch
#   from src.training.config import TrainConfig
#   from src.training.trainer import Trainer
#   import json
#   with open('data/processed/composer_map.json') as f:
#       cmap = json.load(f)
#   cfg = TrainConfig(use_theory=True, use_era=True, num_epochs=1)
#   t = Trainer(cfg, cmap)
#   # Check that the lookup tensors exist and have the right shape
#   assert t._chord_weight_lookup.shape == (len(cmap),)
#   assert t._key_weight_lookup.shape   == (len(cmap),)
#   # Bach should have weight 1.0; Debussy should have weight 0.15
#   bach_id    = cmap['Johann Sebastian Bach']
#   debussy_id = cmap['Claude Debussy']
#   assert t._chord_weight_lookup[bach_id].item()    == 1.0
#   assert t._chord_weight_lookup[debussy_id].item() == 0.15
#   print('Part 3 smoke test passed.')
#   "
#
# ── After Part 3 is complete ─────────────────────────────────────────────────
# Update CLAUDE.md to mark all three composer-style-tuning features complete.
# Update guide.md "Current Phase" checklist for Phase 1.5.
# Update the Kaggle notebook (train_kaggle.ipynb) to pass composer_name=COMPOSER
# into the generate() call in Step 7 so the sampler constraints take effect.
# The notebook's Step 4b config should also set use_era=True in TrainConfig.
