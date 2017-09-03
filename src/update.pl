#!/usr/bin/perl -w
#
# This program update SPADS components in current directory from remote repository.
#
# Copyright (C) 2008-2017  Yann Riou <yaribzh@gmail.com>
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

# Version 0.11 (2017/08/18)

use strict;

use FindBin;
use List::Util 'first';

use lib $FindBin::Bin;

use SimpleLog;
use SpadsUpdater;

sub any (&@) { my $c = shift; return defined first {&$c} @_; }
sub all (&@) { my $c = shift; return ! defined first {! &$c} @_; }
sub none (&@) { my $c = shift; return ! defined first {&$c} @_; }
sub notall (&@) { my $c = shift; return defined first {! &$c} @_; }

my $win=$^O eq 'MSWin32' ? 1 : 0;
my $macOs=$^O eq 'darwin';

my $sLog=SimpleLog->new(logFiles => [""],
                        logLevels => [4],
                        useANSICodes => [-t STDOUT ? 1 : 0],
                        useTimestamps => [-t STDOUT ? 0 : 1],
                        prefix => "[Update] ");

sub invalidUsage {
  $sLog->log("Invalid usage",1);

  print <<EOM;

Usage:
  perl $0 <release> [-f] -a
  perl $0 <release> [-f] <packageName> [<packageName2> [<packageName3> ...]]
      <release>: SPADS release to update ("stable", "testing", "unstable" or "contrib")
      -f: force update (even if it requires manual updates of configuration files)
      -a: update all SPADS packages
      <packageName>: SPADS package to update

EOM

  exit 1;
}

invalidUsage() if($#ARGV < 1 || none {$ARGV[0] eq $_} qw/stable testing unstable contrib/);
my $release=$ARGV[0];

my %packages;
my $force=0;
for my $argNb (1..$#ARGV) {
  if($ARGV[$argNb] eq '-f') {
    $force=1;
  }elsif($ARGV[$argNb] eq '-a') {
    %packages=('getDefaultModOptions.pl' => 1,
               'help.dat' => 1,
               'helpSettings.dat' => 1,
               'SpringAutoHostInterface.pm' => 1,
               'SpringLobbyInterface.pm' => 1,
               'SimpleEvent.pm' => 1,
               'SimpleLog.pm' => 1,
               'spads.pl' => 1,
               'SpadsConf.pm' => 1,
               'spadsInstaller.pl' => 1,
               'SpadsPluginApi.pm' => 1,
               'SpadsUpdater.pm' => 1,
               'update.pl' => 1,
               'argparse.py' => 1,
               'replay_upload.py' => 1);
    if($win) {
      $packages{'PerlUnitSync.pm'}=1;
      $packages{'7za.exe'}=1;
    }elsif(! $macOs) {
      $packages{'7za'}=1;
    }
  }else{
    $packages{$ARGV[$argNb]}=1;
  }
}

my @packs=keys %packages;
invalidUsage() unless(@packs);

my $updaterLog=SimpleLog->new(logFiles => [''],
                              logLevels => [4],
                              useANSICodes => [-t STDOUT ? 1 : 0],
                              useTimestamps => [-t STDOUT ? 0 : 1],
                              prefix => '[SpadsUpdater] ');

my $updater=SpadsUpdater->new(sLog => $updaterLog,
                              repository => 'http://planetspads.free.fr/spads/repository',
                              release => $release,
                              packages => \@packs);

my $updaterRc=$updater->update($force,$force);
if($updaterRc < 0) {
  $sLog->log('Unable to update package(s)',1);
  exit 1;
}
if($updaterRc > 0) {
  $sLog->log("$updaterRc package(s) updated for $release release.",3);
}else{
  $sLog->log("No update available for $release release.",3);
}

exit 0;
