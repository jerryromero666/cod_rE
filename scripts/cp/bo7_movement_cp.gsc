#using scripts\codescripts\struct;
#using scripts\shared\callbacks_shared;
#using scripts\shared\clientfield_shared;
#using scripts\shared\system_shared;
#using scripts\shared\util_shared;

#insert scripts\shared\shared.gsh;
#insert scripts\shared\version.gsh;

// bo7_movement_cp.gsc
//
// BO7-style movement for the Black Ops III campaign: side and frontal wall
// jumps, ledge catch, corner-slice support and prone turning, plus the exo
// suit abilities switched on. A port of the MP / ZM script with its own file,
// namespace and system name, because it is linked into every mode (see
// scripts/shared/animation_debug_shared.gsc) and must not clash with
// scripts/mp/bo7_movement.gsc or scripts/zm/bo7_movement.gsc. It does nothing
// outside the campaign, and nothing in Dead Ops Arcade (cp_doa_bo3).
//
// Camera-side work (weapon cant, own-body hiding, correction smoothing) is done
// by bo7slice.dll, which reads its settings from bo7_slice_cfg.txt.
//
// Engine behaviour this file relies on:
//   - One server frame is wait 0.05; waittillframeend does not advance time.
//   - BulletTrace uses bullet collision. Fences, grates and clip brushes are
//     solid to players but not to bullets, so wall probes sweep a player-sized
//     box with PhysicsTrace (mask 32 = player collision).
//   - IsOnGround() is true during an engine wall run: the wall is the ground.
//   - SetOrigin zeroes velocity, so momentum is read before any teleport.
//   - SetDvar creates a dvar that does not exist yet.

#namespace bo7_movement_cp;

REGISTER_SYSTEM( "bo7_movement_cp", &bo7_init, undefined )

// Clientfields shared with the client script (scripts/cp/_radiant_live_update
// .csc): bo7_omniok tells clients the server's sprint code is patched, so they
// load omnimovement.dll; bo7_lean carries each player's corner-slice cant to
// that player's client; bo7_wjstate tells a player's client which wall-jump
// setting the server is using for them (see monitor_wallcfg). The client
// registers the same three fields in every campaign map, Dead Ops Arcade
// included, so they are registered here before the Dead Ops Arcade check.
function bo7_init()
{
    if ( !SessionModeIsCampaignGame() )
        return;

    clientfield::register( "world", "bo7_omniok", VERSION_SHIP, 1, "int" );
    clientfield::register( "toplayer", "bo7_lean", VERSION_SHIP, 9, "int" );
    clientfield::register( "toplayer", "bo7_wjstate", VERSION_SHIP, 4, "int" );

    // Dead Ops Arcade is a top-down game with its own movement (no jumping);
    // the mod stays out of it.
    if ( bo7_is_doa() )
        return;

    bo7_default( "bo7_cp_enabled", 1 );
    bo7_default( "bo7_cp_exo",     1 );
    bo7_default( "bo7_cp_hud",     0 );
    bo7_default( "bo7_cp_bntext",  "| RIP BO7 CARRY FORWARD | GONE 2 SOON | FUCK SBMM |" );

    level thread bo7_flag_omni();
    callback::on_spawned( &bo7_cp_on_spawned );
}

// True in Dead Ops Arcade (cp_doa_bo3), which runs in the campaign mode.
function bo7_is_doa()
{
    return ( GetDvarString( "mapname" ) == "cp_doa_bo3" );
}

// Every player spawn. bo7_cp_enabled 0 turns the mod off for the mission.
function bo7_cp_on_spawned()
{
    if ( GetDvarInt( "bo7_cp_enabled", 1 ) == 0 )
        return;

    // Exo suit abilities (wall run, energy, slide) on in every mission,
    // including ones the story starts without them (the prologue, or a mission
    // loaded directly). F5 turns off only the mod's wall jump; bo7_cp_exo 0
    // leaves these abilities to the mission scripts.
    if ( GetDvarInt( "bo7_cp_exo", 1 ) != 0 )
    {
        SetDvar( "wallrun_enabled", 1 );
        SetDvar( "playerEnergy_enabled", 1 );
        self AllowWallRun( true );
        self AllowSlide( true );
    }

    // No thrust jump (jet pack double jump), as in BO7 and the MP version of the
    // mod; always applied, including in the safehouse and training simulator.
    // bo7_jetpack 1 gives it back.
    jp = GetDvarInt( "bo7_jetpack", 0 );
    SetDvar( "doublejump_enabled", jp );
    self AllowDoubleJump( jp != 0 );

    self thread monitor_wall_bounce();
}

// A listen server patches its own process (the host's client loads the DLL),
// so sprint-in-any-direction always matches there. A dedicated server has no
// local player, so its sprint code is patched by the movement plugin, which
// sets bo7_srvomni when it has done so. Either way, tell clients it is safe to
// load omnimovement.dll.
function bo7_flag_omni()
{
    wait 0.05;
    if ( !bo7_dedicated() || GetDvarInt( "bo7_srvomni", 0 ) != 0 )
        level clientfield::set( "bo7_omniok", 1 );
}

// Prone omni: turn freely while prone (bg_prone_yawcap / bg_proneSwingSpeed),
// reapplied whenever bo7_prone changes; bo7_prone 0 restores the values the
// map started with. The other MP / ZM engine settings (gravity, base slide,
// lean) are left to the campaign.
function monitor_prone()
{
    self endon( "disconnect" );
    self endon( "stop_bo7_wall_bounce" );

    while ( true )
    {
        pr = GetDvarInt( "bo7_prone", 1 );
        if ( !IsDefined( self.bo7_prone_last ) || self.bo7_prone_last != pr )
        {
            self.bo7_prone_last = pr;
            if ( pr )
            {
                SetDvar( "bg_prone_yawcap",    GetDvarFloat( "bo7_proneyaw", 360 ) );
                SetDvar( "bg_proneSwingSpeed", GetDvarFloat( "bo7_proneswing", 1.0 ) );
            }
            else
            {
                if ( level.bo7_yawcap_base != 987654 )
                    SetDvar( "bg_prone_yawcap", level.bo7_yawcap_base );
                if ( level.bo7_swing_base != 987654 )
                    SetDvar( "bg_proneSwingSpeed", level.bo7_swing_base );
            }
        }
        wait 0.5;
    }
}

// True on a dedicated server (no local player, no UI fonts).
function bo7_dedicated()
{
    return ( IsDedicated() || GetDvarInt( "dedicated", 0 ) != 0 );
}

// Sets a tunable's default unless it already has a value (server config,
// console, or the push from bo7slice.dll), so any bo7_* dvar can be set in a
// dedicated server's config.
function bo7_default( name, value )
{
    if ( GetDvarString( name ) == "" )
        SetDvar( name, value );
}

// Per-spawn setup: engine movement dvars, tunables, the movement threads and
// the load-in text (first spawn of the match only). The engine wall run is
// off so the polling paths own every wall; the reactive bounce on
// "wallrun_begin" remains as a fallback.
function monitor_wall_bounce()
{
    self endon( "disconnect" );
    self notify( "stop_bo7_wall_bounce" );
    self endon( "stop_bo7_wall_bounce" );

    // CP: the campaign's own cyber core abilities (wall run, thrusters, double
    // jump, energy) and its gravity / slide / lean settings are left alone, so
    // missions that depend on them keep working. Only the wall jump, ledge
    // catch, omni sprint and corner slice are added.
    register_bo7_dvars();

    self.bo7_last       = 0;
    self.bo7_front_wall = undefined;
    self thread monitor_front_bounce();
    self thread monitor_ledge();
    self thread monitor_prone();
    self thread monitor_slice();
    self.bo7_spawntime = GetTime();
    self thread bo7_wj_publish();

    if ( !IsDefined( self.bo7_welcomed ) )
    {
        self.bo7_welcomed = 1;
        self thread bo7_loadin_text();
    }

    // The banner uses the MP / ZM HUD menu, which is untested in the campaign;
    // off unless bo7_cp_hud 1.
    if ( GetDvarInt( "bo7_cp_hud", 0 ) != 0 )
        self thread bo7_banner();

    while ( true )
    {
        notification = self util::waittill_any_return(
            "wallrun_begin", "death", "disconnect", "stop_bo7_wall_bounce" );

        if ( notification != "wallrun_begin" )
            break;
        if ( GetDvarInt( "bo7_enabled", 1 ) == 0 )
            continue;

        self thread do_bounce();
    }
}

