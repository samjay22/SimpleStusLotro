-- EasyHealthBar - HealthBarWindow.lua
-- Draggable Health and Power bar display with Ctrl+\ support

import "Turbine";
import "Turbine.Gameplay";
import "Turbine.UI";
import "Turbine.UI.Lotro";

-- =========================================================================
-- CONSTANTS (File-scope, accessible to all functions)
-- =========================================================================
CONSTANTS = {
    -- Buff Display
    BUFF_ICON_SIZE = 36,
    BUFF_SPACING = 4,
    BUFF_ROW_HEIGHT = 36 + 18,
    MAX_BUFF_DURATION = 43200, -- 12 hours in seconds
    
    -- Update Timings
    REBUILD_COOLDOWN_TICKS = 5,
    BUFF_TIMER_INTERVAL = 15,
    
    -- Alert System
    ALERT_DURATION_TICKS = 60,
    ALERT_FADE_TICKS = 15,
    LOW_THRESHOLD = 0.3,
    
    -- UI Sizing
    LABEL_WIDTH = 200,
    LABEL_HEIGHT = 30,
    STATS_TOOLTIP_WIDTH = 240,
    STATS_TOOLTIP_HEIGHT = 280,
    BUFF_TOOLTIP_WIDTH = 260,
    BUFF_TOOLTIP_HEIGHT = 80,
    
    -- Color Thresholds
    HEALTH_HIGH = 0.75,
    HEALTH_MID = 0.5,
    POWER_HIGH = 0.75,
    POWER_MID = 0.5,
};

-- Color Palette
COLORS = {
    TRANSPARENT = Turbine.UI.Color(0, 0, 0, 0),
    BLACK = Turbine.UI.Color(1, 0, 0, 0),
    
    HEALTH_HIGH = Turbine.UI.Color(1, 0.1, 0.85, 0.1),
    HEALTH_MID = Turbine.UI.Color(1, 1.0, 0.85, 0.1),
    HEALTH_LOW = Turbine.UI.Color(1, 0.9, 0.15, 0.1),
    HEALTH_BG = Turbine.UI.Color(0.2, 0.4, 0.4, 0.4),
    
    POWER_HIGH = Turbine.UI.Color(1, 0.2, 0.5, 0.9),
    POWER_MID = Turbine.UI.Color(1, 1.0, 0.85, 0.1),
    POWER_LOW = Turbine.UI.Color(1, 0.9, 0.15, 0.1),
    POWER_BG = Turbine.UI.Color(0.2, 0.2, 0.2, 0.4),
    
    TOOLTIP_BG = Turbine.UI.Color(0.92, 0.05, 0.05, 0.12),
    TOOLTIP_TITLE = Turbine.UI.Color(1, 1.0, 0.85, 0.4),
    TOOLTIP_TEXT = Turbine.UI.Color(1, 0.9, 0.9, 0.9),
    
    TEXT_HEALTH = Turbine.UI.Color(1, 0.2, 1.0, 0.2),
    TEXT_POWER = Turbine.UI.Color(1, 0.2, 0.6, 1.0),
    TEXT_WHITE = Turbine.UI.Color(1, 1, 1, 1),
    TEXT_GRAY = Turbine.UI.Color(0.8, 0.8, 0.8, 0.8),
};

-- Debuff Keywords
DEBUFF_KEYWORDS = {
    "bleed", "wound", "poison", "disease", "fear", "dread",
    "stun", "daze", "root", "slow", "debuff", "curse",
    "fire", "acid", "shadow", "corruption", "dot", "drain"
};

-- Polyfill: define class() if the Turbine environment doesn't expose it
if type(class) ~= "function" then
    function class(baseClass)
        local cls = {};
        setmetatable(cls, {
            __index = baseClass,
            __call = function(self, ...)
                local instance = baseClass();
                for k, v in pairs(cls) do
                    if type(v) == "function" then
                        instance[k] = v;
                    end
                end
                if cls.Constructor then
                    cls.Constructor(instance, ...);
                end
                return instance;
            end
        });
        return cls;
    end
end

-- =========================================================================
-- HELPER FUNCTIONS
-- =========================================================================
function CreateLabel(parent, x, y, w, h, font, color, alignment)
    local label = Turbine.UI.Label();
    label:SetParent(parent);
    label:SetPosition(x, y);
    label:SetSize(w, h);
    label:SetFont(font or Turbine.UI.Lotro.Font.Verdana14);
    label:SetForeColor(color or COLORS.TEXT_WHITE);
    label:SetTextAlignment(alignment or Turbine.UI.ContentAlignment.TopLeft);
    label:SetMouseVisible(false);
    return label;
end

function CreateTooltipWindow(width, height)
    local tooltip = Turbine.UI.Window();
    tooltip:SetSize(width, height);
    tooltip:SetBackColor(COLORS.TOOLTIP_BG);
    tooltip:SetVisible(false);
    tooltip:SetZOrder(500);
    tooltip:SetMouseVisible(false);
    tooltip:SetOpacity(1);
    tooltip:SetText("");
    return tooltip;
end

function FormatTime(seconds)
    if seconds <= 0 then return ""; end
    
    local mins = math.floor(seconds / 60);
    local secs = math.floor(seconds % 60);
    
    if mins > 60 then
        return string.format("%dh", math.floor(mins / 60));
    elseif mins > 0 then
        return string.format("%d:%02d", mins, secs);
    else
        return string.format("%ds", secs);
    end
end

function GetColorForPercentage(pct, highColor, midColor, lowColor, highThreshold, midThreshold)
    if pct >= highThreshold then
        return highColor, 3;
    elseif pct >= midThreshold then
        return midColor, 2;
    else
        return lowColor, 1;
    end
end

function SafeCall(func, default)
    local ok, result = pcall(func);
    return (ok and result) or default;
end

-- =========================================================================
-- HealthBarWindow
-- =========================================================================
HealthBarWindow = class(Turbine.UI.Window);

