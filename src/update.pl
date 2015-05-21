#!/usr/bin/perl -w
#
# This program update SPADS components in current directory from remote repository.
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

# Version 0.8b (2015/05/20)

use strict;

use SimpleLog;
use SpadsUpdater;

my $perlExecPrefix="";
my $win=$^O eq 'MSWin32' ? 1 : 0;
$perlExecPrefix="perl " if($win);

my $sLog=SimpleLog->new(logFiles => [""],
                        logLevels => [4],
                        useANSICodes => [-t STDOUT ? 1 : 0],
                        useTimestamps => [-t STDOUT ? 0 : 1],
                        prefix => "[Update] ");

sub invalidUsage {
  $sLog->log("Invalid usage",1);
  print "Usage:\n";
  print "  $perlExecPrefix$0 <release> [-v] [-f] -a\n";
  if($win) {
    print "  $perlExecPrefix$0 <release> [-v] [-f] -u\n";
    print "  $perlExecPrefix$0 <release> <springVersion> [-v] -s\n";
    print "  $perlExecPrefix$0 <release> <springVersion> [-v] [-f] -A\n";
  }
  if($win) {
    print "  $perlExecPrefix$0 <release> [<springVersion>] [-v] [-f] <packageName> [<packageName2> [<packageName3> ...]]\n";
  }else{
    print "  $perlExecPrefix$0 <release> [-v] [-f] <packageName> [<packageName2> [<packageName3> ...]]\n";
  }
  print "      <release>: release to update (\"stable\", \"testing\", \"unstable\" or \"contrib\")\n";
  print "      <springVersion>: Major Spring version (integer, example: \"95\")\n" if($win);
  print "      -v: verbose mode\n";
  print "      -f: force package update (even if it requires manual updates of configuration files)\n";
  print "      -a: updates all SPADS packages\n";
  if($win) {
    print "      -u: updates all Spring unitsync binaries\n";
    print "      -s: updates all Spring dedicated server binaries\n";
    print "      -A: updates all SPADS packages and Spring binaries\n";
  }
  print "      <packageName>: package to update\n";
  exit 1;
}

invalidUsage() if($#ARGV < 1 || ! grep {/^$ARGV[0]$/} qw/stable testing unstable contrib/);
my $release=$ARGV[0];

my %packages;
my ($verbose,$force,$syncedSpringVersion)=(0,0,'UNKNOWN');
for my $argNb (1..$#ARGV) {
  if($ARGV[$argNb] eq "-v") {
    $verbose=1;
  }elsif($ARGV[$argNb] eq "-f") {
    $force=1;
  }elsif($ARGV[$argNb] eq "-a") {
    %packages=('getDefaultModOptions.pl' => 1,
               'help.dat' => 1,
               'helpSettings.dat' => 1,
               'SpringAutoHostInterface.pm' => 1,
               'SpringLobbyInterface.pm' => 1,
               'SimpleLog.pm' => 1,
               'spads.pl' => 1,
               'SpadsConf.pm' => 1,
               'spadsInstaller.pl' => 1,
               'SpadsPluginApi.pm' => 1,
               'SpadsUpdater.pm' => 1,
               'update.pl' => 1,
               'argparse.py' => 1,
               'replay_upload.py' => 1);
  }elsif($ARGV[$argNb] eq "-u") {
    if(! $win) {
      $sLog->log("The \"-u\" option is only available on Windows",1);
      invalidUsage();
    }
    %packages=('PerlUnitSync.pm' => 1,
               'PerlUnitSync.dll' => 1);
  }elsif($ARGV[$argNb] eq "-s") {
    if(! $win) {
      $sLog->log("The \"-s\" option is only available on Windows",1);
      invalidUsage();
    }
    %packages=('spring-dedicated.exe' => 1,
               'spring-headless.exe' => 1);
  }elsif($ARGV[$argNb] eq "-A") {
    if(! $win) {
      $sLog->log("The \"-A\" option is only available on Windows",1);
      invalidUsage();
    }
    %packages=('getDefaultModOptions.pl' => 1,
               'help.dat' => 1,
               'helpSettings.dat' => 1,
               'SpringAutoHostInterface.pm' => 1,
               'SpringLobbyInterface.pm' => 1,
               'SimpleLog.pm' => 1,
               'spads.pl' => 1,
               'SpadsConf.pm' => 1,
               'spadsInstaller.pl' => 1,
               'SpadsPluginApi.pm' => 1,
               'SpadsUpdater.pm' => 1,
               'update.pl' => 1,
               'argparse.py' => 1,
               'replay_upload.py' => 1,
               'PerlUnitSync.pm' => 1,
               'PerlUnitSync.dll' => 1,
               'spring-dedicated.exe' => 1,
               'spring-headless.exe' => 1);
  }elsif($ARGV[$argNb] =~ /^\d+$/) {
    $syncedSpringVersion=$ARGV[$argNb];
  }else{
    $packages{$ARGV[$argNb]}=1;
  }
}

my @packs=keys %packages;
invalidUsage() unless(@packs);
invalidUsage() if((exists $packages{'spring-dedicated.exe'} || exists $packages{'spring-headless.exe'}) && $syncedSpringVersion eq 'UNKNOWN');

my $updaterLog=SimpleLog->new(logFiles => [""],
                              logLevels => [4],
                              useANSICodes => [-t STDOUT ? 1 : 0],
                              useTimestamps => [-t STDOUT ? 0 : 1],
                              prefix => "[SpadsUpdater] ");

my $updater=SpadsUpdater->new(sLog => $updaterLog,
                              localDir => ".",
                              repository => "http://planetspads.free.fr/spads/repository",
                              release => $release,
                              packages => \@packs,
                              syncedSpringVersion => $syncedSpringVersion);

my $updaterRc=$updater->update($verbose,$force);
if($updaterRc < 0) {
  $sLog->log("Unable to update package(s)",1);
  exit 1;
}
if($updaterRc > 0) {
  $sLog->log("$updaterRc package(s) updated for $release release.",3);
}else{
  $sLog->log("No update available for $release release.",3);
}
