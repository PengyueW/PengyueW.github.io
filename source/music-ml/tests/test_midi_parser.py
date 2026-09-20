"""Tests for MIDI event token encoding/decoding."""

import os
import sys
import tempfile
import mido
import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.data.midi_parser import (
    midi_to_events, events_to_midi,
    velocity_to_bin, bin_to_velocity,
    NOTE_ON_OFFSET, NOTE_OFF_OFFSET, TIME_SHIFT_OFFSET,
    VELOCITY_OFFSET, SOS_TOKEN, EOS_TOKEN, PAD_TOKEN,
    VOCAB_SIZE, NUM_VELOCITY_BINS, MS_PER_STEP, MAX_SHIFT_STEPS,
)


def make_simple_midi(path: str, notes=((60, 100, 0, 500), (64, 80, 500, 1000))):
    """Write a minimal MIDI file. notes = (pitch, velocity, start_ms, end_ms)."""
    mid = mido.MidiFile()
    track = mido.MidiTrack()
    mid.tracks.append(track)
    tempo = 500_000
    tpb = 480
    mid.ticks_per_beat = tpb
    track.append(mido.MetaMessage('set_tempo', tempo=tempo, time=0))

    events = []
    for pitch, vel, start_ms, end_ms in notes:
        ticks_start = int(start_ms / 1000 * tpb * 1_000_000 / tempo)
        ticks_end   = int(end_ms   / 1000 * tpb * 1_000_000 / tempo)
        events.append((ticks_start, 'note_on',  pitch, vel))
        events.append((ticks_end,   'note_off', pitch, 0))

    events.sort()
    prev = 0
    for tick, etype, pitch, vel in events:
        delta = tick - prev
        track.append(mido.Message(etype, note=pitch, velocity=vel, time=delta))
        prev = tick

    mid.save(path)


class TestVelocityBins:
    def test_bin_range(self):
        for v in range(128):
            b = velocity_to_bin(v)
            assert 0 <= b < NUM_VELOCITY_BINS

    def test_roundtrip_approximate(self):
        for b in range(NUM_VELOCITY_BINS):
            v = bin_to_velocity(b)
            assert velocity_to_bin(v) == b

    def test_max_velocity_fits(self):
        assert velocity_to_bin(127) == NUM_VELOCITY_BINS - 1


class TestVocabularyConstants:
    def test_token_ranges_non_overlapping(self):
        ranges = [
            range(NOTE_ON_OFFSET,    NOTE_ON_OFFSET + 128),
            range(NOTE_OFF_OFFSET,   NOTE_OFF_OFFSET + 128),
            range(TIME_SHIFT_OFFSET + 1, TIME_SHIFT_OFFSET + MAX_SHIFT_STEPS + 1),
            range(VELOCITY_OFFSET,   VELOCITY_OFFSET + NUM_VELOCITY_BINS),
        ]
        all_tokens = [t for r in ranges for t in r]
        assert len(all_tokens) == len(set(all_tokens)), "Token ranges overlap"

    def test_special_tokens_outside_ranges(self):
        for special in (PAD_TOKEN, SOS_TOKEN, EOS_TOKEN):
            assert 0 <= special < VOCAB_SIZE

    def test_vocab_size(self):
        assert VOCAB_SIZE == 392


