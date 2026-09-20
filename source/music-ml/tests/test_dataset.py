"""Tests for MusicDataset windowing and output shapes."""

import os
import sys
import json
import tempfile
import numpy as np
import pytest
import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.data.dataset import MusicDataset
from src.data.midi_parser import PAD_TOKEN, SOS_TOKEN, EOS_TOKEN, VOCAB_SIZE


def make_fake_dataset(root: str, composer_map: dict, tokens_per_file: int = 2000):
    """Write synthetic .npy token files in the expected directory layout."""
    for composer, cid in composer_map.items():
        d = os.path.join(root, composer)
        os.makedirs(d, exist_ok=True)
        for i in range(2):
            tokens = np.random.randint(0, 128, size=tokens_per_file, dtype=np.int64)
            tokens[0]  = SOS_TOKEN
            tokens[-1] = EOS_TOKEN
            np.save(os.path.join(d, f'piece_{i}.npy'), tokens)


@pytest.fixture
def dataset(tmp_path):
    composer_map = {'Bach': 0, 'Chopin': 1}
    make_fake_dataset(str(tmp_path), composer_map, tokens_per_file=2000)
    return MusicDataset(str(tmp_path), composer_map, seq_len=512, stride=256)


class TestMusicDataset:
    def test_nonempty(self, dataset):
        assert len(dataset) > 0

    def test_item_shapes(self, dataset):
        x, y, c = dataset[0]
        assert x.shape == (512,)
        assert y.shape == (512,)
        assert c.shape == ()

    def test_x_y_offset_by_one(self, dataset):
        """y should be x shifted left by one (next-token prediction)."""
        # Reconstruct what the underlying window looks like:
        # x = window[:-1], y = window[1:]  =>  y[i] == x[i+1] for non-pad
        x, y, c = dataset[0]
        # The first token of y should equal the second token of x
        assert y[0].item() == x[1].item()

    def test_composer_id_valid(self, dataset):
        composer_map = {'Bach': 0, 'Chopin': 1}
        for i in range(min(len(dataset), 20)):
            _, _, c = dataset[i]
            assert c.item() in composer_map.values()

    def test_token_values_in_vocab(self, dataset):
        x, y, c = dataset[0]
        assert x.max().item() < VOCAB_SIZE
        assert y.max().item() < VOCAB_SIZE
        assert x.min().item() >= 0
        assert y.min().item() >= 0

    def test_window_count_reasonable(self, tmp_path):
        """With seq_len=512, stride=256, 2000-token file → ~6 windows."""
        composer_map = {'Bach': 0}
        make_fake_dataset(str(tmp_path), composer_map, tokens_per_file=2000)
        ds = MusicDataset(str(tmp_path), composer_map, seq_len=512, stride=256)
        # 2 files × ~6 windows each = ~12; allow generous bounds
        assert 8 <= len(ds) <= 20

    def test_short_sequence_padded(self, tmp_path):
        """A sequence shorter than seq_len should be padded to full length."""
        composer_map = {'Bach': 0}
        d = os.path.join(str(tmp_path), 'Bach')
        os.makedirs(d)
        short_tokens = np.array([SOS_TOKEN, 60, 188, EOS_TOKEN], dtype=np.int64)
        np.save(os.path.join(d, 'short.npy'), short_tokens)
        ds = MusicDataset(str(tmp_path), composer_map, seq_len=512, stride=256)
        x, y, c = ds[0]
        assert x.shape == (512,)
        assert (x == PAD_TOKEN).any() or (y == PAD_TOKEN).any()

    def test_missing_composer_dir_skipped(self, tmp_path):
        """A composer in the map with no directory on disk is silently skipped."""
        composer_map = {'Bach': 0, 'Ghost': 1}  # Ghost has no directory
        d = os.path.join(str(tmp_path), 'Bach')
        os.makedirs(d)
        tokens = np.random.randint(0, 128, size=1000, dtype=np.int64)
        np.save(os.path.join(d, 'piece.npy'), tokens)
        ds = MusicDataset(str(tmp_path), composer_map, seq_len=512, stride=256)
        assert len(ds) > 0  # Bach data loaded fine
