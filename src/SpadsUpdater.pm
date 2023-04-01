# Perl module used for Spads auto-updating functionnality
#
# Copyright (C) 2008-2023  Yann Riou <yaribzh@gmail.com>
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
use List::Util qw'any all none notall max';
use Time::HiRes;

my $win=$^O eq 'MSWin32' ? 1 : 0;
my $archName=($win?'win':'linux').($Config{ptrsize} > 4 ? 64 : 32);

our $VERSION='0.24';

my @constructorParams = qw'sLog repository release packages';
my @optionalConstructorParams = qw'localDir springDir';

my $springBuildbotUrl='http://springrts.com/dl/buildbot/default';
my $springVersionUrl='http://planetspads.free.fr/spring/SpringVersion';
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
  return $self;
}

sub _unescapeUrl {
  my $url=shift;
  $url =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
  return $url;
}

sub _buildTagRegexp { return join('(\d+(?:\.\d+){1,3}(?:-\d+-g[0-9a-f]+)?)',map {quotemeta($_)} split(/\Q<version>\E/,$_[0],-1)) }

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
  my $engineVersion=$self->resolveEngineReleaseNameToVersion($release,$r_githubInfo);
  return $engineVersion if(defined $engineVersion);
  my $releaseVersionFile=$self->_getEngineReleaseVersionCacheFile($release,$r_githubInfo);
  return undef unless(-f $releaseVersionFile);
  my $releaseVersionLockFile=$releaseVersionFile.'.lock';
  if(open(my $releaseVersionLockFh,'>',$releaseVersionLockFile)) {
    if(_autoRetry(sub {flock($releaseVersionLockFh, LOCK_EX|LOCK_NB)})) {
      if(open(my $releaseVersionFh,'<',$releaseVersionFile)) {
        $engineVersion=<$releaseVersionFh>;
        close($releaseVersionFh);
        if(defined $engineVersion) {
          chomp($engineVersion);
          $engineVersion=undef if($engineVersion eq '');
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
  return $engineVersion;
}

# Called by spads.pl, spadsInstaller.pl
sub resolveEngineReleaseNameToVersion {
  my ($self,$release,$r_githubInfo)=@_;
  my $sl=$self->{sLog};
  my $engineVersion=$self->_resolveEngineReleaseNameToVersion($release,$r_githubInfo);
  if(defined $engineVersion) {
    my ($releaseVersionPath,$releaseVersionFile)=$self->_getEngineReleaseVersionCacheFile($release,$r_githubInfo);
    if(! defined $self->{engineReleaseVersionCache}{$releaseVersionFile} || $self->{engineReleaseVersionCache}{$releaseVersionFile} ne $engineVersion) {
      $self->{engineReleaseVersionCache}{$releaseVersionFile}=$engineVersion;
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
              print $releaseVersionFh $engineVersion;
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
  }
  return $engineVersion;
}

sub _resolveEngineReleaseNameToVersion {
  my ($self,$release,$r_githubInfo)=@_;
  my $sl=$self->{sLog};
  if(defined $r_githubInfo) {
    if($release eq 'stable') {
      my $ghRepo=$r_githubInfo->{owner}.'/'.$r_githubInfo->{name};
      my $ghRepoUrl='https://github.com/'.$ghRepo.'/';
      my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$ghRepoUrl.'releases/latest');
      if($httpRes->{success} && ref $httpRes->{redirects} eq 'ARRAY' && @{$httpRes->{redirects}} && defined $httpRes->{url}) {
        my $redirectedUrl=_unescapeUrl($httpRes->{url});
        my $tagBaseUrl=$ghRepoUrl.'releases/tag/';
        my $tagBaseUrlLength=length($tagBaseUrl);
        my $tagRegexp=_buildTagRegexp($r_githubInfo->{tag});
        return $1
            if(length($redirectedUrl) > $tagBaseUrlLength && substr($redirectedUrl,0,$tagBaseUrlLength) eq $tagBaseUrl && substr($redirectedUrl,$tagBaseUrlLength) =~ /^$tagRegexp$/);
        $sl->log("Unable to retrieve engine version number for $release release (URL for latest release \"$redirectedUrl\" doesn't match tag template \"$r_githubInfo->{tag}\")",2);
        return undef;
      }
      $sl->log("Unable to retrieve engine version number for $release release from GitHub repository \"$ghRepo\"",2);
      return undef;
    }else{
      my $r_matchingVersions=$self->getAvailableEngineVersionsFromGithub($r_githubInfo);
      return $r_matchingVersions->[0];
    }
  }
  if($release eq 'stable') {
    my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"$springVersionUrl.Stable");
    if($httpRes->{success} && $httpRes->{content} =~ /id="mw-content-text".*>([^<>]+)\n/) {
      return $1;
    }else{
      $sl->log("Unable to retrieve Spring version number for $release release",2);
      return undef;
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
        return $testingRelease gt $latestMasterVersion ? $testingRelease : $latestMasterVersion;
      }else{
        return $testingRelease;
      }
    }elsif(defined $latestMasterVersion) {
      return $latestMasterVersion;
    }
    return undef;
  }elsif($release eq 'unstable') {
    return $self->_getSpringBranchLatestVersion($SPRING_DEV_BRANCH);
  }else{
    return $self->_getSpringBranchLatestVersion($release);
  }
}

sub _getSpringBranchLatestVersion {
  my ($self,$springBranch)=@_;
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
  $sl->log("Unable to retrieve latest Spring version number for $springBranch branch!",2);
  return undef;
}

# Called by spadsInstaller.pl
sub getAvailableSpringVersions {
  my ($self,$branch)=@_;
  my $sl=$self->{sLog};
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"$springBuildbotUrl/$branch/");
  my @versions;
  @versions=$httpRes->{content} =~ /href="([^"]+)\/">\1\//g if($httpRes->{success});
  $sl->log("Unable to get available Spring versions for branch \"$branch\"",2) unless(@versions);
  return \@versions;
}

