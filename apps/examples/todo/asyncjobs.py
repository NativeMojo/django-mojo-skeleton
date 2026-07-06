

def send_reminders(job):
    from todo.models import Task
    tasks = Task.objects.filter(status='pending')
    for task in tasks:
        task.send_reminder()
    return True