// Load-in text a moment after spawning: the wall jump keys. Every player is
// shown it; the keys pick that player's own wall-jump assist (see
// monitor_wallcfg).
function bo7_loadin_text()
{
    self endon( "disconnect" );

    wait 1;
    self IPrintLnBold( "^3WALL JUMP: ^7F1 ^3side+front  ^7F2 ^3side  ^7F3 ^3front  ^7F4 ^3auto/press jump  ^7F5 ^3off" );
}

// Faint single-line tag in the bottom-right corner, kept out of the way (the
// hardcore HUD has no minimap). Drawn with the stock LUI script menu
// "HudElementText" - the LUI text the rest of the HUD uses. (A NewHudElem /
// NewClientHudElem text element is drawn unscaled in this game, so fontscale
// had no effect.) LUI space is SCREEN_WIDTH x SCREEN_HEIGHT (1280 x 720):
// bn_x = right margin, bn_y = bottom margin, bn_scale = size (text height
// 32 x bn_scale), bn_alpha = opacity 0-1; bn_text1 and bn_text2 are joined on
// one line. All follow the bn_* keys in bo7_slice_cfg.txt, re-read twice a
// second; bo7_banner 0 hides it. Only changed values are sent; a respawn
// re-sends everything.
function bo7_banner()
{
    self endon( "disconnect" );

    if ( IsDefined( self.bo7_bn ) )
    {
        self.bo7_bn_resend = 1;
        return;
    }

    menu = self OpenLUIMenu( "HudElementText" );
    self.bo7_bn = menu;
    self.bo7_bn_resend = 1;
    t0 = GetTime();

    shown = "";
    lx = -1;
    ly = -1;
    lh = -1;
    la = -1;
    while ( true )
    {
        if ( self.bo7_bn_resend )
        {
            self.bo7_bn_resend = 0;
            self SetLUIMenuData( menu, "alignment", LUI_HUDELEM_ALIGNMENT_RIGHT );
            self SetLUIMenuData( menu, "red", 1 );
            self SetLUIMenuData( menu, "green", 1 );
            self SetLUIMenuData( menu, "blue", 1 );
            self SetLUIMenuData( menu, "width", 1000 );
            shown = "\x01";
            lx = -1;
            ly = -1;
            lh = -1;
            la = -1;
        }

        // CP: fixed text (bo7_cp_bntext), shown for bo7_bnsecs seconds from
        // the first spawn, then removed. bo7_bntext1/2 (and the shared
        // bo7_slice_cfg.txt they come from) are left to MP.
        if ( GetTime() - t0 >= int( GetDvarFloat( "bo7_bnsecs", 30 ) * 1000 ) )
        {
            self SetLUIMenuData( menu, "alpha", 0 );
            self CloseLUIMenu( menu );
            return;
        }
        line = GetDvarString( "bo7_cp_bntext" );
        if ( line != shown )
        {
            self SetLUIMenuData( menu, "text", line );
            shown = line;
        }

        sc = GetDvarFloat( "bo7_bnscale", 0.7 );
        if ( sc < 0.1 )
            sc = 0.1;
        if ( sc > 4 )
            sc = 4;
        h = int( 32 * sc + 0.5 );
        x = int( SCREEN_WIDTH - GetDvarFloat( "bo7_bnx", 132 ) - 1000 );
        y = int( SCREEN_HEIGHT - GetDvarFloat( "bo7_bny", 6 ) - h );

        a = GetDvarFloat( "bo7_bnalpha", 0.5 );
        if ( a < 0 )
            a = 0;
        if ( a > 1 )
            a = 1;
        if ( line == "" || GetDvarInt( "bo7_banner", 1 ) == 0 )
            a = 0;

        if ( x != lx )
        {
            self SetLUIMenuData( menu, "x", x );
            lx = x;
        }
        if ( y != ly )
        {
            self SetLUIMenuData( menu, "y", y );
            ly = y;
        }
        if ( h != lh )
        {
            self SetLUIMenuData( menu, "height", h );
            lh = h;
        }
        if ( a != la )
        {
            self SetLUIMenuData( menu, "alpha", a );
            la = a;
        }

        wait 0.5;
    }
}

