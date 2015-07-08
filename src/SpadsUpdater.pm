# Perl module used for Spads auto-updating functionnality
#
# Copyright (C) 2008-2015  Yann Riou <yaribzh@gmail.com>
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
use HTTP::Tiny;
use IO::Uncompress::Unzip qw'unzip $UnzipError';
use List::Util qw'first max';
use Time::HiRes;

sub any (&@) { my $c = shift; return defined first {&$c} @_; }
sub all (&@) { my $c = shift; return ! defined first {! &$c} @_; }
sub none (&@) { my $c = shift; return ! defined first {&$c} @_; }
sub notall (&@) { my $c = shift; return defined first {! &$c} @_; }

my $win=$^O eq 'MSWin32' ? 1 : 0;
my $archName=$win?'win32':($Config{ptrsize} > 4 ? 'linux64' : 'linux32');

my $moduleVersion='0.11';

my @constructorParams = qw'sLog localDir repository release packages';
my @optionalConstructorParams = qw'syncedSpringVersion springDir';

my $springBuildbotUrl='https://springrts.com/dl/buildbot/default';
my $springVersionWikiTemplateUrl='https://springrts.com/wiki/Template:EngineVersion';
my %springBranches=(release => 'master', dev => 'develop');

sub getVersion {
  return $moduleVersion;
}

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
  $self->{syncedSpringVersion}='UNKNOWN' unless(exists $self->{syncedSpringVersion});
  return $self;
}

sub resolveSpringReleaseNameToVersion {
  my ($self,$release)=@_;
  my $sl=$self->{sLog};
  my $httpTiny=HTTP::Tiny->new(timeout => 10);
  if($release eq 'stable') {
    my $httpRes=$httpTiny->request('GET',"$springVersionWikiTemplateUrl:Stable");
    if($httpRes->{success} && $httpRes->{content} =~ /id="mw-content-text".*>([^<>]+)\n/) {
      return $1;
    }else{
      $sl->log("Unable to retrieve Spring version number for $release release!",2);
      return undef;
    }
  }elsif($release eq 'testing') {
    my ($testingRelease,$latestRelease);
    my $httpRes=$httpTiny->request('GET',"$springVersionWikiTemplateUrl:Testing");
    if($httpRes->{success} && $httpRes->{content} =~ /id="mw-content-text".*>([^<>]+)\n/) {
      $testingRelease=$1;
    }else{
      $sl->log("Unable to retrieve Spring version number for $release release!",2);
      return undef;
    }
    $httpRes=$httpTiny->request('GET',"$springBuildbotUrl/$springBranches{release}/LATEST");
    if($httpRes->{success} && defined $httpRes->{content}) {
      $latestRelease=$httpRes->{content};
      chomp($latestRelease);
    }else{
      $sl->log("Unable to retrieve latest Spring version number on $springBranches{release} branch!",2);
      return undef;
    }
    return $testingRelease gt $latestRelease ? $testingRelease : $latestRelease;
  }elsif($release eq 'unstable') {
    my $httpRes=$httpTiny->request('GET',"$springBuildbotUrl/$springBranches{dev}/LATEST");
    if($httpRes->{success} && $httpRes->{content} =~ /^{$springBranches{dev}}(.+)$/) {
      return $1;
    }else{
      $sl->log("Unable to retrieve latest Spring version number on $springBranches{dev} branch!",2);
      return undef;
    }
  }else{
    $sl->log("Unable to retrieve Spring version number for release \"$release\" (unknown release)",1);
    return undef;
  }
}

sub getAvailableSpringVersions {
  my ($self,$type)=@_;
  my $sl=$self->{sLog};
  if(! exists $springBranches{$type}) {
    $sl->log("Unable to get available Spring versions, invalid version type \"$type\"",1);
    return [];
  }
  my $branch=$springBranches{$type};
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',"$springBuildbotUrl/$branch/");
  my @versions;
  @versions=$httpRes->{content} =~ /href="([^"]+)\/">\1\//g if($httpRes->{success});
  $sl->log("Unable to get available Spring versions for branch \"$branch\"",2) unless(@versions);
  return \@versions;
}

sub getSpringDir {
  my ($self,$springVersion)=@_;
  if(! exists $self->{springDir}) {
    $self->{sLog}->log("Unable to get Spring directory for version $springVersion, no base Spring directory specified!",1);
    return undef;
  }
  return catdir($self->{springDir},"$springVersion-$archName");
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
      (qw'DevIL.dll spring-dedicated.exe spring-headless.exe unitsync.dll zlib1.dll')
      : (qw'libunitsync.so spring-dedicated spring-headless');
  if($win) {
    if(_compareSpringVersions($springVersion,92) < 0) {
      push(@requiredFiles,'mingwm10.dll');
    }elsif(_compareSpringVersions($springVersion,95) < 0) {
      push(@requiredFiles,'pthreadGC2.dll');
    }
  }
  return \@requiredFiles;
}

