import perl
spads=perl.MySimplePlugin


pluginVersion='0.1'
requiredSpadsVersion='0.12.29'


def getVersion(pluginObject):
    return pluginVersion

def getRequiredSpadsVersion(pluginName):
    return requiredSpadsVersion


class MySimplePlugin:

    def __init__(self,context):
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)
