package SpringieExtension;

use strict;

use File::Basename 'basename';
use JSON::PP;
use SOAP::Lite
    autotype => 0,
    on_action => sub {join('', @_)};

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.4';
my $requiredSpadsVersion='0.11.19';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'],
                           lobbyExtensionChan => ['login'],
                           lobbyExtensionBot => ['login'],
                           springieServiceProxy => ['notNull'],
                           springieServiceTimeout => ['integer'],
                           springieServiceNamespace => ['notNull'],
                           springieServiceLogin => ['login','null'],
                           springieServicePassword => ['password','null'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

my @springieUsersFields=(['SpringieLevel','ZkAdmin','SpadsLevel'],['NewSpadsLevel']);

sub new {
  my $class=shift;
  my $self = { hLobbyDefault => {join => undef,
                                 joined => undef,
                                 left => undef,
                                 said => undef},
               userExt => {},
               json => {},
               lastPurgeTs => time,
               users => {},
               soap => undef };
  bless($self,$class);

  my $p_spadsConf=getSpadsConf();
  my $spads=getSpadsConfFull();
  my $p_users=SpadsConf::loadTableFile($spads->{log},$p_spadsConf->{etcDir}.'/SpringieExtension.users.conf',\@springieUsersFields,{});
  return undef unless(%{$p_users});
  $self->{users}=$p_users->{''};

  my $soap = SOAP::Lite->new();
  return undef unless(defined $soap);

  my $p_conf=getPluginConf();
  $soap->proxy($p_conf->{springieServiceProxy}, timeout => $p_conf->{springieServiceTimeout})->default_ns($p_conf->{springieServiceNamespace});
  $self->{soap}=$soap;

  addSpadsCommandHandler({setOptions => \&hSpadsSetOptions});

  if(getLobbyState() > 3) {
    $self->replaceLobbyHandlers();
    queueLobbyCommand(['JOIN',$p_conf->{lobbyExtensionChan}]);
  }

  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onLobbyConnected {
  my $self=shift;
  $self->{userExt}={};
  $self->replaceLobbyHandlers();
  queueLobbyCommand(['JOIN',getPluginConf()->{lobbyExtensionChan}]);
}

sub hLobbyJoin {
  return if($_[1] eq getPluginConf()->{lobbyExtensionChan});
  &{getPlugin()->{hLobbyDefault}->{join}}(@_);
}

sub hLobbyJoined {
  return if($_[1] eq getPluginConf()->{lobbyExtensionChan});
  &{getPlugin()->{hLobbyDefault}->{joined}}(@_);
}

sub hLobbyLeft {
  return if($_[1] eq getPluginConf()->{lobbyExtensionChan});
  &{getPlugin()->{hLobbyDefault}->{left}}(@_);
}

sub hLobbySaid {
  my $p_conf=getPluginConf();
  if($_[1] eq $p_conf->{lobbyExtensionChan}) {
    handleSpringieExtensionLobbyMsg($_[3]) if($_[2] eq $p_conf->{lobbyExtensionBot});
    return;
  }
  &{getPlugin()->{hLobbyDefault}->{said}}(@_);
}

sub hSpadsSetOptions {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,'setoptions');
    return 0;
  }

  if(getLobbyState() < 6) {
    answer("Unable to set battle settings, battle is closed!");
    return 0;
  }

  my $lobby=getLobbyInterface();
  my $p_spadsConf=getSpadsConf();
  my $spads=getSpadsConfFull();

  my %newSettings;
  my @alreadySet;
  my @bSettingDefs=split(/,/,$p_params->[0]);
  foreach my $bSettingDef (@bSettingDefs) {
    my ($bSetting,$val);
    if($bSettingDef =~ /^([^=]+)=(.*)$/) {
      ($bSetting,$val)=($1,$2);
    }else{
      invalidSyntax($user,'setoptions');
      return 0;
    }
    $bSetting=lc($bSetting);

    my $p_modOptions=::getModOptions($lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod});
    my $p_mapOptions=::getMapOptions($p_spadsConf->{map});
    
    if($bSetting ne 'startpostype' && ! exists $p_modOptions->{$bSetting} && ! exists $p_mapOptions->{$bSetting}) {
      answer("\"$bSetting\" is not a valid battle setting for current mod and map (use \"!list bSettings\" to list available battle settings)");
      return 0;
    }

    my $optionScope='engine';
    my $p_options={};
    my $allowExternalValues=0;
    if(exists $p_modOptions->{$bSetting}) {
      $optionScope='mod';
      $p_options=$p_modOptions;
      $allowExternalValues=$p_spadsConf->{allowModOptionsValues};
    }elsif(exists $p_mapOptions->{$bSetting}) {
      $optionScope='map';
      $p_options=$p_mapOptions;
      $allowExternalValues=$p_spadsConf->{allowMapOptionsValues};
    }
    my @allowedValues=::getBSettingAllowedValues($bSetting,$p_options,$allowExternalValues);
    if(! @allowedValues && $allowExternalValues) {
      answer("\"$bSetting\" is a $optionScope option of type \"$p_options->{$bSetting}->{type}\", it must be defined in current battle preset to be modifiable");
      return 0;
    }
    
    my $allowed=0;
    foreach my $allowedValue (@allowedValues) {
      if(::isRange($allowedValue)) {
        $allowed=1 if(::matchRange($allowedValue,$val));
      }elsif($val eq $allowedValue) {
        $allowed=1;
      }
      last if($allowed);
    }
    if(! $allowed) {
      answer("Value \"$val\" for battle setting \"$bSetting\" is not allowed with current $optionScope or battle preset"); 
      return 0;
    }
    if(exists $spads->{bSettings}->{$bSetting}) {
      if($spads->{bSettings}->{$bSetting} eq $val) {
        push(@alreadySet,$bSetting);
      }else{
        $newSettings{$bSetting}=$val;
      }
    }elsif($val eq $p_options->{$bSetting}->{default}) {
      push(@alreadySet,$bSetting);
    }else{
      $newSettings{$bSetting}=$val;
    }
  }

  if(@alreadySet) {
    my $alreadySetString=join(',',@alreadySet);
    answer('Battle setting'.($#alreadySet>0?'s':'')." $alreadySetString ".($#alreadySet>0?'were':'was').' already set to specified value'.($#alreadySet>0?'s':''));
  }
  return 0 unless(%newSettings);

  my @newDefs;
  foreach my $bSetting (sort keys %newSettings) {
    push(@newDefs,"$bSetting=$newSettings{$bSetting}");
    if(! $checkOnly) {
      $spads->{bSettings}->{$bSetting}=$newSettings{$bSetting};
      ::sendBattleSetting($bSetting);
    }
  }
  my $newDefsString=join(',',@newDefs);
  return "setOptions $newDefsString" if($checkOnly);

  $::timestamps{autoRestore}=time;
  sayBattleAndGame('Battle setting'.($#newDefs>0?'s':'')." changed by $user ($newDefsString)");
  answer('Battle setting'.($#newDefs>0?'s':'')." changed ($newDefsString)") if($source eq 'pv');
  ::applyMapBoxes() if(exists $newSettings{startpostype});
  return;
}

sub onPrivateMsg {
  my (undef,$user,$msg)=@_;
  return 0 unless($user eq getPluginConf()->{lobbyExtensionBot});
  handleSpringieExtensionLobbyMsg($msg);
  return 1;
}

sub onUnload {
  my $self=shift;
  queueLobbyCommand(['LEAVE',getPluginConf()->{lobbyExtensionChan}]) if(getLobbyState() > 3);
  removeLobbyCommandHandler(['JOIN','JOINED','LEFT','SAID'],'main');
  addLobbyCommandHandler( { JOIN => $self->{hLobbyDefault}->{join},
                            JOINED => $self->{hLobbyDefault}->{joined},
                            LEFT => $self->{hLobbyDefault}->{left},
                            SAID => $self->{hLobbyDefault}->{said} },
                          'main' );
  removeSpadsCommandHandler(['setOptions']);
  slog("Plugin unloaded",3);
}

sub updateCmdAliases {
  my ($self,$p_spadsAliases)=@_;
  $p_spadsAliases->{voteresign}=['callVote','resign'];
  $p_spadsAliases->{votesetoptions}=['callVote','setOptions'];
  $p_spadsAliases->{transmit}=['say'];
  $p_spadsAliases->{cheats}=['cheat'];
  $p_spadsAliases->{hostsay}=['send'];
  $p_spadsAliases->{corners}=['split','c','%2%'];
}

sub changeUserAccessLevel {
  my ($self,$user,$p_user,$isAuthenticated,$currentAccessLevel)=@_;
  my $p_userData={SpringieLevel => 0,
                  ZkAdmin => 0,
                  SpadsLevel => $currentAccessLevel};
  if(exists $self->{userExt}->{$user}) {
    my $p_userExt=$self->{userExt}->{$user};
    for my $userExtField (qw/SpringieLevel ZkAdmin/) {
      $p_userData->{$userExtField}=$p_userExt->{$userExtField} if(exists $p_userExt->{$userExtField} && $p_userExt->{$userExtField} ne '');
    }
  }
  my $p_levels=SpadsConf::findMatchingData($p_userData,$self->{users});
  if(@{$p_levels}) {
    return $p_levels->[0]->{NewSpadsLevel};
  }else{
    return undef;
  }
}

sub eventLoop {
  my $self=shift;
  return if(time - $self->{lastPurgeTs} < 60);
  $self->{lastPurgeTs}=time;
  my $autohost=getSpringInterface();
  return if($autohost->getState());

  my @usersToPurge;
  my $lobby=getLobbyInterface();
  foreach my $user (keys %{$self->{userExt}}) {
    push(@usersToPurge,$user) unless(exists $lobby->{users}->{$user});
  }
  foreach my $user (@usersToPurge) {
    delete $self->{userExt}->{$user};
  }
}

# Internal functions

sub replaceLobbyHandlers {
  my $self=shift;
  my $lobby=getLobbyInterface();
  $self->{hLobbyDefault}->{join}=$lobby->{callbacks}->{JOIN}->{main}->[0];
  $self->{hLobbyDefault}->{joined}=$lobby->{callbacks}->{JOINED}->{main}->[0];
  $self->{hLobbyDefault}->{left}=$lobby->{callbacks}->{LEFT}->{main}->[0];
  $self->{hLobbyDefault}->{said}=$lobby->{callbacks}->{SAID}->{main}->[0];
  removeLobbyCommandHandler(['JOIN','JOINED','LEFT','SAID'],'main');
  addLobbyCommandHandler( { JOIN => \&hLobbyJoin,
                            JOINED => \&hLobbyJoined,
                            LEFT => \&hLobbyLeft,
                            SAID => \&hLobbySaid },
                          'main' );
}

sub handleSpringieExtensionLobbyMsg {
  my $msg=shift;
  if($msg =~ /^\s*USER_EXT\s+([^\s]+)\s+(.+)$/) {
    handleUserExt($1,$2);
  }elsif($msg =~ /^!JSON\s+([^\s]+)\s+(.+)$/) {
    handleJson($1,$2);
  }else{
    slog('Ignoring unknown message from '.getPluginConf()->{lobbyExtensionBot}.": $msg",5);
  }
}

sub handleUserExt {
  my ($user,$ext)=@_;
  my @exts=split(/\|/,$ext);
  if(($#exts + 1) % 2) {
    slog('Ignoring invalid USER_EXT message from '.getPluginConf()->{lobbyExtensionBot}.", inconsistent number of fields in \"$ext\" (for user $user)",2);
    return;
  }
  my $self=getPlugin();
  $self->{userExt}->{$user}={};
  while(@exts) {
    my $attribute=shift(@exts);
    my $value=shift(@exts);
    $self->{userExt}->{$user}->{$attribute}=$value;
  }
}

sub handleJson {
  my ($fieldName,$json)=@_;
  getPlugin()->{json}->{$fieldName}=decode_json($json);
}

sub storeKeyValueInHash {
  my ($p_data,$p_hash,$keyName,$valueName)=@_;
  if(ref($p_data) eq 'HASH') {
    if(exists $p_data->{$keyName} && exists $p_data->{$valueName}) {
      $p_hash->{$p_data->{$keyName}}=$p_data->{$valueName};
    }else{
      slog("Ignoring invalid $keyName/$valueName hash in WebService response",2);
    }
  }else{
    slog("Ignoring invalid $keyName/$valueName data in WebService response",2);
  }
}

sub keyValuePairs2hash {
  my ($p_data,$keyName,$valueName)=@_;
  my %res;
  if(ref($p_data) eq 'ARRAY') {
    foreach my $p_subData (@{$p_data}) {
      storeKeyValueInHash($p_subData,\%res,$keyName,$valueName);
    }
  }else{
    storeKeyValueInHash($p_data,\%res,$keyName,$valueName);
  }
  return \%res;
}

sub userCustomParameters2hash {
  my $p_data=shift;
  my $p_res=keyValuePairs2hash($p_data,'LobbyID','Parameters');
  my %res;
  foreach my $id (keys %{$p_res}) {
    if(exists $p_res->{$id}->{ScriptKeyValuePair}) {
      $res{$id}=keyValuePairs2hash($p_res->{$id}->{ScriptKeyValuePair},'Key','Value');
    }
  }
  return \%res;
}

sub GetSpringBattleStartSetup {
  my ($self,$p_players,$p_specs)=@_;
  my @soapParams;
  foreach my $id (@{$p_players}) {
    push(@soapParams,{ LobbyID => $id,
                       IsSpectator => 'false' });
  }
  foreach my $id (@{$p_specs}) {
    push(@soapParams,{ LobbyID => $id,
                       IsSpectator => 'true' });
  }
  my $soapCallResult;
  eval {
    $soapCallResult=$self->{soap}->call('GetSpringBattleStartSetup', SOAP::Data->name(context => {Players => {PlayerTeam => SOAP::Data->value(@soapParams)}}));
  };
  if($@) {
    slog("Error when calling SpringieService/GetSpringBattleStartSetup web service: $@",1);
    return {};
  }
  if($soapCallResult->fault()) {
    slog('SOAP fault when calling SpringieService/GetSpringBattleStartSetup web service: '.$soapCallResult->fault()->{faultstring},1);
    return {};
  }
  my $p_soapRes=$soapCallResult->result();

  my %res;
  if(exists $p_soapRes->{UserParameters} && exists $p_soapRes->{UserParameters}->{UserCustomParameters}) {
    $res{playerData}=userCustomParameters2hash($p_soapRes->{UserParameters}->{UserCustomParameters});
  }
  if(exists $p_soapRes->{ModOptions} && exists $p_soapRes->{ModOptions}->{ScriptKeyValuePair}) {
    my $p_modOptions=keyValuePairs2hash($p_soapRes->{ModOptions}->{ScriptKeyValuePair},'Key','Value');
    foreach my $modOption (keys %{$p_modOptions}) {
      $res{"game/modoptions/$modOption"}=$p_modOptions->{$modOption};
    }
  }
  return \%res;
}

sub getNameOfSimilarSpringieAutohost {
  my ($self,$gameType)=@_;

  if(! defined $gameType) {
    my $p_spadsConf=getSpadsConf();
    my $nbTeams=$p_spadsConf->{nbTeams};
    if($nbTeams == 1) {
      $gameType='Chicken';
    }elsif($nbTeams == 2 && $p_spadsConf->{teamSize} == 1) {
      $gameType='Duel';
    }elsif($nbTeams > 2) {
      $gameType='FFA';
    }else{
      $gameType='Team';
    }
  }

  my %springieAutohosts=(Duel => 'Elerium',
                         FFA => 'Neon',
                         Chicken => 'Iodine');

  return $springieAutohosts{$gameType} if(exists $springieAutohosts{$gameType});
  return undef;
}

sub GetRecommendedMap {
  my ($self,$nbPlayers,$autohostName)=@_;
  slog('GetRecommendedMap called with nbPlayers='.(defined $nbPlayers ? $nbPlayers : 'undef').' and autohostName='.(defined $autohostName ? $autohostName : 'undef'),5);
  my @playerTeams=({IsSpectator => 'false'});
  for my $i (2..$nbPlayers) {
    push(@playerTeams,{IsSpectator => 'false'});
  }

  my %battleContext=(Players => {PlayerTeam => SOAP::Data->value(@playerTeams)});
  $battleContext{AutohostName}=$autohostName if(defined $autohostName);

  my $soapCallResult;
  eval {
    $soapCallResult=$self->{soap}->call('GetRecommendedMap',
                                        SOAP::Data->name(context => \%battleContext),
                                        SOAP::Data->name(pickNew => 'true'));
  };
  if($@) {
    slog("Error when calling SpringieService/GetRecommendedMap web service: $@",1);
    return undef;
  }
  if($soapCallResult->fault()) {
    slog('SOAP fault when calling SpringieService/GetRecommendedMap web service: '.$soapCallResult->fault()->{faultstring},1);
    return undef;
  }
  my $p_soapRes=$soapCallResult->result();
  return $p_soapRes->{MapName} if(exists $p_soapRes->{MapName});
  return undef;
}

sub GetMapCommands {
  my ($self,$map)=@_;
  my $soapCallResult;
  eval {
    $soapCallResult=$self->{soap}->call('GetMapCommands',SOAP::Data->name(mapName => $map));
  };
  if($@) {
    slog("Error when calling SpringieService/GetMapCommands web service: $@",1);
    return undef;
  }
  if($soapCallResult->fault()) {
    slog('SOAP fault when calling SpringieService/GetMapCommands web service: '.$soapCallResult->fault()->{faultstring},1);
    return undef;
  }
  return $soapCallResult->result();
}

sub SubmitSpringBattleResultFromEndGameData {
  my ($self,$p_endGameData,$p_extraData,$description,$login,$password)=@_;
  
  my $p_conf=getPluginConf();
  my $extraDataNeedsInit=0;
  $p_extraData=[] unless(defined $p_extraData);
  $extraDataNeedsInit=1 unless(@{$p_extraData});
  $description=$p_endGameData->{battleContext}->{title} unless(defined $description);
  if(! defined $login) {
    if($p_conf->{springieServiceLogin} ne '') {
      $login=$p_conf->{springieServiceLogin};
    }else{
      $login=$p_endGameData->{ahName};
    }
  }
  if(! defined $password) {
    if($p_conf->{springieServicePassword} ne '') {
      $password=$p_conf->{springieServicePassword};
    }else{
      $password=$p_endGameData->{ahPassword};
    }
  }

  my %context = ( AutohostName => $login,
                  CanPlanetwars => 'false' );
  my %result = ( Duration => $p_endGameData->{duration},
                 EngineBattleID => $p_endGameData->{gameId},
                 EngineVersion => SOAP::Utils::encode_data($p_endGameData->{battleContext}->{engineVersion}),
                 IngameStartTime => SOAP::Utils::format_datetime(gmtime($p_endGameData->{startPlayingTimestamp})).'Z',
                 IsBots => $p_endGameData->{nbBots} ? 'true' : 'false',
                 IsMission => 'false',
                 Map => SOAP::Utils::encode_data($p_endGameData->{map}),
                 Mod => SOAP::Utils::encode_data($p_endGameData->{mod}),
                 ReplayName => SOAP::Utils::encode_data(basename($p_endGameData->{demoFile})),
                 StartTime => SOAP::Utils::format_datetime(gmtime($p_endGameData->{startTimestamp})).'Z',
                 Title => SOAP::Utils::encode_data($description) );
  my @players;
  foreach my $p_gdrPlayer (@{$p_endGameData->{players}}) {
    next if($p_gdrPlayer->{name} eq $p_endGameData->{ahName});
    my $isSpec=$p_gdrPlayer->{allyTeam} eq '' ? 1 : 0;
    my %player=( AllyNumber => $isSpec ? 0 : $p_gdrPlayer->{allyTeam},
                 IsIngameReady => $isSpec ? 'false' : 'true',
                 IsSpectator => $isSpec ? 'true' : 'false',
                 IsVictoryTeam => ($p_endGameData->{result} ne 'undecided' && $p_gdrPlayer->{win}) ? 'true' : 'false',
                 LobbyID => $p_gdrPlayer->{accountId},
                 LoseTime => $p_gdrPlayer->{loseTime} eq '' ? undef : $p_gdrPlayer->{loseTime},
                 Rank => 0 );
    if(exists $p_endGameData->{battleContext}->{users}->{$p_gdrPlayer->{name}}) {
      $player{Rank}=$p_endGameData->{battleContext}->{users}->{$p_gdrPlayer->{name}}->{status}->{rank};
    }
    push(@players,\%player);
    push(@{$p_extraData},"READY:$p_gdrPlayer->{name}") if($extraDataNeedsInit && ! $isSpec);
  }
  for my $i (0..$#{$p_extraData}) {
    $p_extraData->[$i]=SOAP::Utils::encode_data($p_extraData->[$i]);
  }

  return $self->SubmitSpringBattleResult(\%context,$password,\%result,\@players,$p_extraData);
}

sub SubmitSpringBattleResult {
  my ($self,$p_context,$password,$p_result,$p_players,$p_extraData)=@_;
  my $soapCallResult;
  eval {
    $soapCallResult=$self->{soap}->call('SubmitSpringBattleResult',
                                        SOAP::Data->name(context => $p_context),
                                        SOAP::Data->name(password => $password),
                                        SOAP::Data->name(result => $p_result),
                                        SOAP::Data->name(players => {BattlePlayerResult => SOAP::Data->value(@{$p_players})}),
                                        SOAP::Data->name(extraData => {string => SOAP::Data->value(@{$p_extraData})}));
  };
  if($@) {
    slog("Error when calling SpringieService/SubmitSpringBattleResult web service: $@",1);
    return undef;
  }
  if($soapCallResult->fault()) {
    slog('SOAP fault when calling SpringieService/SubmitSpringBattleResult web service: '.$soapCallResult->fault()->{faultstring},1);
    return undef;
  }
  return $soapCallResult->result();
}

1;
