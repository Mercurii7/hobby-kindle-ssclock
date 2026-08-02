#!/usr/bin/env luajit

-- Does software rotation work on this device?
--
-- Renders a line of text into a scratch corner of the framebuffer without
-- refreshing it, reads those pixels back, rotates the bytes by hand, and blits
-- the result to the middle of the screen. If the pipeline works you get text
-- reading bottom-to-top; the numbers in the log say whether each step did what
-- it was supposed to.

local cfg = require("config")
local ffi = require("ffi")
local _ = require("ffi/fbink_h")
local FBInk = ffi.load("lib/libfbink.so.1.0.0")

local fbink_state = ffi.new("FBInkState")
local fbink_cfg = ffi.new("FBInkConfig")
local fbink_ot = ffi.new("FBInkOTConfig")
local fbink_dump = ffi.new("FBInkDump")
local fbink_rect = ffi.new("FBInkRect")

print("FBInk " .. ffi.string(FBInk.fbink_version()))

local fbfd = FBInk.fbink_open()
if fbfd == -1 then
	print("FAIL: cannot open the framebuffer")
	os.exit(1)
end

fbink_cfg.no_refresh = true
FBInk.fbink_add_ot_font_v2(cfg.FONT_FILE, 0, fbink_ot)
FBInk.fbink_init(fbfd, fbink_cfg)
FBInk.fbink_get_state(fbink_cfg, fbink_state)

local FB_W = fbink_state.screen_width
local FB_H = fbink_state.screen_height
local BPP = fbink_state.bpp
print("screen " .. FB_W .. "x" .. FB_H .. ", " .. BPP .. "bpp, rotation " .. fbink_state.current_rota)

-- the scratch box we render into, and then rotate out of
local PAD = 10
local BOX_W = FB_W - (2 * PAD)
local BOX_H = math.floor(FB_H * 0.18)
local TEXT = "SIDEWAYS"

-- how much of a region is dark: proof that the text is where we think it is
local function darkRatio(data, stride, w, h, step)
	local dark, total = 0, 0
	for y = 0, h - 1, 4 do
		for x = 0, w - 1, 4 do
			local v = data[(y * stride) + (x * step)]
			if v < 128 then
				dark = dark + 1
			end
			total = total + 1
		end
	end
	return dark / total
end

-- 1. render the text horizontally, into the framebuffer but NOT onto the panel
fbink_ot.padding = 3 -- full padding, so the box gets a clean white background
fbink_ot.is_centered = true
fbink_ot.size_px = math.floor(BOX_H * 0.6)
fbink_ot.margins.left = PAD
fbink_ot.margins.top = PAD
fbink_ot.margins.right = FB_W - PAD - BOX_W
fbink_ot.margins.bottom = FB_H - PAD - BOX_H
local ret = FBInk.fbink_printf(fbfd, fbink_ot, fbink_cfg, TEXT)
print("1. render " .. BOX_W .. "x" .. BOX_H .. " @ " .. fbink_ot.size_px .. "px returned " .. ret)
if ret < 0 then
	print("FAIL: could not render the text")
	os.exit(1)
end

-- 2. read the pixels back
ret = FBInk.fbink_region_dump(fbfd, PAD, PAD, BOX_W, BOX_H, fbink_cfg, fbink_dump)
local stride = tonumber(fbink_dump.stride)
local step = math.floor(fbink_dump.bpp / 8)
print("2. region_dump returned " .. ret
	.. ", area " .. fbink_dump.area.left .. "," .. fbink_dump.area.top
	.. " " .. fbink_dump.area.width .. "x" .. fbink_dump.area.height
	.. ", " .. fbink_dump.bpp .. "bpp, stride " .. stride
	.. ", size " .. tonumber(fbink_dump.size))
if ret < 0 or fbink_dump.data == nil then
	print("FAIL: the framebuffer cannot be read back, software rotation is not possible")
	os.exit(1)
end
if step < 1 then
	print("FAIL: " .. fbink_dump.bpp .. "bpp is not supported by this test")
	os.exit(1)
end

-- FBInk is allowed to hand back a different area than the one we asked for
local SRC_W = math.min(BOX_W, fbink_dump.area.width)
local SRC_H = math.min(BOX_H, fbink_dump.area.height)
if SRC_W ~= BOX_W or SRC_H ~= BOX_H then
	print("   note: the dump came back as " .. SRC_W .. "x" .. SRC_H .. ", using that")
