"""The one exception the CLI turns into a clean exit: a message and what to do next."""


class LoopSpecError(Exception):
    def __init__(self, message: str, repair: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.repair = repair
