# Import the perl module so we can call the SPADS Plugin API
import perl

# perl.MyConfigurablePlugin is the Perl representation of the MyConfigurablePlugin plugin module
# We will use this object to call the plugin API
spads=perl.MyConfigurablePlugin


# This is the first version of the plugin
pluginVersion='0.1'

# This plugin requires a SPADS version which supports Python plugins
# (only SPADS versions >= 0.12.29 support Python plugins)
requiredSpadsVersion='0.12.29'

# We define one global setting "MyGlobalSetting" and one preset setting "MyPresetSetting".
# Both are of type "notNull", which means any non-null value is allowed
# (check %paramTypes hash in SpadsConf.pm for a complete list of allowed setting types)
globalPluginParams = { 'MyGlobalSetting': ['notNull'] }
presetPluginParams = { 'MyPresetSetting': ['notNull'] }


# This is how SPADS gets our version number (mandatory callback)
def getVersion(pluginObject):
    return pluginVersion

# This is how SPADS determines if the plugin is compatible (mandatory callback)
def getRequiredSpadsVersion(pluginName):
    return requiredSpadsVersion

# This is how SPADS finds what settings we need in our configuration file (mandatory callback for configurable plugins)
def getParams(pluginName):
    return [ globalPluginParams , presetPluginParams ]



# This is the class implementing the plugin
class MyConfigurablePlugin:

    # This is our constructor, called when the plugin is loaded by SPADS (mandatory callback)
    def __init__(self,context):
        
        # We call the API function "slog" to log a notice message (level 3) when the plugin is loaded
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)
