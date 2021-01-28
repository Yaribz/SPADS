# Import the perl module so we can call the SPADS Plugin API
import perl

# Import the datetime module so we can get current time for our !time command
import datetime

# perl.TimePlugin is the Perl representation of the TimePlugin plugin module
# We will use this object to call the plugin API
spads=perl.TimePlugin

# This is the first version of the plugin
pluginVersion='0.1'

# This plugin requires a SPADS version which supports Python plugins
# (only SPADS versions >= 0.12.29 support Python plugins)
requiredSpadsVersion='0.12.29'

# We define 2 global settings (mandatory for plugins implementing new commands):
# - commandsFile: name of the plugin commands rights configuration file (located in etc dir, same syntax as commands.conf)
# - helpFile: name of plugin commands help file (located in plugin dir, same syntax as help.dat)
globalPluginParams = { 'commandsFile': ['notNull'],
                       'helpFile': ['notNull'] }
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
class TimePlugin:

    # This is our constructor, called when the plugin is loaded by SPADS (mandatory callback)
    def __init__(self,context):
        
        # We declare our new command and the associated handler
        spads.addSpadsCommandHandler({'time': hSpadsTime})
        
        # We call the API function "slog" to log a notice message (level 3) when the plugin is loaded
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)

        
    # This is the callback called when the plugin is unloaded
    def onUnload(self,reason):

        # We remove our new command handler
        spads.removeSpadsCommandHandler(['time'])

        # We log a notice message when the plugin is unloaded
        spads.slog("Plugin unloaded",3)



# This is the handler for our new command
def hSpadsTime(source,user,params,checkOnly):

    # checkOnly is true if this is just a check for callVote command, not a real command execution
    if checkOnly :
        
        # time is a basic command, we have nothing to check in case of callvote
        return 1

    # We get current time using "now" function of datetime class from datetime module
    current_time = datetime.datetime.now()
    current_time_string = current_time.strftime("%H:%M:%S")

    # We call the API function "answer" to send back the response to the user who called the command
    # using same canal as he used (private message, battle lobby, in game message...)
    spads.answer("Current local time: %s" % current_time_string)
