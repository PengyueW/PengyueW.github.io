"""
Music generation (inference) module.

Given a trained checkpoint, a composer ID, and generation parameters,
produces a MIDI file of new piano music.

Sampling strategies supported:
  - Temperature scaling
  - Top-k filtering
  - Top-p (nucleus) filtering
  - Per-composer style constraints (Part 2 — see composer_constraints.py)
"""

import torch
import torch.nn.functional as F
from typing import List, Optional

from src.model.transformer import MusicTransformer
from src.data.midi_parser import (
    SOS_TOKEN, EOS_TOKEN, PAD_TOKEN, VOCAB_SIZE,
    events_to_midi,
)
from src.data.composer_meta import get_era_id, NUM_ERAS
from src.data.theory_extractor import KEY_UNKNOWN, CHORD_UNKNOWN, BEAT_UNKNOWN


def _finalize_tokens(tokens: List[int]) -> List[int]:
    """
    Close any NOTE_ON events that never received a NOTE_OFF so no notes
    hang open after the piece ends.  No silence is appended — the natural
    decay of the final chord is the ending.
    """
    active: set = set()
    for tok in tokens:
        if 0 <= tok <= 127:      # NOTE_ON
            active.add(tok)
        elif 128 <= tok <= 255:  # NOTE_OFF
            active.discard(tok - 128)

    if not active:
        return list(tokens)

    result = list(tokens)
    result.append(268)              # TIME_SHIFT ~120 ms gap before release
    for pitch in sorted(active):
        result.append(128 + pitch)  # NOTE_OFF
    return result


def _top_k_top_p_filter(logits: torch.Tensor, top_k: int, top_p: float) -> torch.Tensor:
    """Apply top-k and top-p (nucleus) filtering to logits."""
    if top_k > 0:
        k_val = torch.topk(logits, min(top_k, logits.size(-1))).values[..., -1, None]
        logits = logits.masked_fill(logits < k_val, float('-inf'))

    if top_p < 1.0:
        sorted_logits, sorted_idx = torch.sort(logits, descending=True)
        cum_probs = torch.cumsum(F.softmax(sorted_logits, dim=-1), dim=-1)
        remove_mask = (cum_probs - F.softmax(sorted_logits, dim=-1)) > top_p
        sorted_logits[remove_mask] = float('-inf')
        logits = torch.zeros_like(logits).scatter_(-1, sorted_idx, sorted_logits)

    return logits