function HealthBarWindow:Constructor()
    Turbine.UI.Window.Constructor(self);
    self:SetVisible(true);

    -- Initialize state
    self.player = Turbine.Gameplay.LocalPlayer:GetInstance();
    self.isUnlocked = false;
    self.rebuildNeeded = false;
    self.rebuilding = false;
    self.firstBuild = true;

    -- Initialize default settings
    self:InitializeDefaultSettings();
    
    -- Load saved settings
    self:LoadSettings();

    -- Setup combat tracking
    self:InitializeCombatTracking();

    -- Create UI components
    self:CreateBuffPanel();
    self:RebuildBars();
    self.firstBuild = false;
    
    self:CreateDragOverlay();
    self:CreateSettingsPanel();
    self:CreateAlertLabel();
    
    -- Default to locked
    self:SetUnlocked(false);

    -- Setup event listeners
    self:SetupEventListeners();
    self:SetupKeyListener();
    self:SetupUpdateTimer();

    -- Initial update
    self:UpdateHealth();
    self:UpdatePower();
    self:RefreshBuffList();
end

function HealthBarWindow:InitializeDefaultSettings()
    self.numSegments = 70;
    self.curveDepth = 50;
    self.barHeightTotal = 250;
    self.centerGap = 300;
    self.segThickness = 15;
    self.combatOpacity = 50;
    self.oocOpacity = 5;
end

function HealthBarWindow:InitializeCombatTracking()
    self.inCombat = self.player:IsInCombat();
    self.targetOpacity = self.inCombat 
        and (self.combatOpacity / 100) 
        or (self.oocOpacity / 100);
    self:SetOpacity(self.targetOpacity);
    self.opacityDirty = false;
end

function HealthBarWindow:CreateBuffPanel()
    self.buffRows = {};
    self.activeBuffs = {};
    self.buffPanel = Turbine.UI.Control();
    self.buffPanel:SetParent(self);
    self.buffPanel:SetMouseVisible(false);
    self.buffPanel:SetZOrder(50);
end

function HealthBarWindow:SetupEventListeners()
    local win = self;
    
    -- Flag-based updates: events mark dirty, ProcessUpdateTick handles once per tick
    self.healthDirty = false;
    self.powerDirty = false;
    self.player.MoraleChanged = function() win.healthDirty = true; end;
    self.player.MaxMoraleChanged = function() win.healthDirty = true; end;
    self.player.PowerChanged = function() win.powerDirty = true; end;
    self.player.MaxPowerChanged = function() win.powerDirty = true; end;
    self.player.InCombatChanged = function()
        win.inCombat = win.player:IsInCombat();
        win.targetOpacity = win.inCombat 
            and (win.combatOpacity / 100) 
            or (win.oocOpacity / 100);
        win.opacityDirty = true;
    end;
    
    self.PositionChanged = function()
        if not win.rebuilding then
            win:SavePosition();
        end
    end;
    
    -- Buff events update directly
    local effects = self.player:GetEffects();
    if effects then
        effects.EffectAdded = function(sender, args)
            win:OnEffectAdded(args);
            win:RefreshBuffList();
        end;
        effects.EffectRemoved = function()
            win:RefreshBuffList();
        end;
    end
end

function HealthBarWindow:SetupKeyListener()
    local win = self;
    self.keyListener = Turbine.UI.Control();
    self.keyListener:SetWantsKeyEvents(true);
    self.keyListener.KeyDown = function(sender, args)
        -- 0x1000007B is the "Reposition UI" action (Ctrl+\)
        if args.Action == 0x1000007B then
            win:SetUnlocked(not win.isUnlocked);
        end
    end;
end

function HealthBarWindow:SetupUpdateTimer()
    local win = self;
    self.alertQueue = {};
    self.alertTimer = 0;
    self.alertShowing = false;
    self.lowHealthAlerted = false;
    self.lowPowerAlerted = false;
    
    self.startupTicks = 4;
    self.buffTimerTicks = 0;
    
    self.updateTimer = Turbine.UI.Control();
    self.updateTimer:SetWantsUpdates(true);
    
    self.updateTimer.Update = function(sender, args)
        win:ProcessUpdateTick(sender);
    end;
end

function HealthBarWindow:ProcessUpdateTick(sender)
    -- Startup retry: force full update until player data is available
    if self.startupTicks and self.startupTicks > 0 then
        self.startupTicks = self.startupTicks - 1;
        self.lastHealthPct = nil;
        self.lastHealthTier = nil;
        self.lastPowerPct = nil;
        self.lastPowerTier = nil;
        self.healthDirty = true;
        self.powerDirty = true;
        if self.startupTicks <= 0 then
            self.startupTicks = nil;
        end
    end

    -- Handle rebuild throttling
    if self.rebuildNeeded then
        if not self.rebuildCooldown or self.rebuildCooldown <= 0 then
            self.rebuildNeeded = false;
            self.rebuildCooldown = CONSTANTS.REBUILD_COOLDOWN_TICKS;
            self:RebuildBars();
        else
            self.rebuildCooldown = self.rebuildCooldown - 1;
        end
    end

    -- Process dirty flags (coalesces rapid events into one update per tick)
    if self.healthDirty then
        self.healthDirty = false;
        self:UpdateHealth();
    end
    if self.powerDirty then
        self.powerDirty = false;
        self:UpdatePower();
    end

    -- Smooth opacity transitions (skip when already at target)
    if self.opacityDirty ~= false then
        local curOp = self:GetOpacity();
        local diff = curOp - self.targetOpacity;
        if diff > 0.01 then
            self:SetOpacity(math.max(curOp - 0.02, self.targetOpacity));
        elseif diff < -0.01 then
            self:SetOpacity(math.min(curOp + 0.05, self.targetOpacity));
        else
            self.opacityDirty = false;
        end
    end

    -- Throttled buff timer updates (every BUFF_TIMER_INTERVAL ticks)
    self.buffTimerTicks = (self.buffTimerTicks or 0) + 1;
    if self.buffTimerTicks >= CONSTANTS.BUFF_TIMER_INTERVAL then
        self.buffTimerTicks = 0;
        self:UpdateBuffTimers();
    end

    -- Alert processing every tick
    if self.alertShowing or #self.alertQueue > 0 then
        self:ProcessAlerts();
    end
