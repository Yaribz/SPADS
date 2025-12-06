# Perl module used for Spads auto-updating functionnality
#
# Copyright (C) 2008-2025  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package SpadsUpdater;

use strict;

use Config;
use Fcntl qw':DEFAULT :flock';
use File::Copy;
use File::Path 'mkpath';
use File::Spec::Functions qw'catdir catfile devnull';
use FindBin;
use HTTP::Tiny;
use IO::Uncompress::Unzip qw'unzip $UnzipError';
use JSON::PP 'decode_json';
use List::Util qw'any all none notall max';
use Storable qw'nstore retrieve';
use Time::HiRes;

my $win=$^O eq 'MSWin32' ? 1 : 0;
my $archName=($win?'win':'linux').($Config{ptrsize} > 4 ? 64 : 32);

our $VERSION='0.32';

my @constructorParams = qw'sLog repository release packages';
my @optionalConstructorParams = qw'localDir springDir';

my $springBuildbotUrl='http://springrts.com/dl/buildbot/default';
my $springVersionUrl='http://planetspads.free.fr/spring/SpringVersion';
my $barLauncherConfigUrl='https://launcher-config.beyondallreason.dev/config.json';
our ($SPRING_MASTER_BRANCH,$SPRING_DEV_BRANCH)=('master','develop');

our $HttpTinyCanSsl;
sub checkHttpsSupport {
  return $HttpTinyCanSsl if(defined $HttpTinyCanSsl);
  if(HTTP::Tiny->can('can_ssl')) {
    $HttpTinyCanSsl = HTTP::Tiny->can_ssl() ? 1 : 0;
  }else{
    $HttpTinyCanSsl=eval { require IO::Socket::SSL;
                           IO::Socket::SSL->VERSION(1.42);
                           require Net::SSLeay;
                           Net::SSLeay->VERSION(1.49);
                           1; } ? 1 : 0;
  }
  return $HttpTinyCanSsl;
}

sub getVersion { return $VERSION }

# Called by spadsInstaller.pl, spads.pl
sub new {
  my ($objectOrClass,%params) = @_;
  if(! exists $params{sLog}) {
    print "ERROR - \"sLog\" parameter missing in SpadsUpdater constructor\n";
    return 0;
  }
  my $class = ref($objectOrClass) || $objectOrClass;
  my $self = {sLog => $params{sLog}};
  bless ($self, $class);

  foreach my $param (@constructorParams) {
    if(! exists $params{$param}) {
      $self->{sLog}->log("\"$param\" parameter missing in constructor",1);
      return 0;
    }
  }

  foreach my $param (keys %params) {
    if(grep {$_ eq $param} (@constructorParams,@optionalConstructorParams)) {
      $self->{$param}=$params{$param};
    }else{
      $self->{sLog}->log("Ignoring invalid constructor parameter \"$param\"",2)
    }
  }

  $self->{repository}=~s/\/$//;
  $self->{localDir}//=File::Spec->canonpath($FindBin::Bin);
  $self->{engineReleaseVersionCache}={};

  if(substr($self->{release},0,3) eq 'git') {
    my $release=$self->{release};
    my $githubUrlIdent;
    if(substr($release,3,1) eq '@') {
      if(substr($release,4,4) eq 'tag=') {
        $githubUrlIdent='refs/tags/'.substr($release,8);
      }elsif(substr($release,4,7) eq 'branch=') {
        $githubUrlIdent='refs/heads/'.substr($release,11);
      }else{
        $githubUrlIdent=substr($release,4);
      }
    }else{
      $githubUrlIdent='refs/heads/master';
    }
    $self->{packagesIndexUrl}='https://raw.githubusercontent.com/Yaribz/SPADS/'._escapeUrl($githubUrlIdent).'/packages.txt';
  }else{
    $self->{packagesIndexUrl}=$self->{repository}.'/packages.txt';
  }
  
  return $self;
}

sub _escapeUrl {
  my $url=shift;
  $url =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/eg;
  return $url;
}

sub _unescapeUrl {
  my $url=shift;
  $url =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
  return $url;
}

sub _getEngineReleaseVersionCacheFile {
  my ($self,$release,$r_githubInfo)=@_;
  my @releaseVersionFilePath=$self->{springDir};
  push(@releaseVersionFilePath,$r_githubInfo->{subdir}) if(defined $r_githubInfo);
  my $file=catfile(@releaseVersionFilePath,$release.'Version.dat');
  return wantarray() ? (catdir(@releaseVersionFilePath),$file) : $file;
}

# Called by spads.pl
sub resolveEngineReleaseNameToVersionWithFallback {
  my ($self,$release,$r_githubInfo)=@_;
  my $sl=$self->{sLog};
  my ($engineVersion,$releaseTag)=$self->resolveEngineReleaseNameToVersion($release,$r_githubInfo);
  return ($engineVersion,$releaseTag) if(defined $engineVersion);
  my $releaseVersionFile=$self->_getEngineReleaseVersionCacheFile($release,$r_githubInfo);
  return (undef,undef) unless(-f $releaseVersionFile);
  my $releaseVersionLockFile=$releaseVersionFile.'.lock';
  if(open(my $releaseVersionLockFh,'>',$releaseVersionLockFile)) {
    if(_autoRetry(sub {flock($releaseVersionLockFh, LOCK_EX|LOCK_NB)})) {
      if(open(my $releaseVersionFh,'<',$releaseVersionFile)) {
        ($engineVersion,$releaseTag)=split(/;/,<$releaseVersionFh>,2);
        close($releaseVersionFh);
        foreach my $str ($engineVersion,$releaseTag) {
          next unless(defined $str);
          chomp($str);
          undef $str if($str eq '');
        }
        if(defined $engineVersion) {
          $sl->log("Using cached $release release version \"$engineVersion\" as fallback solution",2);
        }else{
          $sl->log("Failed to read cached release version from file \"$releaseVersionFile\" as fallback solution",2);
        }
      }else{
        $sl->log("Failed to open release version cache file \"$releaseVersionFile\" for fallback solution",2);
      }
    }else{
      $sl->log("Failed to acquire lock on release version cache file \"$releaseVersionFile\" for fallback solution",2);
    }
    close($releaseVersionLockFh);
  }else{
    $sl->log("Failed to open release version cache lock file \"$releaseVersionLockFile\" for fallback solution",2);
  }
  return ($engineVersion,$releaseTag);
}

