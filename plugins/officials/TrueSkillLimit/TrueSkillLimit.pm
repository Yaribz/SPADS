package TrueSkillLimit;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.5';
my $requiredSpadsVersion='0.11.5b';

my %presetPluginParams = ( trueSkillType => ['notNull'],
                           minTrueSkill => ['integer','integerRange','null'],
                           maxTrueSkill => ['integer','integerRange','null'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [{},\%presetPluginParams]; }

sub new {
  my $class=shift;
  my $self = {forceSpecTimestamps => {}};
  my $p_conf=getPluginConf();
  if($p_conf->{trueSkillType} !~ /^\w+$/ || ! grep {/^$p_conf->{trueSkillType}$/} (qw/Duel FFA Team TeamFFA/)) {
    slog("Invalid trueSkillType value \"$p_conf->{trueSkillType}\"",1);
    return undef;
  }
  bless($self,$class);
  if(getLobbyState() > 3) {
    addLobbyCommandHandler({CLIENTBATTLESTATUS => \&hLobbyClientBattleStatus,
                            LEFTBATTLE => \&hLobbyLeftBattle});
    my $lobby=getLobbyInterface();
    if(getLobbyState() > 5 && %{$lobby->{battle}}) {
      foreach my $user (keys %{$lobby->{battle}->{users}}) {
        checkTrueSkillLimit($user,$self);
      }
    }
  }
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onLobbyConnected {
  addLobbyCommandHandler({CLIENTBATTLESTATUS => \&hLobbyClientBattleStatus,
                          LEFTBATTLE => \&hLobbyLeftBattle});
}

sub onUnload {
  removeLobbyCommandHandler(['CLIENTBATTLESTATUS','LEFTBATTLE']);
  slog("Plugin unloaded",3);
}

sub hLobbyClientBattleStatus {
  my (undef,$user)=@_;
  checkTrueSkillLimit($user);
}

sub updatePlayerSkill {
  my $accountId=$_[2];
  if(getLobbyState() > 5) {
    my $lobby=getLobbyInterface();
    checkTrueSkillLimit($lobby->{accounts}->{$accountId}) if(exists $lobby->{accounts}->{$accountId});
  }
}

sub checkTrueSkillLimit {
  my ($user,$self)=@_;
  $self=getPlugin() unless(defined $self);
  return if($user eq getSpadsConf()->{lobbyLogin});
  my $lobby=getLobbyInterface();
  return unless(getLobbyState() > 5 && exists $lobby->{battle}->{users}->{$user} && exists $::battleSkillsCache{$user});
  my $p_battleStatus=$lobby->{battle}->{users}->{$user}->{battleStatus};
  return unless(defined $p_battleStatus && $p_battleStatus->{mode});
  my $p_conf=getPluginConf();
  my $matchedLimit;
  if($p_conf->{minTrueSkill} ne '' && $::battleSkillsCache{$user}->{$p_conf->{trueSkillType}}->{skill} < $p_conf->{minTrueSkill}) {
    $matchedLimit='minimum';
  }elsif($p_conf->{maxTrueSkill} ne '' && $::battleSkillsCache{$user}->{$p_conf->{trueSkillType}}->{skill} > $p_conf->{maxTrueSkill}) {
    $matchedLimit='maximum';
  }
  if(defined $matchedLimit) {
    queueLobbyCommand(["FORCESPECTATORMODE",$user]);
    if(! exists $self->{forceSpecTimestamps}->{$user} || time - $self->{forceSpecTimestamps}->{$user} > 60) {
      $self->{forceSpecTimestamps}->{$user}=time;
      sayBattle("Forcing spectator mode for $user [auto-spec mode] (reason: $matchedLimit $p_conf->{trueSkillType} TrueSkill limit)");
    }
  }
}

sub hLobbyLeftBattle {
  my (undef,$battleId,$user)=@_;
  my $lobby=getLobbyInterface();
  if(%{$lobby->{battle}} && $battleId == $lobby->{battle}->{battleId}) {
    my $self=getPlugin();
    delete $self->{forceSpecTimestamps}->{$user};
  }
}

sub onBattleClosed {
  my $self=shift;
  $self->{forceSpecTimestamps}={};
}

sub onReloadConf {
  my $lobby=getLobbyInterface();
  if(getLobbyState() > 5 && %{$lobby->{battle}}) {
    foreach my $user (keys %{$lobby->{battle}->{users}}) {
      checkTrueSkillLimit($user);
    }
  }
}

1;
