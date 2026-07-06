import mojo.decorators as md
from .models import Task


@md.URL('task')
@md.URL('task/<int:pk>')
def on_todo_task(request, pk=None):
    """
    CRUD API for /api/todo/task
    """
    return Task.on_rest_request(request, pk)


@md.GET("status")
def on_example_get(request):
    """
    Simple Example of GET Request /api/todo/status
    and Response with a valid Json Response

    real world example would be:
    {
        "status": True,
        "data": {
            "new": Task.objects.filter(status="new").count(),
            "open": Task.objects.filter(status="open").count(),
            "paused": Task.objects.filter(status="paused").count(),
            "recently_closed": Task.objects.filter(modified__gt=datetime.now()- timedelta(days=7)).count(),
        }
    }
    """
    # request.DATA is a objict/dict with all data sent in the request (GET PARAMS, or POST DATA)
    # this will return a datetime object if the 'since' parameter is provided and is a valid datetime string
    since = request.DATA.get('since', None, typed="datetime")
    # here is example of nested get
    age = request.DATA.get('person_age', None, typed="int")
    return {
        "status": True,
        "data": {
            "new": 2,
            "open": 12,
            "paused": 2,
            "recently_closed": 2,
        }
    }


@md.POST("echo")
@md.PUT("echo")
@md.requires_params("echo_text", "echo_key")
def on_example_echo(request):
    """
    This example only accepts POST and PUT requests
    And requires that the 'echo_text' and 'echo_key' parameters are provided
    """
    return {
        "status": True,
        "data": {
            "echo_text": request.DATA.echo_text
        }
    }
