#!/bin/bash

useradd imageuser
sudo echo Elha47480611 | passwd imageuser --stdin

echo "imageuser ALL = (ALL) NOPASSWD: ALL" >> /etc/sudoers.d/waagent


