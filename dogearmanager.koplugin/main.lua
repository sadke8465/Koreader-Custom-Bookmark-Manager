--[[--
Dogear Manager plugin for KOReader.

Allows users to swap and resize their digital bookmark (dogear) icon
directly from the Tools menu, without needing a computer.

Custom dogear designs can be placed in either:
    <plugin_folder>/icons/         (bundled with the plugin)
    <koreader_data_dir>/icons/dogears/  (user-added icons)

@module koplugin.DogearManager
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

-- Settings key constants
local S_CUSTOM_ICON      = "dogear_custom_icon"
local S_CUSTOM_ICON_NAME = "dogear_custom_icon_name"
local S_SCALE_FACTOR     = "dogear_scale_factor"
local S_MARGIN_TOP       = "dogear_margin_top"
local S_MARGIN_RIGHT     = "dogear_margin_right"
-- Margin scaling: top and right increments use the same base step size
local MAX_STEPS = 20

local DogearManager = WidgetContainer:extend{
    name = "dogearmanager",
    is_doc_only = false,
}

-- Supported image extensions for dogear designs.
local SUPPORTED_EXTENSIONS = {
    [".png"] = true,
    [".svg"] = true,
    [".alpha"] = true,
    [".bmp"] = true,
    [".jpg"] = true,
    [".jpeg"] = true,
}

--- Strip fill-opacity and opacity attributes from an SVG so it always renders
--- at 100% opacity, regardless of how the file was exported.
--- Returns a path to a processed copy in KOReader's cache dir for SVG files,
--- or the original path unchanged for raster formats.
local function normalizeSvgOpacity(src_path)
    if not src_path:lower():match("%.svg$") then
        return src_path
    end
    local f = io.open(src_path, "r")
    if not f then return src_path end
    local content = f:read("*a")
    f:close()

    content = content:gsub('%s+fill%-opacity%s*=%s*"[^"]*"', "")
    content = content:gsub("%s+fill%-opacity%s*=%s*'[^']*'", "")
    content = content:gsub('%s+opacity%s*=%s*"[^"]*"', "")
    content = content:gsub("%s+opacity%s*=%s*'[^']*'", "")

    local cache_dir = DataStorage:getDataDir() .. "/cache"
    pcall(lfs.mkdir, cache_dir)
    local out_path = cache_dir .. "/dogear_icon_processed.svg"
    local fw = io.open(out_path, "w")
    if not fw then return src_path end
    fw:write(content)
    fw:close()
    return out_path
end

--- Compute pixel step size for margins based on current screen.
-- Both top and right use the same step so one increment moves equally.
-- @return step_px, step_px
local function getMarginStepSizes()
    local screen_min = math.min(Screen:getWidth(), Screen:getHeight())
    local base = math.max(2, math.ceil(screen_min / 128))
    return base, base
end

--- Convert step count to pixels for top margin.
local function topStepsToPx(steps)
    local top_step = getMarginStepSizes()
    return steps * top_step
end

--- Convert step count to pixels for right margin.
local function rightStepsToPx(steps)
    local _, right_step = getMarginStepSizes()
    return steps * right_step
end

function DogearManager:getIconsDir()
    return DataStorage:getDataDir() .. "/icons/dogears"
end

function DogearManager:getPluginIconsDir()
    return self.path .. "/icons"
end

local function scanDir(dir, list, seen)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local ext = entry:match("(%.[^%.]+)$")
            if ext and SUPPORTED_EXTENSIONS[ext:lower()] and not seen[entry] then
                seen[entry] = true
                table.insert(list, { text = entry, path = dir .. "/" .. entry })
            end
        end
    end
end

function DogearManager:scanDesigns()
    local designs = {}
    local seen = {}
    scanDir(self:getPluginIconsDir(), designs, seen)
    scanDir(self:getIconsDir(), designs, seen)
    table.sort(designs, function(a, b) return a.text < b.text end)
    return designs
end

function DogearManager:applyDogearToLive()
    local dogear_widget = self.ui and self.ui.view and self.ui.view.dogear

    if dogear_widget then
        dogear_widget.dogear_size = nil
        dogear_widget:setupDogear()
        dogear_widget:resetLayout()
        UIManager:setDirty(dogear_widget, "ui")
    end
end

--- Reset all dogear settings to defaults.
function DogearManager:resetAll()
    G_reader_settings:delSetting(S_CUSTOM_ICON)
    G_reader_settings:delSetting(S_CUSTOM_ICON_NAME)
    G_reader_settings:delSetting(S_SCALE_FACTOR)
    G_reader_settings:delSetting(S_MARGIN_TOP)
    G_reader_settings:delSetting(S_MARGIN_RIGHT)
    self:applyDogearToLive()
end

function DogearManager:applyDesign(filename, full_path)
    G_reader_settings:saveSetting(S_CUSTOM_ICON, full_path)
    G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, filename)

    self:applyDogearToLive()
    UIManager:show(InfoMessage:new{ text = _("Bookmark updated."), timeout = 2 })
end

function DogearManager:showDesignMenu()
    local designs = self:scanDesigns()

    if #designs == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No custom bookmark designs found.\n\nPlace image files (.png, .svg, .bmp, .jpg) in:\n")
                .. self:getPluginIconsDir() .. "\n" .. _("or") .. "\n"
                .. self:getIconsDir(),
        })
        return
    end

    local menu_items = {}
    for _, design in ipairs(designs) do
        local filename = design.text
        local full_path = design.path
        table.insert(menu_items, {
            text = filename,
            callback = function()
                self:applyDesign(filename, full_path)
            end,
        })
    end

    table.insert(menu_items, {
        text = _("-- Reset to Default --"),
        callback = function()
            G_reader_settings:delSetting(S_CUSTOM_ICON)
            G_reader_settings:delSetting(S_CUSTOM_ICON_NAME)
            self:applyDogearToLive()
            UIManager:show(InfoMessage:new{ text = _("Bookmark reset to default."), timeout = 2 })
        end,
    })

    local design_menu
    design_menu = Menu:new{
        title = _("Change Bookmark Design"),
        item_table = menu_items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function()
            UIManager:close(design_menu)
        end,
    }

    UIManager:show(design_menu)