# Called by spads.pl, spadsInstaller.pl
sub resolveEngineReleaseNameToVersion {
  my ($self,$release,$r_githubInfo,$ignoreUnexistingRelease)=@_;
  my $sl=$self->{sLog};
  my ($engineVersion,$releaseTag)=$self->_resolveEngineReleaseNameToVersion($release,$r_githubInfo,$ignoreUnexistingRelease);
  return (undef,undef) unless(defined $engineVersion);
  my ($releaseVersionPath,$releaseVersionFile)=$self->_getEngineReleaseVersionCacheFile($release,$r_githubInfo);
  my $r_versionCache=$self->{engineReleaseVersionCache}{$releaseVersionFile};
  if(! defined $r_versionCache || $r_versionCache->{version} ne $engineVersion
     || (defined $releaseTag && (! defined $r_versionCache->{tag} || $r_versionCache->{tag} ne $releaseTag))) {
    $self->{engineReleaseVersionCache}{$releaseVersionFile}={version => $engineVersion, tag => $releaseTag};
    if(! -e $releaseVersionPath) {
      eval { mkpath($releaseVersionPath) };
      if($@) {
        $sl->log("Unable to create directory \"$releaseVersionPath\" for engine release version cache ($@)",1);
      }else{
        $sl->log("Created new directory \"$releaseVersionPath\" for engine release version cache",4);
      }
    }
    if(-d $releaseVersionPath) {      
      my $releaseVersionLockFile=$releaseVersionFile.'.lock';
      if(open(my $releaseVersionLockFh,'>',$releaseVersionLockFile)) {
        if(_autoRetry(sub {flock($releaseVersionLockFh, LOCK_EX|LOCK_NB)})) {
          if(open(my $releaseVersionFh,'>',$releaseVersionFile)) {
            print $releaseVersionFh $engineVersion.(defined $releaseTag ? ';'.$releaseTag : '');
            close($releaseVersionFh);
          }else{
            $sl->log("Unable to write release version cache file \"$releaseVersionFile\" ($!)",2);
          }
        }else{
          $sl->log("Failed to acquire lock to write release version cache file \"$releaseVersionFile\"",2);
        }
        close($releaseVersionLockFh);
      }else{
        $sl->log("Failed to open lock file \"$releaseVersionLockFile\" to write release version cache file",2);
      }
    }
  }
  return ($engineVersion,$releaseTag);
}

# Called by spadsInstaller.pl
sub buildTagRegexp {
  my ($tagStr,$capturedField)=@_;
  $capturedField//='version';
  my %placeHolders = (
    branch => '[\w\-\.\/]+',
    version => '\d+(?:\.\d+){1,3}(?:-\d+-g[0-9a-f]+)?',
      );
  $placeHolders{$capturedField}='('.$placeHolders{$capturedField}.')';
  my $tagRegexp='';
  while(length($tagStr)) {
    my %placeHoldersPositions=map {$_ => index($tagStr,'<'.$_.'>')} (keys %placeHolders);
    my ($nextPlaceHolder,$nextPlaceHolderPos);
    map {my $pos=$placeHoldersPositions{$_}; ($nextPlaceHolder,$nextPlaceHolderPos)=($_,$pos) if($pos > -1 && (! defined $nextPlaceHolderPos || $pos < $nextPlaceHolderPos))} (keys %placeHolders);
    return $tagRegexp.quotemeta($tagStr) unless(defined $nextPlaceHolder);
    $tagRegexp.=quotemeta(substr($tagStr,0,$nextPlaceHolderPos)).$placeHolders{$nextPlaceHolder};
    substr($tagStr,0,$nextPlaceHolderPos+2+length($nextPlaceHolder))='';
  }
  return $tagRegexp;
}

sub _resolveEngineReleaseNameToVersion {
  my ($self,$release,$r_githubInfo,$ignoreUnexistingRelease)=@_;
  my $sl=$self->{sLog};
  if(defined $r_githubInfo) {
    if(substr($release,0,3) eq 'bar') {
      my $enginePrefix = $release eq 'bar' ? 'stable' : 'testing';
      my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$barLauncherConfigUrl);
      if($httpRes->{success}) {
        my $r_barOnlineConfig;
        eval {
          $r_barOnlineConfig=decode_json($httpRes->{content});
        };
        if(defined $r_barOnlineConfig) {
          if(ref $r_barOnlineConfig eq 'HASH' && ref $r_barOnlineConfig->{setups} eq 'ARRAY') {
            my $osString=$win?'win':'linux';
            my $idFilter = $release eq 'bar' ? "manual-$osString" : "manual-$osString-test-engine";
            my @tagRegexps=map {buildTagRegexp($_)} @{$r_githubInfo->{tags}};
            foreach my $r_barSetup (@{$r_barOnlineConfig->{setups}}) {
              next unless(ref $r_barSetup eq 'HASH' && ref $r_barSetup->{package} eq 'HASH');
              my $r_barPackage=$r_barSetup->{package};
              next unless(defined $r_barPackage->{id} && ref $r_barPackage->{id} eq '' && $r_barPackage->{id} eq $idFilter);
              if(ref $r_barSetup->{downloads} eq 'HASH' && ref $r_barSetup->{downloads}{resources} eq 'ARRAY') {
                foreach my $r_dlInfo (@{$r_barSetup->{downloads}{resources}}) {
                  next unless(ref $r_dlInfo eq 'HASH' && defined $r_dlInfo->{url} && ref $r_dlInfo->{url} eq '');
                  my $engineUrl=_unescapeUrl($r_dlInfo->{url});
                  next unless($engineUrl =~ /^https:\/\/github\.com\/[\w\.\-]+\/[\w\.\-]+\/releases\/download\/([^\/]+)\//);
                  my $releaseTag=$1;
                  foreach my $tagRegexp (@tagRegexps) {
                    return ($1,$releaseTag) if($releaseTag =~ /^$tagRegexp$/);
                  }
                }
              }
              $sl->log("Unable to find $enginePrefix engine release tag in Beyond All Reason JSON config file",2) unless($ignoreUnexistingRelease);
              return (undef,undef);
            }
            $sl->log("Unable to find engine setup package in Beyond All Reason JSON config file to retrieve $enginePrefix engine version number",2);
          }
        }else{
          my $jsonDecodeError='unknown error';
          if($@) {
            chomp($@);
            $jsonDecodeError=$@;
          }
          $sl->log("Failed to parse Beyond All Reason JSON config file to retrieve $enginePrefix engine version number: $jsonDecodeError",2);
        }
      }else{
        my $errorMsg = $httpRes->{status} == 599 ? $httpRes->{content} : "HTTP status: $httpRes->{status}, reason: $httpRes->{reason}";
        chomp($errorMsg);
        $sl->log("Failed to download Beyond All Reason JSON config file to retrieve $enginePrefix engine version number: $errorMsg",2);
      }
      return (undef,undef);
    }
    my $ghRepo=$r_githubInfo->{owner}.'/'.$r_githubInfo->{name};
    my @tagRegexps=map {buildTagRegexp($_)} @{$r_githubInfo->{tags}};
    my $errMsg="Unable to retrieve engine version number for $release release";
    if($release eq 'stable') {
      my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"https://github.com/$ghRepo/releases/latest");
      if($httpRes->{success} && ref $httpRes->{redirects} eq 'ARRAY' && @{$httpRes->{redirects}} && defined $httpRes->{url}) {
        my $redirectedUrl=_unescapeUrl($httpRes->{url});
        my $failureReason;
        if($redirectedUrl =~ /^https:\/\/github\.com\/([\w\.\-]+\/[\w\.\-]+)\/releases\/tag\/(.+)$/) {
          my ($redirectedGhRepo,$releaseTag)=($1,$2);
          $sl->log("GitHub repository \"$ghRepo\" has been renamed to \"$redirectedGhRepo\"",2)
              if($redirectedGhRepo ne $ghRepo);
          foreach my $tagRegexp (@tagRegexps) {
            return ($1,$releaseTag) if($releaseTag =~ /^$tagRegexp$/);
          }
          $failureReason="URL for latest release \"$redirectedUrl\" doesn't match tag template \"".join('|',@{$r_githubInfo->{tags}})."\"" unless($ignoreUnexistingRelease);
        }else{
          $failureReason="unexpected URL for latest release \"$redirectedUrl\"";
        }
        $sl->log($errMsg." ($failureReason)",2) if(defined $failureReason);
        return (undef,undef);
      }
      $sl->log($errMsg." from GitHub repository \"$ghRepo\"",2);
      return (undef,undef);
    }else{
      my $r_releases=$self->_getGithubRepositoryReleases($ghRepo);
      if(! defined $r_releases) {
        $sl->log($errMsg,2);
        return (undef,undef);
      }
      if(! @{$r_releases}) {
        $sl->log($errMsg.' (no release found on GitHub repository \"$ghRepo\")',2);
        return (undef,undef);
      }
      my $releaseWithLabelOnly = $release eq 'testing';
      foreach my $r_release (@{$r_releases}) {
        my ($releaseTag,$r_releaseLabels)=@{$r_release};
        next if($releaseWithLabelOnly && ! %{$r_releaseLabels});
        foreach my $tagRegexp (@tagRegexps) {
          return ($1,$releaseTag) if($releaseTag =~ /^$tagRegexp$/);
        }
      }
      $sl->log($errMsg.' (no release '.($releaseWithLabelOnly ? 'with label ' : '')."found matching tag template \"".join('|',@{$r_githubInfo->{tags}})."\" on GitHub repository \"$ghRepo\")",2);
      return (undef,undef);
    }
  }
  if($release eq 'stable') {
    my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"$springVersionUrl.Stable");
    if($httpRes->{success} && $httpRes->{content} =~ /id="mw-content-text".*>([^<>]+)\n/) {
      return ($1);
    }else{
      $sl->log("Unable to retrieve Spring version number for $release release",2);
      return (undef);
    }
  }elsif($release eq 'testing') {
    my $testingRelease;
    my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"$springVersionUrl.Testing");
    if($httpRes->{success} && $httpRes->{content} =~ /id="mw-content-text".*>([^<>]+)\n/) {
      $testingRelease=$1;
    }else{
      $sl->log("Unable to retrieve Spring version number for $release release",2);
    }
    my $latestMasterVersion=$self->_getSpringBranchLatestVersion($SPRING_MASTER_BRANCH);
    if(defined $testingRelease) {
      if(defined $latestMasterVersion) {
        return $testingRelease gt $latestMasterVersion ? ($testingRelease) : ($latestMasterVersion);
      }else{
        return ($testingRelease);
      }
    }elsif(defined $latestMasterVersion) {
      return ($latestMasterVersion);
    }
    return (undef);
  }elsif($release eq 'unstable') {
    return ($self->_getSpringBranchLatestVersion($SPRING_DEV_BRANCH,1));
  }else{
    return ($self->_getSpringBranchLatestVersion($release));
  }
}

