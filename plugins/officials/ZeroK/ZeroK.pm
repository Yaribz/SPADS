package ZeroK;

use strict;

use List::Util 'sum';

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.6';
my $requiredSpadsVersion='0.11.20';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
my %presetPluginParams = ( useZkLobbyCpuValue => ['bool2'],
                           handleClans => ['bool'],
                           showClanInStatus => ['bool'],
                           showLevelInStatus => ['bool'],
                           showEloInStatus => ['bool'],
                           addStartScriptTags => ['bool'],
                           useRecommendedMaps => ['bool'],
                           useRecommendedBoxes => ['bool2'],
                           eloBalanceMode => ['bool2'],
                           submitBattleResults => ['bool'],
                           battleDescription => [],
                           minElo => ['integer','integerRange','null'],
                           maxElo => ['integer','integerRange','null'],
                           minLevel => ['integer','integerRange','null'],
                           maxLevel => ['integer','integerRange','null'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }
sub getDependencies { return ('SpringieExtension'); }

sub new {
  my $class=shift;
  my $self = { isCheating => 0,
               extraDataAccepted => [],
               extraDataReceived => {},
               forceSpecTimestamps => {} };
  bless($self,$class);

  addSpadsCommandHandler({predict => \&hSpadsPredict});

  if(getLobbyState() > 3) {
    addLobbyCommandHandler({CLIENTBATTLESTATUS => \&hLobbyClientBattleStatus,
                            LEFTBATTLE => \&hLobbyLeftBattle});
    checkAllSkillLimit($self);
  }
  addSpringCommandHandler({ PLAYER_CHAT => \&hSpringPlayerChat });
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onLobbyConnected {
  addLobbyCommandHandler({CLIENTBATTLESTATUS => \&hLobbyClientBattleStatus,
                          LEFTBATTLE => \&hLobbyLeftBattle});
}

sub onUnload {
  removeLobbyCommandHandler(['CLIENTBATTLESTATUS','LEFTBATTLE']);
  removeSpringCommandHandler(['PLAYER_CHAT']);
  removeSpadsCommandHandler(['predict']);
  slog("Plugin unloaded",3);
}

sub hSpadsPredict {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if(@{$p_params}) {
    invalidSyntax($user,'predict');
    return 0;
  }

  if(! getPluginConf()->{eloBalanceMode}) {
    answer('The !predict command is only available when Elo balance mode is enabled');
    return 0;
  }

  if(getLobbyState() < 6) {
    answer('Unable to predict chances of victory, battle is closed!');
    return 0;
  }

  my $lobby=getLobbyInterface();
  if(! isZkMod($lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod})) {
    answer('The !predict command is only available for Zero-K!');
    return 0;
  }

  if(%{$lobby->{battle}->{bots}}) {
    answer('Unable to predict chances of victory when AI bots are in battle!');
    return 0;
  }

  my $springieExt=getPlugin('SpringieExtension');

  my %teamsElos;
  my $p_bUsers=$lobby->{battle}->{users};
  foreach my $bUser (keys %{$p_bUsers}) {
    next unless(defined $p_bUsers->{$bUser}->{battleStatus} && $p_bUsers->{$bUser}->{battleStatus}->{mode});
    if(exists $springieExt->{userExt}->{$bUser} && exists $springieExt->{userExt}->{$bUser}->{EffectiveElo}) {
      my $team=$p_bUsers->{$bUser}->{battleStatus}->{team};
      $teamsElos{$team}=[] unless(exists $teamsElos{$team});
      push(@{$teamsElos{$team}},$springieExt->{userExt}->{$bUser}->{EffectiveElo});
    }else{
      answer("Unable to predict chances of victory, Elo data missing for player $bUser!");
      return 0;
    }
  }
  if(keys %teamsElos < 2) {
    answer('Unable to predict chances of victory, not enough teams in battle!');
    return 0;
  }

  return 1 if($checkOnly);

  my $maxTeamSize=0;
  foreach my $team (keys %teamsElos) {
    $maxTeamSize = $#{$teamsElos{$team}}+1 if($#{$teamsElos{$team}}+1 > $maxTeamSize);
  }

  my %teamsAvgElo;
  foreach my $team (keys %teamsElos) {
    $teamsAvgElo{$team}=sum(@{$teamsElos{$team}})/$maxTeamSize;
  }

  my @sortedTeams=sort {$teamsAvgElo{$b} <=> $teamsAvgElo{$a}} (keys %teamsAvgElo);
  my $bestTeam=shift(@sortedTeams);

  my $predictMsg='Team '.($bestTeam+1).' has ';
  my @predictStrings;
  foreach my $team (@sortedTeams) {
    my $chancesToWin=int(100/(1+10**(($teamsAvgElo{$team}-$teamsAvgElo{$bestTeam})/400))+0.5);
    push(@predictStrings,"$chancesToWin% chance to win over team ".($team+1));
  }
  $predictMsg.=join(', ',@predictStrings);
  answer($predictMsg);
}

sub hLobbyClientBattleStatus {
  my (undef,$user)=@_;
  checkSkillLimit($user);
}

sub hLobbyLeftBattle {
  my (undef,$battleId,$user)=@_;
  my $lobby=getLobbyInterface();
  if(%{$lobby->{battle}} && $battleId == $lobby->{battle}->{battleId}) {
    my $self=getPlugin();
    delete $self->{forceSpecTimestamps}->{$user};
  }
}

sub forceCpuSpeedValue {
  my $useZkLobbyCpuValue=getPluginConf()->{useZkLobbyCpuValue};
  return undef unless($useZkLobbyCpuValue);
  if($useZkLobbyCpuValue == 1) {
    if($^O eq 'MSWin32') {
      return 6667;
    }else{
      return 6668;
    }
  }else{
    return 6666;
  }
}

sub onJoinBattleRequest {
  my (undef,$user)=@_;
  return 0 unless(getPluginConf()->{handleClans});
  my $springieExt=getPlugin('SpringieExtension');
  if(exists $springieExt->{userExt}->{$user}) {
    my $p_userExt=$springieExt->{userExt}->{$user};
    ::setUserPref($user,'clan',$p_userExt->{Clan}) if(exists $p_userExt->{Clan} && $p_userExt->{Clan} ne '');
  }
  return 0;
}

sub updateStatusInfo {
  my (undef,$p_playerStatus,$accountId)=@_;
  my $lobby=getLobbyInterface();
  return [] unless(exists $lobby->{accounts}->{$accountId});
  my $p_conf=getPluginConf();
  my $user=$lobby->{accounts}->{$accountId};
  my $springieExt=getPlugin('SpringieExtension');
  if(exists $springieExt->{userExt}->{$user}) {
    my $p_userExt=$springieExt->{userExt}->{$user};
    $p_playerStatus->{'Clan (ZK)'}=$p_userExt->{Clan} if($p_conf->{showClanInStatus} && exists $p_userExt->{Clan});
    $p_playerStatus->{'Level (ZK)'}=$p_userExt->{Level} if($p_conf->{showLevelInStatus} && exists $p_userExt->{Level});
    $p_playerStatus->{'Elo (ZK)'}=$p_userExt->{EffectiveElo} if($p_conf->{showEloInStatus} && exists $p_userExt->{EffectiveElo});
  }
  my @customColumns;
  push(@customColumns,'Clan (ZK)') if($p_conf->{showClanInStatus});
  push(@customColumns,'Level (ZK)') if($p_conf->{showLevelInStatus});
  push(@customColumns,'Elo (ZK)') if($p_conf->{showEloInStatus});
  return \@customColumns;
}

sub addStartScriptTags {
  my (undef,$p_additionalData)=@_;
  return unless(getPluginConf()->{addStartScriptTags});

  my $lobby=getLobbyInterface();
  return unless(isZkMod($lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod}));

  my (@players,@specs);
  my $p_bUsers=$lobby->{battle}->{users};
  foreach my $bUser (keys %{$p_bUsers}) {
    next unless(exists $lobby->{users}->{$bUser} && exists $lobby->{users}->{$bUser}->{accountId} && $lobby->{users}->{$bUser}->{accountId});
    my $id=$lobby->{users}->{$bUser}->{accountId};
    if(defined $p_bUsers->{$bUser}->{battleStatus} && $p_bUsers->{$bUser}->{battleStatus}->{mode}) {
      push(@players,$id);
    }else{
      push(@specs,$id);
    }
  }
  my $p_addData=getPlugin('SpringieExtension')->GetSpringBattleStartSetup(\@players,\@specs);
  foreach my $key (keys %{$p_addData}) {
    if($key eq 'playerData') {
      foreach my $id (keys %{$p_addData->{playerData}}) {
        $p_additionalData->{playerData}->{$id}={} unless(exists $p_additionalData->{playerData}->{$id});
        foreach my $userDataKey (keys %{$p_addData->{playerData}->{$id}}) {
          $p_additionalData->{playerData}->{$id}->{$userDataKey}=$p_addData->{playerData}->{$id}->{$userDataKey};
        }
      }
    }else{
      $p_additionalData->{$key}=$p_addData->{$key};
    }
  }
}

