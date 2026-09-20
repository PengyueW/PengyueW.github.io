# Source code

The complete source for every project shown on
[the projects page](https://wpygg4125.github.io/projects.html).

| Project | What it is | Source | Page |
|---|---|---|---|
| **Continuum** | A native macOS control center — cleaning, disk visualization, security scanning, hardware telemetry, app management. Swift/SwiftUI with a Python scanning engine. | [`continuum/`](continuum) | [Page](https://wpygg4125.github.io/projects/continuum.html) |
| **World Brief** | A local-first world news reader: ~700 feeds from 197 nations clustered into events, geolocated, ranked and translated entirely on your own machine. Python/FastAPI, vanilla JS, Kotlin. | [`world-brief/`](world-brief) | [Page](https://wpygg4125.github.io/projects/world-brief.html) |
| **Composer-Conditioned Music Generation** | A decoder-only transformer trained from scratch on 68 classical composers, conditioned on composer, era and music theory. PyTorch. | [`music-ml/`](music-ml) | [Page](https://wpygg4125.github.io/projects/music-ml.html) |
| **华夏五千年 · Historical Territories Timeline Map** | A zero-dependency static map of 137 Chinese and neighbouring polities across a timeline from 8000 BCE to today. Vanilla HTML/CSS/JS. | [`china-map/`](china-map) | [Page](https://wpygg4125.github.io/projects/china-map.html) · [Live](https://wpygg4125.github.io/projects/china-map/index.html) |

Each directory carries its own README with the architecture, how to build or run it, and its
licence where one applies.

## What is and is not here

These are source trees, not build outputs. Datasets, model checkpoints, virtual environments,
build directories, generated icons and signing material are excluded; every project's README
says how to fetch or regenerate what it needs. Shipped installers live alongside their project
pages under [`../projects/`](../projects).

The China Map tree is also served directly as the live demo from
[`../projects/china-map/`](../projects/china-map) — same code, no build step.

## How these were built

Every project here is **architected and directed by Pengyue Wang**, with **Claude** used as an
implementation assistant.

Claude generates boilerplate, scaffolds unit tests, and accelerates front-end visual work. The
engineering judgement is mine throughout: I conceptualise the architecture, peer-review the code
that comes back, debug the inconsistencies and functional flaws, and guide Claude through the
process — deciding what gets built next, how it should behave, and when it is done.

Each project's README states how that division of labour worked on that particular code base.