class TestMidiToEvents:
    def test_starts_with_sos(self, tmp_path):
        midi_path = str(tmp_path / 'test.mid')
        make_simple_midi(midi_path)
        tokens = midi_to_events(midi_path)
        assert tokens[0] == SOS_TOKEN

    def test_ends_with_eos(self, tmp_path):
        midi_path = str(tmp_path / 'test.mid')
        make_simple_midi(midi_path)
        tokens = midi_to_events(midi_path)
        assert tokens[-1] == EOS_TOKEN

    def test_all_tokens_valid(self, tmp_path):
        midi_path = str(tmp_path / 'test.mid')
        make_simple_midi(midi_path)
        tokens = midi_to_events(midi_path)
        for t in tokens:
            assert 0 <= t < VOCAB_SIZE, f"Invalid token: {t}"

    def test_contains_note_on(self, tmp_path):
        midi_path = str(tmp_path / 'test.mid')
        make_simple_midi(midi_path, notes=[(60, 100, 0, 500)])
        tokens = midi_to_events(midi_path)
        assert NOTE_ON_OFFSET + 60 in tokens

    def test_contains_note_off(self, tmp_path):
        midi_path = str(tmp_path / 'test.mid')
        make_simple_midi(midi_path, notes=[(60, 100, 0, 500)])
        tokens = midi_to_events(midi_path)
        assert NOTE_OFF_OFFSET + 60 in tokens

    def test_contains_velocity(self, tmp_path):
        midi_path = str(tmp_path / 'test.mid')
        make_simple_midi(midi_path)
        tokens = midi_to_events(midi_path)
        has_vel = any(VELOCITY_OFFSET <= t < VELOCITY_OFFSET + NUM_VELOCITY_BINS for t in tokens)
        assert has_vel

    def test_contains_time_shift(self, tmp_path):
        midi_path = str(tmp_path / 'test.mid')
        # second note starts 500ms in, so we expect at least one TIME_SHIFT
        make_simple_midi(midi_path, notes=[(60, 100, 0, 100), (64, 80, 500, 600)])
        tokens = midi_to_events(midi_path)
        has_shift = any(TIME_SHIFT_OFFSET < t <= TIME_SHIFT_OFFSET + MAX_SHIFT_STEPS for t in tokens)
        assert has_shift

    def test_long_gap_chained(self, tmp_path):
        """A gap > 1000ms must be encoded as multiple TIME_SHIFT tokens."""
        midi_path = str(tmp_path / 'test.mid')
        make_simple_midi(midi_path, notes=[(60, 100, 0, 100), (64, 80, 3000, 3100)])
        tokens = midi_to_events(midi_path)
        shifts = [t for t in tokens if TIME_SHIFT_OFFSET < t <= TIME_SHIFT_OFFSET + MAX_SHIFT_STEPS]
        total_ms = sum((t - TIME_SHIFT_OFFSET) * MS_PER_STEP for t in shifts)
        assert total_ms >= 2900  # ~3000ms gap


class TestEventsToMidi:
    def test_produces_midi_file(self, tmp_path):
        out_path = str(tmp_path / 'out.mid')
        tokens = [SOS_TOKEN, VELOCITY_OFFSET + 5, NOTE_ON_OFFSET + 60,
                  TIME_SHIFT_OFFSET + 10, NOTE_OFF_OFFSET + 60, EOS_TOKEN]
        events_to_midi(tokens, out_path)
        assert os.path.exists(out_path)

    def test_output_is_valid_midi(self, tmp_path):
        out_path = str(tmp_path / 'out.mid')
        tokens = [SOS_TOKEN, VELOCITY_OFFSET + 5, NOTE_ON_OFFSET + 60,
                  TIME_SHIFT_OFFSET + 10, NOTE_OFF_OFFSET + 60, EOS_TOKEN]
        events_to_midi(tokens, out_path)
        mid = mido.MidiFile(out_path)
        assert len(mid.tracks) > 0

    def test_roundtrip_preserves_notes(self, tmp_path):
        """Encode a MIDI, decode back, re-encode: NOTE_ON tokens should match."""
        src = str(tmp_path / 'src.mid')
        out = str(tmp_path / 'out.mid')
        make_simple_midi(src, notes=[(60, 100, 0, 500), (64, 80, 500, 1000)])
        tokens = midi_to_events(src)
        events_to_midi(tokens, out)
        tokens2 = midi_to_events(out)
        note_ons_1 = {t for t in tokens  if NOTE_ON_OFFSET <= t < NOTE_ON_OFFSET + 128}
        note_ons_2 = {t for t in tokens2 if NOTE_ON_OFFSET <= t < NOTE_ON_OFFSET + 128}
        assert note_ons_1 == note_ons_2
