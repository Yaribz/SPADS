package UpdateMapBoxesConf;

use strict;

use Fcntl qw':DEFAULT :flock';
use File::Spec::Functions qw'catfile';
use HTTP::Tiny;

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

my %globalPluginParams = ( mapBoxesConfUrl => ['notNull'],
                           httpTimeout => ['nonNullInteger'],
                           updateInterval => ['nonNullInteger'] );
my %presetPluginParams;

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

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

sub new {
  my $class=shift;
  my $self = {lock => undef,
              etag => undef};
  bless($self,$class);
  my ($mapBoxesConfUrl,$updateInterval);
  {
    my $r_pluginConf=getPluginConf();
    ($mapBoxesConfUrl,$updateInterval)=@{$r_pluginConf}{(qw'mapBoxesConfUrl updateInterval')};
  }
  if($mapBoxesConfUrl !~ /^http:\/\//i) {
    if($mapBoxesConfUrl =~ /^https:\/\//i) {
      if(! $httpTinyCanSsl) {
        slog("URL unsupported \"$mapBoxesConfUrl\", IO::Socket::SSL version 1.42 or superior and Net::SSLeay version 1.49 or superior are required for SSL support",1);
        return undef;
      }
    }else{
      slog("Invalid URL \"$mapBoxesConfUrl\"",1);
      return undef;
    }
  }
  addTimer('updateMapBoxesConf',
           1,
           $updateInterval*60,
           sub {
             return unless($self->checkLock());
             forkCall(\&updateMapBoxesConf,\&updateEnd);
           });
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub checkLock {
  my $self=shift;
  return 1 if($self->{lock});
  my $lockFile=catfile(getSpadsConf()->{varDir},'UpdateMapBoxesConf.lock');
  if(open(my $lockFh,'>',$lockFile)) {
    if(! flock($lockFh, LOCK_EX|LOCK_NB)) {
      close($lockFh);
      return 0;
    }
    $self->{lock}=$lockFh;
    my $etagFile=catfile(getSpadsConf()->{varDir},'UpdateMapBoxesConf.etag');
    if(-f $etagFile) {
      if(open(my $etagFh,'<',$etagFile)) {
        my $etagVal=<$etagFh>;
        close($etagFh);
        if($etagVal) {
          chomp($etagFh);
          $self->{etag}=$etagVal;
        }else{
          slog('Unable to read ETag file \"$etagFile\": invalid content',2);
        }
      }else{
        slog("Unable to open ETag file \"$etagFile\" for reading: $!",2);
      }
    }
    return 1;
  }else{
    slog("Unable to open UpdateMapBoxesConf lock file \"$lockFile\"",1);
    return undef;
  }
}

sub updateMapBoxesConf {
  my %httpOptions;
  my $self=getPlugin();
  $httpOptions{headers}{'If-None-Match'}=$self->{etag} if($self->{etag});
  my $res=HTTP::Tiny->new(timeout => getPluginConf()->{httpTimeout})->mirror(getPluginConf()->{mapBoxesConfUrl},catfile(getSpadsConf()->{etcDir},'mapBoxes.conf'),\%httpOptions);
  return undef unless(defined $res);
  my $reason=$res->{reason};
  $reason=$res->{content} if($res->{status} == 599);
  return ($res->{success},$res->{status},$reason,$res->{headers}{etag});
}

sub updateEnd {
  my ($success,$status,$reason,$etag)=@_;
  if(defined $success) {
    if($success) {
      if($status != 304) {
        slog('mapBoxes.conf file updated',3);
        newEtag($etag);
      }
    }else{
      slog('Failed to download mapBoxes.conf file from "'.getPluginConf()->{mapBoxesConfUrl}."\" (status $status: $reason)",2);
    }
  }else{
    slog('Failed to download mapBoxes.conf file from "'.getPluginConf()->{mapBoxesConfUrl}.'" (unknown error)',2);
  }
}

sub newEtag {
  my $etag=shift;
  my $self=getPlugin();
  $self->{etag}=$etag;
  my $etagFile=catfile(getSpadsConf()->{varDir},'UpdateMapBoxesConf.etag');
  if(defined $etag) {
    if(open(my $etagFh,'>',$etagFile)) {
      print $etagFh $etag;
      close($etagFh);
    }else{
      slog("Unable to open ETag file \"$etagFile\" for writing: $!",2);
    }
  }else{
    unlink($etagFile)
        or slog("Unable to delete ETag file \"$etagFile\": $!",2);
  }
}

sub onUnload {
  removeTimer('updateMapBoxesConf');
}

1;