// Tunables, registered once per map so console changes survive respawns.
function register_bo7_dvars()
{
    if ( IsDefined( level.bo7_dvars_done ) )
        return;
    level.bo7_dvars_done = 1;

    level.bo7_yawcap_base = GetDvarFloat( "bg_prone_yawcap", 987654 );
    level.bo7_swing_base  = GetDvarFloat( "bg_proneSwingSpeed", 987654 );

    level.bo7_fallmin_base = GetDvarFloat( "bg_fallDamageMinHeight", 128 );
    level.bo7_fallmax_base = GetDvarFloat( "bg_fallDamageMaxHeight", 300 );

    bo7_default( "bo7_enabled",    1 );
    bo7_default( "bo7_front",      1 );
    bo7_default( "bo7_front_air",  1 );
    bo7_default( "bo7_sidepre",    1 );
    bo7_default( "bo7_wallmode",        1 );
    bo7_default( "bo7_wallspace",       0 );
    bo7_default( "bo7_wjbuffer",        50 );
    bo7_default( "bo7_wjtouch",         24 );
    bo7_default( "bo7_wjimpact",        500 );
    bo7_default( "bo7_sidedist",   36 );

    bo7_default( "bo7_lift",       400 );
    bo7_default( "bo7_out",        190 );
    bo7_default( "bo7_look",       1.45 );
    bo7_default( "bo7_minspeed",   200 );
    bo7_default( "bo7_maxspeed",   520 );
    bo7_default( "bo7_minkeep",    0.5 );
    bo7_default( "bo7_maxalign",   0.75 );
    bo7_default( "bo7_tracedist",  60 );

    bo7_default( "bo7_frontlift",  470 );
    bo7_default( "bo7_frontout",   45 );
    bo7_default( "bo7_fronttan",   0.45 );
    bo7_default( "bo7_frontdist",  70 );
    bo7_default( "bo7_frontalign", 0.75 );
    bo7_default( "bo7_frontspeed", 0 );
    bo7_default( "bo7_slowspeed",  120 );
    bo7_default( "bo7_sidespeed",  100 );
    bo7_default( "bo7_side_air",   1 );
    bo7_default( "bo7_samewall",   0.85 );
    bo7_default( "bo7_jetpack",    0 );
    bo7_default( "bo7_energy",     1 );
    bo7_default( "bo7_physprobe",  1 );
    bo7_default( "bo7_probew",     12 );
    bo7_default( "bo7_probeh",     16 );
    bo7_default( "bo7_reach",      16 );
    bo7_default( "bo7_reachk",     0.10 );
    bo7_default( "bo7_sidephys",   1 );
    bo7_default( "bo7_softland",   1 );
    bo7_default( "bo7_fallmin",    600 );
    bo7_default( "bo7_fallmax",    1200 );
    bo7_default( "bo7_speed",      1.08 );
    bo7_default( "bo7_omni",       0 );
    bo7_default( "bo7_peek",       0 );
    bo7_default( "bo7_leanshift",  12 );

    bo7_default( "bo7_ledge",      1 );


    bo7_default( "bo7_ledgereach", 64 );
    bo7_default( "bo7_ledgeup",    100 );
    bo7_default( "bo7_ledgeminrise", 34 );
    bo7_default( "bo7_ledgefall",  260 );
    bo7_default( "bo7_ledgeassist", 1 );
    bo7_default( "bo7_ledgegrace", 150 );
    bo7_default( "bo7_ledgepush",  150 );
    bo7_default( "bo7_ledgeboost", 80 );
    bo7_default( "bo7_ledgemax",   1 );
    bo7_default( "bo7_ledgecool",  350 );
    bo7_default( "bo7_ledgeafter", 1100 );

    bo7_default( "bo7_slice",   1 );
    bo7_default( "bo7_csmax",   10 );
    bo7_default( "bo7_csreach", 45 );
    bo7_default( "bo7_csfull",  30 );
    bo7_default( "bo7_csgap",   12 );
    bo7_default( "bo7_csmove",  30 );
    bo7_default( "bo7_cshold",  250 );
    bo7_default( "bo7_csflip",  250 );
    bo7_default( "bo7_csstart", 150 );
    bo7_default( "bo7_csbal",   28 );
    bo7_default( "bo7_csmem",   400 );
    bo7_default( "bo7_csdead",  0.1 );
    bo7_default( "bo7_csopen",  0.4 );
    bo7_default( "bo7_csdebug", 1 );
    bo7_default( "bo7_csaim",     1 );
    bo7_default( "bo7_csaimnear", 24 );
    bo7_default( "bo7_csaimfull", 40 );
    bo7_default( "bo7_csaimedge", 1 );
    bo7_default( "bo7_csaimang",  8 );
    bo7_default( "bo7_wjsound",   1 );
    bo7_default( "bo7_wjsound3d", 1 );
    bo7_default( "bo7_banner",    1 );
    bo7_default( "bo7_bntext1",   "| RIP BO7 OPEN MATCHMAKING | GONE 2 SOON | FUCK SBMM |" );
    bo7_default( "bo7_bntext2",   "" );
    bo7_default( "bo7_bnx",       132 );
    bo7_default( "bo7_bny",       6 );
    bo7_default( "bo7_bnscale",   0.7 );
    bo7_default( "bo7_bnalpha",   0.5 );

    bo7_default( "bo7_prone",      1 );
    bo7_default( "bo7_pronespeed", 2.2 );
    bo7_default( "bo7_proneyaw",   360 );
    bo7_default( "bo7_proneswing", 1.0 );
    bo7_default( "bo7_chainmax",   3 );
    bo7_default( "bo7_chaindecay", 0.10 );
    bo7_default( "bo7_chainmin",   0.60 );
    bo7_default( "bo7_chainhdecay",0.04 );
    bo7_default( "bo7_chainhmin",  0.80 );
    bo7_default( "bo7_baseslide",  1 );
    bo7_default( "bo7_bggrav",     800 );
    bo7_default( "bo7_frontmaxz",  380 );

    bo7_default( "bo7_grav",       900 );
    bo7_default( "bo7_fallboost",  260 );
    bo7_default( "bo7_fallframes", 12 );
    bo7_default( "bo7_zkeep",      0.35 );
    bo7_default( "bo7_zcap",       90 );
    bo7_default( "bo7_nudge",      18 );
    bo7_default( "bo7_minframes",  2 );
    bo7_default( "bo7_maxframes",  8 );
    bo7_default( "bo7_cooldown",   300 );
    bo7_default( "bo7_probe",      64 );
    bo7_default( "bo7_nudgealways", 0 );
    bo7_default( "bo7_speedlock",   1 );
    bo7_default( "bo7_keepwallrun", 0 );
}

// Corner slice (script side). While aiming down sights near a corner edge it
// finds the open side and requests a weapon cant toward it (bo7_lean_send).
// bo7slice.dll applies the cant to the weapon only, so the world stays level.
function monitor_slice()
{
    self endon( "death" );
    self endon( "disconnect" );

    self thread slice_clear_on_death();

    seen = -100000;
    ed   = -1;
    sent = 0;
    self bo7_lean_send( 0 );

    while ( true )
    {
        wait 0.05;

        want = 0;
        now  = GetTime();
        dd   = 0;
        prox = 0;
        aim  = 0;
        op   = 0;

        if ( GetDvarInt( "bo7_slice", 1 ) != 0 )
        {
            ads = self PlayerADS();

            if ( ads > 0.1 )
            {
                ang = self GetPlayerAngles();
                d = self slice_scan( ang[1] );
                if ( d >= 0 )
                {
                    seen = now;
                    ed   = d;
                }

                if ( ( now - seen ) <= GetDvarInt( "bo7_csmem", 400 ) )
                {
                    reach = GetDvarFloat( "bo7_csreach", 45 );
                    full  = GetDvarFloat( "bo7_csfull", 30 );

                    if ( ed <= full || reach <= full )
                        prox = 1;
                    else
                        prox = ( reach - ed ) / ( reach - full );
                    if ( prox < 0 )
                        prox = 0;

                    dd = self.bo7_csdiff;
                    dz = GetDvarFloat( "bo7_csdead", 0.1 );
                    fo = GetDvarFloat( "bo7_csopen", 0.4 );
                    if ( fo <= dz )
                        fo = dz + 0.01;
                    op = ( abs( dd ) - dz ) / ( fo - dz );
                    if ( op < 0 )
                        op = 0;
                    if ( op > 1 )
                        op = 1;

                    aim = 1;
                    if ( GetDvarInt( "bo7_csaim", 1 ) != 0 )
                        aim = self.bo7_csaimf;

                    sg = 1;
                    if ( dd < 0 )
                        sg = -1;

                    want = sg * op * GetDvarFloat( "bo7_csmax", 10 ) * ads * prox * aim;
                }
            }
            else
                seen = -100000;
        }

        if ( abs( want - sent ) > 0.05 )
        {
            self bo7_lean_send( want );
            if ( GetDvarInt( "bo7_csdebug", 0 ) != 0 && self IsHost() )
                SetDvar( "bo7_csinfo", "want " + want + "  edge " + int( ed ) + "  diff " + dd + "  open " + op + "  prox " + prox + "  aim " + aim );
            sent = want;
        }
    }
}

// Levels the weapon when the player dies.
function slice_clear_on_death()
{
    self endon( "disconnect" );
    self waittill( "death" );
    self bo7_lean_send( 0 );
}

// Sends a cant in degrees to this player's client: bo7_lean clientfield in
// quarter degrees offset by 256 (0 = none). The client script writes it to
// the bo7_lean dvar that bo7slice.dll reads.
function bo7_lean_send( deg )
{
    v = int( deg * 4 + 256.5 );
    if ( v < 1 )
        v = 1;
    if ( v > 511 )
        v = 511;
    self clientfield::set_to_player( "bo7_lean", v );
}