sub _getSpringBranchLatestVersion {
  my ($self,$springBranch,$ignoreUnexistingBranch)=@_;
  my $sl=$self->{sLog};
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"$springBuildbotUrl/$springBranch/LATEST_$archName");
  if($httpRes->{success} && defined $httpRes->{content}) {
    if($springBranch eq $SPRING_MASTER_BRANCH) {
      my $latestVersion=$httpRes->{content};
      chomp($latestVersion);
      return $latestVersion;
    }
    my $quotedBranch=quotemeta($springBranch);
    return $1 if($httpRes->{content} =~ /^{$quotedBranch}(.+)$/);
  }
  $sl->log("Unable to retrieve latest Spring version number for $springBranch branch!",2) unless($ignoreUnexistingBranch);
  return undef;
}

# Called by spadsInstaller.pl
sub getAvailableSpringVersions {
  my ($self,$branch,$ignoreUnexistingBranch)=@_;
  my $sl=$self->{sLog};
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"$springBuildbotUrl/$branch/");
  my @versions;
  @versions=$httpRes->{content} =~ /href="([^"]+)\/">\1\//g if($httpRes->{success});
  $sl->log("Unable to get available Spring versions for branch \"$branch\"",2) unless(@versions || $ignoreUnexistingBranch);
  return \@versions;
}

sub _getHttpErrMsg {
  my $httpRes=shift;
  if($httpRes->{status} == 599) {
    my $errMsg=$httpRes->{content};
    chomp($errMsg);
    return $errMsg;
  }
  return "HTTP $httpRes->{status} $httpRes->{reason}";
}

sub _getGithubRepositoryReleasesPage {
  my ($httpTiny,$ghRepo,$pageNb)=@_;

  my $httpRes=$httpTiny->request('GET','https://github.com/'.$ghRepo.'/releases?page='.$pageNb);
  return (undef,_getHttpErrMsg($httpRes)) unless($httpRes->{success});
  my $redirectedGhRepo;
  ($redirectedGhRepo,$ghRepo)=($1,$1)
      if(ref $httpRes->{redirects} eq 'ARRAY' && @{$httpRes->{redirects}} && defined $httpRes->{url}
         && _unescapeUrl($httpRes->{url}) =~ /^https:\/\/github\.com\/([\w\.\-]+\/[\w\.\-]+)\/releases/
         && $ghRepo ne $1);
  my @htmlTagsAndDetails = $httpRes->{content} =~ /\Q<a href="\/$ghRepo\/releases\/tag\/\E([^\"]+)\"(.+?)\Q src="https:\/\/github.com\/$ghRepo\/releases\/expanded_assets\/\E\1"/sg;
  my @results;
  for my $i (0..@htmlTagsAndDetails/2-1) {
    my %labels;
    map {$labels{$_}=1 if(index($htmlTagsAndDetails[$i*2+1],'>'.$_.'<') != -1)} (qw'Pre-release Latest');
    push(@results,[_unescapeUrl($htmlTagsAndDetails[$i*2]),\%labels]);
  }

  return (\@results,undef,$redirectedGhRepo);
}

