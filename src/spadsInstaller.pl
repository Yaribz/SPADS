#!/usr/bin/perl -w
#
# This program installs SPADS in current directory from remote repository.
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

# Version 0.17a (2015/07/07)

use strict;

use Cwd;
use File::Basename 'fileparse';
use File::Copy;
use File::Path;
use File::Spec;
use HTTP::Tiny;
use List::Util 'first';

use SimpleLog;
use SpadsUpdater;

sub any (&@) { my $c = shift; return defined first {&$c} @_; }
sub all (&@) { my $c = shift; return ! defined first {! &$c} @_; }
sub none (&@) { my $c = shift; return ! defined first {&$c} @_; }
sub notall (&@) { my $c = shift; return defined first {! &$c} @_; }

my $win=$^O eq 'MSWin32';

my @packages=(qw'getDefaultModOptions.pl help.dat helpSettings.dat SpringAutoHostInterface.pm SpringLobbyInterface.pm SimpleEvent.pm SimpleLog.pm spads.pl SpadsConf.pm spadsInstaller.pl SpadsUpdater.pm SpadsPluginApi.pm update.pl argparse.py replay_upload.py',$win?'7za.exe':'7za');
my @packagesWinUnitsync=qw'PerlUnitSync.pm PerlUnitSync.dll';
my @packagesWinServer=qw'spring-dedicated.exe spring-headless.exe';

my $isInteractive=-t STDIN;
my $currentStep=1;
my ($nbSteps,$pathSep,$perlUnitsyncLibName,$defaultUnitsyncDir)=$win?(12,';','PerlUnitSync.dll'):(14,':','PerlUnitSync.so','/lib');
my @pathes=splitPaths($ENV{PATH});
my %conf=(installDir => File::Spec->canonpath(cwd()));

if($win) {
  eval 'use Win32';
  eval 'use Win32::API';
  $conf{updateBin}='yes';
  push(@pathes,cwd());
  push(@packages,@packagesWinUnitsync);
  $defaultUnitsyncDir=File::Spec->catdir(Win32::GetFolderPath(Win32::CSIDL_PROGRAM_FILES()),'Spring');
}else{
  $conf{updateBin}='no';
}

my $sLog=SimpleLog->new(logFiles => [''],
                        logLevels => [4],
                        useANSICodes => [-t STDOUT ? 1 : 0],
                        useTimestamps => [-t STDOUT ? 0 : 1],
                        prefix => '[SpadsInstaller] ');


if(@ARGV) {
  if($#ARGV == 0 && any {$ARGV[0] eq $_} qw'stable testing unstable contrib -g') {
    $conf{release}=$ARGV[0];
  }else{
    $sLog->log('Invalid usage',1);
    print "Usage:\n";
    print "  perl $0 [release]\n";
    print "  perl $0 -g\n";
    print "      release: \"stable\", \"testing\", \"unstable\" or \"contrib\"\n";
    print "      -g: (re)generate unitsync wrapper only\n";
    exit 1;
  }
}

my %prereqFound=(swig => 0, 'g++' => 0);
foreach my $prereq (keys %prereqFound) {
  $prereqFound{$prereq}=1 if(any {-f "$_/$prereq".($win?'.exe':'')} @pathes);
}
if(! $win || (exists $conf{release} && $conf{release} eq '-g')) {
  fatalError("Couldn't find Swig, please install Swig for Perl Unitsync interface module generation") unless($prereqFound{swig});
  fatalError("Couldn't find g++, please install g++ for Perl Unitsync interface module generation") unless($prereqFound{'g++'});
  if($win) {
    fatalError('The PERL5_INCLUDE environment variable must be set to your Perl CORE include directory (for instance: "C:\\Perl\\lib\\CORE")')
        unless(exists $ENV{PERL5_INCLUDE} && -d $ENV{PERL5_INCLUDE});
    fatalError('The PERL5_LIB environment variable must be set to your Perl CORE library absolute path (for instance: "C:\\Perl\\lib\\CORE\\libperl520.a")')
        unless(exists $ENV{PERL5_LIB} && isAbsolutePath($ENV{PERL5_LIB}) && -f $ENV{PERL5_LIB});
    fatalError('The MINGDIR environment variable must be set to your MinGW install directory (for instance: "C:\\mingw")')
        unless(exists $ENV{MINGDIR} && -d "$ENV{MINGDIR}/include");
  }
}