end

function HealthBarWindow:UpdateOpacityTransition()
    -- This method is no longer needed, handled inline in ProcessUpdateTick
end

-- =========================================================================
-- BUILD / REBUILD BARS
-- =========================================================================
function HealthBarWindow:RebuildBars()
    self.rebuilding = true;

    local dimensions = self:CalculateDimensions();
    self:SetSize(dimensions.totalWidth, dimensions.totalHeight);
    self:SetBackColor(COLORS.TRANSPARENT);
    self:SetText("");

    -- Configure buff panel
    self:PositionBuffPanel(dimensions);

    -- Load position on first build
    if self.firstBuild then
        self:LoadPosition(dimensions.totalWidth, dimensions.totalHeight);
    end

    -- Build bar segments
    local centerX = dimensions.totalWidth / 2;
    local leftBase = centerX - (self.centerGap / 2);
    local rightBase = centerX + (self.centerGap / 2);

    self:RebuildBarSegments(leftBase, rightBase);
    self:RebuildTextLabels(leftBase, rightBase, dimensions.barAreaHeight);
    self:RepositionUIElements(dimensions);

    -- Force full update
    self.lastHealthPct = -1;
    self.lastPowerPct = -1;
    self:UpdateHealth();
    self:UpdatePower();
    self:RefreshBuffList();

    self.rebuilding = false;
end

function HealthBarWindow:CalculateDimensions()
    local totalWidth = self.centerGap + (self.curveDepth * 2) + 400;
    local barAreaHeight = self.barHeightTotal + 60;

    -- Calculate buff area dimensions
    local iconsPerRow = math.floor((totalWidth + CONSTANTS.BUFF_SPACING) / 
                                   (CONSTANTS.BUFF_ICON_SIZE + CONSTANTS.BUFF_SPACING));
    if iconsPerRow < 1 then iconsPerRow = 1; end
    self.buffIconsPerRow = iconsPerRow;

    local buffCount = self.lastBuffCount or 0;
    local numRows = math.ceil(buffCount / iconsPerRow);
    if numRows < 1 then numRows = 1; end
    
    local buffHeight = numRows * (CONSTANTS.BUFF_ROW_HEIGHT + CONSTANTS.BUFF_SPACING) + 4;
    if buffHeight < CONSTANTS.BUFF_ROW_HEIGHT + 8 then 
        buffHeight = CONSTANTS.BUFF_ROW_HEIGHT + 8; 
    end

    return {
        totalWidth = totalWidth,
        totalHeight = barAreaHeight + buffHeight,
        barAreaHeight = barAreaHeight,
        buffHeight = buffHeight,
        iconsPerRow = iconsPerRow
    };
end

function HealthBarWindow:PositionBuffPanel(dimensions)
    if self.buffPanel then
        self.buffPanel:SetSize(dimensions.totalWidth, dimensions.buffHeight);
        self.buffPanel:SetPosition(0, dimensions.barAreaHeight);
        self.buffPanel:SetZOrder(50);
    end
end

function HealthBarWindow:LoadPosition(width, height)
    local screenWidth = Turbine.UI.Display:GetWidth();
    local screenHeight = Turbine.UI.Display:GetHeight();
    local pos = Turbine.PluginData.Load(Turbine.DataScope.Character, "EasyHealthBarPos");
    
    if pos and pos.x and pos.y then
        self:SetPosition(pos.x, pos.y);
    else
        self:SetPosition(
            math.floor((screenWidth - width) / 2),
            math.floor((screenHeight - height) / 2)
        );
    end
end

function HealthBarWindow:RebuildBarSegments(leftBase, rightBase)
    self.healthBGSegments = self:UpdateVerticalCurve(
        self.healthBGSegments, leftBase, COLORS.HEALTH_BG, false, -1);
    self.healthFillSegments = self:UpdateVerticalCurve(
        self.healthFillSegments, leftBase, COLORS.HEALTH_HIGH, true, -1);
    self.powerBGSegments = self:UpdateVerticalCurve(
        self.powerBGSegments, rightBase, COLORS.POWER_BG, false, 1);
    self.powerFillSegments = self:UpdateVerticalCurve(
        self.powerFillSegments, rightBase, COLORS.POWER_HIGH, true, 1);
end

function HealthBarWindow:RebuildTextLabels(leftBase, rightBase, barAreaHeight)
    local font = Turbine.UI.Lotro.Font.TrajanProBold24;
    local labelY = (barAreaHeight / 2) - 15;

    -- Health text (right-aligned, left side)
    local healthX = leftBase - CONSTANTS.LABEL_WIDTH - self.curveDepth - 10;
    self.healthTextShadow = self:CreateOrUpdateLabel(
        self.healthTextShadow, healthX + 2, labelY + 2, 
        font, COLORS.BLACK, Turbine.UI.ContentAlignment.MiddleRight, 9);
    self.healthText = self:CreateOrUpdateLabel(
        self.healthText, healthX, labelY, 
        font, COLORS.TEXT_HEALTH, Turbine.UI.ContentAlignment.MiddleRight, 10);

    -- Power text (left-aligned, right side)
    local powerX = rightBase + self.curveDepth + 10;
    self.powerTextShadow = self:CreateOrUpdateLabel(
        self.powerTextShadow, powerX + 2, labelY + 2, 
        font, COLORS.BLACK, Turbine.UI.ContentAlignment.MiddleLeft, 9);
    self.powerText = self:CreateOrUpdateLabel(
        self.powerText, powerX, labelY, 
        font, COLORS.TEXT_POWER, Turbine.UI.ContentAlignment.MiddleLeft, 10);
end