end

--- Build a section label widget, left-aligned.
local function sectionLabel(text, inner_w)
    return LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(24) },
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont", 16),
            bold = true,
        },
    }
end

--- Build a horizontal separator line.
local function separator(inner_w)
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = Size.line.medium },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.medium },
            background = Blitbuffer.COLOR_GRAY,
        },
    }
end

--- Build a framed value display box (makes value fields visually distinct).
local function valueBox(text_widget, box_w, box_h)
    local b = Size.border.default
    return FrameContainer:new{
        bordersize = b,
        radius     = Size.radius.button,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = box_w - b * 2, h = box_h - b * 2 },
            text_widget,
        },
    }
end

function DogearManager:showSizeSlider(scale, mt_steps, mr_steps, icon_idx, designs)
    -- Load saved settings if not provided
    if not scale then scale = G_reader_settings:readSetting(S_SCALE_FACTOR) or 1 end
    if not mt_steps then mt_steps = G_reader_settings:readSetting(S_MARGIN_TOP) or 0 end
    if not mr_steps then mr_steps = G_reader_settings:readSetting(S_MARGIN_RIGHT) or 0 end

    -- Round and clamp scale
    scale = math.floor(scale * 10 + 0.5) / 10
    scale = math.max(0.5, math.min(4.0, scale))

    -- Clamp margin steps
    mt_steps = math.max(0, math.min(MAX_STEPS, mt_steps))
    mr_steps = math.max(0, math.min(MAX_STEPS, mr_steps))

    -- Save originals on first open so Cancel can revert
    if not self._slider_originals then
        self._slider_originals = {
            scale     = G_reader_settings:readSetting(S_SCALE_FACTOR) or 1,
            mt        = G_reader_settings:readSetting(S_MARGIN_TOP)   or 0,
            mr        = G_reader_settings:readSetting(S_MARGIN_RIGHT) or 0,
            icon      = G_reader_settings:readSetting(S_CUSTOM_ICON),
            icon_name = G_reader_settings:readSetting(S_CUSTOM_ICON_NAME),
        }
    end

    -- Scan designs once and pass through rebuilds
    if not designs then
        designs = self:scanDesigns()
    end
    if icon_idx == nil then
        local saved_icon = G_reader_settings:readSetting(S_CUSTOM_ICON)
        icon_idx = 0
        if saved_icon then
            for i, d in ipairs(designs) do
                if d.path == saved_icon then
                    icon_idx = i
                    break
                end
            end
        end
    end
    -- Clamp icon_idx in case designs changed
    icon_idx = math.max(0, math.min(icon_idx, #designs))

    local selected_icon_path = (icon_idx > 0 and designs[icon_idx]) and designs[icon_idx].path or nil
    local selected_icon_name = (icon_idx > 0 and designs[icon_idx]) and designs[icon_idx].text or nil

    -- Rebuild: close and reopen with new parameters (passes designs to avoid rescan)
    local top_widget
    local rebuild_pending = false

    -- Apply values to settings and update the live dog ear behind the modal
    local function applyLivePreview(ns, nmt, nmr, ni)
        G_reader_settings:saveSetting(S_SCALE_FACTOR, ns)
        G_reader_settings:saveSetting(S_MARGIN_TOP,   nmt)
        G_reader_settings:saveSetting(S_MARGIN_RIGHT, nmr)
        local ni_path = (ni > 0 and designs[ni]) and designs[ni].path or nil
        local ni_name = (ni > 0 and designs[ni]) and designs[ni].text or nil
        if ni_path then
            G_reader_settings:saveSetting(S_CUSTOM_ICON,      ni_path)
            G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, ni_name)
        else
            G_reader_settings:delSetting(S_CUSTOM_ICON)
            G_reader_settings:delSetting(S_CUSTOM_ICON_NAME)
        end
        self:applyDogearToLive()
    end

    local function rebuild(ns, nmt, nmr, ni)
        if rebuild_pending then return end
        rebuild_pending = true
        applyLivePreview(ns, nmt, nmr, ni)
        UIManager:close(top_widget)
        UIManager:scheduleIn(0, function()
            self:showSizeSlider(ns, nmt, nmr, ni, designs)
        end)
    end

    -- Layout dimensions
    local dialog_w  = math.floor(Screen:getWidth() * 0.90)
    local pad       = Size.padding.large
    local inner_w   = dialog_w - pad * 2
    local hspan     = Size.span.horizontal_default
    local vspan_sm  = Size.span.vertical_default
    local vspan_lg  = Size.span.vertical_default * 2
    local btn_h     = Screen:scaleBySize(52)

    -- === DESIGN section ===
    local icon_btn_w  = math.floor(inner_w * 0.18)
    local icon_name_w = inner_w - icon_btn_w * 2 - hspan * 2
    local icon_display = selected_icon_name or _("default")

    local icon_row = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = "\u{25C0}",
            width = icon_btn_w,
            enabled = #designs > 0,
            callback = function()
                local new_idx = (icon_idx == 0) and #designs or (icon_idx - 1)
                rebuild(scale, mt_steps, mr_steps, new_idx)
            end,
        },
        HorizontalSpan:new{ width = hspan },
        CenterContainer:new{
            dimen = Geom:new{ w = icon_name_w, h = btn_h },
            TextWidget:new{
                text = icon_display,
                face = Font:getFace("cfont", 18),
                max_width = icon_name_w - Size.padding.default * 2,
            },
        },
        HorizontalSpan:new{ width = hspan },
        Button:new{
            text = "\u{25B6}",
            width = icon_btn_w,
            enabled = #designs > 0,
            callback = function()
                local new_idx = (icon_idx >= #designs) and 0 or (icon_idx + 1)
                rebuild(scale, mt_steps, mr_steps, new_idx)
            end,
        },
    }

    -- === SIZE section ===
    local step_btn_w  = math.floor((inner_w - (hspan * 4)) * 0.18)
    local value_box_w = inner_w - (step_btn_w * 4) - (hspan * 4)

    local function clampScale(v)
        return math.max(0.5, math.min(4.0, math.floor(v * 10 + 0.5) / 10))
    end

    local scale_row = HorizontalGroup:new{
        align = "center",
        Button:new{ text = "−−", width = step_btn_w, callback = function() rebuild(clampScale(scale - 0.5), mt_steps, mr_steps, icon_idx) end },
        HorizontalSpan:new{ width = hspan },
        Button:new{ text = "−",  width = step_btn_w, callback = function() rebuild(clampScale(scale - 0.1), mt_steps, mr_steps, icon_idx) end },
        HorizontalSpan:new{ width = hspan },
        valueBox(
            TextWidget:new{
                text = string.format("%.1f\u{00D7}", scale),
                face = Font:getFace("cfont", 22),
                bold = true,
            },
            value_box_w, btn_h
        ),
        HorizontalSpan:new{ width = hspan },
        Button:new{ text = "+",  width = step_btn_w, callback = function() rebuild(clampScale(scale + 0.1), mt_steps, mr_steps, icon_idx) end },
        HorizontalSpan:new{ width = hspan },
        Button:new{ text = "++", width = step_btn_w, callback = function() rebuild(clampScale(scale + 0.5), mt_steps, mr_steps, icon_idx) end },
    }

    -- === POSITION section ===
    local label_w = math.floor(inner_w * 0.20)
    local mbtn_w  = math.floor(inner_w * 0.18)
    local mval_w  = inner_w - label_w - mbtn_w * 2 - hspan * 3

    local function marginRow(label, step_val, on_dec, on_inc)
        return HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = label_w, h = btn_h },
                TextWidget:new{ text = label, face = Font:getFace("cfont", 18) },
            },
            HorizontalSpan:new{ width = hspan },
            Button:new{ text = "−", width = mbtn_w, callback = on_dec },
            HorizontalSpan:new{ width = hspan },
            valueBox(
                TextWidget:new{
                    text = tostring(step_val),
                    face = Font:getFace("cfont", 20),
                    bold = true,
                },
                mval_w, btn_h
            ),
            HorizontalSpan:new{ width = hspan },
            Button:new{ text = "+", width = mbtn_w, callback = on_inc },
        }
    end

    local top_margin_row = marginRow(
        _("Top"), mt_steps,
        function() rebuild(scale, math.max(0, mt_steps - 1), mr_steps, icon_idx) end,
        function() rebuild(scale, math.min(MAX_STEPS, mt_steps + 1), mr_steps, icon_idx) end
    )
    local right_margin_row = marginRow(
        _("Right"), mr_steps,
        function() rebuild(scale, mt_steps, math.max(0, mr_steps - 1), icon_idx) end,
        function() rebuild(scale, mt_steps, math.min(MAX_STEPS, mr_steps + 1), icon_idx) end
    )

    -- === ACTION buttons ===
    local act_btn_w = math.floor((inner_w - hspan * 2) / 3)
    local actions_row = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = _("Cancel"),
            width = act_btn_w,
            callback = function()
                -- Revert the live dog ear to the original settings
                local orig = self._slider_originals
                if orig then
                    G_reader_settings:saveSetting(S_SCALE_FACTOR, orig.scale)
                    G_reader_settings:saveSetting(S_MARGIN_TOP,   orig.mt)
                    G_reader_settings:saveSetting(S_MARGIN_RIGHT, orig.mr)
                    if orig.icon then
                        G_reader_settings:saveSetting(S_CUSTOM_ICON,      orig.icon)
                        G_reader_settings:saveSetting(S_CUSTOM_ICON_NAME, orig.icon_name)
                    else
                        G_reader_settings:delSetting(S_CUSTOM_ICON)
                        G_reader_settings:delSetting(S_CUSTOM_ICON_NAME)
                    end
                    self:applyDogearToLive()
                    self._slider_originals = nil
                end
                UIManager:close(top_widget)
                UIManager:setDirty("all", "flashui")
            end,
        },
        HorizontalSpan:new{ width = hspan },
        Button:new{
            text = _("Reset"),
            width = act_btn_w,
            callback = function()
                self._slider_originals = nil
                UIManager:close(top_widget)
                UIManager:setDirty("all", "flashui")
                self:resetAll()
                UIManager:show(InfoMessage:new{ text = _("Bookmark settings reset."), timeout = 2 })
            end,
        },
        HorizontalSpan:new{ width = hspan },
        Button:new{
            text = _("Apply"),
            width = act_btn_w,
            callback = function()
                -- Settings already applied live; just commit and close
                self._slider_originals = nil
                UIManager:close(top_widget)
                UIManager:setDirty("all", "flashui")
                UIManager:scheduleIn(0, function()
                    UIManager:show(InfoMessage:new{ text = _("Bookmark updated."), timeout = 2 })
                end)
            end,
        },
    }

    -- === Compose dialog ===
    local dialog_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = pad,
        VerticalGroup:new{
            align = "center",
            -- Title
            TextWidget:new{
                text = _("Bookmark Size & Margins"),
                face = Font:getFace("cfont", 22),
                bold = true,
            },
            VerticalSpan:new{ width = vspan_lg },

            -- Design section
            separator(inner_w),
            VerticalSpan:new{ width = vspan_lg },
            sectionLabel(_("Design"), inner_w),
            VerticalSpan:new{ width = vspan_sm },
            icon_row,
            VerticalSpan:new{ width = vspan_lg },

            -- Separator
            separator(inner_w),
            VerticalSpan:new{ width = vspan_lg },

            -- Size section
            sectionLabel(_("Size"), inner_w),
            VerticalSpan:new{ width = vspan_sm },
            scale_row,
            VerticalSpan:new{ width = vspan_lg },

            -- Separator
            separator(inner_w),
            VerticalSpan:new{ width = vspan_lg },

            -- Position section
            sectionLabel(_("Position"), inner_w),
            VerticalSpan:new{ width = math.floor(vspan_sm / 2) },
            LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(18) },
                TextWidget:new{
                    text = _("Top and right steps move the dogear by equal amounts"),
                    face = Font:getFace("smallinfofont", 14),
                },
            },
            VerticalSpan:new{ width = vspan_sm },
            top_margin_row,
            VerticalSpan:new{ width = vspan_sm },
            right_margin_row,
            VerticalSpan:new{ width = vspan_lg },

            -- Actions
            actions_row,
        },
    }

    top_widget = InputContainer:new{ modal = true, dimen = Screen:getSize() }
    top_widget[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        MovableContainer:new{ dialog_frame },
    }

    if Device:isTouchDevice() then
        function top_widget:onGesture(ev)
            if self[1] and self[1]:handleEvent(Event:new("Gesture", ev)) then
                return true
            end
            if ev.ges == "tap" and dialog_frame.dimen then
                if ev.pos:notIntersectWith(dialog_frame.dimen) then
                    UIManager:close(self)
                    UIManager:setDirty("all", "flashui")
                    return true
                end
            end
        end
    end

    UIManager:show(top_widget)
