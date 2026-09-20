"""
Theory label extraction from MIDI files using music21.

For each MIDI file, produces a per-token label array of shape (N, 4) dtype int16:
  col 0 — key_id     : 0-23  (root*2 + mode), 24 = unknown
  col 1 — chord_id   : 0-59  (root*5 + quality), 60 = unknown
  col 2 — beat_id    : 0-7   (beat position within bar), 8 = unknown
  col 3 — cadence_id : 0 = none, 1 = PAC, 2 = IAC, 3 = HC, 4 = DC, 5 = plagal

Root encoding (0-11): C=0, C#/Db=1, D=2, D#/Eb=3, E=4, F=5,
                       F#/Gb=6, G=7, G#/Ab=8, A=9, A#/Bb=10, B=11
Quality encoding (0-4): major=0, minor=1, diminished=2, augmented=3, dominant-seventh=4
Key encoding: key_id = root_id * 2 + (0 if major else 1)

Usage:
    from src.data.theory_extractor import extract_theory_labels
    import numpy as np
    tokens = np.load("piece.npy")
    labels = extract_theory_labels("piece.mid", tokens)   # shape (N, 4)
    np.save("piece_theory.npy", labels)
"""

import numpy as np
from typing import Optional

# ── Public constants (imported by dataset.py and trainer.py) ──────────────────
KEY_UNKNOWN   = 24
CHORD_UNKNOWN = 60
BEAT_UNKNOWN  = 8
CADENCE_NONE  = 0

NUM_KEYS    = 25   # 0-23 valid + 24 unknown
NUM_CHORDS  = 61   # 0-59 valid + 60 unknown
NUM_BEATS   = 9    # 0-7  valid + 8  unknown

# ── Internal lookup tables ─────────────────────────────────────────────────────
_ROOT_TO_ID = {
    'C': 0,  'C#': 1,  'D-': 1,
    'D': 2,  'D#': 3,  'E-': 3,
    'E': 4,  'E#': 5,  'F-': 4,
    'F': 5,  'F#': 6,  'G-': 6,
    'G': 7,  'G#': 8,  'A-': 8,
    'A': 9,  'A#': 10, 'B-': 10,
    'B': 11, 'B#': 0,  'C-': 11,
}

# Map music21 quality strings → 0-4 index
# Anything not listed defaults to CHORD_UNKNOWN
_QUALITY_TO_ID = {
    'major':              0,
    'minor':              1,
    'diminished':         2,
    'augmented':          3,
    'dominant-seventh':   4,
    # Treat extended/altered chords as their base quality
    'major-seventh':      0,
    'minor-seventh':      1,
    'half-diminished':    2,
    'diminished-seventh': 2,
    'augmented-seventh':  3,
    'major-ninth':        0,
    'minor-ninth':        1,
    'dominant-ninth':     4,
}

# TIME_SHIFT tokens occupy 257-356 in the vocabulary (n*10ms, n=1..100)
_TIME_SHIFT_MIN = 257
_TIME_SHIFT_MAX = 356


# ── Timestamp reconstruction ──────────────────────────────────────────────────

def tokens_to_timestamps_ms(tokens: np.ndarray) -> np.ndarray:
    """
    Reconstruct the absolute time (ms) at which each token fires by
    accumulating TIME_SHIFT tokens.  Non-TIME_SHIFT tokens inherit the
    current accumulated time.

    Returns float32 array of shape (len(tokens),).
    """
    timestamps = np.zeros(len(tokens), dtype=np.float32)
    t = 0.0
    for i, tok in enumerate(tokens):
        timestamps[i] = t
        if _TIME_SHIFT_MIN <= tok <= _TIME_SHIFT_MAX:
            t += (int(tok) - 256) * 10.0   # n × 10 ms
    return timestamps


# ── Core extraction ───────────────────────────────────────────────────────────