function HealthBarWindow:CreateOrUpdateLabel(label, x, y, font, color, alignment, zOrder)
    if not label then
        label = Turbine.UI.Label();
        label:SetParent(self);
    end
    label:SetFont(font);
    label:SetForeColor(color);
    label:SetTextAlignment(alignment);
    label:SetSize(CONSTANTS.LABEL_WIDTH, CONSTANTS.LABEL_HEIGHT);
    label:SetPosition(x, y);
    label:SetZOrder(zOrder);
    label:SetMouseVisible(false);
    return label;
end

function HealthBarWindow:RepositionUIElements(dimensions)
    local centerX = dimensions.totalWidth / 2;
    local centerY = dimensions.barAreaHeight / 2;

    -- Drag labels
    if self.dragLabel then
        self.dragLabel:SetPosition(centerX - 150, centerY - 55);
        self.dragLabel:SetZOrder(200);
    end
    if self.lockLabel then
        self.lockLabel:SetPosition(centerX - 150, centerY - 25);
        self.lockLabel:SetZOrder(200);
    end

    -- Alert labels
    if self.alertLabel then
        self.alertLabel:SetPosition(centerX - 200, dimensions.barAreaHeight - 35);
    end
    if self.alertShadow then
        self.alertShadow:SetPosition(centerX - 200 + 2, dimensions.barAreaHeight - 35 + 2);
    end

    -- Ensure unlocked state is correct
    if self.isUnlocked then
        self:SetMouseVisible(true);
    end
end

-- Resize a segment pool: reuse existing controls, create new ones if needed, hide extras
function HealthBarWindow:UpdateVerticalCurve(pool, xBase, color, isFill, direction)
    pool = pool or {};
    local segHeight = self.barHeightTotal / self.numSegments;
    local n = self.numSegments;

    for i = 1, n do
        local t = (i - 1) / (n - 1);
        local yNorm = (t * 2) - 1;
        local xCurve = (yNorm * yNorm) * self.curveDepth;
        local yPos = (i - 1) * segHeight + 30;

        local xPos;
        if direction == -1 then
            xPos = xBase - self.curveDepth + xCurve;
        else
            xPos = xBase + self.curveDepth - xCurve;
        end

        local seg = pool[i];
        if not seg then
            seg = Turbine.UI.Control();
            seg:SetParent(self);
            seg:SetMouseVisible(false);
            pool[i] = seg;
        end

        seg:SetSize(self.segThickness, segHeight + 1.5);
        seg:SetPosition(xPos, yPos);
        seg:SetBackColor(color);
        seg:SetVisible(not isFill);

        if not isFill then
            seg:SetOpacity(0.3);
        end
    end

    -- Hide any excess segments from a previous higher count
    for i = n + 1, #pool do
        pool[i]:SetVisible(false);
    end

    return pool;
end

function HealthBarWindow:DestroySegments()
    local function clearSegs(segs)
        if segs then
            for _, seg in ipairs(segs) do
                seg:SetParent(nil);
            end
        end
    end
    clearSegs(self.healthBGSegments);
    clearSegs(self.healthFillSegments);
    clearSegs(self.powerBGSegments);
    clearSegs(self.powerFillSegments);
    self.healthBGSegments = nil;
    self.healthFillSegments = nil;
    self.powerBGSegments = nil;
    self.powerFillSegments = nil;
end

function HealthBarWindow:DestroyLabels()
    if self.healthTextShadow then self.healthTextShadow:SetParent(nil); self.healthTextShadow = nil; end
    if self.healthText then self.healthText:SetParent(nil); self.healthText = nil; end
    if self.powerTextShadow then self.powerTextShadow:SetParent(nil); self.powerTextShadow = nil; end
    if self.powerText then self.powerText:SetParent(nil); self.powerText = nil; end
end

-- =========================================================================
-- DRAG LABELS + WINDOW-LEVEL DRAG HANDLING
-- =========================================================================
function HealthBarWindow:CreateDragOverlay()
    local w, h = self:GetSize();

    -- "Drag to Move" label (parented directly on window, no opaque overlay)
    self.dragLabel = Turbine.UI.Label();
    self.dragLabel:SetParent(self);
    self.dragLabel:SetSize(300, 30);
    self.dragLabel:SetPosition((w / 2) - 150, (h / 2) - 55);
    self.dragLabel:SetText("Drag to Move");
    self.dragLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter);
    self.dragLabel:SetFont(Turbine.UI.Lotro.Font.Verdana20);
    self.dragLabel:SetForeColor(Turbine.UI.Color(1, 1, 1, 1));
    self.dragLabel:SetBackColor(Turbine.UI.Color(0.5, 0, 0, 0));
    self.dragLabel:SetZOrder(200);
    self.dragLabel:SetMouseVisible(false);
    self.dragLabel:SetVisible(false);

    -- "Press Ctrl+\ to lock" label
    self.lockLabel = Turbine.UI.Label();
    self.lockLabel:SetParent(self);
    self.lockLabel:SetSize(300, 20);
    self.lockLabel:SetPosition((w / 2) - 150, (h / 2) - 25);
    self.lockLabel:SetText("Press Ctrl+\\ to lock");
    self.lockLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter);
    self.lockLabel:SetFont(Turbine.UI.Lotro.Font.Verdana14);
    self.lockLabel:SetForeColor(Turbine.UI.Color(0.8, 0.8, 0.8, 0.8));
    self.lockLabel:SetBackColor(Turbine.UI.Color(0.5, 0, 0, 0));
    self.lockLabel:SetZOrder(200);
    self.lockLabel:SetMouseVisible(false);
    self.lockLabel:SetVisible(false);

    -- Dragging logic handled on the window itself
    -- (all bar segments have SetMouseVisible(false), so clicks fall through to window)
    self.dragging = false;
    self.dragStartX = 0;
    self.dragStartY = 0;

    self.MouseDown = function(sender, args)
        if self.isUnlocked and (args.Button == Turbine.UI.MouseButton.Left) then
            self.dragging = true;
            self.dragStartX = args.X;
            self.dragStartY = args.Y;
        end
    end;

    self.MouseUp = function(sender, args)
        if self.dragging then
            self.dragging = false;
            self:SavePosition();
        end
    end;

    self.MouseMove = function(sender, args)
        if self.dragging then
            local currentX, currentY = self:GetPosition();
            local newX = currentX + (args.X - self.dragStartX);
            local newY = currentY + (args.Y - self.dragStartY);
            self:SetPosition(newX, newY);
        end
    end;
