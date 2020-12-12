package MyConfigurablePlugin;

use strict;

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

my %globalPluginParams = ( MyGlobalSetting => ['notNull'] );
my %presetPluginParams = ( MyPresetSetting => ['notNull'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

1;