sub fatalError { $sLog->log(shift,0); exit 1; }

sub splitPaths { return split(/$pathSep/,shift//''); }

sub isAbsolutePath {
  my $fileName=shift;
  my $fileSpecRes=File::Spec->file_name_is_absolute($fileName);
  return $fileSpecRes == 2 if($win);
  return $fileSpecRes;
}

sub promptChoice {
  my ($prompt,$p_choices,$default)=@_; 
  my @choices=@{$p_choices};
  my $choicesString=join(',',@choices);
  my $choice='';
  while(none {$choice eq $_} @choices) {
    print "$prompt ($choicesString) [$default] ? ";
    $choice=<STDIN>;
    $choice//='';
    chomp($choice);
    $choice=$default if($choice eq '');
  }
  return $choice;
}

sub promptExistingFile {
  my ($prompt,$fileName,$default)=@_;
  my $choice='';
  my $firstTry=1;
  while(! isAbsoluteFilePath($choice,$fileName)) {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    print "$prompt ($fileName) [$default] ? ";
    $choice=<STDIN>;
    print "\n" unless($isInteractive);
    $choice//='';
    chomp($choice);
    $choice=$default if($choice eq '');
  }
  return isAbsoluteFilePath($choice,$fileName);
}

sub promptExistingDir {
  my ($prompt,$default,$acceptSpecialValue)=@_;
  my $choice='';
  my $firstTry=1;
  while(! isAbsolutePath($choice) || ! -d $choice || index($choice,$pathSep) != -1) {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    print "$prompt [$default] ? ";
    $choice=<STDIN>;
    print "\n" unless($isInteractive);
    $choice//='';
    chomp($choice);
    $choice=$default if($choice eq '');
    last if(defined $acceptSpecialValue && $choice eq $acceptSpecialValue);
  }
  return $choice;
}

sub promptString {
  my $prompt=shift;
  my $choice='';
  while($choice eq '') {
    print "$prompt ? ";
    $choice=<STDIN>;
    $choice//='';
    chomp($choice);
  }
  return $choice;
}

sub isAbsoluteFilePath {
  my ($path,$fileName)=@_;
  return '' unless(isAbsolutePath($path));
  if(! -f $path) {
    $path=File::Spec->catfile($path,$fileName);
    return '' unless(-f $path);
  }
  return '' unless((File::Spec->splitpath($path))[2] eq $fileName);
  return $path;
}

sub createDir {
  my $dir=shift;
  eval { mkpath($dir) };
  fatalError("Couldn't create directory \"$dir\" ($@)") if($@);
  $sLog->log("Directory \"$dir\" created",3);
}

sub downloadFile {
  my ($url,$file)=@_;
  my $httpRes=HTTP::Tiny->new(timeout => 10)->mirror($url,$file);
  if(! $httpRes->{success} || ! -f $file) {
    $sLog->log("Unable to download $file from $url",1);
    unlink($file);
    return 0;
  }
  return 2 if($httpRes->{status} == 304);
  return 1;
}

sub unlinkUnitsyncTmpFiles {
  map {unlink($_)} (qw'unitsync.h unitsync.cpp exportdefines.h maindefines.h PerlUnitSync.i PerlUnitSync_wrap.c PerlUnitSync_wrap.o');
}

sub unlinkUnitsyncModuleFiles {
  map {unlink($_)} ('PerlUnitSync.pm',$perlUnitsyncLibName);
}

my $unitsyncDir;
sub generatePerlUnitSync {
  my $defaultUnitsync='';
  my ($unitsyncLibName,@libPathes)=$win?('unitsync.dll',@pathes):('libunitsync.so',split(/:/,$ENV{LD_LIBRARY_PATH}//''));
  foreach my $libPath (@libPathes,$defaultUnitsyncDir) {
    if(-f "$libPath/$unitsyncLibName") {
      $defaultUnitsync=File::Spec->catfile($libPath,$unitsyncLibName);
      last;
    }
  }
  my $unitsync=promptExistingFile("$currentStep/$nbSteps - Please enter the absolute path of the unitsync library",$unitsyncLibName,$defaultUnitsync);
  $currentStep++;
  $unitsyncDir=File::Spec->canonpath((fileparse($unitsync))[1]);

  $sLog->log('Generating Perl Unitsync interface module',3);
  if(notall {downloadFile("http://planetspads.free.fr/spads/unitsync/src/$_",$_)} (qw'unitsync.h unitsync.cpp exportdefines.h maindefines.h')) {
    unlinkUnitsyncTmpFiles();
    exit 1;
  }
  
  my $exportedFunctions='';
  my $exportedFunctionsFixed='';
  my $usSrc='unitsync.cpp';
  if(-f $usSrc) {
    if(open(US_CPP,"<$usSrc")) {
      while(<US_CPP>) {
        if(/^\s*DLL_EXPORT/ || /^\s*EXPORT\(/) {
          if(! /;$/) {
            chomp();
            $_.=";\n";
          }
          s/[\{\}]//g;
          $exportedFunctions.=$_;
          s/^\s*EXPORT\(([^\)]*)\)/$1/;
          s/^\s*DLL_EXPORT\s*//g;
          s/\s*__stdcall//g;
          $exportedFunctionsFixed.=$_;
        }
      }
      close(US_CPP);
    }else{
      unlinkUnitsyncTmpFiles();
      fatalError("Unable to open unitsync source file ($usSrc)");
    }
  }else{
    unlinkUnitsyncTmpFiles();
    fatalError("Unable to find unitsync source file ($usSrc)");
  }

  if(open(PUS_INT,'>PerlUnitSync.i')) {
    print PUS_INT "\%module PerlUnitSync\n";
    print PUS_INT "\%{\n";
    print PUS_INT "#include \"exportdefines.h\"\n";
    print PUS_INT "#include \"maindefines.h\"\n";
    print PUS_INT "#include \"unitsync.h\"\n\n";
    print PUS_INT $exportedFunctions;
    print PUS_INT "\%}\n\n";
    print PUS_INT $exportedFunctionsFixed;
    close(PUS_INT);
  }else{
    unlinkUnitsyncTmpFiles();
    fatalError('Unable to write Perl Unitsync interface file (PerlUnitSync.i)');
  }

  system('swig -perl5 PerlUnitSync.i');
  if($?) {
    unlinkUnitsyncTmpFiles();
    unlinkUnitsyncModuleFiles();
    fatalError('Error during Unitsync wrapper source generation');
  }

  my $coreIncsString;
  if($win) {
    $coreIncsString="\"-I$ENV{MINGDIR}\\include\" \"-I$ENV{PERL5_INCLUDE}\" -m32";
  }else{
    my @coreIncs;
    foreach my $inc (@INC) {
      push(@coreIncs,"\"-I$inc/CORE\"") if(-d "$inc/CORE");
    }
    $coreIncsString=join(' ','-fpic',@coreIncs);
  }
  system("g++ -c PerlUnitSync_wrap.c -Dbool=char $coreIncsString");
  if($?) {
    unlinkUnitsyncTmpFiles();
    unlinkUnitsyncModuleFiles();
    fatalError('Error during Unitsync wrapper compilation');
  }

  my $linkParam='';
  if($win) {
    $linkParam=" \"$ENV{PERL5_LIB}\" -static-libgcc -static-libstdc++ -m32";
  }else{
    $linkParam=" -Wl,-rpath,\"$1\"" if($unitsync =~ /^(.+)\/[^\/]+$/);
  }
  system("g++ -shared PerlUnitSync_wrap.o \"$unitsync\"$linkParam -o $perlUnitsyncLibName");
  unlinkUnitsyncTmpFiles();
  if($?) {
    unlinkUnitsyncModuleFiles();
    fatalError('Error during Perl Unitsync interface library compilation');
  }
}

sub exportWin32EnvVar {
  my $envVar=shift;
  my $envVarDef="$envVar=".($ENV{$envVar}//'');
  fatalError("Unable to export environment variable definition \"$envVarDef\"") unless(_putenv($envVarDef) == 0);
}

sub areSamePaths {
  my ($p1,$p2)=map {File::Spec->canonpath($_)} @_;
  ($p1,$p2)=map {lc($_)} ($p1,$p2) if($win);
  return $p1 eq $p2;
}

my @availableMods=();
my $springVersion;
sub checkUnitsync {
  my $defaultDataDir='';
  if(defined $unitsyncDir && -d "$unitsyncDir/base") {
    $defaultDataDir=$unitsyncDir;
  }else{
    my @potentialDataDirs=splitPaths($ENV{SPRING_DATADIR});
    if($win) {
      push(@potentialDataDirs,$defaultUnitsyncDir);
    }else{
      push(@potentialDataDirs,'/share/games/spring');
    }
    foreach my $potentialDataDir (@potentialDataDirs) {
      if(-d "$potentialDataDir/base") {
        $defaultDataDir=$potentialDataDir;
        last;
      }
    }
  }
  my $promptMsg=$win?'Please enter the Spring installation directory':'Please enter the absolute path of the main Spring data directory (containing Spring base content)';
  my $mainDataDir=promptExistingDir("$currentStep/$nbSteps - $promptMsg",$defaultDataDir);
  $currentStep++;
  my $defaultSecondaryDataDir='none';
  my @potentialDataDirs=splitPaths($ENV{SPRING_DATADIR});
  if($win) {
    my $win32PersonalDir=Win32::GetFolderPath(Win32::CSIDL_PERSONAL());
    my $win32CommonAppDataDir=Win32::GetFolderPath(Win32::CSIDL_COMMON_APPDATA());
    push(@potentialDataDirs,
         File::Spec->catdir($win32PersonalDir,'My Games','Spring'),
         File::Spec->catdir($win32PersonalDir,'Spring'),
         File::Spec->catdir($win32CommonAppDataDir,'Spring'));
  }else{
    push(@potentialDataDirs,File::Spec->catdir($ENV{HOME},'.spring'),File::Spec->catdir($ENV{HOME},'.config','spring')) if(defined $ENV{HOME});
    push(@potentialDataDirs,File::Spec->catdir($ENV{XDG_CONFIG_HOME},'spring')) if(defined $ENV{XDG_CONFIG_HOME});
  }
  foreach my $potentialDataDir (@potentialDataDirs) {
    if((! areSamePaths($potentialDataDir,$mainDataDir))
       && (! -d "$potentialDataDir/base")
       && (any {-d "$potentialDataDir/$_"} (qw'games maps packages'))) {
      $defaultSecondaryDataDir=$potentialDataDir;
      last;
    }
  }
  my $secondaryDataDir=promptExistingDir("$currentStep/$nbSteps - Please enter the absolute path of a secondary Spring data directory containing additional maps or mods (optional, ".($defaultSecondaryDataDir eq 'none' ? 'press enter' : 'enter "none"').' to skip)',$defaultSecondaryDataDir,'none');
  $currentStep++;
  $conf{dataDir}=$mainDataDir;
  $conf{dataDir}.="$pathSep$secondaryDataDir" unless($secondaryDataDir eq 'none');
  $ENV{SPRING_DATADIR}=$conf{dataDir};
  $ENV{SPRING_WRITEDIR}=$mainDataDir;
  if($win) {
    fatalError('Unable to import _putenv from msvcrt.dll ('.Win32::FormatMessage(Win32::GetLastError()).')')
        unless(Win32::API->Import('msvcrt', 'int __cdecl _putenv (char* envstring)'));
    exportWin32EnvVar('SPRING_DATADIR');
    exportWin32EnvVar('SPRING_WRITEDIR');
    $ENV{PATH}="$mainDataDir;$ENV{PATH}";
  }

  $sLog->log('Checking Perl Unitsync interface module',3);

  eval 'use PerlUnitSync';
  fatalError("Unable to load Perl Unitsync interface module ($@)") if($@);
  
  if(! PerlUnitSync::Init(0,0)) {
    while(my $unitSyncErr=PerlUnitSync::GetNextError()) {
      chomp($unitSyncErr);
      $sLog->log("UnitSync error: $unitSyncErr",1);
    }
    fatalError('Unable to initialize UnitSync library');
  }
  
  my $nbMods = PerlUnitSync::GetPrimaryModCount();
  for my $modNb (0..($nbMods-1)) {
    my $nbInfo = PerlUnitSync::GetPrimaryModInfoCount($modNb);
    my $modName='';
    for my $infoNb (0..($nbInfo-1)) {
      next if(PerlUnitSync::GetInfoKey($infoNb) ne 'name');
      $modName=PerlUnitSync::GetInfoValueString($infoNb);
      last;
    }
    if($modName eq '') {
      $sLog->log("Unable to find mod name for mod \#$modNb",1);
      next;
    }
    push(@availableMods,$modName);
  }
  $springVersion=PerlUnitSync::GetSpringVersion();
  PerlUnitSync::UnInit();
  chdir($conf{installDir});
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

sub makeAbsolutePath {
  my $path=shift;
  $path=File::Spec->catdir($conf{installDir},$path) unless(isAbsolutePath($path));
  return $path;
}

if(! exists $conf{release}) {
  print "\nThis program will install SPADS in the current working directory, overwriting files if needed.\n";
  print "The installer will ask you $nbSteps questions to customize your installation and pre-configure SPADS.\n";
  print "You can stop this installation at any time by hitting Ctrl-c.\n";
  print "Note: if SPADS is already installed on the system, you don't need to reinstall it to run multiple autohosts. Instead, you can share SPADS binaries and use multiple configuration files and/or configuration macros.\n\n";
  
  $conf{release}=promptChoice("1/$nbSteps - Which SPADS release do you want to install",[qw'stable testing unstable contrib'],'testing');
}elsif($conf{release} eq '-g') {
  $nbSteps=3;
  print "\nExecuting SPADS installer in Perl Unitsync interface generation mode.\n";
  print "The installer will ask you $nbSteps questions to (re)generate the Perl Unitsync interface module.\n";
  print "You can stop this process at any time by hitting Ctrl-c.\n\n";
  
  generatePerlUnitSync();

  checkUnitsync();

  $sLog->log('No Spring mod found',2) unless(@availableMods);

  print "\nPerl Unitsync interface module (re)generated.\n";
  print "\n" unless($win);
  exit 0;
}

$currentStep=2;

my $updaterLog=SimpleLog->new(logFiles => [''],
                              logLevels => [4],
                              useANSICodes => [-t STDOUT ? 1 : 0],
                              useTimestamps => [-t STDOUT ? 0 : 1],
                              prefix => '[SpadsUpdater] ');

my $updater=SpadsUpdater->new(sLog => $updaterLog,
                              localDir => cwd(),
                              repository => 'http://planetspads.free.fr/spads/repository',
                              release => $conf{release},
                              packages => \@packages);

my $updaterRc=$updater->update();
fatalError('Unable to retrieve SPADS packages') if($updaterRc < 0);
if($updaterRc > 0) {
  if($win) {
    print "\nSPADS installer has been updated, it must now be restarted as follows: \"perl $0 $conf{release}\"\n";
    exit 0;
  }
  $sLog->log('Restarting installer after update...',3);
  sleep(2);
  portableExec($^X,$0,$conf{release});
  fatalError('Unable to restart installer');
}
$sLog->log('SPADS components are up to date, proceeding with installation...',3);
if(! $win) {
  if(-f 'PerlUnitSync.pm' && -f 'PerlUnitSync.so') {
    $sLog->log('Perl Unitsync interface module already exists, skipping generation (use "-g" flag to force generation)',3);
    $currentStep++;
  }else {
    generatePerlUnitSync();
  }
}

checkUnitsync();

if($win) {
  $updater=SpadsUpdater->new(sLog => $updaterLog,
                             localDir => cwd(),
                             repository => 'http://planetspads.free.fr/spads/repository',
                             release => $conf{release},
                             packages => \@packagesWinServer,
                             syncedSpringVersion => $springVersion);
  $updaterRc=$updater->update();
  fatalError('Unable to retrieve Spring server binaries') if($updaterRc < 0);
  $sLog->log("Spring server binaries updated for Spring $springVersion",3) if($updaterRc > 0);
}

my $serverType=promptChoice("$currentStep/$nbSteps - Which type of server do you want to use (\"headless\" requires much more resource and doesn't support \"ghost maps\", but it allows running AI bots and LUA scripts on server side)?",[qw'dedicated headless'],'dedicated');
$currentStep++;
my $springServer=$win?"spring-$serverType.exe":"spring-$serverType";

if($win) {
  $conf{dedicated}=File::Spec->catfile($conf{installDir},$springServer);
}else{
  my $defaultSpringServerPath='';
  if(defined $unitsyncDir && -f "$unitsyncDir/$springServer") {
    $defaultSpringServerPath=File::Spec->catfile($unitsyncDir,$springServer);
  }else{
    my @potentialSpringServerDirs=splitPaths($ENV{SPRING_DATADIR});
    foreach my $path (@potentialSpringServerDirs,@pathes) {
      if(-f "$path/$springServer") {
        $defaultSpringServerPath=File::Spec->catfile($path,$springServer);
        last;
      }
    }
  }
  $conf{dedicated}=promptExistingFile("$currentStep/$nbSteps - Please enter the absolute path of the spring $serverType server",$springServer,$defaultSpringServerPath);
  $currentStep++;
}

@availableMods=sort(@availableMods);
$conf{modName}='_NO_MOD_FOUND_';

if(! @availableMods) {
  $sLog->log("No Spring mod found, consequently the \"modName\" parameter in \"hostingPresets.conf\" will NOT be auto-configured",2);
  $sLog->log('Hit Ctrl-C now if you want to abort this installation to fix the problem, or remember that you will have to set the default mod manually later',2);
  $currentStep+=2;
}else{
  my $chosenModNb='';
  if($#availableMods == 0) {
    $chosenModNb=0;
  }else{
    print "Available mods:\n";
    foreach my $modNb (0..$#availableMods) {
      print "  $modNb --> $availableMods[$modNb]\n";
    }
    while($chosenModNb !~ /^\d+$/ || $chosenModNb > $#availableMods) {
      print "$currentStep/$nbSteps - Please choose the AutoHost default mod ? ";
      $chosenModNb=<STDIN>;
      $chosenModNb//='';
      chomp($chosenModNb);
    }
  }
  $currentStep++;
  $conf{modName}=$availableMods[$chosenModNb];

  my $modFilter=quotemeta($conf{modName});
  $modFilter =~ s/\d+/\\d+/g;
  
  my $isLatestMod=1;
  foreach my $availableMod (@availableMods) {
    next if($availableMod eq $conf{modName});
    if($availableMod =~ /^$modFilter$/ && $availableMod gt $conf{modName}) {
      $isLatestMod=0;
      last;
    }
  }

  if($isLatestMod) {
    my $chosenModText=$#availableMods>0?'You chose the latest version of this mod currently available in your "games" and "packages" folders. ':'';
    my $useLatestMod=promptChoice("$currentStep/$nbSteps - ${chosenModText}Do you want to enable new mod auto-detection to always host the latest version of this mod available in your \"games\" and \"packages\" folders?",[qw'yes no'],'yes');
    if($useLatestMod eq 'yes') {
      $sLog->log("Using following regular expression as default AutoHost mod filter: \"$modFilter\"",3);
      $modFilter='~'.$modFilter;
      $conf{modName}=$modFilter;
    }else{
      $sLog->log("Using \"$conf{modName}\" as default AutoHost mod",3);
    }
  }else{
    $sLog->log("Using \"$conf{modName}\" as default AutoHost mod",3);
  } 
  $currentStep++;
}

my $defaultDir=File::Spec->catdir($conf{installDir},'var');
print "$currentStep/$nbSteps - Please choose the directory where SPADS dynamic data will be stored [$defaultDir] ? ";
$currentStep++;
my $c=<STDIN>;
$c//='';
chomp($c);
$c=$defaultDir if($c eq '');
$c=makeAbsolutePath($c);
createDir($c);
$conf{varDir}=$c;
$conf{pluginsDir}=File::Spec->catdir($conf{varDir},'plugins');

$defaultDir=File::Spec->catdir($conf{varDir},'log');
print "$currentStep/$nbSteps - Please choose the directory where SPADS will write the logs [$defaultDir] ? ";
$currentStep++;
$c=<STDIN>;
$c//='';
chomp($c);
$c=$defaultDir if($c eq '');
$c=makeAbsolutePath($c);
createDir($c);
createDir(File::Spec->catdir($c,'chat'));
$conf{logDir}=$c;

$defaultDir=File::Spec->catdir($conf{installDir},'etc');
print "$currentStep/$nbSteps - Please choose the directory where SPADS configuration files will be stored [$defaultDir] ? ";
$currentStep++;
$c=<STDIN>;
$c//='';
chomp($c);
$c=$defaultDir if($c eq '');
$c=makeAbsolutePath($c);
createDir($c);
createDir(File::Spec->catdir($c,'templates'));
$conf{etcDir}=$c;

$conf{login}=promptString("$currentStep/$nbSteps - Please enter the AutoHost lobby login (the lobby account must already exist)");
$currentStep++;
$conf{password}=promptString("$currentStep/$nbSteps - Please enter the AutoHost lobby password");
$currentStep++;
$conf{owner}=promptString("$currentStep/$nbSteps - Please enter the lobby login of the AutoHost owner");
$currentStep++;


my @confFiles=qw'banLists.conf battlePresets.conf commands.conf hostingPresets.conf levels.conf mapBoxes.conf mapLists.conf spads.conf users.conf';
$sLog->log('Downloading SPADS configuration templates',3);
exit 1 unless(all {downloadFile("http://planetspads.free.fr/spads/conf/templates/$conf{release}/$_",File::Spec->catdir($conf{etcDir},'templates',$_))} @confFiles);
$sLog->log('Customizing SPADS configuration',3);
foreach my $confFile (@confFiles) {
  my $confFileTemplate=File::Spec->catfile($conf{etcDir},'templates',$confFile);
  fatalError("Unable to read configuration template \"$confFileTemplate\"") unless(open(TEMPLATE,"<$confFileTemplate"));
  my $confFilePath=File::Spec->catfile($conf{etcDir},$confFile);
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

print "\nSPADS has been installed in current directory with default configuration and minimal customization.\n";
print "You can check your configuration files in \"$conf{etcDir}\" and update them if needed.\n";
print "You can then launch SPADS with \"perl spads.pl ".File::Spec->catfile($conf{etcDir},'spads.conf')."\"\n";
