# Skeleton generation: the libraries.dev hero sketch, element by element

Relay's loading sketch replicates the hero animation on https://libraries.dev/
(the transitions.dev "UI generation" effect). This is a breakdown of that
animation taken from the site's shipped source, and how each piece maps onto
`SkeletonGeneration` / `SkeletonLoaderView`.

## How the original runs

- One `UIGeneration.generate(element, …)` call per hero tile, five tiles,
  each delayed 100 ms after the previous. Hero options: `duration 1600`,
  `reveal "fade"`, `fadeDuration 475`, `revealAt 930`. The library default is
  `duration 2400` with a top-down "scan" reveal.
- The element is hidden (`opacity 0`); an SVG overlay is positioned over it
  with a 44 px margin on every side. Every frame is recomputed from
  `a = elapsed / duration` (fraction) and `s = elapsed ms`, on
  `requestAnimationFrame`, until `a ≥ 1.09`.
- The element's children are scanned into **parts**: boxes (background,
  border, media, controls), text lines (one per rendered line box), and small
  SVG icons (each child shape, with its transform). Boxes covering more than
  60 % of the element are skipped. Up to five boxes become **keys**
  (interactive first, then largest). A hero tile yields one part: its 108 px
  `SVG` icon (the outline rect plus the globe), tagged `SVG 108×108`.
- On the hero the whole overlay sits at `opacity 0.5` so it reads as a sketch
  behind the headline.

Timeline windows, as fractions of the duration:

| window  | from | to    | what happens |
|---------|------|-------|--------------|
| dots    | 0.00 | 0.30  | field wavefront expands from the centre |
| probe   | 0.02 | 0.24  | dotted vertical probe sweeps left→right |
| guides  | 0.04 | 0.30  | four edge guides trace in, 0.03 apart |
| outline | 0.10 | 0.42  | contour traces both halves from top centre |
| parts   | 0.28 | 0.74  | contents trace in, one 0.2 window per part |
| reveal  | 0.74 | 1.055 | real UI replaces the sketch |
| clean   | 0.84 | 1.04  | field dots fade |

Easings: `O = cubic-bezier(.16,1,.3,1)` for most motion, `H =
cubic-bezier(.22,1,.36,1)` for reveal, `U(a,b,t)` smoothstep. Dots along any
path **crawl** at 16 px/s (`dashoffset = -(ms·0.016) mod gap`) for the whole
run, so nothing is ever still.

## Every element

1. **Dot field** — grid at 15 px pitch from −30 to +44 px around the element,
   radius 1.1, ink `rgba(245,245,245,.3)`. Each dot has a distance to the
   centre `d`, an `edge` factor (1 inside, fading to 0 across the 44 px
   margin), a per-column drift speed `v = .07+.09·hash`, phase `ph`, trail
   length `tr = 50+70·hash`. Per frame:
   - wavefront `Y = O(dots)·(maxD+60)`: a dot shows once the front passes
     (`h = clamp((Y−d)/50)`), and a gaussian ring 6 px behind the front lights
     it (`u = exp(−((Y−d−6)/14)²)`) until `dots.end+.05`;
   - **rain**: per column a lit trail runs down at `v` px/ms, strength
     `(1−B/tr)^1.6`, gated by `S = U(.04,.2,a)·(1−U(.62,.86,a))`;
   - **reticle glow**: dots within 16 px of the current part's box light up
     (`C`, 1 inside, 0.6 outside) while the reticle shows;
   - **probe glow**: dots within a 9 px gaussian of the probe light (`P`);
   - `V = max(u, I, C·w·.8, P)`; opacity `max(h·.5·edge, V·edge)·clean·J`,
     radius `1.05 + V·.85`, and `V > .35` switches the fill to `strong`
     (`#a3a3a3`). In fade mode `J = 1 − fade`; in scan mode dots inside the
     element above the scan line vanish.
2. **Probe** — one dotted vertical line (dash `0 5`, round caps, 1.6 px,
   `#6f6f6f`) from −44 to h+44, x from −44 to w+44 on `O(probe)`, opacity
   `(fade-in 10 %)·(fade-out 15 %)·0.8`.
3. **Guides** — four lines along the element's edges extended 44 px past the
   corners (top →, right ↓, bottom ←, left ↑), dotted at 6.5 px, traced with
   the crawl, staggered 0.03, each over 0.17; opacity `.5·(1−U(.66,.92,a))`.
4. **Outline** — the rounded rect split into a right half and a left half,
   both starting at top centre and ending at bottom centre, traced together
   on `Q = O(outline)`. Dots 2.1 px (`--gen-dot`) at 4.8 px gap, `#6f6f6f`.
   Each half has a **head**: a 2.8 px `strong` disc sitting on the last placed
   dot while `0 < Q < 1`.
