"""The two output channels for loop-spec's Python, both stdlib logging.

`logger` is stderr: diagnostics, NOTE lines, and the LOOP_SPEC_* markers a log reader
greps; the level says how bad it is. `stdout_log` is stdout: the protocol line
(NEXT/REDO/DONE...) and the JSON callers parse. It is fixed at INFO with no level knob,
because a filtered protocol line is a broken caller, not a quieter log.

Both format the bare message, so every line keeps the bytes that tests, callers, and log
readers match on.
"""
import logging
import sys


class _CurrentStream(logging.StreamHandler):
    """Writes to whatever sys.<name> is at emit time, as print() did. The driver's
    capture() swaps sys.stdout to read a subcommand's answer, and a handler bound at
    import would keep writing past it to the real stream."""

    def __init__(self, stream_name):
        # Handler.__init__ owns `_name` (the handler's name); this one is the sys attribute.
        self._stream_name = stream_name
        super().__init__()

    @property
    def stream(self):
        return getattr(sys, self._stream_name)

    @stream.setter
    def stream(self, _value):
        pass

    def handleError(self, record):
        # logging's default prints a traceback and carries on; a line that could not be
        # written (a closed pipe, a full disk) must fail the call the way print() did.
        raise


def _channel(name, stream_name):
    log = logging.getLogger(name)
    if not log.handlers:
        handler = _CurrentStream(stream_name)
        handler.setFormatter(logging.Formatter("%(message)s"))
        log.addHandler(handler)
        log.setLevel(logging.INFO)
        log.propagate = False
    return log


logger = _channel("loop-spec", "stderr")
stdout_log = _channel("loop-spec.stdout", "stdout")
