#!/usr/bin/perl -w
#
# This program installs SPADS in current directory from remote repository.
#
# Copyright (C) 2008-2013  Yann Riou <yaribzh@gmail.com>
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

# Version 0.12a (2013/11/10)

use strict;

use File::Copy;
use File::Path;
use Cwd;

use SimpleLog;
use SpadsUpdater;

my $currentStep=1;
my $nbSteps=13;
my @packages=qw/getDefaultModOptions.pl help.dat helpSettings.dat SpringAutoHostInterface.pm SpringLobbyInterface.pm SimpleLog.pm spads.pl SpadsConf.pm spadsInstaller.pl SpadsUpdater.pm SpadsPluginApi.pm update.pl argparse.py replay_upload.py/;
my @packagesWin=qw/PerlUnitSync.pm PerlUnitSync.dll spring-dedicated.exe spring-headless.exe/;
my $win=$^O eq 'MSWin32' ? 1 : 0;

my @pathes;
if(exists $ENV{PATH}) {
  if($win) {
    @pathes=split(/;/,$ENV{PATH});
  }else{
    @pathes=split(/:/,$ENV{PATH});
  }
}

my $nullDevice="/dev/null";
my $perlExecPrefix="";
my $exeExtension="";
my $dllExtension=".so";
if($win) {
  $nbSteps=11;
  $nullDevice="nul";
  $perlExecPrefix="perl ";
  $exeExtension=".exe";
  $dllExtension=".dll";
  push(@pathes,cwd());
  push(@packages,@packagesWin);
}

my %conf;
$conf{installDir}=cwd();

my $sLog=SimpleLog->new(logFiles => [""],
                        logLevels => [4],
                        useANSICodes => [1-$win],
                        useTimestamps => [0],
                        prefix => "[SpadsInstaller] ");

if(@ARGV) {
  if($#ARGV == 0 && grep {/^$ARGV[0]$/} qw/stable testing unstable contrib -g/) {
    $conf{release}=$ARGV[0];
  }else{
    $sLog->log("Invalid usage",1);
    print "Usage:\n";
    print "  $perlExecPrefix$0 [release]\n";
    print "  $perlExecPrefix$0 -g\n";
    print "      release: \"stable\", \"testing\", \"unstable\" or \"contrib\"\n";
    print "      -g: (re)generate unitsync wrapper only\n";
    exit 1;
  }
}

my %prereqFound=(swig => 0,
                 "g++" => 0,
                 wget => 0);
foreach my $prereq (keys %prereqFound) {
  foreach my $path (@pathes) {
    if(-f "$path/$prereq$exeExtension") {
      $prereqFound{$prereq}=1;
      last;
    }
  }
}
if(! $prereqFound{wget}) {
  $sLog->log("Couldn't find wget, please install wget before installing SPADS",1);
  exit 1;
}
if(! $win || (exists $conf{release} && $conf{release} eq "-g")) {
  if(! $prereqFound{swig}) {
    $sLog->log("Couldn't find Swig, please install Swig for Perl Unitsync interface module generation",1);
    exit 1;
  }
  if(! $prereqFound{"g++"}) {
    $sLog->log("Couldn't find g++, please install g++ for Perl Unitsync interface module generation",1);
    exit 1;
  }
  if($win) {
    if(! exists $ENV{PERL5_INCLUDE} || ! -d $ENV{PERL5_INCLUDE}) {
      $sLog->log("The PERL5_INCLUDE environment variable must be set to your Perl CORE include directory (for instance: \"C:\\Perl\\lib\\CORE\")",1);
      exit 1;
    }
    if(! exists $ENV{PERL5_LIB} || $ENV{PERL5_LIB} !~ /^[a-zA-Z]\:/ || ! -f $ENV{PERL5_LIB}) {
      $sLog->log("The PERL5_LIB environment variable must be set to your Perl CORE library absolute path (for instance: \"C:\\Perl\\lib\\CORE\\perl510.lib\")",1);
      exit 1;
    }
    if(! exists $ENV{MINGDIR} || ! -d "$ENV{MINGDIR}/include") {
      $sLog->log("The MINGDIR environment variable must be set to your MinGW install directory (for instance: \"C:\\mingw\")",1);
      exit 1;
    }
  }
}

