// Client-side loader for the native movement DLLs and receiver for the
// server's clientfields. This overrides a stock stub that _load.csc already
// includes, so it runs on every map. LuiLoad does nothing before LUI is up,
// so the loads are repeated after short delays; a repeated load is harmless.
// omnimovement.dll changes sprint prediction, which only matches a server
// whose sprint code is patched too (a listen server, or a dedicated server
// running the movement plugin). The server sets the bo7_omniok clientfield
// when that is the case; the DLL is loaded only then, so a client never
// rubber-bands against an unpatched server. bo7slice.dll is client-only and
// always loaded.
// scripts\codescripts\struct is required by REGISTER_SYSTEM.

#using scripts\codescripts\struct;

#using scripts\shared\clientfield_shared;
#using scripts\shared\system_shared;

#insert scripts\shared\shared.gsh;
#insert scripts\shared\version.gsh;

#namespace radiant_live_udpate;

REGISTER_SYSTEM( "bo7_omni_loader", &__bo7_omni_init__, undefined )

function __bo7_omni_init__()
{
    clientfield::register( "world", "bo7_omniok", VERSION_SHIP, 1, "int", &bo7_omniok_cb, !CF_HOST_ONLY, CF_CALLBACK_ZERO_ON_NEW_ENT );
    clientfield::register( "toplayer", "bo7_lean", VERSION_SHIP, 9, "int", &bo7_lean_cb, !CF_HOST_ONLY, CF_CALLBACK_ZERO_ON_NEW_ENT );
    clientfield::register( "toplayer", "bo7_wjsync", VERSION_SHIP, 2, "int", &bo7_wjsync_cb, !CF_HOST_ONLY, CF_CALLBACK_ZERO_ON_NEW_ENT );
    level thread bo7_deferred_load();
}

function bo7_omniok_cb( localClientNum, oldVal, newVal, bNewEnt, bInitialSnap, fieldName, bWasTimeJump )
{
    level.bo7_omniok = newVal;
}

// Corner-slice cant from the server, in quarter degrees offset by 256
// (0 = none), written to the dvar bo7slice.dll reads.
function bo7_lean_cb( localClientNum, oldVal, newVal, bNewEnt, bInitialSnap, fieldName, bWasTimeJump )
{
    lean = 0;
    if ( newVal > 0 )
        lean = ( newVal - 256 ) * 0.25;
    SetDvar( "bo7_lean", lean );
}

// The server asks for this player's wall-jump choice again at each spawn
// (a new non-zero value). Writing bo7_mywallmode back with its own value
// makes bo7slice.dll send the mode and space pair to the server.
function bo7_wjsync_cb( localClientNum, oldVal, newVal, bNewEnt, bInitialSnap, fieldName, bWasTimeJump )
{
    if ( newVal == 0 )
        return;
    v = GetDvarString( "bo7_mywallmode" );
    if ( v != "" )
        SetDvar( "bo7_mywallmode", v );
}

function bo7_deferred_load()
{
    wait 2;
    LuiLoad( "ui.bo7_slice_loader" );
    level thread bo7_wj_watch();

    // Wait for the server to say the sprint code is patched. On a listen
    // server it is set almost at once; on a dedicated server it depends on
    // the plugin. If it never turns on (dedicated, no plugin) the wait times
    // out and omni is skipped.
    for ( i = 0; i < 26 && ( !IsDefined( level.bo7_omniok ) || level.bo7_omniok == 0 ); i++ )
        wait 0.5;

    bo7_load_omni();

    wait 4;
    bo7_load_omni();
    LuiLoad( "ui.bo7_slice_loader" );

    wait 6;
    bo7_load_omni();
    LuiLoad( "ui.bo7_slice_loader" );
}

// F4 is bound to "set bo7_wjtog 1" (the "set" command works in this build;
// "toggle" and "vstr" are both no-ops here). This watches that flag and flips
// bo7_mywallspace (0 auto <-> 1 press-jump), clearing the flag. The SetDvar
// goes through the bo7slice.dll hook - the same path bo7_lean uses - so the
// flip is relayed to the server. F1/F2/F3/F5 relay directly through that hook
// (they use "set" too), so they are not mirrored here.
function bo7_wj_watch()
{
    while ( true )
    {
        wait 0.1;
        if ( GetDvarString( "bo7_wjtog" ) == "1" )
        {
            SetDvar( "bo7_wjtog", "0" );
            if ( GetDvarString( "bo7_mywallspace" ) == "1" )
                SetDvar( "bo7_mywallspace", "0" );
            else
                SetDvar( "bo7_mywallspace", "1" );
        }
    }
}

function bo7_load_omni()
{
    if ( !IsDefined( level.bo7_omniok ) || level.bo7_omniok == 0 )
    {
        SetDvar( "bo7_omnidll", "skipped_server_not_patched" );
        return;
    }
    LuiLoad( "ui.bo7_omni_loader" );
}
