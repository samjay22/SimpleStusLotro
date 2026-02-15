-- EasyHealthBar - HealthBarWindow.lua
-- Draggable Health and Power bar display with Ctrl+\ support

import "Turbine";
import "Turbine.Gameplay";
import "Turbine.UI";
import "Turbine.UI.Lotro";

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
-- HealthBarWindow
-- =========================================================================
HealthBarWindow = class(Turbine.UI.Window);

function HealthBarWindow:Constructor()
    Turbine.UI.Window.Constructor(self);

    self:SetVisible(true);

    -- Get the local player
    self.player = Turbine.Gameplay.LocalPlayer:GetInstance();
    self.isUnlocked = false;
    self.rebuildNeeded = false;
    self.rebuilding = false;

    -- =====================
    -- DEFAULT BAR SETTINGS
    -- =====================
    self.numSegments = 100;
    self.curveDepth = 50;
    self.barHeightTotal = 250;
    self.centerGap = 300;
    self.segThickness = 15;
    self.combatOpacity = 50;   -- percent (0-100)
    self.oocOpacity = 5;       -- percent (0-100)

    -- Load saved settings
    self:LoadSettings();

    -- Combat state
    self.inCombat = self.player:IsInCombat();
    self.targetOpacity = self.inCombat and (self.combatOpacity / 100) or (self.oocOpacity / 100);
    self:SetOpacity(self.targetOpacity);

    -- Create buff panel BEFORE first build so RebuildBars can position it
    self.buffRows = {};
    self.activeBuffs = {};
    self.buffPanel = Turbine.UI.Control();
    self.buffPanel:SetParent(self);
    self.buffPanel:SetMouseVisible(false);
    self.buffPanel:SetZOrder(50);

    -- Build the bars (first build includes position loading)
    self.firstBuild = true;
    self:RebuildBars();
    self.firstBuild = false;

    -- =====================
    -- DRAG OVERLAY (visible only when unlocked via Ctrl+\)
    -- =====================
    self:CreateDragOverlay();

    -- =====================
    -- SETTINGS PANEL (visible only when unlocked)
    -- =====================
    self:CreateSettingsPanel();

    -- =====================
    -- STATS TOOLTIP (hover over bars to see stats)
    -- =====================
    self:CreateStatsTooltip();

    -- Default to locked
    self:SetUnlocked(false);

    -- =====================
    -- GLOBAL KEY LISTENER for Ctrl+\ (Reposition UI)
    -- =====================
    self.keyListener = Turbine.UI.Control();
    self.keyListener:SetWantsKeyEvents(true);
    local win = self;
    self.keyListener.KeyDown = function(sender, args)
        -- 0x1000007B is the "Reposition UI" action (Ctrl+\)
        if (args.Action == 0x1000007B) then
            win:SetUnlocked(not win.isUnlocked);
        end
    end;

    -- =====================
    -- EVENT HOOKS
    -- =====================
    self.player.MoraleChanged = function(sender, args)
        self:UpdateHealth();
    end;
    self.player.MaxMoraleChanged = function(sender, args)
        self:UpdateHealth();
    end;
    self.player.PowerChanged = function(sender, args)
        self:UpdatePower();
    end;
    self.player.MaxPowerChanged = function(sender, args)
        self:UpdatePower();
    end;
    self.PositionChanged = function(sender, args)
        if not self.rebuilding then
            self:SavePosition();
        end
    end;

    -- Combat state tracking
    self.player.InCombatChanged = function(sender, args)
        self.inCombat = self.player:IsInCombat();
        self.targetOpacity = self.inCombat and (self.combatOpacity / 100) or (self.oocOpacity / 100);
    end;

    -- =====================
    -- ALERT SYSTEM
    -- =====================
    self.alertQueue = {};
    self.alertTimer = 0;
    self.alertShowing = false;
    self.lowHealthAlerted = false;
    self.lowPowerAlerted = false;
    self:CreateAlertLabel();

    -- =====================
    -- DEBUFF / EFFECT WATCHER & BUFF BAR
    -- =====================

    local effects = self.player:GetEffects();
    if effects then
        effects.EffectAdded = function(sender, args)
            self:OnEffectAdded(args);
            self:RefreshBuffList();
        end;
        effects.EffectRemoved = function(sender, args)
            self:RefreshBuffList();
        end;
    end;

    -- Initial update
    self:UpdateHealth();
    self:UpdatePower();
    self:RefreshBuffList();

    -- Periodic timer for missed events AND live preview rebuilds
    self.updateTimer = Turbine.UI.Control();
    self.updateTimer:SetWantsUpdates(true);
    self.updateTimer.accumulator = 0;
    self.updateTimer.buffTick = 0;
    self.updateTimer.Update = function(sender, args)
        -- Live preview: rebuild with throttle (at most once per 8 ticks ~0.5s)
        if win.rebuildNeeded then
            if not win.rebuildCooldown or win.rebuildCooldown <= 0 then
                win.rebuildNeeded = false;
                win.rebuildCooldown = 8;
                win:RebuildBars();
            else
                win.rebuildCooldown = win.rebuildCooldown - 1;
            end
        end

        -- Smooth opacity fade for combat/out-of-combat
        local curOp = win:GetOpacity();
        if math.abs(curOp - win.targetOpacity) > 0.01 then
            if curOp < win.targetOpacity then
                win:SetOpacity(math.min(curOp + 0.05, win.targetOpacity));
            else
                win:SetOpacity(math.max(curOp - 0.02, win.targetOpacity));
            end
        end

        -- Buff Timer (every 10 ticks ~0.3s)
        if not sender.buffTick then sender.buffTick = 0; end
        sender.buffTick = sender.buffTick + 1;
        if sender.buffTick >= 10 then
            sender.buffTick = 0;
            win:UpdateBuffTimers();
        end

        -- Periodic health/power refresh
        sender.accumulator = sender.accumulator + 1;
        if sender.accumulator >= 30 then
            sender.accumulator = 0;
            win:UpdateHealth();
            win:UpdatePower();
        end

        -- Alert fade/queue processing
        win:ProcessAlerts();
    end;
