"""
Training loop for the MusicTransformer.

Supports:
  - Cosine LR schedule with linear warmup
  - Gradient clipping
  - Checkpointing (saves best val-loss and every N epochs)
  - Mixed-precision training via torch.amp
  - Multi-GPU via DataParallel (used automatically when >1 GPU is visible)
  - Theory fine-tuning (use_theory=True in TrainConfig):
      * Loads _theory.npy parallel files via MusicDataset
      * Passes key/chord/beat IDs as conditioning to the model
      * Adds auxiliary chord and key prediction losses
      * Optionally freezes token embedding rows 0-391 to preserve
        the 150-epoch backbone (freeze_base_embed=True)
"""

import os
import math
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, random_split
from tqdm import tqdm

from src.model.transformer import MusicTransformer
from src.data.dataset import MusicDataset
from src.training.config import TrainConfig
from src.data.midi_parser import PAD_TOKEN
from src.data.theory_extractor import KEY_UNKNOWN, CHORD_UNKNOWN
from src.data.composer_meta import build_era_lookup, COMPOSER_META


# ── LR schedule ───────────────────────────────────────────────────────────────

def _warmup_cosine_lr(step: int, warmup_steps: int, total_steps: int) -> float:
    if step < warmup_steps:
        return step / max(1, warmup_steps)
    progress = (step - warmup_steps) / max(1, total_steps - warmup_steps)
    return max(0.0, 0.5 * (1.0 + math.cos(math.pi * progress)))


# ── Trainer ───────────────────────────────────────────────────────────────────

