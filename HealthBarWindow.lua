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
    -- DEBUFF / EFFECT WATCHER
    -- =====================
    local effects = self.player:GetEffects();
    if effects then
        effects.EffectAdded = function(sender, args)
            self:OnEffectAdded(args);
        end;
        effects.EffectRemoved = function(sender, args)
            -- Could alert "X removed" but keeping it to additions only
        end;
    end;

    -- Initial update
    self:UpdateHealth();
    self:UpdatePower();

    -- Periodic timer for missed events AND live preview rebuilds
    self.updateTimer = Turbine.UI.Control();
    self.updateTimer:SetWantsUpdates(true);
    self.updateTimer.accumulator = 0;
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
    local totalHeight = self.barHeightTotal + 60;

    self:SetSize(totalWidth, totalHeight);
    self:SetBackColor(Turbine.UI.Color(0, 0, 0, 0));
    self:SetText("");

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
    self.healthTextShadow:SetPosition(leftBase - labelWidth - self.curveDepth - 10 + 2, (totalHeight / 2) - 15 + 2);
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
    self.healthText:SetPosition(leftBase - labelWidth - self.curveDepth - 10, (totalHeight / 2) - 15);
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
    self.powerTextShadow:SetPosition(rightBase + self.curveDepth + 10 + 2, (totalHeight / 2) - 15 + 2);
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
    self.powerText:SetPosition(rightBase + self.curveDepth + 10, (totalHeight / 2) - 15);
    self.powerText:SetZOrder(10);
    self.powerText:SetMouseVisible(false);

    -- Reposition instruction labels after rebuild
    if self.dragLabel then
        self.dragLabel:SetPosition((totalWidth / 2) - 150, (totalHeight / 2) - 55);
        self.dragLabel:SetZOrder(200);
    end
    if self.lockLabel then
        self.lockLabel:SetPosition((totalWidth / 2) - 150, (totalHeight / 2) - 25);
        self.lockLabel:SetZOrder(200);
    end

    -- Reposition alert label
    if self.alertLabel then
        self.alertLabel:SetPosition((totalWidth / 2) - 200, totalHeight - 35);
    end
    if self.alertShadow then
        self.alertShadow:SetPosition((totalWidth / 2) - 200 + 2, totalHeight - 35 + 2);
    end

    if self.isUnlocked then
        self:SetMouseVisible(true);
    end

    -- Force a full update (reset cached state)
    self.lastHealthPct = -1;
    self.lastPowerPct = -1;
    self:UpdateHealth();
    self:UpdatePower();

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