sub promptChoice {
  my ($prompt,$p_choices,$default)=@_; 
  my @choices=@{$p_choices};
  my $choicesString=join(",",@choices);
  my $choice="";
  while(! grep {/^$choice$/} @choices) {
    print "$prompt ($choicesString) [$default] ? ";
    $choice=<STDIN>;
    $choice="" unless(defined $choice);
    chomp($choice);
    $choice=$default if($choice eq "");
  }
  return $choice;
}

sub promptExistingFile {
  my ($prompt,$p_fileNames,$default)=@_;
  my $fileNamesString=join(",",@{$p_fileNames});
  my $choice="";
  while(! isAbsoluteFilePath($choice,$p_fileNames)) {
    print "$prompt ($fileNamesString) [$default] ? ";
    $choice=<STDIN>;
    $choice="" unless(defined $choice);
    chomp($choice);
    $choice=$default if($choice eq "");
  }
  return $choice;
}

sub promptExistingDir {
  my ($prompt,$default)=@_;
  my $choice="";
  while((! $win && $choice !~ /^\//) || ($win && $choice !~ /^[a-zA-Z]\:/) || ! -d $choice) {
    print "$prompt [$default] ? ";
    $choice=<STDIN>;
    $choice="" unless(defined $choice);
    chomp($choice);
    $choice=$default if($choice eq "");
  }
  return $choice;
}

sub promptString {
  my $prompt=shift;
  my $choice="";
  while($choice eq "") {
    print "$prompt ? ";
    $choice=<STDIN>;
    $choice="" unless(defined $choice);
    chomp($choice);
  }
  return $choice;
}

sub isAbsoluteFilePath {
  my ($path,$p_fileNames)=@_;
  foreach my $fileName (@{$p_fileNames}) {
    my $fileRegExp=quotemeta($fileName);
    if($win) {
      return 1 if($path =~ /^[a-zA-Z]\:.*[\/\\]$fileRegExp$/ && -f $path);
    }else{
      return 1 if($path =~ /^\/.*\/$fileRegExp$/ && -f $path);
    }
  }
  return 0;
}

sub createDir {
  my $dir=shift;
  eval { mkpath($dir) };
  if ($@) {
    $sLog->log("Couldn't create directory \"$dir\" ($@)",1);
    exit 1;
  }
  $sLog->log("Directory \"$dir\" created",3);
}

sub downloadFile {
  my ($url,$file)=@_;
  system("wget -T 10 -t 2 $url -O \"$file\" >$nullDevice 2>&1");
  if($? || ! -f $file) {
    $sLog->log("Unable to download $file from $url",1);
    unlink($file);
    return 0;
  }
  return 1;
}

sub generatePerlUnitSync {
  my $defaultUnitsync="";
  my @libPathes=@pathes;
  my @unitsyncNames=qw/unitsync.dll/;
  if(! $win) {
    @unitsyncNames=qw/libunitsync.so/;
    @libPathes=split(/:/,$ENV{LD_LIBRARY_PATH}) if(exists $ENV{LD_LIBRARY_PATH});
    push(@libPathes,"/lib");
  }
  my $found=0;
  foreach my $libPath (@libPathes) {
    foreach my $unitsyncName (@unitsyncNames) {
      if(-f "$libPath/$unitsyncName") {
        $found=1;
        $defaultUnitsync="$libPath/$unitsyncName";
        last;
      }
    }
    last if($found);
  }
  my $unitsync=promptExistingFile("$currentStep/$nbSteps - Please enter the absolute path of the unitsync library",\@unitsyncNames,$defaultUnitsync);
  $currentStep++;

  $sLog->log("Generating Perl Unitsync interface module",3);
  exit 1 unless(downloadFile("http://planetspads.free.fr/spads/unitsync/src/unitsync.h","unitsync.h"));
  if(! downloadFile("http://planetspads.free.fr/spads/unitsync/src/unitsync.cpp","unitsync.cpp")) {
    unlink("unitsync.h");
    exit 1;
  }
  if(! downloadFile("http://planetspads.free.fr/spads/unitsync/src/exportdefines.h","exportdefines.h")) {
    unlink("unitsync.h");
    unlink("unitsync.cpp");
    exit 1;
  }
  if(! downloadFile("http://planetspads.free.fr/spads/unitsync/src/maindefines.h","maindefines.h")) {
    unlink("unitsync.h");
    unlink("unitsync.cpp");
    unlink("exportdefines.h");
    exit 1;
  }
  
  my $exportedFunctions="";
  my $exportedFunctionsFixed="";
  my $usSrc="unitsync.cpp";
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
      $sLog->log("Unable to open unitsync source file ($usSrc)",1);
      unlink("unitsync.h");
      unlink("unitsync.cpp");
      unlink("exportdefines.h");
      unlink("maindefines.h");
      exit 1;
    }
  }else{
    $sLog->log("Unable to find unitsync source file ($usSrc)",1);
    unlink("unitsync.h");
    unlink("unitsync.cpp");
    unlink("exportdefines.h");
    unlink("maindefines.h");
    exit 1;
  }
  unlink("unitsync.cpp");

  if(open(PUS_INT,">PerlUnitSync.i")) {
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
    $sLog->log("Unable to write Perl Unitsync interface file (PerlUnitSync.i)",1);
    unlink("unitsync.h");
    unlink("exportdefines.h");
    unlink("maindefines.h");
    exit 1;
  }

  my $coreIncsString;
  if($win) {
    $coreIncsString="-I$ENV{MINGDIR}/include -I$ENV{PERL5_INCLUDE}";
  }else{
    my @coreIncs;
    foreach my $inc (@INC) {
      push(@coreIncs,"-I$inc/CORE") if(-d "$inc/CORE");
    }
    $coreIncsString=join(" ",@coreIncs);
  }

  system("swig -perl5 PerlUnitSync.i");
  if($?) {
    $sLog->log("Error during Unitsync wrapper source generation",1);
    unlink("unitsync.h");
    unlink("exportdefines.h");
    unlink("maindefines.h");
    unlink("PerlUnitSync.i");
    unlink("PerlUnitSync_wrap.c");
    unlink("PerlUnitSync.pm");
    exit 1;
  }
  system("g++ -fpic -c PerlUnitSync_wrap.c -Dbool=char $coreIncsString");
  if($?) {
    $sLog->log("Error during Unitsync wrapper compilation",1);
    unlink("unitsync.h");
    unlink("exportdefines.h");
    unlink("maindefines.h");
    unlink("PerlUnitSync.i");
    unlink("PerlUnitSync_wrap.c");
    unlink("PerlUnitSync.pm");
    unlink("PerlUnitSync_wrap.o");
    exit 1;
  }
  my $linkParam="";
  if($win) {
    $linkParam=" $ENV{PERL5_LIB}";
  }else{
    $linkParam=" -Wl,-rpath,$1" if($unitsync =~ /^(.+)\/[^\/]+$/);
  }
  system("g++ -shared PerlUnitSync_wrap.o $unitsync$linkParam -o PerlUnitSync$dllExtension");
  unlink("unitsync.h");
  unlink("exportdefines.h");
  unlink("maindefines.h");
  unlink("PerlUnitSync.i");
  unlink("PerlUnitSync_wrap.c");
  unlink("PerlUnitSync_wrap.o");
  if($?) {
    $sLog->log("Error during Perl Unitsync interface library compilation",1);
    unlink("PerlUnitSync.pm");
    unlink("PerlUnitSync$dllExtension");
    exit 1;
  }
}

