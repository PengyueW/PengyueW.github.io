"""
v4 trainer — mixed precision, gradient accumulation, cosine LR with warmup,
label smoothing, and resume-safe checkpointing.

Checkpoints store the ModelConfig, the tokenizer's composer_map + vocab layout
inputs, optimizer/scheduler/scaler state, epoch and best-val so training can be
resumed across Kaggle sessions.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass, asdict
from typing import Optional

import torch
import torch.nn as nn
from torch.utils.data import DataLoader
from tqdm.auto import tqdm

from src.v4.model import MusicTransformerV4, ModelConfig


@dataclass
class TrainConfigV4:
    seq_len:        int   = 2048
    batch_size:     int   = 2       # per step; effective = batch_size * grad_accum
    grad_accum:     int   = 8
    num_epochs:     int   = 40
    lr:             float = 3e-4
    min_lr_frac:    float = 0.1     # cosine floor as a fraction of lr
    weight_decay:   float = 0.01
    warmup_steps:   int   = 1500
    grad_clip:      float = 1.0
    label_smoothing: float = 0.1
    num_workers:    int   = 2
    log_every:      int   = 50
    save_every_steps: int = 400     # mid-epoch 'last' checkpoint (Kaggle session safety); 0 = off
    ckpt_dir:       str   = "/kaggle/working/checkpoints_v4"


def _cosine_lr(step, warmup, total, min_frac):
    if step < warmup:
        return step / max(1, warmup)
    prog = (step - warmup) / max(1, total - warmup)
    prog = min(1.0, prog)
    return min_frac + (1 - min_frac) * 0.5 * (1 + math.cos(math.pi * prog))


class TrainerV4:
    def __init__(
        self,
        model:      MusicTransformerV4,
        model_cfg:  ModelConfig,
        train_ds,
        val_ds,
        cfg:        TrainConfigV4,
        device:     torch.device,
        composer_map: dict,
    ):
        self.model = model.to(device)
        self.model_cfg = model_cfg
        self.cfg = cfg
        self.device = device
        self.composer_map = composer_map
        os.makedirs(cfg.ckpt_dir, exist_ok=True)

        self.train_loader = DataLoader(
            train_ds, batch_size=cfg.batch_size, shuffle=True,
            num_workers=cfg.num_workers, pin_memory=(device.type == 'cuda'),
            drop_last=True,
        )
        self.val_loader = DataLoader(
            val_ds, batch_size=cfg.batch_size, shuffle=False,
            num_workers=cfg.num_workers, pin_memory=(device.type == 'cuda'),
        )

        # No weight decay on norms / embeddings / biases.
        decay, no_decay = [], []
        for n, p in model.named_parameters():
            if not p.requires_grad:
                continue
            (no_decay if (p.dim() < 2) else decay).append(p)
        self.optimizer = torch.optim.AdamW(
            [{'params': decay,    'weight_decay': cfg.weight_decay},
             {'params': no_decay, 'weight_decay': 0.0}],
            lr=cfg.lr, betas=(0.9, 0.95), eps=1e-8,
        )

        steps_per_epoch = max(1, len(self.train_loader) // cfg.grad_accum)
        self.total_steps = steps_per_epoch * cfg.num_epochs
        self.scheduler = torch.optim.lr_scheduler.LambdaLR(
            self.optimizer,
            lambda s: _cosine_lr(s, cfg.warmup_steps, self.total_steps, cfg.min_lr_frac),
        )
        self.scaler = torch.amp.GradScaler(enabled=(device.type == 'cuda'))
        self.criterion = nn.CrossEntropyLoss(
            ignore_index=model.cfg.pad_id, label_smoothing=cfg.label_smoothing
        )

    # ── One pass over a loader ───────────────────────────────────────────────
    def _run(self, loader, train: bool, epoch: int = 0, best_val: float = float('inf')):
        self.model.train(train)
        total, n = 0.0, 0
        pad_id = self.model.cfg.pad_id
        self.optimizer.zero_grad(set_to_none=True)

        with torch.set_grad_enabled(train):
            for step, (x, y) in enumerate(tqdm(loader, leave=False)):
                x = x.to(self.device, non_blocking=True)
                y = y.to(self.device, non_blocking=True)
                pad_mask = (x == pad_id)
                with torch.amp.autocast(self.device.type,
                                        enabled=(self.device.type in ('cuda', 'mps'))):
                    logits = self.model(x, key_padding_mask=pad_mask)
                    loss = self.criterion(
                        logits.reshape(-1, logits.size(-1)), y.reshape(-1)
                    )
                if train:
                    self.scaler.scale(loss / self.cfg.grad_accum).backward()
                    if (step + 1) % self.cfg.grad_accum == 0:
                        self.scaler.unscale_(self.optimizer)
                        nn.utils.clip_grad_norm_(self.model.parameters(), self.cfg.grad_clip)
                        self.scaler.step(self.optimizer)
                        self.scaler.update()
                        self.optimizer.zero_grad(set_to_none=True)
                        self.scheduler.step()
                    if (step + 1) % self.cfg.log_every == 0:
                        lr = self.scheduler.get_last_lr()[0]
                        print(f"  step {step+1:>6d} | loss {loss.item():.4f} | lr {lr:.2e}")
                    # Mid-epoch checkpoint so a killed Kaggle session loses little.
                    if self.cfg.save_every_steps and (step + 1) % self.cfg.save_every_steps == 0:
                        self._save(epoch, best_val, 'last')
                total += loss.item(); n += 1
        return total / max(1, n)

    # ── Checkpointing ────────────────────────────────────────────────────────
    def _save(self, epoch, best_val, tag):
        path = os.path.join(self.cfg.ckpt_dir, f"v4_{tag}.pt")
        torch.save({
            'model_state':   self.model.state_dict(),
            'optim_state':   self.optimizer.state_dict(),
            'sched_state':   self.scheduler.state_dict(),
            'scaler_state':  self.scaler.state_dict(),
            'model_cfg':     asdict(self.model_cfg),
            'composer_map':  self.composer_map,
            'epoch':         epoch,
            'best_val':      best_val,
        }, path)
        return path

    def train(self, start_epoch: int = 1, best_val: float = float('inf'),
              time_budget_s: Optional[float] = None, on_epoch_end=None):
        """
        Args:
            time_budget_s : if set, stop cleanly after the first epoch that
                            finishes past this wall-clock budget (Kaggle has a
                            9-12h session cap — leave headroom for generation).
            on_epoch_end  : optional callback(epoch, train_loss, val_loss, model)
                            e.g. to generate a preview MIDI each epoch.
        """
        import time
        t0 = time.time()
        for epoch in range(start_epoch, self.cfg.num_epochs + 1):
            tr = self._run(self.train_loader, train=True,  epoch=epoch, best_val=best_val)
            va = self._run(self.val_loader,   train=False, epoch=epoch, best_val=best_val)
            print(f"Epoch {epoch:>3d}/{self.cfg.num_epochs} | "
                  f"train {tr:.4f} | val {va:.4f} | ppl {math.exp(min(va,20)):.1f}")
            if va < best_val:
                best_val = va
                print("  ↳ new best:", self._save(epoch, best_val, 'best'))
            self._save(epoch, best_val, 'last')
            if on_epoch_end is not None:
                try:
                    on_epoch_end(epoch, tr, va, self.model)
                except Exception as e:
                    print("  (on_epoch_end callback failed:", e, ")")
            if time_budget_s is not None and (time.time() - t0) > time_budget_s:
                print(f"  ↳ time budget {time_budget_s/3600:.1f}h reached — stopping at epoch {epoch}.")
                break
        return best_val


def load_checkpoint(path: str, device: torch.device):
    """Rebuild model + config + composer_map from a checkpoint."""
    ckpt = torch.load(path, map_location=device, weights_only=False)
    mcfg = ModelConfig(**ckpt['model_cfg'])
    model = MusicTransformerV4(mcfg).to(device)
    model.load_state_dict(ckpt['model_state'])
    model.eval()
    return model, mcfg, ckpt['composer_map'], ckpt
