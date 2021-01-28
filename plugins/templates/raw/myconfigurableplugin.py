import perl
spads=perl.MyConfigurablePlugin


pluginVersion='0.1'
requiredSpadsVersion='0.12.29'

globalPluginParams = { 'MyGlobalSetting': ['notNull'] }
presetPluginParams = { 'MyPresetSetting': ['notNull'] }


def getVersion(pluginObject):
    return pluginVersion

def getRequiredSpadsVersion(pluginName):
    return requiredSpadsVersion

def getParams(pluginName):
      return [ globalPluginParams , presetPluginParams ]

  
class MyConfigurablePlugin:

    def __init__(self,context):
        spads.slog("Plugin loaded (version %s)" % pluginVersion,3)
