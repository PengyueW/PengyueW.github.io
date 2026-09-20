"""
v4 sampling — bar-aware nucleus sampling with a repetition penalty.

The model is a plain LM over the v4 vocabulary, so generation is standard
autoregressive sampling seeded with `[BOS, COMPOSER<id>, BAR]`. We keep the
context inside `max_seq_len` with a sliding window, apply a mild repetition
penalty (discourages the note-machine-gun failure mode), and stop at EOS or when
a target number of bars has been produced.
"""

from __future__ import annotations

import torch
import torch.nn.functional as F
from typing import List, Optional

from src.v4.tokenizer import REMITokenizer
from src.v4.model import MusicTransformerV4


def _filter_top_p(logits: torch.Tensor, top_p: float) -> torch.Tensor:
    if top_p >= 1.0:
        return logits
    sorted_logits, idx = torch.sort(logits, descending=True)
    probs = F.softmax(sorted_logits, dim=-1)
    cum = torch.cumsum(probs, dim=-1)
    remove = cum - probs > top_p
    sorted_logits[remove] = float('-inf')
    out = torch.full_like(logits, float('-inf'))
    return out.scatter(-1, idx, sorted_logits)


@torch.no_grad()
def generate(
    model:        MusicTransformerV4,
    tokenizer:    REMITokenizer,
    composer_name: str,
    device:       torch.device,
    max_bars:     int   = 64,
    max_tokens:   int   = 3000,
    temperature:  float = 0.95,
    top_p:        float = 0.92,
    top_k:        int   = 0,
    rep_penalty:  float = 1.15,
    rep_window:   int   = 128,
    prompt_tokens: Optional[List[int]] = None,
    seed:         Optional[int] = None,
) -> List[int]:
    """
    Returns a full token stream (incl. BOS/COMPOSER, excl. trailing PAD) ready to
    hand to `tokenizer.detokenize`.
    """
    if seed is not None:
        torch.manual_seed(seed)
    model.eval()

    cid = tokenizer.composer_map.get(composer_name)
    if cid is None:
        raise ValueError(f"Unknown composer {composer_name!r}. "
                         f"Options: {sorted(tokenizer.composer_map)[:8]}...")

    history: List[int] = [tokenizer.BOS, tokenizer.COMPOSER_BASE + cid]
    if prompt_tokens:
        history += list(prompt_tokens)
    else:
        history.append(tokenizer.BAR)

    max_ctx = model.cfg.max_seq_len
    bar_count = sum(1 for t in history if t == tokenizer.BAR)

    for _ in range(max_tokens):
        window = history[-max_ctx:]
        x = torch.tensor([window], dtype=torch.long, device=device)
        logits = model(x)[0, -1, :].float()

        # Never sample structural PAD/BOS or a composer token mid-stream.
        logits[tokenizer.PAD] = float('-inf')
        logits[tokenizer.BOS] = float('-inf')
        cb = tokenizer.COMPOSER_BASE
        logits[cb:cb + tokenizer.num_composers] = float('-inf')

        # Repetition penalty over the recent window.
        if rep_penalty and rep_penalty != 1.0:
            recent = set(history[-rep_window:])
            recent.discard(tokenizer.BAR)          # bars are meant to repeat
            if recent:
                idx = torch.tensor(sorted(recent), device=device)
                vals = logits[idx]
                vals = torch.where(vals > 0, vals / rep_penalty, vals * rep_penalty)
                logits[idx] = vals

        logits = logits / max(temperature, 1e-6)
        if top_k > 0:
            kth = torch.topk(logits, min(top_k, logits.numel())).values[-1]
            logits[logits < kth] = float('-inf')
        logits = _filter_top_p(logits, top_p)

        probs = F.softmax(logits, dim=-1)
        nxt = int(torch.multinomial(probs, 1).item())

        if nxt == tokenizer.EOS:
            break
        history.append(nxt)
        if nxt == tokenizer.BAR:
            bar_count += 1
            if bar_count >= max_bars:
                break

    return history
