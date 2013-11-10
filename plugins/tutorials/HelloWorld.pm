# We define our plugin class
package HelloWorld;

# We use strict Perl syntax for cleaner code
use strict;

# We use the SPADS plugin API module
use SpadsPluginApi;

# We don't want warnings when the plugin is reloaded
no warnings 'redefine';

# This is the first version of the plugin
my $pluginVersion='0.1';

# This plugin is compatible with any SPADS version which supports plugins
# (only SPADS versions >= 0.11 support plugins)
my $requiredSpadsVersion='0.11';

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
  slog("HelloWorld plugin loaded (version $pluginVersion)",3);

  # We return the instantiated plugin
  return $self;

}

sub onPrivateMsg {
  
  # $self is the plugin object (first parameter of all plugin callbacks)
  # $userName is the name of the user sending the private message
  # $message is the message sent by the user
  my ($self,$userName,$message)=@_;
  
  # We check the message sent by the user is "Hello"
  if($message eq 'Hello') {
    
    # We send our wonderful Hello World message
    sayPrivate($userName,'Hello World');
    
  }
  
  # We return 0 because we don't want to filter out private messages
  # for other SPADS processing
  return 0;
  
}

1;