sub _getGithubRepositoryReleases {
  my ($self,$ghRepo)=@_;
  my $sl=$self->{sLog};
  
  my $httpTiny=HTTP::Tiny->new(timeout => 10);
  my ($r_releases,$failureReason,$redirectedGhRepo)=_getGithubRepositoryReleasesPage($httpTiny,$ghRepo,1);
  if(! defined $r_releases) {
    $sl->log("Failed to retrieve the list of latest releases for GitHub repository \"$ghRepo\": $failureReason",2);
    return undef;
  }
  if(defined $redirectedGhRepo) {
    $sl->log("GitHub repository \"$ghRepo\" has been renamed to \"$redirectedGhRepo\"",2);
    ($redirectedGhRepo,$ghRepo)=($ghRepo,$redirectedGhRepo);
  }
  return [] unless(@{$r_releases});
  my $lastRelease=$r_releases->[0][0];
  return $self->{ghReleasesCache}{$ghRepo}{releasesList}
    if(exists $self->{ghReleasesCache} && exists $self->{ghReleasesCache}{$ghRepo} && exists $self->{ghReleasesCache}{$ghRepo}{releasesHash}{$lastRelease});
  
  my $ghReleasesCacheFile=catfile($self->{springDir},'githubReleasesCache.dat');
  my $ghReleasesCacheLockFile=$ghReleasesCacheFile.'.lock';
  my $ghReleasesCacheLockFh;
  if(! open($ghReleasesCacheLockFh,'>',$ghReleasesCacheLockFile)) {
    $sl->log("Failed to open GitHub releases cache lock file \"$ghReleasesCacheLockFile\": $!",1);
    return undef;
  }
  if(! flock($ghReleasesCacheLockFh,LOCK_EX)) {
    close($ghReleasesCacheLockFh);
    $sl->log("Failed to acquire exclusive lock on GitHub releases cache data: $!",1);
    return undef;
  }
  if(-f $ghReleasesCacheFile) {
    my $r_cache=retrieve($ghReleasesCacheFile);
    if(defined $r_cache) {
      $self->{ghReleasesCache}=$r_cache;
      if(exists $self->{ghReleasesCache}{$ghRepo} && exists $self->{ghReleasesCache}{$ghRepo}{releasesHash}{$lastRelease}) {
        close($ghReleasesCacheLockFh);
        return $self->{ghReleasesCache}{$ghRepo}{releasesList};
      }
    }else{
      $sl->log("Failed to retrieve cached GitHub releases data from \"$ghReleasesCacheFile\"",2);
    }
  }
  if(! exists $self->{ghReleasesCache}{$ghRepo}) {
    if(defined $redirectedGhRepo && exists $self->{ghReleasesCache}{$redirectedGhRepo}) {
      $sl->log("Initializing releases cache of GitHub repository \"$ghRepo\" from renamed repository \"$redirectedGhRepo\"",3);
      $self->{ghReleasesCache}{$ghRepo}=$self->{ghReleasesCache}{$redirectedGhRepo};
    }else{
      $sl->log("Initializing releases cache for GitHub repository \"$ghRepo\"",3);
      $self->{ghReleasesCache}{$ghRepo}={releasesList => [],
                                         releasesHash => {}};
    }
  }
  my $r_alreadyKnownReleases=$self->{ghReleasesCache}{$ghRepo}{releasesHash};
  my (@newReleases,%alreadyProcessedNewReleases);
  my $pageNb=1;
  HTTP_REQUEST_LOOP: while(1) {
    foreach my $r_release (@{$r_releases}) {
      my $newRelease=$r_release->[0];
      next if($alreadyProcessedNewReleases{$newRelease}); # this might happen each time a new release is created between two releases pages retrievals, thus shifting all release pages by one release...
      last HTTP_REQUEST_LOOP if(exists $r_alreadyKnownReleases->{$newRelease});
      push(@newReleases,$r_release);
      $alreadyProcessedNewReleases{$newRelease}=1;
    }
    if(++$pageNb > 1000) {
      $sl->log("Too many GitHub release pages scanned while trying to get all releases from repository \"$ghRepo\", giving up",1);
      close($ghReleasesCacheLockFh);
      return undef;
    }
    ($r_releases,$failureReason)=_getGithubRepositoryReleasesPage($httpTiny,$ghRepo,$pageNb);
    if(! defined $r_releases) {
      $sl->log("Failed to retrieve page $pageNb of the releases list from GitHub repository \"$ghRepo\": $failureReason",1);
      close($ghReleasesCacheLockFh);
      return undef;
    }
    if(! @{$r_releases}) {
      $sl->log("The full list of releases was retrieved for GitHub repository \"$ghRepo\", but previously cached releases were NOT found (some releases might have been deleted from repository)",2)
          if(%{$r_alreadyKnownReleases});
      last;
    }
  }
  unshift(@{$self->{ghReleasesCache}{$ghRepo}{releasesList}},@newReleases);
  map {$self->{ghReleasesCache}{$ghRepo}{releasesHash}{$_->[0]}=$_->[1]} @newReleases;
  nstore($self->{ghReleasesCache},$ghReleasesCacheFile)
      or $sl->log("Failed to store GitHub releases data to cache file \"$ghReleasesCacheFile\"",2);
  close($ghReleasesCacheLockFh);
  return $self->{ghReleasesCache}{$ghRepo}{releasesList};
}

# Called by spadsInstaller.pl
sub checkEngineReleasesFromGithub {
  my ($self,$r_githubInfo)=@_;
  my $sl=$self->{sLog};

  my $httpTiny=HTTP::Tiny->new(timeout => 10);
  my $ghRepo=$r_githubInfo->{owner}.'/'.$r_githubInfo->{name};

  my $r_releases=$self->_getGithubRepositoryReleases($ghRepo);
  return (undef,undef,undef,undef) unless(defined $r_releases);
  if(! @{$r_releases}) {
    $sl->log("No release found on GitHub repository \"$ghRepo\"",2);
    return ([],{},undef,undef);
  }

  my @tagRegexps=map {buildTagRegexp($_)} @{$r_githubInfo->{tags}};
  my (@orderedVersionsAndTags,%engineVersionToReleaseTag,$testingVersion,$unstableVersion);
  foreach my $r_release (@{$r_releases}) {
    my ($releaseTag,$r_releaseLabels)=@{$r_release};
    my $releaseVersion;
    foreach my $tagRegexp (@tagRegexps) {
      if($releaseTag =~ /^$tagRegexp$/) {
        $releaseVersion=$1;
        last;
      }
    }
    next unless(defined $releaseVersion);
    $engineVersionToReleaseTag{$releaseVersion}=$releaseTag;
    push(@orderedVersionsAndTags,[$releaseVersion,$releaseTag]);
    $unstableVersion//=$releaseVersion;
    next unless(%{$r_releaseLabels});
    $testingVersion//=$releaseVersion;
  }
  if(! %engineVersionToReleaseTag) {
    $sl->log("No release found matching tag template \"".join('|',@{$r_githubInfo->{tags}})."\" on GitHub repository \"$ghRepo\"",2);
  }elsif(! defined $testingVersion) {
    $sl->log("No release with label found matching tag template \"".join('|',@{$r_githubInfo->{tags}})."\" on GitHub repository \"$ghRepo\"",2);
  }
  return (\@orderedVersionsAndTags,\%engineVersionToReleaseTag,$testingVersion,$unstableVersion);
}

# Called by spadsInstaller.pl, spads.pl
sub getEngineDir {
  my ($self,$engineVersion,$r_githubInfo)=@_;
  if(! exists $self->{springDir}) {
    my $engineStr = defined $r_githubInfo ? 'engine' : 'Spring';
    $self->{sLog}->log("Unable to get $engineStr directory for version $engineVersion, no base $engineStr directory specified!",1);
    return undef;
  }
  my @springDirPath=$self->{springDir};
  push(@springDirPath,$r_githubInfo->{subdir}) if(defined $r_githubInfo);
  return catdir(@springDirPath,"$engineVersion-$archName");
}

