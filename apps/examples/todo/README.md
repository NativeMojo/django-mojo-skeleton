# Todo Example App

This example demonstrates how to build a simple todo application using the Django-Mojo framework. It showcases the core concepts of Mojo including automatic REST API generation, permission systems, and model lifecycle hooks.

## Overview

The todo app consists of a single `Task` model that provides a complete CRUD API with zero boilerplate code, thanks to the Mojo framework's `MojoModel` base class.

## Files

- **`models.py`** - Contains the `Task` model with comprehensive documentation
- **`rest.py`** - REST endpoint definitions using Mojo decorators
- **`__init__.py`** - Python package marker

## Task Model

The `Task` model demonstrates:

- **Django Model Fields**: Standard fields like `CharField`, `TextField`, `DateTimeField`
- **Mojo Integration**: Inherits from `MojoModel` for automatic REST capabilities
- **Permission Control**: Owner-based permissions using the `"owner"` permission key
- **Lifecycle Hooks**: Custom logic during create, update, and delete operations
- **Serialization Graphs**: Multiple API response formats (basic, default, full)

### Key Features

```python
# Standard Django fields
title = models.CharField(max_length=200)
description = models.TextField(blank=True, null=True)
status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='new')
priority = models.CharField(max_length=10, choices=PRIORITY_CHOICES, default='medium')
due_date = models.DateTimeField(blank=True, null=True)

# Required for owner-based permissions
user = models.ForeignKey('account.User', on_delete=models.CASCADE)

# Mojo standard timestamp fields
created = models.DateTimeField(default=dates.utcnow)
modified = models.DateTimeField(auto_now=True)
```

### RestMeta Configuration

```python
class RestMeta:
    VIEW_PERMS = ["view_task", "owner"]     # Who can view tasks
    SAVE_PERMS = ["manage_task", "owner"]   # Who can create/update tasks
    DELETE_PERMS = ["delete_task", "owner"] # Who can delete tasks
    SEARCH_FIELDS = ["title", "description"] # Fields to search
    LOG_CHANGES = True                      # Log all API changes
```

## API Endpoints

The REST API is automatically generated from the model definition:

### Task CRUD Operations

| Method | URL | Description |
|--------|-----|-------------|
| `GET` | `/api/todo/task` | List all tasks (paginated) |
| `POST` | `/api/todo/task` | Create a new task |
| `GET` | `/api/todo/task/<id>` | Get a specific task |
| `POST/PUT` | `/api/todo/task/<id>` | Update a specific task |
| `DELETE` | `/api/todo/task/<id>` | Delete a specific task |

### Additional Endpoints

| Method | URL | Description |
|--------|-----|-------------|
| `GET` | `/api/todo/status` | Get task status summary |
| `POST/PUT` | `/api/todo/echo` | Echo test endpoint (requires `echo_text`, `echo_key`) |

## Usage Examples

### Creating a Task

```bash
curl -X POST /api/todo/task \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Learn Django-Mojo Framework",
    "description": "Study the documentation and build example apps",
    "priority": "high",
    "due_date": "2025-09-20T10:00:00Z"
  }'
```

### Listing Tasks

```bash
# Basic list
curl /api/todo/task

# With search
curl "/api/todo/task?search=framework"

# With specific serialization graph
curl "/api/todo/task?graph=basic"

# Pagination
curl "/api/todo/task?page=2&limit=10"
```

### Updating a Task

```bash
curl -X POST /api/todo/task/1 \
  -H "Content-Type: application/json" \
  -d '{
    "status": "completed"
  }'
```

### Filtering and Searching

```bash
# Search in title and description
curl "/api/todo/task?search=important"

# The framework automatically handles:
# - Pagination (?page=1&limit=20)
# - Ordering (?order_by=created&order=desc)
# - Field filtering (?status=open&priority=high)
```

## Serialization Graphs

The model defines three serialization graphs for different use cases:

### Basic Graph
Minimal data for lists and references:
```json
{
  "id": 1,
  "title": "Sample Task",
  "status": "open",
  "priority": "medium"
}
```

### Default Graph  
Standard detail view with timestamps:
```json
{
  "id": 1,
  "title": "Sample Task",
  "description": "Task description here",
  "status": "open",
  "priority": "medium",
  "due_date": "2025-09-20T10:00:00Z",
  "created": "2025-09-13T08:30:00Z",
  "modified": "2025-09-13T08:30:00Z",
  "user": {
    "id": 1,
    "username": "john_doe"
  }
}
```

### Full Graph
Complete data including detailed user information:
```json
{
  "id": 1,
  "title": "Sample Task",
  "description": "Task description here", 
  "status": "open",
  "priority": "medium",
  "due_date": "2025-09-20T10:00:00Z",
  "created": "2025-09-13T08:30:00Z",
  "modified": "2025-09-13T08:30:00Z",
  "user": {
    "id": 1,
    "username": "john_doe",
    "email": "john@example.com",
    "display_name": "John Doe"
  }
}
```

## Permission System

The task model uses Mojo's permission system:

- **Owner Permission**: Users can always view, edit, and delete their own tasks
- **System Permissions**: Admin users can have `view_task`, `manage_task`, `delete_task` permissions
- **Automatic Enforcement**: Permissions are checked automatically by the framework

## Model Lifecycle Hooks

The Task model demonstrates custom logic injection points:

- **`on_rest_pre_save()`** - Called before saving (validation, auto-assignment)
- **`on_rest_saved()`** - Called after saving (logging, notifications)  
- **`on_rest_created()`** - Called only for new tasks (defaults, setup)
- **`on_rest_pre_delete()`** - Called before deletion (cleanup, logging)

## Custom Methods

The model includes utility methods:

```python
# Check if task is overdue
task.is_overdue  # Boolean property

# Days until due date
task.days_until_due  # Integer (negative if overdue)

# Programmatically complete a task
task.mark_completed()

# Custom field setter with validation
task.set_priority('urgent')
```

## Key Mojo Framework Concepts Demonstrated

1. **Zero Boilerplate CRUD**: Single `on_rest_request()` call provides full API
2. **Automatic Permissions**: Declarative permission system in `RestMeta`
3. **Multiple Serialization**: Different API response shapes via graphs
4. **Lifecycle Hooks**: Custom logic injection at key points
5. **Request Data Parsing**: Automatic parsing into `request.DATA` object
6. **Search Integration**: Built-in search across specified fields
7. **Change Logging**: Automatic audit trail of API changes
8. **Custom Field Setters**: Framework calls `set_{field}()` methods automatically

This example serves as a foundation for understanding how to build REST APIs with the Django-Mojo framework efficiently and with minimal code.