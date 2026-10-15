-- Loads omnimovement.dll (sprint in any direction) and reports each step
-- through dvars (bo7_luaalive, bo7_omnidll). The DLL is taken from the mod
-- folder or, for Workshop subscribers, from the Workshop download folder.
-- Kept flat - no nested functions or long strings - for the mod tools' Lua
-- compiler.

Engine.SetDvar( "bo7_luaalive", "1" )

local dll_name = "omnimovement.dll"
local mod_path = "mods\\bo7_movement\\zone\\"
local workshop_path = "..\\..\\workshop\\content\\311210\\3808733329\\"

Engine.SetDvar( "bo7_omnidll", "reached_loadlib" )

local init_func = require( "package" ).loadlib( mod_path .. dll_name, "init" )

if not init_func then
    init_func = require( "package" ).loadlib( workshop_path .. dll_name, "init" )
end

if not init_func then
    init_func = require( "package" ).loadlib( workshop_path .. "zone\\" .. dll_name, "init" )
end

if not init_func then
    Engine.SetDvar( "bo7_omnidll", "FAIL_loadlib" )
    return
end

Engine.SetDvar( "bo7_omnidll", "got_init_calling" )

local r = init_func()

Engine.SetDvar( "bo7_omnidll", "OK_init_returned_" .. tostring( r ) )