// Fan of traces around the view: finds the nearest edge and the open side and
// scales the cant by the distance to that edge.
function slice_scan( yaw )
{
    eye   = self GetEye();
    reach = GetDvarFloat( "bo7_csreach", 45 );
    gap   = GetDvarFloat( "bo7_csgap", 12 );
    offs  = array( -80, -60, -40, -22, -8, 0, 8, 22, 40, 60, 80 );
    wts   = array( 0.4, 0.6, 0.8, 1.0, 1.0, 0, 1.0, 1.0, 0.8, 0.6, 0.4 );
    ctr   = 5;

    dir = [];
    hit = [];
    dst = [];
    pos = [];
    nrm = [];

    for ( i = 0; i < offs.size; i++ )
    {
        dir[ i ] = AnglesToForward( ( 0, yaw + offs[ i ], 0 ) );
        tr = BulletTrace( eye, eye + dir[ i ] * reach, false, self );
        hit[ i ] = ( tr[ "fraction" ] < 1 );
        dst[ i ] = tr[ "fraction" ] * reach;
        pos[ i ] = tr[ "position" ];
        nrm[ i ] = tr[ "normal" ];
    }

    cl = 0;
    wl = 0;
    cr = 0;
    wr = 0;
    for ( i = 0; i < offs.size; i++ )
    {
        if ( i == ctr )
            continue;
        c = 1;
        if ( hit[ i ] )
            c = dst[ i ] / reach;
        if ( offs[ i ] > 0 )
        {
            cl = cl + c * wts[ i ];
            wl = wl + wts[ i ];
        }
        else
        {
            cr = cr + c * wts[ i ];
            wr = wr + wts[ i ];
        }
    }
    self.bo7_csdiff = ( cr / wr ) - ( cl / wl );

    af = 1;
    if ( hit[ ctr ] )
    {
        anear = GetDvarFloat( "bo7_csaimnear", 24 );
        afull = GetDvarFloat( "bo7_csaimfull", 40 );
        if ( afull <= anear )
            afull = anear + 1;
        af = ( dst[ ctr ] - anear ) / ( afull - anear );
        if ( af < 0 )
            af = 0;
        if ( af > 1 )
            af = 1;

        ae = GetDvarFloat( "bo7_csaimedge", 1 );
        if ( ae > 0 && self.bo7_csdiff != 0 )
        {
            oi = 6;
            oj = 7;
            if ( self.bo7_csdiff > 0 )
            {
                oi = 4;
                oj = 3;
            }
            if ( GetDvarInt( "bo7_csaimang", 8 ) >= 20 )
                oi = oj;
            if ( !hit[ oi ] || dst[ oi ] >= afull )
            {
                if ( ae > 1 )
                    ae = 1;
                if ( af < ae )
                    af = ae;
            }
        }
    }
    self.bo7_csaimf = af;

    best = -1;
    for ( i = 0; i < offs.size; i++ )
    {
        if ( !hit[ i ] )
            continue;

        foreach ( j in array( i - 1, i + 1 ) )
        {
            if ( j < 0 || j >= offs.size )
                continue;

            den = VectorDot( dir[ j ], nrm[ i ] );
            if ( den > -0.05 )
                continue;

            t = VectorDot( pos[ i ] - eye, nrm[ i ] ) / den;
            if ( t <= 0 || t > reach )
                continue;

            if ( hit[ j ] && dst[ j ] < t + gap )
                continue;

            q = eye + dir[ j ] * t;
            e = Distance( eye, ( pos[ i ] + q ) * 0.5 );
            if ( best < 0 || e < best )
                best = e;
        }
    }

    return best;
}

// Ledge catch: when a jump or wall jump ends just below a ledge top, helps the
// engine mantle take it.
function monitor_ledge()
{
    self endon( "death" );
    self endon( "disconnect" );

    self.bo7_ledgeused = 0;

    while ( true )
    {
        wait 0.05;

        if ( GetDvarInt( "bo7_ledge", 1 ) == 0 )
            continue;

        if ( self IsOnGround() )
        {
            self.bo7_ledgeused = 0;
            wait 0.15;
            continue;
        }

        if ( self IsMantling() )
            continue;

        v = self GetVelocity();

        if ( v[2] > 0 - GetDvarFloat( "bo7_ledgefall", 260 ) )
            continue;

        if ( self.bo7_ledgeused >= GetDvarInt( "bo7_ledgemax", 1 ) )
            continue;

        if ( IsDefined( self.bo7_ledgenext ) && GetTime() < self.bo7_ledgenext )
            continue;

        if ( IsDefined( self.bo7_last ) &&
             ( GetTime() - self.bo7_last ) < GetDvarInt( "bo7_ledgeafter", 1100 ) )
            continue;

        self try_ledge( v );
    }
}

// Looks for a reachable ledge ahead and lifts the player into mantle range.
function try_ledge( v )
{
    reach = GetDvarFloat( "bo7_ledgereach",   64 );
    up    = GetDvarFloat( "bo7_ledgeup",      100 );
    minr  = GetDvarFloat( "bo7_ledgeminrise", 34 );

    hl = Length( ( v[0], v[1], 0 ) );

    if ( hl > 40 )
    {
        dx = v[0] / hl;
        dy = v[1] / hl;
    }
    else
    {
        a = self GetPlayerAngles();
        f = AnglesToForward( ( 0, a[1], 0 ) );
        dx = f[0];
        dy = f[1];
    }

    o  = self.origin;
    px = o[0] + ( dx * reach );
    py = o[1] + ( dy * reach );

    t = self wall_probe( ( px, py, o[2] + up ), ( px, py, o[2] + minr ) );

    if ( t[ "fraction" ] >= 0.999 )
        return;

    hit = t[ "position" ];

    if ( IsDefined( t[ "normal" ] ) && t[ "normal" ][2] < 0.7 )
        return;

    need = ( hit[2] + 12 ) - o[2];

    if ( need < minr )
        return;

    vz = Sqrt( 1600 * need ) + GetDvarFloat( "bo7_ledgeboost", 80 );
    pu = GetDvarFloat( "bo7_ledgepush", 150 );

    if ( hl > pu )
        pu = hl;

    if ( GetDvarInt( "bo7_ledgeassist", 1 ) )
    {
        self.bo7_ledge_t = GetTime();
        self SetVelocity( ( v[0], v[1], 20 ) );

        grace = GetDvarInt( "bo7_ledgegrace", 150 );
        til   = GetTime() + grace;

        while ( GetTime() < til )
        {
            wait 0.05;

            if ( self IsMantling() )
            {
                self.bo7_ledgeused = 0;
                return;
            }

            if ( self IsOnGround() )
                return;
        }
    }

    self.bo7_ledge_t = GetTime();
    self SetVelocity( ( dx * pu, dy * pu, vz ) );

    self.bo7_ledgeused = self.bo7_ledgeused + 1;
    self.bo7_ledgenext = GetTime() + GetDvarInt( "bo7_ledgecool", 350 );

}

// Player-sized box sweep with player collision (see the notes at the top).
function wall_probe( from, to )
{
    w = GetDvarFloat( "bo7_probew", 12 );
    h = GetDvarFloat( "bo7_probeh", 16 );
    return PhysicsTrace( from, to, ( 0-w, 0-w, 0-h ), ( w, w, h ), self, 32 );
}

// Sets an engine dvar and reports the value the engine actually kept.
function bo7_apply( nm, val )
{
    SetDvar( nm, val );
}

// Prone movement: speed scale while prone and the prone turn cap.
function omni_scale()
{
    base = GetDvarFloat( "bo7_speed", 1.08 );

    if ( !IsAlive( self ) )
        return base;

    if ( GetDvarInt( "bo7_prone", 0 ) && self GetStance() == "prone" )
        return base * GetDvarFloat( "bo7_pronespeed", 2.2 );

    return base;
}

// Records the wall-jump press for press-jump mode (bo7_wallspace 1): a jump
// press made in the air, at the wall. In this mode monitor_front_bounce only
// launches when the wall is within bo7_wjtouch units of the player's centre
// (default 24: the player's collision radius is 15, so within about 9 units
// of touching a wall square to it), and only on a press at most bo7_wjbuffer ms old (default 50, one
// frame of grace), so the press has to be made at the wall, not on the way
// to it. The jump off the ground never counts, so jumping while right next
// to a wall does not fire a wall jump either: the player presses again once
// at the wall. Each wall of a chain needs its own press. Landing, any
// takeoff and each wall jump (launch_off) clear the press, and a press while
// mantling never counts.
//
// By the time a player presses at the wall the engine has already taken out
// the velocity into it, which would leave only a slide along the wall to
// judge from (wrong direction for a front wall hit at an angle, and a weak
// launch). So the poll keeps the horizontal velocity from the frame before
// an impact (a sharp drop in horizontal velocity while airborne) in
// bo7_impv, with the wall it came from (bo7_impn), and for bo7_wjimpact ms
// (default 500; the first sample is kept that long) press mode judges that
// wall from it, as auto mode judges before contact. Any other wall, or no
// launch from the sample, is judged from the current velocity. launch_off
// records the velocity it sets during its hold, so an impact right after a
// wall jump is caught as well.
// The cooldown after a wall jump (bo7_cooldown) only blocks the same wall in
// press mode (bo7_lastwall), so a press at the next wall of a chain is not
// lost to it.
//
// Script runs once per server frame, after that frame's movement, so the
// frame that sees a ground jump press usually has the player in the air
// already. A takeoff is therefore: on the ground or wall running at the
// previous frame, or a sharp rise in vertical speed since then (in the air
// it only falls, about 40 a frame), which catches a landing and jump between
// two frames. The rise test leaves out the mod's own pushes (a wall jump
// launch, the ledge assist) for 150 ms, and is skipped while the engine
// double jump is on (the doublejump_enabled dvar, on with bo7_jetpack 1), as
// a jump press in the air then boosts upward too and would never count.
//
// bo7_jump_poll runs at the top of each monitor_front_bounce frame, before
// its wall-jump check, so the check always sees this frame's press.
function bo7_jump_reset()
{
    self.bo7_jumpat = 0;
    self.bo7_jwas   = false;
    self.bo7_jair   = false;
    self.bo7_jvz    = 0;
    self.bo7_jvh    = ( 0, 0, 0 );
    self.bo7_impv   = undefined;
}

