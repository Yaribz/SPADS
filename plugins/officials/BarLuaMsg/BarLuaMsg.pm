# BarLuaMsg (Perl module)
#
# SPADS plugin implementing parsing of Lua messages used by Beyond All Reason.
#
# Copyright (C) 2026  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

package BarLuaMsg;

use strict;

use IO::Uncompress::Inflate qw'inflate $InflateError';
use List::Util 'all';

use SpadsPluginApi;
use SpringAutoHostInterface qw':luaScript :luaPreproc';

use base 'Exporter';
use constant { # SelectedUnits opcodes
  SEL_UNITS_OP_CLEAR => 0,
  SEL_UNITS_OP_DELTA => 1,
  SEL_UNITS_OP_SET_EXPLICIT => 2,
  SEL_UNITS_OP_SET_TEAM => 3,
  SEL_UNITS_OP_SET_DEFS => 4,
};

our %EXPORT_TAGS = (selUnits => [qw'SEL_UNITS_OP_CLEAR SEL_UNITS_OP_DELTA SEL_UNITS_OP_SET_EXPLICIT SEL_UNITS_OP_SET_TEAM SEL_UNITS_OP_SET_DEFS']);
Exporter::export_ok_tags('selUnits');

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.13.56';

sub getVersion { return $pluginVersion }
sub getRequiredSpadsVersion { return $requiredSpadsVersion }

# Note: expectedFrequency is supposed to be the average occurence in one minute, to optimize Lua message prefix check order
# However, in case of conflicting message prefixes, it can also be used to force checking the longest prefix first (see DraftOrderEvent/DraftOrderMode)
my %BAR_LUA_MSGS = (
  LUA_SCRIPT_RULES() => [
    # MsgName              ,prefix           ,valStrLength, paramPreproc, parsingFunction, expectedFrequency
    ['ActivityBroadcast'   ,'^'              ,2  ,LUA_PREPROC_NOPARAM ,undef, 30],                      # data_activity_broadcast.lua
    ['AutoColors'          ,'AutoColors'     ,0  ,LUA_PREPROC_JSON],                                    # game_autocolors.lua
    ['CameraBroadcast'     ,'='              ,[2],LUA_PREPROC_NONE    ,\&camBroadcastParser, 100],      # data_camera_broadcast.lua
    ['ChangeStartUnit'     ,'changeStartUnit'],                                                         # gui_factionpicker.lua
    ['DraftOrderAction'    ,[qw'skip_my_turn vote_skip_turn i_have_joined_fair vote_wait_too_long send_me_the_info_again']
                                             ,0  ,LUA_PREPROC_NOPARAM ,\&draftOrderActionParser, 1],    # gui_pregameui_draft.lua
    ['FpsOrGpuMemBroadcast','@'              ,2  ,LUA_PREPROC_NONE    ,undef, 34],                      # game_fps_broadcast.lua, data_gpumem_broadcast.lua
    ['FrameTimeBroadcast'  ,'#ft'            ,0  ,LUA_PREPROC_NONE    ,\&frameTimeBroadcastParser, 30], # game_frametime_broadcast.lua
    ['GameAwards'          ,chr(161)         ,0  ,LUA_PREPROC_NONE    ,\&gameAwardsParser],             # game_awards.lua
    ['GameEvent'           ,'l0g'            ,2  ,LUA_PREPROC_NONE    ,\&gameEventParser],              # game_logger.lua
    ['IdlePlayer'          ,'idleplayers '   ,-2],                                                      # cmd_idle_players.lua
    ['LuaMemBroadcast'     ,'%'              ,2  ,LUA_PREPROC_NONE    ,undef, 6],                       # data_luamem_broadcast.lua
    ['LuaSpads'            ,'lu@$p@d$:'      ,0  ,LUA_PREPROC_BASE64  ,\&luaSpadsParser],               # barwidgets.lua
    ['MapMark'             ,'m@pm@rk'        ,2  ,LUA_PREPROC_NONE    ,\&mapMarkParser, 2],             # data_system_info.lua
    ['MouseBroadcast'      ,'£'              ,2  ,LUA_PREPROC_NONE    ,\&mouseBroadcastParser, 480],    # cmd_mouse_pos_broadcast.lua
    ['PauseStatus'         ,'p@u$3:'],                                                                  # data_system_info.lua
    ['PregameEvent'        ,[qw'joined_game ready_to_start_game locking_in_place unlocking_in_place',chr(144),chr(145)]
                                             ,0  ,LUA_PREPROC_NOPARAM ,\&pregameEventParser, 1],        # gui_pregameui.lua
    ['PregameHeartbeat'    ,'pc'             ,0  ,LUA_PREPROC_NOPARAM ,undef, 1],                       # game_end.lua
    ['SelectedUnits'       ,['cos2','cosz']  ,-2 ,LUA_PREPROC_NONE    ,\&selectedUnitsParser, 60],      # data_selected_units.lua
    ['StartPosition'       ,'startpos|'      ,0  ,LUA_PREPROC_NONE    ,\&startPositionParser],          # game_initial_spawn.lua
    ['SystemInfo'          ,'$y$'            ,2  ,LUA_PREPROC_NONE    ,\&sysInfoParser],                # data_system_info.lua
    ['UnitDefs'            ,'unitdefs:'      ,0  ,LUA_PREPROC_ZLIB|LUA_PREPROC_JSON],                   # log_unitdefids.lua
  ],
  LUA_SCRIPT_UI() => [
    ['ChatAction'          ,'gui_chat:chataction:',0,LUA_PREPROC_NONE ,\&chatActionParser, 2],          # gadgets.lua
    ['ComplexMatchEvent'   ,'complex-match-event:',0,LUA_PREPROC_BASE64|LUA_PREPROC_JSON],              # api_analytics.lua, api_unit_tracker_gl4.lua
    ['DraftOrderEvent'     ,'DraftOrder'     ,0   ,LUA_PREPROC_NONE   ,\&draftOrderEventParser, 1],     # game_draft_spawn_order.lua
    ['DraftOrderMode'      ,'DraftOrder_'    ,0   ,LUA_PREPROC_NONE   ,undef, 2],                       # game_draft_spawn_order.lua (expectedFrequency > DraftOrderEvent)
  ],
    );

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  my @registeredMsgs;
  foreach my $luaScript (keys %BAR_LUA_MSGS) {
    foreach my $r_luaMsgData (@{$BAR_LUA_MSGS{$luaScript}}) {
      my ($msgName,$msgPrefix,$validationStringLength,$paramPreprocessing,$r_parsingFunction,$expectedFrequency)=@{$r_luaMsgData};
      if(! registerLuaMsg($msgName,$luaScript,$msgPrefix,$validationStringLength,$paramPreprocessing,$r_parsingFunction,$expectedFrequency)) {
        slog("Failed to register Lua message $msgName",1);
        unregisterLuaMsg($_,1) foreach(@registeredMsgs);
        return undef;
      }
      push(@registeredMsgs,$msgName);
    }
  }
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  foreach my $luaScript (keys %BAR_LUA_MSGS) {
    unregisterLuaMsg($_->[0],1) foreach(@{$BAR_LUA_MSGS{$luaScript}});
  }
  slog('Plugin unloaded',3);
}

