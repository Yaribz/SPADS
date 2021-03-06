package DownloadArchives;

use strict;

use File::Spec::Functions 'catfile';
use HTTP::Tiny;
use List::Util 'first';

my $httpTinyCanSsl;
if(HTTP::Tiny->can('can_ssl')) {
  $httpTinyCanSsl=HTTP::Tiny->can_ssl();
}else{
  $httpTinyCanSsl=eval { require IO::Socket::SSL;
                         IO::Socket::SSL->VERSION(1.42);
                         require Net::SSLeay;
                         Net::SSLeay->VERSION(1.49);
                         1; };
}
my $httpRegExp='http'.($httpTinyCanSsl?'s?':'').'://';

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.4';
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
  slog("Plugin loaded (version $pluginVersion, TLS support ".($httpTinyCanSsl?'':'not ').'available)',3);
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
  if($#{$p_params} != 0 || $p_params->[0] !~ /^$httpRegExp/i || $p_params->[0] =~ /\"/) {
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

sub getFileNameFromUrl {
  return $1 if(shift =~ /[^\/]\/([^\/\\]+)\/?$/);
  return undef;
}

sub getRecommendedFileName {
  my @contentDispositionValues=split(/;/,shift//'');
  foreach my $contentDispositionValue (@contentDispositionValues) {
    return $1 if($contentDispositionValue =~ /^\s*filename\s*=\s*"?(.+)"?\s*$/i);
  }
  return undef;
}

sub generateRandomFileChars {
  my $length=shift;
  my @fileChars=split('','abcdefghijklmnopqrstuvwxyz1234567890');
  my $randomFileChars='';
  for (1..$length) {
    $randomFileChars.=$fileChars[int(rand($#fileChars+1))];
  }
  return $randomFileChars;
}

sub downloadFileForked {
  my ($self,$url,$dlDir)=@_;
  my $defaultFileName=getFileNameFromUrl($url);
  if($url !~ /^$httpRegExp/i || ! defined $defaultFileName) {
    slog("Invalid URL \"$url\", cancelling download!",2);
    exit 1;
  }
  srand();
  my $tmpFile=catfile($dlDir,"$defaultFileName.".generateRandomFileChars(6).'.tmp');
  require Fcntl;
  my $fh;
  if(! sysopen($fh,$tmpFile,Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_WRONLY())) {
    slog("Unable to create temporary file \"$tmpFile\" for download: $!",2);
    exit 2;
  }
  binmode $fh;
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$url,{data_callback => sub { print {$fh} $_[0] }});
  if(! close($fh)) {
    unlink($tmpFile);
    slog("Error while closing temporary file \"$tmpFile\" for download: $!",2);
    exit 3;
  }
  if($httpRes->{success}) {
    my $fileName;
    $fileName=getRecommendedFileName($httpRes->{headers}->{'content-disposition'})
        if(exists $httpRes->{headers} && exists $httpRes->{headers}->{'content-disposition'});
    $fileName//=getFileNameFromUrl($httpRes->{url}) if(exists $httpRes->{url} && defined $httpRes->{url});
    $fileName//=$defaultFileName;
    $fileName=catfile($dlDir,$fileName);
    if(! rename($tmpFile,$fileName)) {
      unlink($tmpFile);
      slog("Error while replacing file \"$fileName\" with downloaded one: $!",2);
      exit 4;
    }
  }else{
    unlink($tmpFile);
    my @reasonStrings;
    push(@reasonStrings,$httpRes->{status}) if(exists $httpRes->{status} && defined $httpRes->{status});
    push(@reasonStrings,$httpRes->{reason}) if(exists $httpRes->{reason} && defined $httpRes->{reason});
    my $reasonString=@reasonStrings?join(' - ',@reasonStrings):'unknown error';
    slog("Error while downloading file from \"$url\" ($reasonString)",2);
    exit 5;
  }
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
