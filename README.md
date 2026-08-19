# TrackpadTyping

Glide typing for the Mac. An on-screen keyboard appears at the bottom of the
screen; you steer the pointer through a word's letters with the trackpad and
the word is typed into whatever app has focus — one-handed, silent, without
switching devices.

Nothing off the shelf does this. The gesture-typing pieces existed separately
(SHARK2 as an algorithm, ways to read raw trackpad data) but nobody had
connected them into a usable Mac input method. This is that connection, built
as a single native menu-bar app with no dependencies.

## Using it

Toggle glide typing with a **four-finger tap** on the trackpad, **⌃⌥Space**,
or the menu bar icon (⌨︎). The keyboard appears, the pointer jumps onto it and
stays confined there until you toggle back out.

Move the pointer freely — nothing is decoded until you press.

| gesture | action |
|---|---|
| click **and hold**, sweep, release | trace a word |
| quick click | type the letter under the pointer |
| two-finger tap | cycle to the next candidate |
| two-finger swipe left | backspace |
| two-finger swipe down | delete the last word |
| ⇧ key / two-finger swipe up | capitalize the next letter |
| ' , . ? keys | punctuation — attaches to the word; . and ? arm an auto-capital |
| long-press a word chip | forget a mislearned word |
| three-finger tap | space |
| four-finger tap | toggle glide typing |

Tracing rides on drag muscle memory: press down on the first letter, keep the
click held while you sweep through the middle letters, release on the last one.
Travel between words is free because only the held click delimits a word —
this is what makes consecutive words possible at all, since on a trackpad
"moving the pointer" and "tracing" are otherwise the same physical act.

The key under the pointer highlights, your trace draws live, and the candidate
strip shows what was recognized. If the first guess is wrong, two-finger tap
cycles through alternatives (top-3 accuracy is ~99%, so it's nearly always in
the first few). A trace too garbled to trust types nothing rather than
guessing.

## How it works

```
CGEventTap             clicks delimit the word; clicks/scrolls swallowed over the keyboard
MultitouchSupport      finger count for the command gestures (~125 Hz)
   -> cursor path      sampled at 120 Hz while the click is held
   -> SHARK2 decoder   shape + location channels + language prior
   -> CGEvent Unicode injection into the focused app
```

**Decoding** (`Sources/TrackpadTyping/Decoder.swift`). Each candidate word has
an ideal path: the polyline through its key centres. A trace is scored against
it on two channels:

- **shape** — both paths centred and scaled to a common size, then compared.
  Forgives drift and traces that are too big or small.
- **location** — the same comparison with no normalization: did the trace
  actually pass over the right keys?

Shape alone confuses words with the same form in different places; location
alone punishes sloppy traces. Summed with a word-frequency prior, they work.
Candidate search is pruned by the trace's endpoints (its most reliable
features) and by arc length before any shape maths runs — mean decode time is
~4 ms against the full 198k-word lexicon.

**Vocabulary** (`Lexicon.swift`). Three tiers: a frequency-ranked core list
that carries the language model; `/usr/share/dict/words` as low-prior coverage
(it is Webster's 2nd — 198k largely archaic entries that would otherwise beat
real words on shape); and words you accept, which get promoted. A word is only
learned after you move on without correcting it, so the lexicon never trains
on its own mistakes.

**Row spacing.** Keys are 1.6× taller than wide (`rowPitchRatio`). Row
confusion is the decoder's dominant error mode, and stretching rows measurably
cuts it — the sweep puts a 10x3 square grid at ~84% top-1 and a 1.6–1.9×
stretch at 90–92%.

## Accuracy

`./.build/release/TrackpadTyping --selftest` scores the decoder on synthesized
traces (key positions jittered, corners rounded the way a moving hand rounds
them):

| trace noise | top-1 | top-3 |
|---|---|---|
| 0.20 key | 96.7% | 100.0% |
| 0.30 key | 90.3% | 99.0% |
| 0.40 key | 86.7% | 97.0% |

Remaining misses are genuinely ambiguous short words (`as`/`add`, `out`/`our`)
— recoverable by candidate cycling, which is why top-3 is the number that
matters in use. `--sweep` reruns the layout/weight grid search;
`--trace [seconds]` is a rehearsal mode that decodes real input but types
nothing.

## Build and install

```bash
./build.sh
open TrackpadTyping.app
```

Grant **System Settings → Privacy & Security → Accessibility** when prompted —
needed to type into other apps and to manage clicks over the keyboard.

> **Rebuilding revokes that permission.** The app is ad-hoc signed, so its
> designated requirement is a bare `cdhash` that changes with every build, and
> the dead entry stays in the list looking identical to the new one. After a
> rebuild: `tccutil reset Accessibility com.local.trackpadtyping`, relaunch,
> approve again. `build.sh` warns when this has happened.

`~/Library/Application Support/TrackpadTyping/status.log` records what happened
at startup (multitouch device, Accessibility, event tap) — both silent-failure
modes show up there.

## Configuration

`~/Library/Application Support/TrackpadTyping/config.json` (menu bar → Reveal
Settings File). Distances are in *key pitches* so they keep meaning at any
keyboard size. Useful knobs:

| key | default | meaning |
|---|---|---|
| `screenKeyPitch` | 64 | key width in points — sets the whole keyboard's size |
| `rowPitchRatio` | 1.6 | row height as a multiple of key width; raise toward 1.9 for accuracy, lower for screen space |
| `tapMaxTravelKeys` | 0.55 | below this travel a click is a letter, not a word |
| `maxScoreKeys` | 3.5 | worst acceptable best-candidate score; above it nothing is typed |
| `fallbackPenaltyKeys` | 1.6 | how strongly non-core dictionary words are disfavoured |
| `priorWeightKeys` | 0.07 | strength of the word-frequency prior |
| `useSystemDictionary` | true | include `/usr/share/dict/words` as fallback coverage |
| `autoSpace` | true | append a space after each glided word |
| `confinePointer` | true | keep the pointer on the keyboard while the mode is on |

## Layout

```
Sources/MTBridge/            C shim over MultitouchSupport (dlopen/dlsym —
                             no link-time reference to the private framework)
Sources/TrackpadTyping/
  Geometry.swift             resampling, shape normalization, distances
  KeyboardLayout.swift       staggered QWERTY grid in screen points
  Lexicon.swift              tiered vocabulary + learning
  CommonWords.swift          frequency-ranked core list
  Decoder.swift              SHARK2-style shape + location scoring
  TrackpadMonitor.swift      multitouch stream (finger count, gestures)
  GestureRecognizer.swift    multi-finger taps and swipes
  EventTapController.swift   click capture, pointer confinement, hotkey
  TextInjector.swift         Unicode keystroke synthesis
  HUDWindow.swift            the on-screen keyboard (never takes focus)
  AppDelegate.swift          wiring, tracing, menu bar, mode state
  SelfTest.swift             accuracy harness, weight sweep, rehearsal mode
```

## Limits

- Letters only; punctuation, digits and capitals need the regular keyboard.
- One keyboard size/position (bottom-centre of the main screen).
- `MultitouchSupport` is a private framework — stable for over a decade and
  verified on macOS 26.5, but Apple owes it no compatibility.
