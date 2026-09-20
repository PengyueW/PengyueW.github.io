"""
Per-composer metadata derived from theory_reference.md (Parts 3–8).

Every entry covers all 68 IDs in composer_map.json and stores:

  era_id            : 0-5  (Baroque → Atonal)
  harmonic_tier     : 0-4  (strict tonal → atonal)
  national_style    : 'western' | 'russian' | 'spanish' | 'norwegian' |
                      'czech'   | 'romanian'| 'hungarian'| 'english'  | 'polish'
  is_transcription  : bool
  chord_aux_weight  : 0.0-1.0  weight on chord prediction auxiliary loss (Phase 1.5)
  key_aux_weight    : 0.0-1.0  weight on key prediction auxiliary loss   (Phase 1.5)
  in_key_bias       : 0.0-1.0  strength of in-key note boost during sampling (Phase 2)
  allow_parallel_fifths : bool  if True parallel P5s are NOT penalised in sampler
  augmented_second_ok   : bool  if True A2 melodic intervals are ENCOURAGED
  prefer_modal_cadence  : bool  if True ♭VII→I preferred over V→I
  dominant_res_strictness: 0.0-1.0  how strongly V must resolve to I during sampling

ERA IDs
───────
  0  Baroque          (~1583–1750)
  1  Classical         (~1732–1827)
  2  Early Romantic    (~1797–1886)
  3  Late Romantic / Nationalist (~1833–1928)
  4  Post-Romantic / Impressionist (~1862–1943)
  5  Modern / Atonal   (~1907+)

HARMONIC TIER
─────────────
  0  Strict tonal — all Part 1–2 rules enforced
  1  Tonal Romantic — chromatic extensions; dominant still resolves
  2  Late-Romantic chromatic — dominant often evaded; modal mixture normal
  3  Impressionist / proto-tonal — parallel chords; tonal centre weak
  4  Atonal — all functional constraints suspended

Usage
─────
  from src.data.composer_meta import COMPOSER_META, build_era_lookup
  era_tensor = build_era_lookup(composer_map)   # shape (num_composers,) long
"""

from dataclasses import dataclass
from typing import Dict, Optional
import torch


# ── Dataclass ─────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class ComposerMeta:
    era_id:                  int
    harmonic_tier:           int
    national_style:          str    # see module docstring for valid values
    is_transcription:        bool
    # Phase 1.5 — auxiliary loss weights
    chord_aux_weight:        float
    key_aux_weight:          float
    # Phase 2 — sampler constraint weights
    in_key_bias:             float
    allow_parallel_fifths:   bool
    augmented_second_ok:     bool
    prefer_modal_cadence:    bool
    dominant_res_strictness: float


# ── Era-level defaults (used as baselines for each entry below) ───────────────
#
# ERA_DEFAULTS[era_id] = dict of field → default value
# Individual entries OVERRIDE only the fields that deviate from the era default.

_D = [
    # era 0 — Baroque
    dict(harmonic_tier=0, chord_aux_weight=1.00, key_aux_weight=1.00,
         in_key_bias=0.85, allow_parallel_fifths=False, augmented_second_ok=False,
         prefer_modal_cadence=False, dominant_res_strictness=0.95),
    # era 1 — Classical
    dict(harmonic_tier=0, chord_aux_weight=0.90, key_aux_weight=0.90,
         in_key_bias=0.80, allow_parallel_fifths=False, augmented_second_ok=False,
         prefer_modal_cadence=False, dominant_res_strictness=0.90),
    # era 2 — Early Romantic
    dict(harmonic_tier=1, chord_aux_weight=0.75, key_aux_weight=0.75,
         in_key_bias=0.65, allow_parallel_fifths=False, augmented_second_ok=False,
         prefer_modal_cadence=False, dominant_res_strictness=0.75),
    # era 3 — Late Romantic / Nationalist
    dict(harmonic_tier=2, chord_aux_weight=0.60, key_aux_weight=0.60,
         in_key_bias=0.50, allow_parallel_fifths=False, augmented_second_ok=False,
         prefer_modal_cadence=False, dominant_res_strictness=0.55),
    # era 4 — Post-Romantic / Impressionist
    dict(harmonic_tier=3, chord_aux_weight=0.30, key_aux_weight=0.30,
         in_key_bias=0.25, allow_parallel_fifths=False, augmented_second_ok=False,
         prefer_modal_cadence=False, dominant_res_strictness=0.25),
    # era 5 — Modern / Atonal
    dict(harmonic_tier=4, chord_aux_weight=0.05, key_aux_weight=0.02,
         in_key_bias=0.05, allow_parallel_fifths=True,  augmented_second_ok=True,
         prefer_modal_cadence=False, dominant_res_strictness=0.02),
]