sub filterRotationMaps {
  my (undef,$p_rotationMaps)=@_;
  return $p_rotationMaps unless(getLobbyState() > 5 && getPluginConf()->{useRecommendedMaps});

  my $nbEntities;
  my $lobby=getLobbyInterface();
  my $p_bUsers=$lobby->{battle}->{users};
  foreach my $bUser (keys %{$p_bUsers}) {
    ++$nbEntities if(defined $p_bUsers->{$bUser}->{battleStatus} && $p_bUsers->{$bUser}->{battleStatus}->{mode});
  }
  my @bots=keys %{$lobby->{battle}->{bots}};
  $nbEntities+=$#bots+1;
  my $recommendedMap=getPlugin('SpringieExtension')->GetRecommendedMap($nbEntities);
  if(! defined $recommendedMap) {
    slog("Unable to find a recommended map through SpringieService/GetRecommendedMap web service",2);
    return $p_rotationMaps;
  }
  my $p_spadsConf=getSpadsConf();
  if($recommendedMap eq $p_spadsConf->{map}) {
    slog("Ignoring map recommended by SpringieService/GetRecommendedMap web service (same as current map)",5);
    return $p_rotationMaps;
  }

  my $mapIsAllowed=0;
  my $spads=getSpadsConfFull();
  foreach my $mapNb (keys %{$spads->{maps}}) {
    if($spads->{maps}->{$mapNb} eq $recommendedMap) {
      $mapIsAllowed=1;
      last;
    }
  }
  if(! $mapIsAllowed) {
    $mapIsAllowed=1 if($p_spadsConf->{allowGhostMaps} && getSpringServerType() eq 'dedicated' && exists $spads->{ghostMaps}->{$recommendedMap});
  }
  if(! $mapIsAllowed) {
    slog("Ignoring map \"$recommendedMap\" recommended by SpringieService/GetRecommendedMap web service (not in current map list)",4);
    return $p_rotationMaps;
  }

  return [$p_spadsConf->{map},$recommendedMap];
}

