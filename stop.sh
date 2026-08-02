#!/bin/sh

source ./libkohelper.sh

kill `ps aux | grep ssclock.lua | grep -v grep | awk '{ print $2 }'`

# put the screen back the way the kindle UI wants it, in case we killed the
# clock while it was holding a rotation
if [ -f /tmp/ssclock.rota ] ; then
	./lua/bin/fbdepth -r `cat /tmp/ssclock.rota`
	rm -f /tmp/ssclock.rota
fi

eips_print_bottom_centered "ssclock stopped" 3
