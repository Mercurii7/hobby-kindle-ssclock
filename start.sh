#!/bin/sh

source ./libkohelper.sh

kill `ps aux | grep ssclock.lua | grep -v grep | awk '{ print $2 }'`

# a previous run may have been killed while holding a rotation; restore it
# first, so that the clock picks up the right orientation to go back to
if [ -f /tmp/ssclock.rota ] ; then
	./lua/bin/fbdepth -r `cat /tmp/ssclock.rota`
	rm -f /tmp/ssclock.rota
fi

cd lua
# the log lands in extensions/ssclock/ssclock.log, readable over USB
(./bin/luajit ssclock.lua > ../ssclock.log 2>&1)&

eips_print_bottom_centered "ssclock started" 3