sub updatePlayerSkill {
  my (undef,$p_playerSkill,$accountId,$modName)=@_;
  my $lobby=getLobbyInterface();
  checkSkillLimit($lobby->{accounts}->{$accountId}) if(getLobbyState() > 5 && exists $lobby->{accounts}->{$accountId});

  return 0 unless(getPluginConf()->{eloBalanceMode} == 1);

  return 0 unless(exists $lobby->{accounts}->{$accountId});

  return 0 if(getLobbyState() > 5 && ! isZkMod($modName));

  my $user=$lobby->{accounts}->{$accountId};
  my $springieExt=getPlugin('SpringieExtension');
  return 0 unless(exists $springieExt->{userExt}->{$user});

  my $p_userExt=$springieExt->{userExt}->{$user};
  return 0 unless(exists $p_userExt->{EffectiveElo} && $p_userExt->{EffectiveElo} =~ /^\d+$/);

  $p_playerSkill->{skill}=$p_userExt->{EffectiveElo}*2/100-5;
  return 1;
}

sub balanceBattle {
  my (undef,$p_players)=@_;
  return undef unless(getPluginConf()->{eloBalanceMode} == 2);

  my $lobby=getLobbyInterface();
  return undef if(getLobbyState() > 5 && ! isZkMod($lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod}));

  my $springieExt=getPlugin('SpringieExtension');
  foreach my $user (keys %{$p_players}) {
    next unless(exists $springieExt->{userExt}->{$user});
    my $p_userExt=$springieExt->{userExt}->{$user};
    next unless(exists $p_userExt->{EffectiveElo} && $p_userExt->{EffectiveElo} =~ /^\d+$/);
    $p_players->{$user}->{skill}=$p_userExt->{EffectiveElo}*2/100-5;
  }

  return undef;
}

