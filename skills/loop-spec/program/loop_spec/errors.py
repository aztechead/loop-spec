"""The one exception the CLI turns into a clean exit.

Raise LoopSpecError whenever a bad input, a broken invariant, or a refused operation
must stop the program with a message and a concrete repair step. Never
`except Exception: pass` in this codebase; raise this instead so `cli.main` can report
it and exit 1 rather than dumping a traceback on an operator.
"""


class LoopSpecError(Exception):
    """A fatal, operator-facing error: message plus the repair step to hand them."""

    def __init__(self, message: str, repair: str) -> None:
        super().__init__(message)
        self.message = message
        self.repair = repair
