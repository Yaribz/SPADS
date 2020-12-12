package MyNewCommandPlugin;

use strict;

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
my %presetPluginParams;

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  addSpadsCommandHandler({myCommand => \&hMyCommand});
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  removeSpadsCommandHandler(['myCommand']);
  slog("Plugin unloaded",3);
}

sub hMyCommand {
  my ($source,$user,$p_params,$checkOnly)=@_;
  return 1 if($checkOnly);
  my $paramsString=join(',',@{$p_params});
  slog("User $user called command myCommand with parameter(s) \"$paramsString\"",3);
}

1;
