#!/usr/bin/perl -w
#
# This program installs SPADS in current directory from remote repository.
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

# Version 0.37 (2023/11/24)

use strict;

use Config;
use Cwd;
use Digest::MD5 'md5_base64';
use File::Basename 'fileparse';
use File::Copy;
use File::Path;
use File::Spec::Functions qw'canonpath catdir catfile devnull file_name_is_absolute splitdir splitpath';
use FindBin;
use HTTP::Tiny;
use JSON::PP 'decode_json';
use List::Util qw'any all none notall';
use POSIX 'ceil';

use constant {
  MAX_PROGRESS_BAR_SIZE => 40,
  REPORT_SEPARATOR => -t STDOUT ? "\r" : "\n",
};

use lib $FindBin::Bin;

use SimpleLog;
use SpadsUpdater;

my $win=$^O eq 'MSWin32';
my $macOs=$^O eq 'darwin';

my $dynLibSuffix=$win?'dll':($macOs?'dylib':'so');
my $unitsyncLibName=($win?'':'lib')."unitsync.$dynLibSuffix";
my $PRD_BIN='pr-downloader'.($win?'.exe':'');

my $URL_SPADS='http://planetspads.free.fr/spads';
my $URL_TEMPLATES="$URL_SPADS/installer/auto/";
my @packages=(qw'getDefaultModOptions.pl help.dat helpSettings.dat PerlUnitSync.pm springLobbyCertificates.dat SpringAutoHostInterface.pm SpringLobbyInterface.pm SimpleEvent.pm SimpleLog.pm spads.pl SpadsConf.pm spadsInstaller.pl SpadsUpdater.pm SpadsPluginApi.pm update.pl argparse.py replay_upload.py sequentialSpadsUnitsyncProcess.pl',$win?'7za.exe':'7za');

my $nbSteps=$macOs?14:15;
my $isInteractive=-t STDIN;
my $pathSep=$win?';':':';
my @pathes=splitPaths($ENV{PATH});
my %conf=(installDir => canonpath($FindBin::Bin));
my %lastRun;
my @lastRunOrder;
my $isBarEngine;

my %ENGINE_RELEASES=(stable => 'recommended release',
                     testing => 'next release candidate',
                     unstable => 'latest develop version');
my @MAP_RESOLVERS=(
  'https://springfiles.springrts.com/json.php?category=map&springname=',
  'https://files-cdn.beyondallreason.dev/find?category=map&springname=',
    );

if($win) {
  eval { require Win32; 1; }
    or die "$@Missing dependency: Win32 Perl module\n";
  eval { require Win32::API; 1; }
    or die "$@Missing dependency: Win32::API Perl module\n";
  eval { Win32::API->VERSION(0.73); 1; }
    or die "$@SPADS requires Win32::API module version 0.73 or superior.\nPlease update your Perl installation (Perl 5.16.2 or superior is recommended)\n";
  eval { require Win32::TieRegistry; Win32::TieRegistry->import(':KEY_'); 1; }
    or die "$@Missing dependency: Win32::TieRegistry Perl module\n";
}else{
  eval { require FFI::Platypus; 1; }
    or die "$@Missing dependency: FFI::Platypus Perl module\n";
}

my $sslAvailable = eval { require IO::Socket::SSL; 1; };

my $sqliteUnavailableReason;
if(eval { require DBI; 1; }) {
  $sqliteUnavailableReason='Perl module not found: DBD::SQLite'
      if(none {$_ eq 'SQLite'} DBI->available_drivers());
}else{
  chomp($@);
  $sqliteUnavailableReason="failed to load Perl DBI module: $@";
}

my $sLog=SimpleLog->new(logFiles => [''],
                        logLevels => [4],
                        useANSICodes => [-t STDOUT ? 1 : 0],
                        useTimestamps => [-t STDOUT ? 0 : 1],
                        prefix => '[SpadsInstaller] ');
sub slog {
  $sLog->log(@_);
}

sub invalidUsage {
  my $err=shift;
  slog('Invalid usage'.(defined $err ? " ($err)" : ''),1);
  print "Usage:\n";
  print "  perl $0 [<release>] [--auto <templateNameOrUrl>]\n";
  print "  perl $0 --list-templates\n";
  print "      release: \"stable\", \"testing\", \"unstable\" or \"contrib\"\n";
  print "      templateNameOrUrl: auto-install template name or URL\n";
  exit 1;
}

sub getAvailableOnlineTemplates {
  my $httpRes=HTTP::Tiny->new(timeout => 10)->get($URL_TEMPLATES);
  if($httpRes->{success}) {
    my @availableTemplates=($httpRes->{content} =~ /<a href="([\w\.\-]+)\/">\1\/<\/a>/ig);
    return \@availableTemplates;
  }else{
    print "ERROR - Unable to retrieve available installation templates (".getHttpErrMsg($httpRes).")\n";
    exit 1;
  }
}

