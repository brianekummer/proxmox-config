#!/bin/bash

# Upgrade Plex Media Server on Debian-based systems
#
# This script is intended to be run as root or with sudo privileges
# 
# Plex does have a public APT repository that can be used for updates (a Plex post 
# discussing it is here: https://support.plex.tv/articles/235974187-enable-repository-updating-for-supported-linux-server-distributions/)
# but this script uses the official download URL to ensure the latest version is installed.
#
# This was written by ChatGPT, but I successfully used it to upgrade Plex in July 2025
# and it was done in like 2 minutes.

cd /tmp
apt update && apt install -y curl jq wget
URL=$(curl -s https://plex.tv/api/downloads/5.json \
 | jq -r '.computer.Linux.releases[] | select(.build=="linux-x86_64" and .distro=="debian") | .url')
wget "$URL" -O plex.deb
dpkg -i plex.deb
systemctl restart plexmediaserver
rm plex.deb