end

function DogearManager:patchReaderDogear()
    local ok, err = pcall(function()
        local ReaderDogear = require("apps/reader/modules/readerdogear")

        if not ReaderDogear._dm_patched then
            ReaderDogear._dm_patched = true
            local orig_setupDogear = ReaderDogear.setupDogear
            local orig_resetLayout = ReaderDogear.resetLayout

            local function applyMarginOffset(rd_self)
                -- Guard: essential widget fields must exist
                if not (rd_self.vgroup and rd_self.icon and rd_self.top_pad) then return end
                -- Guard: dogear_size may be nil during document reflow (e.g. after a
                -- page-margin change triggers resetLayout/updateDogearOffset before
                -- orig_setupDogear has re-computed the size).  Attempting arithmetic on
                -- a nil dogear_size produces a Lua error that propagates to the C event
                -- loop and causes a SIGABRT crash when the widget is next painted.
                if not rd_self.dogear_size or rd_self.dogear_size <= 0 then return end

                local ok, err = pcall(function()
                    local mt_steps = G_reader_settings:readSetting(S_MARGIN_TOP) or 0
                    local mr_steps = G_reader_settings:readSetting(S_MARGIN_RIGHT) or 0
                    local mt = topStepsToPx(mt_steps)
                    local mr = rightStepsToPx(mr_steps)

                    -- Update main container dimensions
                    if rd_self[1] and rd_self[1].dimen then
                        rd_self[1].dimen.w = Screen:getWidth()
                        rd_self[1].dimen.h = (rd_self.dogear_y_offset or 0) + rd_self.dogear_size + mt
                    end

                    -- Apply top margin (VerticalSpan uses .width for its size)
                    rd_self.top_pad.width = (rd_self.dogear_y_offset or 0) + mt

                    -- Apply right margin
                    if mr > 0 then
                        -- Detach icon from old wrapper before freeing to avoid invalidation
                        if rd_self._dm_wrapper then
                            rd_self._dm_wrapper[1] = nil
                            rd_self._dm_wrapper:free()
                        end

                        rd_self._dm_wrapper = HorizontalGroup:new{
                            align = "top",
                            rd_self.icon,
                            HorizontalSpan:new{ width = mr },
                        }
                        rd_self.vgroup[2] = rd_self._dm_wrapper
                    else
                        if rd_self._dm_wrapper then
                            rd_self._dm_wrapper[1] = nil
                            rd_self._dm_wrapper:free()
                            rd_self._dm_wrapper = nil
                        end
                        rd_self.vgroup[2] = rd_self.icon
                    end

                    rd_self.vgroup:resetLayout()
                end)
                if not ok then
                    logger.warn("DogearManager: applyMarginOffset failed:", err)
                end
            end

            ReaderDogear.setupDogear = function(rd_self, new_dogear_size)
                local sf = G_reader_settings:readSetting(S_SCALE_FACTOR) or 1
                local icon_path = G_reader_settings:readSetting(S_CUSTOM_ICON)

                if sf ~= 1 then
                    if new_dogear_size then
                        new_dogear_size = math.ceil(new_dogear_size * sf)
                    elseif rd_self.dogear_max_size then
                        new_dogear_size = math.ceil(rd_self.dogear_max_size * sf)
                    end
                end

                -- Free old custom wrappers and icons before rebuilding
                if rd_self._dm_wrapper then
                    rd_self._dm_wrapper[1] = nil
                    rd_self._dm_wrapper:free()
                    rd_self._dm_wrapper = nil
                end
                if rd_self._dm_custom_icon then
                    rd_self._dm_custom_icon:free()
                    rd_self._dm_custom_icon = nil
                end
                if rd_self.icon and rd_self.icon.text == nil then
                    rd_self.icon:free()
                    rd_self.icon = nil
                end

                orig_setupDogear(rd_self, new_dogear_size)

                if icon_path and lfs.attributes(icon_path, "mode") == "file" and rd_self.icon then
                    rd_self.icon:free()
                    -- is_icon=true tells ImageWidget to skip pre-inversion so
                    -- KOReader's global night-mode framebuffer inversion handles
                    -- dark mode automatically (same as the built-in IconWidget).
                    -- normalizeSvgOpacity strips fill-opacity/opacity attributes
                    -- so custom SVGs always render at 100% black (or white in
                    -- night mode after inversion).
                    local new_icon = ImageWidget:new{
                        file    = normalizeSvgOpacity(icon_path),
                        width   = rd_self.dogear_size,
                        height  = rd_self.dogear_size,
                        alpha   = true,
                        is_icon = true,
                    }
                    rd_self.icon = new_icon
                    rd_self._dm_custom_icon = rd_self.icon
                end

                applyMarginOffset(rd_self)
            end

            if orig_resetLayout then
                ReaderDogear.resetLayout = function(rd_self, ...)
                    orig_resetLayout(rd_self, ...)
                    applyMarginOffset(rd_self)
                end
            end

            local orig_updateDogearOffset = ReaderDogear.updateDogearOffset
            if orig_updateDogearOffset then
                ReaderDogear.updateDogearOffset = function(rd_self, ...)
                    orig_updateDogearOffset(rd_self, ...)
                    applyMarginOffset(rd_self)
                end
            end
        end
    end)

    if not ok then
        logger.err("DogearManager: patchReaderDogear failed:", err)
    end
    self:applyDogearToLive()
end

function DogearManager:init()
    self.ui.menu:registerToMainMenu(self)
end

function DogearManager:onReaderReady()
    self:patchReaderDogear()
end

function DogearManager:addToMainMenu(menu_items)
    menu_items.dogear_manager = {
        text = _("Dogear Manager"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Change Bookmark Design"),
                keep_menu_open = false,
                callback = function() self:showDesignMenu() end,
            },
            {
                text = _("Adjust Bookmark Size & Margins"),
                keep_menu_open = false,
                callback = function() self:showSizeSlider() end,
            },
            {
                text = _("Reset to Original Dogear"),
                keep_menu_open = false,
                callback = function()
                    self:resetAll()
                    UIManager:show(InfoMessage:new{ text = _("Dogear reset to original defaults."), timeout = 2 })
                end,
            },
        },
    }
end

return DogearManager
