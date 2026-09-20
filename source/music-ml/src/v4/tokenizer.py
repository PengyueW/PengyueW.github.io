"""
v4 REMI-style tokenizer  (see IMPROVEMENTS.md, Part C).

A note is represented by its *musical* position and its *duration*, not by a
pair of absolute NOTE_ON / NOTE_OFF events separated by chains of time-shifts.
This (a) roughly halves the tokens-per-note, (b) gives the model an explicit
metrical grid (Bar / Position), and (c) makes note length a first-class quantity
so notes can never "hang". Sustain-pedal (CC64) is applied at parse time so the
durations the model learns are the true *sounding* lengths.

Token stream layout for one piece:

    BOS  COMPOSER<id>
    BAR [TEMPO] POSITION_p  PITCH_a DUR_x VEL_v  PITCH_b DUR_y VEL_w  ...
    BAR ...
    EOS

Everything is derived from a fixed 4-beat grid (BEATS_PER_BAR = 4,
GRID = 12 subdivisions per beat -> 48 positions per bar). Using a fixed grid for
both encode and decode makes the round-trip exact regardless of the notated
metre; the "bar" is simply a regular 4-beat ruler that the model can lock onto.

The class is intentionally dependency-light (only `mido` + `numpy`) and holds no
model state, so it is safe to build once and reuse across the whole dataset.
"""

from __future__ import annotations

import numpy as np
import mido
from typing import List, Dict, Optional, Tuple


# ── Grid / bin configuration ────────────────────────────────────────────────
BEATS_PER_BAR     = 4
GRID              = 12                     # subdivisions per quarter-note beat
POSITIONS_PER_BAR = BEATS_PER_BAR * GRID   # = 48

NUM_TEMPO_BINS = 32
TEMPO_MIN_BPM  = 40.0
TEMPO_MAX_BPM  = 220.0

NUM_VELOCITY_BINS = 32

# Curated duration table (in grid steps). Dense for short notes, sparse for long
# ones — covers 1/48 of a bar up to two full bars.
DURATION_VALUES: List[int] = (
    list(range(1, 33)) + [36, 40, 44, 48, 54, 60, 72, 84, 96]
)
NUM_DURATIONS = len(DURATION_VALUES)


