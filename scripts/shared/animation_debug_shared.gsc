// Second campaign server hook (only one of the two is needed; both are kept
// because the campaign's own scripts are not in the mod tools to confirm which
// one it loads). The stock file is an empty stub (its debug code is stripped)
// that animation_shared.gsc #uses in every mode. This copy is that stub plus a
// #using of scripts/cp/bo7_movement_cp.gsc, which returns at once outside the
// campaign.

#using scripts\shared\animation_shared;
#using scripts\shared\flagsys_shared;
#using scripts\shared\util_shared;
#using scripts\cp\bo7_movement_cp;

#insert scripts\shared\shared.gsh;

#namespace animation;

#define ANIM_DEBUG_TEXT_SCALE .3
#define ANIM_DEBUG_TEXT_SMALL .15
#define ANIM_DEBUG_TEXT_ALPHA .8
