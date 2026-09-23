#!/usr/bin/env bash
# Tests for lib/loop_log.py: both channels write the bare message to the stream in
# place at emit time, and a line that cannot be written fails the call as print() did.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import io, sys
sys.path.insert(0, sys.argv[1] + "/lib")
from loop_log import logger, stdout_log

saved_out, saved_err = sys.stdout, sys.stderr
sys.stdout, sys.stderr = out, err = io.StringIO(), io.StringIO()
stdout_log.info("NEXT phase=verify 100%")
logger.error("LOOP_SPEC_RESULT {\"status\":\"completed\"}")
sys.stdout, sys.stderr = saved_out, saved_err
assert out.getvalue() == "NEXT phase=verify 100%\n", repr(out.getvalue())
assert err.getvalue() == 'LOOP_SPEC_RESULT {"status":"completed"}\n', repr(err.getvalue())
print("PASS: each channel writes the bare message to the stream swapped in after import")

class Closed(io.StringIO):
    def write(self, text):
        raise BrokenPipeError(32, "Broken pipe")
sys.stdout = Closed()
try:
    stdout_log.info("NEXT phase=plan")
except BrokenPipeError:
    failed = True
else:
    failed = False
finally:
    sys.stdout = saved_out
assert failed, "a protocol line lost to a closed pipe must fail the call"
print("PASS: a line that cannot be written raises instead of printing a logging traceback")
PY