end

-- =========================================================================
-- BUILD / REBUILD BARS
-- =========================================================================
function HealthBarWindow:RebuildBars()
    self.rebuilding = true;

    local totalWidth = self.centerGap + (self.curveDepth * 2) + 400;
    local barAreaHeight = self.barHeightTotal + 60;

    -- Calculate buff area height based on how many rows we need
    local BUFF_ICON_SIZE = 36;
    local BUFF_SPACING = 4;
    local BUFF_ROW_HEIGHT = BUFF_ICON_SIZE + 18; -- icon + timer text
    local iconsPerRow = math.floor((totalWidth + BUFF_SPACING) / (BUFF_ICON_SIZE + BUFF_SPACING));
    if iconsPerRow < 1 then iconsPerRow = 1; end
    self.buffIconsPerRow = iconsPerRow;

    -- Estimate rows needed (use cached count or default to 1 row)
    local buffCount = self.lastBuffCount or 0;
    local numRows = math.ceil(buffCount / iconsPerRow);
    if numRows < 1 then numRows = 1; end
    local buffHeight = numRows * (BUFF_ROW_HEIGHT + BUFF_SPACING) + 4;
    if buffHeight < BUFF_ROW_HEIGHT + 8 then buffHeight = BUFF_ROW_HEIGHT + 8; end

    local totalHeight = barAreaHeight + buffHeight;

    self:SetSize(totalWidth, totalHeight);
    self:SetBackColor(Turbine.UI.Color(0, 0, 0, 0));
    self:SetText("");

    -- Configure Buff Panel Position (centered below bars)
    if self.buffPanel then
        local panelW = totalWidth;
        self.buffPanel:SetSize(panelW, buffHeight);
        self.buffPanel:SetPosition(0, barAreaHeight);
        self.buffPanel:SetZOrder(50);
    end

    -- Only load/set position on the very first build
    if self.firstBuild then
        local screenWidth = Turbine.UI.Display:GetWidth();
        local screenHeight = Turbine.UI.Display:GetHeight();
        local pos = Turbine.PluginData.Load(Turbine.DataScope.Character, "EasyHealthBarPos");
        if pos and pos.x and pos.y then
            self:SetPosition(pos.x, pos.y);
        else
            self:SetPosition(
                math.floor((screenWidth - totalWidth) / 2),
                math.floor((screenHeight - totalHeight) / 2)
            );
        end
    end

    local centerX = totalWidth / 2;
    local leftBase = centerX - (self.centerGap / 2);
    local rightBase = centerX + (self.centerGap / 2);

    -- Reuse or create segments (pool-based)
    self.healthBGSegments = self:UpdateVerticalCurve(self.healthBGSegments, leftBase, Turbine.UI.Color(0.2, 0.4, 0.4, 0.4), false, -1);
    self.healthFillSegments = self:UpdateVerticalCurve(self.healthFillSegments, leftBase, Turbine.UI.Color(1, 0.1, 0.7, 0.1), true, -1);
    self.powerBGSegments = self:UpdateVerticalCurve(self.powerBGSegments, rightBase, Turbine.UI.Color(0.2, 0.2, 0.2, 0.4), false, 1);
    self.powerFillSegments = self:UpdateVerticalCurve(self.powerFillSegments, rightBase, Turbine.UI.Color(1, 0.2, 0.5, 0.9), true, 1);

    -- Create or reuse text labels
    local font = Turbine.UI.Lotro.Font.TrajanProBold24;
    local labelWidth = 200;
    local labelHeight = 30;

    if not self.healthTextShadow then
        self.healthTextShadow = Turbine.UI.Label();
        self.healthTextShadow:SetParent(self);
    end
    self.healthTextShadow:SetFont(font);
    self.healthTextShadow:SetForeColor(Turbine.UI.Color(1, 0, 0, 0));
    self.healthTextShadow:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight);
    self.healthTextShadow:SetSize(labelWidth, labelHeight);
    self.healthTextShadow:SetPosition(leftBase - labelWidth - self.curveDepth - 10 + 2, (barAreaHeight / 2) - 15 + 2);
    self.healthTextShadow:SetZOrder(9);
    self.healthTextShadow:SetMouseVisible(false);

    if not self.healthText then
        self.healthText = Turbine.UI.Label();
        self.healthText:SetParent(self);
    end
    self.healthText:SetFont(font);
    self.healthText:SetForeColor(Turbine.UI.Color(1, 0.2, 1.0, 0.2));
    self.healthText:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleRight);
    self.healthText:SetSize(labelWidth, labelHeight);
    self.healthText:SetPosition(leftBase - labelWidth - self.curveDepth - 10, (barAreaHeight / 2) - 15);
    self.healthText:SetZOrder(10);
    self.healthText:SetMouseVisible(false);

    if not self.powerTextShadow then
        self.powerTextShadow = Turbine.UI.Label();
        self.powerTextShadow:SetParent(self);
    end
    self.powerTextShadow:SetFont(font);
    self.powerTextShadow:SetForeColor(Turbine.UI.Color(1, 0, 0, 0));
    self.powerTextShadow:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft);
    self.powerTextShadow:SetSize(labelWidth, labelHeight);
    self.powerTextShadow:SetPosition(rightBase + self.curveDepth + 10 + 2, (barAreaHeight / 2) - 15 + 2);
    self.powerTextShadow:SetZOrder(9);
    self.powerTextShadow:SetMouseVisible(false);

    if not self.powerText then
        self.powerText = Turbine.UI.Label();
        self.powerText:SetParent(self);
    end
    self.powerText:SetFont(font);
    self.powerText:SetForeColor(Turbine.UI.Color(1, 0.2, 0.6, 1.0));
    self.powerText:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleLeft);
    self.powerText:SetSize(labelWidth, labelHeight);
    self.powerText:SetPosition(rightBase + self.curveDepth + 10, (barAreaHeight / 2) - 15);
    self.powerText:SetZOrder(10);
    self.powerText:SetMouseVisible(false);

    -- Reposition instruction labels after rebuild
    if self.dragLabel then
        self.dragLabel:SetPosition((totalWidth / 2) - 150, (barAreaHeight / 2) - 55);
        self.dragLabel:SetZOrder(200);
    end
    if self.lockLabel then
        self.lockLabel:SetPosition((totalWidth / 2) - 150, (barAreaHeight / 2) - 25);
        self.lockLabel:SetZOrder(200);
    end

    -- Reposition alert label (at bottom of bar area, above buff row)
    if self.alertLabel then
        self.alertLabel:SetPosition((totalWidth / 2) - 200, barAreaHeight - 35);
    end
    if self.alertShadow then
        self.alertShadow:SetPosition((totalWidth / 2) - 200 + 2, barAreaHeight - 35 + 2);
    end

    if self.isUnlocked then
        self:SetMouseVisible(true);
    end

    -- Reposition stats hover zone
    if self.statsHoverZone then
        self.statsHoverZone:SetSize(totalWidth, barAreaHeight);
        self.statsHoverZone:SetPosition(0, 0);
    end

    -- Force a full update (reset cached state)
    self.lastHealthPct = -1;
    self.lastPowerPct = -1;
    self:UpdateHealth();
    self:UpdatePower();

    -- Refresh buff layout after bars are built
    self:RefreshBuffList();

    self.rebuilding = false;
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

