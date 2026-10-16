# BarCliPerf (Perl module)
#
# SPADS plugin processing Lua messages provided by Beyond All Reason regarding
# client system and performance to generate realtime client performance reports.
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

package BarCliPerf;

use strict;

use SpadsPluginApi;
use SpringAutoHostInterface qw':cliState :srvState';

use constant { PI => 4 * atan2(1, 1) };
use utf8;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.13.56';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
my %presetPluginParams;

sub getVersion { return $pluginVersion }
sub getRequiredSpadsVersion { return $requiredSpadsVersion }
sub getParams { return [\%globalPluginParams,\%presetPluginParams] }
sub getDependencies { return ('BarLuaMsg') }

my %LUAMSG_HANDLERS=(
  SystemInfo => \&hLuaSystemInfo,
  FpsOrGpuMemBroadcast => \&hLuaFpsOrGpuMem,
  FrameTimeBroadcast => \&hLuaFrameTime,
  LuaMemBroadcast => \&hLuaMem,
  CameraBroadcast => \&hLuaCamera,
    );
sub new {
  my $class=shift;

  my $self = {};
  bless($self,$class);
  $self->onSpringStart(); # reset internal state

  addLuaMsgHandler($_,$LUAMSG_HANDLERS{$_})
      foreach(keys %LUAMSG_HANDLERS);

  addSpringCommandHandler({GAME_LUAMSG => \&hSpringGameLuaMsg});
  addSpadsCommandHandler({cliPerf => \&hSpadsCliPerf});

  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  removeLuaMsgHandler($_)
      foreach(keys %LUAMSG_HANDLERS);
  removeSpringCommandHandler(['GAME_LUAMSG']);
  removeSpadsCommandHandler(['cliPerf']);
  slog('Plugin unloaded',3);
}

sub onSpringStart {
  my $self=shift;
  $self->{$_}={}
    foreach(qw'sysInfo fpsValidationStr lastRcvFpsOrGpuMemValidationStr fps gpuMemUsage frameTime luaMem camera nbLuaMsg');
}

sub hLuaSystemInfo {
  my ($playerNb,$r_luaMsgData)=@_[0,4];
  getPlugin()->{sysInfo}{getSpringInterface()->getPlayerName($playerNb)}=$r_luaMsgData;
}

sub hLuaFpsOrGpuMem {
  my ($playerNb,$param,$validationStr)=@_[0,4,5];
  my $self=getPlugin();
  if(! defined $self->{fpsValidationStr}{$playerNb}) {
    my $lastRcvFpsOrGpuMemValidationStr=$self->{lastRcvFpsOrGpuMemValidationStr}{$playerNb};
    if(defined $lastRcvFpsOrGpuMemValidationStr && $lastRcvFpsOrGpuMemValidationStr eq $validationStr) {
      $self->{fpsValidationStr}{$playerNb}=$validationStr;
    }else{
      $self->{lastRcvFpsOrGpuMemValidationStr}{$playerNb}=$validationStr;
      return;
    }
  }
  my $dataType = $validationStr eq $self->{fpsValidationStr}{$playerNb} ? 'fps' : 'gpuMemUsage';
  $self->{$dataType}{getSpringInterface()->getPlayerName($playerNb)}=[$param,time];
}

sub hLuaFrameTime {
  my ($playerNb,$r_luaMsgData)=@_[0,4];
  getPlugin()->{frameTime}{getSpringInterface()->getPlayerName($playerNb)}=[$r_luaMsgData,time];
}

sub hLuaMem {
  my ($playerNb,$param)=@_[0,4];
  getPlugin()->{luaMem}{getSpringInterface()->getPlayerName($playerNb)}=[$param,time];
}

sub hLuaCamera {
  my ($playerNb,$r_luaMsgData)=@_[0,4];
  getPlugin()->{camera}{getSpringInterface()->getPlayerName($playerNb)}=[$r_luaMsgData,time]
      if(%{$r_luaMsgData});
}

sub hSpringGameLuaMsg {
  my $playerNb=$_[1];
  getPlugin()->{nbLuaMsg}{getSpringInterface()->getPlayerName($playerNb)}++;
}

