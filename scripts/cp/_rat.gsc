// Campaign server hook. The stock scripts/mp/_rat.gsc and scripts/zm/_rat.gsc
// are empty stubs that _globallogic #uses, and the campaign has the same stub.
// This copy adds a #using of scripts/cp/bo7_movement_cp.gsc so it is linked and
// its REGISTER_SYSTEM runs.

#using scripts\shared\system_shared;
#using scripts\shared\util_shared;
#using scripts\shared\rat_shared;
#using scripts\shared\array_shared;
#using scripts\cp\bo7_movement_cp;

#insert scripts\shared\shared.gsh;

#namespace rat;
