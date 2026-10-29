# Recordings: capture → GIF → captions → hosting

How a PR gets the before/after clips it owes. [COMMANDS.md](COMMANDS.md) covers driving the app; this
covers what happens to the pixels afterwards.

## Capture

**Device screen only** — sign prompts, widgets, anything with no app around it. The widget simulator
renders a single demo and takes commands on stdin:

```sh
cd tools/widget_simulator
LIBRARY_PATH="$(brew --prefix sdl2-compat)/lib" cargo run -- <demo_name> --timeout 40000 < cmds.txt
```

`LIBRARY_PATH` is needed because SDL2 arrives via the `sdl2-compat` formula, which installs outside the
linker's default search path; without it the build fails at `ld: library 'SDL2' not found` — a link
error, so it looks like a code problem rather than an environment one. Derive the prefix rather than
hard-coding `/opt/homebrew` — that is Apple Silicon only, and Intel Homebrew lives at `/usr/local`.

Commands: `screenshot <path>`, `wait <ms>`, `touch x,y`, `drag x1,y1 x2,y2`, `release x,y`, `quit`.

> **A bare `drag` does not turn the page.** It calls `handle_vertical_drag(.., false)` and never
> releases; `touch` followed by `release` carries no travel. A swipe that works is `touch 120,250`, five
> stepped `drag`s up the screen, then `release 120,30`.

Demos are the `demo_widget!` match in `frostsnap_widgets/src/demo_widget.rs`. Add a case when you need
particular transaction data — a demo that cannot express the scenario is why a clip ends up not showing
the thing it was made for.

**Whole app** — the real flow, Android only. `session.record('demo.mp4', body)` wraps one async body and
always stops and pulls the mp4; `startRecording()` / `stopRecording(path)` bracket a longer hand-driven
sequence. Caps at 180s. See [COMMANDS.md](COMMANDS.md).

### The device panel

A whole-app recording carries the virtual devices' screens by default, as a panel to the right of
the app. Each device is scaled 2× nearest-neighbour, with its name and fsim number above it: the last name the app knew it by during the recording. The tray
stays closed, because it would cover the app. `record(..., devices: false)` gives the plain clip.

How the two are aligned:
- Every device frame is stamped when it renders, on the emulator's clock.
- The app draws a magenta patch on the left edge just after `screenrecord` starts and again just
  before it stops, and replies with the time of the frame that drew it.
- A frame's PTS is when it reached the screen. So each patch reached the screen after the last
  frame without it and by the first frame with it, which bounds where the clip sits on that clock.
  The clip goes in the middle of what both patches allow, and half that range is the uncertainty.
  If they allow nothing in common, the range covering both is used instead.
  It is written to `<path>.sync.json`, and over 250 ms the composite is refused. On a loaded
  emulator `screenrecord` can leave over half a second between frames, which is why each patch
  stays up for 1 s.
- Both patches are trimmed off. The raw clip is kept beside the output as `<path>.app.mp4`.
- Stopping any recording, with devices or not, first waits until the on-device mp4 has held one
  size for 1.5 s, or 20 s at most. A loaded emulator's `screenrecord` runs seconds behind the
  screen, and stopping it early drops the frames it has not yet encoded, including the end patch. A
  stalled encoder can also hold a size, so this is a bounded wait, not proof. A clip whose end
  patch never arrived is refused.
- The delay between the app drawing a frame and the frame reaching the screen is shared by the
  patch and the rest of the app, so the panel is aligned with what the app showed. Variation in
  that delay is not covered by the bound.

Limits:
- The harness polls each device every 100 ms. A device frame replaced within one poll is never seen,
  so device animation is captured at about 10 fps.
- The panel is resampled at 30 fps.
- A device added mid-recording gets no slot. A device removed mid-recording keeps its slot, dimmed
  to grey from the time it was found gone.
- Labels need ImageMagick (`magick`) as well as `ffmpeg`.

## mp4 → GIF

Two-pass palette. A single pass bands the colours badly:

```sh
ffmpeg -y -i demo.mp4 \
  -vf "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" demo.gif
```

## Frames → GIF

For simulator output. `-framerate` is the reciprocal of seconds-per-frame — `0.8` is 1.25s a frame — and
**you hold the final state by duplicating that frame before assembly**, not with a flag:

```sh
ffmpeg -y -framerate 0.8 -i frames/%03d.png \
  -vf "scale=240:-1:flags=neighbor,split[a][b];[a]palettegen[p];[b][p]paletteuse" out.gif
```

`flags=neighbor`, not lanczos: smoothing a 240px device panel smears text that is already at the limit
of legibility.

## Captions

The Homebrew `ffmpeg` formula does not depend on freetype, so **`drawtext` and `subtitles` do not
exist** in the default build — `No such filter: 'drawtext'`. Use ImageMagick:

```sh
magick in.gif -coalesce -gravity south -background '#000000CC' -fill white \
  -font /System/Library/Fonts/Supplemental/Arial.ttf -pointsize 13 \
  -splice 0x24 -annotate +0+5 'caption text' \
  -set dispose background out.gif
```

Two traps, both of which produce output that looks broken rather than erroring:

- **Do not add `-layers optimize`.** It encodes frames as transparency deltas, and because consecutive
  device pages differ everywhere, the result superimposes every page into unreadable mush.
- **`-font` needs an explicit path.** A bare family name fails with ``unable to read font `'``.

For different text per frame, annotate the PNGs individually and assemble afterwards.

If you need captions burned into an mp4, or timed subtitles, that does want a fuller ffmpeg —
`brew tap homebrew-ffmpeg/ffmpeg` and install from there, which is a source build and displaces the
existing `ffmpeg`.

## Hosting

Clips live in **`LLFourn/frostsnap-artifacts`** (cloned at `~/src/frostsnap-artifacts`), under
`pr-<N>/`, numbered continuing that PR's existing sequence so a reader sees one series rather than
scattered files.

```sh
cp out.gif ~/src/frostsnap-artifacts/pr-546/19-what-it-shows.gif
cd ~/src/frostsnap-artifacts
git add pr-546/19-what-it-shows.gif        # the exact path, never `git add -A`
git commit -m "pr-546: what it shows" && git push
```

`git add -A` in a shared artifacts repo publishes whatever else happens to be lying in the working tree.
Stage the file you meant.

Reference it raw:

```
https://raw.githubusercontent.com/LLFourn/frostsnap-artifacts/main/pr-546/19-what-it-shows.gif
```

**Fetch it back before putting that URL in a comment:**

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://raw.githubusercontent.com/.../19-what-it-shows.gif
```

A dead image in a review comment is worse than no image: it reads as evidence that existed and was
withdrawn.

## Before it goes out

- **Hold the final state 3–5s.** A clip ending on the moment it exists to show flashes once and the loop
  restarts, so the reader never sees it.
- **Verify the file**, don't assume the encode:
  ```sh
  ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames,width,height -of csv=p=0 out.gif
  ```
- **Watch the frames.** Not the file size, not the frame count — the pixels. A green test suite says the
  code does what the test says; only looking says the screen shows what you claim. A fee warning reading
  "5% of the value moved" survived a full green suite while the code had stopped measuring that.