function bo7_jump_poll()
{
    now   = self JumpButtonPressed();
    inair = ( !self IsOnGround() && !self IsWallRunning() );
    vel   = self GetVelocity();
    vz    = vel[2];
    t     = GetTime();
    edge  = ( now && !self.bo7_jwas );

    lift = false;
    if ( IsDefined( self.bo7_launch_t ) && t - self.bo7_launch_t <= 150 )
        lift = true;
    if ( IsDefined( self.bo7_ledge_t ) && t - self.bo7_ledge_t <= 150 )
        lift = true;

    rise = false;
    if ( self.bo7_jair && !lift && GetDvarInt( "doublejump_enabled", 0 ) == 0 && vz > self.bo7_jvz + 100 )
        rise = true;
    takeoff = ( !self.bo7_jair || rise );

    if ( !inair )
    {
        if ( !self IsWallRunning() )
            self.bo7_jumpat = 0;
    }
    else if ( takeoff )
        self.bo7_jumpat = 0;

    if ( edge && inair && !takeoff && !self IsMantling() )
        self.bo7_jumpat = t;

    vh = ( vel[0], vel[1], 0 );
    if ( !inair || takeoff )
        self.bo7_impv = undefined;
    else if ( Length( vh ) < Length( self.bo7_jvh ) && Length( self.bo7_jvh - vh ) > 60 )
    {
        if ( !IsDefined( self.bo7_impv ) || t - self.bo7_impt > GetDvarInt( "bo7_wjimpact", 500 ) )
        {
            d  = vh - self.bo7_jvh;
            dl = Length( d );
            self.bo7_impv = self.bo7_jvh;
            self.bo7_impt = t;
            self.bo7_impn = ( d[0] / dl, d[1] / dl, 0 );
        }
    }

    self.bo7_jwas = now;
    self.bo7_jair = inair;
    self.bo7_jvz  = vz;
    self.bo7_jvh  = vh;
}

function wj_pressed()
{
    if ( !IsDefined( self.bo7_jumpat ) || self.bo7_jumpat <= 0 )
        return false;
    return ( GetTime() - self.bo7_jumpat ) <= GetDvarInt( "bo7_wjbuffer", 50 );
}

// Wall jump modes: bo7_wallmode 0 off, 1 side + frontal, 2 side, 3 frontal.
// bo7_wallspace 1 = press jump mode: a jump press in the air, at the wall
// (see bo7_jump_poll). Keys F1-F5.
function wallmode_name( m )
{
    if ( m <= 0 )
        return "^1OFF";
    if ( m == 2 )
        return "SIDE ONLY";
    if ( m == 3 )
        return "FORWARD ONLY";
    return "FULL (side + forward)";
}

// Each player's wall-jump choice is their own. F1-F5 set the client dvars
// bo7_mywallmode (0 off / 1 side+front / 2 side / 3 front) and bo7_mywallspace
// (F4 toggles it: 0 auto, 1 press jump at the wall); bo7slice.dll
// relays the pair to the server, which delivers it here as a per-player
// "menuresponse" (response "bo7w<mode><space>"). Stored on the player as
// self.bo7_wm / self.bo7_ws, which last until the map ends; while unset the
// server-wide dvar default applies, so a server config can still set a
// default for everyone.
//
// The send is one message with no reply of its own, so it is confirmed
// through the bo7_wjstate clientfield (bo7_wj_publish): the client script
// keeps asking the DLL to send again until the server reports the same
// setting the player picked. That covers a send made before this listener
// was running (loading in, a map change) as well as one that never arrived.
// The listener is started by bo7_wj_publish at each spawn and keeps running
// while the player is dead or in a killcam. It is not started before the
// first spawn on purpose: bo7slice.dll sends its built-in setting (mode 1,
// auto) by itself when it first sees a server, and taking that as the
// player's choice would replace the server's own default (bo7_wallmode /
// bo7_wallspace) for players who never chose. A real choice made before the
// first spawn arrives anyway, as a resend once the server's first report
// reaches the client. A repeat that changes nothing is not announced at
// spawn or more than once in 2 s.
function monitor_wallcfg()
{
    self endon( "disconnect" );
    self notify( "bo7_wallcfg" );
    self endon( "bo7_wallcfg" );

    while ( true )
    {
        self waittill( "menuresponse", menu, resp );

        if ( !IsString( resp ) )
            continue;
        if ( GetSubStr( resp, 0, 4 ) != "bo7w" )
            continue;
        ms = GetSubStr( resp, 4, 5 );
        ss = GetSubStr( resp, 5, 6 );
        if ( ms == "" || ss == "" )
            continue;

        m = int( ms );
        s = int( ss );
        if ( m < 0 || m > 3 )
            continue;

        cm = self bo7_wallmode();
        cs = self bo7_wallspace();
        same = ( m == cm && ( s != 0 ) == cs );

        self.bo7_wm = m;
        self.bo7_ws = ( s != 0 );
        self bo7_wj_state_send();

        if ( same )
        {
            if ( IsDefined( self.bo7_spawntime ) && GetTime() - self.bo7_spawntime < 3000 )
                continue;
            if ( IsDefined( self.bo7_wjmsg ) && GetTime() - self.bo7_wjmsg < 2000 )
                continue;
        }
        self.bo7_wjmsg = GetTime();

        sp = "^2auto";
        if ( s != 0 )
            sp = "^1press jump at the wall";
        self IPrintLnBold( "^3wall jump: " + wallmode_name( m ) + "   ^7space: " + sp );
    }
}

// Keeps the bo7_wjstate clientfield equal to the wall-jump setting this
// player actually has: 1 + mode * 2 + (1 if press jump is required), so 1-8;
// 0 means nothing published yet. It is checked twice a second, so a change
// to the server default (bo7_wallmode / bo7_wallspace) is published too. One
// loop per player, started at the first spawn (nothing is published before
// it): each spawn replaces the last, and it keeps running while the player
// is dead.
function bo7_wj_publish()
{
    self endon( "disconnect" );
    self notify( "bo7_wj_publish" );
    self endon( "bo7_wj_publish" );

    self thread monitor_wallcfg();

    while ( true )
    {
        self bo7_wj_state_send();
        wait 0.5;
    }
}

function bo7_wj_state_send()
{
    m = self bo7_wallmode();
    if ( m < 0 || m > 3 )
        m = 0;
    v = 1 + m * 2;
    if ( self bo7_wallspace() )
        v = v + 1;

    if ( IsDefined( self.bo7_wjpub ) && self.bo7_wjpub == v )
        return;
    self.bo7_wjpub = v;
    self clientfield::set_to_player( "bo7_wjstate", v );
}

// This player's wall-jump mode / jump-press requirement: their own choice if
// they have made one, otherwise the server-wide default dvar.
function bo7_wallmode()
{
    if ( IsDefined( self.bo7_wm ) )
        return self.bo7_wm;
    return GetDvarInt( "bo7_wallmode", 1 );
}

