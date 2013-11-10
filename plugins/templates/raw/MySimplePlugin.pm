package MySimplePlugin;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

1;
