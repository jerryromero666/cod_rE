// Stock _zm_ffotd is an empty stub that _zm.gsc already #uses, so overriding
// it is the lightest way to get bo7_movement linked and its REGISTER_SYSTEM run
// in ZM without replacing _zm.gsc.

#using scripts\zm\bo7_movement;

#namespace zm_ffotd;

function main_start() {}

function main_end() {}

function optimize_for_splitscreen() {}
