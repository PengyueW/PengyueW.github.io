"""
Decoder-only Transformer for autoregressive music event generation,
conditioned on a composer embedding and optionally on theory signals.

Architecture summary (base, use_theory=False)
─────────────────────────────────────────────
  input tokens  ──► token_embed  ──┐
  composer_id   ──► composer_embed ─┤ add ──► pos_encode ──► N × DecoderLayer ──► lm_head
                                    └─ added to every token position

With use_theory=True, three additional lightweight embeddings are added:
  key_ids   ──► key_embed   ─┐
  chord_ids ──► chord_embed ─┤ add (per position) ──► (same pipeline)
  beat_ids  ──► beat_embed  ─┘

During training two auxiliary prediction heads are active:
  hidden ──► chord_head ──► chord logits  (61 classes)
  hidden ──► key_head   ──► key logits    (25 classes)

These auxiliary outputs allow the theory auxiliary loss in trainer.py.
During inference (model.eval()) forward() always returns only logits.
"""

import math
from typing import Optional, Tuple, Union

import torch
import torch.nn as nn
import torch.nn.functional as F

from src.data.theory_extractor import NUM_KEYS, NUM_CHORDS, NUM_BEATS
from src.data.composer_meta import NUM_ERAS


# ── Sub-modules ───────────────────────────────────────────────────────────────

class PositionalEncoding(nn.Module):
    def __init__(self, d_model: int, max_len: int, dropout: float = 0.1):
        super().__init__()
        self.dropout = nn.Dropout(dropout)
        pe  = torch.zeros(max_len, d_model)
        pos = torch.arange(max_len, dtype=torch.float).unsqueeze(1)
        div = torch.exp(
            torch.arange(0, d_model, 2, dtype=torch.float) * (-math.log(10000.0) / d_model)
        )
        pe[:, 0::2] = torch.sin(pos * div)
        pe[:, 1::2] = torch.cos(pos * div)
        self.register_buffer('pe', pe.unsqueeze(0))   # (1, max_len, d_model)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x + self.pe[:, :x.size(1)]
        return self.dropout(x)


class DecoderLayer(nn.Module):
    def __init__(self, d_model: int, n_heads: int, d_ff: int, dropout: float):
        super().__init__()
        self.self_attn = nn.MultiheadAttention(
            d_model, n_heads, dropout=dropout, batch_first=True
        )
        self.ff   = nn.Sequential(
            nn.Linear(d_model, d_ff),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(d_ff, d_model),
        )
        self.norm1 = nn.LayerNorm(d_model)
        self.norm2 = nn.LayerNorm(d_model)
        self.drop1 = nn.Dropout(dropout)
        self.drop2 = nn.Dropout(dropout)

    def forward(
        self,
        x:               torch.Tensor,
        causal_mask:     torch.Tensor,
        key_padding_mask: Optional[torch.Tensor] = None,
    ) -> torch.Tensor:
        residual = x
        x = self.norm1(x)
        attn_out, _ = self.self_attn(
            x, x, x,
            attn_mask=causal_mask,
            key_padding_mask=key_padding_mask,
            need_weights=False,
        )
        x = residual + self.drop1(attn_out)
        residual = x
        x = residual + self.drop2(self.ff(self.norm2(x)))
        return x


# ── Main model ────────────────────────────────────────────────────────────────