-- =========================================================================
-- STATS TOOLTIP (hover over bar area to see character stats)
-- =========================================================================
function HealthBarWindow:CreateStatsTooltip()
    local win = self;

    -- Invisible hover zone that covers the bar area
    self.statsHoverZone = Turbine.UI.Control();
    self.statsHoverZone:SetParent(self);
    self.statsHoverZone:SetBackColor(Turbine.UI.Color(0, 0, 0, 0));
    self.statsHoverZone:SetMouseVisible(true);
    self.statsHoverZone:SetZOrder(5); -- below bar segments (they have mouse off), above nothing

    -- The tooltip window itself (top-level so it can overflow)
    self.statsWindow = Turbine.UI.Window();
    self.statsWindow:SetSize(240, 280);
    self.statsWindow:SetBackColor(Turbine.UI.Color(0.92, 0.05, 0.05, 0.12));
    self.statsWindow:SetVisible(false);
    self.statsWindow:SetZOrder(600);
    self.statsWindow:SetMouseVisible(false);
    self.statsWindow:SetOpacity(1);
    self.statsWindow:SetText("");

    -- Title
    self.statsTitle = Turbine.UI.Label();
    self.statsTitle:SetParent(self.statsWindow);
    self.statsTitle:SetSize(232, 24);
    self.statsTitle:SetPosition(4, 4);
    self.statsTitle:SetFont(Turbine.UI.Lotro.Font.Verdana16);
    self.statsTitle:SetForeColor(Turbine.UI.Color(1, 1.0, 0.85, 0.4));
    self.statsTitle:SetTextAlignment(Turbine.UI.ContentAlignment.TopCenter);
    self.statsTitle:SetMouseVisible(false);
    self.statsTitle:SetText("Character Stats");

    -- Stats body
    self.statsBody = Turbine.UI.Label();
    self.statsBody:SetParent(self.statsWindow);
    self.statsBody:SetSize(232, 248);
    self.statsBody:SetPosition(4, 28);
    self.statsBody:SetFont(Turbine.UI.Lotro.Font.Verdana14);
    self.statsBody:SetForeColor(Turbine.UI.Color(1, 0.9, 0.9, 0.9));
    self.statsBody:SetTextAlignment(Turbine.UI.ContentAlignment.TopLeft);
    self.statsBody:SetMouseVisible(false);

    -- Hover events on the zone
    self.statsHoverZone.MouseEnter = function(sender, args)
        if win.isUnlocked then return; end -- Don't show when dragging
        win:UpdateStatsTooltip();
        -- Position near the center of the window
        local wx, wy = win:GetPosition();
        local ww, wh = win:GetSize();
        win.statsWindow:SetPosition(wx + (ww / 2) - 120, wy - 290);
        win.statsWindow:SetVisible(true);
    end;
    self.statsHoverZone.MouseLeave = function(sender, args)
        win.statsWindow:SetVisible(false);
    end;
