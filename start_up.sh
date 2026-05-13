#!/bin/bash
reset
if [[ -f /root/helper ]] ; then
    helper=$(cat /root/helper)
    echo "helper already set"
else
    read -p "helper: " helper
    # write helper to file
    echo "$helper" > /root/helper
fi
# get helper server
helper_server="${helper#*@}"
# check if helper is reachable
if ! nc -z -w 5 "$helper_server" 22 2>/dev/null; then
    echo "helper unreachable..."
    rm -f /root/helper
    exit 1
fi
# get unknown host keys in silence and add to known_hosts
mkdir -p ~/.ssh
ssh-keyscan "$helper_server" >> ~/.ssh/known_hosts 2>/dev/null
# add key in helper
ssh-copy-id "$helper" 1>/dev/null 2>&1
# get and call needle script
scp "$helper:downloads/helper/starter/scripts/start.sh" .
chmod +x ./start.sh
./start.sh "$helper"