def _m(era: int, national: str = 'western', transcription: bool = False, **overrides) -> ComposerMeta:
    """Build a ComposerMeta from era defaults + named overrides."""
    base = dict(_D[era])
    base.update(overrides)
    return ComposerMeta(
        era_id=era,
        national_style=national,
        is_transcription=transcription,
        **base,
    )


# ── Full metadata table — all 68 composer_map.json entries ───────────────────
#
# Keys must match composer_map.json EXACTLY (including accents / slashes).
# Entries are ordered as in composer_map.json for readability; lookup is by key.

COMPOSER_META: Dict[str, ComposerMeta] = {

    # ── Individual composers ──────────────────────────────────────────────────

    # Berg — fully atonal (Op. 1 Sonata is tonal threshold but treated as atonal)
    'Alban Berg': _m(5),

    # Scriabin — spans early Chopin-like → proto-atonal; mid-point era 4
    # Lower weights than defaults because period ambiguity reduces label reliability
    'Alexander Scriabin': _m(4, chord_aux_weight=0.20, key_aux_weight=0.15,
                               in_key_bias=0.20, dominant_res_strictness=0.20),

    # Soler — Spanish Baroque/Classical transitional; Phrygian colour
    'Antonio Soler': _m(0, national='spanish', augmented_second_ok=True,
                        in_key_bias=0.82),

    # Weber — first fully Romantic pianist; harmonically straightforward
    'Carl Maria von Weber': _m(2, in_key_bias=0.68, dominant_res_strictness=0.78),

    # Gounod — French Romantic; sweet chromaticism; operatic lyricism
    'Charles Gounod': _m(3, harmonic_tier=1, in_key_bias=0.55,
                          dominant_res_strictness=0.60),

    # Debussy — Impressionism; parallel chords; whole-tone; tonal centre absent
    'Claude Debussy': _m(4, allow_parallel_fifths=True,
                          in_key_bias=0.10, chord_aux_weight=0.15,
                          key_aux_weight=0.10, dominant_res_strictness=0.05),

    # Franck — Wagner-influenced chromaticism + cyclic form + organ texture
    'César Franck': _m(3, in_key_bias=0.48, dominant_res_strictness=0.40,
                        chord_aux_weight=0.55, key_aux_weight=0.55),

    # Scarlatti — Spanish Baroque; hand crossings; repeated notes; binary form
    'Domenico Scarlatti': _m(0, national='spanish', in_key_bias=0.80,
                              augmented_second_ok=True),

    # Grieg — Norwegian nationalist; Lydian ♯4; parallel chords (late); ♭VII→I
    'Edvard Grieg': _m(3, national='norwegian',
                        allow_parallel_fifths=True, prefer_modal_cadence=True,
                        in_key_bias=0.48, chord_aux_weight=0.55, key_aux_weight=0.55),

    # Mendelssohn — Classical-Romantic synthesis; most metrically regular Romantic
    'Felix Mendelssohn': _m(2, harmonic_tier=1, in_key_bias=0.70,
                             dominant_res_strictness=0.80, chord_aux_weight=0.78,
                             key_aux_weight=0.78),

    # Liszt — spans early brilliant style to proto-atonal late works
    # Era 3 dominant; late pieces are era 4/5 but epoch weighting makes era 3 correct
    'Franz Liszt': _m(3, national='hungarian', in_key_bias=0.45,
                       augmented_second_ok=True,  # Hungarian Rhapsodies
                       dominant_res_strictness=0.42, chord_aux_weight=0.55,
                       key_aux_weight=0.52),

    # Schubert — hallmark third-relations; major/minor oscillation; lyrical
    'Franz Schubert': _m(2, in_key_bias=0.65, dominant_res_strictness=0.70,
                          chord_aux_weight=0.72, key_aux_weight=0.72),

    # Kreisler — Viennese late-Romantic violinist; light operatic lyricism
    'Fritz Kreisler': _m(3, harmonic_tier=1, in_key_bias=0.55,
                          dominant_res_strictness=0.60),

    # Chopin — most-represented composer; augmented second in mazurkas; wide span
    'Frédéric Chopin': _m(2, national='polish', augmented_second_ok=True,
                           in_key_bias=0.62, chord_aux_weight=0.73,
                           key_aux_weight=0.73),

    # Enescu — Romanian folk + French Impressionism; augmented seconds in melody
    'George Enescu': _m(3, national='romanian', augmented_second_ok=True,
                         allow_parallel_fifths=True, in_key_bias=0.46,
                         chord_aux_weight=0.50, key_aux_weight=0.50),

    # Handel — long melodic arches; diatonic; Italian opera influence
    'George Frideric Handel': _m(0, in_key_bias=0.87, dominant_res_strictness=0.96),

    # Bizet — French opera; Spanish colour (Carmen); habanera rhythm
    'Georges Bizet': _m(3, harmonic_tier=1, augmented_second_ok=True,
                         in_key_bias=0.55, dominant_res_strictness=0.60),

    # Verdi — Italian bel canto; clear tonal harmony; operatic
    'Giuseppe Verdi': _m(3, harmonic_tier=1, in_key_bias=0.58,
                          dominant_res_strictness=0.62),

    # Purcell — English Baroque; ground bass; chromatic; false relations
    'Henry Purcell': _m(0, national='english', in_key_bias=0.80,
                         chord_aux_weight=0.92, key_aux_weight=0.92),

    # Albéniz — Spanish nationalist; Phrygian; flamenco; augmented seconds
    'Isaac Albéniz': _m(3, national='spanish', augmented_second_ok=True,
                         in_key_bias=0.45, chord_aux_weight=0.52,
                         key_aux_weight=0.52),

    # Rameau — French Baroque; theorist of tonal harmony; agréments
    'Jean-Philippe Rameau': _m(0, in_key_bias=0.86, dominant_res_strictness=0.95),

    # Fischer — galant transitional; simple 4-bar phrases; galant schemas
    'Johann Christian Fischer': _m(1, in_key_bias=0.82, dominant_res_strictness=0.91),

    # Pachelbel — clear circle-of-fifths sequences; Lutheran chorale style
    'Johann Pachelbel': _m(0, in_key_bias=0.88, dominant_res_strictness=0.96),

    # Bach — most harmonically rich Baroque; strict counterpoint exemplar
    'Johann Sebastian Bach': _m(0, in_key_bias=0.87, dominant_res_strictness=0.97,
                                 chord_aux_weight=1.00, key_aux_weight=1.00),

    # Strauss — Viennese waltz; oom-pah-pah; lilt timing
    'Johann Strauss': _m(2, in_key_bias=0.68, dominant_res_strictness=0.76),

    # Brahms — Neo-Classical rigour; hemiola; iv in major; conservative Romantic
    'Johannes Brahms': _m(3, in_key_bias=0.52, dominant_res_strictness=0.60,
                           chord_aux_weight=0.62, key_aux_weight=0.62),

    # Haydn — Classical wit; irregular phrases; developmental first themes
    'Joseph Haydn': _m(1, in_key_bias=0.79, dominant_res_strictness=0.89),

    # Janáček — speech melody; obsessive cells; open endings; modal; parallel chords
    'Leoš Janáček': _m(3, national='czech',
                        allow_parallel_fifths=True, prefer_modal_cadence=True,
                        in_key_bias=0.40, chord_aux_weight=0.35,
                        key_aux_weight=0.30, dominant_res_strictness=0.20),

    # Beethoven — spans early Classical to proto-Romantic; sforzando; motivic
    'Ludwig van Beethoven': _m(1, harmonic_tier=1, in_key_bias=0.75,
                                dominant_res_strictness=0.82, chord_aux_weight=0.82,
                                key_aux_weight=0.82),

    # Glinka — father of Russian music; Italian lyricism + folk modes; ♭VII→I
    'Mikhail Glinka': _m(2, national='russian',
                          augmented_second_ok=True, prefer_modal_cadence=True,
                          in_key_bias=0.60, chord_aux_weight=0.70,
                          key_aux_weight=0.70),

    # Balakirev — Russian nationalist; Eastern/Caucasian scales; adventurous harmony
    'Mily Balakirev': _m(2, national='russian',
                          augmented_second_ok=True, prefer_modal_cadence=True,
                          in_key_bias=0.55, chord_aux_weight=0.68,
                          key_aux_weight=0.65),

    # Mussorgsky — Pictures; asymmetric meter; parallel chords; modal cadences
    'Modest Mussorgsky': _m(3, national='russian',
                             allow_parallel_fifths=True, augmented_second_ok=True,
                             prefer_modal_cadence=True, in_key_bias=0.45,
                             chord_aux_weight=0.48, key_aux_weight=0.45),

    # Clementi — Classical pianistic pioneer; sonatinas; Gradus ad Parnassum
    'Muzio Clementi': _m(1, in_key_bias=0.81, dominant_res_strictness=0.90),

    # Paganini — virtuoso violin source material for transcriptions
    'Niccolò Paganini': _m(2, harmonic_tier=1, in_key_bias=0.72,
                            dominant_res_strictness=0.80),

    # Medtner — conservative Romantic; dense counterpoint; extended tonality
    'Nikolai Medtner': _m(4, national='russian', harmonic_tier=2,
                           in_key_bias=0.60, dominant_res_strictness=0.75,
                           chord_aux_weight=0.55, key_aux_weight=0.55),

    # Rimsky-Korsakov — octatonic; Russian nationalist; orchestral colour
    'Nikolai Rimsky-Korsakov': _m(3, national='russian',
                                   augmented_second_ok=True, prefer_modal_cadence=True,
                                   in_key_bias=0.50, chord_aux_weight=0.52,
                                   key_aux_weight=0.50),

    # Gibbons — English Renaissance/early Baroque; false relations; modal
    'Orlando Gibbons': _m(0, national='english', in_key_bias=0.78,
                           chord_aux_weight=0.88, key_aux_weight=0.85),

    # Grainger — Australian folk collector; irregular meters; impressionistic harmony
    'Percy Grainger': _m(4, national='english', harmonic_tier=3,
                          allow_parallel_fifths=True, prefer_modal_cadence=True,
                          in_key_bias=0.30, chord_aux_weight=0.25,
                          key_aux_weight=0.25),

    # Tchaikovsky — Russian lyricism; emotional collapse leaps; ♭VII→I; sequences
    'Pyotr Ilyich Tchaikovsky': _m(3, national='russian',
                                    augmented_second_ok=True, prefer_modal_cadence=True,
                                    in_key_bias=0.55, chord_aux_weight=0.57,
                                    key_aux_weight=0.57),

    # Wagner — Tristan chord; endless melody; chromatic voice leading; leitmotif
    'Richard Wagner': _m(3, in_key_bias=0.38, dominant_res_strictness=0.15,
                          chord_aux_weight=0.45, key_aux_weight=0.42),

    # Schumann — character piece cycles; syncopation; inner-voice melody
    'Robert Schumann': _m(2, in_key_bias=0.64, chord_aux_weight=0.74,
                           key_aux_weight=0.74),

    # Rachmaninoff — Post-Romantic; bell texture; dense; very tonal
    'Sergei Rachmaninoff': _m(4, national='russian', harmonic_tier=2,
                               in_key_bias=0.60, dominant_res_strictness=0.70,
                               prefer_modal_cadence=True,
                               chord_aux_weight=0.55, key_aux_weight=0.55),

    # Mozart — Classical epitome; balanced; Mozartian cadential suffix
    'Wolfgang Amadeus Mozart': _m(1, in_key_bias=0.81, dominant_res_strictness=0.91),


    # ── Transcription / arrangement entries ───────────────────────────────────
    #
    # General rule: transcriber's texture style dominates; source's harmonic
    # skeleton partially preserved.  Era follows transcriber; harmonic tier
    # follows the blend described in theory_reference.md Part 8.

    # Gounod / Liszt — Bach harmonic skeleton + Gounod melody + Liszt elaboration
    'Charles Gounod _ Franz Liszt': _m(3, transcription=True,
                                        in_key_bias=0.75, dominant_res_strictness=0.88,
                                        chord_aux_weight=0.82, key_aux_weight=0.82),

    # Mendelssohn / Rachmaninoff — transcriber (Rachmaninoff) dominates texture
    'Felix Mendelssohn _ Sergei Rachmaninoff': _m(4, national='russian',
                                                   transcription=True, harmonic_tier=2,
                                                   in_key_bias=0.58, prefer_modal_cadence=True,
                                                   dominant_res_strictness=0.68,
                                                   chord_aux_weight=0.52, key_aux_weight=0.52),

    # Liszt / Saint-Saëns — Late Romantic French virtuoso blend
    'Franz Liszt _ Camille Saint-Saëns': _m(3, transcription=True,
                                             in_key_bias=0.48,
                                             dominant_res_strictness=0.50,
                                             chord_aux_weight=0.55, key_aux_weight=0.55),

    # Schubert / Liszt — Schubert third-relations + Liszt texture
    'Franz Schubert _ Franz Liszt': _m(3, transcription=True, in_key_bias=0.52,
                                        dominant_res_strictness=0.55,
                                        chord_aux_weight=0.58, key_aux_weight=0.58),

    # Schubert / Godowsky — densest polyphonic Schubert in dataset
    'Franz Schubert _ Leopold Godowsky': _m(4, transcription=True, harmonic_tier=2,
                                             in_key_bias=0.55, dominant_res_strictness=0.60,
                                             chord_aux_weight=0.55, key_aux_weight=0.55),

    # Kreisler / Rachmaninoff — Kreisler lyricism + Rachmaninoff bell texture
    'Fritz Kreisler _ Sergei Rachmaninoff': _m(4, national='russian',
                                                transcription=True, harmonic_tier=2,
                                                in_key_bias=0.56, prefer_modal_cadence=True,
                                                dominant_res_strictness=0.65,
                                                chord_aux_weight=0.50, key_aux_weight=0.50),

    # Bizet / Busoni — Bizet Spanish colour + Busoni counterpoint
    'Georges Bizet _ Ferruccio Busoni': _m(3, transcription=True,
                                            augmented_second_ok=True, in_key_bias=0.48,
                                            chord_aux_weight=0.52, key_aux_weight=0.50),

    # Bizet / Moszkowski — lighter salon arrangement
    'Georges Bizet _ Moritz Moszkowski': _m(3, transcription=True,
                                             harmonic_tier=1, in_key_bias=0.55,
                                             dominant_res_strictness=0.58,
                                             chord_aux_weight=0.56, key_aux_weight=0.56),

    # Bizet / Horowitz — Carmen Fantasy; extreme virtuosity
    'Georges Bizet _ Vladimir Horowitz': _m(3, transcription=True, harmonic_tier=2,
                                             augmented_second_ok=True, in_key_bias=0.48,
                                             dominant_res_strictness=0.50,
                                             chord_aux_weight=0.50, key_aux_weight=0.48),

    # Verdi / Liszt — operatic paraphrase; full keyboard range
    'Giuseppe Verdi _ Franz Liszt': _m(3, transcription=True, in_key_bias=0.50,
                                        dominant_res_strictness=0.52,
                                        chord_aux_weight=0.55, key_aux_weight=0.55),

    # Albéniz / Godowsky — maximum polyphonic Spanish complexity
    'Isaac Albéniz _ Leopold Godowsky': _m(3, national='spanish',
                                            transcription=True, harmonic_tier=2,
                                            augmented_second_ok=True, in_key_bias=0.42,
                                            chord_aux_weight=0.48, key_aux_weight=0.46),

    # Fischer / Mozart — Mozart variations on Fischer minuet; Classical harmonic skeleton
    'Johann Christian Fischer _ Wolfgang Amadeus Mozart': _m(1, transcription=True,
                                                              in_key_bias=0.81,
                                                              dominant_res_strictness=0.90,
                                                              chord_aux_weight=0.88,
                                                              key_aux_weight=0.88),

    # Bach / Petri — scholarly faithful; close to original Bach
    'Johann Sebastian Bach _ Egon Petri': _m(0, transcription=True,
                                              in_key_bias=0.86, dominant_res_strictness=0.96,
                                              chord_aux_weight=0.95, key_aux_weight=0.95),

    # Bach / Busoni — Baroque harmony + Romantic texture density
    'Johann Sebastian Bach _ Ferruccio Busoni': _m(0, transcription=True,
                                                    harmonic_tier=1, in_key_bias=0.82,
                                                    dominant_res_strictness=0.92,
                                                    chord_aux_weight=0.90, key_aux_weight=0.90),

    # Bach / Liszt — Baroque harmony + Lisztian Romantic drama
    'Johann Sebastian Bach _ Franz Liszt': _m(0, transcription=True,
                                               harmonic_tier=1, in_key_bias=0.82,
                                               dominant_res_strictness=0.90,
                                               chord_aux_weight=0.88, key_aux_weight=0.88),

    # Bach / Hess — simplest Bach transcription; most regular MIDI in dataset
    'Johann Sebastian Bach _ Myra Hess': _m(0, transcription=True,
                                             in_key_bias=0.88, dominant_res_strictness=0.97,
                                             chord_aux_weight=0.97, key_aux_weight=0.97),

    # Strauss / Grünfeld — salon concert arrangement; Viennese waltz
    'Johann Strauss _ Alfred Grünfeld': _m(3, transcription=True, harmonic_tier=1,
                                            in_key_bias=0.58, dominant_res_strictness=0.65,
                                            chord_aux_weight=0.60, key_aux_weight=0.60),

    # Glinka / Balakirev — two Russian nationalists; shared style
    'Mikhail Glinka _ Mily Balakirev': _m(2, national='russian',
                                           transcription=True,
                                           augmented_second_ok=True, prefer_modal_cadence=True,
                                           in_key_bias=0.58, chord_aux_weight=0.68,
                                           key_aux_weight=0.65),

    # Paganini / Liszt — Paganini Études; most technically demanding
    'Niccolò Paganini _ Franz Liszt': _m(2, transcription=True, harmonic_tier=2,
                                          augmented_second_ok=True, in_key_bias=0.55,
                                          dominant_res_strictness=0.55,
                                          chord_aux_weight=0.58, key_aux_weight=0.55),

    # Rimsky-Korsakov / Rachmaninoff — octatonic + bell texture
    'Nikolai Rimsky-Korsakov _ Sergei Rachmaninoff': _m(4, national='russian',
                                                          transcription=True, harmonic_tier=2,
                                                          augmented_second_ok=True,
                                                          prefer_modal_cadence=True,
                                                          in_key_bias=0.48,
                                                          chord_aux_weight=0.45,
                                                          key_aux_weight=0.42),

    # Tchaikovsky / Pletnev — most orchestrally idiomatic; extreme registral range
    'Pyotr Ilyich Tchaikovsky _ Mikhail Pletnev': _m(3, national='russian',
                                                       transcription=True, harmonic_tier=2,
                                                       augmented_second_ok=True,
                                                       prefer_modal_cadence=True,
                                                       in_key_bias=0.52,
                                                       chord_aux_weight=0.52,
                                                       key_aux_weight=0.52),

    # Tchaikovsky / Rachmaninoff — densest Russian Romantic in dataset
    'Pyotr Ilyich Tchaikovsky _ Sergei Rachmaninoff': _m(4, national='russian',
                                                           transcription=True, harmonic_tier=2,
                                                           augmented_second_ok=True,
                                                           prefer_modal_cadence=True,
                                                           in_key_bias=0.55,
                                                           dominant_res_strictness=0.65,
                                                           chord_aux_weight=0.52,
                                                           key_aux_weight=0.52),

    # Schumann / Liszt — inner-voice melody + Liszt elaboration
    'Robert Schumann _ Franz Liszt': _m(3, transcription=True, in_key_bias=0.50,
                                         dominant_res_strictness=0.48,
                                         chord_aux_weight=0.55, key_aux_weight=0.55),

    # Rachmaninoff / Cziffra — extreme virtuosity beyond even Rachmaninoff
    'Sergei Rachmaninoff _ György Cziffra': _m(4, national='russian',
                                                transcription=True, harmonic_tier=2,
                                                prefer_modal_cadence=True, in_key_bias=0.58,
                                                dominant_res_strictness=0.68,
                                                chord_aux_weight=0.52, key_aux_weight=0.50),

    # Rachmaninoff / Gryaznov — straightforward reduction; close to source
    'Sergei Rachmaninoff _ Vyacheslav Gryaznov': _m(4, national='russian',
                                                      transcription=True, harmonic_tier=2,
                                                      prefer_modal_cadence=True, in_key_bias=0.58,
                                                      dominant_res_strictness=0.68,
                                                      chord_aux_weight=0.52, key_aux_weight=0.50),
}


# ── Lookup helpers ────────────────────────────────────────────────────────────

NUM_ERAS = 6    # era IDs 0-5


def build_era_lookup(composer_map: dict, default_era: int = 2) -> torch.Tensor:
    """
    Build a (num_composers,) long tensor mapping composer_id → era_id.

    Composers whose name is not in COMPOSER_META receive `default_era`
    (2 = Early Romantic, a neutral mid-point fallback).

    Args:
        composer_map : dict mapping composer name → int ID
        default_era  : era_id to use for unrecognised names

    Returns:
        torch.LongTensor of shape (num_composers,)
    """
    n      = len(composer_map)
    lookup = torch.full((n,), default_era, dtype=torch.long)
    for name, cid in composer_map.items():
        meta = COMPOSER_META.get(name)
        if meta is not None:
            lookup[cid] = meta.era_id
    return lookup


def get_meta(composer_name: str) -> Optional[ComposerMeta]:
    """Return ComposerMeta for a given name, or None if not found."""
    return COMPOSER_META.get(composer_name)


def get_era_id(composer_name: str, default: int = 2) -> int:
    """Return the era_id for a composer name, or `default` if not found."""
    meta = COMPOSER_META.get(composer_name)
    return meta.era_id if meta is not None else default