def generate(
    model:            MusicTransformer,
    composer_id:      int,
    device:           torch.device,
    max_tokens:       int = 1024,
    temperature:      float = 1.0,
    top_k:            int = 50,
    top_p:            float = 0.95,
    prompt_tokens:    Optional[List[int]] = None,
    context_window:   Optional[int] = None,
    composer_name:    Optional[str] = None,   # used to derive era_id and constraints
    min_tokens:       int = 128,              # suppress EOS until this many tokens generated
) -> List[int]:
    """
    Autoregressively sample a token sequence from the model.

    Args:
        model:          Trained MusicTransformer (eval mode).
        composer_id:    Integer composer label.
        device:         Torch device.
        max_tokens:     Maximum number of tokens to generate.
        temperature:    Sampling temperature (lower = more deterministic).
        top_k:          Keep only the top-k most likely tokens.
        top_p:          Nucleus sampling probability threshold.
        prompt_tokens:  Optional list of tokens to condition generation on.
                        SOS is prepended automatically.
        context_window: Maximum tokens fed to the model at each step.
        composer_name:  Composer name string — used to look up era_id for era-
                        conditioned models and (in Part 2) sampler constraints.
                        If omitted, era conditioning is skipped even when the
                        model has use_era=True.

    Returns:
        List of generated event token integers (including SOS, excluding EOS).
    """
    model.eval()

    max_ctx  = context_window or model.pos_enc.pe.size(1)
    history  = [SOS_TOKEN] + (prompt_tokens or [])
    c_tensor = torch.tensor([composer_id], dtype=torch.long, device=device)

    # Derive era tensor if the model was trained with era conditioning
    era_tensor = None
    if getattr(model, 'use_era', False) and composer_name is not None:
        eid = get_era_id(composer_name)
        era_tensor = torch.tensor([eid], dtype=torch.long, device=device)

    # Theory conditioning: pass all-unknown sentinels when use_theory=True so the
    # model receives the same conditioning it saw during training for unlabelled
    # pieces.  Without these, the model is missing embeddings it relied on and
    # produces degenerate (all-TIME_SHIFT / all-NOTE_OFF) output.
    key_tensor   = None
    chord_tensor = None
    beat_tensor  = None
    if getattr(model, 'use_theory', False):
        key_tensor   = None   # will be expanded per-step in the loop
        chord_tensor = None
        beat_tensor  = None
        _theory_key   = KEY_UNKNOWN
        _theory_chord = CHORD_UNKNOWN
        _theory_beat  = BEAT_UNKNOWN

    # ── Part 2 hook: per-composer logit modifier (populated in Part 2) ────────
    # When composer_constraints.py exists it is imported here and the function
    # apply_composer_constraints() is called inside the sampling loop.
    # For now this is a no-op placeholder so the rest of the code is clean.
    _constraint_fn = None
    try:
        from src.inference.composer_constraints import build_constraint_fn
        if composer_name is not None:
            _constraint_fn = build_constraint_fn(composer_name)
    except ImportError:
        pass   # composer_constraints.py not yet present — Part 2 will add it
    # ─────────────────────────────────────────────────────────────────────────

    with torch.no_grad():
        for _ in range(max_tokens):
            window = history[-max_ctx:]
            x      = torch.tensor([window], dtype=torch.long, device=device)
            T      = x.size(1)

            # Build per-step theory tensors (all-unknown sentinel, shape (1, T))
            if getattr(model, 'use_theory', False):
                key_t   = torch.full((1, T), _theory_key,   dtype=torch.long, device=device)
                chord_t = torch.full((1, T), _theory_chord, dtype=torch.long, device=device)
                beat_t  = torch.full((1, T), _theory_beat,  dtype=torch.long, device=device)
            else:
                key_t = chord_t = beat_t = None

            logits = model(x, c_tensor, era_ids=era_tensor,
                           key_ids=key_t, chord_ids=chord_t, beat_ids=beat_t)   # (1, T, V)
            next_logits = logits[0, -1, :] / max(temperature, 1e-8)

            next_logits[PAD_TOKEN] = float('-inf')
            next_logits[SOS_TOKEN] = float('-inf')

            # Suppress EOS until min_tokens have been generated (mask before
            # top-k/p so wasted EOS draws can't exhaust the iteration budget)
            generated = len(history) - 1 - len(prompt_tokens or [])
            if generated < min_tokens:
                next_logits[EOS_TOKEN] = float('-inf')
            else:
                # Cadential landing: in the final 256 tokens before max_tokens,
                # progressively boost tonic-triad NOTE_ON tokens and EOS so the
                # model resolves to the home key rather than cutting off mid-phrase.
                tokens_remaining = max_tokens - generated
                if tokens_remaining < 256:
                    try:
                        from src.inference.composer_constraints import (
                            _estimate_key, _tonic_triad_pcs,
                        )
                        key_id = _estimate_key(history)
                        if key_id is not None:
                            fade  = 1.0 - tokens_remaining / 256  # 0 → 1
                            boost = 3.5 * fade
                            tonic = _tonic_triad_pcs(key_id)
                            for p in range(128):
                                if p % 12 in tonic:
                                    next_logits[p] += boost
                            next_logits[EOS_TOKEN] += boost * 0.8
                    except Exception:
                        pass

            # Note-drought rescue: if no NOTE_ON has appeared yet, apply a
            # progressive boost so the model breaks out of a TIME_SHIFT loop.
            # Starts after 8 non-note steps; ramps to +2.5 logits by step ~25.
            if not any(0 <= t <= 127 for t in history):
                drought = len(history) - 1
                if drought >= 8:
                    next_logits[:128] += min(0.15 * (drought - 8), 2.5)

            # Apply per-composer style constraints (Part 2)
            if _constraint_fn is not None:
                next_logits = _constraint_fn(next_logits, history)

            next_logits = _top_k_top_p_filter(next_logits, top_k, top_p)
            probs       = F.softmax(next_logits, dim=-1)
            next_token  = torch.multinomial(probs, num_samples=1).item()

            if next_token == EOS_TOKEN:
                break
            history.append(next_token)

    return _finalize_tokens(history)