sub onSpringStart {
  my $self=shift;
  $self->{isCheating}=0;
  $self->{extraDataAccepted}=[];
  $self->{extraDataReceived}={};
}

sub postSpadsCommand {
  my ($self,$command,undef,undef,undef,$commandResult)=@_;
  $self->{isCheating}=1 if($command eq 'cheat' && (! defined $commandResult || $commandResult ne '0'));
}

sub hSpringPlayerChat {
  my (undef,undef,$dest,$msg)=@_;
  return unless($dest eq '255');
  my $springieMsg;
  if($msg =~ /^SPRINGIE:(.+)$/) {
    $springieMsg=$1;
  }else{
    return;
  }
  my $self=getPlugin();
  if(exists $self->{extraDataReceived}->{$springieMsg}) {
    ++$self->{extraDataReceived}->{$springieMsg};
  }else{
    $self->{extraDataReceived}->{$springieMsg}=1;
  }
  if($self->{extraDataReceived}->{$springieMsg} == 2) {
    push(@{$self->{extraDataAccepted}},$springieMsg);
    getSpringInterface()->sendChatMessage("/forcestart") if($springieMsg eq 'FORCE');
  }
}

sub onGameEnd {
  my ($self,$p_endGameData)=@_;

  my $p_conf=getPluginConf();
  return unless( $p_conf->{submitBattleResults} == 1
                 && isZkMod($p_endGameData->{mod})
                 && ! $self->{isCheating}
                 && $p_endGameData->{startPlayingTimestamp}
                 && $p_endGameData->{result} ne 'undecided'
                 && $p_endGameData->{type} ne 'Solo' );

  my $description;
  $description=$p_conf->{battleDescription} unless($p_conf->{battleDescription} eq '');
  my $battleResultMsg=getPlugin('SpringieExtension')->SubmitSpringBattleResultFromEndGameData($p_endGameData,$self->{extraDataAccepted},$description);
  if(! defined $battleResultMsg) {
    slog('Unable to submit battle result through SpringieService/SubmitSpringBattleResult web service',1);
    return;
  }
  my @battleResultMsgs=split(/\n/,$battleResultMsg);
  foreach my $msg (@battleResultMsgs) {
    sayBattle($msg);
  }
}

sub setMapStartBoxes {
  my ($self,$p_boxes,$mapName)=@_;
  my $p_conf=getPluginConf();
  return 0 unless($p_conf->{useRecommendedBoxes});
  return 0 if(@{$p_boxes} && $p_conf->{useRecommendedBoxes} == 2);
  my $mapCommandsString=getPlugin('SpringieExtension')->GetMapCommands($mapName);
  return 0 unless(defined $mapCommandsString);
  my @mapCommands=split(/\n/,$mapCommandsString);
  my $firstBox=1;
  foreach my $mapCommand (@mapCommands) {
    if($mapCommand =~ /^\!addbox (\d+) (\d+) (\d+) (\d+)/) {
      my %springieCoor=(left => $1,
                        top => $2,
                        width => $3,
                        height => $4);
      my %coor=(left => 2*$springieCoor{left},
                top => 2*$springieCoor{top});
      $coor{right}=$coor{left}+2*$springieCoor{width};
      $coor{bottom}=$coor{top}+2*$springieCoor{height};
      foreach my $c (keys %coor) {
        if($coor{$c} > 200) {
          slog("Invalid $c coordinate received from SpringieService/GetMapCommands web service for map $mapName",2);
          $coor{$c}=200;
        }
      }
      if($firstBox) {
        $firstBox=0;
        $#{$p_boxes}=-1;
      }
      push(@{$p_boxes},"$coor{left} $coor{top} $coor{right} $coor{bottom}");
    }elsif($mapCommand =~ /^\!split ([hv] \d+)$/) {
      push(@{$p_boxes},$1);
    }
  }
  return 0;
}