sub _compareSpringVersions ($$) {
  my ($v1,$v2)=@_;
  my (@v1VersionNbs,$v1CommitNb,@v2VersionNbs,$v2CommitNb);
  if($v1 =~ /^(\d+(?:\.\d+)*)(.*)$/) {
    my ($v1NbsString,$v1Remaining)=($1,$2);
    @v1VersionNbs=split(/\./,$v1NbsString);
    $v1CommitNb=$1 if($v1Remaining =~ /^-(\d+)-/);
  }else{
    return undef;
  }
  if($v2 =~ /^(\d+(?:\.\d+)*)(.*)$/) {
    my ($v2NbsString,$v2Remaining)=($1,$2);
    @v2VersionNbs=split(/\./,$v2NbsString);
    $v2CommitNb=$1 if($v2Remaining =~ /^-(\d+)-/);
  }else{
    return undef;
  }
  my $lastVersionNbIndex=max($#v1VersionNbs,$#v2VersionNbs);
  for my $i (0..$lastVersionNbIndex) {
    my $numCmp=($v1VersionNbs[$i]//0) <=> ($v2VersionNbs[$i]//0);
    return $numCmp if($numCmp);
  }
  return ($v1CommitNb//0) <=> ($v2CommitNb//0);
}

sub _getSpringRequiredFiles {
  my $springVersion=shift;
  my @requiredFiles = $win ?
      (qw'spring-dedicated.exe spring-headless.exe unitsync.dll zlib1.dll')
      : (qw'libunitsync.so spring-dedicated spring-headless');
  if($win) {
    if(_compareSpringVersions($springVersion,92) < 0) {
      push(@requiredFiles,'mingwm10.dll');
    }elsif(_compareSpringVersions($springVersion,95) < 0) {
      push(@requiredFiles,'pthreadGC2.dll');
    }
    if(_compareSpringVersions($springVersion,'104.0.1-1398-') < 0) {
      push(@requiredFiles,'DevIL.dll');
    }else{
      push(@requiredFiles,'libIL.dll');
    }
    if(_compareSpringVersions($springVersion,'104.0.1-1058-') > 0) {
      push(@requiredFiles,'libcurl.dll');
    }
  }
  return \@requiredFiles;
}

sub _checkEngineDir {
  my ($engineDir,$engineVersion)=@_;
  return wantarray ? (undef,['base']) : undef unless(-d "$engineDir/base");
  my $p_requiredFiles=_getSpringRequiredFiles($engineVersion);
  my @missingFiles=grep {! -f "$engineDir/$_" && $_ ne 'libcurl.dll'} @{$p_requiredFiles};
  return wantarray ? (undef,[@missingFiles]) : undef if(@missingFiles);
  return wantarray ? ($engineDir,[]) : $engineDir;
}

# Called by spads.pl
sub isUpdateInProgress {
  my $self=shift;
  my $lockFile=catfile($self->{localDir},'SpadsUpdater.lock');
  my $res=0;
  if(open(my $lockFh,'>',$lockFile)) {
    if(flock($lockFh, LOCK_EX|LOCK_NB)) {
      flock($lockFh, LOCK_UN);
    }else{
      $res=1;
    }
    close($lockFh);
  }else{
    $self->{sLog}->log("Unable to write SpadsUpdater lock file \"$lockFile\" ($!)",1);
  }
  return $res;
}

# Called by spads.pl
sub isEngineSetupInProgress {
  my ($self,$version,$r_githubInfo)=@_;
  my $engineDir=$self->getEngineDir($version,$r_githubInfo);
  return 0 unless(defined $engineDir && -e $engineDir);
  my $engineSetupLockFileBasename = (defined $r_githubInfo ? 'Engine' : 'Spring').'Setup';
  my $lockFile=catfile($engineDir,$engineSetupLockFileBasename.'.lock');
  my $res=0;
  if(open(my $lockFh,'>',$lockFile)) {
    if(flock($lockFh, LOCK_EX|LOCK_NB)) {
      flock($lockFh, LOCK_UN);
    }else{
      $res=1;
    }
    close($lockFh);
  }else{
    $self->{sLog}->log("Unable to write $engineSetupLockFileBasename lock file \"$lockFile\" ($!)",1);
  }
  return $res;
}

sub _autoRetry {
  my ($p_f,$retryNb,$delayMs)=@_;
  $retryNb//=20;
  $delayMs//=100;
  my $delayUs=1000*$delayMs;
  my $res=&{$p_f}();
  while(! $res) {
    return 0 unless($retryNb--);
    Time::HiRes::usleep($delayUs);
    $res=&{$p_f}();
  }
  return $res;
}

# Called by spadsInstaller.pl, spads.pl, updater.pl
sub update {
  my ($self,undef,$force)=@_;
  my $sl=$self->{sLog};
  my $lockFile=catfile($self->{localDir},'SpadsUpdater.lock');
  my $lockFh;
  if(! open($lockFh,'>',$lockFile)) {
    $sl->log("Unable to write SpadsUpdater lock file \"$lockFile\" ($!)",1);
    return -2;
  }
  if(! _autoRetry(sub {flock($lockFh, LOCK_EX|LOCK_NB)})) {
    $sl->log('Another instance of SpadsUpdater is already running in same directory',2);
    close($lockFh);
    return -1;
  }
  my $res=$self->_updateLockProtected($force);
  flock($lockFh, LOCK_UN);
  close($lockFh);
  return $res;
}

sub downloadFile {
  my ($self,$url,$file)=@_;
  my $sl=$self->{sLog};
  if($url !~ /^http:\/\//i) {
    if($url =~ /^https:\/\//i) {
      if(! checkHttpsSupport()) {
        $sl->log("Unable to to download file to \"$file\", IO::Socket::SSL version 1.42 or superior and Net::SSLeay version 1.49 or superior are required for SSL support",1);
        return 0;
      }
    }else{
      $sl->log("Unable to download file to \"$file\", unknown URL type \"$url\"",1);
      return 0;
    }
  }
  $sl->log("Downloading file from \"$url\" to \"$file\"...",5);
  my $fh;
  if(! open($fh,'>',$file)) {
    $sl->log("Unable to write file \"$file\" for download: $!",1);
    $_[3]=-1;
    return 0;
  }
  binmode $fh;
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$url,{data_callback => sub { print {$fh} $_[0] }});
  if(! close($fh)) {
    $sl->log("Error while closing file \"$file\" after download: $!",1);
    unlink($file);
    $_[3]=-2;
    return 0;
  }
  if(! $httpRes->{success} || ! -f $file) {
    $sl->log("Failed to download file from \"$url\" to \"$file\" (HTTP status: $httpRes->{status})",5);
    unlink($file);
    $_[3]=$httpRes->{status};
    return 0;
  }
  $sl->log("File downloaded from \"$url\" to \"$file\" (HTTP status: $httpRes->{status})",5);
  return 1;
}

sub _renameToBeDeleted {
  my $fileName=shift;
  my $i=1;
  while(-f "$fileName.$i.toBeDeleted" && $i < 100) {
    $i++;
  }
  return move($fileName,"$fileName.$i.toBeDeleted");
}

sub _updateLockProtected {
  my ($self,$force)=@_;
  $force//=0;
  my $sl=$self->{sLog};

  my %currentPackages;
  my $updateInfoFile=catfile($self->{localDir},'updateInfo.txt');
  if(-f $updateInfoFile) {
    if(open(UPDATE_INFO,'<',$updateInfoFile)) {
      while(local $_ = <UPDATE_INFO>) {
        $currentPackages{$1}=$2 if(/^([^:]+):(.+)$/);
      }
      close(UPDATE_INFO);
    }else{
      $sl->log("Unable to read \"$updateInfoFile\" file",1);
      return -3;
    }
  }

  my $release = substr($self->{release},0,3) eq 'git' ? 'unstable' : $self->{release};
  my %allAvailablePackages;
  if(! $self->downloadFile($self->{packagesIndexUrl},'packages.txt')) {
    $sl->log("Unable to download package list",1);
    return -4;
  }
  if(open(PACKAGES,"<packages.txt")) {
    my $currentSection="";
    while(local $_ = <PACKAGES>) {
      if(/^\s*\[([^\]]+)\]/) {
        $currentSection=$1;
        $allAvailablePackages{$currentSection}={} unless(exists $allAvailablePackages{$currentSection});
      }elsif(/^([^:]+):(.+)$/) {
        $allAvailablePackages{$currentSection}->{$1}=$2;
      }
    }
    close(PACKAGES);
    unlink("packages.txt");
  }else{
    $sl->log("Unable to read downloaded package list",1);
    unlink("packages.txt");
    return -5;
  }

  if(! exists $allAvailablePackages{$release}) {
    $sl->log("Unable to find any package for release \"$release\"",1);
    return -6;
  }

  my %availablePackages=%{$allAvailablePackages{$release}};
  my @updatedPackages;
  foreach my $packageName (@{$self->{packages}}) {
    if(! exists $availablePackages{$packageName}) {
      $sl->log("No \"$packageName\" package available for $release SPADS release",2);
      next;
    }
    my $currentVersion="_UNKNOWN_";
    $currentVersion=$currentPackages{$packageName} if(exists $currentPackages{$packageName});
    my $availableVersion=$availablePackages{$packageName};
    $availableVersion=$1 if($availableVersion =~ /^(.+)\.zip$/);
    if($currentVersion ne $availableVersion) {
      if(! $force) {
        if($currentVersion =~ /_([\d\.]+)\.\w+\.[^\.]+$/) {
          my $currentMajor=$1;
          if($availableVersion =~ /_([\d\.]+)\.\w+\.[^\.]+$/) {
            my $availableMajor=$1;
            if($currentMajor ne $availableMajor) {
              $sl->log("Major version number of package $packageName has changed ($currentVersion -> $availableVersion), which means that it requires manual operations before update.",2);
              $sl->log("Please follow the SPADS upgrade procedure described here: https://github.com/Yaribz/SPADS/blob/master/UPDATE.md",2);
              return -7;
            }
          }
        }
      }
      my $updateMsg="Updating package \"$packageName\"";
      $updateMsg.=" from \"$currentVersion\"" unless($currentVersion eq "_UNKNOWN_");
      $sl->log("$updateMsg to \"$availableVersion\"",4);
      if($availablePackages{$packageName} =~ /\.zip$/) {
        if(! $self->downloadFile("$self->{repository}/$availableVersion.zip",catfile($self->{localDir},"$availableVersion.zip"))) {
          $sl->log("Unable to download package \"$availableVersion.zip\"",1);
          return -8;
        }
        if(! unzip("$self->{localDir}/$availableVersion.zip","$self->{localDir}/$availableVersion",{BinModeOut=>1})) {
          $sl->log("Unable to unzip package \"$availableVersion.zip\" (".($UnzipError//'unknown error').')',1);
          unlink("$self->{localDir}/$availableVersion.zip");
          return -9;
        }
        unlink("$self->{localDir}/$availableVersion.zip");
        $availablePackages{$packageName}=$availableVersion;
      }else{
        if(! $self->downloadFile("$self->{repository}/$availableVersion",catfile($self->{localDir},"$availableVersion.tmp"))) {
          $sl->log("Unable to download package \"$availableVersion\"",1);
          return -8;
        }
        if(! move("$self->{localDir}/$availableVersion.tmp","$self->{localDir}/$availableVersion")) {
          $sl->log("Unable to rename package \"$availableVersion\"",1);
          unlink("$self->{localDir}/$availableVersion.tmp");
          return -9;
        }
      }
      chmod(0755,"$self->{localDir}/$availableVersion") if($availableVersion =~ /\.(pl|py)$/ || index($packageName,'.') == -1);
      push(@updatedPackages,$packageName);
    }
  }
  foreach my $updatedPackage (@updatedPackages) {
    my $updatedPackagePath=catfile($self->{localDir},$updatedPackage);
    my $versionedPackagePath=catfile($self->{localDir},$availablePackages{$updatedPackage});
    unlink($updatedPackagePath);
    if($win) {
      next if(-f $updatedPackagePath && (! _renameToBeDeleted($updatedPackagePath)) && $updatedPackage =~ /\.(exe|dll)$/);
      if(! copy($versionedPackagePath,$updatedPackagePath)) {
        $sl->log("Unable to copy \"$versionedPackagePath\" to \"$updatedPackagePath\", system consistency must be checked manually !",0);
        return -10;
      }
    }else{
      if(! symlink($availablePackages{$updatedPackage},$updatedPackagePath)) {
        $sl->log("Unable to create symbolic link from \"$updatedPackagePath\" to \"$versionedPackagePath\", system consistency must be checked manually !",0);
        return -10;
      }
    }
  }

  my $nbUpdatedPackage=$#updatedPackages+1;
  if($nbUpdatedPackage) {
    foreach my $updatedPackage (@updatedPackages) {
      $currentPackages{$updatedPackage}=$availablePackages{$updatedPackage};
    }
    if(open(UPDATE_INFO,'>',$updateInfoFile)) {
      print UPDATE_INFO time."\n";
      foreach my $currentPackage (keys %currentPackages) {
        print UPDATE_INFO "$currentPackage:$currentPackages{$currentPackage}\n";
      }
      close(UPDATE_INFO);
    }else{
      $sl->log("Unable to write update information to \"$updateInfoFile\" file",1);
      return -11;
    }
    $sl->log("$nbUpdatedPackage package(s) updated",3);
  }

  return $nbUpdatedPackage;
}

sub _getSpringVersionBranch {
  return shift =~ /^\d+\.\d+$/ ? $SPRING_MASTER_BRANCH : $SPRING_DEV_BRANCH;
}

sub _getEngineVersionDownloadInfo {
  my ($version,$springBranchOrGithubTag,$r_githubInfo)=@_;
  if(defined $r_githubInfo) {
    my ($assetUrl,$errorMsg)=_getEngineGithubDownloadUrl($version,$springBranchOrGithubTag,$r_githubInfo);
    return ($errorMsg) if(defined $errorMsg);
    if($assetUrl =~ /^(.+\/)([^\/]+)$/) {
      return (undef,$1,undef,$2);
    }else{
      return ("unknown format for GitHub release asset URL \"$assetUrl\"");
    }
  }
  my $branch=$springBranchOrGithubTag//_getSpringVersionBranch($version);
  my $versionInArchives = $branch eq $SPRING_MASTER_BRANCH ? $version : "{$branch}$version";
  my ($requiredArchive,@optionalArchives);
  if($win) {
    $requiredArchive="spring_${versionInArchives}_".(_compareSpringVersions($version,102)<0?'':"$archName-").'minimal-portable.7z';
    @optionalArchives=("${versionInArchives}_spring-dedicated.7z","${versionInArchives}_spring-headless.7z")
  }else{
    $requiredArchive="spring_${versionInArchives}_minimal-portable-$archName-static.7z";
    @optionalArchives=("${versionInArchives}_spring-dedicated-$archName-static.7z","${versionInArchives}_spring-headless-$archName-static.7z")
  }
  my $baseUrlRequired="$springBuildbotUrl/$branch/$version/".(_compareSpringVersions($version,91)<0?'':"$archName/");
  my $baseUrlOptional="$springBuildbotUrl/$branch/$version/".(_compareSpringVersions($version,92)<0?'':"$archName/");
  return (undef,$baseUrlRequired,$baseUrlOptional,$requiredArchive,@optionalArchives);
}

sub _checkSpringVersionAvailability {
  my ($self,$version,$springBranch)=@_;
  $springBranch//=_getSpringVersionBranch($version);
  my $p_availableVersions = $self->getAvailableSpringVersions($springBranch);
  return 'version unavailable for download' unless(any {$version eq $_} @{$p_availableVersions});
  my (undef,$baseUrlRequired,undef,$requiredArchive)=_getEngineVersionDownloadInfo($version,$springBranch);
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$baseUrlRequired);
  if($httpRes->{success}) {
    return undef if(index($httpRes->{content},">$requiredArchive<") != -1);
    return 'archive not found';
  }elsif($httpRes->{status} == 404) {
    return 'version unavailable for this architecture';
  }else{
    return "unable to check version availability, HTTP status:$httpRes->{status}";
  }
}

sub _getGithubRepositoryRefs {
  my ($httpTiny,$ghRepo,$refType)=@_;
  $refType//='tag';
  
  my $httpRes=$httpTiny->request('GET','https://github.com/'.$ghRepo.'/refs?type='.$refType,{headers => {Accept => 'application/json'}});
  return (undef,_getHttpErrMsg($httpRes)) unless($httpRes->{success});
  
  my $r_refsData;
  eval { $r_refsData=decode_json($httpRes->{content}) };
  if(! defined $r_refsData) {
    my $jsonDecodeError='unknown error';
    if($@) {
      $jsonDecodeError=$@;
      chomp($jsonDecodeError);
    }
    return (undef,'failed to parse JSON response: '.$jsonDecodeError);
  }

  return (undef,'missing "ref" array in JSON response')
      unless(ref $r_refsData eq 'HASH' && ref $r_refsData->{refs} eq 'ARRAY');

  return ($r_refsData->{refs},undef);
}

# Called by spadsInstaller.pl
sub getGithubDefaultBranch {
  my ($ghOwner,$ghName)=@_;
  my $ghRepo=$ghOwner.'/'.$ghName;
  my $httpTiny=HTTP::Tiny->new(timeout => 10);
  my $httpRes=$httpTiny->request('GET','https://github.com/'.$ghRepo.'/branches/');
  my $errMsg;
  if($httpRes->{success}) {
    return ($1,undef) if($httpRes->{content} =~ /\Q"defaultBranch":"\E([^"]+)"/s);
    $errMsg='expected data not found in HTML response';
  }else{
    $errMsg=_getHttpErrMsg($httpRes);
  }
  my ($r_branches,$fallbackErrMsg)=_getGithubRepositoryRefs($httpTiny,$ghRepo,'branch');
  if(defined $r_branches && ! @{$r_branches}) {
    undef $r_branches;
    $fallbackErrMsg='no branch found';
  }
  return (undef,"main error: $errMsg, workaround error: $fallbackErrMsg") unless(defined $r_branches);
  return ($r_branches->[0],$errMsg);
}

sub _getEngineGithubDownloadUrl {
  my ($version,$ghTag,$r_githubInfo)=@_;
  my $ghRepo=$r_githubInfo->{owner}.'/'.$r_githubInfo->{name};
  my @ghTags;
  if(defined $ghTag) {
    @ghTags=($ghTag);
  }else{
    @ghTags=@{$r_githubInfo->{tags}};
    my $defaultBranch;
    foreach my $tag (@ghTags) {
      $tag =~ s/\Q<version>\E/$version/g;
      next unless(index($tag,'<branch>') > -1);
      if(! defined $defaultBranch) {
        my $errMsg;
        ($defaultBranch,$errMsg)=getGithubDefaultBranch($r_githubInfo->{owner},$r_githubInfo->{name});
        return (undef,"unable to identify default branch of GitHub repository \"$ghRepo\", $errMsg")
            unless(defined $defaultBranch);
      }
      $tag =~ s/\Q<branch>\E/$defaultBranch/g;
    }
  }
  my @tagsWithNoMatchingAsset;
  my @notFoundTags;
  my %httpErrStatus;
  foreach my $relTag (@ghTags) {
    my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET','https://github.com/'.$ghRepo.'/releases/expanded_assets/'._escapeUrl($relTag));
    if($httpRes->{success}) {
      foreach my $assetTemplate (@{$r_githubInfo->{assets}}) {
        if($httpRes->{content} =~ /href="([^"]+\/$assetTemplate)"/) {
          my $assetUrl=$1;
          $assetUrl='https://github.com'.$assetUrl if(substr($assetUrl,0,1) eq '/');
          return ($assetUrl);
        }
      }
      push(@tagsWithNoMatchingAsset,$relTag);
    }elsif($httpRes->{status} == 404) {
      push(@notFoundTags,$relTag);
    }else{
      $httpErrStatus{$httpRes->{status}}=1;
    }
  }
  return (undef,'release not found on GitHub: invalid tag'.(@notFoundTags>1?'s':'').' "'.join(', ',@notFoundTags)."\" or invalid repository \"$ghRepo\"")
      unless(@tagsWithNoMatchingAsset || %httpErrStatus);
  my @errMsgs;
  push(@errMsgs,"no asset matching regular expression \"".join('|',@{$r_githubInfo->{assets}})."\" found in release".(@tagsWithNoMatchingAsset>1?'s':'').' "'.join(', ',@tagsWithNoMatchingAsset)."\" of GitHub repository \"$ghRepo\"")
      if(@tagsWithNoMatchingAsset);
  push(@errMsgs,'unable to check version availability, HTTP status: '.join(', ',sort keys %httpErrStatus))
      if(%httpErrStatus);
  return (undef,join(' + ',@errMsgs));
}

