# Test fixtures

Curated inputs the plugin's tests + manual driving run against — homed here so the plugin is
self-contained (previously the sandbox lived loose in `~/code/`).

- **`sandbox/`** — a hand-built compile-target that exercises *every* lens in one small TU:
  `Money` (16 B, `__int128`), a cache-line **straddler** (`Packet.payload` crossing the 64 B line),
  `Money` **embedders/consumers** (`Position`, `money_add/zero/accumulate/eq`), and a **memcmp**
  byte-safety site. It carries `TRY:` hints (e.g. flip `__int128 v` → `int64_t v` and watch 16 B → 8 B).
  It's a **manual inspection target** — open `sandbox/sandbox.cpp` in nvim and drive the HUD.
  The compile features need a `compile_commands.json`; it's machine-specific (absolute paths), so it's
  gitignored — run **`bash sandbox/gen-cc.sh`** once after checkout to (re)generate it.

- **`../fx/`** — header fixtures (fwd-decl preference, class / template / `alignas`) used by
  `test_byte_layout_cascade.lua` (its "Test A"). Already wired + committed.
