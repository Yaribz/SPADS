#!/usr/bin/perl -w
#
# This program prints the default mod options of each Spring mod installed,
# using the unitsync library.
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

# Version 0.4d (2014/01/05)

use strict;

use Cwd;
use FileHandle;

my %optionTypes = (
  0 => "error",
  1 => "bool",
  2 => "list",
  3 => "number",
  4 => "string",
  5 => "section"
);

my $generateComments=0;
my $spadsFormat=0;
my $dataDir="";
my $outputFile="";
my $outputHandle;

if($#ARGV >= 0) {
  my $nextArgIsOutputFile=0;
  foreach my $arg (@ARGV) {
    if($nextArgIsOutputFile) {
      $nextArgIsOutputFile=0;
      $outputFile=$arg;
      next;
    }
    if($arg eq "-c" || $arg eq "--comments") {
      $generateComments=1;
    }elsif($arg eq "-s" || $arg eq "--spads") {
      $spadsFormat=1;
    }elsif($arg eq '-o') {
      $nextArgIsOutputFile=1;
    }elsif($arg =~ /^--output=(.+)$/) {
      $outputFile=$1;
    }elsif(-d $arg) {
      $dataDir=$arg;
    }else{
      print "Usage: $0 [-c|--comments] [-s|--spads] [-o <file>|--output=<file>] [<springDataDir>]\n";
      print "  -c|--comments             : generates comments explaining each mod option\n";
      print "  -s|--spads                : generates output in SPADS format (ready to copy-paste in battlePresets.conf file\n";
      print "  -o <file>|--output=<file> : writes result into <file> instead of stdout\n";
      print "  <springDataDir> : Spring data directory containing the \"games\" or \"packages\" folders\n";
      exit;
    }
  }
}

if($outputFile ne "") {
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

if($dataDir ne "") {
  $ENV{SPRING_DATADIR}=$dataDir;
  $ENV{SPRING_WRITEDIR}=$dataDir;
  if($^O eq 'MSWin32') {
    my $pwd=cwd();
    $ENV{PATH}="$ENV{PATH};$pwd;$dataDir";
    push(@INC,$pwd);
    chdir($dataDir);
  }
} 

eval "use PerlUnitSync";
if ($@) {
  print "ERROR - Unable to load PerlUnitSync module ($@)\n";
  if($dataDir eq '') {
    print "ERROR - Try specifying the Spring data directory as command line parameter\n";
  }else{
    print "ERROR - The unitsync library must be available in your path or in the Sring data directory specified as parameter\n";
  }
  exit 1;
}

if(! PerlUnitSync::Init(0,0)) {
  print("ERROR - Unable to initialize UnitSync library (try specifying the Spring data directory as command line parameter)\n");
  exit 0;
}

my $nbMods = PerlUnitSync::GetPrimaryModCount();
if(! $nbMods) {
  print("ERROR - No Spring mod found\n");
  PerlUnitSync::UnInit();
  exit 0;
}

my @availableMods=();
for my $modNb (0..($nbMods-1)) {
  my $nbInfo = PerlUnitSync::GetPrimaryModInfoCount($modNb);
  my $modName='';
  for my $infoNb (0..($nbInfo-1)) {
    next if(PerlUnitSync::GetInfoKey($infoNb) ne 'name');
    $modName=PerlUnitSync::GetInfoValueString($infoNb);
    last;
  }
  my $modArchive = PerlUnitSync::GetPrimaryModArchive($modNb);
  $availableMods[$modNb]={name=>$modName,archive=>$modArchive};
}

sub printModOptions {
  my ($p_modOptions,$section)=@_;
  $section='' unless(defined $section);
  my @modOptions=@{$p_modOptions};
  foreach my $optionIdx (0..$#modOptions) {
    my $p_option=$modOptions[$optionIdx];
    next if(($p_option->{section} && lc($section) ne lc($p_option->{section}))
            || (! $p_option->{section} && $section ne ''));
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
      $comment.=" ($p_option->{numberMin}..$p_option->{numberMax})";
      printRes("\n#$comment\n") if($generateComments);
      printRes("$p_option->{key}:$p_option->{default}");
      printRes("|$p_option->{numberMin}-$p_option->{numberMax}") if($p_option->{numberMin} =~ /^-?\d+(?:\.\d)?$/ && $p_option->{numberMax} =~ /^-?\d+(?:\.\d)?$/);
      printRes("\n");
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
}

sub formatNumber {
  my $n=shift;
  $n=sprintf("%.1f",$n) if($n=~/^-?\d+\.\d+$/);
  return $n;
}

for my $modNb (0..$#availableMods) {
  PerlUnitSync::RemoveAllArchives();
  PerlUnitSync::AddAllArchives($availableMods[$modNb]->{archive});
  my $modSection=$availableMods[$modNb]->{name};
  $modSection=~s/[^\w]/_/g;
  printRes("[$modSection]\n");
  if($spadsFormat) {
    printRes("description:Default $availableMods[$modNb]->{name} battle settings\n");
    printRes("resetoptions:1\n");
    printRes("disabledunits:-*\n");
    printRes("startpostype:2|0|1\n");
  }
  my $nbModOptions = PerlUnitSync::GetModOptionCount();
  my @modOptions;
  for my $optionIdx (0..($nbModOptions-1)) {
    my %option=(name => PerlUnitSync::GetOptionName($optionIdx),
                key => PerlUnitSync::GetOptionKey($optionIdx),
                description => PerlUnitSync::GetOptionDesc($optionIdx),
                type => $optionTypes{PerlUnitSync::GetOptionType($optionIdx)},
                section => PerlUnitSync::GetOptionSection($optionIdx),
                default => "");
    $option{description}=~s/\n/ /g;
    if($option{type} eq "bool") {
      $option{default}=PerlUnitSync::GetOptionBoolDef($optionIdx);
    }elsif($option{type} eq "number") {
      $option{default}=formatNumber(PerlUnitSync::GetOptionNumberDef($optionIdx));
      $option{numberMin}=formatNumber(PerlUnitSync::GetOptionNumberMin($optionIdx));
      $option{numberMax}=formatNumber(PerlUnitSync::GetOptionNumberMax($optionIdx));
    }elsif($option{type} eq "string") {
      $option{default}=PerlUnitSync::GetOptionStringDef($optionIdx);
      $option{stringMaxLen}=PerlUnitSync::GetOptionStringMaxLen($optionIdx);
    }elsif($option{type} eq "list") {
      $option{default}=PerlUnitSync::GetOptionListDef($optionIdx);
      $option{listCount}=PerlUnitSync::GetOptionListCount($optionIdx);
      $option{list}=[];
      for my $listIdx (0..($option{listCount}-1)) {
        my %item=(name => PerlUnitSync::GetOptionListItemName($optionIdx,$listIdx),
                  description => PerlUnitSync::GetOptionListItemDesc($optionIdx,$listIdx),
                  key => PerlUnitSync::GetOptionListItemKey($optionIdx,$listIdx));
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

PerlUnitSync::UnInit();

$outputHandle->close() if(defined $outputHandle);