# Called by spadsInstaller.pl, spads.pl
sub setupEngine {
  my ($self,$version,$springBranchOrGithubTag,$r_githubInfo,$getPrdownloader)=@_;
  my $engineStr = defined $r_githubInfo ? 'engine' : 'Spring';
  
  my $sl=$self->{sLog};
  if($version !~ /^\d/) {
    $sl->log("Invalid $engineStr version \"$version\"",1);
    return -1;
  }

  my $engineDir=$self->getEngineDir($version,$r_githubInfo);
  return -1 unless(defined $engineDir);
  return 0 if(_checkEngineDir($engineDir,$version));

  if(defined $r_githubInfo) {
    my (undef,$unavailabilityMsg)=_getEngineGithubDownloadUrl($version,$springBranchOrGithubTag,$r_githubInfo);
    if(defined $unavailabilityMsg) {
      $sl->log("Installation aborted for engine version \"$version\" ($unavailabilityMsg)",1);
      return -10;
    }
  }else{
    my $unavailabilityMsg=$self->_checkSpringVersionAvailability($version,$springBranchOrGithubTag);
    if(defined $unavailabilityMsg) {
      $sl->log("Installation aborted for Spring version \"$version\" ($unavailabilityMsg)",1);
      return -10;
    }
  }

  if(! -e $engineDir) {
    eval { mkpath($engineDir) };
    if($@) {
      $sl->log("Unable to create directory \"$engineDir\" ($@)",1);
      return -2;
    }
    $sl->log("Created new directory \"$engineDir\" for automatic $engineStr installation",4);
  }
  
  my $engineSetupLockFileBasename=ucfirst($engineStr).'Setup';
  my $lockFile=catfile($engineDir,$engineSetupLockFileBasename.'.lock');
  my $lockFh;
  if(! open($lockFh,'>',$lockFile)) {
    $sl->log("Unable to write $engineSetupLockFileBasename lock file \"$lockFile\" ($!)",1);
    return -2;
  }
  if(! _autoRetry(sub {flock($lockFh, LOCK_EX|LOCK_NB)})) {
    $sl->log('Another instance of SpadsUpdater is already performing '.(defined $r_githubInfo ? 'an engine' : 'a Spring').' installation in same directory',2);
    close($lockFh);
    return -3;
  }
  my $res=$self->_setupEngineLockProtected($version,$springBranchOrGithubTag,$r_githubInfo,$engineDir,$getPrdownloader);
  flock($lockFh, LOCK_UN);
  close($lockFh);
  return $res;
}

