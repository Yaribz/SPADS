#!/usr/bin/perl -w
#
# This program prints the default mod options of each Spring mod installed,
# using the unitsync library.
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

use strict;

use Cwd;
use File::Basename 'fileparse';
use File::Spec;
use FileHandle;
use FindBin;
use Getopt::Long qw':config auto_version';
use List::Util qw'any all none notall';

use lib $FindBin::Bin;

our $VERSION=0.8;

use constant {
  MSWIN32 => $^O eq 'MSWin32',
  DARWIN => $^O eq 'darwin',
};

use constant {
  UNITSYNC_LIB_NAME => (MSWIN32 ? '' : 'lib').'unitsync.'.(MSWIN32 ? 'dll' : (DARWIN ? 'dylib' : 'so')),
};

my @OPTION_TYPES=qw'error bool list number string section';

my $PATH_SEP=MSWIN32?';':':';
my $CWD=cwd();

if(MSWIN32) {
  eval 'use Win32';
  die "\nWin32::API module version 0.73 or superior is required.\nPlease update your Perl installation (Perl 5.16.2 or superior is recommended)\n"
      unless(eval { require Win32::API; Win32::API->VERSION(0.73); 1; });
  die 'Unable to import _putenv from msvcrt.dll ('.Win32::FormatMessage(Win32::GetLastError()).")\n"
      unless(Win32::API->Import('msvcrt', 'int __cdecl _putenv (char* envstring)'));
}

sub printUsageAndExit {
  print <<EOM;
Usage:

  $0 -h|--help
    Prints help and exits

  $0 [-c|--comments] [-s|--spads] [-o <file>|--output=<file>] [-u <unitsyncPath>|--unitsync=<unitsyncPath>] [-d <springDataDir>|--datadir=<springDataDir>]
    Generates the modoptions list for the games found in the Spring data directories.
    Optional command line parameters:
      -c|--comments             : includes comments explaining each mod option in the output
      -s|--spads                : generates output in SPADS format (ready to be copy-pasted in the battlePresets.conf file)
      -o <file>|--output=<file> : writes output into <file> instead of stdout
      -u <unitsyncPath>|--unitsync=<unitsyncPath> : unitsync library path
      -d <springDataDir>|--datadir=<springDataDir> : Spring data directory (this option can be provided multiple times to load several Spring data directories)

EOM
  exit;
}

sub printHelpAndExit {

  print <<EOM;

getDefaultModOptions is an application bundled with SPADS which retrieves and prints the list of modoptions for all installed Spring games.
The output can be optionnaly generated in SPADS format, ready to be directly copy-pasted in the battlePresets.conf configuration file.

EOM

  printUsageAndExit();
}

