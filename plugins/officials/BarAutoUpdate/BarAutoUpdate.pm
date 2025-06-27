# BarAutoUpdate (Perl module)
#
# SPADS plugin implementing the auto-update functionalities for following
# components:
# - map lists configuration
# - map boxes configuration
# - map files (based on a JSON index file as used by Beyond All Reason)
# - game files (using pr-downloader)
#
# Copyright (C) 2025  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

package BarAutoUpdate;

use strict;

use Fcntl qw':DEFAULT :flock';
use File::Basename 'dirname';
use File::Find ();
use File::Spec::Functions qw'catfile catdir devnull';
use HTTP::Tiny;
use JSON::PP 'decode_json';
use List::Util qw'all any';
use Storable qw'nstore retrieve';

use SpadsPluginApi;

my $pluginVersion='0.3';
my $requiredSpadsVersion='0.13.15';

use constant {
  MSWIN32 => $^O eq 'MSWin32',
  BAR_LAUNCHER_CONFIG_URL => 'https://launcher-config.beyondallreason.dev/config.json',
};

my $PRD_BIN='pr-downloader'.(MSWIN32 ? '.exe' : '');

my %globalPluginParams = (
  autoUpdateInterval => ['integer'],
  httpTimeout => ['integer'],
  mapListsUrl => [],
  autoReloadMapLists => ['bool'],
  mapBoxesUrl => [],
  autoReloadMapBoxes => ['bool'],
  mapInventoryUrl => [],
  mapDownloadDirectory => [],
  gameRapidTag => [],
  prDownloaderPath => ['absoluteExecutableFile','null'],
  prDownloaderWritePath => [],
    );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my ($class,$context)=@_;
  slog("Initializing plugin (version $pluginVersion) [$context]",3);
  
  if(! ( HTTP::Tiny->can('can_ssl') ? HTTP::Tiny->can_ssl() : eval { require IO::Socket::SSL; IO::Socket::SSL->VERSION(1.42); require Net::SSLeay; Net::SSLeay->VERSION(1.49); 1 })) {
    slog('This plugin requires following Perl modules: IO::Socket::SSL version 1.42 or superior, and Net::SSLeay version 1.49 or superior',1);
    return undef;
  }

  my $self = {
    barAuLock => undef,
    updateInProgress => 0,
    mapConfTimestamps => {},
    prDownloaderEnvVars => undef,
    cache => {
      eTags => {},
      mapDownloadDirectory => undef,
      prDownloaderPath => undef,
      prDownloaderWritePath => undef,
      prDownloaderEnvVars => undef,
    },
  };
  bless($self,$class);
  
  return undef unless(onReloadConf($self));
  SimpleEvent::addForkedProcessCallback('CloseBarAuLock',sub {close($self->{barAuLock}) if($self->{barAuLock})});

  my $autoUpdateInterval=getPluginConf()->{autoUpdateInterval}*60;
  
  if($self->acquireBarAuLockAndLoadCache()) {
    $self->{updateInProgress}=1;
    slog('Starting BAR auto-update process...',5);
    if($context eq 'autoload' && $::timestamps{connectAttempt} == 0) {
      my $r_updateResult=updateBarBlocking($self);
      updateBarEnd($r_updateResult,1,$self);
      if(! $autoUpdateInterval) {
        close($self->{barAuLock});
        undef $self->{barAuLock};
      }
    }else{
      if(! forkCall(
             sub {return updateBarBlocking($self)},
             sub {
               my $r_result=shift;
               updateBarEnd($r_result,0,$self);
               if(! $autoUpdateInterval) {
                 close($self->{barAuLock});
                 undef $self->{barAuLock};
               }
             },
         )) {
        $self->{updateInProgress}=0;
        slog('Failed to fork BAR auto-update process',2);
        if(! $autoUpdateInterval) {
          close($self->{barAuLock});
          undef $self->{barAuLock};
        }
      }
    }
  }

  if($autoUpdateInterval) {
    addTimer('BarAutoUpdate',
             $autoUpdateInterval,
             $autoUpdateInterval,
             sub {
               return slog('Skipping BAR auto-update process, previous run is still running...',2)
                   if($self->{updateInProgress});
               return unless($self->{barAuLock} || $self->acquireBarAuLockAndLoadCache());
               $self->{updateInProgress}=1;
               slog('Starting BAR auto-update process...',5);
               if(! forkCall(\&updateBarBlocking,\&updateBarEnd)) {
                 $self->{updateInProgress}=0;
                 slog('Failed to fork BAR auto-update process',2);
               }
             });
  }

  addTimer('MapConfAutoReload',60,60,\&mapConfAutoReload);
  
  slog('Plugin loaded (mode: '.(getPluginConf()->{autoUpdateInterval} ? ($self->{barAuLock} ? 'active' : 'standby') : 'oneshot').')',3);
  return $self;
}

