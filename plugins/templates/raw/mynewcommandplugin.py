import perl
spads=perl.MyNewCommandPlugin


pluginVersion='0.1'
requiredSpadsVersion='0.12.29'

globalPluginParams = { 'commandsFile': ['notNull'],
                       'helpFile': ['notNull'] }
presetPluginParams = None


def getVersion(pluginObject):
    return pluginVersion

def getRequiredSpadsVersion(pluginName):
    return requiredSpadsVersion

def getParams(pluginName):
    return [ globalPluginParams , presetPluginParams ]


class MyNewCommandPlugin:

    def __init__(self,context):
        spads.addSpadsCommandHandler({'myCommand': hMyCommand})
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)

    def onUnload(self,reason):
        spads.removeSpadsCommandHandler(['myCommand'])
        spads.slog("Plugin unloaded",3)


def hMyCommand(source,user,params,checkOnly):
    if checkOnly :
        return 1
    user=spads.fix_string(user)
    for i in range(len(params)):
        params[i]=spads.fix_string(params[i])
    paramsString = ','.join(params)
    spads.slog("User %s called command myCommand with parameter(s) \"%s\"" % (user,paramsString),3)