sub isAbsolutePath {
  my $fileName=shift;
  my $fileSpecRes=File::Spec->file_name_is_absolute($fileName);
  return $fileSpecRes == 2 if(MSWIN32);
  return $fileSpecRes;
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

sub areSamePaths {
  my ($p1,$p2)=map {File::Spec->canonpath($_)} @_;
  ($p1,$p2)=map {lc($_)} ($p1,$p2) if(MSWIN32);
  return $p1 eq $p2;
}

sub setEnvVarFirstPaths {
  my ($varName,@firstPaths)=@_;
  my $needRestart=0;
  die "Unable to handle path containing \"$PATH_SEP\" character!\n" if(any {index($_,$PATH_SEP) != -1} @firstPaths);
  $ENV{"SPADS_$varName"}=$ENV{$varName}//'_UNDEF_' unless(exists $ENV{"SPADS_$varName"});
  my @currentPaths=split(/$PATH_SEP/,$ENV{$varName}//'');
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
    my @origPaths=$ENV{"SPADS_$varName"} eq '_UNDEF_' ? () : split(/$PATH_SEP/,$ENV{"SPADS_$varName"});
    my @newPaths;
    foreach my $path (@origPaths) {
      push(@newPaths,$path) unless(any {areSamePaths($path,$_)} @firstPaths);
    }
    $ENV{$varName}=join($PATH_SEP,@firstPaths,@newPaths);
  }
  return $needRestart;
}

sub exportWin32EnvVar {
  my $envVar=shift;
  my $envVarDef="$envVar=".($ENV{$envVar}//'');
  die "Unable to export environment variable definition \"$envVarDef\"" unless(_putenv($envVarDef) == 0);
}

my $generateComments;
my $spadsFormat;
my $outputFile;
my $unitsyncPath;
my @dataDirs;
my $outputHandle;

my %optionsHash=('help' => sub { printHelpAndExit() },
                 'comments!' => \$generateComments,
                 'spads!' => \$spadsFormat,
                 'output=s' => \$outputFile,
                 'datadir=s' => \@dataDirs,
                 'unitsync=s' => \$unitsyncPath);
printUsageAndExit() unless(GetOptions(%optionsHash));

my @unrecognizedParams;
foreach my $arg (@ARGV) {
  $arg=File::Spec->rel2abs($arg) if(-e $arg);
  $unitsyncPath//=$arg if(isAbsoluteFilePath($arg,UNITSYNC_LIB_NAME));
  if(-d $arg) {
    push(@dataDirs,$arg);
  }else{
    push(@unrecognizedParams,$arg);
  }
}
if(@unrecognizedParams) {
  print 'Invalid parameter: "'.join('", "',@unrecognizedParams)."\"\n";
  printUsageAndExit();
}
@dataDirs=split(/$PATH_SEP/,join($PATH_SEP,@dataDirs));
foreach my $dataDir (@dataDirs) {
  if(-d $dataDir) {
    $dataDir=File::Spec->rel2abs($dataDir);
  }else{
    push(@unrecognizedParams,$dataDir);
  }
}
if(@unrecognizedParams) {
  print 'Invalid Spring data directory: "'.join('", "',@unrecognizedParams)."\"\n";
  printUsageAndExit();
}

my $unitsyncDir;
if(defined $unitsyncPath) {
  $unitsyncPath=File::Spec->rel2abs($unitsyncPath) if(-e $unitsyncPath);
  my $fullUnitsyncPath=isAbsoluteFilePath($unitsyncPath,UNITSYNC_LIB_NAME);
  if(! $fullUnitsyncPath) {
    print "Invalid unitsync path\n";
    printUsageAndExit();
  }
  $unitsyncDir=File::Spec->canonpath((fileparse($fullUnitsyncPath))[1]);
}

if(@dataDirs) {
  setEnvVarFirstPaths('SPRING_DATADIR',@dataDirs);
  exportWin32EnvVar('SPRING_DATADIR') if(MSWIN32);
}

$ENV{SPRING_WRITEDIR}=$CWD unless(areSamePaths($CWD,$ENV{SPRING_WRITEDIR}//''));
exportWin32EnvVar('SPRING_WRITEDIR') if(MSWIN32);

eval {require PerlUnitSync};
die "ERROR - Unable to load PerlUnitSync module - $@" if($@);

my $unitsync = eval {PerlUnitSync->new($unitsyncDir)};
if($@) {
  if($unitsyncPath) {
    die "ERROR - $@";
  }else{
    print "ERROR - Failed to load unitsync library - try specifying the unitsync library path as command line parameter\n";
    printUsageAndExit();
  }
}
die "ERROR - Failed to load unitsync library - unknown error\n" unless(defined $unitsync);

if(! $unitsync->Init(0,0)) {
  while(my $unitSyncErr=$unitsync->GetNextError()) {
    chomp($unitSyncErr);
    print("ERROR - UnitSync error: $unitSyncErr\n");
  }
  my $errorMsg='ERROR - Unable to initialize UnitSync library';
  $errorMsg.=' (try specifying the Spring data directory as command line parameter)' unless(@dataDirs);
  print $errorMsg."\n";
  exit 0;
}

my $nbMods = $unitsync->GetPrimaryModCount();
if(! $nbMods) {
  print("ERROR - No Spring mod found\n");
  $unitsync->UnInit();
  exit 0;
}

my @availableMods=();
for my $modNb (0..($nbMods-1)) {
  my $nbInfo = $unitsync->GetPrimaryModInfoCount($modNb);
  my $modName='';
  for my $infoNb (0..($nbInfo-1)) {
    next if($unitsync->GetInfoKey($infoNb) ne 'name');
    $modName=$unitsync->GetInfoValueString($infoNb);
    last;
  }
  my $modArchive = $unitsync->GetPrimaryModArchive($modNb);
  $availableMods[$modNb]={name=>$modName,archive=>$modArchive};
}

if($outputFile) {
  $outputHandle=new FileHandle;
  if(! $outputHandle->open("> $outputFile")) {
    print("ERROR - Unable to open \"$outputFile\" for writing\n");
    exit 0;
  }
  $outputHandle->autoflush(1);
}

sub printRes {
  my $s=shift;
  if(defined $outputHandle) {
    print $outputHandle $s;
  }else{
    print $s;
  }
}

sub getRangeStepFromBoundaries {
  my $maxNbDecimals=0;
  for my $boundaryValue (@_) {
    if($boundaryValue =~ /\.(\d+)$/) {
      my $nbDecimals=length($1);
      $maxNbDecimals=$nbDecimals if($nbDecimals > $maxNbDecimals);
    }
  }
  return 10**(-$maxNbDecimals);
}

sub printModOptions {
  my ($p_modOptions,$section)=@_;
  $section='' unless(defined $section);
  my @modOptions=@{$p_modOptions};
  my $nothingPrinted=1;
  foreach my $optionIdx (0..$#modOptions) {
    my $p_option=$modOptions[$optionIdx];
    next if(($p_option->{section} && lc($section) ne lc($p_option->{section}))
            || (! $p_option->{section} && $section ne ''));
    $nothingPrinted=0;
    my $comment="$p_option->{name}: $p_option->{description}";
    if($p_option->{type} eq "error") {
      printRes("\n#ERROR: $comment\n");
    }elsif($p_option->{type} eq "bool") {
      printRes("\n#$comment\n") if($generateComments);
      printRes("$p_option->{key}:$p_option->{default}|".(1-$p_option->{default})."\n");
    }elsif($p_option->{type} eq "list") {
      my @list=@{$p_option->{list}};
      printRes("\n#$comment\n") if($generateComments);
      my @values;
      foreach my $p_item (@list) {
        printRes("#  $p_item->{key}: $p_item->{name} ($p_item->{description})\n") if($generateComments);
        push(@values,$p_item->{key}) unless($p_item->{key} eq $p_option->{default});
      }
      my $valuesString=join("|",@values);
      printRes("$p_option->{key}:$p_option->{default}");
      printRes("|$valuesString") if($valuesString);
      printRes("\n");
    }elsif($p_option->{type} eq "number") {
      $comment.=" ($p_option->{numberMin}..$p_option->{numberMax}";
      my $stepString='';
      if($p_option->{numberStep} > 0) {
        if(getRangeStepFromBoundaries($p_option->{numberMin},$p_option->{numberMax}) != $p_option->{numberStep}) {
          $comment.=", step: $p_option->{numberStep}";
          $stepString="\%$p_option->{numberStep}";
        }
      }else{
        $comment.=', no quantization';
        $stepString="\%0";
      }
      $comment.=')';
      printRes("\n#$comment\n") if($generateComments);
      printRes("$p_option->{key}:$p_option->{default}|$p_option->{numberMin}-$p_option->{numberMax}$stepString\n");
    }elsif($p_option->{type} eq "string") {
      $comment.=" (max length: $p_option->{stringMaxLen})";
      printRes("\n#$comment\n") if($generateComments);
      printRes("$p_option->{key}:$p_option->{default}\n");
    }elsif($p_option->{type} eq "section") {
      my $sectionLine="#".('='x(length($comment)+2))."#\n";
      printRes("\n$sectionLine# $comment #\n#".('-'x(length($comment)+2))."#") if($generateComments);
      printModOptions($p_modOptions,$p_option->{key});
      printRes($sectionLine) if($generateComments);
    }else{
      printRes("\n#ERROR: unknown mod option !\n");
    }
  }
  printRes("\n") if($generateComments && $nothingPrinted && $section ne '');
}

sub formatNumber {
  my $n=shift;
  if(index($n,'.') != -1) {
    $n=sprintf('%.7f',$n);
    $n=~s/\.?0*$//;
  }
  $n=~s/^0+(\d.*)$/$1/;
  return $n;
}

for my $modNb (0..$#availableMods) {
  $unitsync->RemoveAllArchives();
  $unitsync->AddAllArchives($availableMods[$modNb]->{archive});
  my $modSection=$availableMods[$modNb]->{name};
  $modSection=~s/[^\w]/_/g;
  printRes("[$modSection]\n");
  if($spadsFormat) {
    printRes("description:Default $availableMods[$modNb]->{name} battle settings\n");
    printRes("resetoptions:1\n");
    printRes("disabledunits:-*\n");
    printRes("startpostype:2|0|1\n");
  }
  my $nbModOptions = $unitsync->GetModOptionCount();
  my @modOptions;
  for my $optionIdx (0..($nbModOptions-1)) {
    my %option=(name => $unitsync->GetOptionName($optionIdx),
                key => $unitsync->GetOptionKey($optionIdx),
                description => $unitsync->GetOptionDesc($optionIdx),
                type => $OPTION_TYPES[$unitsync->GetOptionType($optionIdx)],
                section => $unitsync->GetOptionSection($optionIdx),
                default => "");
    $option{description}=~s/\n/ /g;
    if($option{type} eq "bool") {
      $option{default}=$unitsync->GetOptionBoolDef($optionIdx);
    }elsif($option{type} eq "number") {
      $option{default}=formatNumber($unitsync->GetOptionNumberDef($optionIdx));
      $option{numberMin}=formatNumber($unitsync->GetOptionNumberMin($optionIdx));
      $option{numberMax}=formatNumber($unitsync->GetOptionNumberMax($optionIdx));
      $option{numberStep}=formatNumber($unitsync->GetOptionNumberStep($optionIdx));
    }elsif($option{type} eq "string") {
      $option{default}=$unitsync->GetOptionStringDef($optionIdx);
      $option{stringMaxLen}=$unitsync->GetOptionStringMaxLen($optionIdx);
    }elsif($option{type} eq "list") {
      $option{default}=$unitsync->GetOptionListDef($optionIdx);
      $option{listCount}=$unitsync->GetOptionListCount($optionIdx);
      $option{list}=[];
      for my $listIdx (0..($option{listCount}-1)) {
        my %item=(name => $unitsync->GetOptionListItemName($optionIdx,$listIdx),
                  description => $unitsync->GetOptionListItemDesc($optionIdx,$listIdx),
                  key => $unitsync->GetOptionListItemKey($optionIdx,$listIdx));
        $item{description}=~s/\n/ /g;
        push(@{$option{list}},\%item);
      }
    }
    push(@modOptions,\%option);
  }
  printModOptions(\@modOptions);
  printRes("\n");
  printRes("\n\n") if($generateComments);
}

$unitsync->UnInit();

$outputHandle->close() if(defined $outputHandle);
