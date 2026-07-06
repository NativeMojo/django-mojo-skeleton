from django.db import models
from mojo.models.rest import MojoModel
from mojo.helpers import dates


class Task(models.Model, MojoModel):
    """
    A simple Todo Task model demonstrating the Mojo framework.

    This model showcases:
    - Mojo framework integration for automatic REST API generation
    - Standard Django model fields with Mojo conventions
    - Permission-based access control
    - Multiple serialization graphs for different API responses
    - Owner-based permissions for user-specific tasks
    """

    # Core task fields
    title = models.CharField(
        max_length=200,
        help_text="The task title or summary"
    )

    description = models.TextField(
        blank=True,
        null=True,
        help_text="Detailed description of the task"
    )

    # Task status with predefined choices
    STATUS_CHOICES = [
        ('new', 'New'),
        ('open', 'Open'),
        ('in_progress', 'In Progress'),
        ('paused', 'Paused'),
        ('completed', 'Completed'),
        ('cancelled', 'Cancelled'),
    ]

    status = models.CharField(
        max_length=20,
        choices=STATUS_CHOICES,
        default='new',
        help_text="Current status of the task"
    )

    # Priority levels
    PRIORITY_CHOICES = [
        ('low', 'Low'),
        ('medium', 'Medium'),
        ('high', 'High'),
        ('urgent', 'Urgent'),
    ]

    priority = models.CharField(
        max_length=10,
        choices=PRIORITY_CHOICES,
        default='medium',
        help_text="Task priority level"
    )

    # Due date (optional)
    due_date = models.DateTimeField(
        blank=True,
        null=True,
        help_text="When this task is due (optional)"
    )

    # Task ownership - links to the user who created/owns this task
    # This enables the "owner" permission in RestMeta
    user = models.ForeignKey(
        'account.User',
        on_delete=models.CASCADE,
        help_text="The user who owns this task"
    )

    # Standard Mojo timestamp fields
    created = models.DateTimeField(
        default=dates.utcnow,
        help_text="When this task was created"
    )

    modified = models.DateTimeField(
        auto_now=True,
        help_text="When this task was last modified"
    )

    class Meta:
        """
        Django Meta class for database table configuration.
        """
        db_table = 'todo_tasks'
        ordering = ['-created']  # Show newest tasks first
        indexes = [
            models.Index(fields=['user', 'status']),  # Common query pattern
            models.Index(fields=['due_date']),        # For due date queries
            models.Index(fields=['priority', 'status']),  # For priority filtering
        ]

    class RestMeta:
        """
        Mojo RestMeta class defines how this model behaves in the REST API.
        This is where we configure permissions, serialization, and API behavior.
        """

        # Permission Configuration
        # VIEW_PERMS: Who can view/list tasks
        VIEW_PERMS = [
            "view_task",  # Users with explicit view_task permission
            "owner"       # Task owners can always view their own tasks
        ]

        # SAVE_PERMS: Who can create/update tasks
        SAVE_PERMS = [
            "manage_task",  # Users with explicit manage_task permission
            "owner"         # Task owners can update their own tasks
        ]

        # DELETE_PERMS: Who can delete tasks
        DELETE_PERMS = [
            "delete_task",  # Users with explicit delete_task permission
            "owner"         # Task owners can delete their own tasks
        ]

        # Search Configuration
        # When ?search=query is provided, these fields will be searched
        SEARCH_FIELDS = ["title", "description"]

        # Log all changes made to tasks via the API
        LOG_CHANGES = True

        # Serialization Graphs
        # Different "shapes" of data for different API use cases
        GRAPHS = {
            # Basic graph: minimal data for lists and references
            "basic": {
                "fields": [
                    "id",
                    "title",
                    "status",
                    "priority"
                ]
            },

            # Default graph: standard detail view
            "default": {
                "fields": [
                    "id",
                    "title",
                    "description",
                    "status",
                    "priority",
                    "due_date",
                    "created",
                    "modified"
                ],
                # Include basic user information
                "graphs": {
                    "user": "basic"  # Use the basic graph for the related user
                }
            },

            # Full graph: everything including relationships
            "full": {
                "fields": [
                    "id",
                    "title",
                    "description",
                    "status",
                    "priority",
                    "due_date",
                    "created",
                    "modified"
                ],
                "graphs": {
                    "user": "default"  # More detailed user info
                }
            }
        }

    def __str__(self):
        """
        String representation of the task.
        """
        return f"{self.title} ({self.get_status_display()})"

    def send_reminder(self):
        """
        Sends a reminder for the task.
        """
        # Implementation of sending reminder logic
        pass

    # Mojo Lifecycle Hooks
    # These methods allow you to inject custom logic into the REST API lifecycle

    def on_rest_pre_save(self, changed_fields, created):
        """
        Called before saving a task via the REST API.

        Args:
            changed_fields (dict): Dictionary of fields that were changed
            created (bool): True if this is a new task being created

        This is the perfect place for:
        - Validation logic
        - Data transformation
        - Setting computed fields
        - Triggering side effects before save
        """
        # Example: Auto-set user if creating a new task
        if created and 'user' not in changed_fields:
            # If no user was specified, assign to the current request user
            self.user = self.active_user

        # Example: Update status based on due date
        if self.due_date and self.due_date < dates.utcnow() and self.status in ['new', 'open']:
            # Task is overdue, you might want to flag it
            pass

    def on_rest_saved(self, changed_fields, created):
        """
        Called immediately after a task is saved via the REST API.

        Args:
            changed_fields (dict): Dictionary of fields that were changed
            created (bool): True if this was a new task

        This is ideal for:
        - Sending notifications
        - Updating related models
        - Logging custom events
        - Triggering background jobs
        """
        if created:
            # Log task creation
            self.log("info", f"New task created: {self.title}")

        # Example: Send notification if status changed to completed
        if 'status' in changed_fields and self.status == 'completed':
            self.log("info", f"Task completed: {self.title}")
            # Here you might trigger a notification or update related models

    def on_rest_created(self):
        """
        Called only when a new task is created via the REST API.

        This is a convenience method that's called after on_rest_saved
        but only for new instances.
        """
        # Example: Set default priority based on user preferences
        if not self.priority:
            self.priority = 'medium'

    def on_rest_pre_delete(self):
        """
        Called before a task is deleted via the REST API.

        This is where you can:
        - Validate that deletion is allowed
        - Clean up related data
        - Log the deletion
        - Archive instead of delete
        """
        self.log("info", f"Task being deleted: {self.title}")

    # Custom Methods

    @property
    def is_overdue(self):
        """
        Check if this task is overdue.

        Returns:
            bool: True if the task has a due date and it's in the past
        """
        if not self.due_date:
            return False
        return self.due_date < dates.utcnow() and self.status not in ['completed', 'cancelled']

    @property
    def days_until_due(self):
        """
        Calculate days until this task is due.

        Returns:
            int: Days until due (negative if overdue), None if no due date
        """
        if not self.due_date:
            return None

        delta = self.due_date - dates.utcnow()
        return delta.days

    def mark_completed(self):
        """
        Mark this task as completed and save.

        This is a convenience method for programmatic task completion.
        """
        self.status = 'completed'
        self.save()
        self.log("info", f"Task marked as completed: {self.title}")

    def set_priority(self, priority_level):
        """
        Custom field setter that can be called by the Mojo framework.

        The Mojo framework automatically looks for methods named 'set_{field_name}'
        and calls them when that field is being updated via the REST API.

        Args:
            priority_level (str): The new priority level
        """
        # Validate priority level
        valid_priorities = [choice[0] for choice in self.PRIORITY_CHOICES]
        if priority_level not in valid_priorities:
            raise ValueError(f"Invalid priority level. Must be one of: {valid_priorities}")

        self.priority = priority_level

        # Log priority changes for high/urgent tasks
        if priority_level in ['high', 'urgent']:
            self.log("info", f"Task priority set to {priority_level}: {self.title}")