def extract_theory_labels(
    midi_path: str,
    tokens: np.ndarray,
    token_timestamps_ms: Optional[np.ndarray] = None,
) -> np.ndarray:
    """
    Analyse a MIDI file with music21 and produce per-token theory labels
    aligned with the given token sequence.

    Args:
        midi_path           : Path to the source .mid / .midi file.
        tokens              : int64 token array produced by midi_to_events().
        token_timestamps_ms : Optional pre-computed timestamps (float32, shape N).
                              If None they are computed from `tokens`.

    Returns:
        np.ndarray of shape (len(tokens), 4), dtype int16.
        All-unknown rows are returned on any music21 parse failure so that
        the dataset remains usable even when analysis fails.
    """
    try:
        from music21 import converter
    except ImportError:
        raise ImportError(
            "music21 is required for theory extraction.\n"
            "Install it with:  pip install music21"
        )

    N = len(tokens)
    labels = np.empty((N, 4), dtype=np.int16)
    labels[:, 0] = KEY_UNKNOWN
    labels[:, 1] = CHORD_UNKNOWN
    labels[:, 2] = BEAT_UNKNOWN
    labels[:, 3] = CADENCE_NONE

    if N == 0:
        return labels

    if token_timestamps_ms is None:
        token_timestamps_ms = tokens_to_timestamps_ms(tokens)
    token_times = token_timestamps_ms.astype(np.float64)

    # Total duration encoded in the token stream (ms)
    token_dur_ms = float(token_times[-1])

    # ── Parse MIDI ────────────────────────────────────────────────────────────
    try:
        score = converter.parse(midi_path)
    except Exception:
        return labels

    # ── Tempo: first MetronomeMark or default 120 BPM ────────────────────────
    bpm = 120.0
    for mm in score.flat.getElementsByClass('MetronomeMark'):
        try:
            bpm = float(mm.number)
        except Exception:
            pass
        break
    ms_per_quarter = 60_000.0 / bpm

    # Scale factor: maps music21 quarter-length offsets → token-stream ms
    try:
        score_dur_ql = float(score.duration.quarterLength)
    except Exception:
        score_dur_ql = 0.0
    score_dur_ms = score_dur_ql * ms_per_quarter

    scale = (token_dur_ms / score_dur_ms) if (score_dur_ms > 0 and token_dur_ms > 0) else 1.0

    # ── 1. Global key ─────────────────────────────────────────────────────────
    try:
        k       = score.analyze('key')
        root_id = _ROOT_TO_ID.get(k.tonic.name, -1)
        mode_id = 0 if k.mode == 'major' else 1
        global_key_id = int(root_id * 2 + mode_id) if root_id >= 0 else KEY_UNKNOWN
    except Exception:
        global_key_id = KEY_UNKNOWN
    labels[:, 0] = global_key_id

    # ── 2. Chords ─────────────────────────────────────────────────────────────
    try:
        chord_stream = score.chordify()
        chord_times_list = []
        chord_ids_list   = []

        for c in chord_stream.flat.getElementsByClass('Chord'):
            try:
                offset_ql = float(c.offset)
                t_ms      = offset_ql * ms_per_quarter * scale
                root      = c.root().name
                qual      = c.quality
                root_id   = _ROOT_TO_ID.get(root, -1)
                qual_id   = _QUALITY_TO_ID.get(qual, -1)
                cid = (root_id * 5 + qual_id) if (root_id >= 0 and qual_id >= 0) else CHORD_UNKNOWN
            except Exception:
                t_ms = 0.0
                cid  = CHORD_UNKNOWN
            chord_times_list.append(t_ms)
            chord_ids_list.append(cid)

        if chord_times_list:
            ctimes = np.array(chord_times_list, dtype=np.float64)
            cids   = np.array(chord_ids_list,   dtype=np.int16)
            # Sort by time (chordify is usually ordered, but make sure)
            order  = np.argsort(ctimes, kind='stable')
            ctimes = ctimes[order]
            cids   = cids[order]
            # Assign each token the most-recently-struck chord
            idx    = np.searchsorted(ctimes, token_times, side='right') - 1
            valid  = idx >= 0
            labels[valid, 1] = cids[idx[valid]]
    except Exception:
        pass   # leave chord labels as CHORD_UNKNOWN

    # ── 3. Beat position ─────────────────────────────────────────────────────
    try:
        beats_per_bar = 4   # default 4/4
        for ts in score.flat.getElementsByClass('TimeSignature'):
            try:
                beats_per_bar = int(ts.numerator)
            except Exception:
                pass
            break

        ms_per_beat = ms_per_quarter      # assumes 1 quarter = 1 beat
        ms_per_bar  = ms_per_beat * beats_per_bar

        if ms_per_beat > 0 and ms_per_bar > 0:
            beat_pos_f  = (token_times % ms_per_bar) / ms_per_beat   # 0.0 … beats_per_bar
            # Map to 8 slots: each beat is subdivided into "on-beat" and "mid-beat"
            beat_id_arr = (beat_pos_f * 2).astype(np.int16) % (beats_per_bar * 2)
            beat_id_arr = np.clip(beat_id_arr, 0, 7).astype(np.int16)
            labels[:, 2] = beat_id_arr
    except Exception:
        pass   # leave beat labels as BEAT_UNKNOWN

    # ── 4. Cadence detection (lightweight heuristic) ──────────────────────────
    # Detect V→I transitions in the chord sequence and label the I token.
    # Only attempted when chord labels are available.
    try:
        if np.any(labels[:, 1] != CHORD_UNKNOWN):
            _annotate_cadences(labels)
    except Exception:
        pass

    return labels


