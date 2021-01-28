# Import the perl module so we can call the SPADS Plugin API
import perl

# Import the regular expression module to check for forbidden words
import re

# perl.ForbiddenWords is the Perl representation of the ForbiddenWords plugin module
# We will use this object to call the plugin API
spads=perl.ForbiddenWords

# This is the first version of the plugin
pluginVersion='0.1'

# This plugin requires a SPADS version which supports Python plugins
# (only SPADS versions >= 0.12.29 support Python plugins)
requiredSpadsVersion='0.12.29'

# We define one global setting "words" and one preset setting "immuneLevel".
# "words" has no type associated (no restriction on allowed values)
# "immuneLevel" must be an integer or an integer range
# (check %paramTypes hash in SpadsConf.pm for a complete list of allowed
# setting types)
globalPluginParams = { 'words': [] }
presetPluginParams = { 'immuneLevel': ['integer','integerRange'] }


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
class ForbiddenWords:

    # This is our constructor, called when the plugin is loaded by SPADS (mandatory callback)
    def __init__(self,context):
        
        # We call the API function "slog" to log a notice message (level 3) when the plugin is loaded
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)

        # We set up a lobby command handler on SAIDBATTLE
        spads.addLobbyCommandHandler({'SAIDBATTLE': hLobbySaidBattle})


    # This callback is called each time we (re)connect to the lobby server
    def onLobbyConnected(self,lobbyInterface):
        
        # When we are disconnected from the lobby server, all lobby command
        # handlers are automatically removed, so we (re)set up our command
        # handler here.
        spads.addLobbyCommandHandler({'SAIDBATTLE': hLobbySaidBattle})


    # This callback is called when the plugin is unloaded
    def onUnload(self,reason):
        
        # We remove our lobby command handler when the plugin is unloaded
        spads.removeLobbyCommandHandler(['SAIDBATTLE'])


# This is the handler we set up on SAIDBATTLE lobby command.
# It is called each time a player says something in the battle lobby.
#   command is the lobby command name (SAIDBATTLE)
#   user is the name of the user who said something in the battle lobby
#   message is the message said in the battle lobby
def hLobbySaidBattle(command,user,message):
    
    # First we "fix" strings received from Perl in case
    # the Inline::Python module transmits them as byte strings
    (user,message)=spads.fix_string(user,message)
    
    # Here we check it's not a message from SPADS (so we don't kick ourself)
    spadsConf = spads.getSpadsConf()
    if user == spadsConf['lobbyLogin']:
        return
    
    # Then we check the user isn't a privileged user
    # (autohost access level >= immuneLevel)
    pluginConf = spads.getPluginConf()
    if int(spads.getUserAccessLevel(user)) >= int(pluginConf['immuneLevel']):
        return
    
    # We put the forbidden words in a list
    forbiddenWords = pluginConf['words'].split(';')
            
    # We test each forbidden word
    for forbiddenWord in forbiddenWords:
        
        # If the message contains the forbidden word (case insensitive)
        if re.search(r'\b' + re.escape(forbiddenWord) + r'\b',message,re.IGNORECASE):
            
            # Then we kick the user from the battle lobby
            spads.sayBattle("Kicking %s from battle (watch your language!)" % user)
            spads.queueLobbyCommand(["KICKFROMBATTLE",user])
                    
            # We quit the foreach loop (no need to test other forbidden word)
            break
