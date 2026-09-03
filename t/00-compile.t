#!/usr/bin/perl
#
# Compile-check (perl -c) every Perl source under src/.
#
# SPADS depends on sibling modules (SimpleLog, SimpleEvent, SpringLobbyInterface,
# SpringAutoHostInterface, SpringLobbyProtocol) which are fetched at install time
# and are not vendored in this repository. To allow a syntax/compile check of the
# SPADS sources without a full installation, we generate minimal stubs for them.
#
# This verifies that the sources PARSE and COMPILE; it does not verify runtime
# behaviour. It is the cheapest possible regression net for a codebase that
# currently has no other automated tests.

use strict;
use warnings;
use Test::More;
use File::Temp qw'tempdir';
use File::Spec;
use FindBin;

my $srcDir = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, File::Spec->updir, 'src'));
my $repoDir = File::Spec->catdir($srcDir, File::Spec->updir);

my @stubModules = qw'SimpleLog SimpleEvent SpringLobbyInterface SpringAutoHostInterface SpringLobbyProtocol';

my $stubDir = tempdir(CLEANUP => 1);
for my $mod (@stubModules) {
  my $file = File::Spec->catfile($stubDir, "$mod.pm");
  open(my $fh, '>', $file) or die "Unable to create stub \"$file\": $!";
  print {$fh} "package $mod;\nsub new { bless {}, shift }\nsub AUTOLOAD { }\nsub DESTROY { }\n1;\n";
  close($fh);
}

my @sources = sort (glob("$srcDir/*.pl"), glob("$srcDir/*.pm"));
@sources or BAIL_OUT("No Perl sources found in \"$srcDir\"");

for my $src (@sources) {
  my $rel = File::Spec->abs2rel($src, $repoDir);
  my $output = '';
  my $pid = open(my $fh, '-|');
  defined $pid or die "fork failed: $!";
  if (! $pid) {
    open(STDERR, '>&', \*STDOUT);
    exec($^X, "-I$stubDir", "-I$srcDir", '-c', $src);
    exit 127;
  }
  {
    local $/;
    $output = <$fh>;
  }
  close($fh);
  ok($? == 0, "perl -c $rel") or diag($output);
}

done_testing();