end

-- =========================================================================
-- SETTINGS PANEL (shown when unlocked)
-- =========================================================================
function HealthBarWindow:CreateSettingsPanel()
    local panelWidth = 260;
    local panelHeight = 290;

    self.settingsPanel = Turbine.UI.Lotro.Window();
    self.settingsPanel:SetSize(panelWidth, panelHeight);
    self.settingsPanel:SetText("Bar Settings");
    self.settingsPanel:SetVisible(false);
    self.settingsPanel:SetZOrder(200);

    -- Position it near bottom-center of screen
    local screenW = Turbine.UI.Display:GetWidth();
    local screenH = Turbine.UI.Display:GetHeight();
    self.settingsPanel:SetPosition(
        math.floor((screenW - panelWidth) / 2),
        math.floor(screenH - panelHeight - 100)
    );

    local yOff = 30;
    local rowH = 28;
    local win = self;

    -- Helper to create a slider row (label + scrollbar + value display)
    local function CreateSliderRow(parent, yPos, labelText, minVal, maxVal, currentVal, onChange)
        local lbl = Turbine.UI.Label();
        lbl:SetParent(parent);
        lbl:SetPosition(10, yPos);
        lbl:SetSize(80, rowH);
        lbl:SetText(labelText);
        lbl:SetFont(Turbine.UI.Lotro.Font.Verdana14);
        lbl:SetForeColor(Turbine.UI.Color(1, 1, 1, 1));
        lbl:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft);

        local valLabel = Turbine.UI.Label();
        valLabel:SetParent(parent);
        valLabel:SetPosition(200, yPos);
        valLabel:SetSize(50, rowH);
        valLabel:SetText(tostring(currentVal));
        valLabel:SetFont(Turbine.UI.Lotro.Font.Verdana14);
        valLabel:SetForeColor(Turbine.UI.Color(1, 1, 1, 0));
        valLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter);

        local sb = Turbine.UI.Lotro.ScrollBar();
        sb:SetParent(parent);
        sb:SetPosition(90, yPos + 5);
        sb:SetSize(105, 15);
        sb:SetOrientation(Turbine.UI.Orientation.Horizontal);
        sb:SetMinimum(minVal);
        sb:SetMaximum(maxVal);
        sb:SetValue(currentVal);

        sb.ValueChanged = function(sender, args)
            local val = sb:GetValue();
            valLabel:SetText(tostring(val));
            onChange(val);
            -- Flag a live-preview rebuild on next update tick
            win.rebuildNeeded = true;
        end;

        return sb;
    end

    -- Segments slider
    self.segSlider = CreateSliderRow(self.settingsPanel, yOff, "Segments:", 30, 200, self.numSegments, function(val)
        self.numSegments = val;
    end);

    -- Curve Depth slider
    self.depthSlider = CreateSliderRow(self.settingsPanel, yOff + rowH, "Curve:", 10, 150, self.curveDepth, function(val)
        self.curveDepth = val;
    end);

    -- Bar Height slider
    self.heightSlider = CreateSliderRow(self.settingsPanel, yOff + rowH * 2, "Height:", 80, 500, self.barHeightTotal, function(val)
        self.barHeightTotal = val;
    end);

    -- Center Gap slider
    self.gapSlider = CreateSliderRow(self.settingsPanel, yOff + rowH * 3, "Gap:", 100, 600, self.centerGap, function(val)
        self.centerGap = val;
    end);

    -- Thickness slider
    self.thickSlider = CreateSliderRow(self.settingsPanel, yOff + rowH * 4, "Thickness:", 3, 30, self.segThickness, function(val)
        self.segThickness = val;
    end);

    -- Combat Opacity slider (percent) — no rebuild needed
    self.combatOpSlider = CreateSliderRow(self.settingsPanel, yOff + rowH * 5, "Combat %:", 5, 100, self.combatOpacity, function(val)
        self.combatOpacity = val;
        self.targetOpacity = self.inCombat and (self.combatOpacity / 100) or (self.oocOpacity / 100);
        win.opacityDirty = true;
        win.rebuildNeeded = false;
    end);

    -- Out-of-Combat Opacity slider (percent) — no rebuild needed
    self.oocOpSlider = CreateSliderRow(self.settingsPanel, yOff + rowH * 6, "Idle %:", 1, 100, self.oocOpacity, function(val)
        self.oocOpacity = val;
        self.targetOpacity = self.inCombat and (self.combatOpacity / 100) or (self.oocOpacity / 100);
        win.opacityDirty = true;
        win.rebuildNeeded = false;
    end);

    -- Save button (persists to disk; live preview is automatic)
    local saveBtn = Turbine.UI.Lotro.Button();
    saveBtn:SetParent(self.settingsPanel);
    saveBtn:SetPosition((panelWidth / 2) - 40, yOff + rowH * 7 + 5);
    saveBtn:SetSize(80, 25);
    saveBtn:SetText("Save");

    saveBtn.Click = function(sender, args)
        win:SaveSettings();
    end;
end

-- =========================================================================
-- LOCK / UNLOCK
-- =========================================================================
function HealthBarWindow:SetUnlocked(unlocked)
    self.isUnlocked = unlocked;

    -- Show/hide instruction labels
    if self.dragLabel then self.dragLabel:SetVisible(unlocked); end
    if self.lockLabel then self.lockLabel:SetVisible(unlocked); end
    self.settingsPanel:SetVisible(unlocked);

    if unlocked then
        self:SetMouseVisible(true);
    else
        self:SetMouseVisible(false);
        self.dragging = false;
        -- Save settings & position when locking
        self:SaveSettings();
        self:SavePosition();
    end
