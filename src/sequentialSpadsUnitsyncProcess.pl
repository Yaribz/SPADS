#!/usr/bin/env perl
#
# sequentialSpadsUnitsyncProcess.pl
#
# This program runs the command given as parameter in sequential unitsync mode,
# i.e. using the unitsync library in exclusive mode to avoid conflicts with
# SPADS and the game server processes.
# See the "sequentialUnitsync" global SPADS setting for more information:
# http://planetspads.free.fr/spads/doc/spadsDoc_All.html#global:sequentialUnitsync
#
# Copyright (C) 2023  Yann Riou <yaribzh@gmail.com>
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
# Version 0.1 (2023/11/08)
#

use warnings;
use strict;

use Fcntl qw':DEFAULT :flock';
use File::Spec::Functions qw'catfile';

invalidUsage('at least 2 parameters are required') unless(@ARGV > 1);

my $spadsVarDir=shift(@ARGV);
invalidUsage("\"$spadsVarDir\" is not a valid directory") unless(-d $spadsVarDir);

my $spadsUnitsyncLockFile=catfile($spadsVarDir,'unitsync.lock');

printTimestamped('Acquiring SPADS unitsync exclusive lock...');
open(my $lockFh,'>',$spadsUnitsyncLockFile)
    or die "Failed to open SPADS unitsync lock file \"$spadsUnitsyncLockFile\": $!\n";
flock($lockFh,LOCK_EX)
    or die "Failed to acquire SPADS unitsync exclusive lock: $!\n";

printTimestamped('Calling synchronized process...');
system {$ARGV[0]} @ARGV;
close($lockFh);

printTimestamped('End of synchronized process.');

sub invalidUsage { die "Invalid usage: $_[0]\n  Usage:  perl $0 <spadsVarDir> <command>\n" }

sub printTimestamped { print getFormattedTimestamp().' - '.$_[0]."\n" }

sub getFormattedTimestamp {
  my $timestamp=$_[0]//time();
  my @localtime=localtime($timestamp);
  $localtime[4]++;
  @localtime = map {sprintf('%02d',$_)} @localtime;
  return ($localtime[5]+1900)
      .'-'.$localtime[4]
      .'-'.$localtime[3]
      .' '.$localtime[2]
      .':'.$localtime[1]
      .':'.$localtime[0]
      .' '.getTzOffset($timestamp);
}

sub getTzOffset {
  my $t=shift;
  my ($lMin,$lHour,$lYear,$lYday)=(localtime($t))[1,2,5,7];
  my ($gMin,$gHour,$gYear,$gYday)=(gmtime($t))[1,2,5,7];
  my $deltaMin=($lMin-$gMin)+($lHour-$gHour)*60+( $lYear-$gYear || $lYday - $gYday)*24*60;
  my $sign=$deltaMin>=0?'+':'-';
  $deltaMin=abs($deltaMin);
  my ($deltaHour,$deltaHourMin)=(int($deltaMin/60),$deltaMin%60);
  return $sign.sprintf('%.2u%.2u',$deltaHour,$deltaHourMin);
}
