# We define our plugin class
package MySimplePlugin;

# We use strict Perl syntax for cleaner code
use strict;

# We use the SPADS plugin API module
use SpadsPluginApi;

# This is the first version of the plugin
my $pluginVersion='0.1';

# This plugin is compatible with any SPADS version which supports plugins
# (only SPADS versions >= 0.11.5 support plugins)
my $requiredSpadsVersion='0.11.5';

# This is how SPADS gets our version number (mandatory callback)
sub getVersion { return $pluginVersion; }

# This is how SPADS determines if the plugin is compatible (mandatory callback)
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

# This is our constructor, called when the plugin is loaded by SPADS (mandatory callback)
sub new {

  # Constructors take the class name as first parameter
  my $class=shift;

  # We create a hash which will contain the plugin data
  my $self = {};

  # We instanciate this hash as an object of the given class
  bless($self,$class);

  # We call the API function "slog" to log a notice message (level 3) when the plugin is loaded
  slog("Plugin loaded (version $pluginVersion)",3);

  # We return the instantiated plugin
  return $self;

}

1;
