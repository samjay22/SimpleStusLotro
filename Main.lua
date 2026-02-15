-- EasyHealthBar - Main.lua
-- Entry point for the plugin

import "Turbine";
import "Turbine.Gameplay";
import "Turbine.UI";
import "Turbine.UI.Lotro";
import "EasyHealthBar.HealthBarWindow";

-- Create the main window
healthBarWin = HealthBarWindow();

-- Register a slash command
local cmd = Turbine.ShellCommand();

function cmd:Execute(command, args)
    if args == "toggle" or args == "" then
        healthBarWin:SetVisible(not healthBarWin:IsVisible());
    elseif args == "show" then
        healthBarWin:SetVisible(true);
    elseif args == "hide" then
        healthBarWin:SetVisible(false);
    elseif args == "unlock" then
        healthBarWin:SetUnlocked(true);
        Turbine.Shell.WriteLine("<rgb=#FFFF00>EasyHealthBar unlocked. Drag to move, adjust settings, then press Ctrl+\\ or type /ehb lock.</rgb>");
    elseif args == "lock" then
        healthBarWin:SetUnlocked(false);
        Turbine.Shell.WriteLine("<rgb=#00FF00>EasyHealthBar locked.</rgb>");
    elseif args == "reset" then
        local screenWidth = Turbine.UI.Display:GetWidth();
        local screenHeight = Turbine.UI.Display:GetHeight();
        local w, h = healthBarWin:GetSize();
        healthBarWin:SetPosition(
            math.floor((screenWidth - w) / 2),
            math.floor((screenHeight - h) / 2)
        );
        healthBarWin:SavePosition();
        Turbine.Shell.WriteLine("<rgb=#00FF00>EasyHealthBar reset to center.</rgb>");
    elseif args == "help" then
        Turbine.Shell.WriteLine("<rgb=#00FF00>EasyHealthBar Commands:</rgb>");
        Turbine.Shell.WriteLine("  /ehb            - Toggle visibility");
        Turbine.Shell.WriteLine("  /ehb show       - Show the bars");
        Turbine.Shell.WriteLine("  /ehb hide       - Hide the bars");
        Turbine.Shell.WriteLine("  /ehb unlock     - Unlock for moving/settings");
        Turbine.Shell.WriteLine("  /ehb lock       - Lock in place");
        Turbine.Shell.WriteLine("  /ehb reset      - Reset position to center");
        Turbine.Shell.WriteLine("  /ehb help       - Show this help");
        Turbine.Shell.WriteLine("<rgb=#AAAAAA>You can also press Ctrl+\\ (Reposition UI) to toggle unlock mode!</rgb>");
    else
        Turbine.Shell.WriteLine("<rgb=#FF6666>Unknown command. Type /ehb help</rgb>");
    end
end

Turbine.Shell.AddCommand("ehb", cmd);

-- Auto-save on plugin unload (logout, /plugins unload, etc.)
plugin.Unloading = function(sender, args)
    if healthBarWin then
        healthBarWin:SaveSettings();
        healthBarWin:SavePosition();
    end
end;

Turbine.Shell.WriteLine("<rgb=#00FF00>EasyHealthBar loaded! Press Ctrl+\\ to move/configure. Type /ehb help for commands.</rgb>");