5. **Dimension readout** — 9 px Roboto Mono, `#6f6f6f`, baseline 10 px above
   the top-left corner: `` `${w·Q} × ${h·Q}   t+${a·duration}s` ``. The size
   counts up with the outline; the clock is real elapsed time. Opacity
   `.9·(1−U(.66,.9,a))` once the outline starts.
6. **Corner handles** — 5×5 squares, fill `#181818`, 1 px `strong` stroke,
   centred on the corners. Top pair pops at `a = .17`, bottom pair at `.37`,
   each `scale = O(clamp((a−at)/.1))`, and all shrink out over `.82–.96`.
7. **Flyers** — 44 discs (r 1.6, `strong`) that fly onto the outline. Flyer
   `t` targets fraction `.06+.9·⌊t/2⌋/21` of half `t mod 2`, starts
   `30–70 px` away at a hashed angle, and arrives exactly when the traced
   outline reaches that point (`arr = outline.start + len·O⁻¹(h)`), leaving
   0.09 earlier; opacity ramps over the first quarter of the flight, position
   eases with `O`.
8. **Parts** — spread over `[.28, .74]`: with `n` parts and window `D = .2`,
   part `i` starts at `.28 + (.46−.2)·i/(n−1)`. Inside a part, stroke `k`
   progresses as `O(clamp(i·strokes − k·.75))`. Boxes trace as a rounded rect
   (keys as two halves), text as one dotted baseline at `y + h·.56` with
   1.7 px end caps (start cap on start, end cap on completion), icons as
   their SVG shapes at 3.6 px gap and 1.8 px stroke. Every stroke carries a
   2.4 px `strong` head while live.
9. **Reticle and tag** — corner brackets (`strong`, 1.2 px, arm
   `min(7, w/3, h/3)`) around the current part's box expanded by 5 px. When
   the next part starts, the box lerps from the previous part (or the element)
   to the new one over 0.05 on `O`. Shown from `parts.start` (fade-in 0.04)
   until `reveal.start+.06`. The tag above it (7.5 px, uppercase, `strong`,
   letter-spacing .05em) reads `` `${name} ${w}×${h}` `` — `SVG 108×108` on
   the hero.
10. **Key chrome** — for each key box: four dotted guides reaching 16 px past
    its edges (traced from `t0−.03`, 0.012 apart, each over 0.1, opacity
    `.5·D′`), 4×4 handles (`scale = O(clamp((a−t0−.04)/.08))·D′`), and a
    7.5 px dimension label above the top-left corner counting up with the
    part's eased progress (`.9·D′`), where
    `D′ = 1 − U(reveal.start−.02, reveal.start+.1, a)`.
11. **Coordinate read-out** — 7.5 px `strong` label 6 px right and 5 px above
    the live head, `` `${x:03}·${y:03}` ``: the head's position in element
    space (the `022·130`, `051·130` readings). It follows whichever outline
    half or part stroke is currently live.
12. **Reveal** — scan mode: a 28 px glow gradient and a dotted scan line with
    two 2.3 px heads sweep down on `H(reveal)`; the element's clip-path
    follows with an 80 px soft zone, wires fade to 40 %, blur `3·(1−p)`.
    Fade mode (hero): the element fades in from `revealAt` over `fadeMs` with
    `blur(3·(1−r))` while wires and dots fade out over the same span from
    `reveal.start`. Chrome lets go in order: guides `.66–.92`, dimension
    `.66–.9`, key chrome `.72–.84`, handles `.82–.96`, dots `.84–1.04`.

## Relay Runner mapping

- `SkeletonGeneration` (Motion/) holds the timeline, easings, sampled paths,
  scene building and the per-frame evaluator, so each formula above is
  unit-testable without a view.
- `SkeletonLoaderView` runs a display link and renders each frame into pooled
  shape layers (dots batched by colour and opacity) plus monospace text
  layers. Reduce Motion and hidden views show the completed sketch without a
  display link.
- Elements: a layout's panels (board columns, Notes pane, Settings panes) or,
  without panels, its largest outlines (terminal welcome/prompt). Elements
  stagger 100 ms like the hero's tiles. Bones inside an element are its parts:
  outline bones are `FRAME` boxes (up to three become keys), small fill bones
  `BUTTON`s, line fill bones `TEXT`. One shared field covers the view; each
  dot belongs to its nearest element for the wavefront and edge fade.
- Scale: wire dots are 3 pt on a 5 pt pitch (the notch glyph's dot); every
  other radius keeps the reference ratio to the wire dot (×3/2.1). Field pitch
  15, margin 44, guide gap 6.5 and the 16 px/s crawl are kept as is.
- Colours come from the brand palette: ink/line/strong are the Settings muted
  slate at 0.3 / 0.62 / 1.0, handle fill is the board panel fill.
- Timing: `duration = 2.4 s × RelayMotion.durationScale`. The sketch
  constructs to `hold = .76` and waits there (crawl and rain keep running)
  until the host hands off; the handoff then plays `.76 → 1.09` under the
  existing `SkeletonAssembly` scan so chrome releases in the reference order.