end

-- =========================================================================
-- UPDATE METHODS
-- =========================================================================
function HealthBarWindow:UpdateHealth()
    self:UpdateBar(
        self.healthFillSegments,
        self.player:GetMorale(),
        self.player:GetMaxMorale(),
        COLORS.HEALTH_HIGH, COLORS.HEALTH_MID, COLORS.HEALTH_LOW,
        CONSTANTS.HEALTH_HIGH, CONSTANTS.HEALTH_MID,
        "lastHealthPct", "lastHealthTier",
        self.healthText, self.healthTextShadow,
        "lowHealthAlerted", "LOW HEALTH!", Turbine.UI.Color(1, 1.0, 0.2, 0.2)
    );
end

function HealthBarWindow:UpdatePower()
    self:UpdateBar(
        self.powerFillSegments,
        self.player:GetPower(),
        self.player:GetMaxPower(),
        COLORS.POWER_HIGH, COLORS.POWER_MID, COLORS.POWER_LOW,
        CONSTANTS.POWER_HIGH, CONSTANTS.POWER_MID,
        "lastPowerPct", "lastPowerTier",
        self.powerText, self.powerTextShadow,
        "lowPowerAlerted", "LOW POWER!", Turbine.UI.Color(1, 0.3, 0.5, 1.0)
    );
end

function HealthBarWindow:UpdateBar(segments, current, max, highColor, midColor, lowColor,
                                    highThresh, midThresh, pctKey, tierKey, 
                                    textLabel, shadowLabel, alertKey, alertText, alertColor)
    if not segments then return; end

    if not max or max == 0 then max = 1; end
    if not current then current = 0; end

    local pct = math.min(math.max(current / max, 0), 1);
    local pctInt = math.floor(pct * 1000);
    
    -- Skip if nothing changed
    if self[pctKey] == pctInt then return; end

    local oldStartIdx = self:CalculateOldStartIndex(self[pctKey]);
    self[pctKey] = pctInt;

    local color, colorTier = GetColorForPercentage(pct, highColor, midColor, lowColor, 
                                                    highThresh, midThresh);
    local tierChanged = (self[tierKey] ~= nil and self[tierKey] ~= colorTier);
    self[tierKey] = colorTier;

    local visibleCount = math.floor(self.numSegments * pct);
    local startIdx = self.numSegments - visibleCount + 1;

    -- Update visible segments
    local lo, hi = self:CalculateUpdateRange(startIdx, oldStartIdx, tierChanged);
    for i = lo, hi do
        local seg = segments[i];
        if seg then
            if i >= startIdx then
                seg:SetVisible(true);
                if tierChanged or i >= oldStartIdx then
                    seg:SetBackColor(color);
                end
            else
                seg:SetVisible(false);
            end
        end
    end

    -- Update text
    local txt = tostring(math.floor(pct * 100)) .. "%";
    if textLabel then textLabel:SetText(txt); end
    if shadowLabel then shadowLabel:SetText(txt); end

    -- Handle low resource alert
    if pct < CONSTANTS.LOW_THRESHOLD and not self[alertKey] then
        self[alertKey] = true;
        self:ShowAlert(alertText, alertColor);
    elseif pct >= CONSTANTS.LOW_THRESHOLD then
        self[alertKey] = false;
    end
end

function HealthBarWindow:CalculateOldStartIndex(lastPct)
    if lastPct and lastPct >= 0 then
        local oldPct = lastPct / 1000;
        local oldVisible = math.floor(self.numSegments * oldPct);
        return self.numSegments - oldVisible + 1;
    end
    return 0;
end

function HealthBarWindow:CalculateUpdateRange(startIdx, oldStartIdx, tierChanged)
    if oldStartIdx == 0 or tierChanged then
        -- First update or tier change: repaint all visible segments
        return startIdx, self.numSegments;
    else
        -- Delta update - only update changed segments
        return math.min(startIdx, oldStartIdx), math.max(startIdx, oldStartIdx);
    end
end

-- =========================================================================
-- ALERT SYSTEM
-- =========================================================================
function HealthBarWindow:CreateAlertLabel()
    local w, h = self:GetSize();
    local centerX = w / 2;
    local bottomY = h - 35;

    self.alertShadow = CreateLabel(self, centerX - 200 + 2, bottomY + 2, 
        400, 30, Turbine.UI.Lotro.Font.TrajanProBold24, COLORS.BLACK, 
        Turbine.UI.ContentAlignment.MiddleCenter);
    self.alertShadow:SetZOrder(150);
    self.alertShadow:SetVisible(false);

    self.alertLabel = CreateLabel(self, centerX - 200, bottomY, 
        400, 30, Turbine.UI.Lotro.Font.TrajanProBold24, 
        Turbine.UI.Color(1, 1, 0.2, 0.2), 
        Turbine.UI.ContentAlignment.MiddleCenter);
    self.alertLabel:SetZOrder(151);
    self.alertLabel:SetVisible(false);
end

function HealthBarWindow:ShowAlert(text, color)
    table.insert(self.alertQueue, { text = text, color = color });
end

function HealthBarWindow:ProcessAlerts()
    if self.alertShowing then
        self:UpdateAlertAnimation();
        return;
    end

    if #self.alertQueue > 0 then
        self:DisplayNextAlert();
    end
end

function HealthBarWindow:UpdateAlertAnimation()
    self.alertTimer = self.alertTimer - 1;
    
    if self.alertTimer <= CONSTANTS.ALERT_FADE_TICKS and self.alertTimer > 0 then
        local alpha = self.alertTimer / CONSTANTS.ALERT_FADE_TICKS;
        if self.alertLabel then self.alertLabel:SetOpacity(alpha); end
        if self.alertShadow then self.alertShadow:SetOpacity(alpha); end
    elseif self.alertTimer <= 0 then
        self.alertShowing = false;
        if self.alertLabel then self.alertLabel:SetVisible(false); end
        if self.alertShadow then self.alertShadow:SetVisible(false); end
    end