my $nbMods=0;
my @availableMods=();
sub checkUnitsync {
  my $defaultSpringDataDir="";
  $defaultSpringDataDir="/share/games/spring" if(! $win && -d "/share/games/spring");
  $defaultSpringDataDir=$ENV{SPRING_DATADIR} if(exists $ENV{SPRING_DATADIR} && $ENV{SPRING_DATADIR} ne "" && -d $ENV{SPRING_DATADIR});
  $defaultSpringDataDir=$ENV{SPRING_WRITEDIR} if(exists $ENV{SPRING_WRITEDIR} && $ENV{SPRING_WRITEDIR} ne "" && -d $ENV{SPRING_WRITEDIR});
  if($win) {
    $conf{dataDir}=promptExistingDir("$currentStep/$nbSteps - Please enter the Spring installation directory",$defaultSpringDataDir);
  }else{
    $conf{dataDir}=promptExistingDir("$currentStep/$nbSteps - Please enter the absolute path of the spring data directory (for maps, mods...)",$defaultSpringDataDir);
  }
  $currentStep++;

  $sLog->log("Checking Perl Unitsync interface module",3);
  $ENV{SPRING_DATADIR}=$conf{dataDir};
  $ENV{SPRING_WRITEDIR}=$conf{dataDir};
  if($win) {
    $ENV{PATH}="$ENV{PATH};$conf{dataDir}";
    push(@INC,$conf{installDir});
    chdir($conf{dataDir});
  }

  eval "use PerlUnitSync";
  if ($@) {
    $sLog->log("Unable to load Perl Unitsync interface module ($@)",1);
    exit 1;
  }
  
  if(! PerlUnitSync::Init(0,0)) {
    $sLog->log("Unable to initialize UnitSync library",1);
    exit 1;
  }
  
  $nbMods = PerlUnitSync::GetPrimaryModCount();
  for my $modNb (0..($nbMods-1)) {
    push(@availableMods,PerlUnitSync::GetPrimaryModName($modNb));
  }
  PerlUnitSync::UnInit();
  chdir($conf{installDir});
}

