# Leap Chess

This is a visual demo. The user is screen-recording you to show two things: that an agent can
take an idea to a finished, working product end to end on its own, and that Leap (the MCP
server that lets you see and operate apps in the background with its own visible cursor) is
what lets it work in real applications the way a person would. The product is a small low-poly
3D chess game for macOS, iPhone and iPad, with every 3D asset made new in Blender and a short
cinematic intro rendered from those assets. Nothing here ships or gets maintained afterwards.

So the recording is the real deliverable. Scripts and command-line builds are the right way to
construct things, but a viewer should see the work happen: the models appearing and being
inspected in Blender, the intro rendering, the app building and running, the game being played
in each simulator and on the Mac. Prefer doing the visible parts in the real apps through Leap,
keep the relevant window on screen while you work in it, and let each stage end with something
a viewer can see.

The chat terminal you are running in is part of the recording and must stay visible the whole
time. Before you start, find it (it is the window of the app at the top of your shell's parent
process chain, from `$$` upwards) and look at the desktop with Leap's `list_windows`. Arrange
the other windows around it with `set_window_frame` so they do not cover it, and do the same
for every window that opens later: Blender, Xcode, the game, the simulators. Leave the terminal
where the user put it. If two windows cannot both fit, keep the one you are working in visible
next to the terminal and let the other sit behind it.

All decisions are yours. Keep moving and finish without asking; the user is recording, not
available. Only stop for something you genuinely cannot do yourself (a license to accept, a
credential, a permission prompt).

## Done means

- Low-poly pieces and board, modeled from scratch by your own Blender scripts.
- A playable game on all three platforms against a computer opponent, with the full rules.
- A board the player can pivot by dragging (mouse on the Mac, touch on iPhone and iPad) to view it
  from any angle, with moves still landing on the right squares afterwards.
- An intro of a few seconds that plays at launch.
- Leap visibly used along the way: inspecting the models in Blender's viewport, checking
  renders, and playing the game on the Mac and in the iPhone and iPad simulators.
- A short `README.md` and a `NOTES.md` of the decisions and problems worth narrating.

A finished small game beats an ambitious unfinished one.

## Constraints

- **Every asset is new and built by you in Blender.** No stock or pre-made assets: no Fab,
  Megascans or other downloads, no Blender bundled asset libraries or generator add-ons, no
  downloaded textures or HDRIs. Making them is part of the demo.
- **Use the chess libraries in `vendor/`; don't write chess logic.** Rules and an opponent are
  solved problems. If `vendor/` is not there yet, create it first (see Setup); add the packages
  to the app by local path:
  - `chesskit-swift`: [ChessKit](https://github.com/chesskit-app/chesskit-swift) (MIT), latest
    main. Rules, legal moves, FEN/SAN, game status. Its `Package.swift` points at the local
    `vendor/Dye` so it resolves offline.
  - `chesskit-engine`: [ChessKitEngine](https://github.com/chesskit-app/chesskit-engine) 0.7.0,
    Stockfish 17 over UCI (GPL inside; fine for a demo that is never distributed).
  - `nnue/`: the two network files Stockfish needs at runtime (`EvalFile`, `EvalFileSmall`).
  If the engine costs more than a little time, a small search over ChessKit's legal moves is a
  fine opponent.
- Stay inside the project folder. Don't touch other projects, Blender preferences or system
  settings.

## Setup

If `vendor/` is missing, create it in the project folder before anything else, so nothing
depends on the network once the build starts. These are the latest versions that were tested
together (ChessKit main `c29bdfb`, Dye `45b8ef9`, ChessKitEngine `0.7.0`):

```sh
mkdir -p vendor/nnue && cd vendor
git clone https://github.com/chesskit-app/chesskit-swift.git
git clone https://github.com/dduan/Dye.git
git clone --depth 1 --recurse-submodules -b 0.7.0 https://github.com/chesskit-app/chesskit-engine.git
# ChessKit's command-line tool depends on Dye by URL; point it at the local copy so the
# package resolves offline.
sed -i '' 's|.package(url: "http://github.com/dduan/Dye", from: "0.0.1")|.package(path: "../Dye")|' chesskit-swift/Package.swift
for n in nn-1111cefa1111 nn-37f18f62d772; do
  curl -fsSL -o nnue/$n.nnue https://tests.stockfishchess.org/api/nn/$n.nnue
done
```

`nn-1111cefa1111.nnue` (about 75 MB) is `EvalFile` and `nn-37f18f62d772.nnue` (about 3.5 MB)
is `EvalFileSmall`; bundle both in the app and pass their paths with `setoption`. The engine
package logs an "Invalid Exclude" warning for a missing `lc0/build` folder; it is harmless.

## Useful context

- Tested with macOS 27, Xcode 27 and Blender 5.2. Xcode 27's MCP only drives iOS 27 simulators.
- MCP servers: `leap`, `xcode`, `runner` (long-running commands and services with captured
  output), `chrome-devtools`.
- Skills to read first: `leap`, `leap-3d-game-workflows`, `leap-xcode`. If the `runner` MCP is
  available, read `runner_guide` and run builds, renders and launches through it.
- If Leap can't do something it should, note it in `LEAP-NOTES.md` and carry on another way;
  don't modify Leap. Avoid `foreground: true` unless an app ignores background input.
- Giving board squares accessibility labels ("e2, white pawn") lets Leap read and play the game
  from the tree.

Start.