def load_model_from_checkpoint(checkpoint_path: str, device: torch.device) -> tuple:
    """
    Load a MusicTransformer and its composer_map from a checkpoint file.

    Returns:
        (model, composer_map, config)
    """
    ckpt         = torch.load(checkpoint_path, map_location=device, weights_only=False)
    cfg          = ckpt['config']
    composer_map = ckpt['composer_map']

    model = MusicTransformer(
        vocab_size=cfg.vocab_size,
        d_model=cfg.d_model,
        n_heads=cfg.n_heads,
        n_layers=cfg.n_layers,
        d_ff=cfg.d_ff,
        dropout=0.0,
        max_seq_len=cfg.max_seq_len,
        num_composers=len(composer_map),
        composer_embed_dim=cfg.composer_embed_dim,
        use_theory=getattr(cfg, 'use_theory', False),
        use_era=getattr(cfg, 'use_era',    False),
    )
    model.load_state_dict(ckpt['model_state'], strict=False)
    model.to(device)
    model.eval()

    return model, composer_map, cfg


# ═════════════════════════════════════════════════════════════════════════════
# CONTINUATION NOTES FOR PART 2
# ═════════════════════════════════════════════════════════════════════════════
#
# Part 2 must create:  src/inference/composer_constraints.py
# Part 2 must modify:  this file is already wired for it (see _constraint_fn hook)
#
# ── What composer_constraints.py must implement ────────────────────────────
#
# The function build_constraint_fn(composer_name: str) -> Callable | None
# returns a closure that takes (logits: Tensor[V], history: List[int]) → Tensor[V].
# It applies per-composer logit adjustments BEFORE top-k/nucleus filtering.
#
# The five constraints to implement, all derived from COMPOSER_META fields:
#
# 1. IN-KEY BIAS  (field: in_key_bias)
# ─────────────────────────────────────
# For NOTE_ON tokens (vocab indices 0-127, each = MIDI pitch 0-127):
#   - detect the current key from the last KEY token in `history` if present,
#     otherwise use the globally most likely key for this composer (from meta).
#   - diatonic pitches (pitch % 12 in DIATONIC_SET[key_id]): add +in_key_bias
#   - chromatic pitches (pitch % 12 NOT in set):             add -in_key_bias
# The adjustment is linear (not softmax); it shifts log-probabilities.
#
# Helper needed:
#   DIATONIC_SETS: dict[key_id (0-23)] → frozenset of 7 pitch classes (0-11)
#   key_id = root * 2 + mode  (root: C=0..B=11, mode: major=0, minor=1)
#   Major scale semitones: [0,2,4,5,7,9,11]
#   Natural minor semitones: [0,2,3,5,7,8,10]
#   Apply rotation: diatonic_pcs = frozenset((root + s) % 12 for s in scale)
#
# 2. PARALLEL FIFTH PERMISSION  (field: allow_parallel_fifths, default False)
# ────────────────────────────────────────────────────────────────────────────
# When allow_parallel_fifths=False (most composers):
#   - Track the last two simultaneous NOTE_ON events in history (approximated
#     as the last NOTE_ON and the NOTE_ON immediately before the last
#     TIME_SHIFT token — i.e., the previous chord).
#   - If the previous chord contained notes A and B (interval = 7 semitones = P5),
#     penalise NOTE_ON tokens C and D where C-A == D-B == same semitone delta
#     and the new interval C-D is also 7 semitones.
#   - Penalty magnitude: -1.5 log-prob units on the offending tokens.
# When allow_parallel_fifths=True (Debussy, Mussorgsky, Grieg, Janáček, Berg):
#   - No penalty; optionally add a small bonus (+0.1) to encourage parallel motion.
#
# 3. AUGMENTED SECOND OK  (field: augmented_second_ok)
# ──────────────────────────────────────────────────────
# When augmented_second_ok=False (Baroque, Classical, most Romantic):
#   - Penalise NOTE_ON tokens whose pitch forms an augmented second (3 semitones
#     spelled as a second) with the immediately preceding melody note.
#   - Detection: last NOTE_ON in history = prev_pitch.
#     Candidate NOTE_ON pitches where abs(pitch - prev_pitch) == 3 but the
#     letter names span a second (i.e., not a minor third) → penalise by -0.8.
#     NOTE: This distinction requires spelled pitch tracking (hard).
#     Simplification: penalise all +3 or -3 semitone melodic intervals when
#     they occur in a context where the augmented second is unlikely (non-
#     nationalist, non-Baroque-chromaticism composer).
# When augmented_second_ok=True (Russian, Spanish, Polish mazurka, Hungarian):
#   - No penalty; add +0.2 bonus to reinforce the style marker.
#
# 4. MODAL CADENCE PREFERENCE  (field: prefer_modal_cadence)
# ────────────────────────────────────────────────────────────
# When prefer_modal_cadence=True (Russian nationalists, Grieg, Janáček):
#   - Detect upcoming cadential context by inspecting recent CHORD tokens.
#     If the last few tokens suggest a dominant approach (e.g. last chord token
#     is a V-quality chord), boost ♭VII-quality NOTE_ON tokens over V-quality
#     ones to steer toward a ♭VII→I resolution instead of V→I.
#   - Practical proxy: boost NOTE_ON tokens for the pitch that is a whole step
#     below the current key's tonic (+0.3), which is the root of ♭VII.
#
# 5. DOMINANT RESOLUTION STRICTNESS  (field: dominant_res_strictness)
# ──────────────────────────────────────────────────────────────────────
# This is the most complex constraint. After a dominant chord has been
# sounding (detected from CHORD tokens in history), the probability of
# NOTE_ON tokens belonging to the tonic chord is boosted by:
#   boost = dominant_res_strictness * 0.5  (e.g. 0.95 → +0.475 on tonic notes)
# After a long sequence WITHOUT a dominant chord, this boost is zero.
# For Wagner/Debussy/Berg (dominant_res_strictness < 0.2): the boost is
# effectively zero, allowing endless unresolved dominant harmonies.
#
# ── CHORD token / KEY token vocabulary in history ────────────────────────
# history contains raw integer tokens. CHORD tokens live at 417-476 in the
# EXTENDED vocabulary (if the model was theory fine-tuned).
# In the BASE model (no theory), there are no CHORD tokens in history.
# composer_constraints.py must handle BOTH cases gracefully:
#   - If no theory tokens seen in last N history tokens → use statistical
#     heuristics (pitch-class frequency in recent NOTE_ON tokens to estimate key).
#   - If CHORD/KEY tokens are present → use them directly.
#
# ── Implementation skeleton ───────────────────────────────────────────────
#
# def build_constraint_fn(composer_name: str):
#     from src.data.composer_meta import COMPOSER_META
#     meta = COMPOSER_META.get(composer_name)
#     if meta is None:
#         return None
#
#     # Pre-compute diatonic sets for all 24 keys
#     DIATONIC = _build_diatonic_sets()
#
#     def constraint_fn(logits: torch.Tensor, history: list) -> torch.Tensor:
#         logits = logits.clone()
#         current_key = _estimate_key(history)           # int 0-23 or None
#
#         # 1. In-key bias
#         if current_key is not None and meta.in_key_bias > 0:
#             logits = _apply_in_key_bias(logits, current_key, meta.in_key_bias, DIATONIC)
#
#         # 2. Parallel fifth penalty
#         if not meta.allow_parallel_fifths:
#             logits = _penalise_parallel_fifths(logits, history)
#         elif meta.allow_parallel_fifths:
#             logits = _encourage_parallel_motion(logits, history)
#
#         # 3. Augmented second
#         logits = _handle_augmented_second(logits, history, meta.augmented_second_ok)
#
#         # 4. Modal cadence
#         if meta.prefer_modal_cadence and current_key is not None:
#             logits = _boost_modal_cadence(logits, current_key, meta)
#
#         # 5. Dominant resolution
#         if meta.dominant_res_strictness > 0 and current_key is not None:
#             logits = _apply_dominant_resolution(logits, history, current_key,
#                                                 meta.dominant_res_strictness)
#         return logits
#
#     return constraint_fn
#
# ── Test plan for Part 2 ──────────────────────────────────────────────────
# After implementing, verify with:
#   python -c "
#   import torch
#   from src.inference.composer_constraints import build_constraint_fn
#   fn = build_constraint_fn('Johann Sebastian Bach')
#   assert fn is not None, 'Bach should have constraints'
#   fn = build_constraint_fn('Claude Debussy')
#   assert fn is not None, 'Debussy should have constraints'
#   logits = torch.zeros(392)
#   adjusted = fn(logits, [390])  # history = [SOS]
#   assert adjusted is not logits, 'must return a modified tensor'
#   print('Part 2 smoke test passed.')
#   "
