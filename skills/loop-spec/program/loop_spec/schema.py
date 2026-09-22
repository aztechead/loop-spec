"""Minimal JSON Schema validator: the draft-2020-12 subset the wave-A schemas need.

No third-party dependency is allowed in this tree, so `validate` implements just the
keywords the bundled schemas use (type, required, properties, additionalProperties,
items, enum, const, minItems, minLength, pattern, oneOf/anyOf, same-document $ref) and
collects every violation instead of stopping at the first one, since a phase
implementation's malformed product should report all its problems at once.
"""
import re
from pathlib import Path

from .errors import LoopSpecError
from .jsonio import read_json

_SCHEMAS_DIR = Path(__file__).resolve().parent / "schemas"

_SIMPLE_TYPES = {"string": str, "boolean": bool, "null": type(None)}


def _type_ok(value, type_name: str) -> bool:
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if type_name == "object":
        return isinstance(value, dict)
    if type_name == "array":
        return isinstance(value, list)
    return isinstance(value, _SIMPLE_TYPES[type_name])


def validate(instance, schema: dict, path: str = "$", *, root: dict | None = None) -> list[str]:
    """Return every violation of `schema` at `instance`; empty list means valid.

    `root` defaults to `schema` itself: the top-level call is the document a $ref
    resolves against, and every recursive call threads the same root through so a
    $ref nested inside `items` or `properties` still finds `$defs` at the top.
    """
    if root is None:
        root = schema
    errors: list[str] = []

    if "$ref" in schema:
        ref = schema["$ref"]
        prefix = "#/$defs/"
        if not ref.startswith(prefix):
            raise LoopSpecError(f"unsupported $ref: {ref}", repair="use a #/$defs/<name> ref")
        target = root.get("$defs", {}).get(ref[len(prefix):])
        if target is None:
            raise LoopSpecError(f"$ref target not found: {ref}", repair="check the schema's $defs")
        return validate(instance, target, path, root=root)

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected constant {schema['const']!r}")

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: expected one of {schema['enum']!r}")

    type_spec = schema.get("type")
    if type_spec is not None:
        types = type_spec if isinstance(type_spec, list) else [type_spec]
        if not any(_type_ok(instance, t) for t in types):
            errors.append(f"{path}: expected {' or '.join(types)}")
            return errors  # further keywords assume the right type; nothing more to check

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errors.append(f"{path}: does not match pattern {schema['pattern']}")

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: fewer than minItems {schema['minItems']}")
        item_schema = schema.get("items")
        if item_schema is not None:
            for i, item in enumerate(instance):
                errors.extend(validate(item, item_schema, f"{path}[{i}]", root=root))

    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}.{key}: required field missing")
        properties = schema.get("properties", {})
        for key, sub_schema in properties.items():
            if key in instance:
                errors.extend(validate(instance[key], sub_schema, f"{path}.{key}", root=root))
        additional = schema.get("additionalProperties", True)
        extra = [k for k in instance if k not in properties]
        if additional is False:
            for key in sorted(extra):
                errors.append(f"{path}.{key}: additional property not allowed")
        elif isinstance(additional, dict):
            for key in sorted(extra):
                errors.extend(validate(instance[key], additional, f"{path}.{key}", root=root))

    for keyword in ("oneOf", "anyOf"):
        if keyword in schema:
            matches = sum(1 for sub in schema[keyword] if not validate(instance, sub, path, root=root))
            if keyword == "oneOf" and matches != 1:
                errors.append(f"{path}: expected exactly one oneOf branch to match, {matches} matched")
            elif keyword == "anyOf" and matches < 1:
                errors.append(f"{path}: expected at least one anyOf branch to match")

    return errors


def load_schema(name: str) -> dict:
    return read_json(_SCHEMAS_DIR / f"{name}.json")


def validate_or_raise(instance, name: str) -> None:
    errors = validate(instance, load_schema(name))
    if errors:
        raise LoopSpecError("; ".join(errors), repair=f"fix the listed fields in {name}")
