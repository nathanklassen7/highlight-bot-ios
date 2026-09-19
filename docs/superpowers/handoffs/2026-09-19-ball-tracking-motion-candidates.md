# Handoff: ball tracking — build the candidate stage on the motion mask

You are picking up ball tracking for the HighlightBot iOS app with fresh context. This document is your brief. Read it fully, then read the three files it points at before touching code. Do not trust any earlier summary that claims the tracker works; the evidence below shows it did not, and explains why.

## 1. The one-paragraph state

The repo has a working, reviewed pipeline for analysing a saved clip and drawing a ball overlay in the player: a SwiftPM package `BallTracking/` (detectors, tracker, offline runner, overlay geometry, a `balltrack-lab` CLI) and the app wiring (`ClipTrackService`, sidecar storage, `BallTrackOverlay` in `ClipPlayerScreen`). All of it works mechanically. What does not work is the **detection**: neither Apple Vision's trajectory request nor the luma-blob detector reliably finds the ball. The user reviewed motion-isolated renders of the reference clip and chose a specific motion mask (two-frame absolute difference on grey, threshold 60, one 3×3 dilation). Your job is to build the candidate stage on that mask, then a trajectory stage that picks the ball out of the candidates by its motion, keeping every step visually inspectable.

## 2. Ground truth you can rely on

Reference clip: `/Users/nathan.klassen/Documents/pp highlights/8b95514af4e6468faee879eb63c1dd97.mp4` — 1920×1080, 50 fps (dt = 0.02 s), 20.34 s, 1018 frames, H.264. Static wide-angle corner shot, slight fisheye. Dark table and walls. Near player in a white shirt, far player in a pink shirt. Referred to as `$CLIP`.

**User-confirmed ball location:** frame 18 (t = 0.36 s), centre ≈ pixel (991, 494), normalised (0.516, 0.457). Measured in the raw luma plane: bounding box x 986–996, y 491–497 → **11 × 7 px**, elongated horizontally by motion blur; peak luma 237 on a table at 30–50; chroma neutral (Cb 127, Cr 121). The ball is small but high-contrast. It is not "too small to see".

Other measured facts from the same clip:
- Ball radius as a fraction of frame width ≈ 0.002–0.004. Per-frame displacement in flight ≈ 10–60 px.
- Chroma deviation `max(|Cb−128|, |Cr−128|)`: ball 4–13; skin 21–31; hair 36; red paddle rubber 30; pink shirt 16; white paddle rim 6.
- Surround (ring) luma around a blob: ball 35; shirt fragments 120–215.
- With the chosen mask at frame 18, ~0.3 % of pixels are "moving"; the ball is a solid compact dot; players render as thin edge outlines because slow motion only changes boundary pixels.

## 3. What was tried and why it failed (do not repeat)

| Attempt | Result | Evidence |
| --- | --- | --- |
| Vision `VNDetectTrajectoriesRequest`, radius 0.002–0.03, trajectoryLength 6 | 75 % "tracking" — all on the near player's head, shirt edges, paddle; ring radii 9–16 px | zoom crops under the ring at frames 150, 314, 620, 884 show head/sleeve |
| Vision, radius capped to 0.005 (ball-sized) | 0.06 candidates/frame, 3.5 % visible | Vision does not emit trajectories for an 11×7 px object at 1080p |
| Luma-blob detector (bright ∧ moved, area/aspect/fill filters, top 8 by brightness) | Sees the ball (area 13 blob at the right spot) but returns it with ~45 shirt fragments and drops it under the 8-candidate cap | Python replication on frames 17→18 |
| + surround-luma isolation filter (< 90) | Ball ranked first at frame 18; radii now 3–7 px; but a 12-frame audit found the ring on the ball in only ~2 frames — the rest were lit faces, hands, hair, paddle rubber | `/tmp/balltrack/iso_grid.png` method, see §7 |
| + chroma filter (max deviation 16) | Implemented and unit-tested; not evaluated on footage because the user redirected to a motion-first approach | uncommitted in the tree, see §5 |

The lesson: per-frame appearance cannot separate a 10 px white streak from the hundreds of other bright specks a scene produces. Across ten frames, the ball is the only thing that traces a smooth, near-parabolic path at ball speed. The decision has to be made in the time domain, on a sparse candidate field. The user's chosen mask is the way to make that field sparse.

