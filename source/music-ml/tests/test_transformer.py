"""Tests for MusicTransformer forward pass shapes and basic properties."""

import os
import sys
import pytest
import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.model.transformer import MusicTransformer, PositionalEncoding, DecoderLayer


@pytest.fixture(scope='module')
def tiny_model():
    """A very small model for fast CPU tests."""
    return MusicTransformer(
        vocab_size=392,
        d_model=64,
        n_heads=4,
        n_layers=2,
        d_ff=128,
        dropout=0.0,
        max_seq_len=256,
        num_composers=5,
        composer_embed_dim=16,
    )


class TestPositionalEncoding:
    def test_output_shape(self):
        pe = PositionalEncoding(d_model=64, max_len=256, dropout=0.0)
        x = torch.zeros(2, 100, 64)
        out = pe(x)
        assert out.shape == (2, 100, 64)

    def test_different_positions_differ(self):
        pe = PositionalEncoding(d_model=64, max_len=256, dropout=0.0)
        x = torch.zeros(1, 10, 64)
        out = pe(x)
        # Adjacent positions should not be identical
        assert not torch.allclose(out[0, 0], out[0, 1])


class TestDecoderLayer:
    def test_output_shape(self):
        layer = DecoderLayer(d_model=64, n_heads=4, d_ff=128, dropout=0.0)
        x = torch.randn(2, 32, 64)
        mask = torch.full((32, 32), float('-inf'))
        mask = torch.triu(mask, diagonal=1)
        out = layer(x, mask)
        assert out.shape == (2, 32, 64)


class TestMusicTransformer:
    def test_output_shape(self, tiny_model):
        B, T = 2, 64
        x = torch.randint(0, 392, (B, T))
        c = torch.randint(0, 5,   (B,))
        logits = tiny_model(x, c)
        assert logits.shape == (B, T, 392)

    def test_output_dtype(self, tiny_model):
        x = torch.randint(0, 392, (1, 32))
        c = torch.zeros(1, dtype=torch.long)
        logits = tiny_model(x, c)
        assert logits.dtype == torch.float32

    def test_tied_embeddings(self, tiny_model):
        """lm_head weight should be the same object as token_embed weight."""
        assert tiny_model.lm_head.weight is tiny_model.token_embed.weight

    def test_causal_masking(self, tiny_model):
        """Future tokens must not influence past positions.
        If we change token at position T, logits at positions < T should be unchanged."""
        tiny_model.eval()
        B, T = 1, 32
        x = torch.randint(0, 392, (B, T))
        c = torch.zeros(B, dtype=torch.long)

        with torch.no_grad():
            logits_orig = tiny_model(x, c).clone()
            x2 = x.clone()
            x2[0, -1] = (x2[0, -1] + 1) % 391  # change last token
            logits_mod = tiny_model(x2, c)

        # All positions except the last should be identical
        assert torch.allclose(logits_orig[0, :-1], logits_mod[0, :-1], atol=1e-5)

    def test_padding_mask(self, tiny_model):
        """Model should accept a padding mask without error."""
        B, T = 2, 32
        x = torch.randint(0, 392, (B, T))
        c = torch.zeros(B, dtype=torch.long)
        pad_mask = torch.zeros(B, T, dtype=torch.bool)
        pad_mask[0, 20:] = True  # simulate padding in second half of first sample
        logits = tiny_model(x, c, padding_mask=pad_mask)
        assert logits.shape == (B, T, 392)

    def test_different_composers_give_different_logits(self, tiny_model):
        """Same tokens with different composer IDs should produce different outputs."""
        tiny_model.eval()
        x = torch.randint(0, 392, (1, 16))
        c1 = torch.tensor([0])
        c2 = torch.tensor([1])
        with torch.no_grad():
            out1 = tiny_model(x, c1)
            out2 = tiny_model(x, c2)
        assert not torch.allclose(out1, out2)

    def test_parameter_count(self, tiny_model):
        """Sanity check that the model has the expected rough scale of parameters."""
        n = sum(p.numel() for p in tiny_model.parameters())
        # Tiny config: d_model=64, 2 layers — expect well under 1M params
        assert n < 1_000_000

    def test_no_nan_in_output(self, tiny_model):
        x = torch.randint(0, 392, (2, 64))
        c = torch.randint(0, 5,   (2,))
        logits = tiny_model(x, c)
        assert not torch.isnan(logits).any()
        assert not torch.isinf(logits).any()
