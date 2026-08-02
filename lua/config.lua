local cfg = {
  CLOCK_TIME_FORMAT = "%H:%M", -- see below
  CLOCK_DATE_FORMAT = "%a, %d/%m", -- see below

  -- how the clock is turned on screen: a quarter turn relative to the normal
  -- reading orientation, NOT an absolute framebuffer rotation (some models
  -- report a non-zero one while showing you an upright screen).
  -- "UR" (upright), "CW" (90 degrees clockwise), "UD" (upside down) or
  -- "CCW" (90 degrees anti-clockwise). If your device turns out to rotate the
  -- other way around, swap "CCW" for "CW".
  ROTATION = "CCW",

  -- how the rotation is done. "software" rotates the rendered pixels by hand,
  -- which is the only thing that works on kindles: FBInk cannot rotate their
  -- framebuffer, and asking it to leaves the eink controller refusing every
  -- update until the kindle UI resets it. "hardware" tries the framebuffer
  -- first and falls back to software -- do not use it unless you know your
  -- device supports it.
  ROTATION_METHOD = "software",

  -- when true, the clock fills the whole screen and every size below is
  -- computed from the device's own screen dimensions (reported by FBInk),
  -- so it works on any kindle model. Set to false to use the fixed-size
  -- dialog defined by the DIALOG_* values.
  FULLSCREEN = true,

  -- fullscreen layout (ratios, relative to the screen)
  FULLSCREEN_MARGIN = 0.04, -- free space kept on each side, ratio of screen width
  FULLSCREEN_TIME_HEIGHT = 0.50, -- max height of the time line, ratio of screen height
  FULLSCREEN_DATE_HEIGHT = 0.12, -- max height of the date line, ratio of screen height

  DIALOG_BORDER = 5, -- unit: pixel
  DIALOG_POSITION_X = 100, -- unit: pixel
  DIALOG_POSITION_Y = 100, -- unit: pixel
  DIALOG_SIZE_W = 360, -- unit: pixel
  DIALOG_PADDING = 40, -- unit: pixel
  TIME_FONT_SIZE_PX = 150, -- unit: pixel
  DATE_FONT_SIZE_PX = 50, -- unit: pixel
  FONT_FILE = "/mnt/us/extensions/ssclock/IBMPlexSansArabic.ttf", -- ttf file
  DISABLE_BATT_LOWER_THAN = 10, -- disable when battery is lower than X percent
  RTC_DEVICE = "auto", -- "auto", or a device like "/dev/rtc1"

  -- seconds to let the eink update finish before suspending again. Too short
  -- and the panel is switched off mid-update: the new time never appears, and
  -- only shows up when the kindle UI refreshes the screen on wake.
  SETTLE_SECONDS = 1.5,

  -- waveform for the once-a-minute update: "AUTO" (full quality, slowest),
  -- "GL16" or "GC16_FAST" (quicker), "DU" (quickest, but black and white only,
  -- so the text edges lose their smoothing)
  UPDATE_WAVEFORM = "AUTO",


  -- computed values; don't change
  TIME_X = -1,
  TIME_Y = -1,
  DATE_X = -1,
  DATE_Y = -1,
  DIALOG_SIZE_H = -1,
}

cfg.TIME_X = cfg.DIALOG_POSITION_X + cfg.DIALOG_PADDING
cfg.TIME_Y = cfg.DIALOG_POSITION_Y + math.floor(cfg.DIALOG_PADDING * 0.8)
cfg.DATE_X = cfg.TIME_X
cfg.DATE_Y = cfg.TIME_Y + cfg.TIME_FONT_SIZE_PX
cfg.DIALOG_SIZE_H = (2 * cfg.DIALOG_PADDING) + cfg.TIME_FONT_SIZE_PX + cfg.DATE_FONT_SIZE_PX

--[[
  TIME FORMAT:
  %H	hour, using a 24-hour clock (23) [00-23]
  %I	hour, using a 12-hour clock (11) [01-12]
  %M	minute (48) [00-59]
  %p	either "am" or "pm" (pm)

  DATE FORMAT:
  %a	abbreviated weekday name (e.g., Wed)
  %A	full weekday name (e.g., Wednesday)
  %b	abbreviated month name (e.g., Sep)
  %m	month (09) [01-12]
  %B	full month name (e.g., September)
  %c	date and time (e.g., 09/16/98 23:48:10)
  %d	day of the month (16) [01-31]
  %w	weekday (3) [0-6 = Sunday-Saturday]
  %x	date (e.g., 09/16/98)
  %X	time (e.g., 23:48:10)
  %Y	full year (1998)
  %y	two-digit year (98) [00-99]
  %%	the character `%´
--]]

return cfg
