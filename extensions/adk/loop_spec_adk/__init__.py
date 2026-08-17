"""loop-spec for Google ADK.

Mount loop-spec in an ADK app:

    from loop_spec_adk import build_app
    from google.adk.runners import Runner

    app = build_app(".")          # agent + lifecycle plugin, one shared bridge
    runner = Runner(app=app, ...)

Or let `lib/adk-install.sh` write the mount for you, which is also what makes
`adk run <agent-dir>` and the loop-runner's `--agent-cli adk` backend work.
"""

from .agent import build_agent, build_app, build_readonly_agent, load_roles
from .bridge import LoopSpecBridge
from .plugin import LoopSpecPlugin

__all__ = [
    "LoopSpecBridge",
    "LoopSpecPlugin",
    "build_agent",
    "build_app",
    "build_readonly_agent",
    "load_roles",
]
