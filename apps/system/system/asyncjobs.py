import subprocess

from mojo.helpers import paths, logit

logger = logit.get_logger("system", "system.log")


def on_broadcast_update(data):
    """Broadcast target — runs in-process inside this node's jobman engine.

    aws/update.sh stops jobman as part of its own run, which kills the very
    engine process executing this function. So this must launch update.sh
    detached (new session, no wait) rather than run it synchronously —
    otherwise the update gets cut off by its own restart.
    """
    try:
        subprocess.Popen(
            ["bash", "aws/update.sh"],
            cwd=str(paths.PROJECT_ROOT),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        return "started"
    except Exception as e:
        logger.exception(f"Failed to start aws/update.sh: {e}")
        return "error"
