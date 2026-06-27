#!/usr/bin/env python3
from __future__ import annotations

import importlib
import inspect
import pathlib
import sys
import traceback


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root))
    sys.path.insert(0, str(root / "tests"))

    failures = 0
    total = 0
    for path in sorted((root / "tests").glob("test_*.py")):
        module = importlib.import_module(f"tests.{path.stem}")
        for name, obj in sorted(vars(module).items()):
            if name.startswith("test_") and inspect.isfunction(obj):
                total += 1
                try:
                    obj()
                except Exception:
                    failures += 1
                    print(f"FAIL {path.name}::{name}")
                    traceback.print_exc()
    if failures:
        print(f"failed {failures}/{total} tests")
        return 1
    print(f"ok - {total} tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