function bo7_wallspace()
{
    if ( IsDefined( self.bo7_ws ) )
        return self.bo7_ws;
    return ( GetDvarInt( "bo7_wallspace", 0 ) != 0 );
}

// True while the last launch is within bo7_cooldown ms (launch_off sets
// bo7_last again when its hold ends, so this runs from the end of the hold).
function bo7_cooling()
{
    if ( !IsDefined( self.bo7_last ) )
        return false;
    return ( GetTime() - self.bo7_last ) < GetDvarFloat( "bo7_cooldown", 300 );
}

// True if wall normal n is the wall the impact sample came from: the change
// in velocity at the impact points out of that wall.
function bo7_impwall( n )
{
    if ( !IsDefined( self.bo7_impn ) )
        return false;
    return ( ( n[0] * self.bo7_impn[0] ) + ( n[1] * self.bo7_impn[1] ) ) > GetDvarFloat( "bo7_samewall", 0.85 );
}

// True if wall normal n is the wall of the last wall jump (bo7_samewall).
// Press-jump mode only lets the cooldown block that wall.
function bo7_lastwall( n )
{
    if ( !IsDefined( self.bo7_lastn ) )
        return false;
    return ( ( n[0] * self.bo7_lastn[0] ) + ( n[1] * self.bo7_lastn[1] ) ) > GetDvarFloat( "bo7_samewall", 0.85 );
}

// Wall jump polling, every server frame while airborne:
//   frontal - a trace along the velocity hits a surface square-on within
//             reach (body radius plus one frame of travel); the launch
//             climbs the face.
//   side    - a wall alongside, found with the player-collision sweep; the
//             launch leaves it in the look direction.
function monitor_front_bounce()
{
    self endon( "disconnect" );
    self endon( "stop_bo7_wall_bounce" );

    self bo7_jump_reset();
    while ( true )
    {
        wait 0.05;

        if ( !IsAlive( self ) )
            continue;

        self bo7_jump_poll();

        msp = self omni_scale();
        if ( !IsDefined( self.bo7_speed_applied ) || self.bo7_speed_applied != msp )
        {
            self SetMoveSpeedScale( msp );
            self.bo7_speed_applied = msp;
        }

        if ( self IsOnGround() )
        {
            self.bo7_front_wall = undefined;
            self.bo7_chain = 0;
            self.bo7_refused = undefined;

            if ( IsDefined( self.bo7_softland ) )
            {
                SetDvar( "bg_fallDamageMinHeight", level.bo7_fallmin_base );
                SetDvar( "bg_fallDamageMaxHeight", level.bo7_fallmax_base );
                self.bo7_softland = undefined;
            }
        }
        if ( GetDvarInt( "bo7_enabled", 1 ) == 0 )
            continue;
        wm = self bo7_wallmode();
        if ( wm <= 0 )
            continue;
        wside  = ( wm == 1 || wm == 2 );
        wfront = ( wm == 1 || wm == 3 );
        if ( GetDvarInt( "bo7_front", 1 ) == 0 && GetDvarInt( "bo7_sidepre", 1 ) == 0 )
            continue;
        // Press-jump mode (pm): only on a fresh press, only with the wall
        // within bo7_wjtouch of the player's centre (below), judged from the
        // velocity before the wall impact, and the cooldown only blocks the
        // wall just jumped off (see bo7_jump_poll).
        pm   = self bo7_wallspace();
        cool = self bo7_cooling();
        if ( cool && !pm )
            continue;

        if ( self IsWallRunning() )
            continue;

        if ( pm && ( !self wj_pressed() || self IsMantling() ) )
            continue;
        touch = GetDvarFloat( "bo7_wjtouch", 24 );

        // Press mode with a fresh impact sample judges first from the
        // velocity just before the impact, for the wall that was hit only
        // (bo7_impwall); if that launches nothing it judges again, in the
        // same frame, from the current velocity as auto mode does. Auto
        // mode makes the one ordinary pass.
        usei = ( pm && IsDefined( self.bo7_impv ) && GetTime() - self.bo7_impt <= GetDvarInt( "bo7_wjimpact", 500 ) );
        for ( pass = 0; pass < 2; pass++ )
        {
            if ( pass == 1 && !usei )
                break;
            imp = ( pass == 0 && usei );

            v  = self GetVelocity();
            hs = Length( ( v[0], v[1], 0 ) );
            if ( imp )
            {
                v  = ( self.bo7_impv[0], self.bo7_impv[1], v[2] );
                hs = Length( self.bo7_impv );
            }
            if ( hs < GetDvarFloat( "bo7_frontspeed", 0 ) )
                continue;

            if ( v[2] > GetDvarFloat( "bo7_frontmaxz", 380 ) )
                continue;

            if ( hs < GetDvarFloat( "bo7_slowspeed", 120 ) )
            {
                la   = self GetPlayerAngles();
                lf   = AnglesToForward( ( 0, la[1], 0 ) );
                vhat = ( lf[0], lf[1], 0 );
            }
            else
                vhat = ( v[0]/hs, v[1]/hs, 0 );

            eye      = self.origin + ( 0, 0, 36 );
            onground = self IsOnGround();

            if ( wside && GetDvarInt( "bo7_sidepre", 1 )
                 && hs >= GetDvarFloat( "bo7_sidespeed", 100 )
                 && !( GetDvarInt( "bo7_side_air", 1 ) && onground ) )
            {
                sdist = GetDvarFloat( "bo7_sidedist", 36 );
                sphys = GetDvarInt( "bo7_sidephys", 1 );
                soff  = 0;
                if ( sphys )
                    soff = GetDvarFloat( "bo7_probew", 12 );
                slen  = sdist - soff;
                if ( slen < 4 )
                    slen = 4;
                rtx   = vhat[1];
                rty   = 0 - vhat[0];
                sbf   = 1.0;
                sbn   = ( 0, 0, 0 );
                sba   = 0;
                sbd   = 0;

                dgx = vhat[0] + rtx;
                dgy = vhat[1] + rty;
                dgl = Length( ( dgx, dgy, 0 ) );
                if ( dgl > 0.1 ) { dgx = dgx/dgl; dgy = dgy/dgl; }
                dhx = vhat[0] - rtx;
                dhy = vhat[1] - rty;
                dhl = Length( ( dhx, dhy, 0 ) );
                if ( dhl > 0.1 ) { dhx = dhx/dhl; dhy = dhy/dhl; }

                for ( k = 0; k < 4; k++ )
                {
                    if ( k == 0 )      sv = (  rtx*slen,  rty*slen, 0 );
                    else if ( k == 1 ) sv = ( 0-rtx*slen, 0-rty*slen, 0 );
                    else if ( k == 2 ) sv = (  dgx*slen,  dgy*slen, 0 );
                    else               sv = (  dhx*slen,  dhy*slen, 0 );

                    if ( sphys )
                        ts = self wall_probe( eye, eye + sv );
                    else
                        ts = BulletTrace( eye, eye + sv, false, self );
                    if ( ts[ "fraction" ] >= 0.99 )
                        continue;

                    sn  = ts[ "normal" ];
                    snl = Length( ( sn[0], sn[1], 0 ) );
                    if ( snl < 0.1 && sphys )
                    {
                        t2  = BulletTrace( eye, eye + ( sv[0] + ( sv[0] / slen ) * soff, sv[1] + ( sv[1] / slen ) * soff, 0 ), false, self );
                        sn  = t2[ "normal" ];
                        snl = Length( ( sn[0], sn[1], 0 ) );
                    }
                    if ( snl < 0.1 )
                        continue;

                    snx = sn[0] / snl;
                    sny = sn[1] / snl;
                    sa  = ( snx * vhat[0] ) + ( sny * vhat[1] );
                    if ( sa < 0 )
                        sa = 0 - sa;
                    if ( sa > GetDvarFloat( "bo7_maxalign", 0.75 ) )
                        continue;
                    if ( imp && !self bo7_impwall( ( snx, sny, 0 ) ) )
                        continue;

                    if ( ts[ "fraction" ] < sbf )
                    {
                        self.bo7_hitd = ( ts[ "fraction" ] * slen ) + soff;
                        sbd = self.bo7_hitd;
                        sbf = ts[ "fraction" ];
                        sbn = ( snx, sny, 0 );
                        sba = sa;
                    }
                }

                if ( Length( sbn ) > 0.1 && ( !pm || sbd <= touch ) && !( cool && self bo7_lastwall( sbn ) ) )
                {
                    self thread launch_off( sbn, hs, v[2], sba, "pre", GetTime() );
                    break;
                }
            }

            if ( !wfront || GetDvarInt( "bo7_front", 1 ) == 0 )
                continue;

            if ( GetDvarInt( "bo7_front_air", 1 ) && onground )
                continue;

            dist  = GetDvarFloat( "bo7_frontdist", 70 );
            reach = GetDvarFloat( "bo7_reach", 16 ) + ( hs * GetDvarFloat( "bo7_reachk", 0.10 ) );
            if ( reach > dist )
                reach = dist;
            dv = ( vhat[0]*reach, vhat[1]*reach, 0 );

            if ( GetDvarInt( "bo7_physprobe", 1 ) )
                t = self wall_probe( eye, eye + dv );
            else
                t = BulletTrace( eye, eye + dv, false, self );

            if ( t[ "fraction" ] >= 0.99 )
                continue;

            self.bo7_hitd = t[ "fraction" ] * reach;

            // Distance from the player's centre to the wall: the box probe stops
            // with its face, bo7_probew from the centre, on the wall.
            fd = self.bo7_hitd;
            if ( GetDvarInt( "bo7_physprobe", 1 ) )
                fd = fd + GetDvarFloat( "bo7_probew", 12 );
            if ( pm && fd > touch )
                continue;

            n  = t[ "normal" ];
            nl = Length( ( n[0], n[1], 0 ) );
            if ( nl < 0.1 )
            {
                t2 = BulletTrace( eye, eye + dv, false, self );
                n  = t2[ "normal" ];
                nl = Length( ( n[0], n[1], 0 ) );
            }
            if ( nl < 0.1 )
                continue;
            nx = n[0] / nl;
            ny = n[1] / nl;

            a = ( nx * vhat[0] ) + ( ny * vhat[1] );
            if ( a < 0 )
                a = 0 - a;
            if ( a < GetDvarFloat( "bo7_frontalign", 0.75 ) )
                continue;

            if ( cool && self bo7_lastwall( ( nx, ny, 0 ) ) )
                continue;
            if ( imp && !self bo7_impwall( ( nx, ny, 0 ) ) )
                continue;

            if ( IsDefined( self.bo7_front_wall ) )
            {
                same = ( nx * self.bo7_front_wall[0] ) + ( ny * self.bo7_front_wall[1] );
                if ( same > GetDvarFloat( "bo7_samewall", 0.85 ) )
                    continue;
            }
            self.bo7_front_wall = ( nx, ny, 0 );

            self thread launch_off( ( nx, ny, 0 ), hs, v[2], a, "front", GetTime() );
            break;
        }
    }
}

