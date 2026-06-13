# Phase 1 — red baseline (2026-06-13)

Established by `run_tests.py` over the full corpus. The differential harness
(purs corefn,js → psgo `--entry` per module → `go run` → diff vs JS) works
end-to-end; reachability pruning emits each `Test.*` module's transitive
closure independently. All 10 modules are RED for one reason: **unauthored
foreign shims** (the `Foreigns.hs` catalogue currently holds only the spike's
hand-written `Trivial_*` shims).

The complete shim worklist is `FOREIGN_WORKLIST.txt` — **229 distinct foreign
functions**. Cost to first green, by unique missing shims per module:

| Module            | unique missing foreigns |
|-------------------|-------------------------|
| Test.ADTs         | 56  |
| Test.PatternMatch | 56  |
| Test.Uncurried    | 62  |
| Test.Dictionaries | 82  |
| Test.Numbers      | 93  |
| Test.STTests      | 94  |
| Test.Recursion    | 129 |
| Test.Arrays       | 141 |
| Test.Effects      | 153 |
| Test.Strings      | 173 |

ADTs / PatternMatch are leanest and their 56 are the **core prelude
foundation** (Eq/Ord/Show/Semiring/Ring/EuclideanRing/Semigroup/
HeytingAlgebra/Bounded, array Functor/Apply/Bind/Extend, Unit, Effect+Console,
Record.Unsafe, unsafeCoerce) — shared by every module. Authoring that layer
dents all ten and lands the first real corpus modules green.

Walk order (PLAN §Phase-1, refined by these costs): core layer → ADTs +
PatternMatch → Uncurried/Dictionaries → Numbers/STTests → the rest. Foreign
shims mirror the real JS foreign (`output/<Module>/foreign.js`) per ADR-0005;
they are `any`-typed Go top-level vars named `Module_member`.

---

## Update (session 2): infra + core layer landed; blocked on lazy init

The harness, reachability, core foreign layer (separate embedded `runtime/
prelude.go`), and four codegen fixes (guard `.(bool)`, unused-scrutinee elision,
direct lambda application, `init()` topo ordering) are all in. All 10 modules now
COMPILE and RUN; they panic at init with `nil is not map[string]interface{}` —
the cyclic typeclass-dictionary clusters (Effect Functor/Apply/Applicative/Bind/
Monad) need **lazy initialization** (purs's `$runtime_lazy`; ADR-0004 lazy-thunk).
That is the single next task; see SPIKE-NOTES.md "Session 2" for the diagnosis and
two implementation options. No module is green yet, but the path is unobstructed
and well-understood.

---

## Update (session 3): 6 modules GREEN (235 tests byte-identical)

ADTs 32, PatternMatch 31, Uncurried 9, Dictionaries 42, Numbers 106, STTests 15
— all byte-identical to the JS reference, 0 known-divergence hits, 0 failures.

Added this session: Dictionaries, Numbers, STTests. Beyond shim-authoring, three
fixes that are general (not module-local): `GoVarDef` (interface-typed `let`
bindings so closures can be applied via type assertion); `_jsNumToString`
(ECMAScript Number::toString — Go `'g'` exponent thresholds/padding diverge);
JS int32 bitwise (`_toInt32`/`_toUint32`); and a **bijective reserved-word
mangler** (PS `map` vs foreign `map_` were colliding → strict CAF cycle). See
SPIKE-NOTES.md "Session 3".

Remaining red: Recursion (needs TCO trampoline ADR-0003 + INT64 ledger), Arrays,
Effects, Strings (ASTRAL/UTF-16 ledger).

---

## Update (session 3 FINALE): ALL 10 modules GREEN — Phase 1 complete

`run_tests.py` full corpus: **422/426 identical, 4 known divergences, 0 failures,
0 module errors.** Per-module: ADTs 32, Arrays 85, Dictionaries 42, Effects 14,
Numbers 106, PatternMatch 31, Recursion 16(+2 INT64), STTests 15, Strings 72(+2
ASTRAL), Uncurried 9. The 4 divergences are the seeded ledger entries (INT64
non-wrap, ASTRAL codepoint-vs-UTF16) — intentional 64-bit/UTF-8 target behaviour.

Recursion needed no TCO trampoline (Go's growable stack handled 1M frames); ADR-
0003 is deferred to Phase 2. Phase 1 = a correct, un-optimized any-runtime
CoreFn→Go emitter walking the full conformance corpus to green. DONE.
