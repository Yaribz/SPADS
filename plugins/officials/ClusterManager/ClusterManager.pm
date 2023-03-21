package ClusterManager;

use strict;

use Fcntl qw':DEFAULT :flock';
use File::Copy qw'copy move';
use File::Spec::Functions qw'catdir catfile';
use List::Util qw'all any none sum';
use Storable qw'nstore retrieve';
use Text::ParseWords 'shellwords';

use SpadsPluginApi;

my $pluginVersion='0.6';
my $requiredSpadsVersion='0.13.0';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'],
                           maxInstances => ['nonNullInteger'],
                           maxInstancesPublic => ['integer'],
                           maxInstancesPrivate => ['integer'],
                           removeSpareInstanceDelay => ['integer'],
                           removePrivateInstanceDelay => ['nonNullInteger'],
                           startingInstanceTimeout => ['integer'],
                           offlineInstanceTimeout => ['integer'],
                           orphanInstanceTimeout => ['integer'],
                           baseGamePort => ['port'],
                           baseAutoHostPort => ['port'],
                           clusters => [],
                           createNewConsoles => ['bool'],
                           autoRegister => ['bool2'],
                           shareArchiveCache => ['bool'] );
my %presetPluginParams = ( maxInstancesInCluster => ['integer'],
                           maxInstancesInClusterPublic => ['integer'],
                           maxInstancesInClusterPrivate => ['integer'],
                           targetSpares => ['integer'],
                           nameTemplate => ['notNull'],
                           lobbyPassword => ['password','null'],
                           confMacros => [],
                           confMacrosPublic => [],
                           confMacrosPrivate => [] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }
sub getDependencies { return ('AutoRegister'); }

sub new {
  my ($class,$context)=@_;

  my $pidDir=catdir(getSpadsConf()->{varDir},'ClusterManager');
  if(! -d $pidDir && ! mkdir($pidDir)) {
    slog("Unable to create directory for persistent plugin data \"$pidDir\"",1);
    quit(1,'unable to load ClusterManager plugin') if($context eq 'autoload');
    return undef;
  }

  my $r_confMacros=getConfMacros();
  my $isManager = exists $r_confMacros->{ManagerName} ? 0 : 1;
  my $self = { isManager => $isManager };

  if($isManager) {
    # Manager initialization
    slog('Loading plugin in manager mode...',3);
    if(getPluginConf()->{autoRegister} < 2) {
      getPlugin('AutoRegister')->disable();
    }else{
      getPlugin('AutoRegister')->enable();
    }
    if(! onReloadConf($self)) {
      quit(1,'unable to load ClusterManager plugin') if($context eq 'autoload');
      return undef;
    }
    closeBattle('Cluster Manager mode',1);
    my $lockFile=catfile($pidDir,'ClusterManager.lock');
    if(open(my $lockFh,'>',$lockFile)) {
      if(! flock($lockFh, LOCK_EX|LOCK_NB)) {
        slog("Another manager instance is running in same directory ($pidDir)",1);
        quit(1,'unable to load ClusterManager plugin') if($context eq 'autoload');
        return undef;
      }
      $self->{lock}=$lockFh;
    }else{
      slog("Unable to open ClusterManager lock file \"$lockFile\"",1);
      quit(1,'unable to load ClusterManager plugin') if($context eq 'autoload');
      return undef;
    }
    my $r_existingAccounts={};
    my $existingAccountsFile=catfile($pidDir,'existingAccounts.dat');
    if(-f $existingAccountsFile) {
      $r_existingAccounts=retrieve($existingAccountsFile);
      if(! defined $r_existingAccounts) {
        slog("Unable to load existing accounts data from file \"$existingAccountsFile\"",1);
        quit(1,'unable to load ClusterManager plugin') if($context eq 'autoload');
        return undef;
      }
    }
    $self->{existingAccounts}=$r_existingAccounts;
    $self->{setBotModeSent}={};
    if(getLobbyState() > 3 && ! c_lobbyConnectedInitializations($self)) {
      quit(1,'unable to load ClusterManager plugin') if($context eq 'autoload');
      return undef;
    }
    addTimer('checkClusters',1,1,\&checkClusters);
    addSpadsCommandHandler({privatehost => \&hPrivateHost,
                            listclusters => \&hListClusters,
                            clusterconfig => \&hClusterConfig,
                            clusterstatus => \&hClusterStatus,
                            clusterstats => \&hClusterStats,
                            listinstances => \&hListInstances});
    
  }else{
    # Slave instance initialization
    slog('Loading plugin in slave instance mode...',3);
    if(getPluginConf()->{autoRegister} < 1) {
      getPlugin('AutoRegister')->disable();
    }else{
      getPlugin('AutoRegister')->enable();
    }
    my @macroPassedFields=qw'managerName instNb clustInstNb ownerName';
    foreach my $fieldName (@macroPassedFields) {
      my $macroName=ucfirst($fieldName);
      if(! defined $r_confMacros->{$macroName}) {
        slog("Missing configuration macro $macroName for loading ClusterManager plugin in slave instance mode",1);
        quit(1,'unable to load ClusterManager plugin');
        return undef;
      }
      $self->{$fieldName}=$r_confMacros->{$macroName};
    }
    unlink("$pidDir/$self->{instNb}.exiting");
    my ($lockFh,$pidFile)=c_acquirePidFileLock($self->{instNb},LOCK_EX);
    if(! defined $lockFh) {
      quit(1,'unable to load ClusterManager plugin');
      return undef;
    }
    if(! defined $pidFile) {
      slog("No PID file found for instance $self->{instNb}",1);
      quit(1,'unable to load ClusterManager plugin');
      close($lockFh);
      return undef;
    }
    my ($r_pidData,$instState)=c_loadLockedPidFile($pidFile);
    if(! c_checkPidDataOnInstanceStart($self,$context,\@macroPassedFields,$r_pidData,$instState)) {
      quit(1,'unable to load ClusterManager plugin');
      close($lockFh);
      return undef;
    }
    my $newPidFile=catfile($pidDir,"$self->{instNb}.running");
    if($context ne 'autoload') {
      if(! move($pidFile,$newPidFile)) {
        slog("Unable to rename PID file from \"$pidFile\" to \"$newPidFile\"",1);
        quit(1,'unable to load ClusterManager plugin');
        close($lockFh);
        return undef;
      }
      if(! utime(undef,undef,$newPidFile)) {
        slog("Failed to update PID file timestamp on plugin load: $!",1);
      }
    }else{
      $r_pidData->{instPid}=$$;
      if(! c_saveLockedPidFile($r_pidData,$newPidFile)) {
        slog("Unable to write new PID file \"$newPidFile\"",1);
        quit(1,'unable to load ClusterManager plugin');
        close($lockFh);
        return undef;
      }
      unlink($pidFile);
    }
    close($lockFh);
    if(_isInstanceBattleInUse() || _isInstanceGameInProgress()) {
      $self->{idleTs}=0 ;
    }else{
      $self->{idleTs}=time;
    }
    if(exists getLobbyInterface()->{users}{$self->{managerName}}) {
      $self->{orphanTs}=0;
    }else{
      $self->{orphanTs}=time;
    }
    if(getLobbyState() > 3) {
      addLobbyCommandHandler({ADDUSER => \&hLobbyAddUser,
                              REMOVEUSER => \&hLobbyRemoveUser,
                              JOINEDBATTLE => \&hLobbyJoinedBattle,
                              LEFTBATTLE => \&hLobbyLeftBattle,
                              BATTLECLOSED => \&hLobbyBattleClosed});
    }
    addTimer('checkSlaveInstance',1,1,\&checkSlaveInstance);
  }

  bless($self,$class);
  slog("Plugin loaded (version $pluginVersion) [$context]",3);
  return $self;
}

sub getConfMacrosHashFromString {
  my $macrosString=shift;
  return {} unless(defined $macrosString && $macrosString !~ /^\s*$/);
  my @confMacroTokens=shellwords($macrosString)
      or return undef;
  my %confMacros;
  foreach my $confMacroToken (@confMacroTokens) {
    if($confMacroToken =~ /^([^=]+)=(.*)$/) {
      $confMacros{$1}=$2;
    }else{
      return undef;
    }
  }
  return \%confMacros;
}