Summary numbers printed by the lab ("tracking fraction", "visible fraction") were misleading twice tonight. They measure how often the tracker *believed* it had something, not whether it was the ball. Never accept them without the zoom audit in §7.

## 4. The chosen mask (build on exactly this)

Two-frame absolute difference on the grey (luma) plane, threshold 60, one 3×3 dilation. The user reviewed thresholds 25/40/60/90 and two- vs three-frame differencing and chose two-frame at 60. Reference render used for that decision:

```sh
ffmpeg -i "$CLIP" -vf "format=gray,tblend=all_mode=difference,geq=lum='if(gt(lum(X,Y),60),255,0)',dilation,format=yuv420p" \
  -c:v libx264 -crf 18 -an /tmp/balltrack/motion_white_t60.mp4
```

Notes that matter when you reimplement it in Swift:
- `format=gray` must happen **before** the difference. Differencing yuv420p directly produced garbage (limited-range offset made everything "moving").
- The luma plane of the 420v pixel buffers the app already delivers is exactly the grey input. No colour conversion.
- Existing code downsamples the luma plane 2× (960×540) before analysis. The user's mask was rendered at full resolution. Start at full resolution to match what was approved; downsample only if profiling demands it, and re-render the mask video to confirm it still matches.
- The ffmpeg render is the oracle: your Swift mask must match it frame for frame (see Task A).

## 5. State of the repository

Branch `ball-tracking`, HEAD `381d26b` (phase 1 complete and reviewed). Read these first:
- `docs/superpowers/specs/2026-09-18-ball-tracking-design.md` — architecture and interfaces. Still valid for everything except the detector choice.
- `docs/superpowers/plans/2026-09-18-ball-tracking.md` — the original 14-task plan. Tasks 1–10 are done. Task 8's decision (Vision default) is superseded by this handoff. Tasks 11–14 (device verification, live overlay) are on hold until detection works.
- `docs/superpowers/specs/2026-09-18-ball-tracking-lab-results.md` — **overclaims**; the "chosen" Vision configuration was ringing heads. Rewrite it when you have real results.
- `.superpowers/sdd/2026-09-18-ball-tracking/progress.md` — the execution ledger with every ruling made so far.

Package layout (`BallTracking/`):
- `Model/` — `BallObservation` (time, normalised centre, radius, confidence), `BallTrackFrame` (time, state, position, velocity, radius, candidateCount), `BallTrack` (whole-clip result, Codable, `frame(at:)`, `trail(endingAt:duration:)`).
- `Tracking/` — `BallDetector` protocol, `BallDetectorKind` factory, `BallTracker` (single-target alpha-beta, to be replaced by a trajectory stage), `BallTrail`.
- `Detectors/` — `VisionTrajectoryDetector`, `LumaBlobDetector` (vImage downsample, diff, threshold, connected components, filters), `SampleBufferFactory`.
- `Offline/` — `ClipTrackRunner` (AVAssetReader → detector → tracker → `BallTrack`), `FrameOrientation`.
- `Overlay/` — `OverlayGeometry`.
- `Sources/balltrack-lab/` — CLI: `run` (writes `track.json`, `summary.json`, `annotated.mp4`, prints an ASCII timeline), `extract` (PNG frames), `score` (against a hand-labelled `truth.json`).
- Tests: Swift Testing; helpers `SyntheticFrames.make420v(...)` (draw discs into 420v buffers, with per-disc chroma) and `SyntheticMovie.write(...)` (encode a synthetic H.264 movie).

**Uncommitted changes in `BallTracking/`** (leave them uncommitted until you decide):
- `LumaBlobDetector.swift` — surround-luma isolation filter and chroma filter added, isolation-weighted confidence. Unit tests pass (38/38 package). Useful later as *soft scores* on candidates; not useful as hard rejects for a candidate stage that should stay loose.
- `BallDetectorKind.swift` — default switched to `.luma`.
- `VisionTrajectoryDetector.swift` — max radius 0.005 (honest, near-useless).
- Tests and `SyntheticFrames` updated accordingly.
Recommendation: commit them as "groundwork" once you have decided how they feed the new candidate stage, or revert them; either is defensible. Do not leave them dangling at the end.

