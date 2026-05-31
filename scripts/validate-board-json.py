#!/usr/bin/env python3
"""Validate a board.json against docs/board/schema.json — stdlib only.

No pip/node dependency: implements the JSON Schema draft 2020-12 subset the
board schema actually uses (type incl. union + null, enum, const, required,
properties, additionalProperties bool|schema, items, minItems, minProperties,
pattern, and local $ref into #/$defs/*). `format`, `default`, `description`,
`$comment`, `$schema`, `$id`, `title` are treated as annotations (ignored).

Used by the <ISSUE> aggregator CI step and by the <ISSUE>/.16 local self-tests.

Usage:
  scripts/validate-board-json.py [board.json] [--schema docs/board/schema.json]

Exit 0 = valid; exit 1 = one or more validation errors (printed to stderr);
exit 2 = usage / load error. Beyond the schema it also enforces one
cross-field invariant the schema can't express: every condition key used in
scores[].measurements[].condition must be declared in condition_dims.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCHEMA = REPO_ROOT / "docs" / "board" / "schema.json"
DEFAULT_BOARD = REPO_ROOT / "docs" / "board" / "board.json"

_JSON_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "number": (int, float),
    "integer": int,
    "boolean": bool,
    "null": type(None),
}


def _type_ok(value, t: str) -> bool:
    # bool is a subclass of int in Python; keep number/integer from matching True/False.
    if t in ("number", "integer") and isinstance(value, bool):
        return False
    py = _JSON_TYPES[t]
    return isinstance(value, py)


class Validator:
    def __init__(self, schema: dict):
        self.schema = schema
        self.defs = schema.get("$defs", {})
        self.errors: list[str] = []

    def _resolve(self, node: dict) -> dict:
        ref = node.get("$ref")
        if not ref:
            return node
        if not ref.startswith("#/$defs/"):
            raise ValueError(f"unsupported $ref (only #/$defs/* handled): {ref}")
        name = ref[len("#/$defs/"):]
        if name not in self.defs:
            raise ValueError(f"$ref to unknown def: {ref}")
        return self.defs[name]

    def validate(self, value, node: dict, path: str) -> None:
        node = self._resolve(node)

        if "const" in node and value != node["const"]:
            self._err(path, f"expected const {node['const']!r}, got {value!r}")

        if "enum" in node and value not in node["enum"]:
            self._err(path, f"{value!r} not in enum {node['enum']}")

        if "type" in node:
            types = node["type"]
            types = [types] if isinstance(types, str) else types
            if not any(_type_ok(value, t) for t in types):
                self._err(path, f"expected type {types}, got {type(value).__name__}")
                return  # downstream keyword checks assume the type matched

        if isinstance(value, dict):
            self._validate_object(value, node, path)
        elif isinstance(value, list):
            self._validate_array(value, node, path)
        elif isinstance(value, str):
            pat = node.get("pattern")
            if pat is not None and not re.search(pat, value):
                self._err(path, f"{value!r} does not match pattern /{pat}/")

    def _validate_object(self, value: dict, node: dict, path: str) -> None:
        for req in node.get("required", []):
            if req not in value:
                self._err(path, f"missing required property '{req}'")

        min_props = node.get("minProperties")
        if min_props is not None and len(value) < min_props:
            self._err(path, f"expected >= {min_props} properties, got {len(value)}")

        props = node.get("properties", {})
        addl = node.get("additionalProperties", True)
        for k, v in value.items():
            child_path = f"{path}.{k}"
            if k in props:
                self.validate(v, props[k], child_path)
            elif addl is False:
                self._err(path, f"additional property '{k}' not allowed")
            elif isinstance(addl, dict):
                self.validate(v, addl, child_path)

    def _validate_array(self, value: list, node: dict, path: str) -> None:
        min_items = node.get("minItems")
        if min_items is not None and len(value) < min_items:
            self._err(path, f"expected >= {min_items} items, got {len(value)}")
        item_schema = node.get("items")
        if isinstance(item_schema, dict):
            for i, item in enumerate(value):
                self.validate(item, item_schema, f"{path}[{i}]")

    def _err(self, path: str, msg: str) -> None:
        self.errors.append(f"{path or '<root>'}: {msg}")


def _check_condition_dims(board: dict) -> list[str]:
    """Cross-field invariant the schema can't express: every condition key in a
    measurement must be a declared condition dimension, and its value must be in
    that dimension's allowed values."""
    errors: list[str] = []
    dims = board.get("condition_dims", {})
    for si, score in enumerate(board.get("scores", [])):
        for mi, meas in enumerate(score.get("measurements", [])):
            cond = meas.get("condition", {})
            loc = f"scores[{si}].measurements[{mi}].condition"
            for dim, val in cond.items():
                if dim not in dims:
                    errors.append(f"{loc}: undeclared condition dim '{dim}'")
                    continue
                allowed = dims[dim].get("values", [])
                if val not in allowed:
                    errors.append(f"{loc}.{dim}: {val!r} not in declared values {allowed}")
    return errors


def main(argv: list[str]) -> int:
    board_path = DEFAULT_BOARD
    schema_path = DEFAULT_SCHEMA
    rest = list(argv)
    if "--schema" in rest:
        i = rest.index("--schema")
        try:
            schema_path = Path(rest[i + 1])
        except IndexError:
            print("--schema requires a path", file=sys.stderr)
            return 2
        del rest[i:i + 2]
    if rest:
        board_path = Path(rest[0])

    try:
        schema = json.loads(Path(schema_path).read_text())
        board = json.loads(Path(board_path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"load error: {exc}", file=sys.stderr)
        return 2

    v = Validator(schema)
    try:
        v.validate(board, schema, "")
    except ValueError as exc:
        print(f"schema error: {exc}", file=sys.stderr)
        return 2
    errors = v.errors + _check_condition_dims(board)

    if errors:
        print(f"INVALID: {board_path} ({len(errors)} error(s))", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"OK: {board_path} conforms to {schema_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
