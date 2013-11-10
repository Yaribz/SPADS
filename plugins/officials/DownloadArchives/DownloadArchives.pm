package DownloadArchives;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.4';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  addSpadsCommandHandler({dlmap => \&hSpadsDlMap,
                          dlmod => \&hSpadsDlMod});
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  removeSpadsCommandHandler(['dlmap','dlmod']);
  slog("Plugin unloaded",3);
}

sub hSpadsDlMap {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != 0 || $p_params->[0] !~ /^http:\/\//i || $p_params->[0] =~ /\"/) {
    ::invalidSyntax($user,'dlmap');
    return 0;
  }
  return 1 if($checkOnly);
  answer("Downloading map from \"$p_params->[0]\"...");
  forkProcess( sub { dlStart('map',$p_params->[0]); }, sub { dlEnd($user,'map',$p_params->[0],@_); } );
}

sub hSpadsDlMod {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != 0 || $p_params->[0] !~ /^http:\/\//i || $p_params->[0] =~ /\"/) {
    ::invalidSyntax($user,'dlmod');
    return 0;
  }
  return 1 if($checkOnly);
  answer("Downloading mod from \"$p_params->[0]\"...");
  forkProcess( sub { dlStart('mod',$p_params->[0]); }, sub { dlEnd($user,'mod',$p_params->[0],@_); } );
}

sub dlStart {
  my ($dlType,$url)=@_;
  my $dlDir=getSpadsConf()->{springDataDir};
  if($dlType eq 'map') {
    $dlDir.='/maps';
  }else{
    if(! -d $dlDir.'/games' && -d $dlDir.'/mods') {
      $dlDir.='/mods';
    }else{
      $dlDir.='/games';
    }
  }
  if(! chdir($dlDir)) {
    slog("Unable to go into \"$dlDir\" directory, cancelling download!",2);
    exit 2;
  }
  my $nullDevice = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
  system("wget -T 10 -t 2 --content-disposition \"$url\" >$nullDevice 2>&1");
  exit 1 if($?);
  exit 0;
}

sub dlEnd {
  my ($user,$dlType,$url,$rc)=@_;
  return unless(getLobbyState() > 3 && exists getLobbyInterface()->{users}->{$user});
  if($rc != 0) {
    my $message="Failed to download $dlType from \"$url\"";
    slog("$message (by $user)",2);
    sayPrivate($user,"$message.");
  }else{
    slog("Downloaded $dlType from \"$url\" (by $user)",3);
    sayPrivate($user,"Download of $dlType from \"$url\" finished.");
  }
}

1;