sub checkSpringDir {
  my ($self,$springVersion)=@_;
  my $springDir=$self->getSpringDir($springVersion);
  return undef unless(defined $springDir);
  return undef unless(-d "$springDir/base");
  my $p_requiredFiles=_getSpringRequiredFiles($springVersion);
  return undef unless(all {-f "$springDir/$_"} @{$p_requiredFiles});
  return $springDir;
}

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

sub isSpringSetupInProgress {
  my ($self,$version)=@_;
  my $springDir=$self->getSpringDir($version);
  return 0 unless(defined $springDir && -e $springDir);
  my $lockFile=catfile($springDir,'SpringSetup.lock');
  my $res=0;
  if(open(my $lockFh,'>',$lockFile)) {
    if(flock($lockFh, LOCK_EX|LOCK_NB)) {
      flock($lockFh, LOCK_UN);
    }else{
      $res=1;
    }
    close($lockFh);
  }else{
    $self->{sLog}->log("Unable to write SpringSetup lock file \"$lockFile\" ($!)",1);
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
  my $res=$self->updateUnlocked($force);
  flock($lockFh, LOCK_UN);
  close($lockFh);
  return $res;
}

sub downloadFile {
  my ($self,$url,$file)=@_;
  my $sl=$self->{sLog};
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

sub updateUnlocked {
  my ($self,$force)=@_;
  $force//=0;
  my $sl=$self->{sLog};

  my %currentPackages;
  my $updateInfoFile=catfile($self->{localDir},'updateInfo.txt');
  if(-f $updateInfoFile) {
    if(open(UPDATE_INFO,'<',$updateInfoFile)) {
      while(<UPDATE_INFO>) {
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
    while(<PACKAGES>) {
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

  my $perlMajorVer='';
  $perlMajorVer=$1 if($^V =~ /^v(\d+\.\d+)/);

  my %availablePackages=%{$allAvailablePackages{$self->{release}}};
  my @updatedPackages;
  foreach my $packageName (@{$self->{packages}}) {
    $availablePackages{$packageName}=$availablePackages{"$packageName;$perlMajorVer"} if(exists $availablePackages{"$packageName;$perlMajorVer"});
    $availablePackages{$packageName}=$availablePackages{"$packageName;$self->{syncedSpringVersion}"} if(exists $availablePackages{"$packageName;$self->{syncedSpringVersion}"});
    if(! exists $availablePackages{$packageName}) {
      $sl->log("No \"$packageName\" package available in $self->{release} SPADS release for Spring $self->{syncedSpringVersion} and Perl $perlMajorVer",2);
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
              $sl->log("Please check the section concerning this update in the manual update help: $self->{repository}/UPDATE",2);
              $sl->log("Then force package update with \"perl update.pl $self->{release} -f $packageName\" (or \"perl update.pl $self->{release} -f -a\" to force update of all SPADS packages).",2);
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

sub _getSpringVersionType {
  return shift =~ /^\d+\.\d+$/ ? 'release' : 'dev';
}

sub _getSpringVersionDownloadInfo {
  my $version=shift;
  my $versionType = _getSpringVersionType($version);
  my $branch = $springBranches{$versionType};
  my $versionInArchives = $versionType eq 'release' ? $version : "{$branch}$version";
  my ($requiredArchive,@optionalArchives);
  if($win) {
    $requiredArchive="spring_${versionInArchives}_minimal-portable.7z";
    @optionalArchives=("${versionInArchives}_spring-dedicated.7z","${versionInArchives}_spring-headless.7z")
  }else{
    $requiredArchive="spring_${versionInArchives}_minimal-portable-$archName-static.7z";
    @optionalArchives=("${versionInArchives}_spring-dedicated-$archName-static.7z","${versionInArchives}_spring-headless-$archName-static.7z")
  }
  my $baseUrlRequired="$springBuildbotUrl/$branch/$version/".(_compareSpringVersions($version,91)<0?'':"$archName/");
  my $baseUrlOptional="$springBuildbotUrl/$branch/$version/".(_compareSpringVersions($version,92)<0?'':"$archName/");
  return ($baseUrlRequired,$baseUrlOptional,$requiredArchive,@optionalArchives);
}

sub checkSpringVersionAvailability {
  my ($self,$version)=@_;
  my $p_availableVersions = $self->getAvailableSpringVersions(_getSpringVersionType($version));
  return (0,'version unavailable for download') unless(any {$version eq $_} @{$p_availableVersions});
  my ($baseUrlRequired,undef,$requiredArchive)=_getSpringVersionDownloadInfo($version);
  my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$baseUrlRequired);
  if($httpRes->{success}) {
    return (1) if(index($httpRes->{content},">$requiredArchive<") != -1);
    return (-2,'archive not found');
  }elsif($httpRes->{status} == 404) {
    return (-1,'version unavailable for this architecture');
  }else{
    return (-3,"unable to check version availability, HTTP status:$httpRes->{status}");
  }
}

sub setupSpring {
  my ($self,$version)=@_;
  my $sl=$self->{sLog};

  if($version !~ /^\d/) {
    $sl->log("Invalid Spring version \"$version\"",1);
    return -1;
  }

  my $springDir=$self->getSpringDir($version);
  return -1 unless(defined $springDir);
  return 0 if($self->checkSpringDir($version));

  my (undef,$unavailabilityMsg)=$self->checkSpringVersionAvailability($version);
  if(defined $unavailabilityMsg) {
    $sl->log("Spring $version installation cancelled ($unavailabilityMsg)",1);
    return -10;
  }

  if(! -e $springDir) {
    eval { mkpath($springDir) };
    if($@) {
      $sl->log("Unable to create directory \"$springDir\" ($@)",1);
      return -2;
    }
    $sl->log("Created new directory \"$springDir\" for Spring installation",4);
  }
  my $lockFile=catfile($springDir,'SpringSetup.lock');
  my $lockFh;
  if(! open($lockFh,'>',$lockFile)) {
    $sl->log("Unable to write SpringSetup lock file \"$lockFile\" ($!)",1);
    return -2;
  }
  if(! _autoRetry(sub {flock($lockFh, LOCK_EX|LOCK_NB)})) {
    $sl->log('Another instance of SpadsUpdater is already performing a Spring installation in same directory',2);
    close($lockFh);
    return -3;
  }
  my $res=$self->setupSpringUnlocked($version);
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
  my ($exitCode,$errorMsg)=_systemNoOutput($sevenZipBin,'x','-y',"-o$destDir",$archiveFile,@filesToExtract);
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

sub setupSpringUnlocked {
  my ($self,$version)=@_;
  return 0 if($self->checkSpringDir($version));

  my $sl=$self->{sLog};

  my $springDir=$self->getSpringDir($version);
  $sl->log("Installing Spring $version into \"$springDir\"...",3);

  my ($baseUrlRequired,$baseUrlOptional,$requiredArchive,@optionalArchives)=_getSpringVersionDownloadInfo($version);

  my $tmpArchive=catfile($springDir,$requiredArchive);
  if(! $self->downloadFile($baseUrlRequired.$requiredArchive,$tmpArchive,my $httpStatus)) {
    if($httpStatus == 404) {
      $sl->log("No Spring $version package available for architecture $archName",2);
      return -11;
    }else{
      $sl->log("Unable to downloadable Spring archive file \"$requiredArchive\" from \"$baseUrlRequired\" to \"$springDir\" (HTTP status: $httpStatus)",1);
      return -12;
    }
  }

  my $p_requiredFiles=_getSpringRequiredFiles($version);
  if(! $self->uncompress7zipFile($tmpArchive,$springDir,'base',@{$p_requiredFiles})) {
    unlink($tmpArchive);
    $sl->log("Unable to extract Spring archive \"$tmpArchive\"",1);
    return -13;
  }
  unlink($tmpArchive);

  foreach my $optionalArchive (@optionalArchives) {
    $tmpArchive=catfile($springDir,$optionalArchive);
    if(! $self->downloadFile($baseUrlOptional.$optionalArchive,$tmpArchive,my $httpStatus)) {
      $sl->log("Unable to downloadable Spring archive file \"$optionalArchive\" from \"$baseUrlOptional\" to \"$springDir\" (HTTP status: $httpStatus)",1) if($httpStatus != 404);
    }else{
      if(! $self->uncompress7zipFile($tmpArchive,$springDir,@{$p_requiredFiles})) {
        unlink($tmpArchive);
        $sl->log("Unable to extract Spring archive \"$tmpArchive\"",1);
        return -13;
      }
      unlink($tmpArchive);
    }
  }

  if($self->checkSpringDir($version)) {
    $sl->log("Spring $version installation complete.",3);
    return 1;
  }

  $sl->log("Unable to install Spring version $version (incomplete archives)",1);
  return -14;
}

1;
