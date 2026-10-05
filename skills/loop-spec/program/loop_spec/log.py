"""The program's two output channels, both `logging` loggers; nothing here calls print.

Use `log.stdout` for what a caller reads (status lines, LOOP_SPEC_* markers) and
`log.stderr` for diagnostics. Each record is written as its bare message to whatever
`sys.stdout`/`sys.stderr` is at that moment, so a redirected stream (a test, a
wrapping runner) receives it.
"""
import logging
import sys


class _CurrentStream(logging.Handler):
    def __init__(self, name: str) -> None:
        super().__init__()
        self.name = name

    def emit(self, record: logging.LogRecord) -> None:
        try:
            stream = getattr(sys, self.name)
            stream.write(record.getMessage() + "\n")
            stream.flush()
        except BrokenPipeError:
            pass  # a reader that stopped early (`| head`) is not an error


def _logger(name: str) -> logging.Logger:
    logger = logging.getLogger(f"loop_spec.{name}")
    if not logger.handlers:
        logger.addHandler(_CurrentStream(name))
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


stdout = _logger("stdout")
stderr = _logger("stderr")