sub _escapeWin32Parameter {
  my $arg = shift;
  $arg =~ s/(\\*)"/$1$1\\"/g;
  if($arg =~ /[ \t]/) {
    $arg =~ s/(\\*)$/$1$1/;
    $arg = "\"$arg\"";
  }
  return $arg;
}

sub _systemNoOutput {
  my ($program,@params)=@_;
  my @args=($program,@params);
  my ($exitCode,$exitErr);
  if($win) {
    system(join(' ',(map {_escapeWin32Parameter($_)} @args),'>'.devnull(),'2>&1'));
    ($exitCode,$exitErr)=($?,$!);
  }else{
    open(my $previousStdout,'>&',\*STDOUT);
    open(my $previousStderr,'>&',\*STDERR);
    open(STDOUT,'>',devnull());
    open(STDERR,'>&',\*STDOUT);
    system {$program} (@args);
    ($exitCode,$exitErr)=($?,$!);
    open(STDOUT,'>&',$previousStdout);
    open(STDERR,'>&',$previousStderr);
  }
  return (undef,$exitErr) if($exitCode == -1);
  return (undef,'child process interrupted by signal '.($exitCode & 127).($exitCode & 128 ? ', with coredump' : '')) if($exitCode & 127);
  return ($exitCode >> 8);
}

