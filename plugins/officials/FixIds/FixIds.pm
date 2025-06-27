package FixIds;

use strict;

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

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
  addSpadsCommandHandler({fixIds => \&hFixIds});
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  removeSpadsCommandHandler(['fixIds']);
  slog("Plugin unloaded",3);
}

sub hFixIds {
  my ($source,$user,$r_params,$checkOnly)=@_;
  
  if(@{$r_params}) {
    invalidSyntax($user,'fixIds');
    return 0;
  }

  if(getLobbyState() < LOBBY_STATE_BATTLE_OPENED) {
    answer('Cannot fix IDs, battle lobby is closed');
    return 0;
  }

  if(getSpadsConf()->{autoBalance} ne 'off') {
    answer('Cannot fix IDs, autoBalance is enabled');
    return 0;
  }

  return 1 if($checkOnly);

  my $lobby=getLobbyInterface();
  my $r_battle=$lobby->getBattle();
  my $r_bUsers=$r_battle->{users};
  my $r_bBots=$r_battle->{bots};

  my @bPlayers = grep {defined $r_bUsers->{$_}{battleStatus} && $r_bUsers->{$_}{battleStatus}{mode}} (keys %{$r_bUsers});

  return 1 unless(@bPlayers || %{$r_bBots});

  my $maxId = @bPlayers + %{$r_bBots} - 1;

  my %usedIds;
  my %playersToFix;
  my %botsToFix;

  foreach my $player (@bPlayers) {
    my $id = $r_bUsers->{$player}{battleStatus}{id};
    if($id > $maxId || exists $usedIds{$id}) {
      $playersToFix{$player}=1;
    }else{
      $usedIds{$id}=1;
    }
  }
  foreach my $bot (keys %{$r_bBots}) {
    my $id = $r_bBots->{$bot}{battleStatus}{id};
    if($id > $maxId || exists $usedIds{$id}) {
      $botsToFix{$bot}=1;
    }else{
      $usedIds{$id}=1;
    }
  }

  return 1 unless(%playersToFix || %botsToFix);
  
  my @freeIds = grep {! exists $usedIds{$_}} (0..$maxId);
  queueLobbyCommand(['FORCETEAMNO',$_,shift(@freeIds)]) foreach(sort {$r_bUsers->{$a}{battleStatus}{team} <=> $r_bUsers->{$b}{battleStatus}{team}} keys %playersToFix);
  foreach my $bot (sort {$r_bBots->{$a}{battleStatus}{team} <=> $r_bBots->{$b}{battleStatus}{team}} keys %botsToFix) {
    my $r_bs=$r_bBots->{$bot}{battleStatus};
    $r_bs->{id}=shift(@freeIds);
    queueLobbyCommand(['UPDATEBOT',$bot,$lobby->marshallBattleStatus($r_bs),$lobby->marshallColor($r_bBots->{$bot}{color})]);
  }

  return 1;
}

1;
