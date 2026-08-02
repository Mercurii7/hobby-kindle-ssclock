#!/usr/bin/env luajit

local cfg = require("config")
local ffi = require("ffi")
local C = ffi.C
local _ = require("ffi/fbink_h")
local FBInk = ffi.load("lib/libfbink.so.1.0.0")
print("Loaded FBInk " .. ffi.string(FBInk.fbink_version()))
local haslipc, lipc = pcall(require, "liblipclua")
local fbink_state = ffi.new("FBInkState")
local fbink_cfg = ffi.new("FBInkConfig")
local fbink_ot = ffi.new("FBInkOTConfig")
local fbink_fit = ffi.new("FBInkOTFit")
local fbink_dump = ffi.new("FBInkDump")

function os.executeCaptured(cmd)
  local f = assert(io.popen(cmd, "r"))
  local s = assert(f:read("*a"))
  f:close()
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  s = string.gsub(s, "[\n\r]+", " ")
  return s
end

function getBatteryLevel()
	local lvl = os.executeCaptured("lipc-get-prop com.lab126.powerd battLevel")
	return tonumber(lvl)
end

-- Open the FB
local fbfd = FBInk.fbink_open()
if fbfd == -1 then
	print("Failed to open the framebuffer, aborting . . .")
	os.exit(-1)
end



-- Prepare
-- fbink_cfg.is_quiet = true
fbink_cfg.no_refresh = true
FBInk.fbink_add_ot_font_v2(
	cfg.FONT_FILE,
	0, -- regular
	fbink_ot
)
FBInk.fbink_init(fbfd, fbink_cfg)
fbink_ot.padding = 3 -- full padding

local BORDER = cfg.DIALOG_BORDER
local LAST_DATE = ""

-- Values from fbink.h. Spelled out rather than read off the FBInk namespace:
-- a lookup that failed would take the whole clock down with it.
local LAST_MARKER = 0
local KEEP_CURRENT_BITDEPTH = 128
local KEEP_CURRENT_GRAYSCALE = 128
local WAVEFORMS = {AUTO = 0, DU = 1, GC16 = 2, GL16 = 5, GC16_FAST = 8}

-- Rotation. ROTATION is a quarter-turn count relative to however the device
-- normally sits, NOT an absolute framebuffer rotation: plenty of devices boot
-- with a non-zero one while showing you an upright screen.
local ROTATIONS = {UR = 0, CW = 1, UD = 2, CCW = 3}
local ROTATION_METHOD = cfg.ROTATION_METHOD or "auto"
local ROTA_STATE_FILE = "/tmp/ssclock.rota" -- so stop.sh can undo a rotation
local REL_ROTA, ORIGINAL_ROTA, TARGET_ROTA

-- The framebuffer as it really is . . .
local FB_WIDTH, FB_HEIGHT, FB_BPP
-- . . . and the space the layout is computed in. The two only differ when we
-- rotate in software: then the layout gets the landscape screen it wants, and
-- every rect is mapped back onto the real (portrait) panel when drawing.
local SCREEN_WIDTH, SCREEN_HEIGHT
local SW_ROTATE = false

local function readState()
	FBInk.fbink_get_state(fbink_cfg, fbink_state)
	FB_WIDTH = fbink_state.screen_width
	FB_HEIGHT = fbink_state.screen_height
	FB_BPP = fbink_state.bpp
	if SW_ROTATE and (REL_ROTA == ROTATIONS.CW or REL_ROTA == ROTATIONS.CCW) then
		SCREEN_WIDTH, SCREEN_HEIGHT = FB_HEIGHT, FB_WIDTH
	else
		SCREEN_WIDTH, SCREEN_HEIGHT = FB_WIDTH, FB_HEIGHT
	end
end

readState()
ORIGINAL_ROTA = fbink_state.current_rota
REL_ROTA = ROTATIONS[cfg.ROTATION]
if not REL_ROTA then
	print("Unknown ROTATION '" .. tostring(cfg.ROTATION) .. "', keeping the screen upright")
	REL_ROTA = 0
end
TARGET_ROTA = (ORIGINAL_ROTA + REL_ROTA) % 4
print("Screen: " .. FB_WIDTH .. "x" .. FB_HEIGHT .. ", " .. FB_BPP .. "bpp"
	.. ", rotation " .. ORIGINAL_ROTA
	.. " -> " .. TARGET_ROTA .. " (" .. cfg.ROTATION .. ")")