sub uncompress7zipFile {
  my ($self,$archiveFile,$destDir,@filesToExtract)=@_;
  my $sl=$self->{sLog};
  my $sevenZipBin=catfile($self->{localDir},$win?'7za.exe':'7za');
  $sl->log("Extracting sevenzip file \"$archiveFile\" into \"$destDir\"...",5);
  my $previousEnvLangValue=$ENV{LC_ALL};
  $ENV{LC_ALL}='C' unless($win);
  my ($exitCode,$errorMsg)=_systemNoOutput($sevenZipBin,'x','-y',"-o$destDir",$archiveFile,@filesToExtract);
  if(! $win) {
    if(defined $previousEnvLangValue) {
      $ENV{LC_ALL}=$previousEnvLangValue;
    }else{
      delete $ENV{LC_ALL};
    }
  }
  my $failReason;
  if(defined $errorMsg) {
    $failReason=", error while running 7zip ($errorMsg)";
  }elsif($exitCode != 0) {
    $failReason=" (7zip exit code: $exitCode)";
  }
  if(defined $failReason) {
    $sl->log("Failed to extract \"$archiveFile\"$failReason",1);
    return 0;
  }
  $sl->log("Extraction of sevenzip file \"$archiveFile\" into \"$destDir\" complete.",5);
  return 1;
}

sub _setupEngineLockProtected {
  my ($self,$version,$springBranchOrGithubTag,$r_githubInfo,$engineDir,$getPrdownloader)=@_;

  return 0 if(_checkEngineDir($engineDir,$version));
  
  my $engineStr = defined $r_githubInfo ? 'engine' : 'Spring';

  my $sl=$self->{sLog};
  $sl->log("Installing $engineStr $version into \"$engineDir\"...",3);

  my ($errorMsg,$baseUrlRequired,$baseUrlOptional,$requiredArchive,@optionalArchives)=_getEngineVersionDownloadInfo($version,$springBranchOrGithubTag,$r_githubInfo);
  if(defined $errorMsg) {
    $sl->log("Engine $version installation cancelled ($errorMsg)",1);
    return -10;
  }
  
  my $tmpArchive=catfile($engineDir,$requiredArchive);
  if(! $self->downloadFile($baseUrlRequired.$requiredArchive,$tmpArchive,my $httpStatus)) {
    if($httpStatus == 404 && ! defined $r_githubInfo) {
      $sl->log("No Spring $version package available for architecture $archName",2);
      return -11;
    }else{
      $sl->log("Unable to download $engineStr archive file from \"$baseUrlRequired$requiredArchive\" to \"$engineDir\" (HTTP status: $httpStatus)",1);
      return $httpStatus == 503 ? -9 : -12; # return codes < -9 are for permanent errors
    }
  }

  my $p_requiredFiles=_getSpringRequiredFiles($version);
  my @filesToExtract=@{$p_requiredFiles};
  push(@filesToExtract,'pr-downloader'.($win?'.exe':'')) if($getPrdownloader);
  if(! $self->uncompress7zipFile($tmpArchive,$engineDir,'base',@filesToExtract)) {
    unlink($tmpArchive);
    $sl->log("Unable to extract $engineStr archive \"$tmpArchive\"",1);
    return -13;
  }
  unlink($tmpArchive);

  foreach my $optionalArchive (@optionalArchives) {
    $tmpArchive=catfile($engineDir,$optionalArchive);
    if(! $self->downloadFile($baseUrlOptional.$optionalArchive,$tmpArchive,my $httpStatus)) {
      $sl->log("Unable to download $engineStr archive file \"$optionalArchive\" from \"$baseUrlOptional\" to \"$engineDir\" (HTTP status: $httpStatus)",1) if($httpStatus != 404);
    }else{
      if(! $self->uncompress7zipFile($tmpArchive,$engineDir,@{$p_requiredFiles})) {
        unlink($tmpArchive);
        $sl->log("Unable to extract $engineStr archive \"$tmpArchive\"",1);
        return -13;
      }
      unlink($tmpArchive);
    }
  }

  my ($installResult,$r_missingFiles)=_checkEngineDir($engineDir,$version);
  if($installResult) {
    $sl->log(ucfirst($engineStr)." $version installation complete.",3);
    return 1;
  }

  $sl->log("Unable to install $engineStr version $version (incomplete archive, missing files: ".join(',',@{$r_missingFiles}).')',1);
  return -14;
}

1;
