"""
v4 model — decoder-only Transformer with rotary position embeddings (RoPE).

Differences from the Phase-1 MusicTransformer (src/model/transformer.py):

  * RoPE in every attention layer instead of one additive sinusoidal encoding.
    Rotary positions encode *relative* distance, which suits music's
    translation-invariance and generalizes better past the trained length.
  * Composer conditioning is carried by a prepended COMPOSER token in the input
    stream (handled by the tokenizer / dataset), not added to every position.
    So the model is a plain LM over the v4 vocabulary — simpler and stronger.
  * Sized up (defaults d_model=640, 10 layers) for more structural capacity,
    with everything configurable for smaller GPUs.

Pure PyTorch, no external attention kernels, so it runs anywhere the old model
did (CUDA / MPS / CPU).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional

import torch
import torch.nn as nn
import torch.nn.functional as F


@dataclass
class ModelConfig:
    vocab_size:  int   = 512      # set from the tokenizer at build time
    d_model:     int   = 640
    n_heads:     int   = 10
    n_layers:    int   = 10
    d_ff:        int   = 2560
    dropout:     float = 0.1
    max_seq_len: int   = 2048
    pad_id:      int   = 0
    rope_base:   float = 10000.0


# ── Rotary position embedding ────────────────────────────────────────────────

def _build_rope_cache(seq_len: int, head_dim: int, base: float, device, dtype):
    """Return (cos, sin) of shape (1, 1, seq_len, head_dim)."""
    half = head_dim // 2
    inv_freq = 1.0 / (base ** (torch.arange(0, half, device=device).float() / half))
    t = torch.arange(seq_len, device=device).float()
    freqs = torch.outer(t, inv_freq)             # (seq_len, half)
    emb = torch.cat([freqs, freqs], dim=-1)      # (seq_len, head_dim)
    return emb.cos()[None, None].to(dtype), emb.sin()[None, None].to(dtype)


def _rotate_half(x: torch.Tensor) -> torch.Tensor:
    half = x.shape[-1] // 2
    x1, x2 = x[..., :half], x[..., half:]
    return torch.cat([-x2, x1], dim=-1)


def _apply_rope(x: torch.Tensor, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
    # x: (B, n_heads, T, head_dim)
    T = x.shape[2]
    return x * cos[:, :, :T] + _rotate_half(x) * sin[:, :, :T]


# ── Attention / block ────────────────────────────────────────────────────────

class RoPEAttention(nn.Module):
    def __init__(self, cfg: ModelConfig):
        super().__init__()
        assert cfg.d_model % cfg.n_heads == 0
        self.n_heads  = cfg.n_heads
        self.head_dim = cfg.d_model // cfg.n_heads
        self.qkv  = nn.Linear(cfg.d_model, 3 * cfg.d_model, bias=False)
        self.proj = nn.Linear(cfg.d_model, cfg.d_model, bias=False)
        self.drop = nn.Dropout(cfg.dropout)
        self.attn_dropout = cfg.dropout

    def forward(self, x, cos, sin, key_padding_mask: Optional[torch.Tensor]):
        B, T, C = x.shape
        q, k, v = self.qkv(x).split(C, dim=2)
        q = q.view(B, T, self.n_heads, self.head_dim).transpose(1, 2)
        k = k.view(B, T, self.n_heads, self.head_dim).transpose(1, 2)
        v = v.view(B, T, self.n_heads, self.head_dim).transpose(1, 2)

        q = _apply_rope(q, cos, sin)
        k = _apply_rope(k, cos, sin)

        attn_mask = None
        if key_padding_mask is not None:
            # (B, T) True=pad -> (B, 1, 1, T) additive mask
            attn_mask = torch.zeros(
                B, 1, 1, T, device=x.device, dtype=q.dtype
            ).masked_fill(key_padding_mask[:, None, None, :], float('-inf'))

        out = F.scaled_dot_product_attention(
            q, k, v,
            attn_mask=attn_mask,
            dropout_p=self.attn_dropout if self.training else 0.0,
            is_causal=(attn_mask is None),
        )
        out = out.transpose(1, 2).contiguous().view(B, T, C)
        return self.drop(self.proj(out))


class Block(nn.Module):
    def __init__(self, cfg: ModelConfig):
        super().__init__()
        self.norm1 = nn.LayerNorm(cfg.d_model)
        self.attn  = RoPEAttention(cfg)
        self.norm2 = nn.LayerNorm(cfg.d_model)
        self.ff = nn.Sequential(
            nn.Linear(cfg.d_model, cfg.d_ff),
            nn.GELU(),
            nn.Dropout(cfg.dropout),
            nn.Linear(cfg.d_ff, cfg.d_model),
            nn.Dropout(cfg.dropout),
        )

    def forward(self, x, cos, sin, key_padding_mask):
        x = x + self.attn(self.norm1(x), cos, sin, key_padding_mask)
        x = x + self.ff(self.norm2(x))
        return x


# ── Model ────────────────────────────────────────────────────────────────────

class MusicTransformerV4(nn.Module):
    def __init__(self, cfg: ModelConfig):
        super().__init__()
        self.cfg = cfg
        self.token_embed = nn.Embedding(cfg.vocab_size, cfg.d_model, padding_idx=cfg.pad_id)
        self.drop   = nn.Dropout(cfg.dropout)
        self.blocks = nn.ModuleList([Block(cfg) for _ in range(cfg.n_layers)])
        self.norm   = nn.LayerNorm(cfg.d_model)
        self.lm_head = nn.Linear(cfg.d_model, cfg.vocab_size, bias=False)
        self.lm_head.weight = self.token_embed.weight   # tied

        self._rope_cos = None
        self._rope_sin = None
        self.apply(self._init)

    def _init(self, m):
        if isinstance(m, nn.Linear):
            nn.init.normal_(m.weight, mean=0.0, std=0.02)
            if m.bias is not None:
                nn.init.zeros_(m.bias)
        elif isinstance(m, nn.Embedding):
            nn.init.normal_(m.weight, mean=0.0, std=0.02)

    def _rope(self, T, device, dtype):
        head_dim = self.cfg.d_model // self.cfg.n_heads
        if (self._rope_cos is None or self._rope_cos.shape[2] < T
                or self._rope_cos.device != device or self._rope_cos.dtype != dtype):
            self._rope_cos, self._rope_sin = _build_rope_cache(
                max(T, self.cfg.max_seq_len), head_dim, self.cfg.rope_base, device, dtype
            )
        return self._rope_cos, self._rope_sin

    def forward(self, tokens: torch.Tensor, key_padding_mask: Optional[torch.Tensor] = None):
        B, T = tokens.shape
        x = self.drop(self.token_embed(tokens))
        cos, sin = self._rope(T, x.device, x.dtype)
        for blk in self.blocks:
            x = blk(x, cos, sin, key_padding_mask)
        x = self.norm(x)
        return self.lm_head(x)

    def num_params(self) -> int:
        return sum(p.numel() for p in self.parameters())
