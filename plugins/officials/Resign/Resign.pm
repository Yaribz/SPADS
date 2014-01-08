package Resign;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.2';
my $requiredSpadsVersion='0.11.18';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
my %presetPluginParams;

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  addSpadsCommandHandler({resign => \&hSpadsResign});
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  removeSpadsCommandHandler(['resign']);
  slog("Plugin unloaded",3);
}

sub isNotAllowedToVote {
  my ($user,$resignedPlayer)=@_;
  my $autohost=getSpringInterface();
  return 1 unless($autohost->getState() == 2);
  my $p_runningBattle=getRunningBattle();
  return 2 unless(exists $p_runningBattle->{users}->{$user}
                  && defined $p_runningBattle->{users}->{$user}->{battleStatus}
                  && $p_runningBattle->{users}->{$user}->{battleStatus}->{mode});
  return 3 unless($p_runningBattle->{users}->{$user}->{battleStatus}->{team} == $p_runningBattle->{users}->{$resignedPlayer}->{battleStatus}->{team});
  my $p_ahPlayer=$autohost->getPlayer($user);
  return 4 unless(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1);
  return 5 if($p_ahPlayer->{lost});
  return 0;
}

sub hSpadsResign {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $autohost=getSpringInterface();
  my $ahState=$autohost->getState();
  if($ahState != 2) {
    my $reason='game is not running';
    if($ahState == 1) {
      $reason='game has not started yet';
    }elsif($ahState == 3) {
      $reason='game is already over';
    }
    answer("Unable to resign, $reason!");
    return 0;
  }

  my ($resignedPlayer,$isTeamResign);
  if($#{$p_params} == -1) {
    ($resignedPlayer,$isTeamResign)=($user,1);
  }elsif($#{$p_params} == 0) {
    ($resignedPlayer,$isTeamResign)=($p_params->[0],0);
  }elsif($#{$p_params} == 1) {
    if($p_params->[1] !~ /^team$/i) {
      invalidSyntax($user,'resign');
      return 0;
    }
    ($resignedPlayer,$isTeamResign)=($p_params->[0],1);
  }else{
    invalidSyntax($user,'resign');
    return 0;
  }

  my $p_runningBattle=getRunningBattle();
  my @bPlayers=grep {defined $p_runningBattle->{users}->{$_}->{battleStatus} && $p_runningBattle->{users}->{$_}->{battleStatus}->{mode}} (keys %{$p_runningBattle->{users}});

  if($#{$p_params} == -1) {
    if(! grep {$resignedPlayer eq $_} @bPlayers) {
      answer('Only players are allowed to resign!');
      return 0;
    }
  }else{
    my $p_playerFound=::cleverSearch($resignedPlayer,\@bPlayers);
    if(! @{$p_playerFound}) {
      answer("Unable to resign \"$resignedPlayer\", player not found!");
      return 0;
    }elsif($#{$p_playerFound} > 0) {
      answer("Unable to resign \"$resignedPlayer\", ambiguous command! (multiple matches)");
      return 0;
    }
    $resignedPlayer=$p_playerFound->[0];
  }

  if($checkOnly) {
    my $notAllowed=isNotAllowedToVote($user,$resignedPlayer);
    if($notAllowed) {
      if($notAllowed == 2) {
        answer("Only players are allowed to vote for resign!");
      }elsif($notAllowed == 3) {
        answer("Only the players from same team are allowed to vote for resign!");
      }elsif($notAllowed == 4) {
        answer("Only connected players are allowed to vote for resign!");
      }elsif($notAllowed == 5) {
        answer("Only the players who havn't lost yet are allowed to vote for resign!");
      }
      return 0;
    }
  }

  my @playersToResign;
  if($isTeamResign) {
    my @resignablePlayers;
    foreach my $bPlayer (@bPlayers) {
      my $p_ahPlayer=$autohost->getPlayer($bPlayer);
      push(@resignablePlayers,$bPlayer) if(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1 && $p_ahPlayer->{lost} == 0);
    }
    @playersToResign=grep {$p_runningBattle->{users}->{$_}->{battleStatus}->{team} == $p_runningBattle->{users}->{$resignedPlayer}->{battleStatus}->{team}} @resignablePlayers;
    if(! @playersToResign) {
      answer("Unable to resign ally team of $resignedPlayer, no resignable player found!");
      return 0;
    }
  }else{
    my $p_ahPlayer=$autohost->getPlayer($resignedPlayer);
    if(! %{$p_ahPlayer} || $p_ahPlayer->{disconnectCause} != -1) {
      answer("Unable to resign $resignedPlayer, player not connected!");
      return 0;
    }
    if($p_ahPlayer->{lost}) {
      answer("Unable to resign $resignedPlayer, player has already lost!");
      return 0;
    }
    @playersToResign=($resignedPlayer);
  }

  if($p_runningBattle->{engineVersion} =~ /^(\d+)/ && $1 < 92 && ! isZkMod($p_runningBattle->{mod})) {
    answer('The resign command requires Spring engine version 92 or later!');
    return 0;
  }

  return "resign $resignedPlayer".($isTeamResign?' TEAM':'') if($checkOnly);

  foreach my $playerToResign (@playersToResign) {
    if($p_runningBattle->{engineVersion} =~ /^(\d+)/ && $1 < 92) {
      $autohost->sendChatMessage("/luarules resignteam $playerToResign");
    }else{
      $autohost->sendChatMessage('/specbynum '.($autohost->getPlayer($playerToResign)->{playerNb}));
    }
  }

  if($#playersToResign > 0) {
    sayBattleAndGame('Resigned '.($#playersToResign+1)." players (by $user)");
  }else{
    sayBattleAndGame("Resigned player $playersToResign[0] (by $user)");
  }
}

sub onVoteRequest {
  my ($self,$source,$user,$p_command,$p_remainingVoters)=@_;
  return 1 unless($p_command->[0] eq 'resign');
  foreach my $remainingVoter (keys %{$p_remainingVoters}) {
    delete($p_remainingVoters->{$remainingVoter}) if(isNotAllowedToVote($remainingVoter,$p_command->[1]));
  }
  return 1;
}

sub isZkMod { return index($_[0],'Zero-K') != -1; }

1;
