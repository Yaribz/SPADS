package SignalReloadConf;

use strict;

use File::Spec::Functions 'catfile';

use SpadsPluginApi;

my $pluginVersion='0.2';
my $requiredSpadsVersion='0.13.29';

my %VALID_SIGNALS = map {$_ => 1} (qw'USR1 USR2 HUP');

my %globalPluginParams = ( signal => [sub {$VALID_SIGNALS{uc($_[0])}}] );
my %presetPluginParams;

my $SPADS_PID;
my $PID_FILE;

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

sub new {
  my ($class,$context)=@_;
  if($^O eq 'MSWin32') {
    slog('This plugin is not supported on Windows systems',1);
    return undef;
  }
  $SPADS_PID=$$;
  my $self = { signal => undef };
  bless($self,$class);
  return undef unless($self->onReloadConf());
  slog("Signal $self->{signal} registered for SPADS configuration reload",4);
  slog("Plugin loaded (version $pluginVersion) [$context]",3);
  return $self;
}

sub onReloadConf {
  my $self=shift;
  
  my $signal=uc(getPluginConf()->{signal});
  if(defined $self->{signal}) {
    return 1 if($self->{signal} eq $signal);
    unlink($PID_FILE);
    SimpleEvent::unregisterSignal($self->{signal});
    undef $self->{signal};
  }
  
  if(! SimpleEvent::registerSignal($signal,\&reloadConfKeepSettings)) {
    slog("Failed to register signal \"$signal\"",1);
    return 0;
  }
  
  $self->{signal}=$signal;
  $PID_FILE=catfile(getSpadsConf()->{instanceDir},'SignalReloadConf.pid');
  
  if(open(my $pidFh,'>',$PID_FILE)) {
    print $pidFh $SPADS_PID;
    close($pidFh);
  }else{
    slog("Unable to write PID file \"$PID_FILE\" ($!)",1);
  }
  
  return 1;
}

sub reloadConfKeepSettings {
  slog('SIG'.getPlugin()->{signal}.' received, reloading SPADS configuration (keeping current active settings)',4);
  ::pingIfNeeded();
  $::spads->dumpDynamicData();
  $::timestamps{dataDump}=time;
  my $newSpads=SpadsConf->new($ARGV[0],$::spads->{log},\%::confMacros,$::spads);
  if(! $newSpads) {
    slog('Unable to reload SPADS configuration',1);
    return 0;
  }
  my ($defaultPreset,$currentPreset)=@{$newSpads->{conf}}{'defaultPreset','preset'};
  foreach my $pluginName (keys %{$::spads->{pluginsConf}}) {
    next if(exists $newSpads->{pluginsConf}{$pluginName});
    if(! $newSpads->loadPluginConf($pluginName)) {
      slog("Unable to reload SPADS configuration (failed to reload $pluginName plugin configuration)",1);
      return 0;
    }
    $newSpads->applyPluginPreset($pluginName,$defaultPreset);
    $newSpads->applyPluginPreset($pluginName,$currentPreset) unless($currentPreset eq $defaultPreset);
    $newSpads->{pluginsConf}{$pluginName}{conf}=$::spads->{pluginsConf}{$pluginName}{conf};
  }
  $::spads=$newSpads;
  ::postReloadConfActions(sub {slog($_[0],3)},1);
  return 1;
}

sub onUnload {
  my ($self,$reason)=@_;

  if(defined $self->{signal}) {
    unlink($PID_FILE);
    SimpleEvent::unregisterSignal($self->{signal});
  }
  
  slog("Plugin unloaded [$reason]",3);
}

# END block is executed in all forked processes...
END { unlink($PID_FILE) if($$ == $SPADS_PID && defined $PID_FILE) }

1;