if(any {$_ eq '--list-templates'} @ARGV) {
  invalidUsage('the --list-templates parameter cannot be used with other parameter') unless(@ARGV == 1);
  my $r_availableTemplates=getAvailableOnlineTemplates();
  if(@{$r_availableTemplates}) {
    print 'Available installation template'.($#{$r_availableTemplates}?'s':'').":\n";
    map {print "  . $_\n"} (@{$r_availableTemplates});
  }else{
    print "No available installation template found.\n";
  }
  exit 0;
}

my $templateName;
my $templateUrl;
my $releaseIsFromCmdLineParam;
{
  my $nextParamIsOnlineTemplate;
  foreach my $installArg (@ARGV) {
    if($nextParamIsOnlineTemplate) {
      if($installArg =~ /^[\w\.\-]+$/) {
        $templateName=$installArg;
        my $r_availableTemplates=getAvailableOnlineTemplates();
        invalidUsage("unknown installation template \"$templateName\"")
            unless(any {$templateName eq $_} @{$r_availableTemplates});
        $templateUrl="$URL_TEMPLATES$templateName/spadsInstaller.auto";
      }elsif($installArg =~ /^https?:\/\//i) {
        fatalError('Cannot use online installation template from HTTPS URL because TLS support is missing (IO::Socket::SSL version 1.42 or superior and Net::SSLeay version 1.49 or superior are required)')
            if(lc(substr($installArg,4,1)) eq 's' && ! SpadsUpdater::checkHttpsSupport());
        $templateUrl=$installArg;
      }else{
        invalidUsage("invalid installation template name or URL \"$installArg\"");
      }
      $nextParamIsOnlineTemplate=0;
    }elsif($installArg eq '--auto') {
      if(defined $templateUrl) {
        invalidUsage('duplicate installation template declaration');
      }else{
        $nextParamIsOnlineTemplate=1;
      }
    }elsif(any {$installArg eq $_} qw'stable testing unstable contrib') {
      if(defined $conf{release}) {
        invalidUsage('duplicate installation release parameter');
      }else{
        $releaseIsFromCmdLineParam=1;
        $conf{release}=$installArg;
      }
    }else{
      invalidUsage("invalid parameter \"$installArg\"");
    }
  }
  invalidUsage('missing installation template parameter') if($nextParamIsOnlineTemplate);
}

my @autoInstallLines;
my $autoInstallFile=catfile($conf{installDir},'spadsInstaller.auto');
if(defined $templateUrl) {
  my $httpRes=HTTP::Tiny->new(timeout => 10)->get($templateUrl);
  if($httpRes->{success}) {
    @autoInstallLines=split(/\cJ\cM?/,$httpRes->{content});
  }else{
    print "ERROR - Unable to retrieve auto-install data from \"$templateUrl\" (".getHttpErrMsg($httpRes).")\n";
    exit 1;
  }
  slog("Using auto-install data from URL \"$templateUrl\"...",3);
}elsif(-f $autoInstallFile) {
  open(my $fh,'<',$autoInstallFile)
      or do {
        print "ERROR - Unable to read auto-install data from file \"$autoInstallFile\" ($!)\n";
        exit 1;
  };
  @autoInstallLines=<$fh>;
  close($fh);
  slog("Using auto-install data from file \"$autoInstallFile\"...",3);
}

my %autoInstallData;
foreach my $autoInstallLine (@autoInstallLines) {
  next if($autoInstallLine =~ /^\s*(\#.*)?$/);
  if($autoInstallLine =~ /^\s*([^:]*[^:\s])\s*:\s*((?:.*[^\s])?)\s*$/) {
    $autoInstallData{$1}=$2;
  }else{
    $autoInstallLine =~ s/[\cJ\cM]*$//;
    print "ERROR - Invalid line \"$autoInstallLine\" in auto-install data from ".($templateUrl // "file \"$autoInstallFile\"")."\n";
    exit 1;
  }
}

sub setLastRun {
  my ($k,$v)=@_;
  push(@lastRunOrder,$k);
  $lastRun{$k}=$v;
}

sub fatalError { slog(shift,0); exit 1; }

sub splitPaths { return split(/$pathSep/,shift//''); }

sub isAbsolutePath {
  my $fileName=shift;
  my $fileSpecRes=file_name_is_absolute($fileName);
  return $fileSpecRes == 2 if($win);
  return $fileSpecRes;
}

sub isAbsoluteFilePath {
  my ($path,$fileName)=@_;
  return '' unless(isAbsolutePath($path));
  if(! -f $path) {
    $path=catfile($path,$fileName);
    return '' unless(-f $path);
  }
  return '' unless((splitpath($path))[2] eq $fileName);
  return $path;
}

sub makeAbsolutePath {
  my ($path,$defaultBaseDir)=@_;
  $defaultBaseDir//=$conf{installDir};
  $path=catdir($defaultBaseDir,$path) unless(isAbsolutePath($path));
  return $path;
}

sub createDir {
  my $dir=shift;
  my $nbCreatedDir=0;
  eval { $nbCreatedDir=mkpath($dir) };
  fatalError("Couldn't create directory \"$dir\" ($@)") if($@);
  slog("Directory \"$dir\" created",3) if($nbCreatedDir);
}

sub downloadFile {
  my ($url,$file)=@_;
  my $httpRes=HTTP::Tiny->new(timeout => 10)->mirror($url,$file);
  if(! $httpRes->{success} || ! -f $file) {
    slog("Unable to download $file from $url (".getHttpErrMsg($httpRes).')',1);
    unlink($file);
    return 0;
  }
  return 2 if($httpRes->{status} == 304);
  return 1;
}

{
  my ($progressBar,$progressBarLength);
  my ($nbUpdates,$remainingUpdates);
  my ($currentTrunkNb,$currentTrunkSize);

  sub newProgressBar {
    ($progressBar,$progressBarLength)=('',0);
    ($nbUpdates,$remainingUpdates)=($_[0],$_[0]);
    ($currentTrunkNb,$currentTrunkSize)=(1,$remainingUpdates > MAX_PROGRESS_BAR_SIZE ? MAX_PROGRESS_BAR_SIZE : $remainingUpdates);
    $|=1 if(REPORT_SEPARATOR eq "\r");
    updateProgressBar();
  }

  sub updateProgressBar {
    die "Invalid call to updateProgressBar(): uninitialized progress bar\n" unless(defined $progressBar);
    if(defined $_[0]) {
      $progressBar.=$_[0];
      $progressBarLength++;
      $remainingUpdates--;
    }
    my $updateDetails = defined $_[1] ? ' '.$_[1] : '';
    my $updatesDone = ($currentTrunkNb-1) * MAX_PROGRESS_BAR_SIZE + $progressBarLength;
    my $percentDone=sprintf('%3s',int($updatesDone*100/$nbUpdates+0.5));
    my $trunkString = $nbUpdates > MAX_PROGRESS_BAR_SIZE ? $currentTrunkNb.'/'.ceil($nbUpdates/MAX_PROGRESS_BAR_SIZE).' ' : '';
    my $updateString=$trunkString.'['.$progressBar.(' ' x ($currentTrunkSize-$progressBarLength)).'] '.$percentDone."% ($updatesDone/$nbUpdates)".$updateDetails;
    my $paddingLength=80-length($updateString);
    if($paddingLength>0) {
      $updateString .= ' ' x  $paddingLength;
    }elsif($paddingLength < 0) {
      $updateString=substr($updateString,0,77).'...';
    }
    print $updateString.REPORT_SEPARATOR;
    if(! $remainingUpdates) {
      endProgressBar();
      return;
    }
    if($progressBarLength == $currentTrunkSize) {
      print "\n" if(REPORT_SEPARATOR eq "\r");
      ($progressBar,$progressBarLength)=('',0);
      $currentTrunkNb++;
      $currentTrunkSize = $remainingUpdates > MAX_PROGRESS_BAR_SIZE ? MAX_PROGRESS_BAR_SIZE : $remainingUpdates;
    }
  }

  sub endProgressBar {
    undef $progressBar;
    return if(REPORT_SEPARATOR eq "\n");
    $|=0;
    print "\n";
  }
}

sub getHttpErrMsg {
  my $httpRes=shift;
  if($httpRes->{status} == 599) {
    my $errMsg=$httpRes->{content};
    chomp($errMsg);
    return $errMsg;
  }
  return "HTTP $httpRes->{status}: $httpRes->{reason}";
}

sub downloadMapsWithProgressBar {
  my ($r_urls,$targetDir)=@_;
  my $httpTiny=HTTP::Tiny->new(timeout => 10);
  my @dlErrors;
  newProgressBar($#{$r_urls}+1);
  my $downloadAborted;
  for my $idx (0..$#{$r_urls}) {
    my $url=$r_urls->[$idx];
    if($url =~ /\/([^\/]+\.sd7)$/) {
      my $fileName=$1;
      updateProgressBar(undef,$fileName);
      my $filePath=catfile($targetDir,$fileName);
      if(-e $filePath) {
        updateProgressBar('-');
      }else{
        my $httpRes=$httpTiny->mirror($url,$filePath);
        if(! $httpRes->{success} || ! -f $filePath) {
          push(@dlErrors,"Failed to download \"$url\" to \"$filePath\" (".getHttpErrMsg($httpRes).')');
          updateProgressBar('!');
          unlink($filePath);
        }else{
          updateProgressBar($httpRes->{status} == 304 ? '-' : '=');
        }
      }
    }else{
      push(@dlErrors,"Skipping unrecognized map download URL \"$url\"");
      updateProgressBar('?');
    }
    if($idx == 4 && @dlErrors == 5) {
      $downloadAborted=1;
      endProgressBar();
      last;
    }
  }
  map {slog($_,2)} @dlErrors;
  slog('Map downloads aborted',2) if($downloadAborted);
}

sub downloadMapsFromUrlOrNameWithProgressBar {
  my ($r_mapNames,$targetDir)=@_;
  my $httpTiny=HTTP::Tiny->new(timeout => 10);
  my @dlErrors;
  newProgressBar($#{$r_mapNames}+1);
  my $downloadAborted;
  MAPS_LOOP: for my $idx (0..$#{$r_mapNames}) {
    my ($mapName,$mapUrl) = ref $r_mapNames->[$idx] eq 'ARRAY' ? @{$r_mapNames->[$idx]} : ($r_mapNames->[$idx]);
    updateProgressBar(undef,$mapName);
    my $lastErrorSymbol;
    if(defined $mapUrl) {
      if($mapUrl =~ /\/([^\/]+\.sd[7z])$/) {
        my $filePath=catfile($targetDir,$1);
        if(-e $filePath) {
          updateProgressBar('-');
          next MAPS_LOOP;
        }else{
          my $httpRes=$httpTiny->mirror($mapUrl,$filePath);
          if(! $httpRes->{success} || ! -f $filePath) {
            push(@dlErrors,"Failed to download \"$mapUrl\" to \"$filePath\" (".getHttpErrMsg($httpRes).')');
            $lastErrorSymbol='!'; # (in case @MAP_RESOLVERS is empty)
            unlink($filePath);
          }else{
            updateProgressBar($httpRes->{status} == 304 ? '-' : '=');
            next MAPS_LOOP;
          }
        }
      }else{
        push(@dlErrors,"Skipping unrecognized map download URL \"$mapUrl\" from map list with links");
        $lastErrorSymbol='?'; # (in case @MAP_RESOLVERS is empty)
      }
    }
    my $resolverId = $#MAP_RESOLVERS > 0 ? int(rand($#MAP_RESOLVERS)+0.5) : 0;
    my $nbRetry=0;
    while($nbRetry < @MAP_RESOLVERS) {
      my $httpRes=$httpTiny->get($MAP_RESOLVERS[$resolverId].HTTP::Tiny->_uri_escape($mapName));
      if($httpRes->{success}) {
        my $r_jsonMapData = eval { decode_json($httpRes->{content}) };
        if(defined $r_jsonMapData) {
          if(ref $r_jsonMapData eq 'ARRAY' && ref $r_jsonMapData->[0] eq 'HASH'
             && ref $r_jsonMapData->[0]{mirrors} && 'ARRAY' && defined $r_jsonMapData->[0]{mirrors}[0]) {
            my $url=$r_jsonMapData->[0]{mirrors}[0];
            if($url =~ /\/([^\/]+\.sd[7z])$/) {
              my $filePath=catfile($targetDir,$1);
              if(-e $filePath) {
                updateProgressBar('~');
                next MAPS_LOOP;
              }else{
                $httpRes=$httpTiny->mirror($url,$filePath);
                if(! $httpRes->{success} || ! -f $filePath) {
                  push(@dlErrors,"Failed to download \"$url\" to \"$filePath\" (".getHttpErrMsg($httpRes).')');
                  $lastErrorSymbol='!';
                  unlink($filePath);
                }else{
                  updateProgressBar($httpRes->{status} == 304 ? '~' : '#');
                  next MAPS_LOOP;
                }
              }
            }else{
              push(@dlErrors,"Skipping unrecognized map download URL \"$url\" from map name resolver \#$resolverId");
              $lastErrorSymbol='?';
            }
          }else{
            push(@dlErrors,"Unknown JSON response from map name resolver \#$resolverId for map $mapName");
            $lastErrorSymbol='?';
          }
        }else{
          push(@dlErrors,"Invalid JSON response from map name resolver \#$resolverId for map $mapName");
          $lastErrorSymbol='?';
        }
      }else{
        push(@dlErrors,"Unable to call map name resolver \#$resolverId for map $mapName (".getHttpErrMsg($httpRes).')');
        $lastErrorSymbol='!';
      }
      $nbRetry++;
      if($nbRetry == @MAP_RESOLVERS) {
        updateProgressBar($lastErrorSymbol);
        last;
      }
      $resolverId = ($resolverId+1) % @MAP_RESOLVERS;
    }
    if($idx == 4 && @dlErrors == 5 * (@MAP_RESOLVERS+1)) {
      $downloadAborted=1;
      endProgressBar();
      last;
    }
  }
  if(@dlErrors < 11) {
    map {slog($_,2)} @dlErrors;
  }else{
    map {slog($dlErrors[$_],2)} (0..8);
    slog('... ('.(@dlErrors-9).' more)',2);
  }
  slog('Map downloads aborted',2) if($downloadAborted);
}

# This function is not used because SpringRTS and Recoil pr-downloader have different behavior.
# (Recoil pr-downloader always re-downloads maps, even if they have already been downloaded)
sub downloadMapsUsingPrdWithProgressBar {
  my ($prdPath,$mapModDataDir,$r_mapNames)=@_;
  my @dlErrors;
  newProgressBar($#{$r_mapNames}+1);
  my $downloadAborted;
  for my $idx (0..$#{$r_mapNames}) {
    my $mapName=$r_mapNames->[$idx];
    updateProgressBar(undef,$mapName);
    open(my $previousStdout,'>&',\*STDOUT);
    open(my $previousStderr,'>&',\*STDERR);
    my $nullDevice=devnull();
    open(STDOUT,'>',$nullDevice);
    open(STDERR,'>',$nullDevice);
    my ($rc,$errMsg)=portableSystem($prdPath,'--disable-logging','--filesystem-writepath',$mapModDataDir,'--download-map',$mapName);
    open(STDOUT,'>&',$previousStdout);
    open(STDERR,'>&',$previousStderr);
    if(! defined $rc) {
      push(@dlErrors,'Error when calling pr-downloader - '.$errMsg);
      updateProgressBar('!');
      $downloadAborted=1;
      endProgressBar();
      last;
    }
    if($rc) {
      push(@dlErrors,"pr-downloader exited with return value $rc");
      updateProgressBar('!');
    }else{
      updateProgressBar('=');
    }
    if($idx == 4 && @dlErrors == 5) {
      $downloadAborted=1;
      endProgressBar();
      last;
    }
  }
  map {slog($_,2)} @dlErrors;
  slog('Map downloads aborted',2) if($downloadAborted);
}

sub escapeWin32Parameter {
  my $arg = shift;
  $arg =~ s/(\\*)"/$1$1\\"/g;
  if($arg =~ /[ \t]/) {
    $arg =~ s/(\\*)$/$1$1/;
    $arg = "\"$arg\"";
  }
  return $arg;
}

sub portableExec {
  my ($program,@params)=@_;
  my @args=($program,@params);
  @args=map {escapeWin32Parameter($_)} @args if($win);
  return exec {$program} @args;
}

sub portableSystem {
  my ($program,@params)=@_;
  my @args=($program,@params);
  @args=map {escapeWin32Parameter($_)} @args if($win);
  system {$program} @args;
  if($? == -1) {
    return (undef,"Failed to execute: $!");
  }elsif($? & 127) {
    return (undef,sprintf("Process died with signal %d, %s coredump", $? & 127 , ($? & 128) ? 'with' : 'without'));
  }else{
    return ($? >> 8);
  }
}

sub promptStdin {
  my ($promptMsg,$defaultValue,$autoInstallValue)=@_;
  print "$promptMsg ".(defined $defaultValue ? "[$defaultValue] " : '').'? ';
  my $value;
  if(defined $autoInstallValue) {
    $value=$autoInstallValue;
    print "$value\n";
  }else{
    $value=<STDIN>;
    print "\n" unless($isInteractive);
    $value//='';
    chomp($value);
  }
  $value=$defaultValue if(defined $defaultValue && $value eq '');
  return $value;
}

sub promptChoice {
  my ($prompt,$p_choices,$default,$autoInstallValue)=@_;
  my @choices=@{$p_choices};
  my $choicesString=join(',',@choices);
  my $choice='';
  while(none {$choice eq $_} @choices) {
    $choice=promptStdin("$prompt ($choicesString)",$default,$autoInstallValue);
    $autoInstallValue=undef;
  }
  return $choice;
}

sub promptExistingFile {
  my ($prompt,$fileName,$default,$autoInstallValue)=@_;
  my $choice='';
  my $firstTry=1;
  while(! isAbsoluteFilePath($choice,$fileName)) {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    $choice=promptStdin("$prompt ($fileName)",$default,$autoInstallValue);
    $autoInstallValue=undef;
  }
  return isAbsoluteFilePath($choice,$fileName);
}

sub promptExistingDir {
  my ($prompt,$default,$acceptSpecialValue,$r_testFunction,$autoInstallValue)=@_;
  my $choice='';
  my $firstTry=1;
  while(! isAbsolutePath($choice) || ! -d $choice || index($choice,$pathSep) != -1 || (defined $r_testFunction && ! $r_testFunction->($choice))) {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    $choice=promptStdin($prompt,$default,$autoInstallValue);
    $autoInstallValue=undef;
    last if(defined $acceptSpecialValue && $choice eq $acceptSpecialValue);
  }
  return $choice;
}

sub promptDir {
  my ($prompt,$dirName,$defaultDir,$defaultBaseDir)=@_;
  my $autoInstallValue=$autoInstallData{$dirName};
  my $dir=promptStdin($prompt,$defaultDir,$autoInstallValue);
  setLastRun($dirName,$dir);
  $conf{$dirName}=$dir;
  my $fullDir=makeAbsolutePath($dir,$defaultBaseDir);
  createDir($fullDir);
  return $fullDir;
}

sub promptString {
  my ($prompt,$defaultVal,$autoInstallValue,$r_checkFunc)=@_;
  my $choice='';
  my $firstTry=1;
  while($choice eq '' || (defined $r_checkFunc && ! $r_checkFunc->($choice))) {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    $choice=promptStdin($prompt,$defaultVal,$autoInstallValue);
    $autoInstallValue=undef;
  }
  return $choice;
}

sub areSamePaths {
  my ($p1,$p2)=map {canonpath($_)} @_;
  ($p1,$p2)=map {lc($_)} ($p1,$p2) if($win);
  return $p1 eq $p2;
}

sub setEnvVarFirstPaths {
  my ($varName,@firstPaths)=@_;
  my $needRestart=0;
  fatalError("Unable to handle path containing \"$pathSep\" character!") if(any {index($_,$pathSep) != -1} @firstPaths);
  $ENV{"SPADS_$varName"}=$ENV{$varName}//'_UNDEF_' unless(exists $ENV{"SPADS_$varName"});
  my @currentPaths=split(/$pathSep/,$ENV{$varName}//'');
  $needRestart=1 if($#currentPaths < $#firstPaths);
  if(! $needRestart) {
    for my $i (0..$#firstPaths) {
      if(! areSamePaths($currentPaths[$i],$firstPaths[$i])) {
        $needRestart=1;
        last;
      }
    }
  }
  if($needRestart) {
    my @origPaths=$ENV{"SPADS_$varName"} eq '_UNDEF_' ? () : split(/$pathSep/,$ENV{"SPADS_$varName"});
    my @newPaths;
    foreach my $path (@origPaths) {
      push(@newPaths,$path) unless(any {areSamePaths($path,$_)} @firstPaths);
    }
    $ENV{$varName}=join($pathSep,@firstPaths,@newPaths);
  }
  return $needRestart;
}

my $currentStep;
my $unitsyncDir;
sub configureUnitsyncDir {
  if(exists $conf{autoInstalledSpringDir}) {
    $conf{unitsyncDir}='';
    $unitsyncDir=$conf{autoInstalledSpringDir};
    return;
  }
  my @potentialUnitsyncDirs;
  if($win) {
    @potentialUnitsyncDirs=(@pathes,catdir(Win32::GetFolderPath(Win32::CSIDL_PROGRAM_FILES()),'Spring'));
  }elsif($macOs) {
    @potentialUnitsyncDirs=sort {-M $a <=> -M $b} (grep {-d $_} </Applications/Spring*.app/Contents/MacOS>);
  }else{
    @potentialUnitsyncDirs=(split(/:/,$ENV{LD_LIBRARY_PATH}//''),catdir($ENV{HOME},'spring','lib'),'/usr/local/lib','/usr/lib','/usr/lib/spring');
  }
  my $defaultUnitsync;
  foreach my $libPath (@potentialUnitsyncDirs) {
    if(-f "$libPath/$unitsyncLibName") {
      $defaultUnitsync=catfile($libPath,$unitsyncLibName);
      last;
    }
  }
  my $unitsync=promptExistingFile("[$currentStep/$nbSteps] Please enter the absolute path of the unitsync library".($win?', usually located in the Spring installation directory on Windows systems':''),$unitsyncLibName,$defaultUnitsync,$autoInstallData{unitsyncPath});
  setLastRun('unitsyncPath',$unitsync);
  $conf{unitsyncDir}=canonpath((fileparse($unitsync))[1]);
  $currentStep++;
  $unitsyncDir=$conf{unitsyncDir};
}

sub exportWin32EnvVar {
  my $envVar=shift;
  my $envVarDef="$envVar=".($ENV{$envVar}//'');
  fatalError("Unable to export environment variable definition \"$envVarDef\"") unless(_putenv($envVarDef) == 0);
}

sub uriEscape {
  my $uri=shift;
  $uri =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/eg;
  return $uri;
}

sub naiveParentDir {
  my @dirs=splitdir(shift);
  pop(@dirs);
  return catdir(@dirs);
}

sub configureSpringDataDir {
  my ($baseDataDir,$mapModDataDir);
  if(exists $conf{autoInstalledSpringDir}) {
    $baseDataDir=$conf{autoInstalledSpringDir};
  }else{
    my @potentialBaseDataDirs=($unitsyncDir);
    if(! $win) {
      my $parentUnitsyncDir=naiveParentDir($unitsyncDir);
      push(@potentialBaseDataDirs,canonpath("$parentUnitsyncDir/share/games/spring"));
      push(@potentialBaseDataDirs,'/usr/share/games/spring') unless($macOs);
    }
    my $defaultBaseDataDir;
    foreach my $potentialBaseDataDir (@potentialBaseDataDirs) {
      if(-d "$potentialBaseDataDir/base") {
        $defaultBaseDataDir=$potentialBaseDataDir;
        last;
      }
    }
    $baseDataDir=promptExistingDir("[$currentStep/$nbSteps] Please enter the absolute path of the main Spring data directory, containing Spring base content".($win?' (usually the Spring installation directory on Windows systems)':''),
                                   $defaultBaseDataDir,
                                   undef,
                                   sub {my $dir=shift; return -d "$dir/base";},
                                   $autoInstallData{baseDataDir} );
    setLastRun('baseDataDir',$baseDataDir);
    $currentStep++;
  }

  my @potentialMapModDataDirs;
  if($win) {
    my $win32PersonalDir=Win32::GetFolderPath(Win32::CSIDL_PERSONAL());
    my $win32CommonAppDataDir=Win32::GetFolderPath(Win32::CSIDL_COMMON_APPDATA());
    push(@potentialMapModDataDirs,
         catdir($win32PersonalDir,'My Games','Spring'),
         catdir($win32PersonalDir,'Spring'),
         catdir($win32CommonAppDataDir,'Spring'));
  }else{
    push(@potentialMapModDataDirs,catdir($ENV{HOME},'.spring'),catdir($ENV{HOME},'.config','spring')) if(defined $ENV{HOME});
    push(@potentialMapModDataDirs,catdir($ENV{XDG_CONFIG_HOME},'spring')) if(defined $ENV{XDG_CONFIG_HOME});
  }
  my $defaultMapModDataDir=exists $conf{autoInstalledSpringDir}?'new':'none';
  foreach my $potentialMapModDataDir (@potentialMapModDataDirs) {
    if((! areSamePaths($potentialMapModDataDir,$baseDataDir))
       && (! -d "$potentialMapModDataDir/base")
       && (any {-d "$potentialMapModDataDir/$_"} (qw'games maps packages'))) {
      $defaultMapModDataDir=$potentialMapModDataDir;
      last;
    }
  }
  if(exists $conf{autoInstalledSpringDir}) {
    $mapModDataDir=promptExistingDir("[$currentStep/$nbSteps] Please enter the absolute path of the Spring data directory containing the games and maps that will be hosted by the autohost, or ".($defaultMapModDataDir eq 'new' ? 'press enter' : 'enter "new"').' to initialize a new directory instead',
                                     $defaultMapModDataDir,
                                     'new',
                                     undef,
                                     $autoInstallData{mapModDataDir});
    setLastRun('mapModDataDir',$mapModDataDir);
    $currentStep++;
    if($mapModDataDir eq 'new') {
      $mapModDataDir=catdir($conf{absoluteVarDir},'spring','data');
      my $gamesDir=catdir($mapModDataDir,'games');
      my $mapsDir=catdir($mapModDataDir,'maps');
      slog('Retrieving the list of games available for download...',3);
      my %games=(ba => ['Balanced Annihilation','http://packages.springrts.com/builds/'],
                 'ba(new)' => ['Balanced Annihilation'],
                 bac => ['BA Chicken Defense','http://packages.springrts.com/builds/'],
                 evo => ['Evolution RTS'],
                 jauria => ['Jauria RTS'],
                 metalfactions => ['Metal Factions'],
                 nota => ['NOTA','http://host.notaspace.com/downloads/games/nota/',''],
                 phoenix => ['Phoenix Annihilation'],
                 s44 => ['Spring: 1944'],
                 swiw => ['Imperial Winter'],
                 tard => ['Robot Defense'],
                 tc => ['The Cursed'],
                 techa => ['Tech Annihilation'],
                 xta => ['XTA'],
                 zk => ['Zero-K']);
      my $prdPath=catfile($conf{autoInstalledSpringDir},$PRD_BIN);
      if(-f $prdPath && -x _) {
        $games{'techa(test)'}=['Tech Annihilation','rapid://techa:test'];
        $games{bar}=['Beyond All Reason','rapid://byar:test'];
      }
      my %gamesData;
      foreach my $shortName (sort keys %games) {
        my ($name,$repoUrl,$separator)=@{$games{$shortName}};
        if(defined $repoUrl && substr($repoUrl,0,8) eq 'rapid://') {
          my $rapidTag=substr($repoUrl,8);
          $gamesData{$shortName}={name => "$name [$rapidTag]", rapid => $rapidTag};
        }else{
          my $shortNameInfra=$shortName;
          $shortNameInfra=~s/\(.+\)$//;
          $repoUrl//="http://repos.springrts.com/$shortNameInfra/builds/";
          $separator//='-';
          my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$repoUrl.'?C=M;O=A');
          my @gameArchives;
          @gameArchives=$httpRes->{content} =~ /href="$shortNameInfra$separator[^"]+\.sdz">($shortNameInfra$separator[^<]+\.sdz)</g if($httpRes->{success});
          if(! @gameArchives) {
            slog("Unable to retrieve archives list for game $name",2);
            next;
          }
          my $latestGameArchive=pop(@gameArchives);
          my $gameVersion;
          if($latestGameArchive =~ /^$shortNameInfra$separator\s*(.+)\.sdz$/) {
            $gameVersion=$1;
          }else{
            slog("Unable to retrieve latest archive name for game $name",2);
            next;
          }
          $gamesData{$shortName}={name => "$name $gameVersion", url => $repoUrl.uriEscape($latestGameArchive), file => $latestGameArchive};
        }
      }
      createDir($gamesDir);
      print "\nDirectory \"$gamesDir\" has been created to store the games used by the autohost.\n";
      if(%gamesData) {
        print "You can download one of the following games in this directory automatically by entering the corresponding game abbreviation, or you can choose to manually place some game archives there and enter \"none\" when finished:\n";
        my $defaultShortName;
        foreach my $shortName (sort keys %gamesData) {
          $defaultShortName//=$shortName;
          $defaultShortName=$shortName if($shortName eq 'bar' && $isBarEngine);
          print "  $shortName : $gamesData{$shortName}{name}\n";
        }
        print "\n";
        my $downloadedShortName=promptChoice("[$currentStep/$nbSteps] Which game do you want to download to initialize the autohost \"games\" directory",[(sort keys %gamesData),'none'],$defaultShortName,$autoInstallData{downloadedGameShortName});
        setLastRun('downloadedGameShortName',$downloadedShortName);
        $currentStep++;
        if(exists $gamesData{$downloadedShortName}) {
          slog("Downloading $gamesData{$downloadedShortName}{name}...",3);
          if(exists $gamesData{$downloadedShortName}{rapid}) {
            open(my $previousStdout,'>&',\*STDOUT);
            open(STDOUT,'>',devnull());
            my ($rc,$errMsg)=portableSystem($prdPath,'--disable-logging','--filesystem-writepath',$mapModDataDir,'--download-game',$gamesData{$downloadedShortName}{rapid});
            open(STDOUT,'>&',$previousStdout);
            fatalError('Error when calling pr-downloader - '.$errMsg)
                unless(defined $rc);
            slog("pr-downloader exited with return value $rc",2) if($rc);
          }else{
            if(downloadFile($gamesData{$downloadedShortName}{url},catfile($gamesDir,$gamesData{$downloadedShortName}{file}))) {
              slog("File $gamesData{$downloadedShortName}{file} downloaded.",3);
            }else{
              slog("Unable to download file \"$gamesData{$downloadedShortName}{url}\"",2);
            }
          }
        }
      }else{
        $nbSteps--;
        print "Now you can manually place some games archives there, then press enter when finished.\n";
        <STDIN>;
        print "\n" unless($isInteractive);
      }
      createDir($mapsDir);
      print "\nDirectory \"$mapsDir\" has been created to store the maps used by the autohost.\n";
      my @allBarMaps;
      if(SpadsUpdater::checkHttpsSupport()) {
        my $httpTiny=HTTP::Tiny->new(timeout => 10);
        my $httpRes=$httpTiny->get('https://maps-metadata.beyondallreason.dev/latest/live_maps.validated.json');
        if($httpRes->{success}) {
          my $r_jsonBarMapList = eval { decode_json($httpRes->{content}) };
          if(defined $r_jsonBarMapList) {
            if(ref $r_jsonBarMapList eq 'ARRAY') {
              foreach my $r_jsonBarMapData (@{$r_jsonBarMapList}) {
                next unless(ref $r_jsonBarMapData eq 'HASH' && defined $r_jsonBarMapData->{springName} && ref $r_jsonBarMapData->{springName} eq '');
                if(defined $r_jsonBarMapData->{downloadURL} && ref $r_jsonBarMapData->{downloadURL} eq '') {
                  push(@allBarMaps,[@{$r_jsonBarMapData}{qw'springName downloadURL'}]);
                }else{
                  push(@allBarMaps,$r_jsonBarMapData->{springName});
                }
              }
            }
            slog('Failed to parse the list of Beyond All Reason maps with links (unknown JSON structure), trying fallback method...',2)
                unless(@allBarMaps);
          }else{
            slog('Failed to parse the list of Beyond All Reason maps with links (invalid JSON data), trying fallback method...',2);
          }
        }else{
          slog('Failed to retrieve the list of Beyond All Reason maps with links ('.getHttpErrMsg($httpRes).'), trying fallback method...',2);
        }
        if(! @allBarMaps) {
          $httpRes=$httpTiny->get('https://raw.githubusercontent.com/beyond-all-reason/BYAR-Chobby/master/LuaMenu/configs/gameConfig/byar/mapDetails.lua');
          if($httpRes->{success}) {
            my %dedupMaps;
            map {$dedupMaps{$_}=1} ($httpRes->{content} =~ /^\[\'([^\']+)\'\]\=\{/mg);
            @allBarMaps = sort keys %dedupMaps;
            slog('Failed to retrieve the list of Beyond All Reason maps (unable to find map names in LUA structure)',2)
                unless(@allBarMaps);
          }else{
            slog('Failed to retrieve the list of Beyond All Reason maps ('.getHttpErrMsg($httpRes).')',2)
          }
        }
      }else{
        slog("Unable to retrieve Beyond All Reason map lists because TLS support is missing (IO::Socket::SSL version 1.42 or superior and Net::SSLeay version 1.49 or superior are required)",2);
      }
      my @availableMapSets=('minimal');
      print "You can download a set of maps in this directory automatically by entering the corresponding name, or you can choose to manually place some map archives there and enter \"none\" when finished:\n";
      print "  minimal  : minimal set of 3 basic maps (\"Red Comet\", \"Comet Catcher Redux\" and \"Delta Siege Dry\")\n";
      if(@allBarMaps) {
        print '  bar      : all Beyond All Reason maps ('.(scalar @allBarMaps)." maps)\n";
        push(@availableMapSets,'bar');
      }
      print "  none     : no automatic map download (map archives must be placed manually in \"$mapsDir\")\n";
      print "\n";
      push(@availableMapSets,'none');
      my $defaultMapSet = ($isBarEngine && @allBarMaps) ? 'bar' : 'minimal';
      my $autoDownloadMaps=promptChoice("[$currentStep/$nbSteps] Which map set do you want to download to initialize the autohost \"maps\" directory",\@availableMapSets,$defaultMapSet,$autoInstallData{autoDownloadMaps});
      setLastRun('autoDownloadMaps',$autoDownloadMaps);
      $currentStep++;
      if($autoDownloadMaps eq 'bar') {
        slog('Downloading maps...',3);
        ###  pr-downloader already has too different behaviors between Spring and Recoil...
        # downloadMapsUsingPrdWithProgressBar($prdPath,$mapModDataDir,\@allBarMapNames);
        downloadMapsFromUrlOrNameWithProgressBar(\@allBarMaps,$mapsDir);
      }elsif($autoDownloadMaps eq 'minimal') {
        slog('Downloading maps...',3);
        my @mapUrls=map {'http://planetspads.free.fr/spring/maps/'.$_} (qw'comet_catcher_redux.sd7 deltasiegedry.sd7 red_comet.sd7');
        downloadMapsWithProgressBar(\@mapUrls,$mapsDir);
      }
    }else{
      $nbSteps-=2;
    }
  }else{
    $mapModDataDir=promptExistingDir("[$currentStep/$nbSteps] Please enter the absolute path of an optional ".($win?'':'secondary ')."Spring data directory containing additional games and maps (".($defaultMapModDataDir eq 'none' ? 'press enter' : 'enter "none"').' to skip)',
                                     $defaultMapModDataDir,
                                     'none',
                                     undef,
                                     $autoInstallData{mapModDataDir});
    setLastRun('mapModDataDir',$mapModDataDir);
    $currentStep++;
  }

  my @springDataDirs=($baseDataDir);
  push(@springDataDirs,$mapModDataDir) unless($mapModDataDir eq 'none');
  if(exists $conf{autoInstalledSpringDir}) {
    $conf{springDataDir}=$mapModDataDir;
  }else{
    $conf{springDataDir}=join($pathSep,@springDataDirs);
  }

  setEnvVarFirstPaths('SPRING_DATADIR',@springDataDirs);
  $ENV{SPRING_WRITEDIR}=$conf{absoluteVarDir};
  if($win) {
    fatalError('Unable to import _putenv from msvcrt.dll ('.Win32::FormatMessage(Win32::GetLastError()).')')
        unless(Win32::API->Import('msvcrt', 'int __cdecl _putenv (char* envstring)'));
    exportWin32EnvVar('SPRING_DATADIR');
    exportWin32EnvVar('SPRING_WRITEDIR');
  }
}

sub checkUnitsync {
  my $cwd=cwd();

  slog('Loading Perl Unitsync interface module...',3);

  eval {require PerlUnitSync};
  fatalError("Unable to load Perl UnitSync interface module ($@)") if ($@);

  my $unitsync = eval {PerlUnitSync->new($unitsyncDir)};
  fatalError($@) if ($@);
  fatalError("Failed to load unitsync library from \"$unitsyncDir\" - unknown error") unless(defined $unitsync);

  slog('Initializing Unitsync library...',3);
  if(! $unitsync->Init(0,0)) {
    while(my $unitSyncErr=$unitsync->GetNextError()) {
      chomp($unitSyncErr);
      slog("UnitSync error: $unitSyncErr",1);
    }
    fatalError('Unable to initialize UnitSync library');
  }

  my $unitsyncVersion=$unitsync->GetSpringVersion();
  slog("Unitsync library version $unitsyncVersion initialized.",3);

  my @availableMods;
  my $nbMods = $unitsync->GetPrimaryModCount();
  for my $modNb (0..($nbMods-1)) {
    my $nbInfo = $unitsync->GetPrimaryModInfoCount($modNb);
    my $modName='';
    for my $infoNb (0..($nbInfo-1)) {
      next if($unitsync->GetInfoKey($infoNb) ne 'name');
      $modName=$unitsync->GetInfoValueString($infoNb);
      last;
    }
    if($modName eq '') {
      slog("Unable to find mod name for mod \#$modNb",1);
      next;
    }
    push(@availableMods,$modName);
  }

  $unitsync->UnInit();
  chdir($cwd);
  return \@availableMods;
}

sub ghAssetTemplateToRegex {
  my $assetTmpl=shift;
  return undef if(index($assetTmpl,',') != -1);
  my $osString = $win ? 'windows' : $macOs ? 'macos' : 'linux';
  my $bitnessString = $Config{ptrsize} > 4 ? 64 : 32;
  $assetTmpl=~s/\Q<os>\E/$osString/g;
  $assetTmpl=~s/\Q<bitness>\E/$bitnessString/g;
  return $assetTmpl if(eval { qw/^$assetTmpl$/ } && ! $@);
  return undef;
}

if(! exists $conf{release}) {
  print "\nThis program will install SPADS in the current working directory, overwriting files if needed.\n";
  print "The installer will ask you $nbSteps questions maximum to customize your installation and pre-configure SPADS.\n";
  print "You can stop this installation at any time by hitting Ctrl-c.\n";
  print "Note: if SPADS is already installed on the system, you don't need to reinstall it to run multiple autohosts. Instead, you can share SPADS binaries and use multiple configuration files and/or configuration macros.\n\n";

  $conf{release}=promptChoice("[1/$nbSteps] Which SPADS release do you want to install",[qw'stable testing unstable contrib'],'testing',$autoInstallData{release});
}
setLastRun('release',$conf{release});

my $updaterLog=SimpleLog->new(logFiles => [''],
                              logLevels => [4],
                              useANSICodes => [-t STDOUT ? 1 : 0],
                              useTimestamps => [-t STDOUT ? 0 : 1],
                              prefix => '[SpadsUpdater] ');

my $updater=SpadsUpdater->new(sLog => $updaterLog,
                              localDir => $conf{installDir},
                              repository => "$URL_SPADS/repository",
                              release => $conf{release},
                              packages => \@packages);

my $updaterRc=$updater->update();
fatalError('Unable to retrieve SPADS packages') if($updaterRc < 0);
if($updaterRc > 0) {
  my @restartCmd=($0);
  push(@restartCmd,$conf{release}) unless(! $releaseIsFromCmdLineParam
                                          && defined $autoInstallData{release}
                                          && ($autoInstallData{release} eq $conf{release} || $autoInstallData{release} eq ''));
  push(@restartCmd,'--auto',$templateName//$templateUrl) if(defined $templateUrl);
  if($win) {
    @restartCmd=map {escapeWin32Parameter($_)} @restartCmd;
    print "\nSPADS installer has been updated, it must now be restarted as follows:\n  perl ".join(' ',@restartCmd)."\n";
    exit 0;
  }
  slog('Restarting installer after update...',3);
  sleep(2);
  portableExec($^X,@restartCmd);
  fatalError('Unable to restart installer');
}
slog('SPADS components are up to date, proceeding with installation...',3);

if(! $sslAvailable) {
  slog('Perl module not found: IO::Socket::SSL',2);
  slog('--> this module is needed by SPADS for TLS encryption, which is required to host games on official Spring lobby server',2);
  slog('--> if you plan to use SPADS on official Spring lobby server, it is recommended to hit Ctrl-C now to abort SPADS installation and install the "IO::Socket::SSL" Perl module',2);
}

if($sqliteUnavailableReason) {
  slog('Cannot use SQLite, '.$sqliteUnavailableReason,2);
  slog('--> SQLite is an OPTIONAL dependency: SPADS can run without SQLite but in this case players preferences data cannot be shared between multiple SPADS instances',2);
  slog('--> if you plan to run multiple SPADS instances and want to share players preferences data between instances, you can hit Ctrl-C now to abort SPADS installation and fix the problem',2);
}

$conf{absoluteEtcDir}=promptDir("[2/$nbSteps] Please choose the directory where SPADS configuration files will be stored",'etcDir','etc');
$conf{absoluteTemplatesDir}=catdir($conf{absoluteEtcDir},'templates');
createDir($conf{absoluteTemplatesDir});

$conf{absoluteVarDir}=promptDir("[3/$nbSteps] Please choose the directory where SPADS dynamic data will be stored",'varDir','var');
createDir(catdir($conf{absoluteVarDir},'plugins'));
createDir(catdir($conf{absoluteVarDir},'spring'));
$updater->{springDir}=catdir($conf{absoluteVarDir},'spring');

$conf{absoluteLogDir}=promptDir("[4/$nbSteps] Please choose the directory where SPADS will write the logs",'logDir','log',$conf{absoluteVarDir});
createDir(catdir($conf{absoluteLogDir},'chat'));

my $engineBinariesType;
if($macOs) {
  $engineBinariesType='custom';
}else{
  my ($githubDescStr,@engineBinChoices);
  if(SpadsUpdater::checkHttpsSupport()) {
    $githubDescStr=' engine binaries from GitHub (auto-managed by SPADS),';
    @engineBinChoices=(qw'official github custom');
  }else{
    slog("Engine auto-management using GitHub is unavailable because TLS support is missing (IO::Socket::SSL version 1.42 or superior and Net::SSLeay version 1.49 or superior are required)",2);
    $githubDescStr='';
    @engineBinChoices=(qw'official custom');
  }
  $engineBinariesType=promptChoice("[5/$nbSteps] Do you want to use official Spring binary files (auto-managed by SPADS),$githubDescStr or a custom engine installation already existing on the system?",\@engineBinChoices,'official',$autoInstallData{springBinariesType});
  setLastRun('springBinariesType',$engineBinariesType);
}

if($engineBinariesType eq 'official') {
  
  slog('Checking available Spring versions...',3);
  
  my @engineBranches=(qw'develop master');
  my %engineBranchesVersions;
  map { my $r_availableSpringVersions=$updater->getAvailableSpringVersions($_);
        fatalError("Couldn't check available Spring versions") unless(@{$r_availableSpringVersions} || $_ eq 'develop');
        $engineBranchesVersions{$_}=$r_availableSpringVersions; } @engineBranches;

  my (%engineReleasesVersion,%engineVersionsReleases);
  map { my $releaseVersion=$updater->resolveEngineReleaseNameToVersion($_);
        if(defined $releaseVersion) {
          $engineReleasesVersion{$_}=$releaseVersion;
          $engineVersionsReleases{$releaseVersion}{$_}=1;
        } } (keys %ENGINE_RELEASES);

  print "\nAvailable Spring versions:\n";
  
  my %availableVersions=%engineReleasesVersion;
  foreach my $engineBranch (@engineBranches) {
    my $versionsToAdd=5;
    for my $idx (1..@{$engineBranchesVersions{$engineBranch}}) {
      my ($printedVersion,$versionComment)=($engineBranchesVersions{$engineBranch}[-$idx],'');
      $availableVersions{$printedVersion}=1;
      if(exists $engineVersionsReleases{$printedVersion}) {
        $versionComment=' '.join(' + ', map { '['.uc($_)."] ($ENGINE_RELEASES{$_})" } (sort keys %{$engineVersionsReleases{$printedVersion}}));
        $versionsToAdd=5;
      }
      if($versionsToAdd >= 0) {
        if($versionsToAdd > 0) {
          print "  $printedVersion$versionComment\n";
        }else{
          print "  [...]\n";
        }
        $versionsToAdd--;
      }
    }
  }
  
  print "\nPlease choose the Spring version which will be used by the autohost.\n";
  print "If you choose \"stable\", \"testing\" or \"unstable\", SPADS will stay up to date with the corresponding Spring release by automatically downloading and using new binary files when needed.\n";
  my @engineVersionExamples;
  push(@engineVersionExamples,$engineReleasesVersion{stable}) if(defined $engineReleasesVersion{stable});
  push(@engineVersionExamples,$engineReleasesVersion{testing}) if(defined $engineReleasesVersion{testing} && (none {$engineReleasesVersion{testing} eq $_} @engineVersionExamples));
  push(@engineVersionExamples,$engineReleasesVersion{unstable}) if(defined $engineReleasesVersion{unstable} && (none {$engineReleasesVersion{unstable} eq $_} @engineVersionExamples));
  push(@engineVersionExamples,$engineBranchesVersions{master}[-1]) unless(@engineVersionExamples);
  print "If you choose a specific Spring version number (\"".join('", "',@engineVersionExamples)."\", ...), SPADS will stick to this version until you manually change it in the configuration file.\n\n";
  my $engineVersion;
  my $autoInstallValue=$autoInstallData{autoManagedSpringVersion};
  my $autoManagedSpringVersion='';
  while(! exists $availableVersions{$autoManagedSpringVersion}) {
    $autoManagedSpringVersion=promptStdin("[6/$nbSteps] Which Spring version do you want to use (".(join(',',@engineVersionExamples,(sort grep {defined $engineReleasesVersion{$_}} keys %ENGINE_RELEASES),'...')).')',$engineVersionExamples[0],$autoInstallValue);
    $autoInstallValue=undef;
    if(exists $availableVersions{$autoManagedSpringVersion}) {
      $engineVersion=$engineReleasesVersion{$autoManagedSpringVersion} // $autoManagedSpringVersion;
      my $engineSetupRes=$updater->setupEngine($engineVersion,undef,1);
      if($engineSetupRes < -9) {
        slog("Installation failed: unable to find, download and extract all required files for Spring $engineVersion, please choose a different version",2);
        $autoManagedSpringVersion='';
        next;
      }
      fatalError("Spring installation failed: internal error (you can use a custom Spring installation as a workaround if you don't know how to fix this issue)") if($engineSetupRes < 0);
      slog("Spring $engineVersion is already installed",3) if($engineSetupRes == 0);
    }
  }
  setLastRun('autoManagedSpringVersion',$autoManagedSpringVersion);
  $conf{autoManagedSpringVersion}=$autoManagedSpringVersion;
  $conf{autoInstalledSpringDir}=$updater->getEngineDir($engineVersion);
  
}elsif($engineBinariesType eq 'github') {
  
  my %ghInfo;
  $ghInfo{owner}=promptString('       Please enter the GitHub repository owner name','beyond-all-reason',$autoInstallData{githubOwner},sub {$_[0]=~/^[\w\-]+$/});
  setLastRun('githubOwner',$ghInfo{owner});
  $isBarEngine=1 if($ghInfo{owner} eq 'beyond-all-reason');
  $ghInfo{name}=promptString('       Please enter the GitHub repository name','spring',$autoInstallData{githubName},sub {$_[0]=~/^[\w\-\.]+$/});
  setLastRun('githubName',$ghInfo{name});
  $ghInfo{tag}=promptString('       Please enter the GitHub release tag template','spring_bar_{BAR105}<version>',$autoInstallData{githubTag}, sub {index($_[0],'<version>') != -1 && index($_[0],',') == -1});
  setLastRun('githubTag',$ghInfo{tag});
  my $ghAsset=promptString('       Please enter the GitHub asset regular expression','.+_<os>-<bitness>-minimal-portable\.7z',$autoInstallData{githubAsset},\&ghAssetTemplateToRegex);
  setLastRun('githubAsset',$ghAsset);
  $ghInfo{asset}=ghAssetTemplateToRegex($ghAsset);
  my $ghRepoHash=substr(md5_base64(join('/',@ghInfo{qw'owner name'})),0,7);
  $ghRepoHash=~tr/\/\+/ab/;
  my $ghSubdir=$ghInfo{tag};
  $ghSubdir =~ s/\Q<version>\E/($ghRepoHash)/g;
  $ghSubdir =~ tr/\\\/\:\*\?\"\<\>\|/........./;
  $ghInfo{subdir}=$ghSubdir;

  slog('Checking available engine versions...',3);

  my @latestEngineVersions;
  {
    my $r_engineVersions=$updater->getAvailableEngineVersionsFromGithub(\%ghInfo,0,10);
    @latestEngineVersions=@{$r_engineVersions};
    $r_engineVersions=$updater->getAvailableEngineVersionsFromGithub(\%ghInfo,1,20);
    foreach my $taggedVersion (@{$r_engineVersions}) {
      push(@latestEngineVersions,$taggedVersion) if(none {$taggedVersion eq $_} @latestEngineVersions);
    }
  }
  fatalError("Couldn't check available engine versions") unless(@latestEngineVersions);

  my (%engineReleasesVersion,%engineVersionsReleases);
  map { my $releaseVersion=$updater->resolveEngineReleaseNameToVersion($_,\%ghInfo);
        if(defined $releaseVersion) {
          $engineReleasesVersion{$_}=$releaseVersion;
          $engineVersionsReleases{$releaseVersion}{$_}=1;
        } } (keys %ENGINE_RELEASES);

  print "\nAvailable engine versions:\n";

  my @availableEngineReleases=sort grep {defined $engineReleasesVersion{$_}} keys %ENGINE_RELEASES;
  {
    my $versionsToAdd=5;
    my %engineReleasesToPrint = map {$_ => 1} @availableEngineReleases;
    for my $idx (0..$#latestEngineVersions) {
      my ($printedVersion,$versionComment)=($latestEngineVersions[$idx],'');
      if(exists $engineVersionsReleases{$printedVersion}) {
        my @matchingEngineReleases=sort keys %{$engineVersionsReleases{$printedVersion}};
        delete @engineReleasesToPrint{@matchingEngineReleases};
        $versionComment=' '.join(' + ', map { '['.uc($_)."] ($ENGINE_RELEASES{$_})" } @matchingEngineReleases);
        $versionsToAdd=5;
      }
      if($versionsToAdd >= 0) {
        if($versionsToAdd > 0) {
          print "  $printedVersion$versionComment\n";
        }else{
          print "  [...]\n";
        }
        $versionsToAdd--;
      }
    }
    while(%engineReleasesToPrint) {
      my $printedVersion=$engineReleasesVersion{(sort {$b cmp $a} keys %engineReleasesToPrint)[0]};
      my @matchingEngineReleases=sort keys %{$engineVersionsReleases{$printedVersion}};
      delete @engineReleasesToPrint{@matchingEngineReleases};
      my $versionComment=' '.join(' + ', map { '['.uc($_)."] ($ENGINE_RELEASES{$_})" } @matchingEngineReleases);
      print "  $printedVersion$versionComment\n  [...]\n";
    }
  }
  
  print "\nPlease choose the engine version which will be used by the autohost.\n";
  print "If you choose \"stable\", \"testing\" or \"unstable\", SPADS will stay up to date with the corresponding engine release by automatically downloading and using new binary files when needed.\n";
  my @engineVersionExamples;
  push(@engineVersionExamples,$engineReleasesVersion{stable}) if(defined $engineReleasesVersion{stable});
  push(@engineVersionExamples,$engineReleasesVersion{testing}) if(defined $engineReleasesVersion{testing} && (none {$engineReleasesVersion{testing} eq $_} @engineVersionExamples));
  push(@engineVersionExamples,$engineReleasesVersion{unstable}) if(defined $engineReleasesVersion{unstable} && (none {$engineReleasesVersion{unstable} eq $_} @engineVersionExamples));
  push(@engineVersionExamples,$latestEngineVersions[0]) unless(@engineVersionExamples);
  print "If you choose a specific engine version number (\"".join('", "',@engineVersionExamples)."\", ...), SPADS will stick to this version until you manually change it in the configuration file.\n\n";
  my $engineVersion;
  my $autoInstallValue=$autoInstallData{autoManagedSpringVersion};
  my $autoManagedSpringVersion='';
  while(1) {
    $autoManagedSpringVersion=promptStdin("[6/$nbSteps] Which engine version do you want to use (".(join(',',@engineVersionExamples,@availableEngineReleases,'...')).')',$engineVersionExamples[0],$autoInstallValue);
    $autoInstallValue=undef;
    $engineVersion=$engineReleasesVersion{$autoManagedSpringVersion} // $autoManagedSpringVersion;
    if($engineVersion !~ /^\d/) {
      slog("Invalid engine version \"$engineVersion\"",2);
      $autoManagedSpringVersion='';
      next;
    }
    my $engineSetupRes=$updater->setupEngine($engineVersion,\%ghInfo,1);
    if($engineSetupRes < -9) {
      slog("Installation failed: unable to find, download and extract all required files for engine $engineVersion, please choose a different version",2);
      $autoManagedSpringVersion='';
      next;
    }
    fatalError("Engine installation failed: internal error (you can use a custom engine installation as a workaround if you don't know how to fix this issue)") if($engineSetupRes < 0);
    slog("Engine $engineVersion is already installed",3) if($engineSetupRes == 0);
    last;
  }
  setLastRun('autoManagedSpringVersion',$autoManagedSpringVersion);
  $conf{autoManagedSpringVersion}="[GITHUB]{owner=$ghInfo{owner},name=$ghInfo{name},tag=$ghInfo{tag},asset=$ghAsset}".$autoManagedSpringVersion;
  $conf{autoInstalledSpringDir}=$updater->getEngineDir($engineVersion,\%ghInfo);
  
}else{
  $conf{autoManagedSpringVersion}='';
}

if($macOs) {
  $currentStep=5;
}else{
  $currentStep=$conf{autoManagedSpringVersion}?7:6;
}

configureUnitsyncDir();

configureSpringDataDir();

my $r_availableMods=checkUnitsync();
my @availableMods=sort(@{$r_availableMods});

my $springServerType=promptChoice("[$currentStep/$nbSteps] Which type of server do you want to use (\"headless\" requires much more CPU/memory and doesn't support \"ghost maps\", but it allows running AI bots and LUA scripts on server side)?",
                                  [qw'dedicated headless'],
                                  'dedicated',
                                  $autoInstallData{springServerType});
setLastRun('springServerType',$springServerType);
$conf{springServerType} = exists $conf{autoInstalledSpringDir} ? $springServerType : '';
$currentStep++;

if(exists $conf{autoInstalledSpringDir}) {
  $conf{springServer}='';
}else{
  my $springServerName=$win?"spring-$springServerType.exe":"spring-$springServerType";

  my @potentialSpringServerDirs=($unitsyncDir);
  if(! $win) {
    my $parentUnitsyncDir=naiveParentDir($unitsyncDir);
    push(@potentialSpringServerDirs,canonpath("$parentUnitsyncDir/bin"));
    push(@potentialSpringServerDirs,'/usr/games') unless($macOs);
  }
  my $defaultSpringServerPath;
  foreach my $potentialSpringServerDir (@potentialSpringServerDirs) {
    if(-f "$potentialSpringServerDir/$springServerName") {
      $defaultSpringServerPath=catfile($potentialSpringServerDir,$springServerName);
      last;
    }
  }

  $conf{springServer}=promptExistingFile("[$currentStep/$nbSteps] Please enter the absolute path of the spring $springServerType server",$springServerName,$defaultSpringServerPath,$autoInstallData{springServer});
  setLastRun('springServer',$conf{springServer});
  $currentStep++;
}

$conf{modName}='_NO_GAME_FOUND_';
if(defined $autoInstallData{modName}) {
  $conf{modName}=$autoInstallData{modName};
  slog("Default hosted game set to \"$conf{modName}\" from auto-install data",3);
  $nbSteps-=2;
}else{
  if(! @availableMods) {
    slog("No Spring game found, consequently the \"modName\" parameter in \"hostingPresets.conf\" will NOT be auto-configured",2);
    slog('Hit Ctrl-C now if you want to abort this installation to fix the problem, or remember that you will have to set the default hosted game manually later',2);
    $nbSteps-=2;
  }else{
    my $chosenModNb='';
    if($#availableMods == 0) {
      $chosenModNb=0;
      $nbSteps--;
    }else{
      print "\nAvailable games in your \"games\" and \"packages\" folders:\n";
      foreach my $modNb (0..$#availableMods) {
        print "  $modNb --> $availableMods[$modNb]\n";
      }
      print "\n";
      while($chosenModNb !~ /^\d+$/ || $chosenModNb > $#availableMods) {
        print "[$currentStep/$nbSteps] Please choose the default hosted game ? ";
        $chosenModNb=<STDIN>;
        $chosenModNb//='';
        chomp($chosenModNb);
      }
      $currentStep++;
    }
    $conf{modName}=$availableMods[$chosenModNb];

    my $modFilter;
    if($conf{modName} =~ /^(.+ )test\-\d+\-[\da-f]+$/) {
      $modFilter=quotemeta($1).'test\-\d+\-[\da-f]+';
    }else{
      $modFilter=quotemeta($conf{modName});
      $modFilter =~ s/\d+/\\d+/g;
    }

    my $isLatestMod=1;
    foreach my $availableMod (@availableMods) {
      next if($availableMod eq $conf{modName});
      if($availableMod =~ /^$modFilter$/ && $availableMod gt $conf{modName}) {
        $isLatestMod=0;
        last;
      }
    }

    if($isLatestMod) {
      my $chosenModText=$#availableMods>0?'You chose the latest version of this game currently available in your "games" and "packages" folders. ':'';
      my $useLatestMod=promptChoice("[$currentStep/$nbSteps] ${chosenModText}Do you want to enable new game auto-detection to always host the latest version of the game available in your \"games\" and \"packages\" folders?",[qw'yes no'],'yes');
      $currentStep++;
      if($useLatestMod eq 'yes') {
        slog("Using following regular expression as autohost default game filter: \"$modFilter\"",3);
        $modFilter='~'.$modFilter;
        $conf{modName}=$modFilter;
      }else{
        slog("Using \"$conf{modName}\" as default hosted game",3);
      }
    }else{
      $nbSteps--;
      slog("Using \"$conf{modName}\" as default hosted game",3);
    }
  }
}
setLastRun('modName',$conf{modName});

$conf{lobbyLogin}=promptString("[$currentStep/$nbSteps] Please enter the autohost lobby login (the lobby account must already exist)",undef,$autoInstallData{lobbyLogin});
setLastRun('lobbyLogin',$conf{lobbyLogin});
$currentStep++;
$conf{lobbyPassword}=promptString("[$currentStep/$nbSteps] Please enter the autohost lobby password",undef,$autoInstallData{lobbyPassword});
setLastRun('lobbyPassword',$conf{lobbyPassword});
$currentStep++;
$conf{owner}=promptString("[$currentStep/$nbSteps] Please enter the lobby login of the autohost owner",undef,$autoInstallData{owner});
setLastRun('owner',$conf{owner});
$currentStep++;

$conf{preferencesData}=$sqliteUnavailableReason?'private':'shared';

my @confFiles=qw'banLists.conf battlePresets.conf commands.conf hostingPresets.conf levels.conf mapBoxes.conf mapLists.conf spads.conf users.conf';
slog('Downloading SPADS configuration templates',3);
exit 1 unless(all {downloadFile("$URL_SPADS/conf/templates/$conf{release}/$_",catdir($conf{etcDir},'templates',$_))} @confFiles);
slog('Customizing SPADS configuration',3);
foreach my $confFile (@confFiles) {
  my $confFileTemplate=catfile($conf{etcDir},'templates',$confFile);
  fatalError("Unable to read configuration template \"$confFileTemplate\"") unless(open(TEMPLATE,"<$confFileTemplate"));
  my $confFilePath=catfile($conf{etcDir},$confFile);
  fatalError("Unable to write configuration file \"$confFilePath\"") unless(open(CONF,">$confFilePath"));
  while(<TEMPLATE>) {
    foreach my $macroName (keys %conf) {
      s/\%$macroName\%/$conf{$macroName}/g;
    }
    print CONF $_;
  }
  close(CONF);
  close(TEMPLATE);
}

my $lastRunFile=catfile($conf{installDir},'spadsInstaller.lastRun');
if(open(my $lastRunFh,'>',$lastRunFile)) {
  map {print $lastRunFh "$_:$lastRun{$_}\n"} @lastRunOrder;
  close($lastRunFh);
}else{
  slog("Failed to save install parameters in \"last run\" file \"$lastRunFile\": $!",2);
}

print "\nSPADS has been installed in current directory with default configuration and minimal customization.\n";
print "You can check your configuration files in \"$conf{etcDir}\" and update them if needed.\n";
print "You can then launch SPADS with \"perl spads.pl ".catfile($conf{etcDir},'spads.conf')."\"\n";
