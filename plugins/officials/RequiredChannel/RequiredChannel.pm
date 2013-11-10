package RequiredChannel;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.6';

my %globalPluginParams = ( requiredChannel => ['channel'],
                           denyMessage => ['notNull']);

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  queueLobbyCommand(['JOIN',getPluginConf()->{requiredChannel}]) if(getLobbyState() > 3);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onLobbyConnected {
  queueLobbyCommand(['JOIN',getPluginConf()->{requiredChannel}]);
}

sub onJoinBattleRequest {
  my (undef,$user)=@_;
  my $p_conf=getPluginConf();
  my $reqChan=$p_conf->{requiredChannel};
  $reqChan=$1 if($reqChan =~ /^([^\s]+)\s/);
  my $lobby=getLobbyInterface();
  if(getLobbyState() < 4 || ! exists $lobby->{channels}->{$reqChan}
     || ! exists $lobby->{channels}->{$reqChan}->{$user}) {
    sayPrivate($user,$p_conf->{denyMessage});
    return $p_conf->{denyMessage};
  }
  return 0;
}

1;
