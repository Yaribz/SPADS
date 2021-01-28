# Import the perl module so we can call the SPADS Plugin API
import perl

# perl.HelloWorld is the Perl representation of the HelloWorld plugin module
# We will use this object to call the plugin API
spads=perl.HelloWorld


# This is the first version of the plugin
pluginVersion='0.1'

# This plugin requires a SPADS version which supports Python plugins
# (only SPADS versions >= 0.12.29 support Python plugins)
requiredSpadsVersion='0.12.29'


# This is how SPADS gets our version number (mandatory callback)
def getVersion(pluginObject):
    return pluginVersion

# This is how SPADS determines if the plugin is compatible (mandatory callback)
def getRequiredSpadsVersion(pluginName):
    return requiredSpadsVersion



# This is the class implementing the plugin
class HelloWorld:

    # This is our constructor, called when the plugin is loaded by SPADS (mandatory callback)
    def __init__(self,context):
        
        # We call the API function "slog" to log a notice message (level 3) when the plugin is loaded
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)

    # This is the callback called each time SPADS receives a private message
    #   self is the plugin object (first parameter of all plugin callbacks)
    #   userName is the name of the user sending the private message
    #   message is the message sent by the user
    def onPrivateMsg(self,userName,message):
    
        # Here we "fix" strings received from Perl in case
        # the Inline::Python module transmits them as byte strings
        (userName,message)=spads.fix_string(userName,message)
   
        # We check the message sent by the user is "Hello"
        if message == 'Hello':
            
            # We send our wonderful Hello World message
            spads.sayPrivate(userName,'Hello World')
        
        # We return 0 because we don't want to filter out private messages
        # for other SPADS processing
        return 0