# Called by spadsInstaller.pl
sub getAvailableEngineVersionsFromGithub {
  my ($self,$r_githubInfo)=@_;
  my $sl=$self->{sLog};
  my $ghRepo=$r_githubInfo->{owner}.'/'.$r_githubInfo->{name};
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET','https://github.com/'.$ghRepo.'/releases');
  if($httpRes->{success}) {
    my @versions = $httpRes->{content} =~ /\Q<a href="\/$ghRepo\/releases\/tag\/\E([^\"]+)\"/g;
    if(@versions) {
      my $tagRegexp=_buildTagRegexp($r_githubInfo->{tag});
      my @matchingVersions;
      map {push(@matchingVersions,$1) if(_unescapeUrl($_) =~ /^$tagRegexp$/)} @versions;
      return \@matchingVersions if(@matchingVersions);
    }
    $sl->log("Unable to find available engine releases matching tag template \"$r_githubInfo->{tag}\" from GitHub repository \"$ghRepo\"",2);
  }else{
    $sl->log("Unable to get available engine releases from GitHub repository \"$ghRepo\"",2);
  }
  return [];
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

  my %allAvailablePackages;
  if(! $self->downloadFile("$self->{repository}/packages.txt",'packages.txt')) {
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

  if(! exists $allAvailablePackages{$self->{release}}) {
    $sl->log("Unable to find any package for release \"$self->{release}\"",1);
    return -6;
  }

  my %availablePackages=%{$allAvailablePackages{$self->{release}}};
  my @updatedPackages;
  foreach my $packageName (@{$self->{packages}}) {
    if(! exists $availablePackages{$packageName}) {
      $sl->log("No \"$packageName\" package available for $self->{release} SPADS release",2);
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
  my ($version,$r_githubInfoOrSpringBranch)=@_;
  if(ref $r_githubInfoOrSpringBranch) {
    my ($assetUrl,$errorMsg)=_getEngineGithubDownloadUrl($version,$r_githubInfoOrSpringBranch);
    return ($errorMsg) if(defined $errorMsg);
    if($assetUrl =~ /^(.+\/)([^\/]+)$/) {
      return (undef,$1,undef,$2);
    }else{
      return ("unknown format for GitHub release asset URL \"$assetUrl\"");
    }
  }
  my $branch=$r_githubInfoOrSpringBranch//_getSpringVersionBranch($version);
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

sub _getEngineGithubDownloadUrl {
  my ($version,$r_githubInfo)=@_;
  my $ghTag=$r_githubInfo->{tag};
  $ghTag =~ s/\Q<version>\E/$version/g;
  my $ghRepo=$r_githubInfo->{owner}.'/'.$r_githubInfo->{name};
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET','https://github.com/'.$ghRepo.'/releases/expanded_assets/'.$ghTag);
  if($httpRes->{success}) {
    if($httpRes->{content} =~ /href="([^"]+\/$r_githubInfo->{asset})"/) {
      my $assetUrl=$1;
      $assetUrl='https://github.com'.$assetUrl if(substr($assetUrl,0,1) eq '/');
      return ($assetUrl);
    }else{
      return (undef,"no asset matching regular expression \"$r_githubInfo->{asset}\" found in release \"$ghTag\" of GitHub repository \"$ghRepo\"");
    }
  }elsif($httpRes->{status} == 404) {
    return (undef,"release not found on GitHub: invalid tag \"$ghTag\" or invalid repository \"$ghRepo\"");
  }else{
    return (undef,"unable to check version availability, HTTP status:$httpRes->{status}");
  }
}

sub _checkEngineVersionAvailabilityFromGithub {
  my ($version,$r_githubInfo)=@_;
  my (undef,$reason)=_getEngineGithubDownloadUrl($version,$r_githubInfo);
  return $reason;
}
  
# Called by spadsInstaller.pl, spads.pl
sub setupEngine {
  my ($self,$version,$r_githubInfoOrSpringBranch,$getPrdownloader)=@_;
  my $isFromGithub = ref $r_githubInfoOrSpringBranch eq 'HASH';
  my $engineStr = $isFromGithub ? 'engine' : 'Spring';
  
  my $sl=$self->{sLog};
  if($version !~ /^\d/) {
    $sl->log("Invalid $engineStr version \"$version\"",1);
    return -1;
  }

  my $engineDir=$self->getEngineDir($version,$isFromGithub ? $r_githubInfoOrSpringBranch : undef);
  return -1 unless(defined $engineDir);
  return 0 if(_checkEngineDir($engineDir,$version));

  if($isFromGithub) {
    my $unavailabilityMsg=_checkEngineVersionAvailabilityFromGithub($version,$r_githubInfoOrSpringBranch);
    if(defined $unavailabilityMsg) {
      $sl->log("Installation aborted for engine version \"$version\" ($unavailabilityMsg)",1);
      return -10;
    }
  }else{
    my $unavailabilityMsg=$self->_checkSpringVersionAvailability($version,$r_githubInfoOrSpringBranch);
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
    $sl->log('Another instance of SpadsUpdater is already performing '.($isFromGithub ? 'an engine' : 'a Spring').' installation in same directory',2);
    close($lockFh);
    return -3;
  }
  my $res=$self->_setupEngineLockProtected($version,$r_githubInfoOrSpringBranch,$engineDir,$getPrdownloader);
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
  my ($self,$version,$r_githubInfoOrSpringBranch,$engineDir,$getPrdownloader)=@_;
  return 0 if(_checkEngineDir($engineDir,$version));
  
  my $isFromGithub = ref $r_githubInfoOrSpringBranch eq 'HASH';
  my $engineStr = $isFromGithub ? 'engine' : 'Spring';

  my $sl=$self->{sLog};
  $sl->log("Installing $engineStr $version into \"$engineDir\"...",3);

  my ($errorMsg,$baseUrlRequired,$baseUrlOptional,$requiredArchive,@optionalArchives)=_getEngineVersionDownloadInfo($version,$r_githubInfoOrSpringBranch);
  if(defined $errorMsg) {
    $sl->log("Engine $version installation cancelled ($errorMsg)",1);
    return -10;
  }
  
  my $tmpArchive=catfile($engineDir,$requiredArchive);
  if(! $self->downloadFile($baseUrlRequired.$requiredArchive,$tmpArchive,my $httpStatus)) {
    if($httpStatus == 404 && ! $isFromGithub) {
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
