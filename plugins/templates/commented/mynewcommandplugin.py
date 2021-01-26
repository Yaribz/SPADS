# Import the perl module so we can call the SPADS Plugin API
import perl

# perl.MyNewCommandPlugin is the Perl representation of the MyNewCommandPlugin plugin module
# We will use this object to call the plugin API
spads=perl.MyNewCommandPlugin


# This is the first version of the plugin
pluginVersion='0.1'

# This plugin requires a SPADS version which supports Python plugins
# (only SPADS versions >= 0.12.29 support Python plugins)
requiredSpadsVersion='0.12.29'

# We define 2 global settings (mandatory for plugins implementing new commands):
# - commandsFile: name of the plugin commands rights configuration file (located in etc dir, same syntax as commands.conf)
# - helpFile: name of plugin commands help file (located in plugin dir, same syntax as help.dat)
globalPluginParams = { 'commandsFile': ['notNull'],
                       'helpFile': ['notNull'] };
presetPluginParams = None


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
class MyNewCommandPlugin:

    # This is our constructor, called when the plugin is loaded by SPADS (mandatory callback)
    def __init__(self,context):
        
        # We declare our new command and the associated handler
        spads.addSpadsCommandHandler({'myCommand': hMyCommand})
        
        # We call the API function "slog" to log a notice message (level 3) when the plugin is loaded
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)

        
    # This is the callback called when the plugin is unloaded
    def onUnload(self,reason):

        # We remove our new command handler
        spads.removeSpadsCommandHandler(['myCommand']);

        # We log a notice message when the plugin is unloaded
        spads.slog("Plugin unloaded",3);



# This is the handler for our new command
def hMyCommand(source,user,params,checkOnly):

    # checkOnly is true if this is just a check for callVote command, not a real command execution
    if checkOnly :
        
        # MyCommand is a basic command, we have nothing to check in case of callvote
        return 1
    
    # Fix strings received from Perl if needed
    # This is in case Inline::Python handles Perl strings as byte strings instead of normal strings
    # (this step can be skipped if your Inline::Python version isn't afffected by this bug)
    user=spads.fix_string(user)
    for i in range(len(params)):
        params[i]=spads.fix_string(params[i])
        
    # We join the parameters provided (if any), using ',' as delimiter
    paramsString = ','.join(params)

    # We log the command call as notice message
    spads.slog("User %s called command myCommand with parameter(s) \"%s\"" % (user,paramsString),3);
