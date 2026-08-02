# Screensaver Clock

A KUAL extension that turns a sleeping Kindle into a clock. While the
screensaver is up, the device wakes once a minute, redraws the time, and goes
straight back to sleep. Stand it on its side and you have a bedside clock.

**It will drain your battery.** A Kindle that would otherwise idle for weeks
will now want charging every few days. That is the deal.

```
        +--------------------------+
        |                          |
        |                          |
        |          23:47           |
        |                          |
        |    Sun, 02/08  |  87%    |
        |                          |
        +--------------------------+
```

## Requirements

A jailbroken Kindle with KUAL installed. Developed on a Paperwhite 2; the
original was written on a Paperwhite 3. Nothing in it is model-specific --
every size comes from what the device reports about its own screen.

## Installing

1. Copy the whole folder to `extensions/ssclock` on the Kindle
2. KUAL > Screensaver Clock > **START**
3. Put the Kindle to sleep

**STOP** ends it. After changing anything, STOP then START -- copying files
over does not affect the running clock.

The menu also has two diagnostics, described under [Diagnostics](#diagnostics).

## Configuration

Everything lives in `lua/config.lua`.

### What it shows

| Option | Default | |
|---|---|---|
| `CLOCK_TIME_FORMAT` | `"%H:%M"` | `strftime`-style; `"%I:%M %p"` for 12-hour |
| `CLOCK_DATE_FORMAT` | `"%a, %d/%m"` | the battery percentage is appended to this line |

The format codes are listed at the bottom of `config.lua`. Whatever you choose,
the layout adapts -- a long `"%A, %d %B %Y"` simply gets a smaller font than a
short `"%a %d"`.

### Where it sits

| Option | Default | |
|---|---|---|
| `ROTATION` | `"CCW"` | `"UR"` upright, `"CW"`, `"UD"`, `"CCW"` |
| `ROTATION_METHOD` | `"software"` | see [Rotation](#rotation) |
| `FULLSCREEN` | `true` | `false` gives the small fixed dialog instead |
| `FULLSCREEN_MARGIN` | `0.04` | free space each side, as a fraction of screen width |
| `FULLSCREEN_TIME_HEIGHT` | `0.50` | most of the screen height the time may occupy |
| `FULLSCREEN_DATE_HEIGHT` | `0.12` | same, for the date line |

With `FULLSCREEN = false` the clock is drawn in a fixed box, positioned and
sized by the `DIALOG_*` and `*_FONT_SIZE_PX` values -- the original behaviour,
kept for anyone who preferred it.

### Getting it onto the screen

| Option | Default | |
|---|---|---|
| `SETTLE_SECONDS` | `1.5` | pause after redrawing, before suspending again |
| `UPDATE_WAVEFORM` | `"AUTO"` | `"AUTO"`, `"GL16"`, `"GC16_FAST"`, `"DU"` |
| `RTC_DEVICE` | `"auto"` | which `/dev/rtcN` wakes the device |
| `FONT_FILE` | IBM Plex Sans Arabic | any TTF, full path |

`SETTLE_SECONDS` matters more than it looks: an eink update is asynchronous,
and suspending mid-update means the panel never shows the new time. Lower it to
save battery, raise it if updates are being cut short.

`UPDATE_WAVEFORM` trades quality for speed. `"DU"` is roughly three times
quicker but two-tone, so the smoothed edges of the big digits go blocky.

`DISABLE_BATT_LOWER_THAN` is left over from upstream and is not wired to
anything.

## How it works

### The loop

`lua/ssclock.lua` polls `powerd` for the device state. Awake, it blocks on
`lipc-wait-event` until the screensaver starts. Asleep, each pass:

1. `rtcwake -m no` arms the RTC for the top of the next minute
2. the clock is redrawn and pushed to the panel
3. `rtcwake -m mem` suspends the device until the RTC fires

Between minutes the CPU is genuinely suspended, which is what makes this
merely expensive rather than ruinous.

### Sizing the text

Nothing is hardcoded to a screen size. At startup FBInk is asked how big the
screen is, then the font size is found by binary search: the largest size at
which the text still fits on one line, measured with FBInk's `compute_only`
mode, which runs the layout without drawing anything.

It measures against every *shape* the clock can take, not just the current
time -- a day of times and a year of dates, with digits normalised away since
the font's figures are all one width. Only the words differ, so `Wednesday`
and `September` are accounted for before they ever appear. Nothing is ever
truncated, and no per-model tuning is needed.

For reference, a Paperwhite 2 (758x1024) rotated ends up around 379px for the
time and 90px for the date.

### Rotation

`ROTATION` is a quarter turn relative to however your device normally sits, not
an absolute framebuffer rotation. Some models boot reporting a non-zero
rotation while showing you a perfectly upright screen -- a Paperwhite 2 reports
3.

Rotating the framebuffer would be the obvious approach, and it is not
available: on Kindles FBInk's `fbink_set_fb_info` returns `ENOSYS`, and merely
calling it leaves the eink controller rejecting every subsequent update until
the Kindle UI resets it. So `ROTATION_METHOD` defaults to `"software"`:

1. render the line into a scratch corner of the framebuffer, **without**
   refreshing it, so the panel never shows it
2. read those pixels back with `fbink_region_dump`
3. turn them 90 degrees, a pixel at a time
4. wipe the scratch corner, blit the rotated bitmap where it belongs
5. refresh only that area

Nothing device-wide is touched. The catch is that a line must be rendered
horizontally before it can be turned, so it can never be longer than the
framebuffer is wide: the clock comes out the size of the upright one, turned
sideways, rather than the larger size a genuine landscape screen would allow.

`ROTATION_METHOD = "hardware"` tries the framebuffer first and falls back to
software if the screen dimensions do not actually change. It is not the
default, for the reason above. If your device turns the clock the wrong way,
swap `"CCW"` for `"CW"`.

### One gotcha worth knowing

`fbink_refresh` takes `(top, left, width, height)` -- not `(x, y, w, h)`. Feed
it x where it wants top and the eink driver rejects the update with `Invalid
argument` as soon as the region is off-square. Nothing appears to happen: the
drawing lands in the framebuffer, the panel is never told, and the text
materialises later when the Kindle UI refreshes the screen for its own reasons.
Every failed refresh is now logged rather than swallowed.

## Diagnostics

`start.sh` writes everything the clock has to say to
`extensions/ssclock/ssclock.log`. Plug the Kindle in over USB to read it. It
records the screen size and rotation, which rotation method it settled on, the
font sizes it measured, the RTC it chose, anything `rtcwake` complains about,
and the first several screen updates with their return codes.

Two KUAL entries answer hardware questions directly:

- **TEST screen rotation** turns the framebuffer for 8 seconds, draws text
  while turned, and reports whether the driver honoured it. On a Paperwhite 2
  it does not.
- **TEST software rotation** runs the render/read-back/rotate/blit pipeline
  once and checks that the ink reached the screen. Details land in
  `swrotatetest.log`.

## Troubleshooting

**The clock only appears when I wake the device.** The new time reached the
framebuffer but never the panel. Check the log: `the screen did NOT update`
means the refresh was rejected outright, otherwise the update was cut short by
the suspend -- raise `SETTLE_SECONDS` or set `UPDATE_WAVEFORM = "DU"`.

**The clock is upright when it should be sideways.** The log line
`Using software rotation` confirms which path was taken. `ROTATION` is
relative, so `"CCW"` turns the clock a quarter turn from normal regardless of
what rotation your framebuffer reports.

**Nothing at all, just the usual screensaver.** Check that `ssclock.log` exists
and is recent -- if not, the clock is not running. STOP then START.

**The screen is stuck sideways after stopping.** Only possible with
`ROTATION_METHOD = "hardware"`. `start.sh` and `stop.sh` restore the rotation
from `/tmp/ssclock.rota`.

## What changed from the original

The upstream extension drew the time in a fixed 360x280 box at a fixed
position, in a fixed font size, upright. This version keeps the same idea and
the same wake/suspend loop, and adds:

- **Fullscreen by default**, with the layout derived from the device's actual
  screen size and the font sizes measured rather than assumed
- **Rotation**, including a software implementation for devices whose
  framebuffer cannot be rotated
- **A fix for the refresh region**, which was being passed as `(x, y, ...)`
  where FBInk expects `(top, left, ...)`. Harmless with the original's
  near-square dialog at (95,95), where x and y were equal; fatal as soon as the
  clock covered a taller area, where it silently stopped every screen update
  reaching the panel
- **Waiting for eink updates to complete** before suspending, so a large update
  is not cut short by the device powering the panel down
- **Automatic RTC selection**, instead of a hardcoded `/dev/rtc1`
- **A log file and two hardware test entries**, because none of the above is
  debuggable when the process writes to a stdout nobody reads

## Credits

Originally written by [ngxson](https://github.com/ngxson) --
[hobby-kindle-ssclock](https://github.com/ngxson/hobby-kindle-ssclock). The
wake-once-a-minute-and-suspend loop that makes the whole thing viable is
theirs; this version mostly changes what gets drawn and how it reaches the
screen.

Built on [FBInk](https://github.com/NiLuJe/FBInk) by NiLuJe, which does all the
real work of getting pixels onto an eink panel. Set in
[IBM Plex Sans Arabic](https://github.com/IBM/plex).
