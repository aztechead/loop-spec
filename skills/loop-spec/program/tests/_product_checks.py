"""Shared test assertion: run a phase module's own product through the program's
own schema and Boundary check -- the same validation controller._accept_product
runs on every real cycle. LF-38/39/42/43/44 all reached the live tree because a
phase module's tests only ever checked the module's own state, never asked
whether the product it built would actually survive the program's real
acceptance path; this closes that gap for whichever test imports it.

Only assert_product_holds, no fixtures: every caller already has its own store/
paths/product built the way its own module's tests build them.
"""
from loop_spec import postconditions
from loop_spec.schema import load_schema, validate


def assert_product_holds(testcase, store, paths, project_root, phase, product, *, check_boundary=True):
    """Assert `product` validates against schemas/<phase>.json and, unless
    `check_boundary` is false (a deliberately rejected/blocked/partial product,
    where only the schema half still applies), that a Boundary built from it
    accepts every postcondition its own `exit` requires."""
    errors = validate(product, load_schema(phase))
    testcase.assertEqual(errors, [], f"{phase} product failed its own schema: {errors}")
    if not check_boundary:
        return
    boundary = postconditions.Boundary(
        store, paths, phase=phase, product=product, exit=product["exit"], project_root=project_root,
    )
    failures = boundary.check()
    testcase.assertEqual(
        failures, [],
        f"{phase} {product['exit']!r} product rejected: " + "; ".join(f"{f.id}: {f.message}" for f in failures),
    )
