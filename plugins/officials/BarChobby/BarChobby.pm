# BarChobby (Perl module)
#
# SPADS plugin implementing the Beyond All Reason Chobby specific lobby protocol
# extension for SPADS settings visualization in battle lobby.
#
# Copyright (C) 2024  Yann Riou <yaribzh@gmail.com>
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

package BarChobby;

use strict;

use JSON::PP qw'encode_json decode_json';
use List::Util qw'all none any';

use SpadsPluginApi;

my $pluginVersion='0.11';
my $requiredSpadsVersion='0.11.5';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'],
                           sayBattleMulticastFallback => ['notNull'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

use constant { CHOBBY_MSG_PREFIX => '* BarManager|' };

my @MONITORED_SETTINGS=(qw'teamSize nbTeams preset autoBalance balanceMode');

sub new {
  my $class=shift;
  my $lobby=getLobbyInterface();
  if(! exists $lobby->{protocolExtensions}) {
    slog('SpringLobbyInterface module version 0.51 or greater is required, aborting plugin load',2);
    return undef;
  }
  my $self = {
    sentState => {},
    aiProfiles => {},
  };
  bless($self,$class);
  onReloadConf($self);
  addSpadsCommandHandler({aiProfile => \&hSpadsAiProfile});
  onLobbyConnected($self,$lobby) if(getLobbyState() > 3);
  addTimer('CheckBattleState',0.5,0.5,\&checkBattleState);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onReloadConf {
  my $self=shift;
  my $sayBattleMulticastFallback=getPluginConf()->{sayBattleMulticastFallback};
  if(none {$sayBattleMulticastFallback eq $_} (qw'disabled broadcast unicast')) {
    slog("Invalid value \"$sayBattleMulticastFallback\" for sayBattleMulticastFallback plugin setting",1);
    return 0;
  }
  return 1;
}

sub onLobbyConnected {
  my ($self,$lobby)=@_;
  addLobbyCommandHandler({REMOVEBOT => \&hLobbyRemoveBot});
  return if($lobby->{protocolExtensions}{'sayBattlePrivate:multicast'});
  my $sayBattleMulticastFallback=getPluginConf()->{sayBattleMulticastFallback};
  slog('Lobby server does NOT support multicast for SAYBATTLEPRIVATE commands, battleroom protocol extensions for Chobby will '.
       ($sayBattleMulticastFallback eq 'disabled' ? 'be disabled' : 'use '.$sayBattleMulticastFallback),2);
}

sub isChobbyClient { length($_[0]) > 15 && substr($_[0],0,16) eq 'LuaLobby Chobby:' }

sub checkBattleState {
  return unless(getLobbyState() > 5);
  my $lobby=getLobbyInterface();
  my $sayBattleMulticastFallback=getPluginConf()->{sayBattleMulticastFallback};
  return unless(%{$lobby->{battle}} && ($lobby->{protocolExtensions}{'sayBattlePrivate:multicast'} || $sayBattleMulticastFallback ne 'disabled'));
  my $r_spadsConf=getSpadsConf();
  my %battleState = map {$_ => "$r_spadsConf->{$_}"} @MONITORED_SETTINGS;
  $battleState{locked} = $lobby->{battles}{$lobby->{battle}{battleId}}{locked} ? 'locked' : 'unlocked';
  my $r_bosses=getBosses();
  $battleState{boss}=(sort keys %{$r_bosses})[0]//'';
  my $self=getPlugin();
  return 0 if(%{$self->{sentState}} && (all {$self->{sentState}{$_} eq $battleState{$_}} (keys %battleState)));
  my @chobbyBattleUsers=grep {isChobbyClient($lobby->{users}{$_}{lobbyClient})} (keys %{$lobby->{battle}{users}});
  if(@chobbyBattleUsers) {
    my $msgPayload=CHOBBY_MSG_PREFIX.encode_json({BattleStateChanged => \%battleState});
    if(@chobbyBattleUsers == %{$lobby->{battle}{users}} - 1 || (! $lobby->{protocolExtensions}{'sayBattlePrivate:multicast'} && $sayBattleMulticastFallback eq 'broadcast')) {
      queueLobbyCommand(['SAYBATTLEEX',$msgPayload]);
    }elsif($lobby->{protocolExtensions}{'sayBattlePrivate:multicast'}) {
      queueLobbyCommand(['SAYBATTLEPRIVATEEX',join(',',@chobbyBattleUsers),$msgPayload]);
    }else{
      map {queueLobbyCommand(['SAYBATTLEPRIVATEEX',$_,$msgPayload])} @chobbyBattleUsers;
    }
  }
  $self->{sentState}=\%battleState;
  return 1;
}

sub onJoinedBattle {
  my ($self,$user)=@_;
  return unless(getLobbyState() > 5);
  my $lobby=getLobbyInterface();
  return unless(%{$lobby->{battle}}
                && ($lobby->{protocolExtensions}{'sayBattlePrivate:multicast'} || getPluginConf()->{sayBattleMulticastFallback} ne 'disabled')
                && exists $lobby->{battle}{users}{$user}
                && isChobbyClient($lobby->{users}{$user}{lobbyClient}));
  return if(checkBattleState());
  queueLobbyCommand(['SAYBATTLEPRIVATEEX',$user,CHOBBY_MSG_PREFIX.encode_json({BattleStateChanged => $self->{sentState}})]);
}

sub addStartScriptTags {
  my ($self,$r_addStartData)=@_;
  $r_addStartData->{aiData}{$_}{options}=$self->{aiProfiles}{$_} foreach(keys %{$self->{aiProfiles}});
}

sub hSpadsAiProfile {
  my ($source,$user,$r_params,$checkOnly)=@_;

  my @params=@{$r_params};
  if(@params < 2) {
    invalidSyntax($user,'aiprofile');
    return 0;
  }

  if(getLobbyState() < 6) {
    answer('Cannot configure AI bot when battle lobby is closed');
    return 0;
  }

  my $botName=shift(@params);
  my $r_battle=getLobbyInterface()->getBattle();
  if(! exists $r_battle->{bots}{$botName}) {
    answer("Cannot configure AI bot \"$botName\": AI bot not found");
    return 0;
  }

  my $botOwner=$r_battle->{bots}{$botName}{owner};
  if($user ne $botOwner) {
    answer("$user is not allowed to configure AI bot \"$botName\" (owner is $botOwner)");
    return 0;
  }

  my $r_aiProfile = eval { decode_json(join(' ',@params)) };
  if(ref $r_aiProfile ne 'HASH'
     || ! %{$r_aiProfile}
     || keys %{$r_aiProfile} > 20
     || (any {$_ !~ /^\w{1,20}$/
              || ! defined $r_aiProfile->{$_}
              || ref $r_aiProfile->{$_} ne ''
              || $r_aiProfile->{$_} !~ /^[^\;\"\'\cm\cJ]{0,100}$/} (keys %{$r_aiProfile}))) {
    answer("Failed to configure AI bot \"$botName\": invalid JSON data");
    return 0;
  }

  return 1 if($checkOnly);

  getPlugin()->{aiProfiles}{$botName}=$r_aiProfile;
  sayBattle("AI $botName options are set to ".join(', ',map {"$_: \"$r_aiProfile->{$_}\""} (sort keys %{$r_aiProfile})));
}

sub hLobbyRemoveBot {delete getPlugin()->{aiProfiles}{$_[2]} }
sub onBattleOpened { $_[0]{aiProfiles}={} }
sub onBattleClosed { $_[0]{aiProfiles}={} }

sub onUnload {
  removeSpadsCommandHandler(['aiProfile']);
  removeLobbyCommandHandler(['REMOVEBOT']);
  removeTimer('CheckBattleState');
  slog('Plugin unloaded',3);
}

1;
