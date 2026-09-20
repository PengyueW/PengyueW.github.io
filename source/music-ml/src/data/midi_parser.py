"""
MIDI Parser: converts MIDI files into event token sequences and back.

Event Vocabulary (392 tokens total):
  0   - 127  : NOTE_ON(pitch)       — note starts (MIDI pitch 0-127)
  128 - 255  : NOTE_OFF(pitch)      — note ends   (MIDI pitch 0-127, stored as pitch+128)
  257 - 356  : TIME_SHIFT(n)        — advance time by n*10ms (n=1..100, stored as 256+n)
  357 - 388  : SET_VELOCITY(bin)    — velocity bucket 0-31  (stored as 357+bin)
  389        : PAD
  390        : SOS (start of sequence)
  391        : EOS (end of sequence)
"""

import mido
import numpy as np
from typing import List, Tuple, Optional

# ── Vocabulary constants ──────────────────────────────────────────────────────
NOTE_ON_OFFSET   = 0        # token = pitch
NOTE_OFF_OFFSET  = 128      # token = pitch + 128
TIME_SHIFT_OFFSET = 256     # token = 255 + n  (n in 1..100, representing 10ms..1000ms)
VELOCITY_OFFSET  = 357      # token = 357 + bin  (32 bins, bin in 0..31)

PAD_TOKEN = 389
SOS_TOKEN = 390
EOS_TOKEN = 391
VOCAB_SIZE = 392

# ── Timing & velocity parameters ─────────────────────────────────────────────
MS_PER_STEP    = 10          # each TIME_SHIFT unit = 10 ms
MAX_SHIFT_STEPS = 100        # largest single TIME_SHIFT = 1000 ms
NUM_VELOCITY_BINS = 32


def velocity_to_bin(velocity: int) -> int:
    """Map MIDI velocity (0-127) to a bin index (0-31)."""
    return min(int(velocity * NUM_VELOCITY_BINS / 128), NUM_VELOCITY_BINS - 1)


def bin_to_velocity(bin_idx: int) -> int:
    """Map velocity bin (0-31) back to a representative MIDI velocity."""
    return int((bin_idx + 0.5) * 128 / NUM_VELOCITY_BINS)


def midi_to_events(midi_path: str) -> List[int]:
    """
    Parse a MIDI file and return a list of event tokens.

    Only piano (channel 0) events are kept; other channels are ignored.
    Tempo changes are used to convert ticks to milliseconds accurately.
    """
    mid = mido.MidiFile(midi_path)

    # Collect all messages with their absolute time in ms
    raw_events: List[Tuple[float, str, dict]] = []  # (time_ms, type, attrs)
    tempo = 500_000  # default: 120 BPM in microseconds per beat
    ticks_per_beat = mid.ticks_per_beat

    for track in mid.tracks:
        abs_tick = 0
        abs_ms   = 0.0
        for msg in track:
            abs_tick += msg.time
            delta_ms  = mido.tick2second(msg.time, ticks_per_beat, tempo) * 1000
            abs_ms   += delta_ms

            if msg.type == 'set_tempo':
                tempo = msg.tempo
            elif msg.type == 'note_on' and msg.velocity > 0:
                raw_events.append((abs_ms, 'note_on',  {'pitch': msg.note, 'velocity': msg.velocity}))
            elif msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0):
                raw_events.append((abs_ms, 'note_off', {'pitch': msg.note}))

    raw_events.sort(key=lambda e: e[0])

    # Convert to token sequence
    tokens: List[int] = [SOS_TOKEN]
    current_ms = 0.0
    current_velocity_bin = -1  # force a SET_VELOCITY at the start

    for abs_ms, etype, attrs in raw_events:
        # Encode elapsed time as one or more TIME_SHIFT tokens
        elapsed_steps = round((abs_ms - current_ms) / MS_PER_STEP)
        while elapsed_steps > 0:
            shift = min(elapsed_steps, MAX_SHIFT_STEPS)
            tokens.append(TIME_SHIFT_OFFSET + shift)   # 256 + shift
            elapsed_steps  -= shift
        current_ms = abs_ms

        if etype == 'note_on':
            vel_bin = velocity_to_bin(attrs['velocity'])
            if vel_bin != current_velocity_bin:
                tokens.append(VELOCITY_OFFSET + vel_bin)
                current_velocity_bin = vel_bin
            tokens.append(NOTE_ON_OFFSET + attrs['pitch'])
        elif etype == 'note_off':
            tokens.append(NOTE_OFF_OFFSET + attrs['pitch'])

    tokens.append(EOS_TOKEN)
    return tokens


def events_to_midi(tokens: List[int], output_path: str, tempo: int = 500_000) -> None:
    """
    Convert a list of event tokens back into a MIDI file.

    Args:
        tokens:      List of event token integers.
        output_path: Where to write the .mid file.
        tempo:       Microseconds per beat (default 120 BPM).
    """
    mid = mido.MidiFile()
    track = mido.MidiTrack()
    mid.tracks.append(track)

    ticks_per_beat = 480
    mid.ticks_per_beat = ticks_per_beat
    track.append(mido.MetaMessage('set_tempo', tempo=tempo, time=0))

    seconds_per_tick = tempo / (ticks_per_beat * 1_000_000)

    pending_ticks   = 0   # accumulated ticks before next message
    current_velocity = 64

    for token in tokens:
        if token in (SOS_TOKEN, EOS_TOKEN, PAD_TOKEN):
            continue
        elif NOTE_ON_OFFSET <= token < NOTE_ON_OFFSET + 128:
            pitch = token - NOTE_ON_OFFSET
            track.append(mido.Message('note_on', note=pitch, velocity=current_velocity,
                                      time=pending_ticks))
            pending_ticks = 0
        elif NOTE_OFF_OFFSET <= token < NOTE_OFF_OFFSET + 128:
            pitch = token - NOTE_OFF_OFFSET
            track.append(mido.Message('note_off', note=pitch, velocity=0,
                                      time=pending_ticks))
            pending_ticks = 0
        elif TIME_SHIFT_OFFSET < token <= TIME_SHIFT_OFFSET + MAX_SHIFT_STEPS:
            steps = token - TIME_SHIFT_OFFSET           # 1..100
            ms    = steps * MS_PER_STEP
            ticks = round(ms / 1000 / seconds_per_tick)
            pending_ticks += ticks
        elif VELOCITY_OFFSET <= token < VELOCITY_OFFSET + NUM_VELOCITY_BINS:
            bin_idx = token - VELOCITY_OFFSET
            current_velocity = bin_to_velocity(bin_idx)

    mid.save(output_path)


def token_is_valid(token: int) -> bool:
    return 0 <= token < VOCAB_SIZE
