#!/bin/bash
reset
read -p "helper: " helper
# get helper server
helper_server="${helper#*@}"
# get unknown host keys in silence
ssh-keyscan "$helper_server" > /tmp/helper_key
ssh-keygen -lf /tmp/helper_key 1>/dev/null 2>&1
rm /tmp/helper_key 1>/dev/null 2>&1
# add key in helper
ssh-copy-id "$helper"
# get and call needle script
scp "$helper:downloads/helper/starter/scripts/start.sh" .
chmod +x ./start.sh
./start.sh "$helper" &
