package InGameMute;

use strict;

use Storable qw/nstore retrieve/;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.4';
my $requiredSpadsVersion='0.11.5';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'],
                           minLevelForMuteDuration => ['integer'] );
my %presetPluginParams;

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

sub getInstanceDir {
  return getSpadsConf()->{instanceDir} // getSpadsConf()->{varDir};
}

sub new {
  my $class=shift;
  my $self = { mutes => {},
               storeMutesTs => time,
               restoreForwardLobbyToGame => 0};
  bless($self,$class);
  my $mutesFile=getInstanceDir().'/InGameMute.dat';
  if(-f $mutesFile) {
    my $p_mutes=retrieve($mutesFile);
    if(! defined $p_mutes) {
      slog("Unable to read mute data from file ($mutesFile)",1);
    }else{
      $self->{mutes}=$p_mutes;
    }
  }
  addSpadsCommandHandler({mute => \&hSpadsMute,
                          mutes => \&hSpadsMutes,
                          unmute => \&hSpadsUnmute});
  addSpringCommandHandler({PLAYER_JOINED => \&hSpringPlayerJoined});
  if(getLobbyState() > 3) {
    addLobbyCommandHandler({SAIDBATTLE => \&hLobbyPreSaidBattle,
                            SAIDBATTLEEX => \&hLobbyPreSaidBattle},950);
    addLobbyCommandHandler({SAIDBATTLE => \&hLobbyPostSaidBattle,
                            SAIDBATTLEEX => \&hLobbyPostSaidBattle},1050);
  }
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onLobbyConnected {
  addLobbyCommandHandler({SAIDBATTLE => \&hLobbyPreSaidBattle,
                          SAIDBATTLEEX => \&hLobbyPreSaidBattle},950);
  addLobbyCommandHandler({SAIDBATTLE => \&hLobbyPostSaidBattle,
                          SAIDBATTLEEX => \&hLobbyPostSaidBattle},1050);
}

sub eventLoop {
  my $self=shift;
  my $p_spadsConf=getSpadsConf();
  if($p_spadsConf->{dataDumpDelay} && time-$self->{storeMutesTs} > 60 * $p_spadsConf->{dataDumpDelay}) {
    my $mutesFile=getInstanceDir().'/InGameMute.dat';
    slog("Unable to store mute data into file $mutesFile",1) unless(nstore($self->{mutes},$mutesFile));
    $self->{storeMutesTs}=time;
  }
  foreach my $filter (keys %{$self->{mutes}}) {
    if($self->{mutes}->{$filter}->{endTs} && time > $self->{mutes}->{$filter}->{endTs}) {
      delete $self->{mutes}->{$filter};
      applyUnmuteInGame($filter,'mute expired');
    }
  }
}

sub onUnload {
  my $self=shift;
  removeSpadsCommandHandler(['mute','mutes','unmute']);
  removeSpringCommandHandler(['PLAYER_JOINED']);
  removeLobbyCommandHandler(['SAIDBATTLE','SAIDBATTLEEX'],950);
  removeLobbyCommandHandler(['SAIDBATTLE','SAIDBATTLEEX'],1050);
  my $mutesFile=getInstanceDir().'/InGameMute.dat';
  slog("Unable to store mute data into file $mutesFile",1) unless(nstore($self->{mutes},$mutesFile));
  $self->{storeMutesTs}=time;
  slog("Plugin unloaded",3);
}

sub hSpadsMute {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if(! @{$p_params} || $#{$p_params} > 2) {
    invalidSyntax($user,'mute');
    return 0;
  }

  my ($mutedPlayer,$duration,$type)=@{$p_params};
  $duration=0 unless(defined $duration);
  if(! defined $type) {
    if(lc($duration) eq 'draw') {
      $duration=0;
      $type='draw';
    }elsif(lc($duration) eq 'chat') {
      $duration=0;
      $type='chat';
    }else{
      $type='full';
    }
  }

  my $minuteDuration=::convertBanDuration($duration);
  if($minuteDuration !~ /^\d+$/) {
    invalidSyntax($user,'mute','invalid mute duration');
    return 0;
  }

  if($minuteDuration != 0 && getUserAccessLevel($user) < getPluginConf()->{minLevelForMuteDuration}) {
    answer('You are not allowed to specify mute duration');
    return 0;
  };

  my $isInGame=0;
  my $p_mutedUsers=[];
  my $autohost=getSpringInterface();
  if($autohost->getState()) {
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my @players=keys %{$p_ahPlayers};
    $p_mutedUsers=::cleverSearch($mutedPlayer,\@players);
    if($#{$p_mutedUsers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$mutedPlayer\" in game");
      return 0;
    }elsif(@{$p_mutedUsers}) {
      $isInGame=1;
    }
  }
  my $lobby=getLobbyInterface();
  if(! @{$p_mutedUsers} && getLobbyState() > 5 && %{$lobby->{battle}}) {
    my @players=keys(%{$lobby->{battle}->{users}});
    $p_mutedUsers=::cleverSearch($mutedPlayer,\@players);
    if($#{$p_mutedUsers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$mutedPlayer\" in battle lobby");
      return 0;
    }
  }
  if(! @{$p_mutedUsers}) {
    my @players=keys(%{$lobby->{users}});
    $p_mutedUsers=::cleverSearch($mutedPlayer,\@players);
    if(! @{$p_mutedUsers}) {
      answer("Unable to mute \"$mutedPlayer\", user not found");
      return 0;
    }elsif($#{$p_mutedUsers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$mutedPlayer\" in lobby");
      return 0;
    }
  }
  $mutedPlayer=$p_mutedUsers->[0];

  if($mutedPlayer eq getSpadsConf()->{lobbyLogin}) {
    answer("Nice try ;)");
    return 0;
  }

  my $mutedPlayerLevel=getUserAccessLevel($mutedPlayer);
  my $p_endVoteLevels=getSpadsConfFull()->getCommandLevels('endvote','battle','player','stopped');
  if(exists $p_endVoteLevels->{directLevel} && $mutedPlayerLevel >= $p_endVoteLevels->{directLevel}) {
    answer("Unable to mute privileged user $mutedPlayer");
    return 0;
  }

  return "mute $mutedPlayer $duration" if($checkOnly);

  my $endMuteTs=0;
  $endMuteTs=time+($minuteDuration * 60) if($minuteDuration);
  my $muteFilter;
  my $accountId=::getLatestUserAccountId($mutedPlayer);
  if($accountId =~ /^\d+$/) {
    $muteFilter="\#$accountId";
  }else{
    $muteFilter=$mutedPlayer;
  }
  my $chatMute=$type ne 'draw' ? 1 : 0;
  my $drawMute=$type ne 'chat' ? 1 : 0;
  getPlugin()->{mutes}->{$muteFilter}={endTs => $endMuteTs,
                                       name => $mutedPlayer,
                                       draw => $drawMute,
                                       chat => $chatMute};

  my $muteDuration;
  if($minuteDuration) {
    $muteDuration=secToTime($minuteDuration * 60);
  }else{
    $muteDuration='one game';
  }

  answer("In-game mute added for $mutedPlayer (type: $type, duration: $muteDuration)") if($source eq 'pv');
  broadcastMsg("In-game mute added for $mutedPlayer by $user (type: $type, duration: $muteDuration)");
  $autohost->sendChatMessage("/mute $mutedPlayer $chatMute $drawMute") if($isInGame);
}

sub hSpadsMutes {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if(@{$p_params}) {
    invalidSyntax($user,'mutes');
    return 0;
  }
  return 1 if($checkOnly);
  my $self=getPlugin();
  if(! %{$self->{mutes}}) {
    sayPrivate($user,'No active mute.');
    return 1;
  }

  my ($p_C,$B)=::initUserIrcColors($user);
  my %C=%{$p_C};
  
  my @mutes;
  foreach my $muteFilter (keys %{$self->{mutes}}) {
    my $playerFilter=$muteFilter;
    $playerFilter.=" ($self->{mutes}->{$muteFilter}->{name})" if($playerFilter=~/^\#/);
    my $muteType='full';
    if(! $self->{mutes}->{$muteFilter}->{draw}) {
      $muteType='chat';
    }elsif(! $self->{mutes}->{$muteFilter}->{chat}) {
      $muteType='draw';
    }
    my $muteDuration;
    if($self->{mutes}->{$muteFilter}->{endTs}) {
      $muteDuration=localtime($self->{mutes}->{$muteFilter}->{endTs});
    }elsif(getSpringPid()) {
      $muteDuration='current game';
    }else{
      $muteDuration='next game';
    }
    push(@mutes,{"$C{5}Player$C{1}" => $playerFilter,
                 "$C{6}MuteType$C{1}" => $muteType,
                 "$C{6}MuteDuration$C{1}" => $muteDuration});
  }
  my @fields=("$C{5}Player$C{1}","$C{6}MuteType$C{1}","$C{6}MuteDuration$C{1}");
  my $p_muteLines=formatArray(\@fields,\@mutes,'Muted player'.($#mutes > 0 ? 's' : ''));
  sayPrivate($user,'.');
  foreach my $muteLine (@{$p_muteLines}) {
    sayPrivate($user,$muteLine);
  }
}

sub hSpadsUnmute {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,'unmute');
    return 0;
  }

  my $self=getPlugin();
  my %mutedPlayers;
  foreach my $muteFilter (keys %{$self->{mutes}}) {
    $mutedPlayers{$self->{mutes}->{$muteFilter}->{name}}=$muteFilter;
  }
  my @mutedPlayersNames=keys %mutedPlayers;

  my $p_matchingPlayers=::cleverSearch($p_params->[0],\@mutedPlayersNames);
  if($#{$p_matchingPlayers} > 0) {
    answer("Ambiguous command, multiple matches found for muted player \"$p_params->[0]\"");
    return 0;
  }
  if(! @{$p_matchingPlayers}) {
    answer("Unable to find muted player matching \"$p_params->[0]\"");
    return 0;
  }

  my $unmutedPlayer=$p_matchingPlayers->[0];
  return "unmute $unmutedPlayer" if($checkOnly);

  my $removedFilter=$mutedPlayers{$unmutedPlayer};
  delete $self->{mutes}->{$removedFilter};
  
  answer("In-game mute removed for $unmutedPlayer") if($source eq 'pv');
  broadcastMsg("In-game mute removed for $unmutedPlayer by $user");
  applyUnmuteInGame($removedFilter);
}

sub applyUnmuteInGame {
  my ($removedFilter,$reason)=@_;
  my $autohost=getSpringInterface();
  if($autohost->getState()) {
    my $p_ahPlayers=$autohost->getPlayersByNames();
    if($removedFilter =~ /^\#(\d+)$/) {
      my $unmutedId=$1;
      foreach my $ahPlayer (keys %{$p_ahPlayers}) {
        if(::getLatestUserAccountId($ahPlayer) eq $unmutedId) {
          $autohost->sendChatMessage("/mute $ahPlayer 0 0");
          $autohost->sendChatMessage(getSpadsConf()->{lobbyLogin}." * $ahPlayer is no longer muted ($reason)") if(defined $reason);
        }
      }
    }elsif(exists $p_ahPlayers->{$removedFilter}) {
      $autohost->sendChatMessage("/mute $removedFilter 0 0");
      $autohost->sendChatMessage(getSpadsConf()->{lobbyLogin}." * $removedFilter is no longer muted ($reason)") if(defined $reason);
    }
  }
}

sub getUserMuteData {
  my ($self,$user)=@_;
  my $accountId=::getLatestUserAccountId($user);
  my $r_muteData;
  if($accountId =~ /^\d+$/ && exists $self->{mutes}{"\#$accountId"}) {
    $r_muteData=$self->{mutes}{"\#$accountId"};
  }elsif(exists $self->{mutes}{$user}) {
    $r_muteData=$self->{mutes}{$user};
  }
  return $r_muteData;
}

sub hLobbyPreSaidBattle {
  my (undef,$user,$msg)=@_;
  return if($msg =~ /^!\w/);
  my $r_conf=getSpadsConf();
  return unless($r_conf->{forwardLobbyToGame});
  my $self=getPlugin();
  my $r_muteData=$self->getUserMuteData($user);
  if(defined $r_muteData && $r_muteData->{chat}) {
    $self->{restoreForwardLobbyToGame}=$r_conf->{forwardLobbyToGame};
    $r_conf->{forwardLobbyToGame}=0;
  }
}

sub hLobbyPostSaidBattle {
  my (undef,$user)=@_;
  my $self=getPlugin();
  return unless($self->{restoreForwardLobbyToGame});
  my $r_conf=getSpadsConf();
  $r_conf->{forwardLobbyToGame}=$self->{restoreForwardLobbyToGame};
  $self->{restoreForwardLobbyToGame}=0;
}

sub preSpadsCommand {
  my ($self,$command,undef,$user)=@_;
  return 1 unless($command eq 'say');
  my $r_muteData=$self->getUserMuteData($user);
  return 0 if(defined $r_muteData && $r_muteData->{chat});
  return 1;
}

sub hSpringPlayerJoined {
  my (undef,undef,$name)=@_;
  my $self=getPlugin();
  my $r_muteData=$self->getUserMuteData($name);
  if(defined $r_muteData) {
    my $autohost=getSpringInterface();
    my $muteDetailString='chat messages and drawing ignored';
    if($r_muteData->{chat} && ! $r_muteData->{draw}) {
      $muteDetailString='chat messages ignored';
    }elsif(! $r_muteData->{chat} && $r_muteData->{draw}) {
      $muteDetailString='drawing ignored';
    }
    $autohost->sendChatMessage(getSpadsConf()->{lobbyLogin}." * $name is muted ($muteDetailString)");
    $autohost->sendChatMessage("/mute $name $r_muteData->{chat} $r_muteData->{draw}");
  }
}

sub onSpringStop {
  my $self=shift;
  foreach my $filter (keys %{$self->{mutes}}) {
    delete $self->{mutes}->{$filter} if($self->{mutes}->{$filter}->{endTs} == 0);
  }
}

1;