end

function HealthBarWindow:DisplayNextAlert()
    local alert = table.remove(self.alertQueue, 1);
    self.alertShowing = true;
    self.alertTimer = CONSTANTS.ALERT_DURATION_TICKS;

    if self.alertLabel then
        self.alertLabel:SetText(alert.text);
        if alert.color then
            self.alertLabel:SetForeColor(alert.color);
        end
        self.alertLabel:SetOpacity(1);
        self.alertLabel:SetVisible(true);
    end
    if self.alertShadow then
        self.alertShadow:SetText(alert.text);
        self.alertShadow:SetOpacity(1);
        self.alertShadow:SetVisible(true);
    end
end

function HealthBarWindow:OnEffectAdded(args)
    local effect = args;
    if not effect then return; end
    
    local name = SafeCall(function() return effect:GetName() end, "");
    if name == "" then return; end
    
    if self:IsEffectHarmful(effect) then
        self:ShowAlert(name, Turbine.UI.Color(1, 1.0, 0.5, 0.1));
    end
end

-- =========================================================================
-- PERSISTENCE
-- =========================================================================
function HealthBarWindow:SavePosition()
    local x, y = self:GetPosition();
    Turbine.PluginData.Save(Turbine.DataScope.Character, "EasyHealthBarPos", { x = x, y = y });
end

function HealthBarWindow:SaveSettings()
    local settings = {
        numSegments = self.numSegments,
        curveDepth = self.curveDepth,
        barHeightTotal = self.barHeightTotal,
        centerGap = self.centerGap,
        segThickness = self.segThickness,
        combatOpacity = self.combatOpacity,
        oocOpacity = self.oocOpacity,
    };
    Turbine.PluginData.Save(Turbine.DataScope.Character, "EasyHealthBarSettings", settings);
end

function HealthBarWindow:LoadSettings()
    local settings = Turbine.PluginData.Load(Turbine.DataScope.Character, "EasyHealthBarSettings");
    if settings then
        self.numSegments = math.min(settings.numSegments or self.numSegments, 200);
        self.curveDepth = settings.curveDepth or self.curveDepth;
        self.barHeightTotal = settings.barHeightTotal or self.barHeightTotal;
        self.centerGap = settings.centerGap or self.centerGap;
        self.segThickness = settings.segThickness or self.segThickness;
        self.combatOpacity = settings.combatOpacity or self.combatOpacity;
        self.oocOpacity = settings.oocOpacity or self.oocOpacity;
    end
end

-- =========================================================================
-- BUFF DISPLAY SYSTEM
-- =========================================================================
function HealthBarWindow:RefreshBuffList()
    if not self.buffRows then self.buffRows = {}; end
    if not self.buffPanel then return; end

    -- Hide all existing buff items
    for _, item in ipairs(self.buffRows) do
        item:SetVisible(false);
    end
    self.activeBuffs = {};
    
    local effects = self.player:GetEffects();
    if not effects then return; end
    
    -- Collect valid buffs
    local validEffects = self:CollectValidEffects(effects);
    local numBuffs = #validEffects;
    
    -- Trigger rebuild if buff count changed
    if self.lastBuffCount ~= numBuffs then
        self.lastBuffCount = numBuffs;
        if not self.rebuilding then
            self.rebuildNeeded = true;
        end
    end

    -- Calculate layout
    local panelW = self.buffPanel:GetWidth();
    local iconsPerRow = math.floor((panelW + CONSTANTS.BUFF_SPACING) / 
                                   (CONSTANTS.BUFF_ICON_SIZE + CONSTANTS.BUFF_SPACING));
    if iconsPerRow < 1 then iconsPerRow = 1; end

    -- Display buffs
    for i, effect in ipairs(validEffects) do
        self:DisplayBuffIcon(i, effect, iconsPerRow, numBuffs, panelW);
    end
end

function HealthBarWindow:CollectValidEffects(effects)
    local validEffects = {};
    local count = effects:GetCount();
    
    for i = 1, count do
        local effect = effects:Get(i);
        if not self:IsEffectHarmful(effect) and self:ShouldDisplayEffect(effect) then
            table.insert(validEffects, effect);
        end
    end
    
    return validEffects;
end

function HealthBarWindow:ShouldDisplayEffect(effect)
    local duration = SafeCall(function() return effect:GetDuration() end, 0);
    
    -- Filter out permanent buffs and very long duration buffs (> 12 hours)
    if duration <= 0 or duration > CONSTANTS.MAX_BUFF_DURATION then
        return false;
    end
    
    return true;
end

function HealthBarWindow:DisplayBuffIcon(index, effect, iconsPerRow, totalBuffs, panelWidth)
    local item = self.buffRows[index];
    if not item then
        item = self:CreateBuffIconItem();
        table.insert(self.buffRows, item);
    end
    
    -- Update content
    local success = pcall(function() item:SetEffect(effect); end);
    if not success then
        item.icon:SetVisible(false);
    end

    -- Calculate position with row centering
    local col = (index - 1) % iconsPerRow;
    local row = math.floor((index - 1) / iconsPerRow);
    
    local rowStart = row * iconsPerRow + 1;
    local rowEnd = math.min(rowStart + iconsPerRow - 1, totalBuffs);
    local iconsInRow = rowEnd - rowStart + 1;
    local rowWidth = iconsInRow * CONSTANTS.BUFF_ICON_SIZE + 
                    (iconsInRow - 1) * CONSTANTS.BUFF_SPACING;
    local rowOffsetX = math.max((panelWidth - rowWidth) / 2, 0);

    local xPos = rowOffsetX + col * (CONSTANTS.BUFF_ICON_SIZE + CONSTANTS.BUFF_SPACING);
    local yPos = row * (CONSTANTS.BUFF_ROW_HEIGHT + CONSTANTS.BUFF_SPACING);
    
    item:SetPosition(xPos, yPos);
    item:SetVisible(true);
    
    table.insert(self.activeBuffs, item);