**Do not stage anything under `HighlightBot/`** unless your task explicitly changes it — the user edits app files concurrently. Always `git add` by explicit path.

## 6. What to build

Two stages behind the existing `BallDetector`/tracker seams, each with its own visual output.

**Stage 1 — motion candidate generator** (`MotionCandidateDetector: BallDetector`, new file in `Detectors/`).
Per frame: luma plane → `|Y_t − Y_{t−1}|` → threshold 60 → 3×3 dilation → connected components → candidates. Keep it **loose**: area 3–300 px at full res, aspect ≤ 4, no brightness ranking, no chroma/isolation rejects, cap at ~40 per frame by area-plausibility rather than brightness. Emit `BallObservation` with normalised centre, radius = √(area/π)/width, and a confidence that encodes compactness (fill ratio) and, optionally, the soft scores from the luma work (surround luma, chroma) — as *weights*, never gates. Attach nothing else. vImage is available; `LumaBlobDetector` already has the downsample/diff/flood-fill scaffolding to copy from.

**Stage 2 — trajectory stage** (`TrajectoryFitter`, new file in `Tracking/`, replacing `BallTracker`'s association but producing the same `BallTrackFrame`).
Sliding window of the last W = 12 frames of candidates. RANSAC: sample three candidates from three distinct frames; fit `x(t) = a + b·t`, `y(t) = c + d·t + e·t²`; count inliers within r = 8 px (full-res) at their own timestamps, at most one per frame. Accept the best model if inliers ≥ 6 and it passes plausibility: speed 200–4000 px/s; `e` (image-space gravity) within a wide positive band — start with 300–8000 px/s² and tune, because it scales with depth; the near ball accelerates faster in the image than the far one. Output per frame: `.tracking` with the model evaluated at t (or the inlier at t) when a model holds; `.coasting` for up to 3 frames when the model holds but the current frame has no inlier; `.searching` otherwise. Keep the model between frames; only re-run RANSAC when the current model loses inliers, so the track is stable. A break (new model with different `b` sign or a `d` sign flip) is a hit or bounce — record it in the ledger of segments even though the overlay does not use it yet; it is the future rally feature.

Constraints: Swift 6 strict concurrency; `@unchecked Sendable` only where a comment states which lock or serialisation makes it safe (see existing detectors). Public interfaces in the spec stay as they are; `BallTrackFrame`, `BallTrack`, the sidecar, the lab and the app must not need changes for this to ship.

## 7. Visual observability — required at every task

The failure mode tonight was trusting numbers. Every task below produces an artefact you look at (Read the PNG) before you claim anything, and the user can open the videos. Put everything under `/tmp/balltrack/<task-name>/`. Extend `balltrack-lab` rather than writing throwaway scripts, so the observability ships with the tool:

- `balltrack-lab mask --input $CLIP --out DIR [--threshold 60]` → `mask.mp4` (white on black) — Task A.
- `balltrack-lab candidates --input $CLIP --out DIR` → `candidates.mp4`: source frame with every candidate drawn as a small magenta circle sized to its radius, plus `candidates.jsonl` (frame, t, x, y, radius, area, confidence) — Task B.
- `balltrack-lab run … --debug` → `debug.mp4`, a 2×2 mosaic at half size: source | mask | candidates | track (ring + trail + current parabola drawn as a thin curve over its window). One video answers "which stage lied" — Task C.
- The **zoom audit** (the check that caught the earlier failure): pick 12 frames spread across the clip where the tracker says `.tracking`, crop 80×45 px around the reported position from the *raw* clip, upscale 6× nearest-neighbour, mark the centre, tile 4×3. If the ball is not under the marker in ≥ 10 of 12, the tracker is wrong regardless of what the summary says. Add it as `balltrack-lab audit --track track.json --input $CLIP --out DIR` — Task C.

Reference for what the correct answer looks like: frame 18 at (991, 494). Also verify frames where you know the ball is *not* in play show `.searching`.

Run the lab from a normal terminal (or with sandbox disabled): inside a sandboxed shell `AVAssetReader` fails with `Cannot Decode` (no VideoToolbox). `swift test` may need `--disable-sandbox`. Use a private `--scratch-path` per parallel build.

## 8. Tasks

Work TDD where there is a pure function; use synthetic frames for unit tests and the real clip for acceptance. Commit per task with an imperative message. Keep the ledger at `.superpowers/sdd/2026-09-18-ball-tracking/progress.md` (append; it is the recovery map).

**Task A — Swift motion mask that matches the oracle.**
Implement the mask computation (full-res luma diff, threshold 60, 3×3 dilation) as a reusable type used by the detector, plus `balltrack-lab mask`. Acceptance: render `mask.mp4` and compare against `/tmp/balltrack/motion_white_t60.mp4` (regenerate it with the ffmpeg command in §4 if missing): pixel agreement ≥ 99.5 % on frames 18, 200, 450, 700, 900 (compute with a small script over PNG dumps, not by eye), and a side-by-side still of frame 18 that you look at. Unit test: a synthetic pair of frames with one moving disc yields a mask of exactly the two disc footprints, dilated.

**Task B — `MotionCandidateDetector`.**
Connected components on the mask, loose filters, `BallObservation` output, `balltrack-lab candidates`. Acceptance: `candidates.mp4` reviewed at frames 18, 60, 450, 680; `candidates.jsonl` contains a candidate within 6 px of (991, 494) at frame 18 with area 20–120 (dilation grows it); typical candidates per frame in the 3–30 range during play, near 0 between points. Unit tests on synthetic frames: moving disc → one candidate at the right place and radius; static bright disc → none; large moving disc → rejected by area; two discs → two candidates.

**Task C — `TrajectoryFitter` and the debug/audit tooling.**
RANSAC parabola over the candidate window, `BallTrackFrame` output, `--debug` mosaic, `audit` command. Unit tests: synthetic candidate sets (one true parabola plus 20 random noise points per frame over 12 frames) → the fitted model recovers the parabola parameters within tolerance and reports `.tracking`; a straight-line fast mover with no gravity term still fits (e ≈ 0 is inside the band); a set with only noise → `.searching`; a parabola that reverses `b` at frame 8 → two segments. Acceptance on `$CLIP`: zoom audit ≥ 10 of 12 on the ball; frame 18 `.tracking` within 6 px; no `.tracking` frames in the first 0.3 s; `debug.mp4` reviewed at three rallies.

**Task D — wire it in and rewrite the results.**
`BallDetectorKind` gains `.motion` and it becomes the default; `ClipTrackRunner` uses `TrajectoryFitter` when the detector is `.motion` (keep `BallTracker` for the others or delete it if nothing uses it — your call, ledger it). Re-run the lab, rewrite `docs/superpowers/specs/2026-09-18-ball-tracking-lab-results.md` from scratch with the real numbers, the audit grid description, and the debug video paths. Then the app: analyse a clip in the player on device and confirm the ring is on the ball (this is the original plan's Task 11).

**Task E — only after D holds:** resume the original plan's Tasks 12–14 (live overlay). The live path reuses `MotionCandidateDetector` unchanged; the previous-frame state it keeps is per instance, and `FrameTap` already serialises `analyze` calls per analyzer.

## 9. Things that will bite

- **Frame timing.** Candidates carry the frame PTS; the fitter must use real timestamps, not indices, because dropped frames happen live.
- **Lens distortion.** Straight flights bend slightly near the edges. A 12-frame window and 8 px tolerance should absorb it; if the audit fails only near frame edges, widen tolerance before adding undistortion.
- **The ball in front of a moving player.** The mask merges the ball with the player's motion blob for a few frames. The fitter coasts through that; do not try to fix it in the candidate stage.
- **Serve toss and static ball.** A ball held or resting produces no motion and correctly no track. Say so in the results rather than treating it as a miss.
- **Performance.** Full-res diff + components is ~5–8 ms in Swift release on a Mac; fine offline. For live mode, measure on device before optimising; downsampling is the first lever, and if you take it, re-render the mask video and re-run the audit.
- **`maxCandidates` by brightness** is what hid the ball last time. Do not reintroduce a brightness cap anywhere.
