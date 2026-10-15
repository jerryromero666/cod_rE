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

#namespace radiant_live_update;

REGISTER_SYSTEM( "bo7_omni_loader", &__bo7_omni_init__, undefined )

function __bo7_omni_init__()
{
    clientfield::register( "world", "bo7_omniok", VERSION_SHIP, 1, "int", &bo7_omniok_cb, !CF_HOST_ONLY, CF_CALLBACK_ZERO_ON_NEW_ENT );
    clientfield::register( "toplayer", "bo7_lean", VERSION_SHIP, 9, "int", &bo7_lean_cb, !CF_HOST_ONLY, CF_CALLBACK_ZERO_ON_NEW_ENT );
    clientfield::register( "toplayer", "bo7_wjstate", VERSION_SHIP, 4, "int", &bo7_wjstate_cb, !CF_HOST_ONLY, CF_CALLBACK_ZERO_ON_NEW_ENT );
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

// The wall-jump setting the server is using for this player: 1 + mode * 2 +
// (1 if press jump is required). 0 only means no value yet (a new player
// entity), so it does not replace one already received. bo7_wj_watch compares
// it with the player's own choice.
function bo7_wjstate_cb( localClientNum, oldVal, newVal, bNewEnt, bInitialSnap, fieldName, bWasTimeJump )
{
    if ( newVal != 0 )
        level.bo7_wjstate = newVal;
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

// Wall-jump keys and sync, every 0.1 s.
//
// F4 is bound to "set bo7_wjtog 1" (the "set" command works in this build;
// "toggle" and "vstr" are both no-ops here). This watches that flag and flips
// bo7_mywallspace (0 auto <-> 1 press-jump), clearing the flag. The SetDvar
// goes through the bo7slice.dll hook - the same path bo7_lean uses - so the
// flip is relayed to the server. F1/F2/F3/F5 and the console relay directly
// through that hook (they use "set" too).
//
// A relayed choice is one message with no reply, so on its own it can be
// lost: sent before the server was listening (loading in, a map change) or
// never arriving. The server reports the setting it is really using in the
// bo7_wjstate clientfield; while that differs from the player's choice, both
// dvars are written again (as whole numbers, so the DLL and this script read
// them the same way), which makes the DLL send the pair again. The first
// resend waits 1 s, time for the normal send to be confirmed, then one a
// second for five tries, then one every 5 s until the server agrees.
// bo7_wjstatus (type it in the console) says whether the keys are working.
function bo7_wj_watch()
{
    lastwant = -1;
    ticks    = 0;
    tries    = 0;
    status   = "";

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

        want = bo7_wj_wanted();
        have = 0;
        if ( IsDefined( level.bo7_wjstate ) )
            have = level.bo7_wjstate;

        if ( want != lastwant )
        {
            lastwant = want;
            ticks = 0;
            tries = 0;
        }

        s = bo7_wj_status( want, have, tries );
        if ( s != status )
        {
            status = s;
            SetDvar( "bo7_wjstatus", s );
        }

        if ( want == 0 || want == have )
        {
            ticks = 0;
            tries = 0;
            continue;
        }

        ticks++;
        gap = 10;
        if ( tries >= 5 )
            gap = 50;
        if ( ticks < gap )
            continue;

        ticks = 0;
        tries++;
        m = Int( ( want - 1 ) / 2 );
        SetDvar( "bo7_mywallmode", "" + m );
        SetDvar( "bo7_mywallspace", "" + ( want - 1 - m * 2 ) );
    }
}

// The player's own wall-jump choice in the bo7_wjstate form, or 0 if they have
// never made one (the server default applies). A dvar that is still empty
// counts as the DLL's starting value: mode 1, space 0.
function bo7_wj_wanted()
{
    ms = GetDvarString( "bo7_mywallmode" );
    ss = GetDvarString( "bo7_mywallspace" );
    if ( ms == "" && ss == "" )
        return 0;

    m = 1;
    if ( ms != "" )
        m = GetDvarInt( "bo7_mywallmode" );
    if ( m < 0 )
        m = 0;
    if ( m > 3 )
        m = 3;

    s = 0;
    if ( ss != "" && GetDvarInt( "bo7_mywallspace" ) != 0 )
        s = 1;

    return 1 + m * 2 + s;
}

function bo7_wj_desc( v )
{
    m = Int( ( v - 1 ) / 2 );
    t = "full (side + front)";
    if ( m == 0 )
        t = "off";
    else if ( m == 2 )
        t = "side only";
    else if ( m == 3 )
        t = "front only";

    if ( m != 0 )
    {
        if ( v - 1 - m * 2 != 0 )
            t = t + ", press jump at the wall";
        else
            t = t + ", auto";
    }
    return t;
}

// Text for bo7_wjstatus. Only the server's report counts as working; the
// bo7_slicedll load report is named as the likely cause once a few resends
// have gone unanswered (on BOIII the plugin and the Lua loader both write it,
// so it is not trusted on its own).
function bo7_wj_status( want, have, tries )
{
    if ( want == 0 )
    {
        if ( have == 0 )
            return "default - no choice made, waiting for the server";
        return "default - no choice made, server uses " + bo7_wj_desc( have );
    }
    if ( want == have )
        return "OK - " + bo7_wj_desc( want );

    s = "waiting for the server to apply " + bo7_wj_desc( want ) + " (sent again " + tries + " times)";
    if ( have == 0 )
        s = "waiting for the server to report its setting (sent again " + tries + " times)";
    if ( tries >= 3 && !IsSubStr( GetDvarString( "bo7_slicedll" ), "OK_" ) )
        s = s + " - bo7slice.dll does not look loaded (bo7_slicedll " + GetDvarString( "bo7_slicedll" ) + "); without it F1-F5 and the console settings cannot reach the server";
    return s;
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