end

function HealthBarWindow:CreateBuffIconItem()
    local size = CONSTANTS.BUFF_ICON_SIZE;
    local item = Turbine.UI.Control();
    item:SetParent(self.buffPanel);
    item:SetSize(size, size + 16);
    item:SetMouseVisible(true);
    
    -- Tooltip window — auto-sizing based on content
    local TT_WIDTH = 300;
    item.tooltip = CreateTooltipWindow(TT_WIDTH, 200);
    
    -- Tooltip title
    item.tooltipName = CreateLabel(
        item.tooltip, 4, 4, TT_WIDTH - 8, 22,
        Turbine.UI.Lotro.Font.Verdana16,
        Turbine.UI.Color(1, 1.0, 0.85, 0.4),
        Turbine.UI.ContentAlignment.TopLeft
    );
    
    -- Tooltip description
    item.tooltipDesc = CreateLabel(
        item.tooltip, 4, 28, TT_WIDTH - 8, 170,
        Turbine.UI.Lotro.Font.Verdana14,
        COLORS.TOOLTIP_TEXT,
        Turbine.UI.ContentAlignment.TopLeft
    );
    
    -- Icon
    item.icon = Turbine.UI.Control();
    item.icon:SetParent(item);
    item.icon:SetSize(size, size);
    item.icon:SetPosition(0, 0);
    item.icon:SetBlendMode(Turbine.UI.BlendMode.AlphaBlend);
    item.icon:SetMouseVisible(false);
    
    -- Timer label
    item.timerLabel = CreateLabel(
        item, -5, size - 4, size + 10, 16,
        Turbine.UI.Lotro.Font.Verdana12,
        COLORS.TEXT_WHITE,
        Turbine.UI.ContentAlignment.TopCenter
    );
    item.timerLabel:SetOutlineColor(COLORS.BLACK);
    item.timerLabel:SetFontStyle(Turbine.UI.FontStyle.Outline);
    
    -- Hover events
    local win = self;
    item.MouseEnter = function(sender, args)
        if sender.effectName and sender.effectName ~= "" then
            sender.tooltipName:SetText(sender.effectName);
            
            -- Build tooltip body with description + duration
            local body = sender.effectDesc or "";
            
            if sender.effectDuration and sender.effectDuration > 0 then
                local dur = sender.effectDuration;
                local durStr;
                if dur >= 3600 then
                    durStr = string.format("%.1f hours", dur / 3600);
                elseif dur >= 60 then
                    durStr = string.format("%d min %d sec", math.floor(dur/60), math.floor(dur%60));
                else
                    durStr = string.format("%d sec", math.floor(dur));
                end
                if body ~= "" then body = body .. "\n"; end
                body = body .. "\nDuration: " .. durStr;
            end
            
            sender.tooltipDesc:SetText(body);
            
            -- Auto-size tooltip based on content
            local lines = 2;
            for _ in string.gmatch(body, "\n") do lines = lines + 1; end
            local descLines = math.max(lines, math.ceil(string.len(body) / 38));
            local ttHeight = 32 + descLines * 16;
            ttHeight = math.max(60, math.min(ttHeight, 300));
            
            sender.tooltip:SetSize(TT_WIDTH, ttHeight);
            sender.tooltipDesc:SetSize(TT_WIDTH - 8, ttHeight - 32);
            
            -- Position tooltip above icon
            local ix, iy = sender:GetPosition();
            local px, py = win.buffPanel:GetPosition();
            local wx, wy = win:GetPosition();
            sender.tooltip:SetPosition(wx + px + ix - (TT_WIDTH/2) + (size/2), wy + py + iy - ttHeight - 4);
            sender.tooltip:SetVisible(true);
        end
    end;
    
    item.MouseLeave = function(sender, args)
        sender.tooltip:SetVisible(false);
    end;
    
    -- Method to set effect data
    item.SetEffect = function(sender, effect)
        sender.effect = effect;
        sender.effectName = SafeCall(function() return effect:GetName() end, "");
        sender.effectDesc = SafeCall(function() return effect:GetDescription() end, "");
        sender.effectDuration = SafeCall(function() return effect:GetDuration() end, 0);
        
        local iconID = SafeCall(function() return effect:GetIcon() end, nil);
        if iconID and type(iconID) == "number" then
            sender.icon:SetBackground(iconID);
            sender.icon:SetVisible(true);
        else
            sender.icon:SetVisible(false);
        end
    end
    
    return item;
end

function HealthBarWindow:UpdateBuffTimers()
    if not self.activeBuffs then return; end
    local currentTime = Turbine.Engine.GetGameTime();
    
    for _, row in ipairs(self.activeBuffs) do
        if row.effect then
            local duration = row.effect:GetDuration();
            local startTime = row.effect:GetStartTime();
            local newText;
            
            if duration > 86400 or duration <= 0 then
                newText = "";
            else
                local remaining = duration - (currentTime - startTime);
                if remaining < 0 then remaining = 0; end
                newText = FormatTime(remaining);
            end
            
            -- Only call SetText when the display text actually changes
            if row.lastTimerText ~= newText then
                row.lastTimerText = newText;
                row.timerLabel:SetText(newText);
            end
        end
    end
end

function HealthBarWindow:IsEffectHarmful(effect)
    if not effect then return false; end
    
    -- Check API flag
    if SafeCall(function() return effect:IsDebuff() end, false) then 
        return true; 
    end
    
    -- Check keywords in name
    local name = SafeCall(function() return effect:GetName() end, "");
    if name == "" then return false; end
    
    local nameLower = string.lower(name);
    for _, kw in ipairs(DEBUFF_KEYWORDS) do
        if string.find(nameLower, kw) then
            return true;
        end
    end
    
    return false;
end
