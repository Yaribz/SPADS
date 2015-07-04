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

use Fcntl qw':DEFAULT :flock';
use File::Copy;
use HTTP::Tiny;
use IO::Uncompress::Unzip qw'unzip $UnzipError';
use Time::HiRes;

my $win=$^O eq 'MSWin32' ? 1 : 0;

my $moduleVersion='0.9';

my @constructorParams = qw/sLog localDir repository release packages/;
my @optionalConstructorParams = 'syncedSpringVersion';

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

sub renameToBeDeleted {
  my $fileName=shift;
  my $i=1;
  while(-f "$fileName.$i.toBeDeleted" && $i < 100) {
    $i++;
  }
  return move($fileName,"$fileName.$i.toBeDeleted");
}

sub autoRetry {
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

sub isUpdateInProgress {
  my $self=shift;
  my $lockFile="$self->{localDir}/SpadsUpdater.lock";
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

sub update {
  my ($self,undef,$force)=@_;
  my $sl=$self->{sLog};
  my $lockFile="$self->{localDir}/SpadsUpdater.lock";
  my $lockFh;
  if(! open($lockFh,'>',$lockFile)) {
    $sl->log("Unable to write SpadsUpdater lock file \"$lockFile\" ($!)",1);
    return -2;
  }
  if(! autoRetry(sub {flock($lockFh, LOCK_EX|LOCK_NB)})) {
    $sl->log('Another instance of SpadsUpdater is already running in same directory',1);
    close($lockFh);
    return -1;
  }
  my $res=$self->updateUnlocked($force);
  flock($lockFh, LOCK_UN);
  close($lockFh);
  return $res;
}

sub downloadFile {
  my ($url,$file)=@_;
  my $httpRes=HTTP::Tiny->new(timeout => 10)->mirror($url,$file);
  if(! $httpRes->{success} || ! -f $file) {
    unlink($file);
    return 0;
  }
  return 2 if($httpRes->{status} == 304);
  return 1;
}

sub updateUnlocked {
  my ($self,$force)=@_;
  $force//=0;
  my $sl=$self->{sLog};

  my %currentPackages;
  if(-f "$self->{localDir}/updateInfo.txt") {
    if(open(UPDATE_INFO,"<$self->{localDir}/updateInfo.txt")) {
      while(<UPDATE_INFO>) {
        $currentPackages{$1}=$2 if(/^([^:]+):(.+)$/);
      }
      close(UPDATE_INFO);
    }else{
      $sl->log("Unable to read \"$self->{localDir}/updateInfo.txt\" file",1);
      return -3;
    }
  }

  my %allAvailablePackages;
  if(! downloadFile("$self->{repository}/packages.txt",'packages.txt')) {
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
              $sl->log("Please check the section concerning this update in the manual update help: http://planetspads.free.fr/spads/repository/UPDATE",2);
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
        if(! downloadFile("$self->{repository}/$availableVersion.zip","$self->{localDir}/$availableVersion.zip")) {
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
        if(! downloadFile("$self->{repository}/$availableVersion","$self->{localDir}/$availableVersion.tmp")) {
          $sl->log("Unable to download package \"$availableVersion\"",1);
          return -8;
        }
        if(! move("$self->{localDir}/$availableVersion.tmp","$self->{localDir}/$availableVersion")) {
          $sl->log("Unable to rename package \"$availableVersion\"",1);
          unlink("$self->{localDir}/$availableVersion.tmp");
          return -9;
        }
      }
      chmod(0755,"$self->{localDir}/$availableVersion") if($availableVersion =~ /\.(pl|py)$/);
      utime(undef,undef,"$self->{localDir}/$availableVersion") if($availableVersion =~ /\.(exe|dll)$/);
      push(@updatedPackages,$packageName);
    }
  }
  foreach my $updatedPackage (@updatedPackages) {
    unlink("$self->{localDir}/$updatedPackage");
    if($win) {
      next if(-f "$self->{localDir}/$updatedPackage" && (! renameToBeDeleted("$self->{localDir}/$updatedPackage")) && $updatedPackage =~ /\.(exe|dll)$/);
      if(! copy("$self->{localDir}/$availablePackages{$updatedPackage}","$self->{localDir}/$updatedPackage")) {
        $sl->log("Unable to copy \"$self->{localDir}/$availablePackages{$updatedPackage}\" to \"$self->{localDir}/$updatedPackage\", system consistency must be checked manually !",0);
        return -10;
      }
    }else{
      if(! symlink("$availablePackages{$updatedPackage}","$self->{localDir}/$updatedPackage")) {
        $sl->log("Unable to create symbolic link from \"$self->{localDir}/$updatedPackage\" to \"$self->{localDir}/$availablePackages{$updatedPackage}\", system consistency must be checked manually !",0);
        return -10;
      }
    }
  }

  my $nbUpdatedPackage=$#updatedPackages+1;
  if($nbUpdatedPackage) {
    foreach my $updatedPackage (@updatedPackages) {
      $currentPackages{$updatedPackage}=$availablePackages{$updatedPackage};
    }
    if(open(UPDATE_INFO,">$self->{localDir}/updateInfo.txt")) {
      print UPDATE_INFO time."\n";
      foreach my $currentPackage (keys %currentPackages) {
        print UPDATE_INFO "$currentPackage:$currentPackages{$currentPackage}\n";
      }
      close(UPDATE_INFO);
    }else{
      $sl->log("Unable to write update information to \"$self->{localDir}/updateInfo.txt\" file",1);
      return -11;
    }
    $sl->log("$nbUpdatedPackage package(s) updated",3);
  }

  return $nbUpdatedPackage;
}

1;