# ── Cadence annotation ────────────────────────────────────────────────────────

def _annotate_cadences(labels: np.ndarray) -> None:
    """
    Simple heuristic cadence detection applied in-place to labels[:, 3].

    Scans consecutive pairs of distinct chords looking for:
      V  → I        → PAC  (1)
      V  → i        → IAC  (2)
      *  → V        → HC   (3)
      V  → vi/bVI   → DC   (4)
      IV → I        → plagal (5)
      iv → i        → plagal (5)
    """
    chord_ids = labels[:, 1]
    N = len(chord_ids)

    # Walk through, detect transitions between distinct chord events
    prev_cid    = CHORD_UNKNOWN
    prev_idx    = -1

    for i in range(N):
        cid = int(chord_ids[i])
        if cid == CHORD_UNKNOWN:
            continue
        if cid == prev_cid:
            continue   # same chord still sounding

        if prev_cid != CHORD_UNKNOWN and prev_idx >= 0:
            cat = _classify_cadence(prev_cid, cid)
            if cat != CADENCE_NONE:
                labels[i, 3] = cat

        prev_cid = cid
        prev_idx = i


def _classify_cadence(from_cid: int, to_cid: int) -> int:
    """
    Classify a chord transition as a cadence type (0-5).
    chord_id = root_id * 5 + quality_id
    """
    from_root = from_cid // 5
    from_qual = from_cid %  5
    to_root   = to_cid   // 5
    to_qual   = to_cid   %  5

    # Dominant function: major chord (0) or dominant-seventh (4)
    from_is_dominant = from_qual in (0, 4)
    # Interval from 'from' root to 'to' root (semitones up)
    interval = (to_root - from_root) % 12

    # V → I  (P5 down = m7 up, so interval from V root to I root = 5 semitones)
    # The dominant root is 7 semitones above tonic, so tonic is 5 above dominant.
    if from_is_dominant and interval == 5:
        if to_qual == 0:   # major tonic → PAC
            return 1
        if to_qual == 1:   # minor tonic → IAC
            return 2

    # V → vi  (deceptive: dominant moves to submediant, 2 semitones up)
    if from_is_dominant and interval == 2 and to_qual in (0, 1):
        return 4   # DC

    # * → V  (half cadence: any → dominant quality chord)
    if to_qual in (0, 4):
        # Loosely flag if the to_chord sounds dominant (can't easily verify
        # without key context; we use quality as a proxy)
        # Only flag IV→V and ii→V to reduce false positives
        if from_qual in (0, 1) and interval in (2, 7):
            return 3   # HC

    # IV → I  or  iv → i  (plagal)
    if interval == 5 and from_qual in (0, 1) and to_qual == from_qual:
        return 5   # plagal

    return CADENCE_NONE
