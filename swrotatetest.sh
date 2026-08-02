#!/bin/sh

# Software rotation test: draws a line of text sideways by rotating the pixels
# by hand. Full output goes to extensions/ssclock/swrotatetest.log

source ./libkohelper.sh

eips_print_bottom_centered "testing software rotation..." 3

cd lua
./bin/luajit swrotatetest.lua > ../swrotatetest.log 2>&1
cd ..

VERDICT=`grep -E "^(PASS|FAIL)" swrotatetest.log | head -1`
if [ -z "$VERDICT" ] ; then
	VERDICT="test did not finish, see swrotatetest.log"
fi
eips_print_bottom_centered "$VERDICT" 3