end

local src_dark = darkRatio(fbink_dump.data, stride, SRC_W, SRC_H, step)
print("   the dump is " .. math.floor(src_dark * 100) .. "% dark pixels (should be a few %, that's the text)")

-- 3. rotate the bytes, 90 degrees anti-clockwise
local dst_w, dst_h = SRC_H, SRC_W
local len = dst_w * dst_h
local dst = ffi.new("uint8_t[?]", len)
local src = fbink_dump.data

local readGray
if step == 1 then
	readGray = function(off) return src[off] end
elseif step == 2 then -- RGB565, take the green channel as the gray level
	readGray = function(off) return (((src[off + 1] % 8) * 8) + math.floor(src[off] / 32)) * 4 end
else -- 24/32bpp, the green byte will do, our content is gray anyway
	readGray = function(off) return src[off + 1] end
end

local t0 = os.clock()
for y = 0, SRC_H - 1 do
	local row = y * stride
	for x = 0, SRC_W - 1 do
		-- anti-clockwise: the right edge of the source becomes the top
		dst[((SRC_W - 1 - x) * dst_w) + y] = readGray(row + (x * step))
	end
end
local rotate_ms = (os.clock() - t0) * 1000
print("3. rotated " .. SRC_W .. "x" .. SRC_H .. " into " .. dst_w .. "x" .. dst_h
	.. " in " .. string.format("%.0f", rotate_ms) .. "ms")

FBInk.fbink_free_dump_data(fbink_dump)

-- 4. wipe the scratch box, so only the rotated copy is left
fbink_rect.left = PAD
fbink_rect.top = PAD
fbink_rect.width = BOX_W
fbink_rect.height = BOX_H
FBInk.fbink_cls(fbfd, fbink_cfg, fbink_rect, false)

-- 5. blit the rotated pixels to the middle of the screen
local px = math.floor((FB_W - dst_w) / 2)
local py = math.floor((FB_H - dst_h) / 2)
ret = FBInk.fbink_print_raw_data(fbfd, dst, dst_w, dst_h, len, px, py, fbink_cfg)
print("5. print_raw_data " .. dst_w .. "x" .. dst_h .. " @ " .. px .. "," .. py .. " returned " .. ret)
if ret < 0 then
	print("FAIL: could not blit the rotated pixels")
	os.exit(1)
end

-- 6. push it to the panel
fbink_cfg.no_refresh = false
fbink_cfg.is_flashing = true
FBInk.fbink_refresh(fbfd, 0, 0, FB_W, FB_H, fbink_cfg)
fbink_cfg.is_flashing = false
fbink_cfg.no_refresh = true
FBInk.fbink_wait_for_complete(fbfd, FBInk.LAST_MARKER)

-- 7. read the blitted area back: it should hold as much ink as the source did
ret = FBInk.fbink_region_dump(fbfd, px, py, dst_w, dst_h, fbink_cfg, fbink_dump)
if ret >= 0 and fbink_dump.data ~= nil then
	local dst_dark = darkRatio(fbink_dump.data, tonumber(fbink_dump.stride),
		math.min(dst_w, fbink_dump.area.width),
		math.min(dst_h, fbink_dump.area.height),
		math.floor(fbink_dump.bpp / 8))
	print("7. the blitted area is " .. math.floor(dst_dark * 100) .. "% dark pixels")
	if dst_dark > (src_dark * 0.5) then
		print("PASS: the rotated text made it to the screen")
	else
		print("FAIL: the blitted area has no text in it")
	end
	FBInk.fbink_free_dump_data(fbink_dump)
end

print("leaving it on screen for 12 seconds")
os.execute("sleep 12")

-- tidy up: a clean screen, the kindle UI redraws itself when you touch it
fbink_cfg.no_refresh = false
fbink_cfg.is_flashing = true
FBInk.fbink_cls(fbfd, fbink_cfg, nil, false)
fbink_cfg.is_flashing = false
FBInk.fbink_wait_for_complete(fbfd, FBInk.LAST_MARKER)
FBInk.fbink_close(fbfd)