sub getClientData {
  my ($self,$player,$p_C,$B)=@_;
  my %C = defined $p_C ? %{$p_C} : (map {$_ => ''} (0..15));
  $B//='';

  my $currentTime=time();

  my %cliData=("$C{5}Player$C{1}" => $player);

  if(exists $self->{sysInfo}{$player}) {
    $cliData{"$C{5}CPU (cores)$C{1}"} = $self->{sysInfo}{$player}{CPU} // "$C{15}?$C{1}";
    my $cpuCores=$self->{sysInfo}{$player}{'CPU cores'};
    if(defined $cpuCores) {
      $cpuCores="$1/$2" if($cpuCores =~ /^\s*(\d+)\s*\/\s*(\d+)\s*$/);
      $cliData{"$C{5}CPU (cores)$C{1}"}.=" ($cpuCores)";
    }
    my $os=$self->{sysInfo}{$player}{OS};
    if(defined $os) {
      if($os eq 'Linux') {
        $os=$C{6}.$os.$C{1};
      }elsif($os eq 'Windows 10') {
        $os='Windows';
      }else{
        $os=$C{13}.$os.$C{1};
      }
    }else{
      $os="$C{15}?$C{1}";
    }
    $cliData{"$C{5}OS$C{1}"}=$os;
    my $ram=$self->{sysInfo}{$player}{RAM};
    if(defined $ram) {
      if($ram =~ /^(\d+)MB$/) {
        my $mbRam=$1;
        my $color;
        if($mbRam < 12000) {
          $color=13;
        }elsif($mbRam < 15000) {
          $color=4;
        }elsif($mbRam < 31000) {
          $color=7;
        }
        $ram="$C{$color}$ram$C{1}" if(defined $color);
      }
    }else{
      $ram="$C{15}?$C{1}";
    }
    $cliData{"$C{5}RAM$C{1}"}=$ram;
    $cliData{$C{5}.$_.$C{1}} = $self->{sysInfo}{$player}{$_} // "$C{15}?$C{1}"
        foreach('GPU','Display mode');
    my $vram=$self->{sysInfo}{$player}{'GPU VRAM'};
    if(defined $vram) {
      if($vram =~ /^(\d+)MB$/) {
        my $mbRam=$1;
        my $color;
        if($mbRam < 4000) {
          $color=13;
        }elsif($mbRam < 6000) {
          $color=4;
        }elsif($mbRam < 8000) {
          $color=7;
        }
        $vram="$C{$color}$vram$C{1}" if(defined $color);
      }
    }else{
      $vram="$C{15}?$C{1}";
    }
    $cliData{"$C{5}VRAM$C{1}"}=$vram;
  }else{
    $cliData{$C{5}.$_.$C{1}}="$C{15}?$C{1}"
        foreach('CPU (cores)','RAM','GPU','VRAM','Display mode','OS');
  }

  if(exists $self->{gpuMemUsage}{$player}) {
    my $val=$self->{gpuMemUsage}{$player}[0];
    if($currentTime - $self->{gpuMemUsage}{$player}[1] > 29) {
      $val=$C{14}.$val.'%'.$C{1} ;
    }else{
      my $color;
      if($val > 90) {
        $color=13;
      }elsif($val > 85) {
        $color=4;
      }elsif($val > 80) {
        $color=7;
      }
      $val.='%';
      $val=$C{$color}.$val.$C{1} if(defined $color);
    }
    $cliData{"$C{5}VRAM usage$C{1}"}=$val;
  }else{
    $cliData{"$C{5}VRAM usage$C{1}"}="$C{15}?$C{1}";
  }
  
  if(exists $self->{luaMem}{$player}) {
    my $val=$self->{luaMem}{$player}[0].'MB';
    $val=$C{14}.$val.$C{1} if($currentTime - $self->{luaMem}{$player}[1] > 19);
    $cliData{"$C{5}Lua mem.$C{1}"}=$val;
  }else{
    $cliData{"$C{5}Lua mem.$C{1}"}="$C{15}?$C{1}";
  }

  if(exists $self->{frameTime}{$player}) {
    my $r_val=$self->{frameTime}{$player}[0];
    my ($avgSim,$simPeak,$avgDraw,$drawPeak)=@{$r_val}{qw'avgSim simPeak avgDraw drawPeak'};
    my $simVal=$avgSim.'ms ('.$simPeak.'ms)';
    my $drawVal=$avgDraw.'ms ('.$drawPeak.'ms)';
    if($currentTime - $self->{frameTime}{$player}[1] > 3) {
      $simVal=$C{14}.$simVal.$C{1};
      $drawVal=$C{14}.$drawVal.$C{1};
    }else{
      my $color;
      if($avgSim > 19 || $simPeak > 29) {
        $color=13;
      }elsif($avgSim > 13 || $simPeak > 20) {
        $color=4;
      }elsif($avgSim > 9 || $simPeak > 14) {
        $color=7;
      }
      $simVal=$C{$color}.$simVal.$C{1} if(defined $color);
      if($avgDraw > 24 || $drawPeak > 40) {
        $color=13;
      }elsif($avgDraw > 16 || $drawPeak > 27) {
        $color=4;
      }elsif($avgDraw > 10 || $drawPeak > 17) {
        $color=7;
      }
      $drawVal=$C{$color}.$drawVal.$C{1} if(defined $color);
    }
    $cliData{"$C{5}SimFrame (peak)$C{1}"}=$simVal;
    $cliData{"$C{5}DrawFrame (peak)$C{1}"}=$drawVal;
  }else{
    $cliData{"$C{5}SimFrame (peak)$C{1}"}="$C{15}?$C{1}";
    $cliData{"$C{5}DrawFrame (peak)$C{1}"}="$C{15}?$C{1}";
  }

  if(exists $self->{fps}{$player}) {
    my $val=$self->{fps}{$player}[0];
    if($currentTime - $self->{fps}{$player}[1] > 3) {
      $val=$C{14}.$val.$C{1};
    }else{
      my $color;
      if($val < 15) {
        $color=13;
      }elsif($val < 25) {
        $color=4;
      }elsif($val < 35) {
        $color=7;
      }
      $val=$C{$color}.$val.$C{1} if(defined $color);
    }
    $cliData{"$C{5}FPS$C{1}"}=$val;
  }else{
    $cliData{"$C{5}FPS$C{1}"}="$C{15}?$C{1}";
  }

  if(exists $self->{camera}{$player} && defined $self->{camera}{$player}[0]{cameraName}) {
    my $r_val=$self->{camera}{$player}[0];
    my $val=$r_val->{cameraName};
    my ($angle,$dist,$defaultFov,$fov);
    if($r_val->{cameraId} eq 'spring') {
      $angle = int($r_val->{rx} * 180 / PI + 0.5) - 90;
      $dist=$r_val->{dist};
      $defaultFov=45;
    }elsif($r_val->{cameraId} eq 'fps') {
      $angle =  int($r_val->{rx} * 180 / PI + 0.5) - 90;
      $dist=$r_val->{py};
      $defaultFov=90;
    }elsif($r_val->{cameraId} eq 'ta') {
      $angle = 90 - int($r_val->{angle} * 180 / PI + 0.5);
      $dist=$r_val->{height};
      $defaultFov=45;
    }elsif($r_val->{cameraId} eq 'rot') {
      $angle = int($r_val->{rx} * 180 / PI + 0.5) - 90;
      $dist=$r_val->{py};
      $defaultFov=45;
    }elsif($r_val->{cameraId} eq 'free') {
      $angle = int(0.5 - ($r_val->{rx} * 180 / PI));
      $dist=$r_val->{py};
      $defaultFov=45;
    }
    $fov=$r_val->{fov} unless($r_val->{fov} == $defaultFov);
    my $details;
    if(defined $angle) {
      $val.=" ($angle°/$dist)";
      $val.=" [fov=$fov]" if(defined $fov);
    }
    $val=$C{14}.$val.$C{1} if($currentTime - $self->{camera}{$player}[1] > 60);
    $cliData{"$C{5}Camera (angle/dist)$C{1}"}=$val;
  }else{
    $cliData{"$C{5}Camera (angle/dist)$C{1}"}="$C{15}?$C{1}";
  }

  $cliData{"$C{5}Lua Msgs$C{1}"} = $self->{nbLuaMsg}{$player} // "$C{15}?$C{1}";

  return \%cliData;
}

