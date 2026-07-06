#!/bin/bash

if [ "$(pwd)" != "/opt/api" ]; then
    echo "Error: This script must be run from /opt/api directory"
    exit 1
fi

echo "$(date): UPDATE STARTED" >> var/update.log

git fetch origin
git reset --hard origin/main
git clean -fd

sudo bash ./aws/post_deploy.sh

echo "$(date): stopping job engine" >> var/update.log
./bin/jobman stop
VERSION=$(grep '^__version__' config/settings/version.py | cut -d '"' -f 2)
echo "$(date): system now at: $VERSION" >> var/update.log
echo "$VERSION" > var/version
echo "$VERSION"
