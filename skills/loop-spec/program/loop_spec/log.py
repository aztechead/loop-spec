"""The program's two output channels, both `logging` loggers; nothing here calls print.

Use `log.stdout` for what a caller reads (status lines, LOOP_SPEC_* markers) and
`log.stderr` for diagnostics. Each record is written as its bare message, so the
stdout protocol lines are unchanged, to whatever `sys.stdout`/`sys.stderr` is at
that moment, so a redirected stream (a test, a wrapping runner) receives it.
"""
import logging
import sys


class _CurrentStreamHandler(logging.StreamHandler):
    def __init__(self, stream_name: str) -> None:
        self._stream_name = stream_name
        super().__init__()

    @property
    def stream(self):
        return getattr(sys, self._stream_name)

    @stream.setter
    def stream(self, _value) -> None:
        pass  # the stream is looked up per record; StreamHandler.__init__ assigns one


def _logger(stream_name: str) -> logging.Logger:
    logger = logging.getLogger(f"loop_spec.{stream_name}")
    if not logger.handlers:
        handler = _CurrentStreamHandler(stream_name)
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


stdout = _logger("stdout")
stderr = _logger("stderr")