end

function HealthBarWindow:UpdateStatsTooltip()
    local p = self.player;
    local lines = {};

    -- Morale / Power
    local morale = p:GetMorale() or 0;
    local maxMorale = p:GetMaxMorale() or 1;
    local power = p:GetPower() or 0;
    local maxPower = p:GetMaxPower() or 1;
    table.insert(lines, string.format("Morale: %d / %d", morale, maxMorale));
    table.insert(lines, string.format("Power:  %d / %d", power, maxPower));
    table.insert(lines, "");

    -- Base Attributes via GetAttributes()
    local ok, attrs = pcall(function() return p:GetAttributes() end);
    if ok and attrs then
        local function getStat(fn)
            local s, v = pcall(fn);
            return (s and v) or "?";
        end

        if attrs.GetMight then
            table.insert(lines, "Might:    " .. tostring(getStat(function() return attrs:GetMight() end)));
        end
        if attrs.GetAgility then
            table.insert(lines, "Agility:  " .. tostring(getStat(function() return attrs:GetAgility() end)));
        end
        if attrs.GetVitality then
            table.insert(lines, "Vitality: " .. tostring(getStat(function() return attrs:GetVitality() end)));
        end
        if attrs.GetWill then
            table.insert(lines, "Will:     " .. tostring(getStat(function() return attrs:GetWill() end)));
        end
        if attrs.GetFate then
            table.insert(lines, "Fate:     " .. tostring(getStat(function() return attrs:GetFate() end)));
        end
        table.insert(lines, "");

        -- Ratings
        if attrs.GetCriticalRating then
            table.insert(lines, "Critical:   " .. tostring(getStat(function() return attrs:GetCriticalRating() end)));
        end
        if attrs.GetPhysicalMastery then
            table.insert(lines, "Phys Mast:  " .. tostring(getStat(function() return attrs:GetPhysicalMastery() end)));
        end
        if attrs.GetTacticalMastery then
            table.insert(lines, "Tact Mast:  " .. tostring(getStat(function() return attrs:GetTacticalMastery() end)));
        end
        if attrs.GetArmour then
            table.insert(lines, "Armour:     " .. tostring(getStat(function() return attrs:GetArmour() end)));
        end
        if attrs.GetResistance then
            table.insert(lines, "Resistance: " .. tostring(getStat(function() return attrs:GetResistance() end)));
        end
    else
        -- Fallback: try individual methods on player directly
        table.insert(lines, "Level: " .. tostring(p:GetLevel() or "?"));
    end

    self.statsBody:SetText(table.concat(lines, "\n"));
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
    self.segSlider = CreateSliderRow(self.settingsPanel, yOff, "Segments:", 30, 1000, self.numSegments, function(val)
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
        win.rebuildNeeded = false;
    end);

    -- Out-of-Combat Opacity slider (percent) — no rebuild needed
    self.oocOpSlider = CreateSliderRow(self.settingsPanel, yOff + rowH * 6, "Idle %:", 1, 100, self.oocOpacity, function(val)
        self.oocOpacity = val;
        self.targetOpacity = self.inCombat and (self.combatOpacity / 100) or (self.oocOpacity / 100);
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
    if not self.healthFillSegments then return; end

    local morale = self.player:GetMorale();
    local maxMorale = self.player:GetMaxMorale();

    if maxMorale == nil or maxMorale == 0 then maxMorale = 1; end
    if morale == nil then morale = 0; end

    local pct = morale / maxMorale;
    if pct > 1 then pct = 1; end
    if pct < 0 then pct = 0; end

    -- Skip if nothing changed (within 0.1% tolerance)
    local pctInt = math.floor(pct * 1000);
    if self.lastHealthPct == pctInt then return; end

    local oldStartIdx = 0;
    if self.lastHealthPct and self.lastHealthPct >= 0 then
        local oldPct = self.lastHealthPct / 1000;
        local oldVisible = math.floor(self.numSegments * oldPct);
        oldStartIdx = self.numSegments - oldVisible + 1;
    end
    self.lastHealthPct = pctInt;

    local r, g, b;
    local colorTier;
    if pct >= 0.75 then
        r = 0.1; g = 0.85; b = 0.1; colorTier = 3;
    elseif pct >= 0.5 then
        r = 1.0; g = 0.85; b = 0.1; colorTier = 2;
    else
        r = 0.9; g = 0.15; b = 0.1; colorTier = 1;
    end
    local color = Turbine.UI.Color(1, r, g, b);

    -- Detect if color tier changed — if so, recolor ALL visible segments
    local tierChanged = (self.lastHealthTier ~= nil and self.lastHealthTier ~= colorTier);
    self.lastHealthTier = colorTier;

    local visibleCount = math.floor(self.numSegments * pct);
    local startIdx = self.numSegments - visibleCount + 1;

    -- Full recolor if tier changed, otherwise delta-only
    local lo, hi;
    if tierChanged or oldStartIdx == 0 then
        lo = startIdx; hi = self.numSegments;
    else
        lo = math.min(startIdx, oldStartIdx);
        hi = math.max(startIdx, oldStartIdx);
    end

    for i = lo, hi do
        local seg = self.healthFillSegments[i];
        if seg then
            if i >= startIdx then
                seg:SetVisible(true);
                seg:SetBackColor(color);
            else
                seg:SetVisible(false);
            end
        end
    end

    local txt = tostring(math.floor(pct * 100)) .. "%";
    if self.healthText then self.healthText:SetText(txt); end
    if self.healthTextShadow then self.healthTextShadow:SetText(txt); end

    -- Low health alert
    if pct < 0.3 and not self.lowHealthAlerted then
        self.lowHealthAlerted = true;
        self:ShowAlert("LOW HEALTH!", Turbine.UI.Color(1, 1.0, 0.2, 0.2));
    elseif pct >= 0.3 then
        self.lowHealthAlerted = false;
    end
end

function HealthBarWindow:UpdatePower()
    if not self.powerFillSegments then return; end

    local power = self.player:GetPower();
    local maxPower = self.player:GetMaxPower();

    if maxPower == nil or maxPower == 0 then maxPower = 1; end
    if power == nil then power = 0; end

    local pct = power / maxPower;
    if pct > 1 then pct = 1; end
    if pct < 0 then pct = 0; end

    -- Skip if nothing changed (within 0.1% tolerance)
    local pctInt = math.floor(pct * 1000);
    if self.lastPowerPct == pctInt then return; end

    local oldStartIdx = 0;
    if self.lastPowerPct and self.lastPowerPct >= 0 then
        local oldPct = self.lastPowerPct / 1000;
        local oldVisible = math.floor(self.numSegments * oldPct);
        oldStartIdx = self.numSegments - oldVisible + 1;
    end
    self.lastPowerPct = pctInt;

    -- Turn yellow below 75%, red below 50%
    local r, g, b;
    local colorTier;
    if pct >= 0.75 then
        r = 0.2; g = 0.5; b = 0.9; colorTier = 3;
    elseif pct >= 0.5 then
        r = 1.0; g = 0.85; b = 0.1; colorTier = 2;
    else
        r = 0.9; g = 0.15; b = 0.1; colorTier = 1;
    end
    local color = Turbine.UI.Color(1, r, g, b);

    -- Detect if color tier changed — if so, recolor ALL visible segments
    local tierChanged = (self.lastPowerTier ~= nil and self.lastPowerTier ~= colorTier);
    self.lastPowerTier = colorTier;

    local visibleCount = math.floor(self.numSegments * pct);
    local startIdx = self.numSegments - visibleCount + 1;

    -- Full recolor if tier changed, otherwise delta-only
    local lo, hi;
    if tierChanged or oldStartIdx == 0 then
        lo = startIdx; hi = self.numSegments;
    else
        lo = math.min(startIdx, oldStartIdx);
        hi = math.max(startIdx, oldStartIdx);
    end

    for i = lo, hi do
        local seg = self.powerFillSegments[i];
        if seg then
            if i >= startIdx then
                seg:SetVisible(true);
                seg:SetBackColor(color);
            else
                seg:SetVisible(false);
            end
        end
    end

    local txt = tostring(math.floor(pct * 100)) .. "%";
    if self.powerText then self.powerText:SetText(txt); end
    if self.powerTextShadow then self.powerTextShadow:SetText(txt); end

    -- Low power alert
    if pct < 0.3 and not self.lowPowerAlerted then
        self.lowPowerAlerted = true;
        self:ShowAlert("LOW POWER!", Turbine.UI.Color(1, 0.3, 0.5, 1.0));
    elseif pct >= 0.3 then
        self.lowPowerAlerted = false;
    end
end

-- =========================================================================
-- ALERT SYSTEM
-- =========================================================================
function HealthBarWindow:CreateAlertLabel()
    local w, h = self:GetSize();

    -- Shadow
    self.alertShadow = Turbine.UI.Label();
    self.alertShadow:SetParent(self);
    self.alertShadow:SetSize(400, 30);
    self.alertShadow:SetPosition((w / 2) - 200 + 2, h - 35 + 2);
    self.alertShadow:SetFont(Turbine.UI.Lotro.Font.TrajanProBold24);
    self.alertShadow:SetForeColor(Turbine.UI.Color(1, 0, 0, 0));
    self.alertShadow:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter);
    self.alertShadow:SetZOrder(150);
    self.alertShadow:SetMouseVisible(false);
    self.alertShadow:SetVisible(false);

    -- Main text
    self.alertLabel = Turbine.UI.Label();
    self.alertLabel:SetParent(self);
    self.alertLabel:SetSize(400, 30);
    self.alertLabel:SetPosition((w / 2) - 200, h - 35);
    self.alertLabel:SetFont(Turbine.UI.Lotro.Font.TrajanProBold24);
    self.alertLabel:SetForeColor(Turbine.UI.Color(1, 1, 0.2, 0.2));
    self.alertLabel:SetTextAlignment(Turbine.UI.ContentAlignment.MiddleCenter);
    self.alertLabel:SetZOrder(151);
    self.alertLabel:SetMouseVisible(false);
    self.alertLabel:SetVisible(false);
