package DownloadArchives;

use strict;

use File::Spec;
use List::Util 'first';

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.2';
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
  return spadsDlArchive('map',@_);
}

sub hSpadsDlMod {
  return spadsDlArchive('mod',@_);
}

sub spadsDlArchive {
  my ($type,$source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != 0 || $p_params->[0] !~ /^http:\/\//i || $p_params->[0] =~ /\"/) {
    ::invalidSyntax($user,"dl$type");
    return 0;
  }
  my $plugin=getPlugin();
  my $dlDir=$plugin->getWritableDataSubDir($type);
  if(! defined $dlDir) {
    my $errorMsg="Unable to find any writable $type data directory, download aborted!";
    answer($errorMsg);
    slog($errorMsg,2);
    return 0;
  }
  return 1 if($checkOnly);
  if(forkProcess( sub { $plugin->downloadFileForked($p_params->[0],$dlDir) }, sub { dlEnd($user,$type,$p_params->[0],@_); } )) {
    answer("Downloading $type archive from \"$p_params->[0]\"...");
    return 1;
  }else{
    my $errorMsg="Unable to fork to download $type archive from \"$p_params->[0]\"";
    answer($errorMsg);
    slog($errorMsg,2);
    return 0;
  }
}

sub getWritableDataSubDir {
  my ($self,$type)=@_;
  my $pathSep=$^O eq 'MSWin32'?';':':';
  my @dataDirs=split(/$pathSep/,getSpadsConf()->{springDataDir});
  my $dir;
  if($type eq 'map') {
    $dir=first {-d "$_/maps" && -x "$_/maps" && -w "$_/maps"} @dataDirs;
    $dir.='/maps' if(defined $dir);
  }else{
    $dir=first {-d "$_/games" && -x "$_/games" && -w "$_/games"} @dataDirs;
    if(defined $dir) {
      $dir.='/games';
    }else{
      $dir=first {-d "$_/mods" && -x "$_/mods" && -w "$_/mods"} @dataDirs;
      $dir.='/mods' if(defined $dir);
    }
  }
  return $dir;
}

sub downloadFileForked {
  my ($self,$url,$dlDir)=@_;
  if(! chdir($dlDir)) {
    slog("Unable to go into \"$dlDir\" directory, cancelling download!",2);
    exit 2;
  }
  my $nullDevice=File::Spec->devnull();
  system("wget -T 10 -t 2 --content-disposition \"$url\" >$nullDevice 2>&1");
  exit 1 if($?);
  exit 0;
}

sub dlEnd {
  my ($user,$dlType,$url,$rc)=@_;
  my $canAnswer=(getLobbyState() > 3 && exists getLobbyInterface()->{users}->{$user});
  if($rc != 0) {
    my $message="Failed to download $dlType archive from \"$url\"";
    slog("$message (by $user)",2);
    sayPrivate($user,"$message.") if($canAnswer);
  }else{
    slog("Downloaded $dlType archive from \"$url\" (by $user)",3);
    sayPrivate($user,"Download of $dlType archive from \"$url\" complete.") if($canAnswer);
  }
}

1;
