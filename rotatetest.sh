#!/bin/sh

# Does this device let us rotate the framebuffer? Rotates it, draws a line of
# text while rotated (so you can see for yourself which way it comes out),
# then puts everything back and reports what the driver actually did.

source ./libkohelper.sh

FBINK=./lua/bin/fbink
FBDEPTH=./lua/bin/fbdepth
LOG=/tmp/ssclock-rotatetest.log

WAS=`$FBDEPTH -o 2> $LOG`

$FBINK -f -m -M -S 3 "rotating . . ." >> $LOG 2>&1
sleep 1

$FBDEPTH -r 3 >> $LOG 2>&1
GOT=`$FBDEPTH -o 2>> $LOG`

# drawn AFTER the rotation: if the rotation is real, this comes out sideways
$FBINK -f -m -M -S 3 "SIDEWAYS = ROTATION WORKS" >> $LOG 2>&1
sleep 8

$FBDEPTH -r "$WAS" >> $LOG 2>&1

if [ "$GOT" = "3" ] ; then
	VERDICT="rotation WORKS (was $WAS, got $GOT)"
else
	VERDICT="rotation REFUSED (was $WAS, asked 3, got $GOT)"
fi
$FBINK -f -m -M -S 3 "$VERDICT" >> $LOG 2>&1
eips_print_bottom_centered "$VERDICT" 3