sub setInGameVoteMsg {
  my ($reqYesVotes,$reqNoVotes)=($_[2],$_[4]);
  return undef unless(getSpringInterface()->getState());
  return undef unless(isZkMod(getRunningBattle()->{mod}));
  my $p_currentVote=getCurrentVote();
  my $remainingTime=$p_currentVote->{expireTime} - time;
  my $votedCommand=join(' ',@{$p_currentVote->{command}});
  return "Poll: \"$votedCommand\" ? [!y=$p_currentVote->{yesCount}/$reqYesVotes, !n=$p_currentVote->{noCount}/$reqNoVotes] (${remainingTime}s remaining)";
}

sub onVoteStart {
  return unless(getSpringInterface()->getState());
  return unless(isZkMod(getRunningBattle()->{mod}));
  my (undef,$inGameVoteMsg)=::getVoteStateMsg();
  sayGame($inGameVoteMsg) if(defined $inGameVoteMsg);
}

sub onVoteStop {
  my (undef,$voteResult)=@_;
  return unless(getSpringInterface()->getState());
  return unless(isZkMod(getRunningBattle()->{mod}));
  if($voteResult > 0) {
    sayGame('Poll [END:SUCCESS]');
  }else{
    sayGame('Poll [END:FAILED]');
  }
}

sub onBattleClosed {
  my $self=shift;
  $self->{forceSpecTimestamps}={};
}

sub onSettingChange {
  my ($self,$setting)=@_;
  checkAllSkillLimit() if(grep {$setting eq $_} (qw/minElo maxElo minLevel maxLevel/));
}

sub onReloadConf {
  checkAllSkillLimit();
}

sub checkAllSkillLimit {
  my $self=shift;
  my $lobby=getLobbyInterface();
  if(getLobbyState() > 5 && %{$lobby->{battle}}) {
    foreach my $user (keys %{$lobby->{battle}->{users}}) {
      checkSkillLimit($user,$self);
    }
  }
}

sub isZkMod { return index($_[0],'Zero-K') != -1; }

sub checkSkillLimit {
  my ($user,$self)=@_;
  $self=getPlugin() unless(defined $self);
  return if($user eq getSpadsConf()->{lobbyLogin});
  my $lobby=getLobbyInterface();
  return unless(getLobbyState() > 5 && exists $lobby->{battle}->{users}->{$user});
  return unless(isZkMod($lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod}));
  my $p_battleStatus=$lobby->{battle}->{users}->{$user}->{battleStatus};
  return unless(defined $p_battleStatus && $p_battleStatus->{mode});
  my $springieExt=getPlugin('SpringieExtension');
  return unless(exists $springieExt->{userExt}->{$user});
  my $p_userExt=$springieExt->{userExt}->{$user};

  my $p_conf=getPluginConf();
  my $matchedLimit;
  if($p_conf->{minElo} ne '' && exists $p_userExt->{EffectiveElo} &&  $p_userExt->{EffectiveElo} < $p_conf->{minElo}) {
    $matchedLimit='minimum Elo';
  }elsif($p_conf->{maxElo} ne '' && exists $p_userExt->{EffectiveElo} &&  $p_userExt->{EffectiveElo} > $p_conf->{maxElo}) {
    $matchedLimit='maximum Elo';
  }elsif($p_conf->{minLevel} ne '' && exists $p_userExt->{Level} &&  $p_userExt->{Level} < $p_conf->{minLevel}) {
    $matchedLimit='minimum level';
  }elsif($p_conf->{maxLevel} ne '' && exists $p_userExt->{Level} &&  $p_userExt->{Level} > $p_conf->{maxLevel}) {
    $matchedLimit='maximum level';
  }

  if(defined $matchedLimit) {
    queueLobbyCommand(["FORCESPECTATORMODE",$user]);
    if(! exists $self->{forceSpecTimestamps}->{$user} || time - $self->{forceSpecTimestamps}->{$user} > 60) {
      $self->{forceSpecTimestamps}->{$user}=time;
      sayBattle("Forcing spectator mode for $user [auto-spec mode] (reason: $matchedLimit limit)");
    }
  }
}

1;
