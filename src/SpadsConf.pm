# Object-oriented Perl module handling SPADS configuration files
#
# Copyright (C) 2008-2013  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package SpadsConf;

use strict;

use FileHandle;
use File::Basename;
use File::Copy;
use Storable qw/nstore retrieve dclone/;

use SimpleLog;

# Internal data ###############################################################

my $moduleVersion='0.11.3a';
my $win=$^O eq 'MSWin32' ? 1 : 0;

my %globalParameters = (lobbyLogin => ["login"],
                        lobbyPassword => ["password"],
                        lobbyHost => ["hostname"],
                        lobbyPort => ["port"],
                        lobbyReconnectDelay => ["integer"],
                        localLanIp => ["ipAddr","star","null"],
                        lobbyFollowRedirect => ["bool"],
                        autoHostPort => ["port"],
                        forceHostIp => ['ipAddr','null'],
                        springConfig => ['readableFile','null'],
                        springServer => ["executableFile"],
                        springServerType => ['springServerType','null'],
                        autoUpdateRelease => ["autoUpdateType","null"],
                        autoUpdateDelay => ["integer"],
                        autoRestartForUpdate => ["autoRestartType"],
                        autoUpdateBinaries => ["binUpdateType"],
                        onBadSpringVersion => ['onBadSpringVersionType','null'],
                        binDir => ["writableDir"],
                        etcDir => ["readableDir"],
                        varDir => ["writableDir"],
                        logDir => ["writableDir"],
                        springDataDir => ["writableDir"],
                        autoReloadArchivesMinDelay => ["integer"],
                        sendRecordPeriod => ["integer"],
                        maxBytesSent => ["integer"],
                        maxLowPrioBytesSent => ["integer"],
                        maxChatMessageLength => ["integer"],
                        maxAutoHostMsgLength => ["integer"],
                        msgFloodAutoKick => ["integerCouple"],
                        statusFloodAutoKick => ["integerCouple"],
                        kickFloodAutoBan => ["integerTriplet"],
                        cmdFloodAutoIgnore => ["integerTriplet"],
                        floodImmuneLevel => ["integer"],
                        maxSpecsImmuneLevel => ['integer'],
                        autoLockClients => ["integer","null"],
                        defaultPreset => ["notNull"],
                        restoreDefaultPresetDelay => ["integer"],
                        masterChannel => ["channel","null"],
                        broadcastChannels => ["channelList","null"],
                        opOnMasterChannel => ["bool"],
                        voteTime => ["integer"],
                        minVoteParticipation => ["integer"],
                        reCallVoteDelay => ["integer"],
                        promoteDelay => ["integer"],
                        botsRank => ["integer"],
                        autoSaveBoxes => ["bool2"],
                        autoLearnMaps => ["bool"],
                        lobbyInterfaceLogLevel => ["integer"],
                        autoHostInterfaceLogLevel => ["integer"],
                        updaterLogLevel => ["integer"],
                        spadsLogLevel => ["integer"],
                        logChanChat => ["bool"],
                        logChanJoinLeave => ["bool"],
                        logBattleChat => ["bool"],
                        logBattleJoinLeave => ["bool"],
                        logGameChat => ["bool"],
                        logGameJoinLeave => ["bool"],
                        logGameServerMsg => ["bool"],
                        logPvChat => ["bool"],
                        alertLevel => ["integer"],
                        alertDelay => ["integer"],
                        alertDuration => ["integer"],
                        promoteMsg => [],
                        promoteChannels => ["channelList","null"],
                        springieEmulation => ["onOffWarnType"],
                        colorSensitivity => ["integer"],
                        dataDumpDelay => ["integer"],
                        allowSettingsShortcut => ["bool"],
                        kickBanDuration => ["integer"],
                        minLevelForIpAddr => ["integer"],
                        userDataRetention => ["dataRetention"],
                        useWin32Process => ["useWin32ProcessType"],
                        pluginsDir => [],
                        autoLoadPlugins => []);

my %spadsSectionParameters = (description => ["notNull"],
                              commandsFile => ["notNull"],
                              mapList => ["ident"],
                              banList => ["ident","null"],
                              preset => ["notNull"],
                              hostingPreset => ["ident"],
                              battlePreset => ["ident"],
                              map => [],
                              rotationType => ["rotationType"],
                              rotationEndGame => ["rotationMode"],
                              rotationEmpty => ["rotationMode"],
                              rotationManual => ['manualRotationMode'],
                              rotationDelay => ["integer","integerRange"],
                              minRankForPasswd => ["integer","integerRange"],
                              minLevelForPasswd => ["integer","integerRange"],
                              midGameSpecLevel => ['integer','integerRange'],
                              autoAddBotNb => ['integer','integerRange'],
                              maxBots => ["integer","integerRange","null"],
                              maxLocalBots => ["integer","integerRange","null"],
                              maxRemoteBots => ["integer","integerRange","null"],
                              localBots => ['botList','null'],
                              allowedLocalAIs => [],
                              maxSpecs => ["integer","integerRange","null"],
                              speedControl => ['bool2'],
                              welcomeMsg => [],
                              welcomeMsgInGame => [],
                              mapLink => [],
                              advertDelay => ['integer','integerRange'],
                              advertMsg => [],
                              ghostMapLink => [],
                              autoSetVoteMode => ["bool"],
                              voteMode => ["voteMode"],
                              votePvMsgDelay => ["integer","integerRange"],
                              voteRingDelay => ["integer","integerRange"],
                              minRingDelay => ["integer","integerRange"],
                              handleSuggestions => ["bool"],
                              ircColors => ['bool'],
                              spoofProtection => ['onOffWarnType'],
                              rankMode => ["rankMode"],
                              skillMode => ['skillMode'],
                              shareId => ["password","null"],
                              autoCallvote => ["bool"],
                              autoLoadMapPreset => ["bool"],
                              hideMapPresets => ["bool"],
                              balanceMode => ["balanceModeType"],
                              clanMode => ["clanModeType"],
                              nbPlayerById => ["nonNullInteger","nonNullIntegerRange"],
                              teamSize => ["nonNullInteger","nonNullIntegerRange"],
                              minTeamSize => ["integer","integerRange"],
                              nbTeams => ["nonNullInteger","nonNullIntegerRange"],
                              extraBox => ["integer","integerRange"],
                              idShareMode => ["idShareModeType"],
                              minPlayers => ["nonNullInteger","nonNullIntegerRange"],
                              endGameCommand => [],
                              endGameCommandEnv => ['null','varAssignments'],
                              endGameCommandMsg => ['null','exitMessages'],
                              endGameAwards => ['bool'],
                              autoLock => ["autoParamType"],
                              autoSpecExtraPlayers => ["bool"],
                              autoBalance => ["autoParamType"],
                              autoFixColors => ["autoParamType"],
                              autoBlockBalance => ["bool"],
                              autoBlockColors => ["bool"],
                              autoStart => ["autoParamType"],
                              autoStop => ['autoStopType'],
                              autoLockRunningBattle => ["bool"],
                              forwardLobbyToGame => ["bool"],
                              noSpecChat => ['bool'],
                              noSpecDraw => ['bool'],
                              unlockSpecDelay => ["integerCouple"],
                              freeSettings => ["settingList"],
                              allowModOptionsValues => ["bool"],
                              allowMapOptionsValues => ["bool"],
                              allowGhostMaps =>["bool"]);

my %hostingParameters = (description => ["notNull"],
                         battleName => ["notNull"],
                         modName => ["notNull"],
                         port => ["port"],
                         natType => ["integer","integerRange"],
                         password => ["password"],
                         maxPlayers => ["maxPlayersType"],
                         minRank => ["integer","integerRange"]);

my %battleParameters = (description => ["notNull"],
                        startpostype => ["integer","integerRange"],
                        resetoptions => ["bool"],
                        disabledunits => ["disabledUnitList","null"]);

my %paramTypes = (login => '[\w\[\]]{2,20}',
                  password => '[^\s]+',
                  hostname => '\w[\w\-\.]*',
                  port => sub { return ($_[0] =~ /^\d+$/ && $_[0] < 65536) },
                  integer => '\d+',
                  nonNullInteger => '[1-9]\d*',
                  ipAddr => '\d+\.\d+\.\d+\.\d+',
                  star => '\*',
                  null => "",
                  executableFile => sub { return (-f $_[0] && -x $_[0]) },
                  autoUpdateType => "(stable|testing|unstable|contrib)",
                  autoRestartType => "(on|off|whenEmpty|whenOnlySpec)",
                  onBadSpringVersionType => '(closeBattle|quit)',
                  readableDir => sub { return (-d $_[0] && -x $_[0] && -r $_[0]) },
                  writableDir => sub { return (-d $_[0] && -x $_[0] && -r $_[0] && -w $_[0]) },
                  integerCouple => '\d+;\d+',
                  integerTriplet => '\d+;\d+;\d+',
                  bool => '[01]',
                  bool2 => '[012]',
                  ident => '[\w\.\-]+',
                  channel => '[\w\[\]\ ]+',
                  channelList => '([\w\[\]\ ]+(;[\w\[\]\ ]+)*)?',
                  disabledUnitList => '(\-\*|\-\w+|\w+)(;(\-\*|\-\w+|\w+))*',
                  notNull => '.+',
                  readableFile => sub { return (-f $_[0] && -r $_[0]) },
                  rotationType => '(map(;[\w\.\-]+)?|preset)',
                  rotationMode => "(off|random|order)",
                  manualRotationMode => '(random|order)',
                  maxPlayersType => sub { return (($_[0] =~ /^\d+$/ && $_[0] < 252) || ($_[0] =~ /^(\d+)\-(\d+)$/ && $1 < $2 && $2 < 252)) },
                  integerRange => '\d+\-\d+',
                  nonNullIntegerRange => '[1-9]\d*\-\d+',
                  float => '\d+(\.\d*)?',
                  balanceModeType => "(clan|clan;skill|skill|random)",
                  clanModeType => '(tag(\(\d*\))?(;pref(\(\d*\))?)?|pref(\(\d*\))?(;tag(\(\d*\))?)?)',
                  idShareModeType => "(all|auto|manual|clan|off)",
                  deathMode => "(killall|com|comcontrol)",
                  autoParamType => "(on|off|advanced)",
                  autoStopType => '(gameOver|noOpponent|onlySpec|off)',
                  onOffWarnType => "(on|off|warn)",
                  voteMode => "(normal|away)",
                  rankMode => '(account|ip|[0-7])',
                  skillMode => '(rank|TrueSkill)',
                  varAssignments => '\w+=[^;]*(;\w+=[^;]*)*',
                  exitMessages => '(\(\d+(-\d+)?(,\d+(-\d+)?)*\))?[^\|]+(\|(\(\d+(-\d+)?(,\d+(-\d+)?)*\))?[^\|]+)*',
                  dataRetention => '(-1|\d+);(-1|\d+);(-1|\d+)',
                  useWin32ProcessType => sub { return (($win && $_[0] =~ /^[01]$/) || $_[0] eq '0') },
                  springServerType => '(dedicated|headless)',
                  binUpdateType => sub {
                                     return 1 if($_[0] eq "no");
                                     return 0 unless($win);
                                     return 1 if($_[0] eq "yes" || $_[0] eq "unitsync" || $_[0] eq "server");
                                     return 0;
                                   },
                  settingList => sub {
                                   my @sets=split(/;/,$_[0]);
                                   foreach my $set (@sets) {
                                     $set=$1 if($set =~ /^([^\(]+)\([^\)]+\)$/);
                                     return 0 unless(exists($spadsSectionParameters{$set}));
                                   }
                                   return 1;
                                 },
                  botList => '[\w\[\]]{2,20} \w+ [^ \;][^\;]*(;[\w\[\]]{2,20} \w+ [^ \;][^\;]*)*',
                  db => '[^\/]+\/[^\@]+\@(?i:dbi)\:\w+\:\w.*');

