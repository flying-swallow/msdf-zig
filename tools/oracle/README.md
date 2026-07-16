# Reference oracle

Generates the golden fixtures in `src/test/fixtures` by running the same glyphs
through **msdfgen**, the C++ original this library is a port of. `zig build test`
then compares msdf-zig's output against them per-texel.

The fixtures are committed, so the test suite is hermetic and CI needs no C++
toolchain. You only need any of this when bumping the msdfgen reference version.

## Regenerating

```sh
MSDFGEN_DIR=/path/to/msdfgen tools/oracle/regenerate.sh
```

Needs CMake, Ninja, a C++11 compiler, and FreeType development headers. Tested
against msdfgen v1.13.0.

**Review the resulting fixture diff carefully.** Regenerating moves the oracle
itself, so a change here can just as easily hide a regression as reveal one. If
fixtures shift, understand *why* before committing them.

## How it stays honest

`oracle.cpp` mirrors `src/Generator.zig`'s pipeline exactly, and the config
matrix in `main()` mirrors `buildCases()` in `src/test/differential.zig`. If the
two drift apart, the Zig side fails on a missing fixture rather than silently
skipping a case.

The parts that are easy to get subtly wrong, all of which produced a confidently
wrong "reference" at some point while this was being written:

- **Distance mapping direction.** `DistanceMapping(Range)` maps distance → [0,1],
  which is what the generators write. `DistanceMapping::inverse(Range)` is the
  other direction and yields a uniformly blank field.
- **Coordinate scaling.** msdf-zig scales outlines by `1/unitsPerEM` at decompose
  time, which is `FONT_SCALING_EM_NORMALIZED` — *not* msdfgen's `FONT_SCALING_LEGACY`
  default, which divides by 64.
- **Orientation flip ordering.** msdf-zig flips inside `generate*()`, before the
  scanline sign correction. Flipping afterwards inverts the entire field for any
  face whose winding trips the flip — i.e. every CFF outline.
- **Row order.** msdf-zig writes shape row `y` to bitmap row `h-1-y`; the oracle
  flips on dump so the Zig side can compare directly.
- **Error-correction mode.** msdf-zig's `check_distance` defaults on and is forced
  off by a scanline pass. It folds the shape-distance check into a single
  `findErrors`, which is `ALWAYS_CHECK_DISTANCE` here, not `CHECK_DISTANCE_AT_EDGE`.

## Debugging

`ORACLE_DEBUG=1` prints per-config bounds, translate, bitmap size, the
out-of-bounds probe and its inversion decision, plus an ASCII rendering of
channel 0 — usually enough to spot a geometry mismatch by eye.