// Picks the wall being run along: the hit whose normal is most perpendicular
// to the direction of travel.
function find_wall( vhat, vlen )
{
    out = [];
    out[ "normal" ] = ( 0, 0, 0 );
    out[ "align" ]  = 0;

    ang  = self GetPlayerAngles();
    dist = GetDvarFloat( "bo7_tracedist", 60 );
    eye  = self.origin + ( 0, 0, 36 );

    max_align = GetDvarFloat( "bo7_maxalign", 0.75 );
    have_v    = ( vlen > 20 );

    best_f = 1.0;  best_n = ( 0, 0, 0 );  best_a = 0;
    any_f  = 1.0;  any_n  = ( 0, 0, 0 );  any_a  = 0;

    for ( i = 0; i < 8; i++ )
    {
        dir = AnglesToForward( ( 0, ang[1] + ( i * 45 ), 0 ) );
        t   = BulletTrace( eye, eye + ( dir[0]*dist, dir[1]*dist, 0 ), false, self );
        if ( t[ "fraction" ] >= 0.99 )
            continue;

        n  = t[ "normal" ];
        nl = Length( ( n[0], n[1], 0 ) );
        if ( nl < 0.1 )
            continue;

        nx = n[0] / nl;
        ny = n[1] / nl;

        a = 0;
        if ( have_v )
        {
            a = ( nx * vhat[0] ) + ( ny * vhat[1] );
            if ( a < 0 )
                a = 0 - a;
        }

        if ( t[ "fraction" ] < any_f )
        {
            any_f = t[ "fraction" ];  any_n = ( nx, ny, 0 );  any_a = a;
        }
        if ( have_v && a < max_align && t[ "fraction" ] < best_f )
        {
            best_f = t[ "fraction" ];  best_n = ( nx, ny, 0 );  best_a = a;
        }
    }

    if ( Length( best_n ) > 0.1 )
    {
        out[ "normal" ] = best_n;
        out[ "align" ]  = best_a;
        return out;
    }
    out[ "normal" ] = any_n;
    out[ "align" ]  = any_a;
    return out;
}

// Reactive side bounce on the engine "wallrun_begin" notify (fallback path).
function do_bounce()
{
    self endon( "disconnect" );
    self endon( "death" );
    self endon( "stop_bo7_wall_bounce" );

    wm = self bo7_wallmode();
    if ( wm != 1 && wm != 2 )
        return;
    if ( self bo7_wallspace() && !self wj_pressed() )
        return;

    t0   = GetTime();
    v    = self GetVelocity();
    peak = Length( ( v[0], v[1], 0 ) );

    waittillframeend;
    if ( !IsAlive( self ) )
        return;

    v2 = self GetVelocity();
    h2 = Length( ( v2[0], v2[1], 0 ) );

    if ( h2 >= peak )
    {
        vhat = ( v2[0], v2[1], 0 );
        vlen = h2;
    }
    else
    {
        vhat = ( v[0], v[1], 0 );
        vlen = peak;
    }
    if ( h2 > peak )
        peak = h2;
    if ( vlen > 0.1 )
        vhat = ( vhat[0]/vlen, vhat[1]/vlen, 0 );

    vz_in = v2[2];
    if ( vz_in < v[2] )
        vz_in = v[2];

    wall = self find_wall( vhat, vlen );
    if ( Length( wall[ "normal" ] ) < 0.1 )
    {
        return;
    }

    self launch_off( wall[ "normal" ], peak, vz_in, wall[ "align" ], "bounce", t0 );
}

// Wall jump sound: 2D for the jumper, 3D for everyone else. (The MP Dead
// Silence branch is removed: that perk does not exist in ZM.)
function bo7_wj_sound()
{
    if ( GetDvarInt( "bo7_wjsound", 1 ) == 0 )
        return;

    local_alias = "bo7_wall_jump";
    world_alias = "bo7_wall_jump_3d";
    self PlayLocalSound( local_alias );
    if ( GetDvarInt( "bo7_wjsound3d", 1 ) != 0 )
        self PlaySoundToAllButPlayer( world_alias, self );
}

// Strength multiplier for the n-th wall jump of one airborne chain.
function chain_mult( n, decay, floor_v )
{
    m = 1.0 - ( decay * ( n - 1 ) );
    if ( m < floor_v )
        m = floor_v;
    return m;
}