class REMITokenizer:
    """
    Bidirectional MIDI <-> token converter.

    Vocabulary sections are laid out contiguously; `self.<NAME>_BASE` gives the
    first id of each section. `vocab_size` and `composer_map` are fixed at
    construction so the same tokenizer instance defines the model's embedding
    table.
    """

    def __init__(self, composer_map: Dict[str, int]):
        # composer_map: composer name -> contiguous id (0..N-1)
        self.composer_map  = dict(composer_map)
        self.num_composers = (max(composer_map.values()) + 1) if composer_map else 0

        # ── Vocabulary layout ────────────────────────────────────────────────
        self.PAD = 0
        self.BOS = 1
        self.EOS = 2
        self.BAR = 3

        cur = 4
        self.COMPOSER_BASE = cur;  cur += self.num_composers
        self.POSITION_BASE = cur;  cur += POSITIONS_PER_BAR
        self.TEMPO_BASE    = cur;  cur += NUM_TEMPO_BINS
        self.PITCH_BASE    = cur;  cur += 128
        self.DURATION_BASE = cur;  cur += NUM_DURATIONS
        self.VELOCITY_BASE = cur;  cur += NUM_VELOCITY_BINS
        self.vocab_size    = cur

    # ── Small helpers ────────────────────────────────────────────────────────

    @staticmethod
    def _bpm_to_bin(bpm: float) -> int:
        frac = (bpm - TEMPO_MIN_BPM) / (TEMPO_MAX_BPM - TEMPO_MIN_BPM)
        return int(min(max(round(frac * (NUM_TEMPO_BINS - 1)), 0), NUM_TEMPO_BINS - 1))

    @staticmethod
    def _bin_to_bpm(b: int) -> float:
        frac = b / (NUM_TEMPO_BINS - 1)
        return TEMPO_MIN_BPM + frac * (TEMPO_MAX_BPM - TEMPO_MIN_BPM)

    @staticmethod
    def _vel_to_bin(v: int) -> int:
        return int(min(v * NUM_VELOCITY_BINS // 128, NUM_VELOCITY_BINS - 1))

    @staticmethod
    def _bin_to_vel(b: int) -> int:
        return int((b + 0.5) * 128 / NUM_VELOCITY_BINS)

    @staticmethod
    def _quantize_duration(steps: int) -> int:
        """Return the DURATION_VALUES index nearest to `steps`."""
        steps = max(1, steps)
        arr   = DURATION_VALUES
        # linear scan is fine (39 entries) and avoids a numpy import in the hot loop
        best_i, best_d = 0, abs(arr[0] - steps)
        for i in range(1, len(arr)):
            d = abs(arr[i] - steps)
            if d < best_d:
                best_i, best_d = i, d
        return best_i

    # ── Encode: MIDI file -> token ids ───────────────────────────────────────

    def tokenize(self, midi_path: str, composer_id: Optional[int] = None) -> List[int]:
        """
        Parse a MIDI file into v4 token ids.

        Sustain pedal (CC64) is applied: a note released while the pedal is down
        is held until the next pedal-up. Returns [] if the file has no notes.
        """
        mid = mido.MidiFile(midi_path)
        tpb = mid.ticks_per_beat or 480

        # Flatten every track to absolute-tick messages we care about.
        note_ons: List[Tuple[int, int, int]] = []   # (tick, pitch, velocity)
        note_offs: List[Tuple[int, int]]     = []    # (tick, pitch)
        pedal_events: List[Tuple[int, bool]] = []    # (tick, is_down)
        tempo_events: List[Tuple[int, float]] = []   # (tick, bpm)

        for track in mid.tracks:
            t = 0
            for msg in track:
                t += msg.time
                if msg.type == 'set_tempo':
                    tempo_events.append((t, mido.tempo2bpm(msg.tempo)))
                elif msg.type == 'note_on' and msg.velocity > 0:
                    note_ons.append((t, msg.note, msg.velocity))
                elif msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0):
                    note_offs.append((t, msg.note))
                elif msg.type == 'control_change' and msg.control == 64:
                    pedal_events.append((t, msg.value >= 64))

        if not note_ons:
            return []

        notes = self._pair_notes(note_ons, note_offs, pedal_events)
        if not notes:
            return []

        tempo_events.sort()

        def bpm_at(tick: int) -> float:
            bpm = 120.0
            for et, eb in tempo_events:
                if et <= tick:
                    bpm = eb
                else:
                    break
            return bpm

        # ── Emit the token stream ────────────────────────────────────────────
        tokens: List[int] = [self.BOS]
        if composer_id is not None and self.num_composers:
            tokens.append(self.COMPOSER_BASE + int(composer_id))

        notes.sort(key=lambda n: (n[0], n[1]))   # by onset tick, then pitch

        cur_bar   = -1
        cur_pos   = -1
        cur_tempo = -1
        for onset, pitch, dur_ticks, vel in notes:
            beat     = onset / tpb
            bar      = int(beat // BEATS_PER_BAR)
            pos_beat = beat - bar * BEATS_PER_BAR
            pos      = int(round(pos_beat * GRID))
            if pos >= POSITIONS_PER_BAR:          # rounding spill into next bar
                bar += 1
                pos -= POSITIONS_PER_BAR
            pos = min(pos, POSITIONS_PER_BAR - 1)

            # Advance bars (one BAR token per bar keeps decode timing exact).
            while cur_bar < bar:
                tokens.append(self.BAR)
                cur_bar += 1
                cur_pos  = -1
                tb = self._bpm_to_bin(bpm_at(onset))
                if tb != cur_tempo:
                    tokens.append(self.TEMPO_BASE + tb)
                    cur_tempo = tb

            if pos != cur_pos:
                tokens.append(self.POSITION_BASE + pos)
                cur_pos = pos

            dur_steps = max(1, int(round(dur_ticks / tpb * GRID)))
            tokens.append(self.PITCH_BASE + pitch)
            tokens.append(self.DURATION_BASE + self._quantize_duration(dur_steps))
            tokens.append(self.VELOCITY_BASE + self._vel_to_bin(vel))

        tokens.append(self.EOS)
        return tokens

    @staticmethod
    def _pair_notes(
        note_ons:     List[Tuple[int, int, int]],
        note_offs:    List[Tuple[int, int]],
        pedal_events: List[Tuple[int, bool]],
    ) -> List[Tuple[int, int, int, int]]:
        """
        Match each NOTE_ON to its NOTE_OFF and extend the end through any active
        sustain pedal. Returns (onset_tick, pitch, duration_ticks, velocity).
        """
        pedal_events.sort()

        def pedal_release_after(tick: int) -> Optional[int]:
            """First pedal-up tick strictly after `tick` while pedal is down."""
            down = False
            for pt, is_down in pedal_events:
                if pt <= tick:
                    down = is_down
                else:
                    if down and not is_down:
                        return pt
                    down = is_down
            return None

        def pedal_down_at(tick: int) -> bool:
            down = False
            for pt, is_down in pedal_events:
                if pt <= tick:
                    down = is_down
                else:
                    break
            return down

        # Per-pitch FIFO of pending offs.
        offs_by_pitch: Dict[int, List[int]] = {}
        for t, p in sorted(note_offs):
            offs_by_pitch.setdefault(p, []).append(t)

        notes: List[Tuple[int, int, int, int]] = []
        for onset, pitch, vel in sorted(note_ons):
            queue = offs_by_pitch.get(pitch)
            end   = None
            if queue:
                # first off at or after onset
                idx = 0
                while idx < len(queue) and queue[idx] < onset:
                    idx += 1
                if idx < len(queue):
                    end = queue.pop(idx)
            if end is None:
                end = onset + 1
            # Extend through sustain pedal if the release lands while pedal down.
            if pedal_events and pedal_down_at(end):
                rel = pedal_release_after(end)
                if rel is not None:
                    end = max(end, rel)
            dur = max(1, end - onset)
            notes.append((onset, pitch, dur, vel))
        return notes

    # ── Decode: token ids -> MIDI file ───────────────────────────────────────

    def detokenize(self, tokens: List[int], out_path: str) -> int:
        """
        Convert a v4 token sequence back to a MIDI file. Returns the number of
        notes written. Robust to slightly malformed model output (missing
        duration/velocity fall back to sensible defaults).
        """
        tpb = 480
        mid = mido.MidiFile(ticks_per_beat=tpb)
        track = mido.MidiTrack()
        mid.tracks.append(track)

        events: List[Tuple[int, str, int, int]] = []   # (tick, kind, pitch, vel)
        tempo_changes: List[Tuple[int, int]] = []        # (tick, microsec/beat)

        cur_bar   = -1
        cur_pos   = 0
        pending_pitch: Optional[int] = None
        pending_dur:   Optional[int] = None
        n_notes = 0

        def bar_pos_to_tick(bar: int, pos: int) -> int:
            beat = bar * BEATS_PER_BAR + pos / GRID
            return int(round(beat * tpb))

        for tok in tokens:
            if tok in (self.PAD, self.BOS, self.EOS):
                continue
            if self.COMPOSER_BASE <= tok < self.COMPOSER_BASE + self.num_composers:
                continue
            if tok == self.BAR:
                cur_bar = max(0, cur_bar) + 1 if cur_bar >= 0 else 0
                cur_pos = 0
                pending_pitch = pending_dur = None
            elif self.POSITION_BASE <= tok < self.POSITION_BASE + POSITIONS_PER_BAR:
                cur_pos = tok - self.POSITION_BASE
                pending_pitch = pending_dur = None
            elif self.TEMPO_BASE <= tok < self.TEMPO_BASE + NUM_TEMPO_BINS:
                bpm = self._bin_to_bpm(tok - self.TEMPO_BASE)
                tick = bar_pos_to_tick(max(cur_bar, 0), cur_pos)
                tempo_changes.append((tick, int(mido.bpm2tempo(bpm))))
            elif self.PITCH_BASE <= tok < self.PITCH_BASE + 128:
                pending_pitch = tok - self.PITCH_BASE
                pending_dur   = None
            elif self.DURATION_BASE <= tok < self.DURATION_BASE + NUM_DURATIONS:
                pending_dur = DURATION_VALUES[tok - self.DURATION_BASE]
            elif self.VELOCITY_BASE <= tok < self.VELOCITY_BASE + NUM_VELOCITY_BINS:
                if pending_pitch is not None:
                    vel   = self._bin_to_vel(tok - self.VELOCITY_BASE)
                    dur   = pending_dur if pending_dur is not None else GRID  # 1 beat
                    start = bar_pos_to_tick(max(cur_bar, 0), cur_pos)
                    dur_ticks = int(round(dur / GRID * tpb))
                    events.append((start,            'on',  pending_pitch, vel))
                    events.append((start + dur_ticks, 'off', pending_pitch, 0))
                    n_notes += 1
                pending_pitch = pending_dur = None

        # Merge tempo metas + note events on one timeline, delta-encode.
        if not tempo_changes:
            tempo_changes = [(0, int(mido.bpm2tempo(120)))]
        timeline: List[Tuple[int, int, str, int, int]] = []
        for tick, us in tempo_changes:
            timeline.append((tick, 0, 'tempo', us, 0))
        for tick, kind, pitch, vel in events:
            order = 1 if kind == 'off' else 2   # offs before ons at same tick
            timeline.append((tick, order, kind, pitch, vel))
        timeline.sort(key=lambda e: (e[0], e[1]))

        prev = 0
        for tick, _order, kind, a, b in timeline:
            delta = max(0, tick - prev)
            prev  = tick
            if kind == 'tempo':
                track.append(mido.MetaMessage('set_tempo', tempo=a, time=delta))
            elif kind == 'on':
                track.append(mido.Message('note_on',  note=a, velocity=b, time=delta))
            else:
                track.append(mido.Message('note_off', note=a, velocity=0, time=delta))

        mid.save(out_path)
        return n_notes
