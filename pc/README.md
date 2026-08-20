# TrackpadTyping for Windows

Glide typing for a Windows PC — the same design as the macOS original: an
always-on-top keyboard panel, the mouse pointer as the input, and
press-and-hold-click to trace a word. Text is typed into whatever window has
focus.

## Build

Needs any C++17 compiler. From this `pc/` folder:

**Visual Studio** (x64 Native Tools Command Prompt):
```
cl /std:c++17 /O2 /EHsc src\main_win32.cpp /Fe:TrackpadTyping.exe user32.lib gdi32.lib shell32.lib
```

**MinGW-w64**:
```
g++ -std=c++17 -O2 -mwindows -o TrackpadTyping.exe src/main_win32.cpp -lgdi32 -lshell32
```

Then put `resources/lexicon-en.txt` **next to the .exe** and run it. No
install, no admin rights, no dependencies.

## Use

- **Ctrl+Alt+Space** shows/hides the keyboard. While it's up, the pointer is
  confined to the panel and clicks belong to typing.
- **Click and hold, sweep through the letters, release** — types the word.
- **Quick click** a letter — types it, with word completions offered above.
- Click a **suggestion chip** (or press ←/→) to pick a different candidate.
  Scroll to see more suggestions.
- **Space** (double-tap for “. ”), **' , . ? !** keys, **⇧** or auto-capitals
  after sentence enders, **⌫** (right after a glide it removes the whole
  word; hold to delete progressively more).
- The **top bar** shows what you've typed — click a word there, then glide,
  to replace it in place.
- The **bottom row** is your five most-used words; click to type one,
  long-press to make the app forget a word it learned. Words you spell out
  by hand get learned automatically (stored in `%APPDATA%\TrackpadTyping`).
- Drag the panel by the bar at its very top.

## Structure

```
src/engine.hpp       the recognizer: geometry, layout, lexicon, two-stage
                     rigid+DTW decoder — identical logic to the macOS app,
                     no platform dependencies
src/main_win32.cpp   Win32 shell: overlay panel, low-level mouse/keyboard
                     hooks, SendInput text injection, GDI rendering
test/selftest.cpp    accuracy harness; builds and runs on any OS
resources/           the frequency-ranked lexicon (CC-BY-SA, from
                     hermitdave/FrequencyWords)
```

## Status

The recognition engine is tested (the `test/selftest.cpp` harness runs the
same synthetic-trace evaluation as the macOS app and scores equivalently:
~84% top-1 clean, ~71% sloppy at 0.30-key noise). The Win32 shell compiles
against documented APIs but was written on a Mac and has not run on real
Windows yet — expect possibly a round of small fixes on first launch, and
report anything odd.
