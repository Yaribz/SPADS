package AutoPauseOnVote;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.2';
my $requiredSpadsVersion='0.11.2';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onVoteStart {
  return if(getSpringPid() == 0);
  my $autohost=getSpringInterface();
  return if($autohost->getState() != 2);
  $autohost->sendChatMessage('/pause 1');
  $autohost->sendChatMessage(getSpadsConf()->{lobbyLogin}.' * AutoPauseOnVote: Game paused.');
}

sub onVoteStop {
  return if(getSpringPid() == 0);
  my $autohost=getSpringInterface();
  return if($autohost->getState() != 2);
  $autohost->sendChatMessage('/pause 0');
  $autohost->sendChatMessage(getSpadsConf()->{lobbyLogin}.' * AutoPauseOnVote: Game unpaused.');
}

1;
