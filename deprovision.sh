#!/bin/bash

echo $(whoami) > /opt/extension_user.txt
waagent -deprovision -force
