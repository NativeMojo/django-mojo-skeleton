from mojo.apps import jobs


def trigger():
    """Fire-and-forget broadcast: every node with jobman running picks this up
    and runs system.asyncjobs.on_broadcast_update. No replies collected —
    the handler kicks off aws/update.sh, which restarts jobman itself, so the
    runner that received this broadcast won't reliably survive to reply."""
    jobs.broadcast_execute("system.asyncjobs.on_broadcast_update", data={})
