# fox-symdeps — landmines

Traps that have bitten more than once. Read before touching the compile/analysis pipeline.

## L1 — The compile/subprocess pipeline swallows errors → misleading fallback

**Symptom (every time):** a feature shows a plausible-but-wrong "nothing here" —
`(unavailable)`, `{inlined}`, "size unknown", "none broken" — with no hint of the real
cause. It looks identical regardless of *why* it failed, which is exactly what makes it
hard to diagnose.

**The class.** Any shell-out (`vim.system` / `vim.fn.systemlist`) or `pcall` in the
pipeline that, on failure, silently returns an empty/nil result instead of surfacing WHY.

**Instances seen:**

- `-flto` in the borrowed flags → `clang -S` emits LLVM IR, not asm → `blocks==0` →
  silent "unavailable". (fixed: `strip_opt` drops `-flto`.)
- `asmdiff.run` read only `res.stdout`, ignoring stderr/exit → any compile error →
  silent "unavailable". (fixed: surface the first `error:` line.)
- `asmdiff.run` demangled with `c++filt :wait()` **inside** the `vim.system` on_exit
  callback → `E5560: vim.wait must not be called in a fast event context` → the `pcall`
  ate it → mangled-label fallback → a QUALIFIED name (`tt::foo`) never matched → silent
  `{inlined}`. (fixed: demangle + match + analyze moved into `vim.schedule` = main loop.)
  Global names dodged it because the mangled symbol still contains the bare identifier.
- `breakcheck.check` (SAFETY) reported an empty failset = "none broken" for EVERY
  non-run: no `compile_commands`, missing header, real compile error, spawn/write fail.
  A safety check silently green when it never compiled. (fixed: second `errors` channel
  → caller shows `⚠ UNVERIFIED`.)

**The rule.** Every `pcall` / `vim.system` / `vim.fn.systemlist` in the compile/analysis
path MUST surface its failure — distinguish "ran, found nothing" from "could not run."
Never fall back to an empty result that reads as a clean/negative answer. For a SAFETY
check (breakcheck), "couldn't run" must be LOUDER than "found nothing," never quieter.

**Fast-event rule.** `vim.system(...):wait()` and other blocking calls are forbidden
inside a `vim.system` on_exit callback (fast context, E5560). Do the blocking / `:wait()`
work inside `vim.schedule(...)`. Audited clean: `runner`, `sizeprobe`, `breakcheck` all
schedule; `asmdiff` did not (now fixed).

### Remaining swallow points (MEDIUM/LOW — misleading-empty, not dangerous)

From the 2026-07-04 swallow sweep; fix opportunistically:

- `sizeprobe.compute` — a non-size compile failure → `cb(nil)` → silent "size unknown"
  (can't tell a template from a broken compile). Drives Layout / width-lits.
- `runner.run` — drops `stderr`; `res.code~=0 && empty stdout → cb(nil)` conflates
  "no matches" with "tool errored."
- `compose.lua` (×2) + `byte_layout_cascade.lua` — `vim.fn.systemlist` never checks
  `v:shell_error` → shell failure → misleading empty result (also synchronous, blocks nvim).
- `asmdiff.run` — if `c++filt` is missing, `okd=false` → mangled fallback → qualified
  names silently fail again (defensive; c++filt is standard).
