package AutoSpec;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

my %globalPluginParams = ( minSyncedReadyPlayers => ['integer'],
                           minSyncedReadyRatio => ['integer'],
                           autoSpecDelay => ['integerCouple'],
                           autoRingDelay => ['integerCouple'],
                           autoMsgDelay => ['integerCouple'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my $class=shift;
  my $self = { unsyncedPlayers => {},
               unreadyPlayers => {} };
  bless($self,$class);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onBattleOpened {
  my $self=shift;
  $self->{unsyncedPlayers}={};
  $self->{unreadyPlayers}={};
}

sub onSpringStart {
  my $self=shift;
  $self->{unsyncedPlayers}={};
  $self->{unreadyPlayers}={};
}

sub eventLoop {
  my $self=shift;
  my $lobby=getLobbyInterface();
  return unless(getLobbyState() > 5 && %{$lobby->{battle}} && getSpringPid() == 0);
  my (%unsyncedPlayers,%unreadyPlayers,%syncedReadyPlayers);
  foreach my $user (keys %{$lobby->{battle}->{users}}) {
    my $p_battleStatus=$lobby->{battle}->{users}->{$user}->{battleStatus};
    next unless(defined $p_battleStatus && $p_battleStatus->{mode});
    if($p_battleStatus->{sync} != 1) {
      $unsyncedPlayers{$user}=1;
    }elsif($p_battleStatus->{inGame} || ! $p_battleStatus->{ready}) {
      $unreadyPlayers{$user}=1;
    }else{
      $syncedReadyPlayers{$user}=1;
    }
  }
  my $p_conf=getPluginConf();
  my $nbUnsyncedPlayers=keys %unsyncedPlayers;
  my $nbUnreadyPlayers=keys %unreadyPlayers;
  my $nbSyncedReadyPlayers=keys %syncedReadyPlayers;
  if((! $nbUnsyncedPlayers && ! $nbUnreadyPlayers) || $nbSyncedReadyPlayers < $p_conf->{minSyncedReadyPlayers}
     || ($nbSyncedReadyPlayers / ($nbUnsyncedPlayers + $nbUnreadyPlayers + $nbSyncedReadyPlayers)) * 100 < $p_conf->{minSyncedReadyRatio}) {
    $self->{unsyncedPlayers}={};
    $self->{unreadyPlayers}={};
    return;
  }
  $p_conf->{autoSpecDelay} =~ /^(\d+);(\d+)$/;
  my ($unsyncedAutoSpecDelay,$unreadyAutoSpecDelay)=($1,$2);
  $p_conf->{autoRingDelay} =~ /^(\d+);(\d+)$/;
  my ($unsyncedAutoRingDelay,$unreadyAutoRingDelay)=($1,$2);
  $p_conf->{autoMsgDelay} =~ /^(\d+);(\d+)$/;
  my ($unsyncedAutoMsgDelay,$unreadyAutoMsgDelay)=($1,$2);
  foreach my $unsyncedPlayer (keys %unsyncedPlayers) {
    $self->{unsyncedPlayers}->{$unsyncedPlayer}={timestamp => time, rung => 0, alerted => 0} unless(exists $self->{unsyncedPlayers}->{$unsyncedPlayer});
    my $p_unsyncData=$self->{unsyncedPlayers}->{$unsyncedPlayer};
    if($unsyncedAutoSpecDelay && time - $p_unsyncData->{timestamp} >= $unsyncedAutoSpecDelay) {
      queueLobbyCommand(["FORCESPECTATORMODE",$unsyncedPlayer]);
      delete $self->{unsyncedPlayers}->{$unsyncedPlayer};
      next;
    }
    if($unsyncedAutoRingDelay && time - $p_unsyncData->{timestamp} >= $unsyncedAutoRingDelay && ! $p_unsyncData->{rung}) {
      queueLobbyCommand(["RING",$unsyncedPlayer]);
      $self->{unsyncedPlayers}->{$unsyncedPlayer}->{rung}=1;
    }
    if($unsyncedAutoMsgDelay && time - $p_unsyncData->{timestamp} >= $unsyncedAutoMsgDelay && ! $p_unsyncData->{alerted}) {
      my $alertMsg='WARNING: a new game is preparing but you are unsynchronized';
      $alertMsg.=' (forcing spectator mode in '.($p_unsyncData->{timestamp}+$unsyncedAutoSpecDelay-time).' seconds)' if($unsyncedAutoSpecDelay);
      sayPrivate($unsyncedPlayer,$alertMsg);
      $self->{unsyncedPlayers}->{$unsyncedPlayer}->{alerted}=1;
    }
  }
  foreach my $unsyncedPlayer (keys %{$self->{unsyncedPlayers}}) {
    delete $self->{unsyncedPlayers}->{$unsyncedPlayer} unless(exists $unsyncedPlayers{$unsyncedPlayer});
  }
  foreach my $unreadyPlayer (keys %unreadyPlayers) {
    $self->{unreadyPlayers}->{$unreadyPlayer}={timestamp => time, rung => 0, alerted => 0} unless(exists $self->{unreadyPlayers}->{$unreadyPlayer});
    my $p_unreadyData=$self->{unreadyPlayers}->{$unreadyPlayer};
    if($unreadyAutoSpecDelay && time - $p_unreadyData->{timestamp} >= $unreadyAutoSpecDelay) {
      queueLobbyCommand(["FORCESPECTATORMODE",$unreadyPlayer]);
      delete $self->{unreadyPlayers}->{$unreadyPlayer};
      next;
    }
    if($unreadyAutoRingDelay && time - $p_unreadyData->{timestamp} >= $unreadyAutoRingDelay && ! $p_unreadyData->{rung}) {
      queueLobbyCommand(["RING",$unreadyPlayer]);
      $self->{unreadyPlayers}->{$unreadyPlayer}->{rung}=1;
    }
    if($unreadyAutoMsgDelay && time - $p_unreadyData->{timestamp} >= $unreadyAutoMsgDelay && ! $p_unreadyData->{alerted}) {
      my $alertMsg='WARNING: a new game is preparing but you are ';
      if(! $lobby->{battle}->{users}->{$unreadyPlayer}->{battleStatus}->{ready}) {
        $alertMsg.='not ready';
      }else{
        $alertMsg.='already in game';
      }
      $alertMsg.=' (forcing spectator mode in '.($p_unreadyData->{timestamp}+$unreadyAutoSpecDelay-time).' seconds)' if($unreadyAutoSpecDelay);
      sayPrivate($unreadyPlayer,$alertMsg);
      $self->{unreadyPlayers}->{$unreadyPlayer}->{alerted}=1;
    }
  }
  foreach my $unreadyPlayer (keys %{$self->{unreadyPlayers}}) {
    delete $self->{unreadyPlayers}->{$unreadyPlayer} unless(exists $unreadyPlayers{$unreadyPlayer});
  }
}

1;