my @banListsFields=(["accountId","name","country","cpu","rank","access","bot","level","ip"],["banType","startDate","endDate","reason"]);
my @preferencesListsFields=(["accountId"],["autoSetVoteMode","voteMode","votePvMsgDelay","voteRingDelay","minRingDelay","handleSuggestions","password","rankMode",'skillMode',"shareId","spoofProtection",'ircColors','clan']);
my @usersFields=(["accountId","name","country","cpu","rank","access","bot","auth"],["level"]);
my @levelsFields=(["level"],["description"]);
my @commandsFields=(["source","status","gameState"],["directLevel","voteLevel"]);
my @mapBoxesFields=(["mapName","nbTeams"],["boxes"]);
my @mapHashesFields=(["springMajorVersion","mapName"],["mapHash"]);
my @userDataFields=(["accountId"],["country","cpu","rank","timestamp","ips",'names']);

# Constructor #################################################################

sub new {
  my ($objectOrClass,$confFile,$sLog,$p_macros,$p_previousInstance) = @_;
  $p_previousInstance=0 unless(defined $p_previousInstance);
  my $class = ref($objectOrClass) || $objectOrClass;

  my $p_conf = loadSettingsFile($sLog,$confFile,\%globalParameters,\%spadsSectionParameters,$p_macros);
  if(! checkSpadsConfig($sLog,$p_conf)) {
    $sLog->log("Unable to load main configuration parameters",1);
    return 0;
  }

  $sLog=SimpleLog->new(logFiles => [$p_conf->{""}->{logDir}."/spads.log",""],
                       logLevels => [$p_conf->{""}->{spadsLogLevel},3],
                       useANSICodes => [0,1],
                       useTimestamps => [1,0],
                       prefix => "[SPADS] ");

  my $p_hConf =  loadSettingsFile($sLog,$p_conf->{""}->{etcDir}."/hostingPresets.conf",{},\%hostingParameters,$p_macros);
  if(! checkHConfig($sLog,$p_conf,$p_hConf)) {
    $sLog->log("Unable to load hosting presets",1);
    return 0;
  }

  my $p_bConf =  loadSettingsFile($sLog,$p_conf->{""}->{etcDir}."/battlePresets.conf",{},\%battleParameters,$p_macros,1);
  if(! checkBConfig($sLog,$p_conf,$p_bConf)) {
    $sLog->log("Unable to load battle presets",1);
    return 0;
  }
  my $p_banLists=loadTableFile($sLog,$p_conf->{""}->{etcDir}."/banLists.conf",\@banListsFields,$p_macros);
  my $p_mapLists=loadSimpleTableFile($sLog,$p_conf->{""}->{etcDir}."/mapLists.conf",$p_macros);
  if(!checkConfigLists($sLog,$p_conf,$p_banLists,$p_mapLists)) {
    $sLog->log("Unable to load banLists or mapLists configuration files",1);
    return 0;
  }

  my $defaultPreset=$p_conf->{""}->{defaultPreset};
  my $commandsFile=$p_conf->{$defaultPreset}->{commandsFile}->[0];
  my $p_users=loadTableFile($sLog,$p_conf->{""}->{etcDir}."/users.conf",\@usersFields,$p_macros);
  my $p_levels=loadTableFile($sLog,$p_conf->{""}->{etcDir}."/levels.conf",\@levelsFields,$p_macros);
  my $p_commands=loadTableFile($sLog,$p_conf->{""}->{etcDir}."/$commandsFile",\@commandsFields,$p_macros,1);
  my $p_help=loadSimpleTableFile($sLog,$p_conf->{""}->{binDir}."/help.dat",$p_macros,1);
  my $p_helpSettings=loadHelpSettingsFile($sLog,$p_conf->{""}->{binDir}."/helpSettings.dat",$p_macros,1);
  
  touch($p_conf->{""}->{varDir}."/bans.dat") unless(-f $p_conf->{""}->{varDir}."/bans.dat");
  my $p_bans=loadTableFile($sLog,$p_conf->{""}->{varDir}."/bans.dat",\@banListsFields,$p_macros);

  if(! checkNonEmptyHash($p_users,$p_levels,$p_commands,$p_help,$p_helpSettings,$p_bans)) {
    $sLog->log("Unable to load commands, help and permission system",1);
    return 0;
  }

  touch($p_conf->{""}->{varDir}."/preferences.dat") unless(-f $p_conf->{""}->{varDir}."/preferences.dat");
  my $p_preferences=loadFastTableFile($sLog,$p_conf->{""}->{varDir}."/preferences.dat",\@preferencesListsFields,{});
  if(! %{$p_preferences}) {
    $sLog->log("Unable to load preferences",1);
    return 0;
  }else{
    $p_preferences=preparePreferences($sLog,$p_preferences->{""});
  }

  my $p_mapBoxes=loadFastTableFile($sLog,$p_conf->{""}->{etcDir}."/mapBoxes.conf",\@mapBoxesFields,$p_macros);
  if(! %{$p_mapBoxes}) {
    $sLog->log("Unable to load map boxes",1);
    return 0;
  }

  touch($p_conf->{""}->{varDir}."/savedBoxes.dat") unless(-f $p_conf->{""}->{varDir}."/savedBoxes.dat");
  my $p_savedBoxes=loadFastTableFile($sLog,$p_conf->{""}->{varDir}."/savedBoxes.dat",\@mapBoxesFields,{});
  if(! %{$p_savedBoxes}) {
    $sLog->log("Unable to load saved map boxes",1);
    return 0;
  }

  touch($p_conf->{""}->{varDir}."/mapHashes.dat") unless(-f $p_conf->{""}->{varDir}."/mapHashes.dat");
  my $p_mapHashes=loadFastTableFile($sLog,$p_conf->{""}->{varDir}."/mapHashes.dat",\@mapHashesFields,{});
  if(! %{$p_mapHashes}) {
    $sLog->log("Unable to load map hashes",1);
    return 0;
  }

  touch($p_conf->{""}->{varDir}."/userData.dat") unless(-f $p_conf->{""}->{varDir}."/userData.dat");
  my $p_userData=loadFastTableFile($sLog,$p_conf->{""}->{varDir}."/userData.dat",\@userDataFields,{});
  if(! %{$p_userData}) {
    my $savExtension=1;
    while(-f $p_conf->{""}->{varDir}."/userData.dat.sav$savExtension" && $savExtension < 100) {
      ++$savExtension;
    }
    move($p_conf->{""}->{varDir}."/userData.dat",$p_conf->{""}->{varDir}."/userData.dat.sav$savExtension");
    touch($p_conf->{""}->{varDir}."/userData.dat");
    $sLog->log("Unable to load user data, user data file reinitialized (old file renamed to \"userData.dat.sav.$savExtension\")",2);
    $p_userData=loadFastTableFile($sLog,$p_conf->{""}->{varDir}."/userData.dat",\@userDataFields,{});
    if(! %{$p_userData}) {
      $sLog->log("Unable to load user data after file reinitialization, giving up!",1);
      return 0;
    }
  }
  my ($p_accountData,$p_countryCpuIds,$p_ipIds,$p_nameIds)=buildUserDataCaches($p_userData->{""});

  my $p_mapInfoCache={};
  if(-f $p_conf->{""}->{varDir}.'/mapInfoCache.dat') {
    $p_mapInfoCache=retrieve($p_conf->{""}->{varDir}.'/mapInfoCache.dat');
    if(! defined $p_mapInfoCache) {
      $sLog->log("Unable to load map info cache",1);
      return 0;
    }
  }

  my $self = {
    presets => $p_conf,
    hPresets => $p_hConf,
    bPresets => $p_bConf,
    banLists => $p_banLists,
    mapLists => $p_mapLists,
    commands => $p_commands,
    levels => $p_levels,
    mapBoxes => $p_mapBoxes->{""},
    savedBoxes => $p_savedBoxes->{""},
    mapHashes => $p_mapHashes->{""},
    users => $p_users->{""},
    help => $p_help,
    helpSettings => $p_helpSettings,
    log => $sLog,
    conf => $p_conf->{""},
    values => {},
    hSettings => {},
    hValues => {},
    bSettings => {},
    bValues => {},
    bans => $p_bans->{""},
    preferences => $p_preferences,
    accountData => $p_accountData,
    countryCpuIds => $p_countryCpuIds,
    ipIds => $p_ipIds,
    nameIds => $p_nameIds,
    mapInfo => $p_mapInfoCache,
    maps => {},
    orderedMaps => [],
    ghostMaps => {},
    orderedGhostMaps => [],
    macros => $p_macros,
    pluginsConf => {}
  };

  bless ($self, $class);

  $self->removeExpiredBans();

  if($self->{conf}->{autoLoadPlugins} ne '') {
    my @pluginNames=split(/;/,$self->{conf}->{autoLoadPlugins});
    foreach my $pluginName (@pluginNames) {
      if(! $self->loadPluginConf($pluginName)) {
        $self->{log}->log("Unable to load configuration for plugin \"$pluginName\"",1);
        return 0;
      }
    }
  }

  $self->applyPreset($self->{conf}->{defaultPreset},1);

  if($p_previousInstance) {
    $self->{conf}=$p_previousInstance->{conf};
    $self->{hSettings}=$p_previousInstance->{hSettings};
    $self->{bSettings}=$p_previousInstance->{bSettings};
    $self->{maps}=$p_previousInstance->{maps};
    $self->{orderedMaps}=$p_previousInstance->{orderedMaps};
    $self->{ghostMaps}=$p_previousInstance->{ghostMaps};
    $self->{orderedGhostMaps}=$p_previousInstance->{orderedGhostMaps};
    foreach my $pluginName (keys %{$p_previousInstance->{pluginsConf}}) {
      $self->{pluginsConf}->{$pluginName}=$p_previousInstance->{pluginsConf}->{$pluginName} unless(exists $self->{pluginsConf}->{$pluginName});
      $self->{pluginsConf}->{$pluginName}->{conf}=$p_previousInstance->{pluginsConf}->{$pluginName}->{conf};
    }
  }

  return $self;
}


# Accessor ####################################################################

sub getVersion {
  return $moduleVersion;
}

# Internal functions ##########################################################

sub touch {
  my $file=shift;
  open(TMP,">$file");
  close(TMP);
}

sub aindex (\@$;$) {
  my ($aref, $val, $pos) = @_;
  for ($pos ||= 0; $pos < @$aref; $pos++) {
    return $pos if $aref->[$pos] eq $val;
  }
  return -1;
}

sub checkValue {
  my ($value,$p_types)=@_;
  return 1 unless(@{$p_types});
  foreach my $type (@{$p_types}) {
    my $checkFunction=$paramTypes{$type};
    if(ref($checkFunction)) {
      return 1 if(&{$checkFunction}($value));
    }else{
      return 1 if($value =~ /^$checkFunction$/);
    }
  }
  return 0;
}

sub checkNonEmptyHash {
  foreach my $p_hash (@_) {
    return 0 unless(%{$p_hash});
  }
  return 1;
}