end

function HealthBarWindow:ShowAlert(text, color)
    -- Add to queue; alerts display one at a time
    table.insert(self.alertQueue, { text = text, color = color });
end

function HealthBarWindow:ProcessAlerts()
    -- If currently showing, count down the timer
    if self.alertShowing then
        self.alertTimer = self.alertTimer - 1;
        -- Fade out in last 15 ticks
        if self.alertTimer <= 15 and self.alertTimer > 0 then
            local alpha = self.alertTimer / 15;
            if self.alertLabel then self.alertLabel:SetOpacity(alpha); end
            if self.alertShadow then self.alertShadow:SetOpacity(alpha); end
        elseif self.alertTimer <= 0 then
            self.alertShowing = false;
            if self.alertLabel then self.alertLabel:SetVisible(false); end
            if self.alertShadow then self.alertShadow:SetVisible(false); end
        end
        return;
    end

    -- If queue has items, show the next one
    if #self.alertQueue > 0 then
        local alert = table.remove(self.alertQueue, 1);
        self.alertShowing = true;
        self.alertTimer = 60; -- ~2 seconds at 30fps

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
end

function HealthBarWindow:OnEffectAdded(args)
    -- args is the Effect object in the Turbine API
    local effect = args;
    if effect then
        local name = "";
        if effect.GetName then
            name = effect:GetName();
        end
        if name and name ~= "" then
            -- Check for common debuff/bleed keywords
            local nameLower = string.lower(name);
            local isDebuff = false;
            local debuffKeywords = { "bleed", "wound", "poison", "disease", "fear", "dread",
                "stun", "daze", "root", "slow", "debuff", "curse", "fire", "acid",
                "shadow", "corruption", "dot", "drain" };
            for _, kw in ipairs(debuffKeywords) do
                if string.find(nameLower, kw) then
                    isDebuff = true;
                    break;
                end
            end

            -- Also check if the effect is harmful via category if available
            if not isDebuff and effect.IsDebuff then
                isDebuff = effect:IsDebuff();
            end

            if isDebuff then
                self:ShowAlert(name, Turbine.UI.Color(1, 1.0, 0.5, 0.1));
            end
        end
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
        self.numSegments = settings.numSegments or self.numSegments;
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
    -- Configuration for Buff Layout
    local BUFF_SIZE = 36;
    local SPACING = 4;
    local ROW_HEIGHT = BUFF_SIZE + 18; -- icon + timer text below
    
    if not self.buffRows then self.buffRows = {}; end
    if not self.buffPanel then return; end

    -- Hide all existing buff items
    for _, item in ipairs(self.buffRows) do
        item:SetVisible(false);
    end
    self.activeBuffs = {};
    
    local effects = self.player:GetEffects();
    if not effects then return; end
    
    local count = effects:GetCount();
    
    -- First pass: Collect valid buffs (non-harmful, duration <= 12 hours)
    local MAX_DURATION = 43200; -- 12 hours in seconds
    local validEffects = {};
    for i = 1, count do
        local effect = effects:Get(i);
        if not self:IsEffectHarmful(effect) then
            -- Filter: only show short-duration buffs (12h or less)
            local dominated = false;
            local ok, dur = pcall(function() return effect:GetDuration() end);
            if ok and dur then
                -- dur <= 0 means permanent/toggle, dur > MAX_DURATION means very long buff
                if dur <= 0 or dur > MAX_DURATION then
                    dominated = true;
                end
            end
            if not dominated then
                table.insert(validEffects, effect);
            end
        end
    end

    local numBuffs = #validEffects;
    
    -- If count changed, trigger a rebuild so the window resizes
    if self.lastBuffCount ~= numBuffs then
        self.lastBuffCount = numBuffs;
        -- Only flag rebuild if we're not already inside one
        if not self.rebuilding then
            self.rebuildNeeded = true;
        end
    end

    -- Calculate how many icons fit per row
    local panelW = self.buffPanel:GetWidth();
    local iconsPerRow = math.floor((panelW + SPACING) / (BUFF_SIZE + SPACING));
    if iconsPerRow < 1 then iconsPerRow = 1; end

    for i, effect in ipairs(validEffects) do
        local item = self.buffRows[i];
        if not item then
            item = self:CreateBuffIconItem();
            table.insert(self.buffRows, item);
        end
        
        -- Update Content
        local success, err = pcall(function() item:SetEffect(effect); end);
        if not success then
             item.icon:SetVisible(false);
        end

        -- Calculate row and column
        local col = (i - 1) % iconsPerRow;
        local row = math.floor((i - 1) / iconsPerRow);

        -- Center each row: figure out how many icons are in this row
        local rowStart = row * iconsPerRow + 1;
        local rowEnd = math.min(rowStart + iconsPerRow - 1, numBuffs);
        local iconsInRow = rowEnd - rowStart + 1;
        local rowWidth = iconsInRow * BUFF_SIZE + (iconsInRow - 1) * SPACING;
        local rowOffsetX = (panelW - rowWidth) / 2;
        if rowOffsetX < 0 then rowOffsetX = 0; end

        local xPos = rowOffsetX + col * (BUFF_SIZE + SPACING);
        local yPos = row * (ROW_HEIGHT + SPACING);
        item:SetPosition(xPos, yPos);
        item:SetVisible(true);
        
        table.insert(self.activeBuffs, item);
    end