sub onReloadConf {
  my $self=shift;
  my $r_pluginConf=getPluginConf();
  foreach my $urlParam (qw'mapListsUrl mapBoxesUrl mapInventoryUrl') {
    if($r_pluginConf->{$urlParam} ne '' && $r_pluginConf->{$urlParam} !~ /^https?:\/\//i) {
      slog("Invalid URL \"$r_pluginConf->{$urlParam}\" for \"$urlParam\" plugin setting",1);
      return 0;
    }
  }
  foreach my $writableDirParam (qw'mapDownloadDirectory prDownloaderWritePath') {
    my $paramVal=$r_pluginConf->{$writableDirParam};
    if($paramVal ne '' && ! (-d $paramVal && -x _ && -w _)) {
      slog("Invalid value \"$paramVal\" for \"$writableDirParam\" plugin setting: not a writable directory",1);
      return 0;
    }
  }
  my $spadsEtcDir=getSpadsConf()->{etcDir};
  foreach my $mapConfType (qw'Lists Boxes') {
    next unless($r_pluginConf->{'autoReloadMap'.$mapConfType});
    my $confFile='map'.$mapConfType.'.conf';
    $self->{mapConfTimestamps}{$confFile}=(stat(catfile($spadsEtcDir,$confFile)))[9];
  }
  return 1;
}

sub acquireBarAuLockAndLoadCache {
  my $self=shift;
  my $spadsVarDir=getSpadsConf()->{varDir};
  my $lockFile=catfile($spadsVarDir,'BarAutoUpdate.lock');
  if(open(my $lockFh,'>',$lockFile)) {
    if(! flock($lockFh, LOCK_EX|LOCK_NB)) {
      if(! defined $self->{barAuLock}) {
        slog('BAR auto-update has been automatically disabled on this instance (BAR auto-update is already managed by another instance)',4);
        $self->{barAuLock}=0;
      }
      close($lockFh);
      return 0;
    }
    SimpleEvent::win32HdlDisableInheritance($lockFh) if(::MSWIN32());
    slog('BAR auto-update has been automatically re-enabled on this instance (BAR auto-update was previously managed by another instance)',4)
        if(defined $self->{barAuLock});
    $self->{barAuLock}=$lockFh;
  }else{
    slog("Unable to open BarAutoUpdate lock file \"$lockFile\", skipping BAR auto-update check",1);
    return 0;
  }
  my $cacheFile=catfile($spadsVarDir,'BarAutoUpdate.dat');
  if(-f $cacheFile) {
    my $r_cache=retrieve($cacheFile);
    if(defined $r_cache) {
      my $needCacheDump;
      foreach my $writableDirParam (qw'mapDownloadDirectory prDownloaderWritePath') {
        if(defined $r_cache->{$writableDirParam} && ! (-d $r_cache->{$writableDirParam} && -x _ && -w _)) {
          slog("Cached value for autodetected \"$writableDirParam\" setting (\"$r_cache->{$writableDirParam}\") is no longer valid, clearing cache",4);
          undef $r_cache->{$writableDirParam};
          $needCacheDump=1;
        }
      }
      if(defined $r_cache->{prDownloaderPath} && ! (-f $r_cache->{prDownloaderPath} && -x _)) {
        slog("Cached value for autodetected \"prDownloaderPath\" setting (\"$r_cache->{prDownloaderPath}\") is no longer valid, clearing cache",4);
        undef $r_cache->{prDownloaderPath};
        $needCacheDump=1;
      }
      if($needCacheDump) {
        nstore($r_cache,$cacheFile)
            or slog("Failed to store cache data in file \"$cacheFile\"",1);
      }
      $self->{cache}=$r_cache;
    }else{
      slog("Unable to retrieve cached data from file \"$cacheFile\"",2);
    }
  }
  return 1;
}

