-- Loads bo7slice.dll (weapon cant, own-body hiding, correction smoothing)
-- and reports each step through bo7_slicedll. The DLL is taken from the mod
-- folder or, for Workshop subscribers, from the Workshop download folder.
-- Kept flat - no nested functions or long strings - for the mod tools' Lua
-- compiler.

local dll_name = "bo7slice.dll"
local mod_path = "mods\\bo7_movement\\zone\\"
local workshop_path = "..\\..\\workshop\\content\\311210\\3808733329\\"

Engine.SetDvar( "bo7_slicedll", "reached" )

local slice_func = require( "package" ).loadlib( mod_path .. dll_name, "init" )

if not slice_func then
    slice_func = require( "package" ).loadlib( workshop_path .. dll_name, "init" )
end

if not slice_func then
    slice_func = require( "package" ).loadlib( workshop_path .. "zone\\" .. dll_name, "init" )
end

if not slice_func then
    Engine.SetDvar( "bo7_slicedll", "FAIL_loadlib" )
    return
end

Engine.SetDvar( "bo7_slicedll", "calling" )

local sr = slice_func()

Engine.SetDvar( "bo7_slicedll", "OK_returned_" .. tostring( sr ) )
