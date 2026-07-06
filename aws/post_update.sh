#!/bin/bash
#
# You can update this script to add custom deployment steps
# It runs after the git pull and before the application is restarted
#

cd /opt/api

sudo pip install django-mojo --upgrade

if [ -f /opt/api/var/allow_migrate ]; then
    ./bin/manage.py migrate
else
    sleep 5
fi
