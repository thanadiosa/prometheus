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
# get unknown host keys in silence
ssh-keyscan "$helper_server" > /tmp/helper_key 2>/dev/null
ssh-keygen -lf /tmp/helper_key 1>/dev/null 2>&1
rm /tmp/helper_key 1>/dev/null 2>&1
# add key in helper
ssh-copy-id "$helper" 1>/dev/null 2>&1
# get and call needle script
scp "$helper:downloads/helper/starter/scripts/start.sh" .
chmod +x ./start.sh
./start.sh "$helper"