// Shared launch for every wall jump path. The horizontal direction follows the
// look direction with the into-wall part removed, so frontal jumps climb the
// face and side jumps leave along the wall; height comes from bo7_lift /
// bo7_frontlift. The velocity is held for a few frames so the engine does not
// absorb it.
function launch_off( normal, peak, vz_in, align, tag, t0 )
{
    self.bo7_launch_t = GetTime();
    self.bo7_jumpat = 0;
    self.bo7_impv   = undefined;
    self.bo7_lastn  = normal;

    if ( !IsDefined( self.bo7_chain ) )
        self.bo7_chain = 0;

    cmax = GetDvarInt( "bo7_chainmax", 5 );
    if ( cmax > 0 && self.bo7_chain >= cmax )
    {
        if ( !IsDefined( self.bo7_refused ) )
        {
            self.bo7_refused = 1;
        }
        return;
    }

    self.bo7_chain = self.bo7_chain + 1;
    cn = self.bo7_chain;
    cv = chain_mult( cn, GetDvarFloat( "bo7_chaindecay",  0.10 ), GetDvarFloat( "bo7_chainmin",  0.60 ) );
    ch = chain_mult( cn, GetDvarFloat( "bo7_chainhdecay", 0.04 ), GetDvarFloat( "bo7_chainhmin", 0.80 ) );

    self endon( "disconnect" );
    self endon( "death" );
    self endon( "stop_bo7_wall_bounce" );

    self notify( "bo7_bounce_again" );
    self endon( "bo7_bounce_again" );

    self.bo7_last = GetTime();
    start = GetTime();

    self bo7_wj_sound();

    if ( GetDvarInt( "bo7_softland", 1 ) )
    {
        SetDvar( "bg_fallDamageMinHeight", GetDvarFloat( "bo7_fallmin", 600 ) );
        SetDvar( "bg_fallDamageMaxHeight", GetDvarFloat( "bo7_fallmax", 1200 ) );
        self.bo7_softland = 1;
    }

    av  = self GetVelocity();
    avl = Length( ( av[0], av[1], 0 ) );
    avx = 0;
    avy = 0;
    if ( avl > 1 )
    {
        avx = av[0] / avl;
        avy = av[1] / avl;
    }

    lift = GetDvarFloat( "bo7_lift", 300 );
    if ( tag == "front" )
        lift = GetDvarFloat( "bo7_frontlift", 470 );
    lift = lift * cv;
    sep = GetDvarFloat( "bo7_out", 190 );

    spd = peak * GetDvarFloat( "bo7_look", 1.45 );
    min_spd = GetDvarFloat( "bo7_minspeed", 380 );
    max_spd = GetDvarFloat( "bo7_maxspeed", 660 );
    if ( spd < min_spd ) spd = min_spd;
    if ( spd > max_spd ) spd = max_spd;

    ang = self GetPlayerAngles();
    fwd = AnglesToForward( ( 0, ang[1], 0 ) );

    hx = fwd[0] * spd;
    hy = fwd[1] * spd;

    if ( tag == "front" )
    {
        d = ( hx * normal[0] ) + ( hy * normal[1] );
        if ( d < 0 )
        {
            hx = hx - normal[0] * d;
            hy = hy - normal[1] * d;
        }

        tanscale = GetDvarFloat( "bo7_fronttan", 0.45 );
        hx = hx * tanscale;
        hy = hy * tanscale;

        fo = GetDvarFloat( "bo7_frontout", 45 );
        d2 = ( hx * normal[0] ) + ( hy * normal[1] );
        if ( d2 < fo )
        {
            hx = hx + normal[0] * ( fo - d2 );
            hy = hy + normal[1] * ( fo - d2 );
        }
    }
    else
    {
        d = ( hx * normal[0] ) + ( hy * normal[1] );
        if ( d < 0 )
        {
            hx = hx - normal[0] * d;
            hy = hy - normal[1] * d;
        }

        hmag = Length( ( hx, hy, 0 ) );
        if ( avl > 1 && hmag < ( spd * GetDvarFloat( "bo7_minkeep", 0.5 ) ) )
        {
            td = ( avx * normal[0] ) + ( avy * normal[1] );
            tx = avx - ( normal[0] * td );
            ty = avy - ( normal[1] * td );
            tl = Length( ( tx, ty, 0 ) );
            if ( tl > 0.1 )
            {
                hx = ( tx / tl ) * spd;
                hy = ( ty / tl ) * spd;
            }
        }

        d = ( hx * normal[0] ) + ( hy * normal[1] );
        if ( d < sep )
        {
            add = sep - d;
            hx = hx + normal[0] * add;
            hy = hy + normal[1] * add;
        }

        if ( GetDvarInt( "bo7_speedlock", 1 ) )
        {
            lm = Length( ( hx, hy, 0 ) );
            if ( lm > 1 )
            {
                hx = ( hx / lm ) * spd;
                hy = ( hy / lm ) * spd;
            }
        }
    }

    vz = vz_in;
    if ( vz < 0 )
        vz = 0;
    vz = vz * GetDvarFloat( "bo7_zkeep", 0.35 );
    zcap = GetDvarFloat( "bo7_zcap", 90 );
    if ( vz > zcap )
        vz = zcap;
    zout = vz + lift;

    hx = hx * ch;
    hy = hy * ch;

    wr0  = self IsWallRunning();
    gnd0 = self IsOnGround();

    probe = GetDvarFloat( "bo7_probe", 64 );
    rv    = ( normal[0]*probe, normal[1]*probe, 0 );
    room  = probe;

    heights = array( 12, 36, 62 );
    foreach ( h in heights )
    {
        e = self.origin + ( 0, 0, h );
        t = BulletTrace( e, e + rv, false, self );
        r = t[ "fraction" ] * probe;
        if ( r < room )
            room = r;
    }

    nudge = GetDvarFloat( "bo7_nudge", 18 );
    limit = room * 0.45;
    if ( nudge > limit )
        nudge = limit;

    wt = GetTime() - t0;

    if ( nudge >= 4 && ( wr0 || GetDvarInt( "bo7_nudgealways", 0 ) ) )
    {
        self SetOrigin( self.origin + ( normal[0]*nudge, normal[1]*nudge, 2 ) );
        tele = 1;
    }
    else
        tele = 0;

    min_f = int( GetDvarFloat( "bo7_minframes", 2 ) );
    max_f = int( GetDvarFloat( "bo7_maxframes", 8 ) );
    if ( min_f < 1 ) min_f = 1;
    if ( max_f > 12 ) max_f = 12;
    if ( max_f < min_f ) max_f = min_f;

    grav = GetDvarFloat( "bo7_grav", 900 );
    zcur = zout;
    held = 0;

    hv = "";
    for ( i = 0; i < max_f; i++ )
    {
        pv = self GetVelocity();
        hv = hv + int( Length( ( pv[0], pv[1], 0 ) ) ) + "/";

        self SetVelocity( ( hx, hy, zcur ) );
        self.bo7_jvh = ( hx, hy, 0 );
        held = i + 1;
        wait 0.05;
        if ( !IsAlive( self ) )
            return;
        zcur = zcur - ( grav * 0.05 );

        if ( i >= ( min_f - 1 ) && !self IsWallRunning() )
            break;
    }

    self.bo7_last = GetTime();

    cmd = Length( ( hx, hy, 0 ) );
    cosv = 0;
    if ( cmd > 1 )
        cosv = ( ( hx/cmd ) * fwd[0] ) + ( ( hy/cmd ) * fwd[1] );

    hitd = -1;
    if ( IsDefined( self.bo7_hitd ) )
        hitd = int( self.bo7_hitd );


    boost = GetDvarFloat( "bo7_fallboost", 260 );
    fmax  = int( GetDvarFloat( "bo7_fallframes", 12 ) );
    if ( fmax > 24 ) fmax = 24;
    if ( fmax < 1 )  fmax = 1;

    zt = "";
    for ( i = 0; i < fmax; i++ )
    {
        wait 0.05;
        if ( !IsAlive( self ) )
            return;
        if ( self IsOnGround() || self IsWallRunning() )
            break;

        cv = self GetVelocity();
        if ( i < 6 )
            zt = zt + int( cv[2] ) + "/";

        if ( cv[2] < 0 )
            self SetVelocity( ( cv[0], cv[1], cv[2] - ( boost * 0.05 ) ) );
    }

    b = self GetVelocity();
}
