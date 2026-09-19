# Ball Tracking — Lab Results (Task 8)

**Clip:** `~/Documents/pp highlights/8b95514af4e6468faee879eb63c1dd97.mp4` — 1920×1080, 50 fps, 20.34 s, 1018 frames. Static wide-angle corner shot; dark table and walls; near player in a white shirt.
**Machine:** macOS 26.6.1, Xcode 27, release build. Timings are Mac CPU/GPU, a proxy for device.
**Decision:** `BallDetectorKind.default = .vision` with `VisionTrajectoryDetector.Config` defaults `trajectoryLength 6`, `minimumNormalizedRadius 0.001`, `maximumNormalizedRadius 0.012`.

## Commands

```sh
cd BallTracking
swift run -c release balltrack-lab run --input "$CLIP" --detector vision --out /tmp/balltrack/vision
swift run -c release balltrack-lab run --input "$CLIP" --detector luma   --out /tmp/balltrack/luma
# after editing Config defaults (min 0.001, max 0.012):
swift run -c release balltrack-lab run --input "$CLIP" --detector vision --out /tmp/balltrack/vision-r012
swift run -c release balltrack-lab run --input "$CLIP" --detector vision --trajectory-length 5 --out /tmp/balltrack/vision-r012-tl5
for t in 1.0 3.0 5.5 9.0 9.1 12.0 16.0 18.0; do ffmpeg -ss $t -i .../annotated.mp4 -frames:v 1 still_$t.png; done
```

Inside a sandboxed agent shell `AVAssetReader` fails with `Cannot Decode` (no VideoToolbox access); run the lab from a normal terminal.

## Runs

### Luma (plan defaults) — rejected

```
detect ms           mean 0.54  p95 0.67  errors 0
wall                0.6 s (33.5× realtime)
tracking fraction   85.1%   visible 94.2%
track starts        13
longest run         3.12 s
candidates/frame    7.99
#########################+########+######
```

Stills at 3.0 s and 9.0 s: the ring and trail sit on the near player's white shirt, with the trail scribbling across the torso. `candidates/frame` is pinned at the cap of 8, i.e. the shirt's moving edges produce a stream of ball-sized bright blobs every frame and the tracker locks onto them. The 85 % "tracking" is almost entirely this false lock. Fast (0.5 ms) but unusable here without a region of interest or a much stricter blob model.

### Vision (plan defaults: tl 6, radius 0.002–0.03) — false positives on body and paddle

```
detect ms           mean 3.45  p95 3.92  errors 0
wall                3.6 s (5.7× realtime)
tracking fraction   75.1%   visible 90.1%
track starts        22
longest run         2.46 s
candidates/frame    2.89
.##########+#############################
```

Stills: 1.0 s and 3.0 s ring the real ball (tight ring, ball in flight). 9.1 s rings the near player's shorts; 16.0 s rings the swinging paddle. Both false rings are large — Vision is following body parts and the paddle as "trajectories" and their `movingAverageRadius` is ~0.014+ of frame width, while the ball is ~0.002–0.005.

### Vision, radius 0.001–0.012, tl 6 — chosen

```
detect ms           mean 3.46  p95 4.23  errors 0
wall                3.6 s (5.7× realtime)
tracking fraction   41.7%   visible 54.0%
track starts        22
longest run         1.08 s
candidates/frame    1.10
...+###+##+++###+...+##+#++#+..+.++++#+##
```

Stills: 1.0 and 3.0 s ring the ball. 16.0 s: small coasting ring on the ball just off the paddle (previously the paddle itself). 9.1 s and 5.5 s: `searching`, no ring — the ball is near a paddle in both and Vision has not yet accumulated a trajectory; a miss, not a false positive. No false ring in any of the eight stills.

### Vision, radius 0.001–0.012, tl 5 — rejected

```
tracking fraction   59.4%   visible 79.0%
track starts        31
candidates/frame    2.09
+################.++#+#######..##++###+##
```

More coverage, but stills at 12.0 and 18.0 s ring the shirt and 5.5 s rings the far player's paddle/hand. Shorter trajectories admit non-parabolic body motion again.

## Assessment against the spec's acceptance rule

- Higher tracking fraction during rallies **without a sustained false track**: only the tuned Vision run satisfies the second half. Luma and tl-5 Vision fail it; default-radius Vision fails it.
- ≤ 8 ms mean per frame in release on the Mac: Vision 3.5 ms ✓, luma 0.5 ms ✓.
- On device Vision runs on the Neural Engine; a 20 s, 60 fps clip (1200 frames) at even 10 ms/frame is ~12 s of analysis, acceptable behind the progress pill.

## Known limitations of the chosen configuration

- Recall is partial: 42 % of frames tracking, 22 short tracks (longest 1.08 s). The ball is lost at hits and re-acquired ~6 frames later because Vision needs `trajectoryLength` points before reporting. The overlay therefore blinks off briefly around each hit.
- Balls smaller than ~2 px radius at 1080p (very far tables) fall under `minimumNormalizedRadius`.
- Nothing was tuned on a second clip; a bright room or a white wall behind the table will need re-evaluation.

## Follow-ups (not in this plan)

1. Bridge Vision gaps with `projectedPoints` or a short coast extension in `BallTracker` so hits do not blink the overlay.
2. Region of interest around the table (both detectors accept one cheaply) would let luma work as a low-power fallback.
3. Radius consistency gating in `BallTracker` (reject candidates whose radius is >2.5× the track's running radius) as a detector-independent guard.