my @CAMERAS=(
  ['fps','FirstPerson',[qw'oldHeight rx ry rz']],
  ['ta','Overhead',[qw'height angle flipped']],
  ['spring','Spring',[qw'dist rx ry rz']],
  ['rot','RotOverhead',[qw'oldHeight rx ry rz']],
  ['free','Free',[qw'gndOffset gravity slide scrollSpeed tiltSpeed velTime avelTime autoTilt goForward invertAlt gndLock rx ry rz vx vy vz avx avy avz']],
  ['ov','Overview',[]],
  ['dolly','Dolly',[qw'rx ry rz']],
  ['dummy','Dummy',[]],
    );
foreach my $r_cam (@CAMERAS) {
  my @sortedAttribs=sort((qw'dx dy dz fov px py pz'),@{$r_cam->[2]});
  $r_cam->[2]=\@sortedAttribs;
}
sub camBroadcastParser {
  my ($luaMsgParam)=@_;
  my $luaMsgParamLength=length($luaMsgParam);
  return {}
    unless($luaMsgParamLength);
  my $camNb=unpack('C',substr($luaMsgParam,0,1,''));
  $camNb-=1;
  return (undef,"invalid camera number $camNb")
      unless($camNb >= 0 && $camNb <= $#CAMERAS);
  my ($camId,$camName,$r_camAttribs)=@{$CAMERAS[$camNb]};
  my $expectedSize=int((@{$r_camAttribs}*14+7)/8)+1;
  return (undef,"invalid camera state data size (expected $expectedSize, got $luaMsgParamLength)")
      unless($expectedSize == $luaMsgParamLength);
  my $r_unpacked=unpackCustomFloats14($luaMsgParam);
  my %camData=(cameraNb => $camNb,
               cameraId => $camId,
               cameraName => $camName,
      );
  for my $i (0..$#{$r_camAttribs}) {
    $camData{$r_camAttribs->[$i]}=$r_unpacked->[$i];
  }
  return \%camData;
}

sub unpackCustomFloats14 {
  my ($data)=@_;

  my @bytes=unpack('C*',$data);
  my @values;

  my $bitBuffer=0;
  my $bitCount=0;

  foreach my $byte (@bytes) {
    $bitBuffer = ($bitBuffer << 8) | $byte;
    $bitCount+=8;

    while($bitCount >= 14) {
      $bitCount-=14;

      my $code = ($bitBuffer >> $bitCount) & 0x3FFF;
      push(@values,unpackCustomFloat14($code));

      # Keep unused bits
      $bitBuffer &= (1 << $bitCount) - 1;
    }
  }

  return \@values;
}

sub unpackCustomFloat14 {
  my ($packedFloat14)=@_;

  my $sign=1;
  my $exponent=int($packedFloat14/64);
  my $mantissa = $packedFloat14 - ($exponent * 64);
  my $norm=1;

  if($exponent >= 128) {
    $exponent-=128;
    $sign=-1;
  }

  return undef
      if($exponent == 0);

  if($exponent == 1) {
    $exponent=2;
    $norm=0;
  }

  return $sign * ($norm + $mantissa/64) * (2 ** ($exponent - 64));
}

my %DRAFT_ORDER_ACTIONS=(
  skip_my_turn => 'SkipMyTurn',
  vote_skip_turn => 'VoteSkipTurn',
  i_have_joined_fair => 'JoinedFair',
  vote_wait_too_long => 'VoteTooLong',
  send_me_the_info_again => 'SendInfoAgain',
    );
sub draftOrderActionParser {
  my (undef,$prefix)=@_;
  return $DRAFT_ORDER_ACTIONS{$prefix};
}

sub frameTimeBroadcastParser {
  my ($luaMsgParam)=@_;
  my @ft=split('/',$luaMsgParam,6);
  return (undef,'invalid number of fields')
      unless(@ft == 6 && (all {defined $_} @ft));
  return (undef,'invalid data')
      unless((all {/^\d+$/} @ft[0,1])
             && (all {/^\d+\.\d$/} @ft[2..5]));
  return {
    simN => $ft[0],
    drawN => $ft[1],
    avgSim => $ft[2],
    simPeak => $ft[3],
    avgDraw => $ft[4],
    drawPeak => $ft[5],
  };
}

sub gameAwardsParser {
  my ($luaMsgParam)=@_;
  return (undef,'invalid data')
      unless($luaMsgParam =~ /^
                  (\d+) : (\d+(?:\.\d+)?)
             \xA1 (\d+) : (\d+(?:\.\d+)?)
             \xA1 (\d+) : (\d+(?:\.\d+)?)

             \xA2 (\d+) : (\d+(?:\.\d+)?)
             \xA2 (\d+) : (\d+(?:\.\d+)?)
             \xA2 (\d+) : (\d+(?:\.\d+)?)

             \xA3 (\d+) : (\d+(?:\.\d+)?)
             \xA3 (\d+) : (\d+(?:\.\d+)?)
             \xA3 (\d+) : (\d+(?:\.\d+)?)

             \xA4 (\d+)
             \xA5 (\d+) : (\d+(?:\.\d+)?)
             \xA6 (\d+) : (\d+(?:\.\d+)?)
             \xA7 (\d+) : (\d+(?:\.\d+)?)
             $/x);
  return {economyDestroyed => [[$1-1,$2],[$3-1,$4],[$5-1,$6]],
          fightingForcesDestroyed => [[$7-1,$8],[$9-1,$10],[$11-1,$12]],
          relativeEfficiency => [[$13-1,$14],[$15-1,$16],[$17-1,$18]],
          goldenCow => $19-1,
          economyProduced => [$20-1,$21],
          damageReceived => [$22-1,$23],
          sleepTime => [$24-1,$25]};
}

sub gameEventParser {
  my ($luaMsgParam)=@_;
  return (undef,'missing data')
      unless(length($luaMsgParam));
  return (undef,'missing colon at start of data')
      unless(substr($luaMsgParam,0,1,'') eq ':');
  my @gameEventData=split(/:/,$luaMsgParam,6);
  return (undef, "invalid map mark data \"$luaMsgParam\"")
      unless(@gameEventData == 6
             && (all {/^\d+$/} @gameEventData[1,3..5]));
  my %gameEvent;
  $gameEvent{$_}=shift(@gameEventData)
      foreach(qw'eventType gameFrame unknown targetTeamId actorTeamId targetUnitDefId');
  return \%gameEvent;
}

sub luaSpadsParser {
  my ($luaMsgParam)=@_;
  return (undef,'invalid data')
      unless($luaMsgParam =~ /^<([^>]+)> <(.+)> <(\d+)>$/);
  return {
    playerName => $1,
    event => $2,
    gameTime => $3,
  };
}

sub mapMarkParser {
  my ($luaMsgParam)=@_;
  return (undef,'missing data')
      unless(length($luaMsgParam));
  return (undef,'missing colon at start of data')
      unless(substr($luaMsgParam,0,1,'') eq ':');
  my @mapMarkData=split(/:/,$luaMsgParam,6);
  return (undef, "invalid map mark data \"$luaMsgParam\"")
      unless(@mapMarkData == 6
             && (all {/^\d+$/} @mapMarkData[0..3]));
  my %mapMark;
  $mapMark{$_}=shift(@mapMarkData)
      foreach(qw'gameFrame playerId posX posZ playerName text');
  return \%mapMark;
}

sub mouseBroadcastParser {
  my ($luaMsgParam)=@_;
  return (undef,'invalid length')
      unless(length($luaMsgParam) == 5);
  my %mouseData;
  @mouseData{qw'clickChar posX posY'}=unpack('a v v',$luaMsgParam);
  return \%mouseData;
}

my %PREGAME_MSGS=(
  joined_game => 'JoinedGame',
  ready_to_start_game => 'Ready',
  locking_in_place => 'Locked',
  unlocking_in_place => 'Unlocked',
  chr(144) => 'OfferedAsSub',
  chr(145) => 'SubOfferWithdrawn',
    );
sub pregameEventParser {
  my (undef,$prefix)=@_;
  return $PREGAME_MSGS{$prefix};
}

my @SELECTED_UNITS_OPERATIONS=(
  'CLEAR',
  'DELTA',
  'SET_EXPLICIT',
  'SET_TEAM',
  'SET_DEFS',
    );
sub selectedUnitsParser {
  my ($luaMsgParam,$prefix)=@_;
  my $msgDataStr;
  if(substr($prefix,-1) eq 'z') {
    inflate(\$luaMsgParam,\$msgDataStr)
        or return (undef,$InflateError);
  }else{
    $msgDataStr=$luaMsgParam;
  }
  my $msgDataStrLength=length($msgDataStr);
  return (undef,'missing opcode')
      unless($msgDataStrLength);
  my $opcode=unpack('C',substr($msgDataStr,0,1,''));
  return (undef,"unknown opcode \"$opcode\"")
      unless($opcode =~ /^\d+$/ && $opcode <= $#SELECTED_UNITS_OPERATIONS);
  my %msgData=(opcode => $opcode, operation => $SELECTED_UNITS_OPERATIONS[$opcode]);
  if($opcode == SEL_UNITS_OP_CLEAR) {
    return (undef,'unexpected data in CLEAR operation message')
        if($msgDataStrLength > 1);
  }elsif($opcode == SEL_UNITS_OP_DELTA) {
    return (undef,'missing count params in DELTA operation message')
        unless($msgDataStrLength > 4);
    my ($addCount,$removeCount)=unpack('v v',substr($msgDataStr,0,4,''));
    my $expectedSize=($addCount+$removeCount)*2+5;
    return (undef,"inconsistent message size for DELTA operation, expected $expectedSize got $msgDataStrLength")
        unless($msgDataStrLength == $expectedSize);
    my @addUnits=unpack("v$addCount",substr($msgDataStr,0,2*$addCount,''));
    my @removeUnits=unpack("v$removeCount",$msgDataStr);
    $msgData{addUnits}=\@addUnits;
    $msgData{removeUnits}=\@removeUnits;
  }elsif($opcode == SEL_UNITS_OP_SET_EXPLICIT) {
    return (undef,'missing count param in SET_EXPLICIT operation message')
        unless($msgDataStrLength > 2);
    my $count=unpack('v',substr($msgDataStr,0,2,''));
    my $expectedSize=$count*2+3;
    return (undef,"inconsistent message size for SET_EXPLICIT operation, expected $expectedSize got $msgDataStrLength")
        unless($msgDataStrLength == $expectedSize);
    my @units=unpack("v$count",$msgDataStr);
    $msgData{units}=\@units;
  }else{
    my $hasUnitDefParam = ($opcode == SEL_UNITS_OP_SET_DEFS) ? 1 : 0; # used as a number later
    return (undef,"missing baseline or count params in $SELECTED_UNITS_OPERATIONS[$opcode] operation message")
        unless($msgDataStrLength > ($hasUnitDefParam ? 12 : 10));
    my ($baselineCount,$baselineSum,$baselineSumSquares)=unpack('v3',substr($msgDataStr,0,6,''));
    my $unitDefCount = $hasUnitDefParam ? unpack('v',substr($msgDataStr,0,2,'')) : 0;
    my ($includeCount,$excludeCount)=unpack('v2',substr($msgDataStr,0,4,''));
    my $expectedSize=($hasUnitDefParam+$unitDefCount+$includeCount+$excludeCount)*2+11;
    return (undef,"inconsistent message size for $SELECTED_UNITS_OPERATIONS[$opcode] operation, expected $expectedSize got $msgDataStrLength")
        unless($msgDataStrLength == $expectedSize);
    my @unitDefIDs;
    @unitDefIDs=unpack("v$unitDefCount",substr($msgDataStr,0,2*$unitDefCount,''))
        if($unitDefCount);
    my @includeUnits=unpack("v$includeCount",substr($msgDataStr,0,2*$includeCount,''));
    my @excludeUnits=unpack("v$excludeCount",$msgDataStr);
    @msgData{qw'baselineCount baselineSum baselineSumSquares includeUnits excludeUnits'}=($baselineCount,$baselineSum,$baselineSumSquares,\@includeUnits,\@excludeUnits);
    $msgData{unitDefIDs}=\@unitDefIDs if($opcode == SEL_UNITS_OP_SET_DEFS);
  }
  return \%msgData;
}

sub startPositionParser {
  my ($luaMsgParam)=@_;
  my @teamStartPositionsStr=split(/\|/,$luaMsgParam);
  return (undef,'empty start position data')
      unless(@teamStartPositionsStr);
  my @teamStartPositions;
  foreach my $teamStartPositionStr (@teamStartPositionsStr) {
    return (undef,"invalid start position data \"$teamStartPositionStr\"")
        unless($teamStartPositionStr =~ /^(\d+),(\d+),(\d+(?:\.\d+)?),(\d+)$/);
    push(@teamStartPositions,{teamId => $1, posX => $2, posY => $3, posZ => $4});
  }
  return \@teamStartPositions;
}

sub sysInfoParser {
  my ($luaMsgParam)=@_;
  return (undef,'empty message')
      unless(length($luaMsgParam));
  my %sysInfo;
  my @sysInfoLines=split(/\n/,$luaMsgParam);
  my $nextLineIsDisplayMode;
  foreach my $sysInfoLine (@sysInfoLines) {
    if($nextLineIsDisplayMode
       && ! exists $sysInfo{'Display mode'}
       && $sysInfoLine =~ /^\d+x\d+/) {
      $sysInfo{'Display mode'}=$sysInfoLine;
      $nextLineIsDisplayMode=0;
    }elsif($sysInfoLine =~ /^(.+[^\s])\s*:\s*(.*[^\s])\s*$/) {
      $sysInfo{$1}=$2;
      $nextLineIsDisplayMode = $1 eq 'Display max';
    }
  }
  return (\%sysInfo,undef);
}

sub chatActionParser {
  my ($luaMsgParam)=@_;
  if($luaMsgParam =~ /^([^:]+):([^:]+):(.*)$/s) {
    my ($source,$mode,$cmd)=($1,$2,$3);
    my $param;
    if($mode eq 'snapshot') {
      my @cmds;
      while(length($cmd)) {
        my $colonPos=index($cmd,':');
        return (undef,'missing colon in command declaration')
            if($colonPos == -1);
        my $fieldLength=substr($cmd,0,$colonPos,'');
        return (undef,"invalid length value \"$fieldLength\" in command declaration")
            unless($fieldLength =~ /^\d+$/);
        substr($cmd,0,1,'');
        return (undef,'length overflow in command declaration')
            if($fieldLength > length($cmd));
        push(@cmds,substr($cmd,0,$fieldLength,''));
      }
      $param=\@cmds;
    }else{
      $param=$cmd;
    }
    return ({source => $source, mode => $mode, param => $param},undef);
  }else{
    return (undef,'not enough colon characters');
  }
}

sub draftOrderEventParser {
  my ($luaMsgParam)=@_;
  return [split(/ /,$luaMsgParam)];
}

1;