if(! exists $conf{release}) {
  print "\nThis program will install SPADS in the current working directory, overwriting files if needed.\n";
  print "The installer will ask you $nbSteps questions to customize your installation and pre-configure SPADS.\n";
  print "You can stop this installation at any time by hitting Ctrl-c.\n";
  print "Note: if SPADS is already installed on the system, you don't need to reinstall it to run multiple autohosts. Instead, you can share SPADS binaries and use multiple configuration files and/or configuration macros.\n\n";
  
  $conf{release}=promptChoice("1/$nbSteps - Which SPADS release do you want to install",[qw/stable testing unstable contrib/],"testing");
}elsif($conf{release} eq "-g") {
  $nbSteps=2;
  print "\nExecuting SPADS installer in Perl Unitsync interface generation mode.\n";
  print "The installer will ask you $nbSteps questions to (re)generate the Perl Unitsync interface module.\n";
  print "You can stop this process at any time by hitting Ctrl-c.\n\n";

  generatePerlUnitSync();

  checkUnitsync();

  $sLog->log("No Spring mod found",2) if(! $nbMods);

  print "\nPerl Unitsync interface module (re)generated.\n";
  print "\n" unless($win);
  exit 0;
}

$currentStep=2;

my $updaterLog=SimpleLog->new(logFiles => [""],
                              logLevels => [4],
                              useANSICodes => [1 - $win],
                              useTimestamps => [0],
                              prefix => "[SpadsUpdater] ");

my $updater=SpadsUpdater->new(sLog => $updaterLog,
                              localDir => cwd(),
                              repository => "http://planetspads.free.fr/spads/repository",
                              release => $conf{release},
                              packages => \@packages);

my $updaterRc=$updater->update();
if($updaterRc < 0) {
  $sLog->log("Unable to retrieve SPADS packages",1);
  exit 1;
}
if($updaterRc > 0) {
  if($win) {
    print "\nSPADS installer has been updated, it must now be restarted as follows: \"perl $0 $conf{release}\"\n";
    exit 0;
  }else{
    $sLog->log("Restarting installer after update...",3);
    sleep(2);
    exec("$0 $conf{release}");
  }
}
$sLog->log("Components are up to date, proceeding with installation...",3);

my $serverType=promptChoice("$currentStep/$nbSteps - Which type of server do you want to use (\"headless\" requires much more resource and doesn't support \"ghost maps\", but it allows running AI bots and LUA scripts at server side)?",[qw/dedicated headless/],'dedicated');
$currentStep++;

if($win) {
  $conf{updateBin}="yes";
  $conf{dedicated}="$conf{installDir}/spring-$serverType.exe";
}else{
  $conf{updateBin}="no";
  if(-f "PerlUnitSync.pm" && -f "PerlUnitSync.so") {
    $sLog->log("Perl Unitsync interface module already exists, skipping generation",3);
    $currentStep++;
  }else {
    generatePerlUnitSync();
  }
  my $defaultSpringDedicated="";
  foreach my $path (@pathes) {
    if(-f "$path/spring-$serverType") {
      $defaultSpringDedicated="$path/spring-$serverType";
      last;
    }
  }
  $conf{dedicated}=promptExistingFile("$currentStep/$nbSteps - Please enter the absolute path of the spring $serverType server",["spring-$serverType"],$defaultSpringDedicated);
  $currentStep++;
}

checkUnitsync();

