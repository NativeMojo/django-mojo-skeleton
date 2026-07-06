from mojo.decorators.cron import schedule
from mojo.apps import jobs


# Runs hourly at the 15 minute mark
@schedule(minutes="15")
def send_reminders():
    jobs.publish(func="todo.asyncjobs.send_reminders", payload={})