class MusicTransformer(nn.Module):
    """
    Composer-conditioned (and optionally theory-conditioned) decoder-only
    Transformer.

    Args:
        vocab_size         : Music event vocabulary size (default 392).
        d_model            : Embedding / hidden dimension.
        n_heads            : Number of attention heads.
        n_layers           : Number of decoder layers.
        d_ff               : Feed-forward inner dimension.
        dropout            : Dropout rate.
        max_seq_len        : Maximum sequence length for positional encoding.
        num_composers      : Total number of distinct composers.
        composer_embed_dim : Dimension of the learned composer embedding
                             (projected to d_model before being added).
        use_theory         : If True, add key/chord/beat conditioning embeddings
                             and auxiliary prediction heads.
    """

    def __init__(
        self,
        vocab_size:         int   = 392,
        d_model:            int   = 512,
        n_heads:            int   = 8,
        n_layers:           int   = 6,
        d_ff:               int   = 2048,
        dropout:            float = 0.1,
        max_seq_len:        int   = 1024,
        num_composers:      int   = 10,
        composer_embed_dim: int   = 64,
        use_theory:         bool  = False,
        use_era:            bool  = False,
    ):
        super().__init__()
        self.d_model    = d_model
        self.use_theory = use_theory
        self.use_era    = use_era

        # ── Base components (identical to pre-theory architecture) ────────────
        self.token_embed    = nn.Embedding(vocab_size, d_model, padding_idx=389)
        self.composer_embed = nn.Embedding(num_composers, composer_embed_dim)
        self.composer_proj  = nn.Linear(composer_embed_dim, d_model, bias=False)

        # ── Era conditioning ─────────────────────────────────────────────────
        if use_era:
            self.era_embed = nn.Embedding(NUM_ERAS, d_model)
        self.pos_enc        = PositionalEncoding(d_model, max_seq_len, dropout)
        self.layers         = nn.ModuleList([
            DecoderLayer(d_model, n_heads, d_ff, dropout)
            for _ in range(n_layers)
        ])
        self.norm    = nn.LayerNorm(d_model)
        self.lm_head = nn.Linear(d_model, vocab_size, bias=False)

        # Tied weights: lm_head shares the token embedding matrix
        self.lm_head.weight = self.token_embed.weight

        # ── Theory components (only when use_theory=True) ────────────────────
        if use_theory:
            # Conditioning embeddings — each adds a d_model vector per position
            self.key_embed   = nn.Embedding(NUM_KEYS,   d_model)   # 25 entries
            self.chord_embed = nn.Embedding(NUM_CHORDS, d_model)   # 61 entries
            self.beat_embed  = nn.Embedding(NUM_BEATS,  d_model)   # 9  entries

            # Auxiliary heads used only during training for extra supervision
            self.chord_head  = nn.Linear(d_model, NUM_CHORDS)
            self.key_head    = nn.Linear(d_model, NUM_KEYS)

        self._init_weights()

    # ── Initialisation ────────────────────────────────────────────────────────

    def _init_weights(self):
        for name, p in self.named_parameters():
            if p.dim() > 1:
                nn.init.xavier_uniform_(p)
        # Small init for theory / era embeddings so they don't dominate at the start
        if self.use_theory:
            nn.init.normal_(self.key_embed.weight,   std=0.02)
            nn.init.normal_(self.chord_embed.weight, std=0.02)
            nn.init.normal_(self.beat_embed.weight,  std=0.02)
        if self.use_era:
            nn.init.normal_(self.era_embed.weight, std=0.02)

    # ── Forward ───────────────────────────────────────────────────────────────

    def forward(
        self,
        tokens:       torch.Tensor,                    # (B, T)  long
        composer_id:  torch.Tensor,                    # (B,)    long
        padding_mask: Optional[torch.Tensor] = None,   # (B, T)  bool  True=pad
        key_ids:      Optional[torch.Tensor] = None,   # (B, T)  long
        chord_ids:    Optional[torch.Tensor] = None,   # (B, T)  long
        beat_ids:     Optional[torch.Tensor] = None,   # (B, T)  long
        era_ids:      Optional[torch.Tensor] = None,   # (B,)    long
    ) -> Union[torch.Tensor, Tuple[torch.Tensor, torch.Tensor, torch.Tensor]]:
        """
        Returns:
            During eval  : logits  (B, T, vocab_size)
            During train, use_theory=True, theory inputs provided:
                           (logits, chord_aux_logits, key_aux_logits)
                           shapes: (B,T,V), (B,T,61), (B,T,25)
        """
        B, T   = tokens.shape
        device = tokens.device

        # Causal mask: upper-triangular -inf so each position only sees past
        causal_mask = torch.triu(
            torch.full((T, T), float('-inf'), device=device), diagonal=1
        )

        # Token embeddings + composer conditioning (broadcast over sequence)
        x  = self.token_embed(tokens)                              # (B, T, d_model)
        ce = self.composer_proj(self.composer_embed(composer_id))  # (B, d_model)
        x  = x + ce.unsqueeze(1)                                   # broadcast over T

        # Era conditioning (broadcast over sequence, same mechanism as composer)
        if self.use_era and era_ids is not None:
            x = x + self.era_embed(era_ids.long().clamp(0, NUM_ERAS - 1)).unsqueeze(1)

        # Theory conditioning (add per-position if provided and use_theory)
        if self.use_theory:
            if key_ids   is not None:
                x = x + self.key_embed(key_ids.long().clamp(0, NUM_KEYS - 1))
            if chord_ids is not None:
                x = x + self.chord_embed(chord_ids.long().clamp(0, NUM_CHORDS - 1))
            if beat_ids  is not None:
                x = x + self.beat_embed(beat_ids.long().clamp(0, NUM_BEATS - 1))

        x = self.pos_enc(x)

        for layer in self.layers:
            x = layer(x, causal_mask, key_padding_mask=padding_mask)

        hidden = self.norm(x)                          # (B, T, d_model)
        logits = self.lm_head(hidden)                  # (B, T, vocab_size)

        # During training with theory, return auxiliary logits as well
        if self.use_theory and self.training and (chord_ids is not None or key_ids is not None):
            chord_aux = self.chord_head(hidden)        # (B, T, 61)
            key_aux   = self.key_head(hidden)          # (B, T, 25)
            return logits, chord_aux, key_aux

        return logits
