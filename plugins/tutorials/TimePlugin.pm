# We define our plugin class
package TimePlugin;

# We use strict Perl syntax for cleaner code
use strict;

# We use the SPADS plugin API module
use SpadsPluginApi;

# This is the first version of the plugin
my $pluginVersion='0.1';

# This plugin is compatible with any SPADS version which supports plugins
# (only SPADS versions >= 0.11 support plugins)
my $requiredSpadsVersion='0.11';

# We define 2 global settings (mandatory for plugins implementing new commands):
# - commandsFile: name of the plugin commands rights configuration file (located in etc dir, same syntax as commands.conf)
# - helpFile: name of plugin commands help file (located in plugin dir, same syntax as help.dat)
my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
my %presetPluginParams;

# This is how SPADS gets our version number (mandatory callback)
sub getVersion { return $pluginVersion; }

# This is how SPADS determines if the plugin is compatible (mandatory callback)
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

# This is how SPADS finds what settings we need in our configuration file (mandatory callback for configurable plugins)
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

# This is our constructor, called when the plugin is loaded by SPADS (mandatory callback)
sub new {

  # Constructors take the class name as first parameter
  my $class=shift;

  # We create a hash which will contain the plugin data
  my $self = {};

  # We instanciate this hash as an object of the given class
  bless($self,$class);

  # We declare our new command and the associated handler
  addSpadsCommandHandler({time => \&hSpadsTime});

  # We call the API function "slog" to log a notice message (level 3) when the plugin is loaded
  slog("Plugin loaded (version $pluginVersion)",3);

  # We return the instantiated plugin
  return $self;

}

# This is the callback called when the plugin is unloaded
sub onUnload {

  # We remove our new command handler
  removeSpadsCommandHandler(['time']);

  # We log a notice message when the plugin is unloaded
  slog("TimePlugin plugin unloaded",3);

}

# This is the handler for our new command
sub hSpadsTime {
  my ($source,$user,$p_params,$checkOnly)=@_;
  
  # time is a basic command, we have nothing to check in case of callvote
  return 1 if($checkOnly);
  
  my @time = localtime();
  @time = map(sprintf("%02d",$_),@time);
  
  answer("Current local time: $time[2]:$time[1]:$time[0]");
}

1;