end

function HealthBarWindow:CreateBuffIconItem()
    local size = 36;
    local item = Turbine.UI.Control();
    item:SetParent(self.buffPanel);
    item:SetSize(size, size + 16); -- Extra height for timer text below/overlay
    item:SetMouseVisible(true); -- Enable mouse for tooltip
    
    -- Tooltip window (shown on hover) — large enough for full effect descriptions
    local TT_WIDTH = 300;
    item.tooltip = Turbine.UI.Window();
    item.tooltip:SetSize(TT_WIDTH, 200);
    item.tooltip:SetBackColor(Turbine.UI.Color(0.92, 0.05, 0.05, 0.12));
    item.tooltip:SetVisible(false);
    item.tooltip:SetZOrder(500);
    item.tooltip:SetMouseVisible(false);
    item.tooltip:SetOpacity(1);
    
    -- Name line (gold, bold)
    item.tooltipName = Turbine.UI.Label();
    item.tooltipName:SetParent(item.tooltip);
    item.tooltipName:SetSize(TT_WIDTH - 8, 22);
    item.tooltipName:SetPosition(4, 4);
    item.tooltipName:SetFont(Turbine.UI.Lotro.Font.Verdana16);
    item.tooltipName:SetForeColor(Turbine.UI.Color(1, 1.0, 0.85, 0.4));
    item.tooltipName:SetTextAlignment(Turbine.UI.ContentAlignment.TopLeft);
    item.tooltipName:SetMouseVisible(false);
    
    -- Description / stats area (large, multi-line)
    item.tooltipDesc = Turbine.UI.Label();
    item.tooltipDesc:SetParent(item.tooltip);
    item.tooltipDesc:SetSize(TT_WIDTH - 8, 170);
    item.tooltipDesc:SetPosition(4, 28);
    item.tooltipDesc:SetFont(Turbine.UI.Lotro.Font.Verdana14);
    item.tooltipDesc:SetForeColor(Turbine.UI.Color(1, 0.9, 0.9, 0.9));
    item.tooltipDesc:SetTextAlignment(Turbine.UI.ContentAlignment.TopLeft);
    item.tooltipDesc:SetMouseVisible(false);
    
    -- Hover events
    item.MouseEnter = function(sender, args)
        if sender.effectName and sender.effectName ~= "" then
            sender.tooltipName:SetText(sender.effectName);
            
            -- Build full tooltip body with description + extra info
            local body = "";
            if sender.effectDesc and sender.effectDesc ~= "" then
                body = sender.effectDesc;
            end
            
            -- Append duration info
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
            
            -- Estimate tooltip height based on content
            local lines = 2; -- name + padding
            for _ in string.gmatch(body, "\n") do lines = lines + 1; end
            -- Rough estimate: ~16px per line of description
            local descLines = math.max(lines, math.ceil(string.len(body) / 38));
            local ttHeight = 32 + descLines * 16;
            if ttHeight < 60 then ttHeight = 60; end
            if ttHeight > 300 then ttHeight = 300; end
            sender.tooltip:SetSize(TT_WIDTH, ttHeight);
            sender.tooltipDesc:SetSize(TT_WIDTH - 8, ttHeight - 32);
            
            -- Position tooltip above the icon
            local ix, iy = sender:GetPosition();
            local px, py = self.buffPanel:GetPosition();
            local wx, wy = self:GetPosition();
            sender.tooltip:SetPosition(wx + px + ix - (TT_WIDTH/2) + (size/2), wy + py + iy - ttHeight - 4);
            sender.tooltip:SetVisible(true);
        end
    end;
    item.MouseLeave = function(sender, args)
        sender.tooltip:SetVisible(false);
    end;
    
    -- Icon
    item.icon = Turbine.UI.Control();
    item.icon:SetParent(item);
    item.icon:SetSize(size, size);
    item.icon:SetPosition(0, 0);
    item.icon:SetBlendMode(Turbine.UI.BlendMode.AlphaBlend);
    item.icon:SetMouseVisible(false);
    
    -- Timer Overlay
    item.timerLabel = Turbine.UI.Label();
    item.timerLabel:SetParent(item);
    item.timerLabel:SetSize(size + 10, 16);
    item.timerLabel:SetPosition(-5, size - 4); -- Just below/overlapping bottom
    item.timerLabel:SetFont(Turbine.UI.Lotro.Font.Verdana12);
    item.timerLabel:SetForeColor(Turbine.UI.Color(1, 1.0, 1.0, 1.0));
    item.timerLabel:SetTextAlignment(Turbine.UI.ContentAlignment.TopCenter);
    item.timerLabel:SetOutlineColor(Turbine.UI.Color(1, 0, 0, 0)); -- Shadow effect
    item.timerLabel:SetFontStyle(Turbine.UI.FontStyle.Outline);
    item.timerLabel:SetMouseVisible(false);
    
    -- Method to set data — extract all available effect info
    item.SetEffect = function(sender, effect)
        sender.effect = effect;
        
        -- Store name
        local nameOk, eName = pcall(function() return effect:GetName() end);
        sender.effectName = (nameOk and eName) or "";
        
        -- Store description (this is where stat info lives in the Turbine API)
        local descOk, eDesc = pcall(function() return effect:GetDescription() end);
        sender.effectDesc = (descOk and eDesc) or "";
        
        -- Store duration for tooltip
        local durOk, eDur = pcall(function() return effect:GetDuration() end);
        sender.effectDuration = (durOk and eDur) or 0;
        
        -- Try to get icon
        local status, iconID = pcall(function() return effect:GetIcon() end);
        if status and iconID and type(iconID) == "number" then
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
            
            -- If duration is 0 or very large, it's permanent/toggle
            if duration > 86400 or duration <= 0 then
                row.timerLabel:SetText("");
            else
                local remaining = duration - (currentTime - startTime);
                if remaining < 0 then remaining = 0; end
                
                -- Format time
                local mins = math.floor(remaining / 60);
                local secs = math.floor(remaining % 60);
                if mins > 60 then
                     row.timerLabel:SetText(string.format("%dh", math.floor(mins/60)));
                elseif mins > 0 then
                     row.timerLabel:SetText(string.format("%d:%02d", mins, secs));
                else
                     row.timerLabel:SetText(string.format("%ds", secs));
                end
            end
        end
    end
end

function HealthBarWindow:IsEffectHarmful(effect)
    if not effect then return false; end
    
    -- Check API flag first
    if effect.IsDebuff and effect:IsDebuff() then return true; end
    
    -- Check keywords in name
    local name = effect:GetName();
    if not name then return false; end
    
    local nameLower = string.lower(name);
    local debuffKeywords = { "bleed", "wound", "poison", "disease", "fear", "dread",
        "stun", "daze", "root", "slow", "debuff", "curse", "fire", "acid",
        "shadow", "corruption", "dot", "drain" };
        
    for _, kw in ipairs(debuffKeywords) do
        if string.find(nameLower, kw) then
            return true;
        end
    end
    return false;
end