sub getClientStatusString {
  my ($disconnectCause,$p_C,$B)=@_;
  my %C = defined $p_C ? %{$p_C} : (map {$_ => ''} (0..15));
  $B//='';
  return "$C{7}Loading$C{1}" if($disconnectCause == CLI_STATE_LOADING);
  return "$C{3}Connected$C{1}" if($disconnectCause == CLI_STATE_CONNECTED);
  return "$C{4}Timeouted$C{1}" if($disconnectCause == CLI_STATE_CONNECTION_LOST);
  return "$C{14}Disconnected$C{1}" if($disconnectCause == CLI_STATE_LEFT);
  return "$C{13}Kicked$C{1}" if($disconnectCause == CLI_STATE_KICKED);
  return "$C{6}Unknown$C{1}";
}

sub hSpadsCliPerf {
  my ($source,$user,$r_params,$checkOnly)=@_;

  my $includeDisconnectedClients;
  my $displaySysInfo=1;
  my $displayPerfs=1;
  my $targetFilter;
  foreach my $param (@{$r_params}) {
    my $lcParam=lc($param);
    if($lcParam eq '-a') {
      if($includeDisconnectedClients) {
        invalidSyntax($user,'cliPerf');
        return 0;
      }
      $includeDisconnectedClients=1;
      next;
    }
    if($lcParam eq '-s') {
      if(! $displaySysInfo || ! $displayPerfs) {
        invalidSyntax($user,'cliPerf');
        return 0;
      }
      $displayPerfs=0;
      next;
    }
    if($lcParam eq '-p') {
      if(! $displaySysInfo || ! $displayPerfs) {
        invalidSyntax($user,'cliPerf');
        return 0;
      }
      $displaySysInfo=0;
      next;
    }
    if(defined $targetFilter) {
      invalidSyntax($user,'cliPerf');
      return 0;
    }
    $targetFilter=$param;
  }

  my $springAutohostInterface=getSpringInterface();
  my $serverState=$springAutohostInterface->getState();
  if(! $serverState) {
    answer('Unable to retrieve client information, game is not running.');
    return 0;
  }

  my $r_players=$springAutohostInterface->getPlayersByNames();
  my @targets = keys %{$r_players};
  if(! @targets) {
    answer('Unable to retrieve client information, no client has connected to game server yet.');
    return 0;
  }

  if(! $includeDisconnectedClients) {
    @targets = grep {$r_players->{$_}{disconnectCause} <= CLI_STATE_CONNECTED} @targets;
    if(! @targets) {
      answer('Unable to retrieve client information, no client connected to game server (try using "-a" parameter)');
      return 0;
    }
  }

  if(defined $targetFilter) {
    my $r_targetPlayers=::cleverSearch($targetFilter,\@targets);
    @targets=@{$r_targetPlayers};
    if(! @targets) {
      answer('Unable to retrieve client information, no '.($includeDisconnectedClients ? '' : 'connected ')."client matching filter \"$targetFilter\"");
      return 0;
    }
  }

  return 1 if($checkOnly);

  my ($p_C,$B)=::initUserIrcColors($user);
  my %C=%{$p_C};

  my @displayedFields = map {"$C{5}$_$C{1}"}  (
    'Player','Status',
    $displaySysInfo ? ('OS','CPU (cores)','RAM','GPU','VRAM','Display mode') : (),
    $displayPerfs ? ('VRAM usage','Lua mem.','SimFrame (peak)','DrawFrame (peak)','FPS','Camera (angle/dist)','Lua Msgs') : (),
  );
  my $dataType;
  if($displaySysInfo) {
    if($displayPerfs) {
      $dataType='performance information';
    }else{
      $dataType='system information';
    }
  }else{
    $dataType='performance data';
  }
  
  my $self=getPlugin();

  my (@cliPerfRows,$r_perfDataLines);
  if(@targets == 1) {
    my $player=$targets[0];
    my $r_clientPerfs=$self->getClientData($player,$p_C,$B);
    $r_clientPerfs->{"$C{5}Status$C{1}"}=getClientStatusString($r_players->{$player}{disconnectCause},$p_C,$B);
    shift(@displayedFields);
    push(@cliPerfRows,{"$C{2}Information$C{1}" => $_, "$C{2}Value$C{1}" => $r_clientPerfs->{$_}})
        foreach(@displayedFields);
    $r_perfDataLines=formatArray(["$C{2}Information$C{1}","$C{2}Value$C{1}"],\@cliPerfRows,"$C{12}Client $dataType for $player$C{1}",100);
    $r_perfDataLines->[0]="\[ $C{12}Client $dataType for $player$C{1} ]"
        if($r_perfDataLines->[0] !~ /^\s*\[ /);
  }else{
    foreach my $player (sort @targets) {
      my $r_clientPerfs=$self->getClientData($player,$p_C,$B);
      $r_clientPerfs->{"$C{5}Status$C{1}"}=getClientStatusString($r_players->{$player}{disconnectCause},$p_C,$B);
      push(@cliPerfRows,$r_clientPerfs);
    }
    $r_perfDataLines=formatArray(\@displayedFields,\@cliPerfRows,"$C{12}Client $dataType$C{1}",50);
  }
  sayPrivate($user,$_)
      foreach(@{$r_perfDataLines});
}

1;