sub ipToInt {
  my $ip=shift;
  my $int=0;
  $int=$1*(256**3)+$2*(256**2)+$3*256+$4 if ($ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  return $int;
}

sub findMatchingData {
  my ($p_data,$p_filters,$normalSearch)=@_;
  $normalSearch=1 unless(defined $normalSearch);
  my %data=%{$p_data};
  my @filters=@{$p_filters};
  my @matchingData;
  for my $i (0..$#filters) {
    my @filterData=@{$filters[$i]};
    my %filter=%{$filterData[0]};
    my $matched=1;
    foreach my $field (keys %data) {
      next if($data{$field} eq "");
      if(! (exists $filter{$field} && defined $filter{$field} && $filter{$field} ne "")) {
        next if($normalSearch);
        $matched=0;
        last;
      }
      my @filterFieldValues=split(",",$filter{$field});
      my $matchedField=0;
      my $fieldData=$data{$field};
      $fieldData=$1 if($field eq "accountId" && $fieldData =~ /^([^\(]+)\(/);
      foreach my $filterFieldValue (@filterFieldValues) {
        if($field eq "accountId" && $filterFieldValue =~ /^([^\(]+)(\(.*)$/) {
          my ($filterAccountId,$filterUserName)=($1,$2);
          if($fieldData =~ /^\(/) {
            $filterFieldValue=$filterUserName;
          }else{
            $filterFieldValue=$filterAccountId;
          }
        }
        if($normalSearch && $fieldData =~ /^\d+$/ && $filterFieldValue =~ /^(\d+)\-(\d+)$/) {
          if($1 <= $fieldData && $fieldData <= $2) {
            $matchedField=1;
            last;
          }
        }elsif($normalSearch && $fieldData =~ /^\d+\.\d+\.\d+\.\d+$/ && $filterFieldValue =~ /^(\d+\.\d+\.\d+\.\d+)\-(\d+\.\d+\.\d+\.\d+)$/) {
          my ($startIp,$endIp)=(ipToInt($1),ipToInt($2));
          my $ip=ipToInt($fieldData);
          if($startIp <= $ip && $ip <= $endIp) {
            $matchedField=1;
            last;
          }
        }elsif($normalSearch && $filterFieldValue =~ /^~(.*)$/ && $fieldData =~ /^$1$/) {
          $matchedField=1;
          last;
        }elsif($fieldData eq $filterFieldValue) {
          $matchedField=1;
          last;
        }elsif($field eq 'status' && $fieldData eq 'playing' && $filterFieldValue eq 'player') {
          $matchedField=1;
          last;
        }
      }
      $matched=$matchedField;
      last unless($matched);
    }
    push(@matchingData,$filters[$i]->[1]) if($matched);
  }
  return \@matchingData;
}

sub mergeMapArrays {
  my ($p_orderedMaps,$p_orderedGhostMaps)=@_;

  my $maxIndex=-1;
  $maxIndex=$#{$p_orderedMaps} if(defined $p_orderedMaps);
  $maxIndex=$#{$p_orderedGhostMaps} if(defined $p_orderedGhostMaps && $#{$p_orderedGhostMaps} > $maxIndex);

  my @array;
  for my $i (0..$maxIndex) {
    push(@array,@{$p_orderedMaps->[$i]}) if(defined $p_orderedMaps && defined $p_orderedMaps->[$i]);
    push(@array,@{$p_orderedGhostMaps->[$i]}) if(defined $p_orderedGhostMaps && defined $p_orderedGhostMaps->[$i]);
  }

  return \@array;
}

# Internal functions - Configuration ##########################################

sub preProcessConfFile {
  my ($sLog,$p_content,$file,$p_macros,$p_alreadyLoaded)=@_;
  $p_alreadyLoaded->{$file}=1;
  my $fh=new FileHandle($file,"r");
  if(! defined $fh) {
    $sLog->log("Unable to read configuration file ($file: $!)",1);
    return 0;
  }
  while(<$fh>) {
    foreach my $macroName (keys %{$p_macros}) {
      s/\%$macroName\%/$p_macros->{$macroName}/g;
    }
    if(/^\{(.*)\}$/) {
      my $subConfFile=$1;
      if(($win && $subConfFile !~ /^[a-zA-Z]\:/) || (! $win && $subConfFile !~ /^\//)) {
        my $etcPath=dirname($file);
        $subConfFile=$etcPath."/".$subConfFile;
      }
      if(exists $p_alreadyLoaded->{$subConfFile}) {
        $fh->close();
        $sLog->log("Recursive include of $subConfFile (from $file)",1);
        return 0;
      }
      if(! preProcessConfFile($sLog,$p_content,$subConfFile,$p_macros,$p_alreadyLoaded)) {
        $fh->close();
        return 0;
      }
    }else{
      push(@{$p_content},$_);
    }
  }
  $fh->close();
  delete $p_alreadyLoaded->{$file};
  return 1;
}

sub loadSettingsFile {
  my ($sLog,$cFile,$p_globalParams,$p_sectionParams,$p_macros,$caseInsensitiveNoCheck)=@_;

  $caseInsensitiveNoCheck=0 unless(defined $caseInsensitiveNoCheck);
  my $currentSection="";
  my %newConf=("" => {});

  my @confData;
  return {} unless(preProcessConfFile($sLog,\@confData,$cFile,$p_macros,{}));

  my @invalidGlobalParams;
  my @invalidSectionParams;
  while($_=shift(@confData)) {
    next if(/^\s*(\#.*)?$/);
    if(/^\s*\[([^\]]+)\]\s*$/) {
      $currentSection=$1;
      $newConf{$currentSection}={} unless(exists $newConf{$currentSection});
      next;
    }elsif(/^([^:]+):(.*)$/) {
      my ($param,$value)=($1,$2);
      $param=lc($param) if($caseInsensitiveNoCheck);
      if($currentSection) {
        if(! exists $p_sectionParams->{$param}) {
          if(!$caseInsensitiveNoCheck) {
            $sLog->log("Ignoring invalid section parameter ($param)",2);
            next;
          }
        }
        my @values=split(/\|/,$value);
        $values[0]="" unless(defined $values[0]);
        if(exists $p_sectionParams->{$param}) {
          foreach my $v (@values) {
            if(! checkValue($v,$p_sectionParams->{$param})) {
              push(@invalidSectionParams,$param);
              last;
            }
          }
        }
        if(exists $newConf{$currentSection}->{$param}) {
          $sLog->log("Duplicate parameter definitions in configuration file \"$cFile\" (section \"$currentSection\", parameter \"$param\")",2);
        }
        $newConf{$currentSection}->{$param}=\@values;
      }else{
        if(! exists $p_globalParams->{$param}) {
          $sLog->log("Ignoring invalid global parameter ($param)",2);
          next;
        }
        push(@invalidGlobalParams,$param) unless(checkValue($value,$p_globalParams->{$param}));
        if(exists $newConf{""}->{$param}) {
          $sLog->log("Duplicate parameter definitions in configuration file \"$cFile\" (parameter \"$param\")",2);
        }
        $newConf{""}->{$param}=$value;
      }
      next;
    }else{
      chomp($_);
      $sLog->log("Ignoring invalid configuration line in file \"$cFile\" ($_)",2);
      next;
    }
  }

  if(@invalidGlobalParams) {
    $sLog->log("Configuration file \"$cFile\" contains inconsistent values for following global parameter(s): ".join(",",@invalidGlobalParams),1);
    return {};
  }

  if(@invalidSectionParams) {
    $sLog->log("Configuration file \"$cFile\" contains inconsistent values for following section parameter(s): ".join(",",@invalidSectionParams),1);
    return {};
  }

  return \%newConf;
}

sub loadTableFile {
  my ($sLog,$cFile,$p_fieldsArrays,$p_macros,$caseInsensitive)=@_;
  $caseInsensitive=0 unless(defined $caseInsensitive);

  my @confData;
  return {} unless(preProcessConfFile($sLog,\@confData,$cFile,$p_macros,{}));

  my @pattern;
  my $section="";
  my %newConf=("" => []);

  while($_=shift(@confData)) {
    my $line=$_;
    chomp($line);
    if(/^\s*\#\?\s*([^\s]+)\s*$/) {
      my $patternString=$1;
      my @subPatternStrings=split(/\|/,$patternString);
      @pattern=();
      for my $i (0..$#subPatternStrings) {
        my @splitSubPattern=split(/\:/,$subPatternStrings[$i]);
        $pattern[$i]=\@splitSubPattern;
      }
      if($#pattern != $#{$p_fieldsArrays}) {
        $sLog->log("Invalid pattern \"$line\" in configuration file \"$cFile\" (number of fields invalid)",1);
        return {};
      }
      for my $index (0..$#pattern) {
        my @fields=@{$pattern[$index]};
        foreach my $field (@fields) {
          if(! grep(/^$field$/,@{$p_fieldsArrays->[$index]})) {
            $sLog->log("Invalid pattern \"$line\" in configuration file \"$cFile\" (invalid field: \"$field\")",1);
            return {};
          }
        }
      }
      next;
    }
    next if(/^\s*(\#.*)?$/);
    if(/^\s*\[([^\]]+)\]\s*$/) {
      $section=$1;
      $section=lc($section) if($caseInsensitive);
      if(exists $newConf{$section}) {
        $sLog->log("Duplicate section definitions in configuration file \"$cFile\" ($section)",2);
      }else{
        $newConf{$section}=[];
      }
      next;
    }
    my $p_data=parseTableLine($sLog,\@pattern,$line);
    if(@{$p_data}) {
      push(@{$newConf{$section}},$p_data);
    }else{
      $sLog->log("Invalid configuration line in file \"$cFile\" ($line)",1);
      return {};
    }
  }

  return \%newConf;

}

sub parseTableLine {
  my ($sLog,$p_pattern,$line,$iter)=@_;
  $iter=0 unless(defined $iter);
  my $p_subPattern=$p_pattern->[$iter];
  my $subPatSize=$#{$p_subPattern};
  my %hashData;
  for my $index (0..($subPatSize-1)) {
    if($line =~ /^([^:]*):(.*)$/) {
      $hashData{$p_subPattern->[$index]}=$1;
      $line=$2;
    }else{
      $sLog->log("Unable to parse fields in following configuration data \"$line\"",1);
      return [];
    }
  }
  if($line =~ /^([^\|]*)\|(.*)$/) {
    $hashData{$p_subPattern->[$subPatSize]}=$1;
    $line=$2;
  }else{
    $hashData{$p_subPattern->[$subPatSize]}=$line;
    $line="";
  }
  my @data=(\%hashData);
  if($iter < $#{$p_pattern}) {
    my $p_data=parseTableLine($sLog,$p_pattern,$line,++$iter);
    return [] unless(@{$p_data});
    push(@data,@{$p_data});
  }
  return \@data;
}

sub loadSimpleTableFile {
  my ($sLog,$cFile,$p_macros,$caseInsensitive)=@_;
  $caseInsensitive=0 unless(defined $caseInsensitive);

  my @confData;
  return {} unless(preProcessConfFile($sLog,\@confData,$cFile,$p_macros,{}));

  my $section="";
  my %newConf=("" => []);

  while($_=shift(@confData)) {
    my $line=$_;
    next if(/^\s*(\#.*)?$/);
    if(/^\s*\[([^\]]+)\]\s*$/) {
      $section=$1;
      $section=lc($section) if($caseInsensitive);
      $newConf{$section}=[] unless(exists $newConf{$section});
      next;
    }
    chomp($line);
    if($section) {
      push(@{$newConf{$section}},$line);
    }else{
      $sLog->log("Invalid configuration file \"$cFile\" (missing section declaration)",1);
      return {};
    }
  }

  return \%newConf;
}

sub loadFastTableFile {
  my ($sLog,$cFile,$p_fieldsArrays,$p_macros)=@_;
  my @confData;

  return {} unless(preProcessConfFile($sLog,\@confData,$cFile,$p_macros,{}));

  my @pattern;
  my %newConf;

  while($_=shift(@confData)) {
    my $line=$_;
    chomp($line);
    if(/^\s*\#\?\s*([^\s]+)\s*$/) {
      my $patternString=$1;
      my @subPatternStrings=split(/\|/,$patternString);
      @pattern=();
      for my $i (0..$#subPatternStrings) {
        my @splitSubPattern=split(/\:/,$subPatternStrings[$i]);
        $pattern[$i]=\@splitSubPattern;
      }
      if($#pattern != $#{$p_fieldsArrays}) {
        $sLog->log("Invalid pattern \"$line\" in configuration file \"$cFile\" (number of fields invalid)",1);
        return {};
      }
      for my $index (0..$#pattern) {
        my @fields=@{$pattern[$index]};
        foreach my $field (@fields) {
          if(! grep(/^$field$/,@{$p_fieldsArrays->[$index]})) {
            $sLog->log("Invalid pattern \"$line\" in configuration file \"$cFile\" (invalid field: \"$field\")",1);
            return {};
          }
        }
      }
      next;
    }
    next if(/^\s*(?:\#.*)?$/);
    my @subDataStrings=split(/\|/,$line,-1);
    if($#subDataStrings != $#pattern) {
      $sLog->log("Invalid number of fields in file \"$cFile\" ($line)",1);
      return {};
    }
    my $p_nextKeyData=\%newConf;
    for my $index (0..$#pattern) {
      my @fields=split(/\:/,$subDataStrings[$index],-1);
      if($#fields != $#{$pattern[$index]}) {
        $sLog->log("Invalid number of subfields in file \"$cFile\" ($line)",1);
        return {};
      }
      if($index == 0) {
        foreach my $keyVal (@fields) {
          $p_nextKeyData->{$keyVal}={} unless(exists $p_nextKeyData->{$keyVal});
          $p_nextKeyData=$p_nextKeyData->{$keyVal};
        }
      }else{
        $sLog->log("Duplicate entry in file \"$cFile\" ($line)",2) if(%{$p_nextKeyData});
        foreach my $fieldIndex (0..$#{$pattern[$index]}) {
          $p_nextKeyData->{$pattern[$index]->[$fieldIndex]}=$fields[$fieldIndex];
        }
      }
    }
  }
  return {"" => \%newConf};
}

sub loadHelpSettingsFile {
  my ($sLog,$cFile,$p_macros)=@_;
  my $p_helpSettingsRaw=loadSimpleTableFile($sLog,$cFile,$p_macros);
  return {} unless(%{$p_helpSettingsRaw});
  my %helpSettings=();
  foreach my $setting (keys %{$p_helpSettingsRaw}) {
    next if($setting eq "");
    if($setting =~ /^(\w+):(\w+)$/) {
      my ($type,$name,$nameLc)=(lc($1),$2,lc($2));
      $helpSettings{$type}={} unless(exists $helpSettings{$type});
      if(exists $helpSettings{$type}->{$nameLc}) {
        $sLog->log("Duplicate \"$type:$nameLc\" setting definition in help file \"$cFile\"",2);
      }else{
        $helpSettings{$type}->{$nameLc}={};
      }
      $helpSettings{$type}->{$nameLc}->{name}=$name;
      my @content;
      my $index=0;
      $content[$index]=[];
      foreach my $helpLine (@{$p_helpSettingsRaw->{$setting}}) {
        if($helpLine eq "-") {
          $index++;
          $content[$index]=[];
          next;
        }
        push(@{$content[$index]},$helpLine);
      }
      $helpSettings{$type}->{$nameLc}->{explicitName}=$content[0];
      $helpSettings{$type}->{$nameLc}->{description}=$content[1];
      $helpSettings{$type}->{$nameLc}->{format}=$content[2];
      $helpSettings{$type}->{$nameLc}->{default}=$content[3];
    }else{
      $sLog->log("Invalid help section \"$setting\" in file \"$cFile\"",1);
      return {};
    }
  }
  return \%helpSettings;
}

sub loadPluginConf {
  my ($self,$pluginName)=@_;
  if(! exists $self->{pluginsConf}->{$pluginName}) {
    if($self->{conf}->{pluginsDir} ne '') {
      my $quotedPluginDir=quotemeta($self->{conf}->{pluginsDir});
      unshift(@INC,$self->{conf}->{pluginsDir}) unless(grep {/^$quotedPluginDir$/} @INC);
    }
    eval "use $pluginName";
    if($@) {
      $self->{log}->log("Unable to load plugin module \"$pluginName\": $@",1);
      return 0;
    }
    my $hasConf;
    eval "\$hasConf=$pluginName->can('getParams')";
    return 1 unless($hasConf);
  }
  my $p_pluginParams;
  eval "\$p_pluginParams=$pluginName->getParams()";
  if($@) {
    $self->{log}->log("Unable to get parameters for plugin \"$pluginName\": $@",1);
    return 0;
  }
  my ($p_globalParams,$p_presetParams)=@{$p_pluginParams};
  $p_globalParams={} unless(defined $p_globalParams);
  $p_presetParams={} unless(defined $p_presetParams);
  return 1 unless(%{$p_globalParams} || %{$p_presetParams});
  my $p_pluginPresets = loadSettingsFile($self->{log},"$self->{conf}->{etcDir}/$pluginName.conf",$p_globalParams,$p_presetParams,$self->{macros});
  return 0 unless($self->checkPluginConfig($pluginName,$p_pluginPresets,$p_globalParams,$p_presetParams));
  my ($p_commands,$p_help)=({},{});
  if(exists $p_pluginPresets->{''}->{commandsFile}) {
    my $commandsFile=$p_pluginPresets->{''}->{commandsFile};
    $p_commands=loadTableFile($self->{log},$self->{conf}->{etcDir}."/$commandsFile",\@commandsFields,$self->{macros},1);
    if(! exists $p_pluginPresets->{''}->{helpFile}) {
      $self->{log}->log("A commands file without associated help file is defined for plugin $pluginName",1);
      return 0;
    }
    my $helpFile=$p_pluginPresets->{''}->{helpFile};
    $p_help=loadSimpleTableFile($self->{log},$self->{conf}->{pluginsDir}."/$helpFile",$self->{macros},1);
    if(! checkNonEmptyHash($p_commands,$p_help)) {
      $self->{log}->log("Unable to load commands, help and permission system for plugin $pluginName",1);
      return 0;
    }
  }
  $self->{log}->log("Reloading configuration of plugin $pluginName",4) if(exists $self->{pluginsConf}->{$pluginName});
  $self->{pluginsConf}->{$pluginName}={ presets => $p_pluginPresets,
                                        commands => $p_commands,
                                        help => $p_help,
                                        conf => $p_pluginPresets->{''},
                                        values => {} };
  return 1;
}

sub checkPluginConfig {
  my ($self,$pluginName,$p_conf,$p_globalParams,$p_presetParams)=@_;
  my $sLog=$self->{log};

  return 0 unless(defined $p_conf && %{$p_conf});

  my @missingParams;
  foreach my $requiredGlobalParam (keys %{$p_globalParams}) {
    if(! exists $p_conf->{''}->{$requiredGlobalParam}) {
      push(@missingParams,$requiredGlobalParam);
    }
  }
  if(@missingParams) {
    my $mParams=join(",",@missingParams);
    $sLog->log("Incomplete plugin configuration for $pluginName (missing global parameters: $mParams)",1);
    return 0;
  }

  if(%{$p_presetParams}) {
    my $defaultPreset=$self->{conf}->{defaultPreset};
    if(! exists $p_conf->{$defaultPreset}) {
      $sLog->log("Invalid plugin configuration for $pluginName: default preset \"$defaultPreset\" does not exist",1);
      return 0;
    }
    foreach my $requiredSectionParam (keys %{$p_presetParams}) {
      push(@missingParams,$requiredSectionParam) unless(exists $p_conf->{$defaultPreset}->{$requiredSectionParam});
    }
    if(@missingParams) {
      my $mParams=join(",",@missingParams);
      $sLog->log("Incomplete plugin configuration for $pluginName (missing parameter(s) in default preset: $mParams)",1);
      return 0;
    }
  }

  return 1;
}

sub checkSpadsConfig {
  my ($sLog,$p_conf)=@_;

  return 0 unless(%{$p_conf});

  my @missingParams;
  foreach my $requiredGlobalParam (keys %globalParameters) {
    if(! exists $p_conf->{""}->{$requiredGlobalParam}) {
      push(@missingParams,$requiredGlobalParam);
    }
  }
  if(@missingParams) {
    my $mParams=join(",",@missingParams);
    $sLog->log("Incomplete SPADS configuration (missing global parameters: $mParams)",1);
    return 0;
  }
  my $defaultPreset=$p_conf->{""}->{defaultPreset};
  if(! exists $p_conf->{$defaultPreset}) {
    $sLog->log("Invalid SPADS configuration: default preset \"$defaultPreset\" does not exist",1);
    return 0;
  }
  foreach my $requiredSectionParam (keys %spadsSectionParameters) {
    if(! exists $p_conf->{$defaultPreset}->{$requiredSectionParam}) {
      push(@missingParams,$requiredSectionParam);
    }
  }
  if(@missingParams) {
    my $mParams=join(",",@missingParams);
    $sLog->log("Incomplete SPADS configuration (missing parameter(s) in default preset: $mParams)",1);
    return 0;
  }
  foreach my $preset (keys %{$p_conf}) {
    next if($preset eq "");
    if(exists $p_conf->{$preset}->{preset} && $p_conf->{$preset}->{preset}->[0] ne $preset) {
      $sLog->log("The default value of parameter \"preset\" ($p_conf->{$preset}->{preset}->[0]) must be the name of the preset ($preset)",1);
      return 0;
    }
  }

  return 1;
}

sub checkHConfig {
  my ($sLog,$p_conf,$p_hConf)=@_;

  return 0 unless(%{$p_conf});

  my $defaultPreset=$p_conf->{""}->{defaultPreset};
  my $defaultHPreset=$p_conf->{$defaultPreset}->{hostingPreset}->[0];
  if(! exists $p_hConf->{$defaultHPreset}) {
    $sLog->log("Invalid hosting settings configuration: default hosting preset \"$defaultHPreset\" does not exist",1);
    return 0;
  }
  my @missingParams;
  foreach my $requiredParam (keys %hostingParameters) {
    if(! exists $p_hConf->{$defaultHPreset}->{$requiredParam}) {
      push(@missingParams,$requiredParam);
    }
  }
  if(@missingParams) {
    my $mParams=join(",",@missingParams);
    $sLog->log("Incomplete hosting settings configuration (missing parameter(s) in default hosting preset: $mParams)",1);
    return 0;
  }

  return 1;
}

sub checkBConfig {
  my ($sLog,$p_conf,$p_bConf)=@_;

  return 0 unless(%{$p_conf});

  my $defaultPreset=$p_conf->{""}->{defaultPreset};
  my $defaultBPreset=$p_conf->{$defaultPreset}->{battlePreset}->[0];
  if(! exists $p_bConf->{$defaultBPreset}) {
    $sLog->log("Invalid battle settings configuration: default battle preset \"$defaultBPreset\" does not exist",1);
    return 0;
  }
  my @missingParams;
  foreach my $requiredParam (keys %battleParameters) {
    if(! exists $p_bConf->{$defaultBPreset}->{$requiredParam}) {
      push(@missingParams,$requiredParam);
    }
  }
  if(@missingParams) {
    my $mParams=join(",",@missingParams);
    $sLog->log("Incomplete battle settings configuration (missing parameter(s) in default preset: $mParams)",1);
    return 0;
  }

  return 1;
}

sub checkConfigLists {
  my ($sLog,$p_conf,$p_banLists,$p_mapLists)=@_;

  my $defaultPreset=$p_conf->{""}->{defaultPreset};
  my $banList=$p_conf->{$defaultPreset}->{banList}->[0];
  my $mapList=$p_conf->{$defaultPreset}->{mapList}->[0];

  if(! exists $p_banLists->{$banList}) {
    $sLog->log("Invalid banList configuration: default banList \"$banList\" does not exist",1);
    return 0;
  }

  if(! exists $p_mapLists->{$mapList}) {
    $sLog->log("Invalid mapList configuration: default mapList \"$mapList\" does not exist",1);
    return 0;
  }

  return 1;
}

sub pruneExpiredBans {
  my $self=shift;
  my $nbPrunedBans=0;
  my $p_banLists=$self->{banLists};
  foreach my $section (keys %{$p_banLists}) {
    my @filters=@{$p_banLists->{$section}};
    my @newFilters=();
    for my $i (0..$#filters) {
      if(exists $filters[$i]->[1]->{endDate} && defined $filters[$i]->[1]->{endDate} && $filters[$i]->[1]->{endDate} ne "" && $filters[$i]->[1]->{endDate} < time) {
        $nbPrunedBans++;
      }else{
        push(@newFilters,$filters[$i]);
      }
    }
    $p_banLists->{$section}=\@newFilters;
  }
  return $nbPrunedBans;
}

# Internal functions - Dynamic data ###########################################

sub dumpFastTable {
  my ($self,$p_data,$file,$p_fields)=@_;

  if(! open(TABLEFILE,">$file")) {
    $self->{log}->log("Unable to write to file \"$file\"",1);
    return 0;
  }

  print TABLEFILE <<EOH;
# Warning, this file is updated automatically by SPADS.
# Any modifications performed on this file while SPADS is running will be automatically erased.
  
EOH

  my $templateLine=join(":",@{$p_fields->[0]})."|".join(":",@{$p_fields->[1]});
  print TABLEFILE "#?$templateLine\n";

  my $p_rows=$self->printFastTable($p_data,$p_fields,1);
  foreach my $line (@{$p_rows}) {
    print TABLEFILE "$line\n";
  }
  close TABLEFILE;

  $self->{log}->log("File \"$file\" dumped",4);

  return 1;
}

sub printFastTable {
  my ($self,$p_data,$p_fields,$isFirst)=@_;
  $isFirst=0 unless(defined $isFirst);
  my @indexFields=@{$p_fields->[0]};
  my @dataFields=@{$p_fields->[1]};
  if(@indexFields) {
    my @result;
    shift @indexFields;
    foreach my $k (sort keys %{$p_data}) {
      my $p_subResults=$self->printFastTable($p_data->{$k},[\@indexFields,\@dataFields]);
      my $sep=":";
      $sep="" if($isFirst);
      if($k =~ /[\:\|]/) {
        $self->{log}->log("Invalid value found while dumping data \"$k\"",2);
        $k =~ s/[\:\|]/_/g;
      }
      my @keyResults=map {"$sep$k".$_} @{$p_subResults};
      push(@result,@keyResults);
    }
    return \@result;
  }else{
    my @dataFieldsValues=map {$p_data->{$_}} @dataFields;
    for my $i (0..$#dataFieldsValues) {
      $dataFieldsValues[$i]='' unless(defined $dataFieldsValues[$i]);
    }
    my $result=join(":",@dataFieldsValues);
    return ["|$result"];
  }
}

# Internal functions - Dynamic data - Preferences #############################

sub preparePreferences {
  my ($sLog,$p_prefs)=@_;
  my %newPrefs;
  foreach my $key (keys %{$p_prefs}) {
    if($key =~ /^(.+)\((.+)\)$/) {
      my ($accountId,$name)=($1,$2);
      my $newKey=$key;
      $newKey=$accountId if($accountId =~ /^\d+$/ && $accountId != 0);
      $newPrefs{$newKey}=$p_prefs->{$key};
      $newPrefs{$newKey}->{name}=$name;
    }else{
      $sLog->log("Ignoring invalid preference key \"$key\"",2);
    }
  }
  return \%newPrefs;
}

sub getPrunedRawPreferences {
  my $self=shift;
  my %newPrefs;
  foreach my $key (keys %{$self->{preferences}}) {
    my $keepPrefs=0;
    foreach my $p (keys %{$self->{preferences}->{$key}}) {
      next if($p eq 'name' || ($self->{conf}->{autoSetVoteMode} && $p eq 'voteMode') || $self->{preferences}->{$key}->{$p} eq "");
      $keepPrefs=1;
      last;
    }
    next unless($keepPrefs);
    my $newKey=$key;
    $newKey.="($self->{preferences}->{$key}->{name})" if($key !~ /\)$/);
    $newPrefs{$newKey}={};
    foreach my $p (keys %{$self->{preferences}->{$key}}) {
      next if($p eq 'name');
      $newPrefs{$newKey}->{$p}=$self->{preferences}->{$key}->{$p};
    }
  }
  return \%newPrefs;
}

# Internal functions - Dynamic data - User data ###############################

sub buildUserDataCaches {
  my $p_userData=shift;
  my (%accountData,%countryCpuIds,%ipIds,%nameIds);
  foreach my $id (keys %{$p_userData}) {
    $accountData{$id}={};
    my $idCountry=$p_userData->{$id}->{country};
    my $idCpu=$p_userData->{$id}->{cpu};
    my $idTs=$p_userData->{$id}->{timestamp};
    $countryCpuIds{$idCountry}={} unless(exists $countryCpuIds{$idCountry});
    $countryCpuIds{$idCountry}->{$idCpu}={} unless(exists $countryCpuIds{$idCountry}->{$idCpu});
    $countryCpuIds{$idCountry}->{$idCpu}->{$id}=$idTs;
    $accountData{$id}->{country}=$idCountry;
    $accountData{$id}->{cpu}=$idCpu;
    $accountData{$id}->{timestamp}=$idTs;
    $accountData{$id}->{rank}=$p_userData->{$id}->{rank};
    $accountData{$id}->{ips}={};
    my @idIps=split(' ',$p_userData->{$id}->{ips});
    if(@idIps) {
      foreach my $idIp (@idIps) {
        if($idIp =~ /^(\d+(?:\.\d+){3});(\d+)$/) {
          my ($ip,$ts)=($1,$2);
          $accountData{$id}->{ips}->{$ip}=$ts;
          $ipIds{$ip}={} unless(exists $ipIds{$ip});
          $ipIds{$ip}->{$id}=$ts;
        }
      }
    }
    $accountData{$id}->{names}={};
    my @idNames=split(' ',$p_userData->{$id}->{names});
    if(@idNames) {
      foreach my $idName (@idNames) {
        if($idName =~ /^([\w\[\]]+);(\d+)$/) {
          my ($name,$ts)=($1,$2);
          $accountData{$id}->{names}->{$name}=$ts;
          $nameIds{$name}={} unless(exists $nameIds{$name});
          $nameIds{$name}->{$id}=$ts;
        }
      }
    }
  }
  return (\%accountData,\%countryCpuIds,\%ipIds,\%nameIds);
}

sub flushUserDataCache {
  my $self=shift;
  my %userData;
  my $p_accountData=$self->{accountData};
  $self->{countryCpuIds}={};
  $self->{ipIds}={};
  $self->{nameIds}={};
  my ($userDataRetentionPeriod,$userIpRetention,$userNameRetention)=(-1,-1,-1);
  $userDataRetentionPeriod=$1 if($self->{conf}->{userDataRetention} =~ /^(\d+);/);
  $userIpRetention=$1 if($self->{conf}->{userDataRetention} =~ /;(\d+);/);
  $userNameRetention=$1 if($self->{conf}->{userDataRetention} =~ /;(\d+)$/);
  foreach my $id (keys %{$p_accountData}) {
    my $ts=$p_accountData->{$id}->{timestamp};
    if($userDataRetentionPeriod != -1 && time-$ts > $userDataRetentionPeriod * 86400) {
      delete $p_accountData->{$id};
      next;
    }
    my $country=$p_accountData->{$id}->{country};
    my $cpu=$p_accountData->{$id}->{cpu};
    $self->{countryCpuIds}->{$country}={} unless(exists $self->{countryCpuIds}->{$country});
    $self->{countryCpuIds}->{$country}->{$cpu}={} unless(exists $self->{countryCpuIds}->{$country}->{$cpu});
    $self->{countryCpuIds}->{$country}->{$cpu}->{$id}=$ts;
    $userData{$id}->{country}=$country;
    $userData{$id}->{cpu}=$cpu;
    $userData{$id}->{timestamp}=$ts;
    $userData{$id}->{rank}=$p_accountData->{$id}->{rank};
    my @ipData;
    my @sortedUserIps=sort {$p_accountData->{$id}->{ips}->{$b} <=> $p_accountData->{$id}->{ips}->{$a}} (keys %{$p_accountData->{$id}->{ips}});
    foreach my $ip (@sortedUserIps) {
      my $ipTs=$p_accountData->{$id}->{ips}->{$ip};
      if(($userIpRetention != -1 && $#ipData + 1 >= $userIpRetention) || ($userDataRetentionPeriod != -1 && time-$ipTs > $userDataRetentionPeriod * 86400)) {
        delete $p_accountData->{$id}->{ips}->{$ip};
      }else{
        push(@ipData,"$ip;$ipTs");
        $self->{ipIds}->{$ip}={} unless(exists $self->{ipIds}->{$ip});
        $self->{ipIds}->{$ip}->{$id}=$ipTs;
      }
    }
    if(@ipData) {
      $userData{$id}->{ips}=join(" ",@ipData);
    }else{
      $userData{$id}->{ips}="";
    }
    my @nameData;
    my @sortedUserNames=sort {$p_accountData->{$id}->{names}->{$b} <=> $p_accountData->{$id}->{names}->{$a}} (keys %{$p_accountData->{$id}->{names}});
    foreach my $name (@sortedUserNames) {
      my $nameTs=$p_accountData->{$id}->{names}->{$name};
      if(($userNameRetention != -1 && $#nameData + 1 > $userNameRetention) || ($userDataRetentionPeriod != -1 && time-$nameTs > $userDataRetentionPeriod * 86400)) {
        delete $p_accountData->{$id}->{names}->{$name};
      }else{
        push(@nameData,"$name;$nameTs");
        $self->{nameIds}->{$name}={} unless(exists $self->{nameIds}->{$name});
        $self->{nameIds}->{$name}->{$id}=$nameTs;
      }
    }
    if(@nameData) {
      $userData{$id}->{names}=join(" ",@nameData);
    }else{
      $userData{$id}->{names}="";
    }
  }
  return \%userData;
}

# Internal functions - Dynamic data - Bans ####################################

sub removeMatchingData {
  my ($p_data,$p_filters)=@_;
  my %data=%{$p_data};
  my @filters=@{$p_filters};
  my @newFilters;
  for my $i (0..$#filters) {
    my @filterData=@{$filters[$i]};
    my %filter=%{$filterData[0]};
    my $matched=1;
    foreach my $field (keys %data) {
      next if($data{$field} eq "");
      if(! (exists $filter{$field} && defined $filter{$field} && $filter{$field} ne "")) {
        $matched=0;
        last;
      }
      my @filterFieldValues=split(",",$filter{$field});
      my $matchedField=0;
      my $fieldData=$data{$field};
      $fieldData=$1 if($field eq "accountId" && $fieldData =~ /^([^\(]+)\(/);
      foreach my $filterFieldValue (@filterFieldValues) {
        if($field eq "accountId" && $filterFieldValue =~ /^([^\(]+)(\(.*)$/) {
          my ($filterAccountId,$filterUserName)=($1,$2);
          if($fieldData =~ /^\(/) {
            $filterFieldValue=$filterUserName;
          }else{
            $filterFieldValue=$filterAccountId;
          }
        }
        if($fieldData eq $filterFieldValue) {
          $matchedField=1;
          last;
        }
      }
      $matched=$matchedField;
      last unless($matched);
    }
    push(@newFilters,$filters[$i]) unless($matched);
  }
  return \@newFilters;
}

sub removeExpiredBans {
  my $self=shift;
  my $nbRemovedBans=0;
  my @bans=@{$self->{bans}};
  my @newBans=();
  for my $i (0..$#bans) {
    if(exists $bans[$i]->[1]->{endDate} && defined $bans[$i]->[1]->{endDate} && $bans[$i]->[1]->{endDate} ne "" && $bans[$i]->[1]->{endDate} < time) {
      $nbRemovedBans++;
    }else{
      push(@newBans,$bans[$i]);
    }
  }
  if($nbRemovedBans) {
    $self->{bans}=\@newBans;
    $self->{log}->log("$nbRemovedBans expired ban(s) removed from file \"bans.dat\"",3);
    $self->dumpTable($self->{bans},$self->{conf}->{varDir}."/bans.dat",\@banListsFields);
  }
}

sub dumpTable {
  my ($self,$p_data,$file,$p_fields)=@_;

  if(! open(TABLEFILE,">$file")) {
    $self->{log}->log("Unable to write to file \"$file\"",1);
    return 0;
  }

  print TABLEFILE <<EOH;
# Warning, this file is updated automatically by SPADS.
# Any modifications performed on this file while SPADS is running will be automatically erased.
  
EOH

  my $templateLine=join(":",@{$p_fields->[0]})."|".join(":",@{$p_fields->[1]});
  print TABLEFILE "#?$templateLine\n";

  for my $row (0..$#{$p_data}) {
    my $p_rowData=$p_data->[$row];
    my $invalidData="";
    foreach my $p_rowEntry (@{$p_rowData}) {
      foreach my $field (keys %{$p_rowEntry}) {
        if($p_rowEntry->{$field} =~ /[\:\|]/) {
          $invalidData="invalid value \"$p_rowEntry->{$field}\" for field \"$field\"";
          last;
        }
      }
      last if($invalidData);
    }
    if($invalidData) {
      $self->{log}->log("Skipping entry during dump table ($invalidData)",2);
      next;
    }
    my $line="";
    foreach my $fieldNb (0..$#{$p_fields->[0]}) {
      my $field=$p_fields->[0]->[$fieldNb];
      $line.=":" if($fieldNb);
      $line.=$p_rowData->[0]->{$field} if(exists $p_rowData->[0]->{$field} && defined $p_rowData->[0]->{$field});
    }
    $line.="|";
    foreach my $fieldNb (0..$#{$p_fields->[1]}) {
      my $field=$p_fields->[1]->[$fieldNb];
      $line.=":" if($fieldNb);
      $line.=$p_rowData->[1]->{$field} if(exists $p_rowData->[1]->{$field} && defined $p_rowData->[1]->{$field});
    }
    print TABLEFILE "$line\n";
  }
    
  close(TABLEFILE);

  $self->{log}->log("File \"$file\" dumped",4);

  return 1;
}

# Internal functions - Dynamic data - Map hashes ##############################

sub getMapHashes {
  my ($self,$springMajorVersion)=@_;
  return $self->{mapHashes}->{$springMajorVersion} if(exists $self->{mapHashes}->{$springMajorVersion});
  return {};
}

# Business functions ##########################################################

# Business functions - Configuration ##########################################

sub applyPreset {
  my ($self,$preset,$commandsAlreadyLoaded)=@_;
  $commandsAlreadyLoaded=0 unless(defined $commandsAlreadyLoaded);
  my %settings=%{$self->{presets}->{$preset}};
  foreach my $param (keys %settings) {
    $self->{conf}->{$param}=$settings{$param}->[0];
    $self->{values}->{$param}=$settings{$param};
  }
  $self->{conf}->{preset}=$preset;
  if(! $commandsAlreadyLoaded) {
    my $p_commands=loadTableFile($self->{log},$self->{conf}->{etcDir}."/".$self->{conf}->{commandsFile},\@commandsFields,$self->{macros},1);
    if(%{$p_commands}) {
      $self->{commands}=$p_commands;
    }else{
      $self->{log}->log("Unable to load commands file \"".$self->{conf}->{commandsFile}."\"",1);
    }
  }
  $self->applyHPreset($self->{conf}->{hostingPreset});
  $self->applyBPreset($self->{conf}->{battlePreset});
  foreach my $pluginName (keys %{$self->{pluginsConf}}) {
    $self->applyPluginPreset($pluginName,$preset);
  }
}

sub applyPluginPreset {
  my ($self,$pluginName,$preset)=@_;
  return unless(exists $self->{pluginsConf}->{$pluginName} && exists $self->{pluginsConf}->{$pluginName}->{presets}->{$preset});
  my %settings=%{$self->{pluginsConf}->{$pluginName}->{presets}->{$preset}};
  foreach my $param (keys %settings) {
    $self->{pluginsConf}->{$pluginName}->{conf}->{$param}=$settings{$param}->[0];
    $self->{pluginsConf}->{$pluginName}->{values}->{$param}=$settings{$param};
  }
}

sub applyHPreset {
  my ($self,$preset)=@_;
  my %settings=%{$self->{hPresets}->{$preset}};
  foreach my $param (keys %settings) {
    $self->{hSettings}->{$param}=$settings{$param}->[0];
    $self->{hValues}->{$param}=$settings{$param};
  }
  $self->{conf}->{hostingPreset}=$preset;
}

sub applyBPreset {
  my ($self,$preset)=@_;
  my %settings=%{$self->{bPresets}->{$preset}};
  if(exists $settings{resetoptions} && $settings{resetoptions}->[0]) {
    foreach my $bSetKey (keys %{$self->{bSettings}}) {
      delete $self->{bSettings}->{$bSetKey} unless(exists $battleParameters{$bSetKey});
    }
    foreach my $bValKey (keys %{$self->{bValues}}) {
      delete $self->{bValues}->{$bValKey} unless(exists $battleParameters{$bValKey});
    }
  }
  foreach my $param (keys %settings) {
    if($param eq "disabledunits") {
      my @currentDisUnits=();
      if(exists $self->{bSettings}->{disabledunits} && $self->{bSettings}->{disabledunits}) {
        @currentDisUnits=split(/;/,$self->{bSettings}->{disabledunits});
      }
      my @newDisUnits=split(/;/,$settings{disabledunits}->[0]);
      foreach my $newDisUnit (@newDisUnits) {
        if($newDisUnit eq "-*") {
          @currentDisUnits=();
        }elsif($newDisUnit =~ /^\-(.*)$/) {
          my $removedUnitIndex=aindex(@currentDisUnits,$1);
          splice(@currentDisUnits,$removedUnitIndex,1) if($removedUnitIndex != -1);
        }else{
          push(@currentDisUnits,$newDisUnit) unless(aindex(@currentDisUnits,$newDisUnit) != -1);
        }
      }
      $self->{bSettings}->{disabledunits}=join(";",@currentDisUnits);
    }else{
      $self->{bSettings}->{$param}=$settings{$param}->[0];
      $self->{bValues}->{$param}=$settings{$param};
    }
  }
  $self->{conf}->{battlePreset}=$preset;
}

sub applyMapList {
  my ($self,$p_availableMaps,$springMajorVersion)=@_;
  my $p_mapFilters=$self->{mapLists}->{$self->{conf}->{mapList}};
  $self->{maps}={};
  $self->{orderedMaps}=[];
  $self->{ghostMaps}={};
  $self->{orderedGhostMaps}=[];
  my %alreadyTestedMaps;
  for my $i (0..$#{$p_availableMaps}) {
    $alreadyTestedMaps{$p_availableMaps->[$i]->{name}}=1;
    for my $j (0..$#{$p_mapFilters}) {
      my $mapFilter=$p_mapFilters->[$j];
      if($mapFilter =~ /^!(.*)$/) {
        my $realMapFilter=$1;
        last if($p_availableMaps->[$i]->{name} =~ /^$realMapFilter$/);
      }elsif($p_availableMaps->[$i]->{name} =~ /^$mapFilter$/) {
        $self->{maps}->{$i}=$p_availableMaps->[$i]->{name};
        $self->{orderedMaps}->[$j]=[] unless(defined $self->{orderedMaps}->[$j]);
        push(@{$self->{orderedMaps}->[$j]},$p_availableMaps->[$i]->{name});
        last;
      }
    }
  }
  my $p_availableGhostMaps=$self->getMapHashes($springMajorVersion);
  foreach my $ghostMapName (keys %{$p_availableGhostMaps}) {
    next if(exists $alreadyTestedMaps{$ghostMapName});
    for my $j (0..$#{$p_mapFilters}) {
      my $mapFilter=$p_mapFilters->[$j];
      if($mapFilter =~ /^!(.*)$/) {
        my $realMapFilter=$1;
        last if($realMapFilter eq "_GHOSTMAPS_" || $ghostMapName =~ /^$realMapFilter$/);
      }elsif($mapFilter eq "_GHOSTMAPS_" || $ghostMapName =~ /^$mapFilter$/) {
        $self->{ghostMaps}->{$ghostMapName}=$p_availableGhostMaps->{$ghostMapName};
        $self->{orderedGhostMaps}->[$j]=[] unless(defined $self->{orderedGhostMaps}->[$j]);
        push(@{$self->{orderedGhostMaps}->[$j]},$ghostMapName);
        last;
      }
    }
  }
}

sub applySubMapList {
  my ($self,$mapList)=@_;
  $mapList="" unless(defined $mapList);

  my $p_orderedMaps;
  if($self->{conf}->{allowGhostMaps}) {
    $p_orderedMaps=mergeMapArrays($self->{orderedMaps},$self->{orderedGhostMaps});
  }else{
    $p_orderedMaps=mergeMapArrays($self->{orderedMaps});
  }
  return $p_orderedMaps unless($mapList && exists $self->{mapLists}->{$mapList});

  my @filteredMaps;
  my $p_mapFilters=$self->{mapLists}->{$mapList};
  foreach my $mapName (@{$p_orderedMaps}) {
    for my $i (0..$#{$p_mapFilters}) {
      my $mapFilter=$p_mapFilters->[$i];
      if($mapFilter =~ /^!(.*)$/) {
        my $realMapFilter=$1;
        last if($mapName =~ /^$realMapFilter$/);
      }elsif($mapName =~ /^$mapFilter$/) {
        $filteredMaps[$i]=[] unless(defined $filteredMaps[$i]);
        push(@{$filteredMaps[$i]},$mapName);
        last;
      }
    }
  }

  $p_orderedMaps=mergeMapArrays(\@filteredMaps);
  return $p_orderedMaps;
}

sub getFullCommandsHelp {
  my $self=shift;
  my $p_fullHelp=loadSimpleTableFile($self->{log},$self->{conf}->{binDir}."/help.dat",$self->{macros});
  return $p_fullHelp;
}

sub getUserAccessLevel {
  my ($self,$name,$p_user,$authenticated)=@_;
  my $p_userData={name => $name,
                  accountId => $p_user->{accountId},
                  country => $p_user->{country},
                  cpu => $p_user->{cpu},
                  rank => $p_user->{status}->{rank},
                  access => $p_user->{status}->{access},
                  bot => $p_user->{status}->{bot},
                  auth => $authenticated};
  my $p_levels=findMatchingData($p_userData,$self->{users});
  if(@{$p_levels}) {
    return $p_levels->[0]->{level};
  }else{
    return 0;
  }
}

sub getLevelDescription {
  my ($self,$level)=@_;
  my $p_descriptions=findMatchingData({level => $level},$self->{levels}->{""});
  if(@{$p_descriptions}) {
    return $p_descriptions->[0]->{description};
  }else{
    return "Unknown level";
  }
}

sub getCommandLevels {
  my ($self,$command,$source,$status,$gameState)=@_;
  if(exists $self->{commands}->{$command}) {
    my $p_rights=findMatchingData({source => $source, status => $status, gameState => $gameState},$self->{commands}->{$command});
    return dclone($p_rights->[0]) if(@{$p_rights});
  }else{
    foreach my $pluginName (keys %{$self->{pluginsConf}}) {
      if(exists $self->{pluginsConf}->{$pluginName}->{commands}->{$command}) {
        my $p_rights=findMatchingData({source => $source, status => $status, gameState => $gameState},$self->{pluginsConf}->{$pluginName}->{commands}->{$command});
        return dclone($p_rights->[0]) if(@{$p_rights});
      }
    }
  }
  return {};
}

sub getHelpForLevel {
  my ($self,$level)=@_;
  my @direct=();
  my @vote=();
  foreach my $command (sort keys %{$self->{commands}}) {
    if(! exists $self->{help}->{$command}) {
      $self->{log}->log("Missing help for command \"$command\"",2) unless($command =~ /^#/);
      next;
    }
    my $p_filters=$self->{commands}->{$command};
    my $foundDirect=0;
    my $foundVote=0;
    foreach my $p_filter (@{$p_filters}) {
      if(exists $p_filter->[1]->{directLevel}
         && defined $p_filter->[1]->{directLevel}
         && $p_filter->[1]->{directLevel} ne ""
         && $level >= $p_filter->[1]->{directLevel}) {
        $foundDirect=1;
      }
      if(exists $p_filter->[1]->{voteLevel}
         && defined $p_filter->[1]->{voteLevel}
         && $p_filter->[1]->{voteLevel} ne ""
         && $level >= $p_filter->[1]->{voteLevel}) {
        $foundVote=1;
      }
      last if($foundDirect);
    }
    if($foundDirect) {
      push(@direct,$self->{help}->{$command}->[0]);
    }elsif($foundVote) {
      push(@vote,$self->{help}->{$command}->[0]);
    }
  }
  foreach my $pluginName (keys %{$self->{pluginsConf}}) {
    my $p_pluginCommands=$self->{pluginsConf}->{$pluginName}->{commands};
    foreach my $command (sort keys %{$p_pluginCommands}) {
      if(! exists $self->{pluginsConf}->{$pluginName}->{help}->{$command}) {
        $self->{log}->log("Missing help for command \"$command\" of plugin $pluginName ",2);
        next;
      }
      my $p_filters=$p_pluginCommands->{$command};
      my $foundDirect=0;
      my $foundVote=0;
      foreach my $p_filter (@{$p_filters}) {
        if(exists $p_filter->[1]->{directLevel}
           && defined $p_filter->[1]->{directLevel}
           && $p_filter->[1]->{directLevel} ne ""
           && $level >= $p_filter->[1]->{directLevel}) {
          $foundDirect=1;
        }
        if(exists $p_filter->[1]->{voteLevel}
           && defined $p_filter->[1]->{voteLevel}
           && $p_filter->[1]->{voteLevel} ne ""
           && $level >= $p_filter->[1]->{voteLevel}) {
          $foundVote=1;
        }
        last if($foundDirect);
      }
      if($foundDirect) {
        push(@direct,$self->{pluginsConf}->{$pluginName}->{help}->{$command}->[0]);
      }elsif($foundVote) {
        push(@vote,$self->{pluginsConf}->{$pluginName}->{help}->{$command}->[0]);
      }
    }
  }
  return {direct => \@direct, vote => \@vote};
}

# Business functions - Dynamic data ###########################################

sub dumpDynamicData {
  my $self=shift;
  my $startDumpTs=time;
  my $p_prunedPrefs=$self->getPrunedRawPreferences();
  $self->dumpFastTable($p_prunedPrefs,$self->{conf}->{varDir}."/preferences.dat",\@preferencesListsFields);
  $self->dumpFastTable($self->{mapHashes},$self->{conf}->{varDir}."/mapHashes.dat",\@mapHashesFields);
  my $p_userData=flushUserDataCache($self);
  $self->dumpFastTable($p_userData,$self->{conf}->{varDir}."/userData.dat",\@userDataFields);
  my $dumpDuration=time-$startDumpTs;
  $self->{log}->log("Dynamic data dump process took $dumpDuration seconds",2) if($dumpDuration > 15);
}

# Business functions - Dynamic data - Map info cache ##########################

sub getUncachedMaps {
  my ($self,$p_maps)=@_;
  my $p_uncachedMaps=[];
  foreach my $map (@{$p_maps}) {
    push(@{$p_uncachedMaps},$map) unless(exists $self->{mapInfo}->{$map});
  }
  return $p_uncachedMaps;
}

sub isCachedMapInfo {
  my ($self,$map)=@_;
  return exists $self->{mapInfo}->{$map};
}

sub getCachedMapInfo {
  my ($self,$map)=@_;
  return $self->{mapInfo}->{$map} if(exists $self->{mapInfo}->{$map});
  return undef;
}

sub cacheMapsInfo {
  my ($self,$p_mapsInfo)=@_;
  foreach my $map (keys %{$p_mapsInfo}) {
    $self->{mapInfo}->{$map}=$p_mapsInfo->{$map};
  }
  $self->{log}->log("Unable to store map info cache",1) unless(nstore($self->{mapInfo},$self->{conf}->{varDir}.'/mapInfoCache.dat'));
}

# Business functions - Dynamic data - Map boxes ###############################

sub existSavedMapBoxes {
  my ($self,$map,$nbTeams)=@_;
  return (exists $self->{savedBoxes}->{$map} && exists $self->{savedBoxes}->{$map}->{$nbTeams});
}

sub getSavedBoxesMaps {
  my $self=shift;
  my @savedBoxesMaps=keys %{$self->{savedBoxes}};
  return \@savedBoxesMaps;
}

sub getMapBoxes {
  my ($self,$map,$nbTeams,$extraBox)=@_;
  my $p_boxes;
  if($extraBox) {
    my $tmpNbTeams=($nbTeams+$extraBox)."(-$extraBox)";
    if(exists $self->{mapBoxes}->{$map} && exists $self->{mapBoxes}->{$map}->{$tmpNbTeams}) {
      $p_boxes=$self->{mapBoxes}->{$map}->{$tmpNbTeams}->{boxes};
    }elsif(exists $self->{savedBoxes}->{$map} && exists $self->{savedBoxes}->{$map}->{$tmpNbTeams}) {
      $p_boxes=$self->{savedBoxes}->{$map}->{$tmpNbTeams}->{boxes};
    }
  }
  if(! defined $p_boxes) {
    if(exists $self->{mapBoxes}->{$map} && exists $self->{mapBoxes}->{$map}->{$nbTeams}) {
      $p_boxes=$self->{mapBoxes}->{$map}->{$nbTeams}->{boxes};
    }elsif(exists $self->{savedBoxes}->{$map} && exists $self->{savedBoxes}->{$map}->{$nbTeams}) {
      $p_boxes=$self->{savedBoxes}->{$map}->{$nbTeams}->{boxes};
    }
  }
  if(defined $p_boxes) {
    my @boxes=split(";",$p_boxes);
    return \@boxes;
  }
  return [];
}

sub saveMapBoxes {
  my ($self,$map,$p_startRects,$extraBox)=@_;
  return -1 unless(%{$p_startRects});
  my @ids=sort (keys %{$p_startRects});
  my $nbTeams=$#ids+1;
  $nbTeams.="(-$extraBox)" if($extraBox);
  $self->{savedBoxes}->{$map}={} unless(exists $self->{savedBoxes}->{$map});
  $self->{savedBoxes}->{$map}->{$nbTeams}={} unless(exists $self->{savedBoxes}->{$map}->{$nbTeams});
  my $boxId=$ids[0];
  my $boxesString="$p_startRects->{$boxId}->{left} $p_startRects->{$boxId}->{top} $p_startRects->{$boxId}->{right} $p_startRects->{$boxId}->{bottom}";
  for my $boxIndex (1..$#ids) {
    $boxId=$ids[$boxIndex];
    $boxesString.=";$p_startRects->{$boxId}->{left} $p_startRects->{$boxId}->{top} $p_startRects->{$boxId}->{right} $p_startRects->{$boxId}->{bottom}";
  }
  return if(exists $self->{savedBoxes}->{$map}->{$nbTeams}->{boxes} && $self->{savedBoxes}->{$map}->{$nbTeams}->{boxes} eq $boxesString);
  $self->{savedBoxes}->{$map}->{$nbTeams}->{boxes}=$boxesString;
  $self->dumpFastTable($self->{savedBoxes},$self->{conf}->{varDir}."/savedBoxes.dat",\@mapBoxesFields);
  $self->{log}->log("File \"savedBoxes.dat\" updated for \"$map\" (nbTeams=$nbTeams)",3);
  return 1;
}

# Business functions - Dynamic data - Map hashes ##############################

sub getMapHash {
  my ($self,$map,$springMajorVersion)=@_;
  if(exists $self->{mapHashes}->{$springMajorVersion} && exists $self->{mapHashes}->{$springMajorVersion}->{$map}) {
    return $self->{mapHashes}->{$springMajorVersion}->{$map}->{mapHash};
  }
  return 0;
}

sub saveMapHash {
  my ($self,$map,$springMajorVersion,$hash)=@_;
  $self->{mapHashes}->{$springMajorVersion}={} unless(exists $self->{mapHashes}->{$springMajorVersion});
  $self->{mapHashes}->{$springMajorVersion}->{$map}={} unless(exists $self->{mapHashes}->{$springMajorVersion}->{$map});
  $self->{mapHashes}->{$springMajorVersion}->{$map}->{mapHash}=$hash;
  $self->{log}->log("Hash saved for map \"$map\" (springMajorVersion=$springMajorVersion)",5);
  return 1;
}

# Business functions - Dynamic data - User data ###############################

sub getNbAccounts {
  my $self=shift;
  my $nbAccounts=keys %{$self->{accountData}};
  return $nbAccounts;
}

sub getNbNames {
  my $self=shift;
  my $nbNames=keys %{$self->{nameIds}};
  return $nbNames;
}

sub getNbIps {
  my $self=shift;
  my $nbIps=keys %{$self->{ipIds}};
  return $nbIps;
}

sub isStoredAccount {
  my ($self,$aId)=@_;
  return (exists $self->{accountData}->{$aId});
}

sub isStoredUser {
  my ($self,$name)=@_;
  return (exists $self->{nameIds}->{$name});
}

sub isStoredIp {
  my ($self,$ip)=@_;
  return (exists $self->{ipIds}->{$ip});
}

sub getAccountNamesTs {
  my ($self,$id)=@_;
  return $self->{accountData}->{$id}->{names};
}

sub getAccountIpsTs {
  my ($self,$id)=@_;
  return $self->{accountData}->{$id}->{ips};
}

sub getAccountMainData {
  my ($self,$id)=@_;
  return $self->{accountData}->{$id};
}

sub getUserIds {
  my ($self,$user)=@_;
  my @ids=keys %{$self->{nameIds}->{$user}};
  return \@ids;
}

sub getIpIdsTs {
  my ($self,$ip)=@_;
  return $self->{ipIds}->{$ip};
}

sub getSimilarAccounts {
  my ($self,$country,$cpu)=@_;
  return $self->{countryCpuIds}->{$country}->{$cpu};
}

sub getAccountIps {
  my ($self,$id,$p_ignoredIps)=@_;
  $p_ignoredIps={} unless(defined $p_ignoredIps);
  my @ips;
  if(exists $self->{accountData}->{$id}) {
    my %ipHash=%{$self->{accountData}->{$id}->{ips}};
    @ips=sort {$ipHash{$b} <=> $ipHash{$a}} (keys %ipHash);
  }
  my @filteredIps;
  foreach my $ip (@ips) {
    push(@filteredIps,$ip) unless(exists $p_ignoredIps->{$ip});
  }
  return \@filteredIps;
}

sub getLatestAccountIp {
  my ($self,$id)=@_;
  my $latestIdIp='';
  if(exists $self->{accountData}->{$id}) {
    my $latestTimestamp=0;
    foreach my $ip (keys %{$self->{accountData}->{$id}->{ips}}) {
      if($self->{accountData}->{$id}->{ips}->{$ip} > $latestTimestamp) {
        $latestIdIp=$ip;
        $latestTimestamp=$self->{accountData}->{$id}->{ips}->{$ip};
      }
    }
  }
  return $latestIdIp;
}

sub getLatestUserAccountId {
  my ($self,$name)=@_;
  my $latestUserAccountId='';
  if(exists $self->{nameIds}->{$name}) {
    my $latestTimestamp=0;
    foreach my $id (keys %{$self->{nameIds}->{$name}}) {
      if($self->{nameIds}->{$name}->{$id} > $latestTimestamp) {
        $latestUserAccountId=$id;
        $latestTimestamp=$self->{nameIds}->{$name}->{$id};
      }
    }
  }
  return $latestUserAccountId;
}

sub getLatestIpAccountId {
  my ($self,$ip)=@_;
  my $latestIpAccountId='';
  if(exists $self->{ipIds}->{$ip}) {
    my $latestTimestamp=0;
    foreach my $id (keys %{$self->{ipIds}->{$ip}}) {
      if($self->{ipIds}->{$ip}->{$id} > $latestTimestamp) {
        $latestIpAccountId=$id;
        $latestTimestamp=$self->{ipIds}->{$ip}->{$id};
      }
    }
  }
  return $latestIpAccountId;
}

sub getIpAccounts {
  my ($self,$ip)=@_;
  my %accounts;
  if(exists $self->{ipIds}->{$ip}) {
    foreach my $i (keys %{$self->{ipIds}->{$ip}}) {
      $accounts{$i}=$self->{accountData}->{$i}->{rank};
    }
  }
  return \%accounts;
}

sub searchUserIds {
  my ($self,$search)=@_;
  my $filter=quotemeta($search);
  my $nbMatchingId=0;
  my %matchingIds;
  foreach my $name (sort keys %{$self->{nameIds}}) {
    if($name =~ /$filter/i) {
      my %nameIds=%{$self->{nameIds}->{$name}};
      foreach my $id (keys %nameIds) {
        if(exists $matchingIds{$id}) {
          $matchingIds{$id}->{timestamp}=$nameIds{$id} unless($matchingIds{$id}->{timestamp} > $nameIds{$id});
          $matchingIds{$id}->{names}->{$name}=$nameIds{$id};
        }else{
          ++$nbMatchingId;
          $matchingIds{$id}={timestamp => $nameIds{$id},
                             names => {$name => $nameIds{$id}}};
        }
      }
    }
  }
  return (\%matchingIds,$nbMatchingId);
}

sub searchIpIds {
  my ($self,$search)=@_;
  my $filter=$search;
  $filter=~s/\./\\\./g;
  $filter=~s/\*/\.\*/g;
  my $nbMatchingId=0;
  my %matchingIds;
  foreach my $ip (sort keys %{$self->{ipIds}}) {
    if($ip =~ /^$filter$/) {
      my %ipIds=%{$self->{ipIds}->{$ip}};
      foreach my $id (keys %ipIds) {
        if(exists $matchingIds{$id}) {
          $matchingIds{$id}->{timestamp}=$ipIds{$id} unless($matchingIds{$id}->{timestamp} > $ipIds{$id});
          $matchingIds{$id}->{ips}->{$ip}=$ipIds{$id};
        }else{
          ++$nbMatchingId;
          $matchingIds{$id}={timestamp => $ipIds{$id},
                             ips => {$ip => $ipIds{$id}}};
        }
      }
    }
  }
  return (\%matchingIds,$nbMatchingId);
}

sub getSmurfs {
  my ($self,$id)=@_;
  my $latestAccountIp=$self->getLatestAccountIp($id);
  return [] unless($latestAccountIp);
  my $p_smurfs1=$self->getIpAccounts($latestAccountIp);
  my @smurfs1=sort {$p_smurfs1->{$b} <=> $p_smurfs1->{$a}} (keys %{$p_smurfs1});
  my @smurfs=(\@smurfs1);
  my @ips=([$latestAccountIp]);
  my ($p_processedAccounts,$p_processedIps,$p_newIps)=({$id => 1},{},$self->getAccountIps($id));
  while(@{$p_newIps}) {
    push(@ips,$p_newIps);
    my %newAccounts;
    foreach my $newIp (@{$p_newIps}) {
      next if(exists $p_processedIps->{$newIp});
      my $p_ipNewAccounts=$self->getIpAccounts($newIp);
      foreach my $newAccount (keys %{$p_ipNewAccounts}) {
        $newAccounts{$newAccount}=$p_ipNewAccounts->{$newAccount} unless(exists $p_processedAccounts->{$newAccount});
      }
      $p_processedIps->{$newIp}=1;
    }
    my @newSmurfs;
    $p_newIps=[];
    foreach my $newAccount (sort {$newAccounts{$b} <=> $newAccounts{$a}} (keys %newAccounts)) {
      push(@newSmurfs,$newAccount) unless(exists $p_smurfs1->{$newAccount});
      my $p_accountIps=$self->getAccountIps($newAccount,$p_processedIps);
      push(@{$p_newIps},@{$p_accountIps});
      $p_processedAccounts->{$newAccount}=1;
    }
    push(@smurfs,\@newSmurfs);
  }
  return (\@smurfs,\@ips);
}

sub learnUserData {
  my ($self,$user,$country,$cpu,$id)=@_;
  if(! exists $self->{accountData}->{$id}) {
    $self->{accountData}->{$id}={country => $country,
                                  cpu => $cpu,
                                  rank => 0,
                                  timestamp => time,
                                  ips => {},
                                  names => {$user => time}};
  }else{
    my $userNameRetention=-1;
    $userNameRetention=$1 if($self->{conf}->{userDataRetention} =~ /;(\d+)$/);
    $self->{accountData}->{$id}->{country}=$country;
    $self->{accountData}->{$id}->{cpu}=$cpu;
    $self->{accountData}->{$id}->{timestamp}=time;
    my $isNewName=0;
    $isNewName=1 unless(exists $self->{accountData}->{$id}->{names}->{$user});
    $self->{accountData}->{$id}->{names}->{$user}=time;
    if($isNewName && $userNameRetention > -1) {
      my $p_accountNames=$self->{accountData}->{$id}->{names};
      my @accountNames=sort {$p_accountNames->{$a} <=> $p_accountNames->{$b}} (keys %{$p_accountNames});
      delete $self->{accountData}->{$id}->{names}->{$accountNames[0]} if($#accountNames > $userNameRetention);
    }
  }
  $self->{countryCpuIds}->{$country}={} unless(exists $self->{countryCpuIds}->{$country});
  $self->{countryCpuIds}->{$country}->{$cpu}={} unless(exists $self->{countryCpuIds}->{$country}->{$cpu});
  $self->{countryCpuIds}->{$country}->{$cpu}->{$id}=time;
  $self->{nameIds}->{$user}={} unless($self->isStoredUser($user));
  $self->{nameIds}->{$user}->{$id}=time;
}

sub learnAccountIp {
  my ($self,$id,$ip,$userIpRetention)=@_;
  my $isNewIp=0;
  $isNewIp=1 unless(exists $self->{accountData}->{$id}->{ips}->{$ip});
  $self->{accountData}->{$id}->{ips}->{$ip}=time;
  $self->{ipIds}->{$ip}={} unless(exists $self->{ipIds}->{$ip});
  $self->{ipIds}->{$ip}->{$id}=time;
  if($isNewIp && $userIpRetention > 0) {
    my $p_accountIps=$self->{accountData}->{$id}->{ips};
    my @accountIps=sort {$p_accountIps->{$a} <=> $p_accountIps->{$b}} (keys %{$p_accountIps});
    delete $self->{accountData}->{$id}->{ips}->{$accountIps[0]} if($#accountIps + 1 > $userIpRetention);
  }
}

sub learnAccountRank {
  my ($self,$id,$rank,$bot)=@_;
  if($self->{accountData}->{$id}->{rank} eq '' || $rank > $self->{accountData}->{$id}->{rank}) {
    if($bot) {
      $self->{accountData}->{$id}->{rank}=-$rank;
    }else{
      $self->{accountData}->{$id}->{rank}=$rank;
    }
  }
}

# Business functions - Dynamic data - Bans ####################################

sub getDynamicBans {
  my $self=shift;
  return $self->{bans};
}

sub banExists {
  my ($self,$p_filters)=@_;

  my $nbPrunedBans = $self->pruneExpiredBans();
  $self->{log}->log("$nbPrunedBans bans have expired in file \"banLists.cfg\"",3) if($nbPrunedBans);

  $self->removeExpiredBans();

  my $p_bans=findMatchingData($p_filters,$self->{bans},0);
  if(@{$p_bans}) {
    return 1;
  }else{
    return 0;
  }
}

sub getUserBan {
  my ($self,$name,$p_user,$authenticated,$ip)=@_;
  if(! defined $ip) {
    my $id=$p_user->{accountId};
    $id.="($name)" unless($id);
    $ip=$self->getLatestAccountIp($id);
  }
  my $p_userData={name => $name,
                  accountId => $p_user->{accountId},
                  country => $p_user->{country},
                  cpu => $p_user->{cpu},
                  rank => $p_user->{status}->{rank},
                  access => $p_user->{status}->{access},
                  bot => $p_user->{status}->{bot},
                  level => $self->getUserAccessLevel($name,$p_user,$authenticated),
                  ip => $ip};
  $p_userData->{ip}="_UNKNOWN_" if($p_userData->{ip} eq "");
  my $nbPrunedBans = $self->pruneExpiredBans();
  $self->{log}->log("$nbPrunedBans bans have expired in file \"banLists.cfg\"",3) if($nbPrunedBans);

  $self->removeExpiredBans();

  my $p_effectiveBan={banType => 3};
  my @allBans=();

  my $p_bans=findMatchingData($p_userData,$self->{banLists}->{""});
  push(@allBans,$p_bans->[0]) if(@{$p_bans});

  my $p_bansAuto=findMatchingData($p_userData,$self->{bans});
  push(@allBans,@{$p_bansAuto});

  my $p_bansSpecific=[];
  $p_bansSpecific=findMatchingData($p_userData,$self->{banLists}->{$self->{conf}->{banList}}) if($self->{conf}->{banList});
  push(@allBans,$p_bansSpecific->[0]) if(@{$p_bansSpecific});

  foreach my $p_ban (@allBans) {
    $p_effectiveBan=$p_ban if($p_ban->{banType} < $p_effectiveBan->{banType})
  }

  return $p_effectiveBan;
}

sub banUser {
  my ($self,$p_user,$p_ban)=@_;
  push(@{$self->{bans}},[$p_user,$p_ban]);
  $self->dumpTable($self->{bans},$self->{conf}->{varDir}."/bans.dat",\@banListsFields);
}

sub unban {
  my ($self,$p_filters)=@_;
  $self->{bans}=removeMatchingData($p_filters,$self->{bans});
  $self->dumpTable($self->{bans},$self->{conf}->{varDir}."/bans.dat",\@banListsFields);
}

# Business functions - Dynamic data - Preferences #############################

sub checkUserPref {
  my ($self,$prefName,$prefValue)=@_;
  $prefName=lc($prefName);
  my $invalidValue=0;
  $invalidValue=1 if($prefValue =~ /[\:\|]/);
  foreach my $pref (@{$preferencesListsFields[1]}) {
    if($prefName eq lc($pref)) {
      if($invalidValue || ($prefValue ne "" && exists $spadsSectionParameters{$pref} && (! checkValue($prefValue,$spadsSectionParameters{$pref})))) {
        return ("invalid value \"$prefValue\" for preference $pref",$pref);
      }else{
        return ("",$pref);
      }
    }
  }
  return("invalid preference \"$prefName\"");
}

sub getAccountPrefs {
  my ($self,$aId)=@_;
  my %prefs;
  foreach my $pref (@{$preferencesListsFields[1]}) {
    $prefs{$pref}='';
  }
  return \%prefs unless(exists $self->{preferences}->{$aId});
  foreach my $pref (keys %{$self->{preferences}->{$aId}}) {
    next if($pref eq 'name');
    $prefs{$pref}=$self->{preferences}->{$aId}->{$pref};
  }
  return \%prefs;
}

sub getUserPrefs {
  my ($self,$aId,$name)=@_;
  my %prefs;
  foreach my $pref (@{$preferencesListsFields[1]}) {
    $prefs{$pref}="";
  }
  my $key=$aId || "?($name)";
  if(! exists $self->{preferences}->{$key}) {
    if(exists $self->{preferences}->{"?($name)"}) {
      $self->{preferences}->{$key}=delete $self->{preferences}->{"?($name)"};
    }else{
      return \%prefs;
    }
  }
  $self->{preferences}->{$key}->{name}=$name;
  foreach my $pref (keys %{$self->{preferences}->{$key}}) {
    next if($pref eq 'name');
    $prefs{$pref}=$self->{preferences}->{$key}->{$pref};
  }
  return \%prefs;
}

sub setUserPref {
  my ($self,$aId,$name,$prefName,$prefValue)=@_;
  my $key=$aId || "?($name)";
  if(! exists $self->{preferences}->{$key}) {
    if(exists $self->{preferences}->{"?($name)"}) {
      $self->{preferences}->{$key}=delete $self->{preferences}->{"?($name)"};
    }else{
      $self->{preferences}->{$key}={};
      foreach my $pref (@{$preferencesListsFields[1]}) {
        $self->{preferences}->{$key}->{$pref}="";
      }
    }
  }
  $self->{preferences}->{$key}->{name}=$name;
  $self->{preferences}->{$key}->{$prefName}=$prefValue;
}

1;
