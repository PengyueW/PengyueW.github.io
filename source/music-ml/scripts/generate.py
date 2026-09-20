"""
CLI script: generate a piano MIDI file from a trained checkpoint.

Usage:
  python scripts/generate.py \
      --checkpoint checkpoints/checkpoint_best.pt \
      --composer   "Chopin" \
      --output     output/chopin_gen.mid \
      --max_tokens 1024 \
      --temperature 1.0 \
      --top_k 50 \
      --top_p 0.95
"""

import argparse
import os
import sys
import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.inference.generate import generate, load_model_from_checkpoint
from src.data.midi_parser import events_to_midi


def main():
    parser = argparse.ArgumentParser(description='Generate music with MusicTransformer')
    parser.add_argument('--checkpoint',  required=True,       help='Path to .pt checkpoint')
    parser.add_argument('--composer',    required=True,       help='Composer name (must exist in checkpoint)')
    parser.add_argument('--output',      default='output/generated.mid')
    parser.add_argument('--max_tokens',  type=int,   default=1024)
    parser.add_argument('--temperature', type=float, default=1.0)
    parser.add_argument('--top_k',       type=int,   default=50)
    parser.add_argument('--top_p',       type=float, default=0.95)
    parser.add_argument('--prompt_midi', default=None,
                        help='MIDI file whose opening tokens seed generation. '
                             'Strongly recommended — cold SOS starts produce sparse output.')
    parser.add_argument('--prompt_tokens', type=int, default=100,
                        help='How many tokens to take from --prompt_midi (default 100)')
    args = parser.parse_args()

    device = torch.device('cuda' if torch.cuda.is_available() else
                          'mps'  if torch.backends.mps.is_available() else 'cpu')
    print(f"Device: {device}")

    model, composer_map, cfg = load_model_from_checkpoint(args.checkpoint, device)

    if args.composer not in composer_map:
        print(f"[ERROR] Composer '{args.composer}' not in checkpoint. "
              f"Available: {list(composer_map.keys())}")
        sys.exit(1)

    composer_id = composer_map[args.composer]
    print(f"Generating as: {args.composer} (id={composer_id})")

    prompt_tokens = None
    if args.prompt_midi:
        from src.data.midi_parser import midi_to_events, SOS_TOKEN, EOS_TOKEN, PAD_TOKEN
        all_tokens = midi_to_events(args.prompt_midi)
        inner = [t for t in all_tokens if t not in (SOS_TOKEN, EOS_TOKEN, PAD_TOKEN)]
        prompt_tokens = inner[:args.prompt_tokens]
        print(f"Prompt: {args.prompt_midi} ({len(prompt_tokens)} tokens)")
    else:
        print("No --prompt_midi supplied. Output may be sparse. "
              "Pass --prompt_midi path/to/piece.mid for better results.")

    tokens = generate(
        model=model,
        composer_id=composer_id,
        device=device,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        top_k=args.top_k,
        top_p=args.top_p,
        prompt_tokens=prompt_tokens,
        context_window=cfg.seq_len,
    )
    print(f"Generated {len(tokens)} tokens.")

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    events_to_midi(tokens, args.output)
    print(f"Saved MIDI to: {args.output}")


if __name__ == '__main__':
    main()