-- The corner we render text into before rotating it. It sits inside the
-- border, so wiping it never eats the frame.
local SCRATCH_X, SCRATCH_Y = BORDER, BORDER



-- Text measuring helpers (FBInk can compute a layout without drawing it)

local function setMargins(m)
	fbink_ot.margins.top = m.top
	fbink_ot.margins.bottom = m.bottom
	fbink_ot.margins.left = m.left
	fbink_ot.margins.right = m.right
end

-- a measuring box of w x h, in the top left corner of the real framebuffer
local function measureBox(w, h)
	return {top = 0, left = 0, right = FB_WIDTH - w, bottom = FB_HEIGHT - h}
end

-- true when `text` fits on a single line inside the box described by `m`
local function fitsOnOneLine(text, size_px, m)
	setMargins(m)
	fbink_ot.size_px = size_px
	fbink_ot.compute_only = true
	fbink_ot.no_truncation = true
	fbink_fit.computed_lines = 0
	local ret = FBInk.fbink_print_ot(fbfd, text, fbink_ot, fbink_cfg, fbink_fit)
	fbink_ot.compute_only = false
	fbink_ot.no_truncation = false
	return ret >= 0 and fbink_fit.computed_lines == 1
end

local function allFitOnOneLine(texts, size_px, m)
	for i = 1, #texts do
		if not fitsOnOneLine(texts[i], size_px, m) then
			return false
		end
	end
	return true
end

-- biggest font size at which every string of `texts` still fits on one line
-- inside a box of avail_w x avail_h, or nil when even the smallest doesn't
local function fitFontSize(texts, avail_w, avail_h)
	local m = measureBox(avail_w, avail_h)
	local lo, hi, best = 8, avail_h, nil
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if allFitOnOneLine(texts, mid, m) then
			best = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return best
end

-- how tall the line box has to be so that `texts` render untruncated at size_px
local function fitLineHeight(texts, size_px, avail_w)
	local lo, hi = size_px, math.floor(size_px * 3)
	local best = hi
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if allFitOnOneLine(texts, size_px, measureBox(avail_w, mid)) then
			best = mid
			hi = mid - 1
		else
			lo = mid + 1
		end
	end
	return best
end