class Trainer:
    def __init__(self, config: TrainConfig, composer_map: dict):
        self.cfg          = config
        self.composer_map = composer_map
        self.device       = torch.device(
            'cuda' if torch.cuda.is_available() else
            'mps'  if torch.backends.mps.is_available() else 'cpu'
        )
        print(f"Using device: {self.device}")

        # Build era lookup: (num_composers,) tensor mapping composer_id → era_id
        # Stored on CPU; moved to device inside _run_epoch as needed.
        self._era_lookup: torch.Tensor = build_era_lookup(composer_map)

        # Build per-composer auxiliary loss weight lookups (Part 3).
        # Indexed by composer_id; values from ComposerMeta.chord/key_aux_weight.
        # Composers absent from COMPOSER_META default to weight 1.0.
        n = len(composer_map)
        self._chord_weight_lookup = torch.ones(n)
        self._key_weight_lookup   = torch.ones(n)
        for name, cid in composer_map.items():
            m = COMPOSER_META.get(name)
            if m is not None:
                self._chord_weight_lookup[cid] = m.chord_aux_weight
                self._key_weight_lookup[cid]   = m.key_aux_weight

        self._build_dataloaders()
        self._build_model()
        self._build_optimizer()

        os.makedirs(config.checkpoint_dir, exist_ok=True)

    # ── Data ──────────────────────────────────────────────────────────────────

    def _build_dataloaders(self):
        cfg    = self.cfg
        n_gpus = torch.cuda.device_count() if self.device.type == 'cuda' else 1
        total_batch = cfg.batch_size * max(1, n_gpus)

        dataset = MusicDataset(
            data_dir=cfg.processed_data_dir,
            composer_map=self.composer_map,
            seq_len=cfg.seq_len,
            stride=cfg.stride,
            use_theory=cfg.use_theory,
        )
        n_train = int(len(dataset) * cfg.train_split)
        n_val   = len(dataset) - n_train
        train_ds, val_ds = random_split(
            dataset, [n_train, n_val],
            generator=torch.Generator().manual_seed(42)
        )
        self.train_loader = DataLoader(
            train_ds, batch_size=total_batch,
            shuffle=True,  num_workers=4, pin_memory=True
        )
        self.val_loader = DataLoader(
            val_ds, batch_size=total_batch,
            shuffle=False, num_workers=4, pin_memory=True
        )

    # ── Model ─────────────────────────────────────────────────────────────────

    def _build_model(self):
        cfg = self.cfg
        model = MusicTransformer(
            vocab_size=cfg.vocab_size,
            d_model=cfg.d_model,
            n_heads=cfg.n_heads,
            n_layers=cfg.n_layers,
            d_ff=cfg.d_ff,
            dropout=cfg.dropout,
            max_seq_len=cfg.max_seq_len,
            num_composers=len(self.composer_map),
            composer_embed_dim=cfg.composer_embed_dim,
            use_theory=cfg.use_theory,
            use_era=cfg.use_era,
        ).to(self.device)

        n_gpus = torch.cuda.device_count() if self.device.type == 'cuda' else 1
        if n_gpus > 1:
            print(f"Using {n_gpus} GPUs via DataParallel")
            model = nn.DataParallel(model)

        self.model = model
        n_params = sum(p.numel() for p in self.model.parameters() if p.requires_grad)
        print(f"Model parameters: {n_params:,}")

    # ── Optimizer ─────────────────────────────────────────────────────────────

    def _build_optimizer(self):
        cfg = self.cfg
        self.optimizer = torch.optim.AdamW(
            self.model.parameters(),
            lr=cfg.learning_rate,
            weight_decay=cfg.weight_decay,
        )
        total_steps = cfg.num_epochs * max(1, len(self.train_loader))
        self.scheduler = torch.optim.lr_scheduler.LambdaLR(
            self.optimizer,
            lr_lambda=lambda step: _warmup_cosine_lr(step, cfg.warmup_steps, total_steps),
        )
        self.scaler = torch.amp.GradScaler(enabled=(self.device.type == 'cuda'))

    # ── Embedding freeze ──────────────────────────────────────────────────────

    def freeze_old_embeddings(self):
        """
        Freeze token embedding rows 0-391 (the pre-trained vocabulary) by
        registering a gradient hook that zeroes those rows on every backward
        pass.  Theory token rows (392+) and the lm_head rows tied to them
        remain trainable.

        Call this after loading a backbone checkpoint, before training.
        """
        if not self.cfg.freeze_base_embed:
            return

        BASE_VOCAB = 392   # original vocabulary size

        def _zero_base_grad(grad: torch.Tensor) -> torch.Tensor:
            g = grad.clone()
            g[:BASE_VOCAB] = 0.0
            return g

        raw = self._raw_model()
        raw.token_embed.weight.register_hook(_zero_base_grad)
        print(f"Frozen token embedding rows 0-{BASE_VOCAB - 1} "
              f"(pre-trained vocabulary preserved).")

    # ── Loss ──────────────────────────────────────────────────────────────────

    def _loss(
        self,
        logits:       torch.Tensor,              # (B, T, V)
        targets:      torch.Tensor,              # (B, T)
        chord_logits: torch.Tensor = None,       # (B, T, 61)
        chord_labels: torch.Tensor = None,       # (B, T)
        key_logits:   torch.Tensor = None,       # (B, T, 25)
        key_labels:   torch.Tensor = None,       # (B, T)
        composer_ids: torch.Tensor = None,       # (B,)  — for per-composer weights
    ) -> torch.Tensor:
        B, T, V = logits.shape
        main_loss = nn.functional.cross_entropy(
            logits.reshape(B * T, V),
            targets.reshape(B * T),
            ignore_index=PAD_TOKEN,
        )

        if not (self.cfg.use_theory and chord_logits is not None):
            return main_loss

        w = self.cfg.theory_loss_weight

        # ── Per-sample auxiliary loss weights (Part 3) ────────────────────────
        # Look up chord_aux_weight and key_aux_weight per composer.
        # Composers absent from COMPOSER_META default to 1.0.
        # Shapes: (B,) on the same device as logits.
        dev = logits.device
        if composer_ids is not None:
            chord_w = self._chord_weight_lookup[composer_ids.cpu()].to(dev)
            key_w   = self._key_weight_lookup[composer_ids.cpu()].to(dev)
        else:
            chord_w = torch.ones(B, device=dev)
            key_w   = torch.ones(B, device=dev)

        # Compute per-token losses without reduction, then weight per sample.
        # ignore_index ensures unknown-label positions contribute zero gradient.
        chord_loss_flat = nn.functional.cross_entropy(
            chord_logits.reshape(B * T, chord_logits.size(-1)),
            chord_labels.reshape(B * T).long(),
            ignore_index=CHORD_UNKNOWN,
            reduction='none',
        )                                                   # (B*T,)
        chord_loss = (
            chord_loss_flat.reshape(B, T).mean(dim=1)       # (B,)
            * chord_w
        ).mean()

        key_loss_flat = nn.functional.cross_entropy(
            key_logits.reshape(B * T, key_logits.size(-1)),
            key_labels.reshape(B * T).long(),
            ignore_index=KEY_UNKNOWN,
            reduction='none',
        )                                                   # (B*T,)
        key_loss = (
            key_loss_flat.reshape(B, T).mean(dim=1)         # (B,)
            * key_w
        ).mean()

        return main_loss + w * chord_loss + w * 0.5 * key_loss

    # ── Epoch loop ────────────────────────────────────────────────────────────

    def _run_epoch(self, loader: DataLoader, train: bool) -> float:
        self.model.train(train)
        total_loss  = 0.0
        total_steps = 0

        with torch.set_grad_enabled(train):
            for step, batch in enumerate(tqdm(loader, leave=False)):

                # Unpack batch — 3-tuple (base) or 4-tuple (theory)
                if self.cfg.use_theory:
                    x, y, composer, theory = batch
                    # theory shape: (B, seq_len, 4) — columns: key,chord,beat,cadence
                    key_ids   = theory[:, :, 0].to(self.device)
                    chord_ids = theory[:, :, 1].to(self.device)
                    beat_ids  = theory[:, :, 2].to(self.device)
                else:
                    x, y, composer = batch
                    key_ids = chord_ids = beat_ids = None

                x        = x.to(self.device)
                y        = y.to(self.device)
                composer = composer.to(self.device)
                pad_mask = (x == PAD_TOKEN)

                # Derive era IDs from composer IDs via lookup table
                era_ids = None
                if self.cfg.use_era:
                    era_ids = self._era_lookup[composer.cpu()].to(self.device)

                with torch.amp.autocast(
                    self.device.type,
                    enabled=(self.device.type in ('cuda', 'mps'))
                ):
                    out = self.model(
                        x, composer,
                        padding_mask=pad_mask,
                        key_ids=key_ids,
                        chord_ids=chord_ids,
                        beat_ids=beat_ids,
                        era_ids=era_ids,
                    )

                    # During training with theory, model returns a 3-tuple
                    if self.cfg.use_theory and train and isinstance(out, tuple):
                        logits, chord_logits, key_logits = out
                        loss = self._loss(
                            logits, y,
                            chord_logits, chord_ids,
                            key_logits,   key_ids,
                            composer_ids=composer,
                        )
                    else:
                        logits = out if not isinstance(out, tuple) else out[0]
                        loss   = self._loss(logits, y)

                if train:
                    self.scaler.scale(loss).backward()
                    self.scaler.unscale_(self.optimizer)
                    nn.utils.clip_grad_norm_(self.model.parameters(), self.cfg.grad_clip)
                    self.scaler.step(self.optimizer)
                    self.scaler.update()
                    self.optimizer.zero_grad(set_to_none=True)
                    self.scheduler.step()

                total_loss  += loss.item()
                total_steps += 1

                if train and (step + 1) % self.cfg.log_every == 0:
                    lr = self.scheduler.get_last_lr()[0]
                    print(f"  step {step + 1:>6d} | loss {loss.item():.4f} | lr {lr:.2e}")

        return total_loss / max(1, total_steps)

    # ── Train ─────────────────────────────────────────────────────────────────

    def train(self, start_epoch: int = 1, best_val: float = float('inf')):
        cfg = self.cfg
        for epoch in range(start_epoch, cfg.num_epochs + 1):
            train_loss = self._run_epoch(self.train_loader, train=True)
            val_loss   = self._run_epoch(self.val_loader,   train=False)

            print(
                f"Epoch {epoch:3d}/{cfg.num_epochs} | "
                f"train {train_loss:.4f} | val {val_loss:.4f}"
            )

            if val_loss < best_val:
                best_val = val_loss
                self._save_checkpoint(epoch, val_loss, tag='best')

            if epoch % cfg.save_every == 0:
                self._save_checkpoint(epoch, val_loss, tag=f'epoch{epoch:04d}')

    # ── Checkpoint ────────────────────────────────────────────────────────────

    def _save_checkpoint(self, epoch: int, val_loss: float, tag: str):
        path = os.path.join(self.cfg.checkpoint_dir, f'checkpoint_{tag}.pt')
        torch.save({
            'epoch':           epoch,
            'val_loss':        val_loss,
            'model_state':     self._raw_model().state_dict(),
            'optim_state':     self.optimizer.state_dict(),
            'scheduler_state': self.scheduler.state_dict(),
            'config':          self.cfg,
            'composer_map':    self.composer_map,
        }, path)
        print(f"  Saved: {path}")

    def _raw_model(self) -> MusicTransformer:
        """Unwrap DataParallel if present."""
        return self.model.module if isinstance(self.model, nn.DataParallel) else self.model
