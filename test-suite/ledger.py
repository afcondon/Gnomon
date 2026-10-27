#!/usr/bin/env python3
"""
The divergence ledger, and the one judge every conformance lane uses.

A test either prints the same value on this backend as on the JS reference,
or it is in `divergences.json` WITH BOTH VALUES. Nothing else passes.

Two holes this closes (REVIEW-2026-10, X3 a and b):

  - A ledger of (module, test) NAMES passed a ledgered test whatever value it
    printed. A divergence is a claim about two specific values ("JS wraps to
    -2147483648, we print 2147483648"); if either value moves, the claim is
    no longer the one that was triaged, and the lane says so.
  - The optimizer lanes did not read the ledger at all. They exempted any
    diff line whose text matched INT64|ASTRAL|STACK|NEGZERO, so a regression
    in any test whose NAME carried one of those words could not fail them.
    Now every lane imports this module and reads the same file.

And it reports the opposite drift: an entry whose test now prints identically,
or no longer exists, is STALE and fails the run. The ledger is the published
answer to "what can I NOT rely on across platforms?", so an entry that is no
longer true is as wrong as a divergence that is missing from it.

Usage as a library (run_tests.py):
    led = ledger.load()
    v = led.judge(module, js_stdout, backend_stdout)
    ...
    stale = led.unvisited(modules_run)

Usage from a lane script:
    python3 ledger.py compare --lane backend-py Test.Foo js.txt be.txt
    python3 ledger.py stale --lane backend-py Test.Foo Test.Bar ...
"""

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEDGER = HERE / "divergences.json"
SCHEMA = 1

TEST_LINE = re.compile(r"^TEST ([^:]+): (.*)$")


def parse_output(stdout):
    """-> (tests {name: value}, order [name], other [non-TEST lines])"""
    tests, order, other = {}, [], []
    for line in (stdout or "").splitlines():
        m = TEST_LINE.match(line)
        if m:
            tests[m.group(1)] = m.group(2)
            order.append(m.group(1))
        else:
            other.append(line)
    return tests, order, other


class Verdict:
    """What one module's comparison found. `ok` is the only thing a lane
    needs; the lists are what it prints."""

    def __init__(self, module):
        self.module = module
        self.identical = 0
        self.known = []      # (name, js, be)           ledgered and exact
        self.fail = []       # (name, js, be)           unledgered divergence
        self.mismatch = []   # (name, js, be, entry)    ledgered, value moved
        self.stale = []      # (name, why)              entry no longer true
        self.structure = []  # str                      missing/extra/other lines

    @property
    def ok(self):
        return not (self.fail or self.mismatch or self.stale or self.structure)

    @property
    def total(self):
        return self.identical + len(self.known) + len(self.fail) + len(self.mismatch)

    def lines(self, backend):
        out = []
        for name, js, be in self.known:
            out.append(f"  KNOWN     {self.module}/{name}: js={js!r} {backend}={be!r}")
        for name, js, be in self.fail:
            out.append(f"  FAIL      {self.module}/{name}: js={js!r} {backend}={be!r}"
                       f"  (not in the ledger)")
        for name, js, be, e in self.mismatch:
            out.append(f"  MISMATCH  {self.module}/{name}: js={js!r} {backend}={be!r}"
                       f"  (ledger says js={e['js']!r} {backend}={e['backend']!r})")
        for name, why in self.stale:
            out.append(f"  STALE     {self.module}/{name}: {why}"
                       f" — remove it from divergences.json")
        for s in self.structure:
            out.append(f"  STRUCTURE {self.module}: {s}")
        return out


class Ledger:
    def __init__(self, data, lane):
        if data.get("schema") != SCHEMA:
            sys.exit(f"divergences.json: schema {data.get('schema')!r}, "
                     f"expected {SCHEMA}")
        self.backend = data["backend"]
        self.causes = data["causes"]
        self.lane = lane
        self.entries = {}
        for e in data["entries"]:
            key = (e["module"], e["test"])
            if key in self.entries:
                sys.exit(f"divergences.json: duplicate entry {key}")
            if e["cause"] not in self.causes:
                sys.exit(f"divergences.json: {key} cites unknown cause "
                         f"{e['cause']!r}")
            self.entries[key] = e

    def expected(self, entry):
        """The backend value this lane must print. A lane may differ from the
        oracle lane only where the entry says so, by lane name."""
        return entry.get("lanes", {}).get(self.lane, entry["backend"])

    def judge(self, module, js_stdout, be_stdout):
        v = Verdict(module)
        js, js_order, js_other = parse_output(js_stdout)
        be, _, be_other = parse_output(be_stdout)
        for name in js_order:
            jsv, bev = js[name], be.get(name)
            entry = self.entries.get((module, name))
            if entry is None:
                if jsv == bev:
                    v.identical += 1
                else:
                    v.fail.append((name, jsv, bev))
                continue
            want = self.expected(entry)
            if jsv == bev:
                if want == jsv:
                    # A lane-specific "identical" override: not a divergence
                    # on this lane, by declaration.
                    v.identical += 1
                else:
                    v.identical += 1
                    v.stale.append((name, f"now identical ({jsv!r})"))
            elif jsv == entry["js"] and bev == want:
                v.known.append((name, jsv, bev))
            else:
                v.mismatch.append(
                    (name, jsv, bev, {"js": entry["js"], "backend": want}))
        for (m, name) in self.entries:
            if m == module and name not in js:
                v.stale.append((name, "no such test in this module's output"))
        missing = sorted(set(js) - set(be))
        extra = sorted(set(be) - set(js))
        if missing:
            v.structure.append(f"tests missing on {self.backend}: {missing}")
        if extra:
            v.structure.append(f"tests only on {self.backend}: {extra}")
        if js_other != be_other:
            v.structure.append(
                f"non-TEST output differs ({len(js_other)} js lines, "
                f"{len(be_other)} {self.backend} lines)")
        return v

    def unvisited(self, modules_run):
        """Entries naming a module the corpus no longer has."""
        run = set(modules_run)
        return sorted((m, t) for (m, t) in self.entries if m not in run)


def load(lane=None, path=LEDGER):
    data = json.loads(Path(path).read_text())
    return Ledger(data, lane or data["backend"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare", help="judge one module's two outputs")
    c.add_argument("--lane", required=True)
    c.add_argument("module")
    c.add_argument("js_out")
    c.add_argument("be_out")
    s = sub.add_parser("stale", help="entries for modules not in the corpus")
    s.add_argument("--lane", required=True)
    s.add_argument("modules", nargs="+")
    args = ap.parse_args()

    led = load(args.lane)
    if args.cmd == "compare":
        v = led.judge(args.module, Path(args.js_out).read_text(),
                      Path(args.be_out).read_text())
        for line in v.lines(args.lane):
            print(line)
        kind = ("identical" if not v.known else
                f"{len(v.known)} ledgered") if v.ok else "FAIL"
        print(f"RESULT {kind} {v.identical}/{v.total}")
        sys.exit(0 if v.ok else 1)
    else:
        gone = led.unvisited(args.modules)
        for m, t in gone:
            print(f"  STALE     {m}/{t}: module is not in the corpus"
                  f" — remove it from divergences.json")
        sys.exit(1 if gone else 0)


if __name__ == "__main__":
    main()