-- every distinct shape the clock can take, digits normalized away (the font
-- uses same-width digits, only the words -- weekday, month, am/pm -- differ)
local function sampleStrings(fmt, from, to, step, suffix)
	local seen, out = {}, {}
	for t = from, to, step do
		local s = string.gsub(os.date(fmt, t), "%d", "0") .. (suffix or "")
		if not seen[s] then
			seen[s] = true
			out[#out + 1] = s
		end
	end
	return out
end



-- Layout: rects of the form {x, y, w, h}, in layout space

local layout = nil

local function computeFullscreenLayout()
	local layout = {}
	local side = math.floor(SCREEN_WIDTH * cfg.FULLSCREEN_MARGIN)
	local pad = BORDER + side
	local avail_w = SCREEN_WIDTH - (2 * pad)
	if SW_ROTATE then
		-- a rotated line is rendered horizontally first, so it can never be
		-- longer than the framebuffer is wide
		avail_w = math.min(avail_w, FB_WIDTH - (2 * BORDER))
	end

	local now = os.time()
	-- a day's worth of times, and a year's worth of dates
	local time_texts = sampleStrings(cfg.CLOCK_TIME_FORMAT, now, now + 86400, 1800)
	local date_texts = sampleStrings(cfg.CLOCK_DATE_FORMAT, now, now + (366 * 86400), 86400, "  | 000%")

	local time_size = fitFontSize(time_texts, avail_w, math.floor(SCREEN_HEIGHT * cfg.FULLSCREEN_TIME_HEIGHT))
	local date_size = fitFontSize(date_texts, avail_w, math.floor(SCREEN_HEIGHT * cfg.FULLSCREEN_DATE_HEIGHT))
	local time_h, date_h
	if time_size and date_size then
		time_h = fitLineHeight(time_texts, time_size, avail_w)
		date_h = fitLineHeight(date_texts, date_size, avail_w)
	else
		-- measuring is unavailable for some reason, fall back to plain ratios
		print("Could not measure the font, using estimated sizes")
		time_size = math.floor(avail_w / 3.2)
		date_size = math.floor(time_size * 0.28)
		time_h = math.floor(time_size * 1.35)
		date_h = math.floor(date_size * 1.35)
	end

	local gap = math.floor(date_size * 0.5)
	local block_h = math.min(time_h + gap + date_h, SCREEN_HEIGHT - (2 * BORDER))
	local block_x = math.floor((SCREEN_WIDTH - avail_w) / 2)
	local time_top = math.max(math.floor((SCREEN_HEIGHT - block_h) / 2), BORDER)
	local date_top = time_top + time_h + gap
	print("Font sizes: time=" .. time_size .. "px date=" .. date_size .. "px")

	layout.centered = true
	-- the frame fills the screen, the white area sits BORDER pixels inside it
	layout.frame = {x = 0, y = 0, w = SCREEN_WIDTH, h = SCREEN_HEIGHT}
	layout.inner = {
		x = BORDER,
		y = BORDER,
		w = SCREEN_WIDTH - (2 * BORDER),
		h = SCREEN_HEIGHT - (2 * BORDER),
	}
	layout.time = {x = block_x, y = time_top, w = avail_w, h = time_h, size = time_size}
	layout.date = {x = block_x, y = date_top, w = avail_w, h = date_h, size = date_size}
	-- only the text block has to be pushed to the panel on every update
	layout.refresh = {x = block_x, y = time_top, w = avail_w, h = block_h}
	return layout
end

local function computeDialogLayout()
	local layout = {}
	layout.centered = false
	layout.frame = {
		x = cfg.DIALOG_POSITION_X - BORDER,
		y = cfg.DIALOG_POSITION_Y - BORDER,
		w = cfg.DIALOG_SIZE_W + (2 * BORDER),
		h = cfg.DIALOG_SIZE_H + (2 * BORDER),
	}
	layout.inner = {
		x = cfg.DIALOG_POSITION_X,
		y = cfg.DIALOG_POSITION_Y,
		w = cfg.DIALOG_SIZE_W,
		h = cfg.DIALOG_SIZE_H,
	}
	layout.time = {
		x = cfg.TIME_X,
		y = cfg.TIME_Y,
		w = cfg.DIALOG_SIZE_W - (cfg.TIME_X - cfg.DIALOG_POSITION_X),
		h = cfg.TIME_FONT_SIZE_PX,
		size = cfg.TIME_FONT_SIZE_PX,
	}
	layout.date = {
		x = cfg.DATE_X,
		y = cfg.DATE_Y,
		w = cfg.DIALOG_SIZE_W - (cfg.DATE_X - cfg.DIALOG_POSITION_X),
		h = cfg.DATE_FONT_SIZE_PX,
		size = cfg.DATE_FONT_SIZE_PX,
	}
	layout.refresh = layout.frame
	return layout
end

-- the layout depends on the screen size, which changes when we rotate, so
-- keep one per geometry instead of measuring the font again every time
local layout_cache = {}

local function ensureLayout()
	local key = SCREEN_WIDTH .. "x" .. SCREEN_HEIGHT .. (SW_ROTATE and "-sw" or "")
	if not layout_cache[key] then
		if cfg.FULLSCREEN then
			layout_cache[key] = computeFullscreenLayout()
		else
			layout_cache[key] = computeDialogLayout()
		end
		print()
	end
	layout = layout_cache[key]
end



-- Drawing. Layout rects are mapped onto the panel, which is a no-op unless we
-- are rotating in software.

local function toPanel(r)
	if not SW_ROTATE then
		return r
	end
	if REL_ROTA == ROTATIONS.CCW then
		return {x = r.y, y = SCREEN_WIDTH - r.x - r.w, w = r.h, h = r.w}
	elseif REL_ROTA == ROTATIONS.CW then
		return {x = SCREEN_HEIGHT - r.y - r.h, y = r.x, w = r.h, h = r.w}
	elseif REL_ROTA == ROTATIONS.UD then
		return {x = SCREEN_WIDTH - r.x - r.w, y = SCREEN_HEIGHT - r.y - r.h, w = r.w, h = r.h}
	end
	return r
end

-- panel rect -> the margins FBInk wants
local function marginsOf(r)
	return {
		left = r.x,
		top = r.y,
		right = FB_WIDTH - r.x - r.w,
		bottom = FB_HEIGHT - r.y - r.h,
	}
end

local UPDATE_WAVEFORM = WAVEFORMS[cfg.UPDATE_WAVEFORM] or WAVEFORMS.AUTO
local log_updates = 8 -- chatty for the first few, then quiet

local function refreshRegion(rect, flashing)
	fbink_cfg.no_refresh = false
	fbink_cfg.is_flashing = flashing and true or false
	fbink_cfg.wfm_mode = flashing and WAVEFORMS.AUTO or UPDATE_WAVEFORM
	-- NOTE: fbink_refresh takes (top, left, width, height), NOT (x, y, w, h).
	-- Feed it x as the top and the eink driver rejects the update as soon as
	-- the region is off the square -- silently, and the panel never updates.
	local ret = FBInk.fbink_refresh(fbfd, rect.y, rect.x, rect.w, rect.h, fbink_cfg)
	fbink_cfg.is_flashing = false
	fbink_cfg.no_refresh = true
	-- fbink_refresh only submits the update: a big one takes the better part of
	-- a second to land, and suspending before it does leaves the panel showing
	-- the previous content (the text stays stuck in the framebuffer until the
	-- kindle UI refreshes the panel itself, on wake)
	local waited = FBInk.fbink_wait_for_complete(fbfd, LAST_MARKER)
	if ret < 0 or log_updates > 0 then
		log_updates = log_updates - 1
		print("refresh x=" .. rect.x .. " y=" .. rect.y .. " " .. rect.w .. "x" .. rect.h
			.. (flashing and " flashing" or (" wfm " .. UPDATE_WAVEFORM))
			.. " -> " .. ret .. ", wait_for_complete -> " .. waited)
		if ret < 0 then
			print("  the screen did NOT update; the region has to fit in "
				.. FB_WIDTH .. "x" .. FB_HEIGHT)
		end
	end
end

-- fill a panel rect with the background (or foreground) colour: printing a
-- space with full padding paints the whole box
local function fillRect(r, inverted)
	fbink_cfg.is_inverted = inverted and true or false
	fbink_ot.is_centered = false
	fbink_ot.size_px = math.min(layout.time.size, r.h)
	setMargins(marginsOf(r))
	FBInk.fbink_printf(fbfd, fbink_ot, fbink_cfg, " ")
	fbink_cfg.is_inverted = false
end

local function drawText(text, box, centered)
	fbink_ot.is_centered = centered
	fbink_ot.size_px = box.size
	setMargins(marginsOf(toPanel(box)))
	FBInk.fbink_printf(fbfd, fbink_ot, fbink_cfg, text)
end



-- Software rotation: render the line into the scratch corner without
-- refreshing, read the pixels back, turn them, and blit them where they go.

local rot_slots = {}

local function grayReader(step)
	if step == 1 then
		return function(src, off) return src[off] end
	elseif step == 2 then -- RGB565, the green channel is a good gray level
		return function(src, off)
			return (((src[off + 1] % 8) * 8) + math.floor(src[off] / 32)) * 4
		end
	end
	-- 24/32bpp: the green byte will do, our content is gray anyway
	return function(src, off) return src[off + 1] end
end

local function rotateDump(dump, want_w, want_h, slot_key)
	local stride = tonumber(dump.stride)
	local step = math.floor(dump.bpp / 8)
	local src = dump.data
	-- FBInk may hand back a different area than the one we asked for
	local sw = math.min(want_w, dump.area.width)
	local sh = math.min(want_h, dump.area.height)
	local dw, dh
	if REL_ROTA == ROTATIONS.UD then
		dw, dh = sw, sh
	else
		dw, dh = sh, sw
	end

	local len = dw * dh
	local slot = rot_slots[slot_key]
	if not slot or slot.len ~= len then
		slot = {buf = ffi.new("uint8_t[?]", len), len = len}
		rot_slots[slot_key] = slot
	end
	local dst = slot.buf
	local read = grayReader(step)

	if REL_ROTA == ROTATIONS.CCW then
		-- anti-clockwise: the right edge of the source becomes the top
		for y = 0, sh - 1 do
			local row = y * stride
			for x = 0, sw - 1 do
				dst[((sw - 1 - x) * dw) + y] = read(src, row + (x * step))
			end
		end
	elseif REL_ROTA == ROTATIONS.CW then
		for y = 0, sh - 1 do
			local row = y * stride
			for x = 0, sw - 1 do
				dst[(x * dw) + (sh - 1 - y)] = read(src, row + (x * step))
			end
		end
	else -- upside down
		for y = 0, sh - 1 do
			local row = y * stride
			for x = 0, sw - 1 do
				dst[((sh - 1 - y) * dw) + (sw - 1 - x)] = read(src, row + (x * step))
			end
		end
	end

	return dst, dw, dh, len
end

local function renderRotated(text, box, centered, slot_key)
	fbink_ot.is_centered = centered
	fbink_ot.size_px = box.size
	setMargins({
		top = SCRATCH_Y,
		left = SCRATCH_X,
		right = FB_WIDTH - SCRATCH_X - box.w,
		bottom = FB_HEIGHT - SCRATCH_Y - box.h,
	})
	FBInk.fbink_printf(fbfd, fbink_ot, fbink_cfg, text)

	local ret = FBInk.fbink_region_dump(fbfd, SCRATCH_X, SCRATCH_Y, box.w, box.h, fbink_cfg, fbink_dump)
	if ret < 0 or fbink_dump.data == nil then
		print("region_dump failed (" .. ret .. "), cannot rotate")
		return nil
	end
	local buf, w, h, len = rotateDump(fbink_dump, box.w, box.h, slot_key)
	FBInk.fbink_free_dump_data(fbink_dump)
	return buf, w, h, len
end

local function blit(buf, w, h, len, box)
	local r = toPanel(box)
	FBInk.fbink_print_raw_data(fbfd, buf, w, h, len, r.x, r.y, fbink_cfg)
end



function displayClock(battery_percent)
	local display_time = os.date(cfg.CLOCK_TIME_FORMAT)
	local display_date = os.date(cfg.CLOCK_DATE_FORMAT) .. "  | " .. battery_percent .. "%%"

	if SW_ROTATE then
		-- both lines go through the same scratch corner, so both have to be
		-- redrawn: wiping the scratch would otherwise eat the other one
		local tb, tw, th, tl = renderRotated(display_time, layout.time, layout.centered, "time")
		local db, dw, dh, dl = renderRotated(display_date, layout.date, layout.centered, "date")
		fillRect({
			x = SCRATCH_X,
			y = SCRATCH_Y,
			w = math.max(layout.time.w, layout.date.w),
			h = math.max(layout.time.h, layout.date.h),
		}, false)
		if tb then
			blit(tb, tw, th, tl, layout.time)
		end
		if db then
			blit(db, dw, dh, dl, layout.date)
		end
	else
		drawText(display_time, layout.time, layout.centered)
		if LAST_DATE ~= display_date then
			drawText(display_date, layout.date, layout.centered)
		end
	end

	LAST_DATE = display_date
	-- flush to screen
	refreshRegion(toPanel(layout.refresh))
end

function drawDialogBackground()
	fillRect(toPanel(layout.frame), true)
	fillRect(toPanel(layout.inner), false)
	-- flush the whole background to screen, flashing to clear the ghosting
	-- left by the screensaver image we just painted over
	refreshRegion(toPanel(layout.frame), true)
end



-- Rotation. Hardware rotation is a device-wide setting the kindle UI also
-- depends on, so we only hold it while the screensaver is up; where the
-- framebuffer refuses to rotate, we do it ourselves instead.

local function setHardwareRotation(rota)
	if fbink_state.current_rota == rota then
		return
	end
	local ret = FBInk.fbink_set_fb_info(
		fbfd,
		rota,
		KEEP_CURRENT_BITDEPTH,
		KEEP_CURRENT_GRAYSCALE,
		fbink_cfg
	)
	FBInk.fbink_reinit(fbfd, fbink_cfg)
	readState()
	print("set_fb_info(rota=" .. rota .. ") returned " .. ret
		.. ", rotation is now " .. fbink_state.current_rota
		.. ", screen " .. FB_WIDTH .. "x" .. FB_HEIGHT
		.. ", can_rotate " .. tostring(fbink_state.can_rotate))
end

local function rememberRotation()
	local f = io.open(ROTA_STATE_FILE, "w")
	if f then
		f:write(tostring(ORIGINAL_ROTA) .. "\n")
		f:close()
	end
end

local function setupRotation()
	SW_ROTATE = false
	readState()
	if REL_ROTA == 0 then
		return
	end

	local quarter_turn = (REL_ROTA == ROTATIONS.CW or REL_ROTA == ROTATIONS.CCW)
	-- Only when explicitly asked for. On kindles fbink_set_fb_info is not
	-- implemented (it returns ENOSYS), and worse, calling it leaves the eink
	-- controller rejecting every update until the kindle UI resets it -- a
	-- clock that cannot draw anything at all.
	if ROTATION_METHOD == "hardware" then
		local was_w = FB_WIDTH
		rememberRotation()
		setHardwareRotation(TARGET_ROTA)
		-- a quarter turn HAS to swap the screen dimensions. Whether the driver
		-- echoes the rotation value back is worth nothing: plenty of them
		-- accept it and carry on drawing exactly as before.
		if quarter_turn and FB_WIDTH ~= was_w then
			print("Hardware rotation in effect, screen is " .. FB_WIDTH .. "x" .. FB_HEIGHT)
			return
		end
		print("Hardware rotation had no effect on the screen geometry")
		setHardwareRotation(ORIGINAL_ROTA)
		os.remove(ROTA_STATE_FILE) -- nothing left to undo
	end

	SW_ROTATE = true
	readState()
	print("Using software rotation, layout is " .. SCREEN_WIDTH .. "x" .. SCREEN_HEIGHT)
end

local IN_CLOCK_MODE = false

function enterClockMode()
	if IN_CLOCK_MODE then
		return
	end
	setupRotation()
	ensureLayout()
	IN_CLOCK_MODE = true
	drawDialogBackground()
end

function leaveClockMode()
	if not IN_CLOCK_MODE then
		return
	end
	setHardwareRotation(ORIGINAL_ROTA)
	os.remove(ROTA_STATE_FILE)
	SW_ROTATE = false
	readState()
	IN_CLOCK_MODE = false
end

-- for testing
-- enterClockMode()
-- displayClock(getBatteryLevel())
-- leaveClockMode()
-- os.exit(0)



-- The RTC we ask to wake us up on. Which one can actually wake the device
-- differs between models, so try the configured one and fall back.
local RTC_DEVICE = cfg.RTC_DEVICE
if RTC_DEVICE == "auto" then
	RTC_DEVICE = nil
	for _, dev in ipairs({"/dev/rtc1", "/dev/rtc0"}) do
		local f = io.open(dev, "r")
		if f then
			f:close()
			RTC_DEVICE = dev
			break
		end
	end
	if not RTC_DEVICE then
		RTC_DEVICE = "/dev/rtc1"
		print("Found no /dev/rtc*, falling back to " .. RTC_DEVICE)
	end
end
print("Using RTC " .. RTC_DEVICE)

-- rtcwake is chatty and its failures are the kind of thing that leaves the
-- clock frozen, so report what it says -- but only once per distinct message
local rtcwake_said = {}
local function rtcwake(mode, seconds)
	local out = os.executeCaptured(
		"rtcwake -d " .. RTC_DEVICE .. " -m " .. mode .. " -s " .. seconds .. " 2>&1")
	if out ~= "" and not rtcwake_said[out] then
		rtcwake_said[out] = true
		print("rtcwake -m " .. mode .. ": " .. out)
	end
end



-- Main loop
local log_loops = 8

while true do
	local state = os.executeCaptured("lipc-get-prop com.lab126.powerd state")
	local battery_percent = getBatteryLevel()
	if log_loops > 0 then
		log_loops = log_loops - 1
		print(os.date("%H:%M:%S") .. " powerd state: " .. state .. ", battery " .. tostring(battery_percent))
	end

	if (state == "screenSaver" or state == "readyToSuspend" or state == "suspended") then
		-- screensaver is showing
		-- (no-op unless we started while the device was already asleep)
		enterClockMode()

		local current_seconds = os.time() % 60
		local wait_seconds = 60 - current_seconds + 1
		rtcwake("no", wait_seconds)

		-- update the clock
		displayClock(battery_percent)

		-- put back to sleep mode. The settle delay is what stands between the
		-- eink update and the suspend that would cut it short, for devices
		-- where waiting on the update does not actually wait.
		os.execute("sleep " .. cfg.SETTLE_SECONDS)
		rtcwake("mem", wait_seconds)
		os.execute("sleep 0.2")
	else
		-- screensaver is NOT showing
		-- give the screen back to the kindle UI and wait for the user to
		-- enter screensaver mode
		LAST_DATE = ""
		leaveClockMode()
		os.executeCaptured("lipc-wait-event com.lab126.powerd goingToScreenSaver,readyToSuspend")
		os.execute("sleep 1.5")
		enterClockMode()
	end
end