sub onReloadConf {
  my $self=shift;
  return unless($self->{isManager});
  
  # Configuration checks
  my $r_conf=getSpadsConf();
  my $spads=getSpadsConfFull();
  my @clusterPresets=_getConfiguredClusterList();
  my @invalidClusters = grep {! exists $spads->{presets}{$_}} @clusterPresets;
  if(@invalidClusters) {
    slog('Invalid value for "clusters" plugin setting (invalid SPADS preset'.($#invalidClusters > 0 ? 's':'').': '.(join(', ',@invalidClusters)).')',1);
    return 0;
  }
  my %nameTemplates;
  foreach my $clustPreset (@clusterPresets) {
    push(@invalidClusters,$clustPreset) unless(all {exists $spads->{presets}{$clustPreset}{$_}} (keys %{$spads->{presets}{$r_conf->{defaultPreset}}}));
    my $presetNameTemplate=c_getConfForPreset($clustPreset)->{nameTemplate};
    next if(any {index($presetNameTemplate,"\%$_\%") != -1} (qw'InstNb InstNb2 InstNb3 InstNb0 PresetName'));
    $nameTemplates{$presetNameTemplate}//=[];
    push(@{$nameTemplates{$presetNameTemplate}},$clustPreset);
  }
  if(@invalidClusters) {
    slog('Invalid value for "clusters" plugin setting (partial SPADS preset'.($#invalidClusters > 0 ? 's':'').': '.(join(', ',@invalidClusters)).')',1);
    return 0;
  }
  my @conflictStrings;
  foreach my $nameTemplate (keys %nameTemplates) {
    push(@conflictStrings,'('.(join(',',@{$nameTemplates{$nameTemplate}})).')') if($#{$nameTemplates{$nameTemplate}} > 0);
  }
  if(@conflictStrings) {
    slog('Conflicting name templates found for following clusters: '.(join(' ',@conflictStrings)),1);
    return 0;
  }
  my $r_pluginConf=getPluginConf();
  if($r_pluginConf->{maxInstances} > abs($r_pluginConf->{baseGamePort}-$r_pluginConf->{baseAutoHostPort})) {
    slog("Incompatible values for maxInstances ($r_pluginConf->{maxInstances}), baseGamePort ($r_pluginConf->{baseGamePort}) and baseAutoHostPort ($r_pluginConf->{baseAutoHostPort}) plugin settings: not enough ports between $r_pluginConf->{baseGamePort} and $r_pluginConf->{baseAutoHostPort} to allow $r_pluginConf->{maxInstances} instances",1);
    return 0;
  }
  my $highPort=$r_pluginConf->{baseGamePort}>$r_pluginConf->{baseAutoHostPort}?'baseGamePort':'baseAutoHostPort';
  if($r_pluginConf->{maxInstances} > 65536-$r_pluginConf->{$highPort}) {
    slog("Incompatible values for maxInstances ($r_pluginConf->{maxInstances}) and $highPort ($r_pluginConf->{$highPort}) plugin settings: not enough valid ports above $r_pluginConf->{$highPort} to allow $r_pluginConf->{maxInstances} instances",1);
    return 0;
  }
  if($r_conf->{autoHostPort} >= $r_pluginConf->{baseGamePort} && $r_conf->{autoHostPort} < $r_pluginConf->{baseGamePort}+$r_pluginConf->{maxInstances}) {
    slog("Incompatible values for autoHostPort global setting ($r_conf->{autoHostPort}) and baseGamePort ($r_pluginConf->{baseGamePort}) and maxInstances ($r_pluginConf->{maxInstances}) plugin settings: the autoHostPort of the manager is inside the port range used by slave instances",1);
    return 0;
  }
  if($r_conf->{autoHostPort} >= $r_pluginConf->{baseAutoHostPort} && $r_conf->{autoHostPort} < $r_pluginConf->{baseAutoHostPort}+$r_pluginConf->{maxInstances}) {
    slog("Incompatible values for autoHostPort global setting ($r_conf->{autoHostPort}) and baseAutoHostPort ($r_pluginConf->{baseAutoHostPort}) and maxInstances ($r_pluginConf->{maxInstances}) plugin settings: the autoHostPort of the manager is inside the port range used by slave instances",1);
    return 0;
  }

  foreach my $pluginPreset (keys %{$spads->{pluginsConf}{ClusterManager}{presets}}) {
    next if($pluginPreset eq '');
    my $r_pluginPresetConf=$spads->{pluginsConf}{ClusterManager}{presets}{$pluginPreset};
    foreach my $macroSetting (qw'confMacros confMacrosPublic confMacrosPrivate') {
      if(exists $r_pluginPresetConf->{$macroSetting}) {
        if(! getConfMacrosHashFromString($r_pluginPresetConf->{$macroSetting}[0])) {
          slog("Invalid configuration macro definition (preset \"$pluginPreset\", setting \"$macroSetting\"): $r_pluginPresetConf->{$macroSetting}[0]",1);
          return 0;
        }
      }
    }
  }

  if($r_pluginConf->{shareArchiveCache} && ! $r_conf->{sequentialUnitsync}) {
    slog('Archive cache data are shared but unitsync sequential mode is disabled, this can lead to race conditions and cache data corruption',2);
  }
  
  c_provisionClustersIfNeeded($self) if(exists $self->{instData});

  return 1;
}

sub _getConfiguredClusterList {
  my $r_pluginConf=getPluginConf();
  return split(',',$r_pluginConf->{clusters}) if($r_pluginConf->{clusters} ne '');
  return (getSpadsConf()->{defaultPreset});
}

sub c_checkPidDataOnInstanceStart {
  my ($self,$context,$r_macroPassedFields,$r_pidData,$instState)=@_;
  if(! defined $r_pidData) {
    slog('Unable to initialize plugin data from PID file',1);
    return 0;
  }
  if($context eq 'load' && none {$instState eq $_} (qw'unloaded reloading')) {
    slog('No previous ".unloaded" or ".reloading" PID file found when trying to load the plugin manually in slave instance mode',1);
    return 0;
  }elsif($context eq 'reload' && $instState ne 'reloading') {
    slog('No previous ".reloading" PID file found when trying to reload the plugin manually in slave instance mode',1);
    return 0;
  }elsif($context eq 'autoload' && none {$instState eq $_} (qw'launched restarting')) {
    slog('No previous ".launched" or ".restarting" PID file found when trying to auto-load the plugin in slave instance mode',1);
    return 0;
  }
  my $r_conf=getSpadsConf();
  my @inconsistentFields;
  map {push(@inconsistentFields,$_) if($r_pidData->{$_} ne $self->{$_})} @{$r_macroPassedFields};
  push(@inconsistentFields,'clustPreset') if($r_pidData->{clustPreset} ne $r_conf->{defaultPreset});
  push(@inconsistentFields,'instName') if($r_pidData->{instName} ne $r_conf->{lobbyLogin});
  push(@inconsistentFields,'instPid') if(exists $r_pidData->{instPid} && $r_pidData->{instPid} ne $$);
  if(@inconsistentFields) {
    slog('Inconsistent data found in PID file for following field'.($#inconsistentFields>0?'s: ':': ').(join(', ',@inconsistentFields)),1);
    return 0;
  }
  return 1;
}

sub c_acquirePidFileLock {
  my ($instNb,$lockType)=@_;
  my $pidDir=catdir(getSpadsConf()->{varDir},'ClusterManager');
  my $lockFile=catfile($pidDir,"$instNb.lock");
  if(open(my $lockFh,'>',$lockFile)) {
    if(flock($lockFh, $lockType)) {
      if(opendir(my $pidDirFh,$pidDir)) {
        my @pidFiles = grep {-f "$pidDir/$_" && /^$instNb\.(?:launched|restarting|reloading|unloaded|running)$/} readdir($pidDirFh);
        close($pidDirFh);
        if($#pidFiles > 0) {
          slog("Multiple PID files found for instance $instNb (".(join(', ',@pidFiles)).')',1);
          close($lockFh);
          return ();
        }elsif($#pidFiles < 0) {
          return ($lockFh);
        }
        return ($lockFh,catfile($pidDir,$pidFiles[0]));
      }else{
        slog("Unable to open PID directory \"$pidDir\" to acquire lock for PID file of instance $instNb",1);
        close($lockFh);
        return ();
      }
    }else{
      slog("Failed to acquire lock for PID file of instance $instNb",1);
      close($lockFh);
      return ();
    }
  }else{
    slog("Failed to open PID file lock of instance $instNb",1);
    return ();
  }
}

sub c_loadLockedPidFile {
  my $pidFile=shift;
  $pidFile =~ /\.(launched|restarting|reloading|unloaded|running)$/;
  my $instState=$1;
  my $instStateTimestamp=(stat($pidFile))[9];
  my %pidData;
  my @expectedDataNames=qw'managerName instNb instName clustPreset clustInstNb ownerName';
  push(@expectedDataNames,'instPid') unless($pidFile =~ /\.launched$/);
  my %expectedData;
  @expectedData{@expectedDataNames}=((undef) x @expectedDataNames);
  if(open(my $fh,'<',$pidFile)) {
    while(my $pidLine = <$fh>) {
      if($pidLine =~ /^([^:]+):(.+)$/) {
        my ($dataName,$dataValue)=($1,$2);
        if(! exists $expectedData{$dataName}) {
          slog("Invalid data in PID file \"$pidFile\": $dataName",1);
          close($fh);
          return ();
        }
        if(exists $pidData{$dataName}) {
          slog("Duplicate data in PID file \"$pidFile\"",1);
          close($fh);
          return ();
        }
        $pidData{$dataName}=$dataValue;
      }else{
        chomp($pidLine);
        slog("Invalid line in PID file \"$pidFile\" ($pidLine)",1);
        close($fh);
        return ();
      }
    }
    close($fh);
  }else{
    slog("Unable to open PID file \"$pidFile\" for reading",1);
    return ();
  }
  foreach my $expectedData (@expectedDataNames) {
    if(! exists $pidData{$expectedData}) {
      slog("Missing data in PID file \"$pidFile\": $expectedData",1);
      return ();
    }
  }
  delete $pidData{instPid} if($pidFile =~ /\.restarting$/);
  return (\%pidData,$instState,$instStateTimestamp);
}

sub c_saveLockedPidFile {
  my ($r_data,$file)=@_;
  if(open(my $fh,'>',$file)) {
    foreach my $dataName (keys %{$r_data}) {
      print $fh "$dataName:$r_data->{$dataName}\n";
    }
    close($fh);
  }else{
    slog("Unable to open PID file \"$file\" for writing",1);
    return 0;
  }
  return 1;
}

sub onUnload {
  my ($self,$reason)=@_;
  if($self->{isManager}) {
    removeLobbyCommandHandler([qw'ADDUSER REMOVEUSER JOINEDBATTLE LEFTBATTLE CLIENTSTATUS']);
    getLobbyInterface()->removePreCallbacks(['BATTLECLOSED']);
    removeTimer('checkClusters');
    removeSpadsCommandHandler([qw'privatehost listclusters clusterconfig clusterstatus clusterstats listinstances']);
    my $existingAccountsFile=catfile(getSpadsConf()->{varDir},'ClusterManager','existingAccounts.dat');
    nstore($self->{existingAccounts},$existingAccountsFile)
        or slog("Unable to store existing accounts data in file \"$existingAccountsFile\"",1);
  }else{
    removeLobbyCommandHandler([qw'ADDUSER REMOVEUSER JOINEDBATTLE LEFTBATTLE BATTLECLOSED']);
    removeTimer('checkSlaveInstance');
    my $pidDir=catdir(getSpadsConf()->{varDir},'ClusterManager');
    my $expectedPidFile=catfile($pidDir,"$self->{instNb}.running");
    my $fileExtension={reload => 'reloading',unload => 'unloaded'}->{$reason} // $reason;
    my $newPidFile=catfile($pidDir,"$self->{instNb}.$fileExtension");
    my ($lockFh,$pidFile)=c_acquirePidFileLock($self->{instNb},LOCK_EX);
    if(! defined $lockFh) {
      slog('Unable to rename PID file when unloading plugin: failed to acquire lock',1);
    }elsif(! defined $pidFile) {
      slog('Unable to rename PID file when unloading plugin: PID file does not exist',1);
      close($lockFh);
    }elsif($pidFile ne $expectedPidFile) {
      slog("Unable to rename PID file when unloading plugin: unexpected file found \"$pidFile\"",1);
      close($lockFh);
    }else{
      if(! move($pidFile,$newPidFile)) {
        slog('Unable to rename PID file when unloading plugin',1);
      }
      if(! utime(undef,undef,$newPidFile)) {
        slog("Failed to update PID file timestamp when unloading plugin: $!",1);
      }
      close($lockFh);
    }
  }
  slog("Plugin unloaded [$reason]",3);
}

sub c_lobbyConnectedInitializations {
  my $self=shift;
  my $pidDir=catdir(getSpadsConf()->{varDir},'ClusterManager');
  my %instNbs;
  if(opendir(my $pidDirFh,$pidDir)) {
    map {$instNbs{$1}=1 if(-f "$pidDir/$_" && /^(\d+)\.(?:launched|restarting|reloading|unloaded|running)$/)} readdir($pidDirFh);
    close($pidDirFh);
  }else{
    slog("Unable to open PID directory \"$pidDir\"",1);
    return 0;
  }
  my $r_conf=getSpadsConf();
  my $r_pluginConf=getPluginConf();
  my @clusterPresets=_getConfiguredClusterList();
  my (%instData,%instNames,%clustPresets,%instStates,%instOwners);
  foreach my $instNb (keys %instNbs) {
    my ($lockFh,$pidFile)=c_acquirePidFileLock($instNb,LOCK_EX);
    return 0 unless(defined $lockFh);
    if(! defined $pidFile) {
      close($lockFh);
      next;
    }
    my ($r_pidData,$instState,$instStateTimestamp)=c_loadLockedPidFile($pidFile);
    if(! defined $r_pidData) {
      slog("Unable to load PID file for instance $instNb",1);
      close($lockFh);
      return 0;
    }
    if(any {$instState eq $_} (qw'launched restarting')) {
      if($r_pluginConf->{startingInstanceTimeout} && time - $instStateTimestamp >= $r_pluginConf->{startingInstanceTimeout}) {
        slog("Instance $instNb ($r_pidData->{instName}) failed to start, removing obsolete PID file",2);
        unlink($pidFile);
        close($lockFh);
        next;
      }
    }elsif(! kill(0,$r_pidData->{instPid})) {
      slog("Instance $instNb ($r_pidData->{instName}) exited unexpectedly, removing obsolete PID file",2);
      unlink($pidFile);
      close($lockFh);
      next;
    }
    if($instNb != $r_pidData->{instNb}) {
      slog("Inconsistency detected for PID file of instance $instNb",1);
      close($lockFh);
      return 0;
    }
    if($r_conf->{lobbyLogin} ne $r_pidData->{managerName}) {
      slog("Wrong manager name in PID file of instance $instNb (expected \"$r_conf->{lobbyLogin}\", got \"$r_pidData->{managerName}\")",1);
      close($lockFh);
      return 0;
    }
    if(exists $instNames{$r_pidData->{instName}}) {
      slog("Duplicate PID file for instanceName \"$r_pidData->{instName}\" (instance numbers $instNames{$r_pidData->{instName}} and $instNb)",1);
      close($lockFh);
      return 0;
    }
    if($r_pidData->{ownerName} ne '*' && exists $instOwners{$r_pidData->{ownerName}}) {
      slog("Duplicate PID file for ownerName \"$r_pidData->{ownerName}\" (instance numbers $instOwners{$r_pidData->{ownerName}} and $instNb)",1);
      close($lockFh);
      return 0;
    }
    if(exists $clustPresets{$r_pidData->{clustPreset}} && exists $clustPresets{$r_pidData->{clustPreset}}{$r_pidData->{clustInstNb}}) {
      slog("Duplicate PID file for clusterPreset \"$r_pidData->{clustPreset}\" and clusterInstanceNb $r_pidData->{clustInstNb} (instance numbers $clustPresets{$r_pidData->{clustPreset}}{$r_pidData->{clustInstNb}} and $instNb)",1);
      close($lockFh);
      return 0;
    }
    close($lockFh);
    if(none {$r_pidData->{clustPreset} eq $_} @clusterPresets) {
      slog("PID file found for unmanaged cluster \"$r_pidData->{clustPreset}\" ($pidFile)",2);
    }
    $instData{$instNb}={instName => $r_pidData->{instName},
                        clustPreset => $r_pidData->{clustPreset},
                        clustInstNb => $r_pidData->{clustInstNb},
                        state => $instState,
                        ownerName => $r_pidData->{ownerName}};
    $instData{$instNb}{instPid}=$r_pidData->{instPid} if(exists $r_pidData->{instPid});
    $instNames{$r_pidData->{instName}}=$instNb;
    $clustPresets{$r_pidData->{clustPreset}}{$r_pidData->{clustInstNb}}=$instNb;
    $instStates{$instState}{$instNb}=$instStateTimestamp;
    $instOwners{$r_pidData->{ownerName}}=$instNb unless($r_pidData->{ownerName} eq '*');
  }
  my $lobby = getLobbyInterface();
  my %battleHosts;
  foreach my $bId (keys %{$lobby->{battles}}) {
    $battleHosts{$lobby->{battles}{$bId}{founder}} = $#{$lobby->{battles}{$bId}{userList}} > 0 ? 1 : 0;
  }
  foreach my $instNb (keys %instData) {
    my $instName=$instData{$instNb}{instName};
    if(exists $lobby->{users}{$instName}) {
      my $instLobbyState='spare';
      $instLobbyState='inUse' if(exists $battleHosts{$instName} && $battleHosts{$instName});
      $instData{$instNb}{lobbyState}=$instLobbyState;
      $self->{instLobbyStates}{$instLobbyState}{$instNb}=time;
    }else{
      $instData{$instNb}{lobbyState}='offline';
      $self->{instLobbyStates}{offline}{$instNb}=time;
    }
  }
  $self->{instData}=\%instData;
  $self->{instNames}=\%instNames;
  $self->{clustPresets}=\%clustPresets;
  $self->{instStates}=\%instStates;
  $self->{instOwners}=\%instOwners;
  addLobbyCommandHandler({ADDUSER => \&hLobbyAddUser,
                          REMOVEUSER => \&hLobbyRemoveUser,
                          JOINEDBATTLE => \&hLobbyJoinedBattle,
                          LEFTBATTLE => \&hLobbyLeftBattle,
                          CLIENTSTATUS => \&hLobbyClientStatus});
  $lobby->addPreCallbacks({BATTLECLOSED => \&hLobbyPreBattleClosed});
  c_provisionClustersIfNeeded($self);
  return 1;
}

sub onLobbyConnected {
  my $self=shift;
  if($self->{isManager}) {
    c_lobbyConnectedInitializations($self)
        or quit(1,'unable to initialize ClusterManager plugin data');
  }else{
    $self->{orphanTs}=0 if(exists getLobbyInterface()->{users}{$self->{managerName}});
    addLobbyCommandHandler({ADDUSER => \&hLobbyAddUser,
                            REMOVEUSER => \&hLobbyRemoveUser,
                            JOINEDBATTLE => \&hLobbyJoinedBattle,
                            LEFTBATTLE => \&hLobbyLeftBattle,
                            BATTLECLOSED => \&hLobbyBattleClosed});
  }
}

sub _updateInstLobbyState {
  my ($instNb,$newState)=@_;
  my $self=getPlugin();
  slog("Instance $instNb ($self->{instData}{$instNb}{instName}) went from lobby state $self->{instData}{$instNb}{lobbyState} to $newState",5);
  delete $self->{instLobbyStates}{$self->{instData}{$instNb}{lobbyState}}{$instNb};
  $self->{instLobbyStates}{$newState}{$instNb}=time;
  $self->{instData}{$instNb}{lobbyState}=$newState;
}

sub c_startNewInstancesIfNeeded {
  my ($self,$clustPreset)=@_;
  my @clusterPresets=_getConfiguredClusterList();
  return unless(any {$clustPreset eq $_} @clusterPresets);
  my %lobbyStates=(offline => 0, spare => 0, inUse => 0, 'offline(stuck)' => 0);
  foreach my $clustInstNb (keys %{$self->{clustPresets}{$clustPreset}}) {
    my $instNb=$self->{clustPresets}{$clustPreset}{$clustInstNb};
    next unless($self->{instData}{$instNb}{ownerName} eq '*');
    my $instLobbyState=$self->{instData}{$instNb}{lobbyState};
    $lobbyStates{$instLobbyState}++;
  }
  slog("Cluster $clustPreset public instance counts before start instance loop: spare=$lobbyStates{spare}, inUse=$lobbyStates{inUse}, offline=$lobbyStates{offline}, stuckOffline=$lobbyStates{'offline(stuck)'}",5);
  my $r_pluginConf=getPluginConf();
  my $r_presetConf=c_getConfForPreset($clustPreset);
  while($lobbyStates{spare} + $lobbyStates{offline} < $r_presetConf->{targetSpares}
        && ($r_presetConf->{maxInstancesInCluster} == 0 || keys %{$self->{clustPresets}{$clustPreset}} < $r_presetConf->{maxInstancesInCluster})
        && ($r_presetConf->{maxInstancesInClusterPublic} == 0 || sum(values(%lobbyStates)) < $r_presetConf->{maxInstancesInClusterPublic})
        && keys %{$self->{instData}} < $r_pluginConf->{maxInstances}
        && ($r_pluginConf->{maxInstancesPublic} == 0 || keys(%{$self->{instData}}) - keys(%{$self->{instOwners}}) < $r_pluginConf->{maxInstancesPublic})) {
    my $r_instData=c_startInstance($self,$clustPreset);
    if(defined $r_instData) {
      $lobbyStates{offline}++;
      $self->{instData}{$r_instData->{instNb}}={instName => $r_instData->{instName},
                                                clustPreset => $r_instData->{clustPreset},
                                                clustInstNb => $r_instData->{clustInstNb},
                                                state => 'launched',
                                                lobbyState => 'offline',
                                                ownerName => '*'};
      $self->{instNames}{$r_instData->{instName}}=$r_instData->{instNb};
      $self->{clustPresets}{$r_instData->{clustPreset}}{$r_instData->{clustInstNb}}=$r_instData->{instNb};
      $self->{instStates}{launched}{$r_instData->{instNb}}=time;
      $self->{instLobbyStates}{offline}{$r_instData->{instNb}}=time;
      slog("Started a new public instance (\#$r_instData->{instNb} - $r_instData->{instName}) in cluster \"$clustPreset\"",4);
    }else{
      slog("Failed to start a new public instance in cluster $clustPreset",1);
      last;
    }
  }
  slog("Cluster $clustPreset public instance counts after start instance loop: spare=$lobbyStates{spare}, inUse=$lobbyStates{inUse}, offline=$lobbyStates{offline}, stuckOffline=$lobbyStates{'offline(stuck)'}",5);
}

sub checkClusters {
  return unless(getLobbyState() > 3);
  _detectCrashedInstances();                 # enforce startingInstanceTimeout and offlineInstanceTimeout and detect offline instance that crashed
  _pruneClustersIfNeeded();                  # enforce removeSpareInstanceDelay and remove instances from obsolete/unknown clusters
}

sub _detectCrashedInstances {
  my $self=getPlugin();
  my $r_pluginConf=getPluginConf();
  my %impactedClusters;
  foreach my $instNb (keys %{$self->{instData}}) {
    my $r_instData=$self->{instData}{$instNb};
    my $instState=$r_instData->{state};
    my $clustPreset=$r_instData->{clustPreset};
    if(any {$instState eq $_} (qw'launched restarting')) {
      if($r_pluginConf->{startingInstanceTimeout} && time - $self->{instStates}{$instState}{$instNb} >= $r_pluginConf->{startingInstanceTimeout}) {
        my $newState=_refreshInstDataFromPidFile($instNb);
        if(! defined $newState) {
          slog("Instance $instNb ($r_instData->{instName}) failed to start",1);
          _removeInstDataFromMemory($instNb);
          $impactedClusters{$clustPreset}=1 if($r_instData->{ownerName} eq '*');
        }elsif(any {$newState eq $_} (qw'exiting crashed')) {
          $impactedClusters{$clustPreset}=1 if($r_instData->{ownerName} eq '*');
        }
      }
    }elsif(index($r_instData->{lobbyState},'offline') == 0 && ! kill(0,$r_instData->{instPid})) {
      my $newState=_refreshInstDataFromPidFile($instNb);
      if(! defined $newState) {
        slog("Instance $instNb ($r_instData->{instName}) exited unexpectedly",1);
        _removeInstDataFromMemory($instNb);
        $impactedClusters{$clustPreset}=1 if($r_instData->{ownerName} eq '*');
      }elsif(any {$newState eq $_} (qw'exiting crashed')) {
        $impactedClusters{$clustPreset}=1 if($r_instData->{ownerName} eq '*');
      }
    }elsif($r_instData->{lobbyState} eq 'offline') {
      if($r_pluginConf->{offlineInstanceTimeout} && time - $self->{instLobbyStates}{offline}{$instNb} >= $r_pluginConf->{offlineInstanceTimeout}) {
        _updateInstLobbyState($instNb,'offline(stuck)');
        $impactedClusters{$clustPreset}=1 if($r_instData->{ownerName} eq '*');
      }
    }
  }
  if(%impactedClusters) {
    my @clustersList=keys %impactedClusters;
    c_provisionClustersIfNeeded($self,\@clustersList);
  }
}

sub c_provisionClustersIfNeeded {
  my ($self,$r_clusters)=@_;
  my @clusterPresets = defined $r_clusters ? @{$r_clusters} : _getConfiguredClusterList();
  foreach my $clustPreset (@clusterPresets) {
    c_startNewInstancesIfNeeded($self,$clustPreset);
  }
}

sub _pruneClustersIfNeeded {
  my $self=getPlugin();
  my $r_pluginConf=getPluginConf();
  my @clusterPresets=_getConfiguredClusterList();
  foreach my $clustPreset (keys %{$self->{clustPresets}}) {
    $self->{clusterPruneTs}{$clustPreset}//=0;
    next if(time-$self->{clusterPruneTs}{$clustPreset} < 5);
    if(any {$clustPreset eq $_} @clusterPresets) {
      my ($nbOldSpares,%removableClustInstNbs)=(0);
      foreach my $clustInstNb (keys %{$self->{clustPresets}{$clustPreset}}) {
        my $instNb=$self->{clustPresets}{$clustPreset}{$clustInstNb};
        next unless($self->{instData}{$instNb}{ownerName} eq '*');
        if($self->{instData}{$instNb}{lobbyState} eq 'spare') {
          $removableClustInstNbs{$clustInstNb}=$instNb;
          $nbOldSpares++ if($r_pluginConf->{removeSpareInstanceDelay} && time-$self->{instLobbyStates}{spare}{$instNb} >= $r_pluginConf->{removeSpareInstanceDelay});
        }
      }
      my $r_presetConf=c_getConfForPreset($clustPreset);
      if($nbOldSpares > $r_presetConf->{targetSpares}) {
        $self->{clusterPruneTs}{$clustPreset}=time;
        my @orderedClustInstNbs = sort {$b <=> $a} (keys %removableClustInstNbs);
        for my $i (0..($nbOldSpares-$r_presetConf->{targetSpares}-1)) {
          my $clustInstNb=$orderedClustInstNbs[$i];
          my $instNb=$self->{clustPresets}{$clustPreset}{$clustInstNb};
          my $instName=$self->{instData}{$instNb}{instName};
          slog("Spare instance pruning for cluster \"$clustPreset\" (removing instance \"$instName\")",5);
          sayPrivate($instName,'!#quitIfIdle');
        }
      }
    }else{
      my @removableInstanceNames;
      foreach my $clustInstNb (keys %{$self->{clustPresets}{$clustPreset}}) {
        my $instNb=$self->{clustPresets}{$clustPreset}{$clustInstNb};
        push(@removableInstanceNames,$self->{instData}{$instNb}{instName}) if($self->{instData}{$instNb}{lobbyState} eq 'spare');
      }
      if(@removableInstanceNames) {
        $self->{clusterPruneTs}{$clustPreset}=time;
        foreach my $instName (@removableInstanceNames) {
          slog("Instance removal for obsolete cluster \"$clustPreset\" (removing instance \"$instName\")",2);
          sayPrivate($instName,'!#quitIfIdle');
        }
      }
    }
  }
}

sub _removeInstDataFromMemory {
  my $instNb=shift;
  my $self=getPlugin();
  my $r_instData=$self->{instData}{$instNb};
  delete $self->{instNames}{$r_instData->{instName}};
  delete $self->{clustPresets}{$r_instData->{clustPreset}}{$r_instData->{clustInstNb}};
  delete $self->{instStates}{$r_instData->{state}}{$instNb};
  delete $self->{instLobbyStates}{$r_instData->{lobbyState}}{$instNb};
  delete $self->{instOwners}{$r_instData->{ownerName}} unless($r_instData->{ownerName} eq '*');
  delete $self->{instData}{$instNb};
}

sub _refreshInstDataFromPidFile {
  my $instNb=shift;
  my $self=getPlugin();
  my $r_instData=$self->{instData}{$instNb};
  
  my $r_conf=getSpadsConf();
  my $exitingPidFile="$r_conf->{varDir}/ClusterManager/$instNb.exiting";
  if(-f $exitingPidFile) {
    unlink($exitingPidFile);
    if(index($r_instData->{lobbyState},'offline') == 0) {
      slog("Instance $instNb ($r_instData->{instName}) exited",4);
    }else{
      slog("Instance $instNb ($r_instData->{instName}) exited but still appears online",2);
    }
    _removeInstDataFromMemory($instNb);
    return 'exiting';
  }
  
  my ($lockFh,$pidFile)=c_acquirePidFileLock($instNb,LOCK_EX);
  my $errorMsg="Unable to load instance data from PID file for instance $instNb ($r_instData->{instName})";
  if(! defined $lockFh) {
    slog("$errorMsg: failed to acquire lock",1);
    return undef;
  }
  if(! defined $pidFile) {
    slog("$errorMsg: PID file not found",1);
    close($lockFh);
    return undef;
  }
  
  my ($r_pidData,$instState,$instStateTimestamp)=c_loadLockedPidFile($pidFile);
  if(! defined $r_pidData) {
    slog($errorMsg,1);
    close($lockFh);
    return undef;
  }
  my @inconsistentFields;
  push(@inconsistentFields,'managerName') if($r_pidData->{managerName} ne $r_conf->{lobbyLogin});
  push(@inconsistentFields,'instNb') if($r_pidData->{instNb} ne $instNb);
  foreach my $pidField (qw'instName clustPreset clustInstNb ownerName') {
    push(@inconsistentFields,$pidField) if($r_pidData->{$pidField} ne $r_instData->{$pidField});
  }
  if(@inconsistentFields) {
    slog("$errorMsg, inconsistent data found for following field".($#inconsistentFields>0?'s: ':': ').(join(', ',@inconsistentFields)),1);
    close($lockFh);
    return undef;
  }

  my $r_pluginConf=getPluginConf();
  if(any {$instState eq $_} (qw'launched restarting')) {
    if($r_pluginConf->{startingInstanceTimeout} && time - $instStateTimestamp >= $r_pluginConf->{startingInstanceTimeout}) {
      slog("Instance $instNb ($r_pidData->{instName}) failed to start, removing PID file",2);
      _removeInstDataFromMemory($instNb);
      unlink($pidFile);
      close($lockFh);
      return 'crashed';
    }
  }elsif(! kill(0,$r_pidData->{instPid})) {
    slog("Instance $instNb ($r_pidData->{instName}) exited unexpectedly, removing PID file",2);
    _removeInstDataFromMemory($instNb);
    unlink($pidFile);
    close($lockFh);
    return 'crashed';
  }
  close($lockFh);

  $r_instData->{instPid}=$r_pidData->{instPid};
  if($r_instData->{state} ne $instState || $self->{instStates}{$r_instData->{state}}{$instNb} != $instStateTimestamp) {
    slog("Instance $instNb ($r_instData->{instName}) went from state $r_instData->{state} (timestamp:$self->{instStates}{$r_instData->{state}}{$instNb}) to $instState (timestamp:$instStateTimestamp)",5);
    delete $self->{instStates}{$r_instData->{state}}{$instNb};
    $r_instData->{state}=$instState;
    $self->{instStates}{$r_instData->{state}}{$instNb}=$instStateTimestamp;
  }
  return $instState;
}

sub hLobbyAddUser {
  my (undef,$user)=@_;
  my $self=getPlugin();
  if($self->{isManager}) {
    return unless(exists $self->{instNames}{$user});
    $self->{existingAccounts}{$user}=time;
    my $instNb=$self->{instNames}{$user};
    _updateInstLobbyState($instNb,'spare');
    _refreshInstDataFromPidFile($instNb);
  }else{
    $self->{orphanTs}=0 if($user eq $self->{managerName});
  }
}

sub hLobbyRemoveUser {
  my (undef,$user)=@_;
  my $self=getPlugin();
  if($self->{isManager}) {
    return unless(exists $self->{instNames}{$user});
    my $instNb=$self->{instNames}{$user};
    _updateInstLobbyState($instNb,'offline');
    my $clustPreset=$self->{instData}{$instNb}{clustPreset};
    my $ownerName=$self->{instData}{$instNb}{ownerName};
    my $newState=_refreshInstDataFromPidFile($instNb);
    if(defined $newState && (any {$newState eq $_} (qw'exiting crashed')) && $ownerName eq '*') {
      c_startNewInstancesIfNeeded($self,$clustPreset);
    }
  }else{
    $self->{orphanTs}=time if($user eq $self->{managerName});
  }
}

sub hLobbyJoinedBattle {
  my (undef,$bId)=@_;
  my $self=getPlugin();
  my $lobby=getLobbyInterface();
  if($self->{isManager}) {
    my $user=$lobby->{battles}{$bId}{founder};
    return unless(exists $self->{instNames}{$user});
    my $instNb=$self->{instNames}{$user};
    my $r_instData=$self->{instData}{$instNb};
    return unless($r_instData->{lobbyState} eq 'spare');
    _updateInstLobbyState($instNb,'inUse');
    c_startNewInstancesIfNeeded($self,$r_instData->{clustPreset}) if($r_instData->{ownerName} eq '*');
  }elsif(%{$lobby->{battle}} && $bId == $lobby->{battle}{battleId}) {
    $self->{idleTs}=0;
  }
}

sub hLobbyLeftBattle {
  my (undef,$bId)=@_;
  my $self=getPlugin();
  my $lobby=getLobbyInterface();
  if($self->{isManager}) {
    my $r_battleData=$lobby->{battles}{$bId};
    my $user=$r_battleData->{founder};
    return unless(exists $self->{instNames}{$user} && $#{$r_battleData->{userList}} < 1);
    return if($lobby->{users}{$user}{status}{inGame});
    my $instNb=$self->{instNames}{$user};
    _updateInstLobbyState($instNb,'spare');
  }elsif(%{$lobby->{battle}} && $bId == $lobby->{battle}{battleId}) {
    $self->{idleTs}=time unless(keys %{$lobby->{battle}{users}} > 1 || _isInstanceGameInProgress());
  }
}

sub hLobbyPreBattleClosed {
  my (undef,$bId)=@_;
  my $self=getPlugin();
  my $lobby=getLobbyInterface();
  my $r_battleData=$lobby->{battles}{$bId};
  my $user=$r_battleData->{founder};
  return unless(exists $self->{instNames}{$user} && ! $lobby->{users}{$user}{status}{inGame});
  my $instNb=$self->{instNames}{$user};
  return if($self->{instData}{$instNb}{lobbyState} eq 'spare');
  _updateInstLobbyState($instNb,'spare');
}

sub hLobbyBattleClosed {
  my (undef,$bId)=@_;
  my $self=getPlugin();
  my $lobby=getLobbyInterface();
  return if($self->{idleTs});
  $self->{idleTs}=time unless(%{$lobby->{battle}} || _isInstanceGameInProgress());
}

sub hLobbyClientStatus {
  my (undef,$user)=@_;
  my $self=getPlugin();
  return unless(exists $self->{instNames}{$user});
  my $instNb=$self->{instNames}{$user};
  my $lobby=getLobbyInterface();
  if(! $lobby->{users}{$user}{status}{bot} && ! exists $self->{setBotModeSent}{$user}) {
    if($lobby->{users}{getSpadsConf()->{lobbyLogin}}{status}{access}) {
      queueLobbyCommand(['SETBOTMODE',$user,1]);
      $self->{setBotModeSent}{$user}=1;
    }
  }
  my $r_instData=$self->{instData}{$instNb};
  if($r_instData->{lobbyState} eq 'spare' && $lobby->{users}{$user}{status}{inGame}) {
    _updateInstLobbyState($instNb,'inUse');
    c_startNewInstancesIfNeeded($self,$r_instData->{clustPreset}) if($r_instData->{ownerName} eq '*');
  }elsif($r_instData->{lobbyState} eq 'inUse' && ! $lobby->{users}{$user}{status}{inGame}) {
    my $emptyBattle=1;
    foreach my $bId (keys %{$lobby->{battles}}) {
      if($lobby->{battles}{$bId}{founder} eq $user) {
        $emptyBattle=0 if($#{$lobby->{battles}{$bId}{userList}} > 0);
        last;
      }
    }
    if($emptyBattle) {
      _updateInstLobbyState($instNb,'spare');
    }
  }
}

sub onLobbyDisconnected {
  my $self=shift;
  return if($self->{isManager});
  $self->{orphanTs}||=time;
  $self->{idleTs}||=time unless(_isInstanceGameInProgress());
}

sub onSpringStart {
  my $self=getPlugin();
  if($self->{isManager}) {
    slog('Unexpected Spring start encountered on Cluster manager',2);
  }else{
    $self->{idleTs}=0;
  }
}

sub onSpringStop {
  my $self=getPlugin();
  if(! $self->{isManager}) {
    $self->{idleTs}=time unless(_isInstanceBattleInUse());
  }
}

sub c_getConfForPreset {
  my $preset=shift;
  my %presetConf;
  my $spads=getSpadsConfFull();
  if(exists $spads->{pluginsConf}{ClusterManager}{presets}{$preset}) {
    my $r_presetPluginConf=$spads->{pluginsConf}{ClusterManager}{presets}{$preset};
    foreach my $param (keys %{$r_presetPluginConf}) {
      $presetConf{$param}=$r_presetPluginConf->{$param}[0];
    }
  }
  my $r_conf=getSpadsConf();
  foreach my $param (keys %presetPluginParams) {
    next if(exists $presetConf{$param});
    $presetConf{$param}=$spads->{pluginsConf}{ClusterManager}{presets}{$r_conf->{defaultPreset}}{$param}[0];
  }
  return \%presetConf;
}

sub _isInstanceBattleInUse {
  my $lobby=getLobbyInterface();
  return getLobbyState() > 5 && %{$lobby->{battle}} && keys %{$lobby->{battle}{users}} > 1
}

sub _isInstanceGameInProgress {
  return getSpringPid() || getSpringInterface()->getState();
}

sub checkSlaveInstance {
  my $self=getPlugin();
  return unless($self->{idleTs});
  my $r_pluginConf=getPluginConf();
  if($r_pluginConf->{orphanInstanceTimeout} && $self->{orphanTs} && time - $self->{orphanTs} > $r_pluginConf->{orphanInstanceTimeout}) {
    $self->{orphanTs}=time;
    slog('Timeout for idle orphan instance, exiting',2);
    quit(1,'cluster manager is offline');
  }elsif($self->{ownerName} ne '*') {
    if(time - $self->{idleTs} > $r_pluginConf->{removePrivateInstanceDelay}) {
      $self->{idleTs}=time;
      slog('Timeout for idle private instance, exiting',4);
      quit(1,'private instance is idle');
    }elsif(getLobbyState() > 3 && ! exists getLobbyInterface()->{users}{$self->{ownerName}} && time - $self->{idleTs} >= 10) {
      $self->{idleTs}=time;
      slog('Owner of private instance is offline, exiting',4);
      quit(1,'private instance owner is offline');
    }
  }
}

sub c_startInstance {
  my ($self,$preset,$owner)=@_;
  my ($instNb,$clustInstNb)=(0,0);
  while(exists $self->{instData}{$instNb}) {
    $instNb++;
  }
  while(exists $self->{clustPresets}{$preset}{$clustInstNb}) {
    $clustInstNb++;
  }

  my $r_pluginConf=getPluginConf();
  my $instNbAutoDigits=length($r_pluginConf->{maxInstances}-1);

  my $r_presetConf=c_getConfForPreset($preset);
  my $clustInstNbAutoDigits = $r_presetConf->{maxInstancesInCluster} ? length($r_presetConf->{maxInstancesInCluster}-1) : $instNbAutoDigits;

  my $instName=$r_presetConf->{nameTemplate};
  if(none {index($instName,"\%$_\%") != -1} (qw'InstNb InstNb2 InstNb3 InstNb0 ClustInstNb ClustInstNb2 ClustInstNb3 ClustInstNb0')) {
    $instName.='%ClustInstNb0%';
  }
  
  my $r_conf=getSpadsConf();
  my %placeHolders=(InstNb => $instNb,
                    InstNb2 => sprintf('%02u',$instNb),
                    InstNb3 => sprintf('%03u',$instNb),
                    InstNb0 => sprintf("\%0${instNbAutoDigits}u",$instNb),
                    ClustInstNb => $clustInstNb,
                    ClustInstNb2 => sprintf('%02u',$clustInstNb),
                    ClustInstNb3 => sprintf('%03u',$clustInstNb),
                    ClustInstNb0 => sprintf("\%0${clustInstNbAutoDigits}u",$clustInstNb),
                    PresetName => $preset,
                    ManagerName => $r_conf->{lobbyLogin},
                    OwnerName => $owner//'*');
  foreach my $placeHolder (keys %placeHolders) {
    $instName =~ s/\%$placeHolder\%/$placeHolders{$placeHolder}/g;
  }
  $placeHolders{InstanceName}=$instName;

  if($instName !~ /^[\w\[\]]{2,20}$/) {
    slog("Unable to start new instance, invalid instance name: $instName",1);
    return undef;
  }

  if(exists $self->{instNames}{$instName}) {
    slog("Unable to start new instance, duplicate instance name: $instName",1);
    return undef;
  }

  my $lobby=getLobbyInterface();
  if(getLobbyState() > 3 && exists $lobby->{users}{$instName}) {
    slog("Unable to start new instance, instance \"$instName\" is already online",1);
    return undef;
  }

  my $fpInstanceDir=catdir($r_conf->{varDir},'ClusterManager',$instName);
  if(! -d $fpInstanceDir && ! mkdir($fpInstanceDir)) {
    slog("Unable to start new instance, failed to create new instance directory \"$fpInstanceDir\"",1);
    return undef;
  }

  my ($sourceCacheDir,$instanceCacheDir)=(catdir($r_conf->{instanceDir},'cache'),catdir($fpInstanceDir,'cache'));
  if(-d $sourceCacheDir && ! -d $instanceCacheDir) {
    if($r_pluginConf->{shareArchiveCache}) {
      if(my $symLinkCreateError=symLinkDir($sourceCacheDir,$instanceCacheDir)) {
        slog("Failed to create symbolic link \"$instanceCacheDir\" to directory \"$sourceCacheDir\" to initialize instance Spring archive cache ($symLinkCreateError)",2);
      }
    }else{
      slog("Failed to copy cache data from \"$sourceCacheDir\" to \"$instanceCacheDir\" to initialize instance Spring archive cache",2)
          unless(_copyDir($sourceCacheDir,$instanceCacheDir));
    }
  }
  
  my @instanceDatFiles=qw'mapHashes.dat userData.dat';
  map {push(@instanceDatFiles,"$_.dat") if($r_conf->{$_.'Data'} eq 'private')} (qw'bans preferences savedBoxes trustedLobbyCertificates mapInfoCache');
  my @datFiles = grep {-f "$r_conf->{instanceDir}/$_" && ! -f "$fpInstanceDir/$_"} @instanceDatFiles;
  foreach my $datFile (@datFiles) {
    if(! copy("$r_conf->{instanceDir}/$datFile",$fpInstanceDir)) {
      slog("Unable to start new instance, failed to copy instance data file \"$datFile\" from \"$r_conf->{instanceDir}\" to \"$fpInstanceDir\" to prepare new instance directory",1);
      return undef;
    }
  }
  
  my $fpLogDir=catdir($fpInstanceDir,'log');
  if(! -d $fpLogDir && ! mkdir($fpLogDir)) {
    slog("Unable to start new instance, failed to create new log directory \"$fpLogDir\"",1);
    return undef;
  }
  my ($lockFh,$pidFile)=c_acquirePidFileLock($instNb,LOCK_EX);
  return undef unless(defined $lockFh);
  if(defined $pidFile) {
    slog("Unable to start new instance $instNb ($instName), a PID file already exists: $pidFile",1);
    close($lockFh);
    return undef;
  }
  $pidFile=catfile($r_conf->{varDir},'ClusterManager',"$instNb.launched");
  my %instanceData=(managerName => $r_conf->{lobbyLogin},
                    instNb => $instNb,
                    instName => $instName,
                    clustPreset => $preset,
                    clustInstNb => $clustInstNb,
                    ownerName => $owner // '*');
  if(! c_saveLockedPidFile(\%instanceData,$pidFile)) {
    slog("Unable to start new instance, failed to create new PID file \"$pidFile\"",1);
    close($lockFh);
    return undef;
  }
  unlink("$r_conf->{varDir}/ClusterManager/$instNb.exiting");
  close($lockFh);

  if($lobby->{users}{$r_conf->{lobbyLogin}}{status}{access} && $r_presetConf->{lobbyPassword} eq '' && ! exists $self->{existingAccounts}{$instName}) {
    queueLobbyCommand(['CREATEBOTACCOUNT',$instName,$r_conf->{lobbyLogin}]);
    $self->{existingAccounts}{$instName}=-1;
  }
  
  my $r_confMacros=getConfMacros();
  my %instanceMacros=%{$r_confMacros};

  foreach my $placeHolder (keys %placeHolders) {
    $instanceMacros{$placeHolder}=$placeHolders{$placeHolder};
  }

  my $r_confMacrosOverload=getConfMacrosHashFromString($r_presetConf->{confMacros});
  my $r_specificConfMacrosOverload=getConfMacrosHashFromString($r_presetConf->{$owner?'confMacrosPrivate':'confMacrosPublic'});
  foreach my $confOverloadName (keys %{$r_specificConfMacrosOverload}) {
    $r_confMacrosOverload->{$confOverloadName}=$r_specificConfMacrosOverload->{$confOverloadName};
  }
  foreach my $confOverloadValue (values %{$r_confMacrosOverload}) {
    foreach my $placeHolder (keys %instanceMacros) {
      $confOverloadValue =~ s/\%$placeHolder\%/$instanceMacros{$placeHolder}/g;
    }
  }

  $instanceMacros{'set:lobbyLogin'}=$instName;
  $instanceMacros{'set:defaultPreset'}=$preset;
  $instanceMacros{'hSet:port'}=$r_pluginConf->{baseGamePort}+$instNb;
  $instanceMacros{'set:autoHostPort'}=$r_pluginConf->{baseAutoHostPort}+$instNb;
  $instanceMacros{'set:instanceDir'}=catdir('ClusterManager',$instName);
  $instanceMacros{'set:logDir'}='log';
  if($owner) {
    my $passwd=::generatePassword(4,'abcdefghjkmnpqrstuvwxyz123456789');
    $instanceMacros{'hSet:password'}=$passwd;
    $instanceData{password}=$passwd;
  }
  $instanceMacros{'set:lobbyPassword'}=$r_presetConf->{lobbyPassword} unless($r_presetConf->{lobbyPassword} eq '');

  foreach my $confOverloadName (keys %{$r_confMacrosOverload}) {
    $instanceMacros{$confOverloadName}=$r_confMacrosOverload->{$confOverloadName};
  }

  if(! createDetachedProcess($^X,
                             [$0,$ARGV[0],map {"$_=$instanceMacros{$_}"} (keys %instanceMacros)],
                             $spadsDir,
                             $r_pluginConf->{createNewConsoles})) {
    slog('Unable to create detached process to start new instance',1);
    return undef;
  }
  return \%instanceData;
}

sub symLinkDir {
  my ($targetDir,$link)=@_;
  if($^O eq 'MSWin32') {
    return 'invalid file name'
        if(any {/[\Q*?"<>|\E]/} ($targetDir,$link));
    map {$_='"'.$_.'"' if(/[ \t]/)} ($targetDir,$link);
    system {'cmd.exe'} ('cmd.exe','/c','mklink','/j',$link,$targetDir,'>NUL','2>&1');
    if($? == -1) {
      return 'failed to execute cmd.exe: '.$!;
    }elsif($? & 127) {
      return 'cmd.exe interrupted by signal '.($? & 127);
    }else{
      my $exitCode=$? >> 8;
      return 'mklink returned with exit code '.$exitCode if($exitCode);
      return undef;
    }
  }else{
    my $rc;
    if(eval { $rc=symlink($targetDir,$link); 1 }) {
      return $! unless($rc);
      return undef;
    }else{
      chomp($@);
      return $@;
    }
  }
}

sub _copyDir {
  my ($sourceDir,$destDir)=@_;
  if(! -d $destDir && ! mkdir $destDir) {
    slog("Failed to create directory \"$destDir\"",1);
    return 0;
  }
  if(opendir(my $dirHandle,$sourceDir)) {
    my @content=grep {! -l $_ && index($_,'.') != 0} readdir($dirHandle);
    close($dirHandle);
    foreach my $fileOrDir (@content) {
      if(-f "$sourceDir/$fileOrDir") {
        my ($sourceFile,$destFile)=(catfile($sourceDir,$fileOrDir),catfile($destDir,$fileOrDir));
        if(! copy($sourceFile,$destFile)) {
          slog("Failed to copy \"$sourceFile\" to \"$destFile\"",2);
          return 0;
        }
      }elsif(-d "$sourceDir/$fileOrDir") {
        return 0 unless(_copyDir(catdir($sourceDir,$fileOrDir),catdir($destDir,$fileOrDir)));
      }else{
        slog("Ignoring unknown item during directory copy: \"$sourceDir/$fileOrDir\"",2);
      }
    }
    return 1;
  }else{
    slog("Failed to read directory \"$sourceDir\"",1);
    return 0;
  }
}

sub onPrivateMsg {
  my ($self,$user,$msg)=@_;
  return 0 if($self->{isManager});
  return 0 if($user ne $self->{managerName});
  return 0 if($msg ne '!#quitIfIdle');
  quit(1,'requested by Cluster manager') if($self->{idleTs});
  return 1;
}

sub hPrivateHost {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 0) {
    invalidSyntax($user,'privateHost');
    return 0;
  }
  
  my @clusterPresets=_getConfiguredClusterList();
  my $clustPreset=$p_params->[0]//$clusterPresets[0];
  if(none {$clustPreset eq $_} @clusterPresets) {
    answer("Invalid cluster \"$clustPreset\" (use !listClusters to list available clusters)");
    return 0;
  }

  my $self=getPlugin();
  if(exists $self->{instOwners}{$user}) {
    answer("There is already a private host created for you: $self->{instData}{$self->{instOwners}{$user}}{instName} (only one private host is allowed by user)");
    return 0;
  }
  
  my $r_presetConf=c_getConfForPreset($clustPreset);
  
  if($r_presetConf->{maxInstancesInCluster} != 0 && keys %{$self->{clustPresets}{$clustPreset}} >= $r_presetConf->{maxInstancesInCluster}) {
    answer("Unable to create a new host in $clustPreset cluster: the maximum number of instances is reached for this cluster");
    return 0;
  }
  
  my $nbPrivInstancesInCluster=0;
  foreach my $clustInstNb (keys %{$self->{clustPresets}{$clustPreset}}) {
    my $instNb=$self->{clustPresets}{$clustPreset}{$clustInstNb};
    next if($self->{instData}{$instNb}{ownerName} eq '*');
    $nbPrivInstancesInCluster++;
  }
  if($r_presetConf->{maxInstancesInClusterPrivate} != 0 && $nbPrivInstancesInCluster >= $r_presetConf->{maxInstancesInClusterPrivate}) {
    answer("Unable to create a new private host in $clustPreset cluster: the maximum number of private instances is reached for this cluster");
    return 0;
  }
  
  my $r_pluginConf=getPluginConf();
  if(keys %{$self->{instData}} >= $r_pluginConf->{maxInstances}) {
    answer('Unable to create a new host: the maximum number of instances is reached');
    return 0;
  }
  
  if($r_pluginConf->{maxInstancesPrivate} != 0 && keys(%{$self->{instOwners}}) >= $r_pluginConf->{maxInstancesPrivate}) {
    answer('Unable to create a new private host: the maximum number of private instances is reached');
    return 0;
  }
  
  my $r_instData=c_startInstance($self,$clustPreset,$user);
  if(defined $r_instData) {
    my $instNb=$r_instData->{instNb};
    $self->{instData}{$instNb}={instName => $r_instData->{instName},
                                clustPreset => $r_instData->{clustPreset},
                                clustInstNb => $r_instData->{clustInstNb},
                                state => 'launched',
                                lobbyState => 'offline',
                                ownerName => $user};
    $self->{instNames}{$r_instData->{instName}}=$instNb;
    $self->{clustPresets}{$clustPreset}{$r_instData->{clustInstNb}}=$instNb;
    $self->{instStates}{launched}{$instNb}=time;
    $self->{instLobbyStates}{offline}{$instNb}=time;
    $self->{instOwners}{$user}=$instNb;
    sayPrivate($user,"Starting a new private instance in $clustPreset cluster (name=$r_instData->{instName}, password=$r_instData->{password})");
    slog("Started a new private instance (\#$instNb - $r_instData->{instName}) in cluster \"$clustPreset\" (owner \"$user\", password=$r_instData->{password})",4);
    return 1;
  }else{
    answer("Failed to start a new private instance in cluster $clustPreset (internal error)");
    slog("Failed to start a new private instance in cluster $clustPreset (user \"$user\")",1);
    return 0;
  }
}

sub hListClusters {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if(@{$p_params}) {
    invalidSyntax($user,'listClusters');
    return 0;
  }
  return 1 if($checkOnly);
  my ($p_C,$B)=::initUserIrcColors($user);
  my %C=%{$p_C};
  my $spads=getSpadsConfFull();
  sayPrivate($user,"$B********** AutoHost clusters **********");
  my @clusterPresets=_getConfiguredClusterList();
  foreach my $preset (sort @clusterPresets) {
    my $presetString='  ';
    $presetString.=$C{12} if($preset eq $clusterPresets[0]);
    $presetString.=$preset;
    $presetString.=" ($spads->{presets}{$preset}{description}[0])" if(exists $spads->{presets}{$preset}{description});
    $presetString.=" *** DEFAULT ***" if($preset eq $clusterPresets[0]);
    sayPrivate($user,$presetString);
  }
}

sub hClusterConfig {
  my ($source,$user,$p_params,$checkOnly)=@_;
  
  if($#{$p_params} > 0) {
    invalidSyntax($user,'clusterConfig');
    return 0;
  }
  
  my ($p_C,$B)=::initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $clustPreset=$p_params->[0];
  if(defined $clustPreset) {
    my @clusterPresets=_getConfiguredClusterList();
    if(none {$clustPreset eq $_} @clusterPresets) {
      answer("Invalid cluster \"$clustPreset\" (use !listClusters to list available clusters)");
      return 0;
    }
    return 1 if($checkOnly);
    my $r_presetConf=c_getConfForPreset($clustPreset);
    my @configData;
    foreach my $pluginSetting (sort keys %{$r_presetConf}) {
      next if($pluginSetting eq 'lobbyPassword');
      push(@configData,{"$C{5}Setting$C{1}" => $pluginSetting,
                        "$C{5}Value$C{1}" => $C{12}.$r_presetConf->{$pluginSetting} });
    }
    my $r_configDataLines=formatArray(["$C{5}Setting$C{1}","$C{5}Value$C{1}"],\@configData,"$C{2}$clustPreset cluster configuration$C{1}");
    foreach my $configDataLine (@{$r_configDataLines}) {
      sayPrivate($user,$configDataLine);
    }
    return 1;
  }
  return 1 if($checkOnly);
  
  my $r_pluginConf=getPluginConf();
  my @clusterManagerPublicSettings=(qw'maxInstances maxInstancesPublic maxInstancesPrivate removeSpareInstanceDelay removePrivateInstanceDelay startingInstanceTimeout offlineInstanceTimeout orphanInstanceTimeout baseGamePort baseAutoHostPort clusters autoRegister shareArchiveCache');
  my @configData;
  foreach my $pluginSetting (sort @clusterManagerPublicSettings) {
    push(@configData,{"$C{5}Setting$C{1}" => $pluginSetting,
                      "$C{5}Value$C{1}" => $C{12}.$r_pluginConf->{$pluginSetting} });
  }
  my $r_configDataLines=formatArray(["$C{5}Setting$C{1}","$C{5}Value$C{1}"],\@configData,"$C{2}ClusterManager configuration$C{1}");
  foreach my $configDataLine (@{$r_configDataLines}) {
    sayPrivate($user,$configDataLine);
  }
  return 1;
}

sub hClusterStatus {
  my ($source,$user,$p_params,$checkOnly)=@_;
  
  if($#{$p_params} > 0) {
    invalidSyntax($user,'clusterStatus');
    return 0;
  }
  
  my ($p_C,$B)=::initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $self=getPlugin();
  my @selectedInstances;
  my @maxValues;
  my $statusTitle;
  
  my $clustPreset=$p_params->[0];
  if(defined $clustPreset) {
    my @clusterPresets=_getConfiguredClusterList();
    if(none {$clustPreset eq $_} @clusterPresets) {
      answer("Invalid cluster \"$clustPreset\" (use !listClusters to list available clusters)");
      return 0;
    }
    return 1 if($checkOnly);
    @selectedInstances=values %{$self->{clustPresets}{$clustPreset}};
    my $r_presetConf=c_getConfForPreset($clustPreset);
    @maxValues=($r_presetConf->{maxInstancesInClusterPublic},$r_presetConf->{maxInstancesInClusterPrivate},$r_presetConf->{maxInstancesInCluster});
    $statusTitle="Status for cluster: $clustPreset";
  }else{
    return 1 if($checkOnly);
    @selectedInstances=keys %{$self->{instData}};
    my $r_pluginConf=getPluginConf();
    @maxValues=($r_pluginConf->{maxInstancesPublic},$r_pluginConf->{maxInstancesPrivate},$r_pluginConf->{maxInstances});
    $statusTitle="Global cluster status";
  }
  
  my @statusCounts=({type => "$C{10}public$C{1}", inUse => 0, idle => 0, offline => 0, error => 0, total => 0},
                    {type => "$C{10}private$C{1}", inUse => 0, idle => 0, offline => 0, error => 0, total => 0},
                    {type => "$C{10}-total-$C{1}", inUse => 0, idle => 0, offline => 0, error => 0, total => 0});
  foreach my $instNb (@selectedInstances) {
    my $type = $self->{instData}{$instNb}{ownerName} eq '*' ? 0 : 1;
    my $status = {spare => 'idle', 'offline(stuck)' => 'error'}->{$self->{instData}{$instNb}{lobbyState}} // $self->{instData}{$instNb}{lobbyState};
    $statusCounts[$type]{$status}++;
    $statusCounts[$type]{total}++;
    $statusCounts[2]{$status}++;
    $statusCounts[2]{total}++;
  }
  for my $typeIdx (0..2) {
    $statusCounts[$typeIdx]{total}.="$C{14}/$maxValues[$typeIdx]$C{1}" if($maxValues[$typeIdx]);
  }

  my @fields=map {"$C{5}$_$C{1}"} (qw'type inUse idle offline error total');
  foreach my $r_statusData (@statusCounts) {
    foreach my $k (keys %{$r_statusData}) {
      $r_statusData->{"$C{5}$k$C{1}"}=delete $r_statusData->{$k};
    }
  }
  
  my $r_statusLines=formatArray(\@fields,\@statusCounts,"$C{2}$statusTitle$C{1}");
  foreach my $statusLine (@{$r_statusLines}) {
    sayPrivate($user,$statusLine);
  }
  return 1;
}

sub hClusterStats {
  my ($source,$user,$p_params,$checkOnly)=@_;
  
  if(@{$p_params}) {
    invalidSyntax($user,'clusterStats');
    return 0;
  }
  
  return 1 if($checkOnly);

  my ($p_C,$B)=::initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $self=getPlugin();

  my %clusterStats;
  map {$clusterStats{$_}={cluster => "$C{10}$_$C{1}", public => 0, private => 0, total => 0}} _getConfiguredClusterList();
  my %totalStats=(cluster => "$C{10}-total-$C{1}", public => 0, private => 0, total => 0);

  foreach my $instNb (keys %{$self->{instData}}) {
    my $r_instData=$self->{instData}{$instNb};
    my $type = $r_instData->{ownerName} eq '*' ? 'public' : 'private';
    $clusterStats{$r_instData->{clustPreset}}{$type}++;
    $clusterStats{$r_instData->{clustPreset}}{total}++;
    $totalStats{$type}++;
    $totalStats{total}++;
  }
  
  my @fields=map {"$C{5}$_$C{1}"} (qw'cluster public private total');
  my @statsData;
  foreach my $cluster (sort keys %clusterStats) {
    my $r_presetConf=c_getConfForPreset($cluster);
    $clusterStats{$cluster}{public}.="$C{14}/$r_presetConf->{maxInstancesInClusterPublic}$C{1}" if($r_presetConf->{maxInstancesInClusterPublic});
    $clusterStats{$cluster}{private}.="$C{14}/$r_presetConf->{maxInstancesInClusterPrivate}$C{1}" if($r_presetConf->{maxInstancesInClusterPrivate});
    $clusterStats{$cluster}{total}.="$C{14}/$r_presetConf->{maxInstancesInCluster}$C{1}" if($r_presetConf->{maxInstancesInCluster});
    map {$clusterStats{$cluster}{"$C{5}$_$C{1}"}=delete $clusterStats{$cluster}{$_}} (keys %{$clusterStats{$cluster}});
    push(@statsData,$clusterStats{$cluster})
  }
  my $r_pluginConf=getPluginConf();
  $totalStats{public}.="$C{14}/$r_pluginConf->{maxInstancesPublic}$C{1}" if($r_pluginConf->{maxInstancesPublic});
  $totalStats{private}.="$C{14}/$r_pluginConf->{maxInstancesPrivate}$C{1}" if($r_pluginConf->{maxInstancesPrivate});
  $totalStats{total}.="$C{14}/$r_pluginConf->{maxInstances}$C{1}";
  map {$totalStats{"$C{5}$_$C{1}"}=$totalStats{$_}} (keys %totalStats);
  push(@statsData,\%totalStats);

  my $r_statsLines=formatArray(\@fields,\@statsData,"$C{2}Cluster statistics$C{1}");
  foreach my $statsLine (@{$r_statsLines}) {
    sayPrivate($user,$statsLine);
  }
  return 1;
}

sub hListInstances {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 0) {
    invalidSyntax($user,'listInstances');
    return 0;
  }
  
  my ($p_C,$B)=::initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $self=getPlugin();

  my @fields;
  my $title;
  my @instancesData;
  my $clustPreset=$p_params->[0];
  if(defined $clustPreset) {
    my @clusterPresets=_getConfiguredClusterList();
    if(none {$clustPreset eq $_} @clusterPresets) {
      answer("Invalid cluster \"$clustPreset\" (use !listClusters to list available clusters)");
      return 0;
    }
    return 1 if($checkOnly);
    @fields=map {"$C{5}$_$C{1}"} (qw'clustInstNb instName instNb owner hostState instState PID');
    $title="Instances list for cluster: $clustPreset";
    foreach my $clustInstNb (sort {$a <=> $b} keys %{$self->{clustPresets}{$clustPreset}}) {
      my $instNb=$self->{clustPresets}{$clustPreset}{$clustInstNb};
      my $r_instData=$self->{instData}{$instNb};
      my %instanceData=(clustInstNb => $clustInstNb,
                        instName => $r_instData->{instName},
                        instNb => $instNb,
                        owner => $r_instData->{ownerName},
                        hostState => {spare => 'idle',
                                      inUse => "$C{3}inUse$C{1}",
                                      offline => "$C{4}offline$C{1}",
                                      'offline(stuck)' => "$C{13}error$C{1}"}->{$r_instData->{lobbyState}} // $r_instData->{lobbyState},
                        instState => {launched => "$C{14}launched$C{1}",
                                         restarting => "$C{14}restarting$C{1}",
                                         reloading => "$C{7}reloading$C{1}",
                                         unloaded => "$C{13}unloaded$C{1}",
                                         running => "$C{3}running$C{1}"}->{$r_instData->{state}} // $r_instData->{state},
                        PID => $r_instData->{instPid} // '?');
      map {$instanceData{"$C{5}$_$C{1}"}=delete $instanceData{$_}} (keys %instanceData);
      push(@instancesData,\%instanceData);
    }
    if(! @instancesData) {
      answer("No instance found for cluster: $clustPreset");
      return 1;
    }
  }else{
    return 1 if($checkOnly);
    @fields=map {"$C{5}$_$C{1}"} (qw'instNb instName cluster clustInstNb owner hostState instState PID');
    $title='Global cluster instances list';
    foreach my $instNb (sort {$a <=> $b} keys %{$self->{instData}}) {
      my $r_instData=$self->{instData}{$instNb};
      my %instanceData=(instNb => $instNb,
                        instName => $r_instData->{instName},
                        cluster => $r_instData->{clustPreset},
                        clustInstNb => $r_instData->{clustInstNb},
                        owner => $r_instData->{ownerName},
                        hostState => {spare => 'idle',
                                      inUse => "$C{3}inUse$C{1}",
                                      offline => "$C{4}offline$C{1}",
                                      'offline(stuck)' => "$C{13}error$C{1}"}->{$r_instData->{lobbyState}} // $r_instData->{lobbyState},
                        instState => {launched => "$C{14}launched$C{1}",
                                         restarting => "$C{14}restarting$C{1}",
                                         reloading => "$C{7}reloading$C{1}",
                                         unloaded => "$C{13}unloaded$C{1}",
                                         running => "$C{3}running$C{1}"}->{$r_instData->{state}} // $r_instData->{state},
                        PID => $r_instData->{instPid} // '?');
      map {$instanceData{"$C{5}$_$C{1}"}=delete $instanceData{$_}} (keys %instanceData);
      push(@instancesData,\%instanceData);
    }
    if(! @instancesData) {
      answer('No instance found.');
      return 1;
    }
  }

  my $r_instancesLines=formatArray(\@fields,\@instancesData,"$C{2}$title$C{1}");
  foreach my $instanceLine (@{$r_instancesLines}) {
    sayPrivate($user,$instanceLine);
  }

  return 1;
}

1;