@availableMods=sort(@availableMods);
$conf{modName}="_NO_MOD_FOUND_";

if(! $nbMods) {
  $sLog->log("No Spring mod found, consequently the \"modName\" parameter in \"hostingPresets.conf\" will NOT be auto-configured",2);
  $sLog->log("Hit Ctrl-C now if you want to abort this installation to fix the problem, or remember that you will have to set the default mod manually later",2);
  $currentStep+=2;
}else{
  my $chosenModNb="";
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
      $chosenModNb="" unless(defined $chosenModNb);
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
    my $useLatestMod=promptChoice("$currentStep/$nbSteps - You chose the latest version of this mod currently available locally in your \"games\" or \"packages\" folder. Do you want to enable new mod auto-detection to always host the latest version available locally ?",[qw/yes no/],"yes");
    if($useLatestMod eq "yes") {
      $sLog->log("Using following regular expression as default AutoHost mod filter: \"$modFilter\"",3);
      $modFilter="~".$modFilter;
      $conf{modName}=$modFilter;
    }else{
      $sLog->log("Using \"$conf{modName}\" as default AutoHost mod",3);
    }
  }else{
    $sLog->log("Using \"$conf{modName}\" as default AutoHost mod",3);
  } 
  $currentStep++;
}

sub makeAbsolutePath {
  my $path=shift;
  if($win) {
    $path="$conf{installDir}/$path" unless($path =~ /^[a-zA-Z]\:/);
  }else{
    $path="$conf{installDir}/$path" unless($path =~ /^\//);
  }
  return $path;
}

print "$currentStep/$nbSteps - Please choose the directory where SPADS will store its dynamic data [$conf{installDir}/var] ? ";
$currentStep++;
my $c=<STDIN>;
$c="" unless(defined $c);
chomp($c);
$c="var" if($c eq "");
$c=makeAbsolutePath($c);
createDir($c);
$conf{varDir}=$c;

print "$currentStep/$nbSteps - Please choose the directory where SPADS will write its logs [$conf{installDir}/var/log] ? ";
$currentStep++;
$c=<STDIN>;
$c="" unless(defined $c);
chomp($c);
$c="var/log" if($c eq "");
$c=makeAbsolutePath($c);
createDir($c);
createDir("$c/chat");
$conf{logDir}=$c;

print "$currentStep/$nbSteps - Please choose the directory where SPADS configuration files will be stored [$conf{installDir}/etc] ? ";
$currentStep++;
$c=<STDIN>;
$c="" unless(defined $c);
chomp($c);
$c="etc" if($c eq "");
$c=makeAbsolutePath($c);
createDir($c);
createDir("$c/templates");
$conf{etcDir}=$c;

$conf{login}=promptString("$currentStep/$nbSteps - Please enter the AutoHost lobby login (the lobby account must already exist)");
$currentStep++;
$conf{password}=promptString("$currentStep/$nbSteps - Please enter the AutoHost lobby password");
$currentStep++;
$conf{owner}=promptString("$currentStep/$nbSteps - Please enter the lobby login of the AutoHost owner");
$currentStep++;


my @confFiles=qw/banLists.conf battlePresets.conf commands.conf hostingPresets.conf levels.conf mapBoxes.conf mapLists.conf spads.conf users.conf/;
$sLog->log("Downloading SPADS configuration templates",3);
foreach my $confFile (@confFiles) {
  exit 1 unless(downloadFile("http://planetspads.free.fr/spads/conf/templates/$conf{release}/$confFile","$conf{etcDir}/templates/$confFile"));
}
$sLog->log("Customizing SPADS configuration",3);
foreach my $confFile (@confFiles) {
  if(! open(TEMPLATE,"<$conf{etcDir}/templates/$confFile")) {
    $sLog->log("Unable to read configuration template \"$conf{etcDir}/templates/$confFile\"",1);
    exit 1;
  }
  if(! open(CONF,">$conf{etcDir}/$confFile")) {
    $sLog->log("Unable to write configuration file \"$conf{etcDir}/$confFile\"",1);
    exit 1;
  }
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
if($win) {
  print "You can then launch SPADS with \"perl spads.pl $conf{etcDir}/spads.conf\"\n";
}else{
  print "You can then launch SPADS with \"./spads.pl $conf{etcDir}/spads.conf\"\n";
}