sub updateBarBlocking {
  my $self = shift // getPlugin();
  my %result;
  
  my $r_spadsConf=getSpadsConf();
  my $r_pluginConf=getPluginConf();
  foreach my $mapConfUpdateType (qw'mapLists mapBoxes') {
    my $url=$r_pluginConf->{$mapConfUpdateType.'Url'};
    next if($url eq '');
    my $confFile=$mapConfUpdateType.'.conf';
    my %httpOptions;
    $httpOptions{headers}{'If-None-Match'}=$self->{cache}{eTags}{$confFile} if(defined $self->{cache}{eTags}{$confFile});
    my $httpRes=HTTP::Tiny->new(timeout => $r_pluginConf->{httpTimeout})->mirror($url,
                                                                                 catfile($r_spadsConf->{etcDir},$confFile),
                                                                                 \%httpOptions);
    if(! $httpRes->{success}) {
      $result{$mapConfUpdateType}={error => getHttpErrMsg($httpRes)};
      next;
    }
    $result{$mapConfUpdateType}={httpStatus => $httpRes->{status}, httpReason => $httpRes->{reason}};
    $result{cache}{eTags}{$confFile}=$httpRes->{headers}{etag} unless($httpRes->{status} == 304);
  }

  my $mapInventoryUrl=$r_pluginConf->{mapInventoryUrl};
  my $gameRapidTag=$r_pluginConf->{gameRapidTag};
  my @requestedUpdates;
  push(@requestedUpdates,'maps') unless($mapInventoryUrl eq '');
  push(@requestedUpdates,'game') unless($gameRapidTag eq '');
  return \%result unless(@requestedUpdates);
  
  my $usLockFh;
  my $usLockFile = catfile($r_spadsConf->{$r_spadsConf->{sequentialUnitsync} ? 'varDir' : 'instanceDir'},'unitsync.lock');
  if(open($usLockFh,'>',$usLockFile)) {
    if(! flock($usLockFh, LOCK_EX)) {
      @result{@requestedUpdates}=({error => "failed to acquire unitsync library lock ($!)"}) x @requestedUpdates;
      close($usLockFh);
      return \%result;
    }
  }else{
    @result{@requestedUpdates}=({error => "failed to open unitsync library lock file \"$usLockFile\" ($!)"}) x @requestedUpdates;
    return \%result;
  }

  if($mapInventoryUrl ne '') {
    my $errMsg;
    my @allBarMaps;
    my $httpRes=HTTP::Tiny->new(timeout => $r_pluginConf->{httpTimeout})->get($r_pluginConf->{mapInventoryUrl});
    if($httpRes->{success}) {
      my $r_jsonBarMapList = eval { decode_json($httpRes->{content}) };
      if(defined $r_jsonBarMapList) {
        if(ref $r_jsonBarMapList eq 'ARRAY') {
          foreach my $r_jsonBarMapData (@{$r_jsonBarMapList}) {
            next unless(ref $r_jsonBarMapData eq 'HASH'
                        && defined $r_jsonBarMapData->{springName} && ref $r_jsonBarMapData->{springName} eq ''
                        && defined $r_jsonBarMapData->{downloadURL} && ref $r_jsonBarMapData->{downloadURL} eq '');
            push(@allBarMaps,[@{$r_jsonBarMapData}{qw'springName downloadURL'}]);
          }
        }
        $errMsg='failed to parse map inventory file (unexpected JSON structure)' unless(@allBarMaps);
      }else{
        $errMsg='failed to parse map inventory file (invalid JSON data)';
      }
    }else{
      $errMsg='failed to retrieve map inventory file ('.getHttpErrMsg($httpRes).')';
    }
    my $mapDownloadDirectory=$r_pluginConf->{mapDownloadDirectory};
    if($mapDownloadDirectory eq '' && ! defined $errMsg) {
      if(defined $self->{cache}{mapDownloadDirectory}) {
        $mapDownloadDirectory=$self->{cache}{mapDownloadDirectory};
      }else{
        my ($selectedDir,$nbMapsInSelectedDir)=(undef,-1);
        my @dataDirs=::splitPaths($r_spadsConf->{springDataDir});
        foreach my $dataDir (@dataDirs) {
          my $mapDataDir=catdir($dataDir,'maps');
          next unless(-d $mapDataDir && -x _ && -w _);
          if(opendir(my $dirHdl,$mapDataDir)) {
            my $nbMapsInDir=grep {-f "$mapDataDir/$_" && /\.sd[7z]$/i} readdir($dirHdl);
            closedir($dirHdl);
            ($selectedDir,$nbMapsInSelectedDir)=($mapDataDir,$nbMapsInDir) if($nbMapsInDir > $nbMapsInSelectedDir);
          }
        }
        if(defined $selectedDir) {
          $mapDownloadDirectory=$selectedDir;
          $result{cache}{mapDownloadDirectory}=$mapDownloadDirectory;
        }else{
          $errMsg='failed to find maps download directory automatically using "springDataDir" SPADS setting (you can set "mapDownloadDirectory" plugin setting to configure this directory manually)';
        }
      }
    }
    if(defined $errMsg) {
      $result{maps}={error => $errMsg};
    }else{
      my $httpTiny=HTTP::Tiny->new(timeout => $r_pluginConf->{httpTimeout});
      foreach my $r_mapNameAndUrl (@allBarMaps) {
        my ($mapName,$mapUrl)=@{$r_mapNameAndUrl};
        if((::getMapHashAndArchive($mapName))[1] ne '') {
          push(@{$result{maps}{skipped}},$mapName);
          next;
        }
        if($mapUrl =~ /\/([^\/]+\.sd[7z])$/i) {
          my $filePath=catfile($mapDownloadDirectory,$1);
          if(-e $filePath) {
            push(@{$result{maps}{skipped}},$mapName);
            next;
          }
          my $httpRes=$httpTiny->mirror($mapUrl,$filePath);
          if($httpRes->{success}) {
            push(@{$result{maps}{downloaded}},$mapName);
          }else{
            push(@{$result{maps}{failed}},{mapName => $mapName,
                                           mapUrl => $mapUrl,
                                           error => getHttpErrMsg($httpRes)});
          }
        }else{
          push(@{$result{maps}{failed}},{mapName => $mapName,
                                         mapUrl => $mapUrl,
                                         error => 'unrecognized download URL'});
        }
      }
    }
  }
  
  if($gameRapidTag ne '') {
    my $errMsg;
    my $prDownloaderPath=$r_pluginConf->{prDownloaderPath};
    if($prDownloaderPath eq '') {
      if(defined $self->{cache}{prDownloaderPath}) {
        $prDownloaderPath=$self->{cache}{prDownloaderPath};
      }else{
        if($r_spadsConf->{springServer} eq '') {
          my ($selectedPrd,$timestampPrd)=(undef,0);
          File::Find::find(
            {
              wanted => sub {
                return unless($_ eq $PRD_BIN && -x $File::Find::name);
                my $modifTime=(stat($File::Find::name))[9]//0;
                ($selectedPrd,$timestampPrd)=($File::Find::name,$modifTime) if($modifTime > $timestampPrd);
              },
              follow => 1,
            },
            $r_spadsConf->{autoManagedSpringDir});
          if(defined $selectedPrd) {
            $selectedPrd =~ tr{/}{\\} if(::MSWIN32());
            $prDownloaderPath=$selectedPrd;
            $result{cache}{prDownloaderPath}=$prDownloaderPath;
          }else{
            $errMsg='failed to autodetect pr-downloader path using "autoManagedSpringDir" SPADS setting (you can set "prDownloaderPath" plugin setting to configure this path manually)';
          }
        }else{
          my $engineDir=dirname($r_spadsConf->{springServer});
          my $prdPath=catfile($engineDir,$PRD_BIN);
          if(-f $prdPath && -x _) {
            $prDownloaderPath=$prdPath;
            $result{cache}{prDownloaderPath}=$prDownloaderPath;
          }else{
            $errMsg='failed to autodetect pr-downloader path using "springServer" SPADS setting (you can set "prDownloaderPath" plugin setting to configure this path manually)';
          }
        }
      }
    }
    if(defined $errMsg) {
      $result{game}={error => $errMsg};
      return \%result;
    }
    my $prDownloaderWritePath=$r_pluginConf->{prDownloaderWritePath};
    if($prDownloaderWritePath eq '') {
      if(defined $self->{cache}{prDownloaderWritePath}) {
        $prDownloaderWritePath=$self->{cache}{prDownloaderWritePath};
      }else{
        my ($selectedDir,$nbRapidSubdir)=(undef,-1);
        my @dataDirs=::splitPaths($r_spadsConf->{springDataDir});
        foreach my $dataDir (@dataDirs) {
          next unless(-d $dataDir && -x _ && -w _);
          my $nbRapidSubdirInDir=0;
          map {++$nbRapidSubdirInDir if(-d "$dataDir/$_")} (qw'rapid pool packages');
          ($selectedDir,$nbRapidSubdir)=($dataDir,$nbRapidSubdirInDir) if($nbRapidSubdirInDir > $nbRapidSubdir);
        }
        if(defined $selectedDir) {
          $prDownloaderWritePath=$selectedDir;
          $result{cache}{prDownloaderWritePath}=$prDownloaderWritePath;
        }else{
          $errMsg='failed to identify correct pr-downloader write path automatically using "springDataDir" SPADS setting (you can set "prDownloaderWritePath" plugin setting to configure this directory manually)';
        }
      }
    }
    if(defined $errMsg) {
      $result{game}={error => $errMsg};
      return \%result;
    }
    if(lc(substr($gameRapidTag,0,5)) eq 'byar:') {
      if(! defined $self->{prDownloaderEnvVars}) {
        my $httpRes=HTTP::Tiny->new(timeout => $r_pluginConf->{httpTimeout})->get(BAR_LAUNCHER_CONFIG_URL);
        if($httpRes->{success}) {
          my $r_barLauncherConf = eval {decode_json($httpRes->{content})};
          if(ref $r_barLauncherConf eq 'HASH' && ref $r_barLauncherConf->{setups} eq 'ARRAY') {
            my $launcherPackageId = 'manual-'.(MSWIN32 ? 'win' : 'linux');
            foreach my $r_barSetup (@{$r_barLauncherConf->{setups}}) {
              next unless(ref $r_barSetup eq 'HASH' && ref $r_barSetup->{package} eq 'HASH');
              my $r_barPackage=$r_barSetup->{package};
              next unless(defined $r_barPackage->{id} && ref $r_barPackage->{id} eq '' && $r_barPackage->{id} eq $launcherPackageId);
              if(ref $r_barSetup->{env_variables} eq 'HASH' && (all {defined $r_barSetup->{env_variables}{$_} && ref $r_barSetup->{env_variables}{$_} eq ''} (keys %{$r_barSetup->{env_variables}}))) {
                if(! defined $self->{cache}{prDownloaderEnvVars} || keys %{$self->{cache}{prDownloaderEnvVars}} != keys %{$r_barSetup->{env_variables}}
                   || (any {! defined $self->{cache}{prDownloaderEnvVars}{$_} || $self->{cache}{prDownloaderEnvVars}{$_} ne $r_barSetup->{env_variables}{$_}} (keys %{$r_barSetup->{env_variables}}))) {
                  $self->{cache}{prDownloaderEnvVars}=$r_barSetup->{env_variables};
                  $result{cache}{prDownloaderEnvVars}=$r_barSetup->{env_variables};
                }
              }
              last;
            }
          }
        }
        $self->{prDownloaderEnvVars}=$self->{cache}{prDownloaderEnvVars};
      }
      if(defined $self->{prDownloaderEnvVars}) {
        map {$ENV{$_}=$self->{prDownloaderEnvVars}{$_}} (keys %{$self->{prDownloaderEnvVars}});
      }
    }
    my $packagesDir=catdir($prDownloaderWritePath,'packages');
    my $packagesDirTimestamp=(stat($packagesDir))[9]//0;
    open(my $previousStdout,'>&',\*STDOUT);
    open(STDOUT,'>',devnull());
    my ($ec,$prdErrMsg)=portableSystem($prDownloaderPath,'--disable-logging','--filesystem-writepath',$prDownloaderWritePath,'--download-game',$gameRapidTag);
    open(STDOUT,'>&',$previousStdout);
    if(defined $ec) {
      $result{game}={
        prdExitCode => $ec,
        packagesDirUpdated => ((stat($packagesDir))[9]//0) == $packagesDirTimestamp ? 0 : 1,
      };
    }else{
      $result{game}={error => "failed to run pr-downloader ($prdErrMsg)"};
    }
  }

  return \%result;
}

sub getHttpErrMsg {
  my $httpRes=shift;
  if($httpRes->{status} == 599) {
    my $errMsg=$httpRes->{content};
    chomp($errMsg);
    return $errMsg;
  }
  return "HTTP status $httpRes->{status} - $httpRes->{reason}";
}

sub portableSystem {
  my ($program,@params)=@_;
  my @args=($program,@params);
  @args=map {::escapeWin32Parameter($_)} @args if(::MSWIN32());
  system {$program} @args;
  if($? == -1) {
    return (undef,$!);
  }elsif($? & 127) {
    return (undef,sprintf("Process died with signal %d, %s coredump", $? & 127 , ($? & 128) ? 'with' : 'without'));
  }else{
    return ($? >> 8);
  }
}

sub updateBarEnd {
  my ($r_result,$reloadArchivesIfNeeded,$self)=@_;
  $self//=getPlugin();
  
  $self->{updateInProgress}=0;
  slog('End of BAR auto-update process',5);
  
  if(! ref $r_result eq 'HASH') {
    slog('BAR auto-update process terminated abnormally (unknown error)',1);
    return;
  }

  my $spadsConfFull=getSpadsConfFull();
  foreach my $mapConfUpdateType (qw'mapLists mapBoxes') {
    my $r_mapConfResult=$r_result->{$mapConfUpdateType};
    my $mapConfFile=$mapConfUpdateType.'.conf';
    if(! defined $r_mapConfResult) {
      slog("Auto-update of $mapConfFile file: disabled",5);
      next;
    }
    if(exists $r_mapConfResult->{error}) {
      slog("Error during auto-update of $mapConfFile file: $r_mapConfResult->{error}",2);
      next;
    }
    if($r_mapConfResult->{httpStatus} == 304) {
      slog("Auto-update of $mapConfFile file: no change",5);
    }else{
      slog("File $mapConfFile auto-updated",3);
      if($mapConfUpdateType eq 'mapLists') {
        if($spadsConfFull->can('reloadMapLists')) {
          if($spadsConfFull->reloadMapLists(\%::confMacros)) {
            ::applySettingChange('maplist');
            slog('Auto-reloaded new map lists',5);
          }else{
            slog('Failed to auto-reload new map lists',2);
          }
        }else{
          slog('Unable to reload new map lists (not supported by current SpadsConf module)',2);
        }
      }else{
        if($spadsConfFull->can('reloadMapBoxes')) {
          if($spadsConfFull->reloadMapBoxes(\%::confMacros)) {
            slog('Auto-reloaded new map boxes',5);
          }else{
            slog('Failed to auto-reload new map boxes',2);
          }
        }else{
          slog('Unable to reload new map boxes (not supported by current SpadsConf module)',2);
        }
      }
    }
  }

  my $reloadArchivesNeeded;
  
  my $r_mapsResult=$r_result->{maps};
  if(defined $r_mapsResult) {
    if(exists $r_mapsResult->{error}) {
      slog("Error during automatic download of new maps: $r_mapsResult->{error}",2);
    }else{
      my %mapCounts;
      map {$mapCounts{$_} = exists $r_mapsResult->{$_} ? @{$r_mapsResult->{$_}} : 0} (qw'skipped downloaded failed');
      slog("Automatic download of new maps: $mapCounts{skipped} kept, $mapCounts{downloaded} downloaded, $mapCounts{failed} failed",5);
      if($mapCounts{downloaded}) {
        $reloadArchivesNeeded=1;
        my $mapListStrSuffix='';
        my $maxMapIdx=$mapCounts{downloaded}-1;
        if($maxMapIdx > 4) {
          $maxMapIdx=4;
          $mapListStrSuffix=', ...';
        }
        my $mapListStr=join(', ',@{$r_mapsResult->{downloaded}}[0..$maxMapIdx]).$mapListStrSuffix;
        slog('Automatic download of new maps: '.$mapCounts{downloaded}.' new map'.($mapCounts{downloaded}>1?'s':'').' downloaded ('.$mapListStr.')',3);
      }
      if($mapCounts{failed}) {
        my $failureIdx=0;
        while($failureIdx < $mapCounts{failed}) {
          if($failureIdx > 3 && $mapCounts{failed} > 5) {
            slog('('.($mapCounts{failed}-$failureIdx).' more map download failures...)',2);
            last;
          }
          my $r_failureData=$r_mapsResult->{failed}[$failureIdx];
          slog("Error while downloading new map \"$r_failureData->{mapName}\" from \"$r_failureData->{mapUrl}\": $r_failureData->{error}",2);
        }
      }
    }
  }else{
    slog('Automatic download of new maps: disabled',5);
  }

  my $r_gameResult=$r_result->{game};
  if(defined $r_gameResult) {
    if(exists $r_gameResult->{error}) {
      slog("Error during game auto-update: $r_gameResult->{error}",2);
    }else{
      my $ecStr = $r_gameResult->{prdExitCode} ? " pr-downloader exited with return value $r_gameResult->{prdExitCode}," : '';
      my $updStr = $r_gameResult->{packagesDirUpdated} ? 'rapid packages updated' : 'no rapid package update';
      slog("Game auto-update:$ecStr $updStr",$r_gameResult->{prdExitCode} ? 2 : ($r_gameResult->{packagesDirUpdated} ? 3 : 5));
      $reloadArchivesNeeded=1 if($r_gameResult->{packagesDirUpdated});
    }
  }else{
    slog('Game auto-update: disabled',5);
  }

  my $r_cache=$r_result->{cache};
  if(defined $r_cache) {
    if(exists $r_cache->{eTags}) {
      foreach my $configFile (keys %{$r_cache->{eTags}}) {
        if((defined $self->{cache}{eTags}{$configFile} && ! defined $r_cache->{eTags}{$configFile})
           || (! defined $self->{cache}{eTags}{$configFile} && defined $r_cache->{eTags}{$configFile})
           || (defined $self->{cache}{eTags}{$configFile} && $self->{cache}{eTags}{$configFile} ne $r_cache->{eTags}{$configFile})) {
          slog("Caching updated eTag for file \"$configFile\" (old value: "
               .($self->{cache}{eTags}{$configFile} // 'UNDEF').', new value: '
               .($r_cache->{eTags}{$configFile} // 'UNDEF').')',5);
          $self->{cache}{eTags}{$configFile}=$r_cache->{eTags}{$configFile};
        }
      }
    }
    foreach my $cachedData (qw'mapDownloadDirectory prDownloaderPath prDownloaderWritePath') {
      if(exists $r_cache->{$cachedData}) {
        slog("Caching autodetected value for setting \"$cachedData\" (\"$r_cache->{$cachedData}\")",5);
        $self->{cache}{$cachedData}=$r_cache->{$cachedData};
      }
    }
    if(exists $r_cache->{prDownloaderEnvVars}) {
      my $envVars=join(', ',map {"$_=$r_cache->{prDownloaderEnvVars}{$_}"} sort keys %{$r_cache->{prDownloaderEnvVars}});
      slog("Caching new pr-downloader environement variables set ($envVars)",5);
      $self->{cache}{prDownloaderEnvVars}=$r_cache->{prDownloaderEnvVars};
      $self->{prDownloaderEnvVars}=$self->{cache}{prDownloaderEnvVars};
    }
    my $cacheFile=catfile(getSpadsConf()->{varDir},'BarAutoUpdate.dat');
    nstore($self->{cache},$cacheFile)
        or slog("Failed to store cache data in file \"$cacheFile\"",1);
  }
  $self->{prDownloaderEnvVars}//=$self->{cache}{prDownloaderEnvVars};

  if($reloadArchivesNeeded && $reloadArchivesIfNeeded) {
    slog('Auto-reloading archives after BAR auto-update at startup...',3);
    ::loadArchives();
    AE::now_update() unless(SimpleEvent::getModel() eq 'internal');
  }
  
  slog('End of BAR auto-update post-processing',5);
}

sub mapConfAutoReload {
  my $self=getPlugin();
  return if($self->{barAuLock});
  my $r_pluginConf=getPluginConf();
  my $r_spadsConf=getSpadsConf();
  my $spadsConfFull=getSpadsConfFull();
  foreach my $mapConfType (qw'Lists Boxes') {
    next unless($r_pluginConf->{'autoReloadMap'.$mapConfType});
    my $confFile='map'.$mapConfType.'.conf';
    my $confFileAbsPath=catfile($r_spadsConf->{etcDir},$confFile);
    my $modifTime=(stat($confFileAbsPath))[9];
    if(! defined $modifTime) {
      slog("Unable to check timestamp of file \"$confFileAbsPath\" for auto-reload",2);
      next;
    }
    if(! defined $self->{mapConfTimestamps}{$confFile} || $self->{mapConfTimestamps}{$confFile} != $modifTime) {
      $self->{mapConfTimestamps}{$confFile}=$modifTime;
      slog("File $confFile changed on disk, auto-reloading...",3);
      if($mapConfType eq 'Lists') {
        if($spadsConfFull->can('reloadMapLists')) {
          if($spadsConfFull->reloadMapLists(\%::confMacros)) {
            ::applySettingChange('maplist');
            slog('Auto-reloaded new map lists',5);
          }else{
            slog('Failed to auto-reload new map lists',2);
          }
        }else{
          slog('Unable to reload new map lists (not supported by current SpadsConf module)',2);
        }
      }else{
        if($spadsConfFull->can('reloadMapBoxes')) {
          if($spadsConfFull->reloadMapBoxes(\%::confMacros)) {
            slog('Auto-reloaded new map boxes',5);
          }else{
            slog('Failed to auto-reload new map boxes',2);
          }
        }else{
          slog('Unable to reload new map boxes (not supported by current SpadsConf module)',2);
        }
      }
    }
  }
}

sub onUnload {
  my $self=shift;
  removeTimer('BarAutoUpdate') if(getPluginConf()->{autoUpdateInterval});
  removeTimer('MapConfAutoReload');
  SimpleEvent::removeForkedProcessCallback('CloseBarAuLock');
  close($self->{barAuLock}) if($self->{barAuLock});
  slog('Plugin unloaded',3);
}

sub delayShutdown {
  my $self=shift;
  return $self->{updateInProgress};
}

1;
