package KickBanNextGame;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

sub new {
  my $class=shift;
  my $self = {previousKickBanHandler => $::spadsHandlers{kickban}};
  bless($self,$class);
  addSpadsCommandHandler({kickban => \&hSpadsKickBan},1);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  my $self=shift;
  addSpadsCommandHandler({kickban => $self->{previousKickBanHandler}},1);
  slog("Plugin unloaded",3);
}

sub onSpringStop {
  my $spads=getSpadsConfFull();
  my $p_dynamicBans=$spads->getDynamicBans();
  if(@{$p_dynamicBans}) {
    foreach my $p_ban (@{$p_dynamicBans}) {
      $spads->unban($p_ban->[0]) if(exists $p_ban->[1]->{reason} && defined $p_ban->[1]->{reason} && $p_ban->[1]->{reason} =~ /^temporary kick\-ban/);
    }
  }
}

sub hSpadsKickBan {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my $vanillaKickBanRes=::hKickBan($source,$user,$p_params,1);
  return $vanillaKickBanRes unless($vanillaKickBanRes && ! $checkOnly);

  my $bannedUser;
  $bannedUser=$1 if($vanillaKickBanRes =~ /^kickBan (.+)$/);
  if(! defined $bannedUser) {
    ::invalidSyntax($user,'kickban');
    return 0;
  }
  
  my $autohost=getSpringInterface();
  if($autohost->getState()) {
    my $p_ahPlayers=$autohost->getPlayersByNames();
    if(exists $p_ahPlayers->{$bannedUser} && %{$p_ahPlayers->{$bannedUser}} && $p_ahPlayers->{$bannedUser}->{disconnectCause} == -1) {
      $autohost->sendChatMessage("/kick $bannedUser");
    }
  }

  my $lobby=getLobbyInterface();
  if(getLobbyState() > 5 && %{$lobby->{battle}}) {
    if(exists $lobby->{battle}->{users}->{$bannedUser}) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }
  }

  my $p_conf=getSpadsConf();
  my $p_user={name => $bannedUser};
  my $accountId=::getLatestUserAccountId($bannedUser);
  $p_user={accountId => "$accountId($bannedUser)"} if($accountId =~ /^\d+$/);
  my $p_ban={banType => 1,
             startDate => time,
             endDate => time + $p_conf->{kickBanDuration},
             reason => "temporary kick-ban by $user"};
  my $spads=getSpadsConfFull();
  $spads->banUser($p_user,$p_ban);
  my $kickBanDuration=secToTime($p_conf->{kickBanDuration});
  broadcastMsg("Battle ban added for user \"$bannedUser\" (duration: until next game or maximum $kickBanDuration, reason: temporary kick-ban by $user)");

  return "kickBan $bannedUser";
}

1;
