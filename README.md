# wpygg4125.github.io

The personal site of **Pengyue Wang / 王鹏越** — software engineer.
Live at **[wpygg4125.github.io](https://wpygg4125.github.io/)**.

It is a static site with no build step: plain HTML, CSS and JavaScript with a vendored copy of
Bootstrap. Clone it and open `index.html`, or serve the directory with anything at all.

## What's in here

| Path | What |
|---|---|
| `index.html` | Landing page — about, selected work, contact |
| `projects.html` | Every project, each linking to its own page and to its source |
| `projects/` | One page per project, plus the shipped installers and the China Map live demo |
| [`source/`](source) | **The complete source code for every project on the site** |
| `tools/` | Small self-contained browser tools and games |
| `resources/` | Images, icons, fonts and textures used by the pages |

## The projects

Every project on the site is open, and its code is in [`source/`](source) — nothing here is a
screenshot of something you cannot read.

| Project | Source | Page |
|---|---|---|
| **Continuum** — native macOS control center (Swift/SwiftUI + a Python scanning engine) | [`source/continuum`](source/continuum) | [Page](https://wpygg4125.github.io/projects/continuum.html) |
| **World Brief** — local-first world news reader, ~700 feeds from 197 nations (Python/FastAPI, vanilla JS, Kotlin) | [`source/world-brief`](source/world-brief) | [Page](https://wpygg4125.github.io/projects/world-brief.html) |
| **Composer-Conditioned Music Generation** — a decoder-only transformer trained from scratch on 68 composers (PyTorch) | [`source/music-ml`](source/music-ml) | [Page](https://wpygg4125.github.io/projects/music-ml.html) |
| **华夏五千年 · Historical Territories Timeline Map** — zero-dependency historical map, 8000 BCE to today | [`source/china-map`](source/china-map) | [Page](https://wpygg4125.github.io/projects/china-map.html) · [Live](https://wpygg4125.github.io/projects/china-map/index.html) |

## How these were built

Every project here is **architected and directed by me**, with **Claude** used as an
implementation assistant. I think that is worth stating plainly rather than leaving to be
guessed at, so each project page and each source README says the same thing.

**What Claude did.** Boilerplate generation, unit-test scaffolding, accelerated front-end
visual work, and the routine implementation that follows once a design is settled.

**What I did.**

- **Conceptualised the architecture** — the module boundaries, the data models, and the
  constraints each project is built around: Continuum's feature-kit split and its privileged-task
  and safety boundaries, World Brief's local-first pipeline with no external AI service anywhere
  in it, the music model's tokenisation and conditioning scheme, the China Map's zero-dependency
  keyframe-and-interpolate design.
- **Peer-reviewed the code** that came back, reworking or rejecting what did not fit the design.
- **Debugged the inconsistencies and functional flaws** — the permission edge cases, the
  clustering that chained across unrelated stories, the conditioning the model was quietly
  ignoring, the seams between neighbouring polities.
- **Guided Claude throughout**, deciding what got built next, how it should behave, and when it
  was done.

The division of labour on each particular code base is described in that project's own README:
[Continuum](source/continuum/README.md) · [World Brief](source/world-brief/README.md) ·
[Music ML](source/music-ml/README.md) · [China Map](source/china-map/README.md).

## Contact

[wpyggg@gmail.com](mailto:wpyggg@gmail.com) ·
[GitHub](https://github.com/WpyGG4125) ·
[LinkedIn](https://www.linkedin.com/in/pengyue-wang/)

---

© Pengyue Wang. Individual projects carry their own licences where one applies — see
[`source/continuum/LICENSE`](source/continuum/LICENSE) (CC BY-NC-SA 4.0) and each project's README.
