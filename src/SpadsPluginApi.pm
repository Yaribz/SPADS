# SpadsPluginApi: SPADS plugin API
#
# Copyright (C) 2013-2015  Yann Riou <yaribzh@gmail.com>
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

package SpadsPluginApi;

use Exporter 'import';
@EXPORT=qw/$spadsVersion $spadsDir getLobbyState getSpringPid getSpringServerType getTimestamps getRunningBattle getCurrentVote getPlugin addSpadsCommandHandler removeSpadsCommandHandler addLobbyCommandHandler removeLobbyCommandHandler addSpringCommandHandler removeSpringCommandHandler forkProcess addSocket removeSocket getLobbyInterface getSpringInterface getSpadsConf getSpadsConfFull getPluginConf slog secToTime secToDayAge formatList formatArray formatFloat formatInteger getDirModifTime applyPreset quit cancelQuit closeBattle closeBattle rehost cancelCloseBattle getUserAccessLevel broadcastMsg sayBattleAndGame sayPrivate sayBattle sayBattleUser sayChan sayGame answer invalidSyntax queueLobbyCommand loadArchives/;

my $apiVersion='0.18';

our $spadsVersion=$::spadsVer;
our $spadsDir=$::cwd;

sub getVersion {
  return $apiVersion;
}

################################
# Accessors
################################

sub getCurrentVote {
  return \%::currentVote;
}

sub getLobbyInterface {
  return $::lobby;
}

sub getLobbyState {
  return $::lobbyState;
}

sub getRunningBattle {
  return $::p_runningBattle;
}

sub getSpadsConf {
  return \%::conf;
}

sub getSpadsConfFull {
  return $::spads;
}

sub getSpringInterface {
  return $::autohost;
}

sub getSpringPid {
  return $::springPid;
}

sub getSpringServerType {
  return $::springServerType;
}

sub getTimestamps {
  return \%::timestamps;
}

################################
# Plugin management
################################

sub getPlugin {
  my $pluginName=shift;
  $pluginName=caller() unless(defined $pluginName);
  return $::plugins{$pluginName} if(exists $::plugins{$pluginName});
}

sub getPluginConf {
  my $plugin=shift;
  $plugin=caller() unless(defined $plugin);
  return $::spads->{pluginsConf}->{$plugin}->{conf} if(exists $::spads->{pluginsConf}->{$plugin});
}

################################
# Handlers management
################################

sub addLobbyCommandHandler {
  my ($p_handlers,$priority)=@_;
  $priority=caller() unless(defined $priority);
  $::lobby->addCallbacks($p_handlers,0,$priority);
}

sub addSpadsCommandHandler {
  my ($p_handlers,$replace)=@_;
  my $plugin=caller();
  $replace=0 unless(defined $replace);
  foreach my $commandName (keys %{$p_handlers}) {
    my $lcName=lc($commandName);
    if(exists $::spadsHandlers{$lcName} && (! $replace)) {
      ::slog("Ignoring addSpadsCommandHandler for plugin $plugin (\"$lcName\" command already exists)",2);
    }else{
      $::spadsHandlers{$lcName}=$p_handlers->{$commandName};
    }
  }
}

sub addSpringCommandHandler {
  my ($p_handlers,$priority)=@_;
  $priority=caller() unless(defined $priority);
  $::autohost->addCallbacks($p_handlers,0,$priority);
}

sub removeLobbyCommandHandler {
  my ($p_commands,$priority)=@_;
  $priority=caller() unless(defined $priority);
  $::lobby->removeCallbacks($p_commands,$priority);
}

sub removeSpadsCommandHandler {
  my $p_commands=shift;
  my $plugin=caller();
  foreach my $commandName (@{$p_commands}) {
    my $lcName=lc($commandName);
    delete $::spadsHandlers{$lcName};
  }
}

sub removeSpringCommandHandler {
  my ($p_commands,$priority)=@_;
  $priority=caller() unless(defined $priority);
  $::autohost->removeCallbacks($p_commands,$priority);
}

################################
# Forking processes
################################

sub forkProcess {
  my ($p_processFunction,$p_endCallback)=@_;
  my $plugin=caller();
  my $childPid = fork();
  if(! defined $childPid) {
    ::slog("Unable to fork process for plugin $plugin !",1);
    return 0;
  }elsif($childPid == 0) {
    $SIG{CHLD}='' unless($win);
    &{$p_processFunction}();
    exit 0;
  }else{
    $::forkedProcesses{$childPid}=$p_endCallback;
    return $childPid;
  }
}

################################
# Sockets management
################################

sub addSocket {
  my ($socket,$p_readCallback)=@_;
  my $plugin=caller();
  if(exists $::sockets{$socket}) {
    ::slog("Unable to add socket for plugin $plugin: socket has already been added!",2);
    return 0;
  }
  $::sockets{$socket}=$p_readCallback;
  return 1;
}

sub removeSocket {
  my $socket=shift;
  my $plugin=caller();
  if(! exists $::sockets{$socket}) {
    ::slog("Unable to remove socket for plugin $plugin: unknown socket!",2);
    return 0;
  }
  delete $::sockets{$socket};
  return 1;
}

################################
# SPADS operations
################################

sub applyPreset {
  ::applyPreset(@_);
}

sub cancelCloseBattle {
  ::cancelCloseBAttleAfterGame();
}

sub cancelQuit {
  my $reason=shift;
  ::cancelQuitAfterGame($reason);
}

sub closeBattle {
  ::closeBattleAfterGame(@_);
}

sub getUserAccessLevel {
  ::getUserAccessLevel(@_);
}

sub loadArchives {
  ::loadArchives(@_);
}

sub queueLobbyCommand {
  ::queueLobbyCommand(@_);
}

sub quit {
  my ($type,$reason)=@_;
  my %typeFunctions=( 1 => \&::quitAfterGame,
                      2 => \&::restartAfterGame,
                      3 => \&::quitWhenEmpty,
                      4 => \&::restartWhenEmpty,
                      5 => \&::quitWhenOnlySpec,
                      6 => \&::restartWhenOnlySpec );
  &{$typeFunctions{$type}}($reason);
}

sub rehost {
  ::rehostAfterGame(@_);
}

sub slog {
  my($m,$l)=@_;
  my $plugin=caller();
  $m="<$plugin> $m";
  ::slog($m,$l);
}

################################
# AutoHost messaging system
################################

sub answer {
  ::answer(@_);
}

sub broadcastMsg {
  ::broadcastMsg(@_);
}

sub invalidSyntax {
  ::invalidSyntax(@_);
}

sub sayBattle {
  ::sayBattle(@_);
}

sub sayBattleAndGame {
  ::sayBattleAndGame(@_);
}

sub sayBattleUser {
  ::sayBattleUser(@_);
}

sub sayChan {
  ::sayChan(@_);
}

sub sayGame {
  ::sayGame(@_);
}

sub sayPrivate {
  ::sayPrivate(@_);
}

################################
# Time utils
################################

sub getDirModifTime {
  ::getDirModifTime(@_);
}

sub secToDayAge {
  ::secToDayAge(@_);
}

sub secToTime {
  ::secToTime(@_);
}

################################
# Data formatting
################################

sub formatArray {
  ::formatArray(@_);
}

sub formatFloat {
  ::formatNumber(@_);
}

sub formatInteger {
  ::formatInteger(@_);
}

sub formatList {
  ::formatList(@_);
}

1;

__END__

=head1 NAME

SpadsPluginApi - SPADS Plugin API

=head1 SYNOPSIS

  package MyPlugin;

  use SpadsPluginApi;

  no warnings 'redefine';

  my $pluginVersion='0.1';
  my $requiredSpadsVersion='0.11';

  sub getVersion { return $pluginVersion; }
  sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

  sub new {
    my $class=shift;
    my $self = {};
    bless($self,$class);
    slog("MyPlugin plugin loaded (version $pluginVersion)",3);
    return $self;
  }

  1;

=head1 DESCRIPTION

C<SpadsPluginApi> is a Perl module implementing the plugin API for SPADS. This
API allows anyone to add new features as well as customize existing SPADS
features (such as balancing algorithms, battle status presentation, players
skills management, command aliases...).

This API relies on plugin callback functions (implemented by SPADS plugins),
which can in turn call plugin API functions (implemented by SPADS core) and
access shared SPADS data.

=head1 CALLBACK FUNCTIONS

The callback functions are called from SPADS core and implemented by SPADS
plugins. SPADS plugins are actually Perl classes, which are instanciated as
objects. So even if not indicated below, all callback functions receive a
reference to the plugin object as first parameter (except the constructor,
which receives the class name as first parameter).

=head2 Mandatory callbacks

To be valid, a SPADS plugin must implement at least these 3 callbacks:

=over 2

=item C<new()>

This is the plugin constructor, it is called when SPADS (re)loads the plugin. It
must return the plugin object.

=item C<getVersion()>

returns the plugin version number (example: C<"0.1">).

=item C<getRequiredSpadsVersion()>

returns the required minimum SPADS version number (example: C<"0.11">).

=back

=head2 Configuration callback

SPADS plugins can use the core SPADS configuration system to manage their own
configuration parameters. This way, all configuration management tools in place
(parameter values checking, C<!reloadconf> etc.) can be reused by the plugins. To
do so, the plugin must implement following configuration callback:

=over 2

=item C<getParams()>

This callback must return a reference to an array containing 2 elements. The
first element is a reference to a hash containing the global plugin settings
declarations, the second one is the same but for plugin preset settings
declarations. These hashes use setting names as keys, and references to array of
allowed types as values. The types must match the keys of C<%paramTypes> defined
in SpadsConf.pm.

Example of implementation:

  my %globalPluginParams = ( MyGlobalSetting1 => ['integer'],
                             MyGlobalSetting2 => ['ipAddr']);
  my %presetPluginParams = ( MyPresetSetting1 => ['readableDir','null'],
                             MyPresetSetting2 => ['bool'] );

  sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

=back

=head2 Dependencies callback

SPADS plugins can use data and functions from other plugins (dependencies). But
this can only work if the plugin dependencies are loaded before the plugin
itself. That's why following callback should be used by such dependent plugins
to declare their dependencies, which will allow SPADS to perform the check for
them.
Also, SPADS will automatically unload dependent plugins when one of their
dependencies is unloaded.

=over 2

=item C<getDependencies()>

returns the dependencies plugins names list

Example of implementation:

  sub getDependencies { return ('SpringForumInterface','MailAlerts'); }

=back

=head2 Event-based callbacks

Following callbacks are triggered by events from various sources (SPADS, Spring
lobby, Spring server...):

=over 2

=item C<onBattleClosed()>

=item C<onBattleOpened()>

=item C<onGameEnd(\%endGameData)>

=item C<onJoinBattleRequest($userName,$ipAddr)>

This callback must return:

C<0> if the user is allowed to join the battle

C<1> if the user isn't allowed to join the battle (without explicit reason)

C<< "<explicit reason string>" >> if the user isn't allowed to join the battle, with explicit reason

=item C<onLobbyConnected($lobbyInterface)>

=item C<onLobbyDisconnected()>

=item C<onPresetApplied($oldPresetName,$newPresetName)>

=item C<onPrivateMsg($userName,$message)>

This callback must return:

C<0> if the message can be treated by other plugins and SPADS core

C<1> if the message must not be treated by other plugins and SPADS core (this
prevents logging)

=item C<onReloadConf($keepSettings)>

This callback must return:

C<0> if an error occured while reloading the plugin configuration

C<1> if the plugin configuration has been reloaded correctly

=item C<onSettingChange($settingName,$oldValue,$newValue)>

=item C<onSpringStart($springPid)>

=item C<onSpringStop($springPid)>

=item C<onUnload()>

This callback is called when the plugin is unloaded. If the plugin added
handlers for SPADS command, lobby commands, or Spring commands, then they must
be removed here. If the plugin handles persistent data, then these data must be
serialized here.

=item C<onVoteRequest($source,$user,\@command,\%remainingVoters)>

This callback is called each time a vote is requested by a player.

C<\%remainingVoters> is a reference to a hash containing the players allowed to
vote. This hash is indexed by player names. The plugin can filter these players
by simply removing the corresponding entries from the hash.

This callback must return 0 to prevent the vote call from happening, or 1 to
allow it.

=item C<onVoteStart($user,\@command)>

=item C<onVoteStop($voteResult)>

C<$voteResult> values: C<-1> (vote failed), C<0> (vote cancelled), C<1> (vote
passed)

=item C<postSpadsCommand($command,$source,$user,\@params,$commandResult)>

This callback is called each time a SPADS command has been executed.

If C<$commandResult> is defined and set to 0, then it means the command failed.

=item C<preSpadsCommand($command,$source,$user,\@params)>

This callback is called each time a SPADS command is going to be executed.

It must return 0 to prevent the command from being treated by other plugins and
executed by SPADS core, or 1 to allow it.

=back

=head2 Customization callbacks

Following callbacks are called by SPADS during specific operations to allow
plugins to customize features (more callbacks can be added on request):

=over 2

=item C<addStartScriptTags(\%additionalData)>

This callback is called when a Spring start script is generated, just before
launching the game. It allows plugins to declare additional scrip tags which
will be written in the start script.

C<\%additionalData> is a reference to a hash which must be updated by adding the
desired keys/values. For example a plugin can add a modoption named
"hiddenoption" with value "test" like this: C<$additionalData{"game/modoptions/hiddenoption"}="test">.
For tags to be added in player sections, the special key "playerData" must be
used. This special key must point to a hash associating each account ID to a
hash containing the tags to add in the corresponding player section.

=item C<balanceBattle(\%players,\%bots,$clanMode,$nbTeams,$teamSize)>

This callback is called each time SPADS needs to balance a battle and evaluate
the resulting balance quality. It allows plugins to replace the built-in balance
algorithm.

C<\%players> is a reference to a hash containing the players in the battle
lobby. This hash is indexed by player names, and the values are references to a
hash containing player data. For balancing, you should only need to access the
players skill as follows: C<< $players->{<playerName>}->{skill} >>

C<\%bots> is a reference to a hash containing the bots in the battle lobby. This
hash has exact same structure has C<\%players>.

C<$clanMode> is the current clan mode which must be applied to the balance. Clan
modes are specified L<here|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#set:clanMode>.
C<< <maxUnbalance> >> thresholds are automatically managed by SPADS, plugins
don't need to handle them. So basically, plugins only need to check if C<tag>
and/or C<pref> clan modes are enabled and apply them to their balance algorithm.

C<$nbTeams> and C<$teamSize> are the target battle structue computed by SPADS.
The number of entities to balance is the number of entries in C<\%players> +
number of entries in C<\%bots>. The number of entities to balance is always
C<< > $nbTeams*($teamSize-1) >>, and C<< <= $nbTeams*$teamSize >>.

If the plugin is able to balance the battle, it must update the C<\%players> and
C<\%bots> hash references with the team and id information. Assigned player
teams must be written in
C<< $players->{<playerName>}->{battleStatus}->{team} >>, and assigned player ids
must be written in C<< $players->{<playerName>}->{battleStatus}->{id} >>.
C<\%bots> works the same way. The return value is the unbalance indicator,
defined as follows: C<standardDeviationOfTeamSkills * 100 / averageTeamSkill>.

If the plugin is unable to balance the battle, it must not update C<\%players>
and C<\%bots>. The callback must return undef or a negative value so that SPADS
knows it has to use another plugin or internal balance algorithm instead.

=item C<canBalanceNow()>

This callback allows plugins to delay the battle balance operation. It is called
each time a battle balance operation is required (either automatic if
autoBalance is enabled, either manual if C<!balance> command is called). If the
plugin is ready for balance, it must return C<1>. Else, it can delay the
operation by returning C<0> (the balance algorithm won't be launched as long as
the plugin didn't return C<1>).

=item C<changeUserAccessLevel($userName,\%userData,$isAuthenticated,$currentAccessLevel)>

This callback is called by SPADS each time it needs to get the access level of a
user. It allows plugins to overwrite this level. Don't call the
C<getUserAccessLevel($user)> function from this callback, or the program will be
locked in recusrive loop! (and it would give you the same value as
C<$currentAccessLevel> anyway).

C<\%userData> is a reference to a hash containing the lobby data of the user

C<$isAuthenticated> indicates if the user has been authenticated (0: lobby
server in LAN mode and not authenticated at autohost level, 1: authenticated by
lobby server only, 2: authenticated by autohost)

The callback must return the new access level value if changed, or undef if not
changed.

=item C<filterRotationMaps(\@rotationMaps)>

This callback is called by SPADS each time a new map must be picked up for
rotation. It allows plugins to remove some maps from the rotation maps list
just before the new map is picked up.

C<\@rotationMaps> is a reference to an array containing the names of the maps
currently allowed for rotation.

The callback must return a reference to a new array containing the filtered map
names.

=item C<forceCpuSpeedValue()>

This callback allows plugins to force the CPU speed value declared by SPADS in
lobby. The callback must return the CPU speed value or undef if not forced.

=item C<setMapStartBoxes(\@boxes,$mapName,$nbTeams,$nbExtraBox)>

This callback allows plugins to set map start boxes (for "Choose in game" start
position type).

C<\@boxes> is a reference to an array containing the start boxes definitions.
A start box definition is a string containing the box coordinates separated by
spaces, in following order: left, top, right, bottom (0,0 is top left corner
and 200,200 is bottom right corner). If the array already contains box
definitions, it means SPADS already knows boxes for this map. In this case the
plugin can choose to override them by replacing the array content, or simply
leave it unmodified.

C<$nbExtraBox> is the number of extra box required. Usually this is 0, unless a
special game mode is enabled such as King Of The Hill.

The callback must return C<1> to prevent start boxes from being replaced by
other plugins, C<0> else.

=item C<setVoteMsg($reqYesVotes,$maxReqYesVotes,$reqNoVotes,$maxReqNoVotes,$nbRequiredManualVotes)>

This callback allows plugins to customize the vote status messages.

C<$reqYesVotes> is the total number of "yes" votes required for vote to pass (if
away-voters don't vote).

C<$reqNoVotes> is the total number of "no" votes required for vote to fail (if
away-voters don't vote).

C<$maxReqYesVotes> is the maximum total number of "yes" votes required for vote
to pass (if all away-voters come back and vote).

C<$maxReqNoVotes>  is the maximum total number of "no" votes required for vote
to fail (if all away-voters come back and vote).

C<$nbRequiredManualVotes> is the minimum number of manual votes required for
vote to be taken into account.

The callback must return a list containing following 2 elements: the lobby vote
message, and the in-game vote message (undef values can be used to keep default
messages).

=item C<updateCmdAliases(\%aliases)>

This callback allows plugins to add new SPADS command aliases by adding new
entries in the C<\%aliases> hash reference. This hash is indexed by alias names
and the values are references to an array containing the associated command. For
example, a plugin can add an alias "C<!cvmap ...>" for "C<!callVote map ...>"
like this: C<< $aliases->{cvmap}=['callVote','map'] >>

C<< "%<N>%" >> can be used as placeholders for original alias command
parameters. For example, a plugin can add an alias "C<< !iprank <playerName> >>"
for "C<< !chrank <playerName> ip >>" like this:
C<< $aliases->{iprank}=['chrank','%1%','ip'] >>

=item C<updatePlayerSkill(\%playerSkill,$accountId,$modName,$gameType)>

This callback is called by SPADS each time it needs to get or update the skill
of a player (on battle join, on game type change...). This allows plugins to
replace the built-in skill estimations (rank, TrueSkill...) with custom skill
estimations (ELO, Glicko ...).

C<\%playerSkill> is a reference to a hash containing the skill data of the
player. The plugin must update the C<skill> entry as follows:
C<< $playerSkill->{skill}=<skillValue> >>

C<$accountId> is the account ID of the player for whom skill value is requested.

C<$modName> is the currently hosted MOD (example: C<"Balanced Annihilation
V7.72">)

C<$gameType> is the current game type (C<"Duel">, C<"Team">, C<"FFA"> or
C<"TeamFFA">)

The return value is the skill update status: C<0> (skill not updated by the
plugin), C<1> (skill updated by the plugin), C<2> (skill updated by the plugin
in degraded mode)

=item C<updateGameStatusInfo(\%playerStatus,$accessLevel)>

This callback is called by SPADS for each player in game when the C<!status>
command is called, to allow plugins to update and/or add data which will be
presented to the user.

C<\%playerStatus> is a reference to the hash containing current player status
data. The plugin must update existing data or add new data in this hash. For
example: C<< $playerStatus->{myPluginData}=<myPluginValue> >>

C<$accessLevel> is the autohost access level of the user issuing the C<!status>
command.

The return value must be a reference to an array containing the names of the
status information updated or added by the plugin.

=item C<updateStatusInfo(\%playerStatus,$accountId,$modName,$gameType,$accessLevel)>

This callback is called by SPADS for each player in the battle lobby when the
C<!status> command is called, to allow plugins to update and/or add data which
will be presented to the user.

C<\%playerStatus> is a reference to the hash containing current player status
data. The plugin must update existing data or add new data in this hash. For
example: C<< $playerStatus->{myPluginData}=<myPluginValue> >>

C<$accountId> is the account ID of the player for whom status data update is
requested.

C<$modName> is the currently hosted MOD (example: C<"Balanced Annihilation
V7.72">)

C<$gameType> is the current game type (C<"Duel">, C<"Team">, C<"FFA"> or
C<"TeamFFA">)

C<$accessLevel> is the autohost access level of the user issuing the C<!status>
command.

The return value must be a reference to an array containing the names of the
status information updated or added by the plugin.

=back

=head2 Event loop callback

SPADS uses the asynchronous programming paradigm, so it is based on a main event
loop. The following callback is called during each iteration of this event loop,
to allow plugins to use same paradigm or simply manage time events:

=over 2

=item C<eventLoop()>

The plugins must manage all their time related operations (timeouts, scheduled
actions...) in this callback. This is also the place to check for results of
asynchronous calls, or to serialize regularly persistent data to avoid losing
them in case of crash for example. This callback shouldn't be blocking,
otherwise SPADS may become unstable.

=back

=head1 API FUNCTIONS

The API functions are implemented by SPADS core and can be called by SPADS
plugins.

=head2 Accessors

=over 2

=item C<getCurrentVote()>

=item C<getLobbyInterface()>

=item C<getLobbyState()>

This accessor returns an integer describing current lobby state (C<0>: not
connected, C<1>: connecting, C<2>: connected, C<3>: just logged in, C<4>: lobby
data received, C<5>: opening battle, C<6>: battle opened)

=item C<getRunningBattle()>

=item C<getSpadsConf()>

=item C<getSpadsConfFull()>

=item C<getSpringInterface()>

=item C<getSpringPid()>

=item C<getSpringServerType()>

=item C<getTimestamps()>

=back

=head2 Plugin management

=over 2

=item C<getPlugin($pluginName=caller())>

This function returns the plugin object matching the plugin name given as
parameter C<$pluginName>. If no parameter is provided, the plugin name of the
plugin calling the function is used.


=item C<getPluginConf($pluginName=caller())>

This function returns the plugin configuration for the plugin named
C<$pluginName>. If no parameter is provided, the plugin name of the plugin
calling the function is used. The return value is a reference to a hash using
plugin settings names as keys and plugin settings values as values.

=back

=head2 Handlers management

=over 2

=item C<addLobbyCommandHandler(\%handlers,$priority=caller())>

This function allows plugins to set up their own handlers for Spring lobby
commands received by SPADS from lobby server.

C<\%handlers> is a reference to a hash which contains the handlers to be added:
each entry associates a lobby command (in uppercase) to a handler function
implemented by the plugin. For example, with C<< { JOINBATTLEREQUEST =>
\&hLobbyJoinBattleRequest } >>, the plugin has to implement the function
C<hLobbyJoinBattleRequest>. The parameters passed to the handlers are the
command tokens: the command name followed by command parameters. Refer to
L<Spring lobby protocol specifications|http://springrts.com/dl/LobbyProtocol/ProtocolDescription.html>
for more information.

C<$priority> is the priority of the handlers. Lowest priority number actually
means higher priority. If not provided, the plugin name is used as priority,
which means it is executed after handlers having priority < 1000, and before
handlers having priority > 1000. Usually you don't need to provide priority,
unless you use data managed by other handlers.

=item C<addSpadsCommandHandler(\%handlers,$replace=0)>

This function allows plugins to add or replace SPADS command handlers.

C<\%handlers> is a reference to a hash which contains the handlers to be added
or replaced: each entry associates a SPADS command to a handler function
implemented by the plugin. For example, with
C<< { myCommand => \&hSpadsMyCommand } >>, the plugin has to implement the
function C<hSpadsMyCommand>. The parameters passed to the handlers are:
C<$source>,C<$userName>,C<\@params>,C<$checkOnly>.

C<$source> indicates the way the command has been called (C<"pv">: private lobby
message, C<"battle">: battle lobby message, C<"chan">: master lobby channel
message, C<"game">: in game message)

C<$userName> is the name of the user issuing the command

C<\@params> is a reference to an array containing the command parameters

C<$checkOnly> indicates that the command must not be executed but only checked
for consistency (this mode is used for !callVote command)

If the command cannot be executed (invalid syntax ...) the handler must return
C<0>. If the command is correct but requires automatic parameter adjustments
(automatic case correction or name completion for example), a string containing
the adjusted command must be returned. If it can be executed directly without
any adjustement, C<1> must be returned.

C<$replace> indicates if the handlers provided can replace existing ones: C<0>
means add handlers only if there is no handler for the given command (default),
C<1> means add or replace if existing.

=item C<addSpringCommandHandler(\%handlers,$priority=caller())>

This function allows plugins to set up their own handlers for Spring AutoHost
commands received by SPADS from Spring server.

C<\%handlers> is a reference to a hash which contains the handlers to be added:
each entry associates a Spring AutoHost command to a handler function
implemented by the plugin. The Spring AutoHost command names must match the
values of C<%commandCodes> defined in SpringAutoHostInterface.pm. For example,
with C<< { SERVER_STARTED => \&hSpringServerStarted } >>, the plugin has to
implement the function C<hSpringServerStarted>. The parameters passed to the
handlers are the command tokens: the command name followed by command
parameters. Refer to L<Spring autohost protocol specifications (from source comments)|https://raw.github.com/spring/spring/master/rts/Net/AutohostInterface.cpp> for more information.

C<$priority> is the priority of the handlers. Lowest priority number actually
means higher priority. If not provided, the plugin name is used as priority,
which means it is executed after handlers having priority < 1000, and before
handlers having priority > 1000. Usually you don't need to provide priority,
unless you use data managed by other handlers.

=item C<removeLobbyCommandHandler(\@commands,$priority=caller())>

This function must be called by plugins which added lobby command handlers
previously using C<addLobbyCommandHandler> function, when these handlers are no
longer required (for example in the C<onUnload> callback, when the plugin is
unloaded).

C<\@commands> is a reference to an array containing the lobby command names (in
uppercase) for which the handlers must be removed.

C<$priority> is the priority of the handlers to remove. It must be the same as
the priority used when adding the handlers. If not provided, the plugin name is
used as priority. Usually you don't need to provide priority, unless you use
data managed by other handlers.

=item C<removeSpadsCommandHandler(\@commands)>

This function must be called by plugins which added SPADS command handlers
previously using C<addSpadsCommandHandler> function, when these handlers are no
longer required (for example in the C<onUnload> callback, when the plugin is
unloaded).

C<\@commands> is a reference to an array containing the SPADS command names (in
uppercase) for which the handlers must be removed.

=item C<removeSpringCommandHandler(\@commands,$priority=caller())>

This function must be called by plugins which added Spring AutoHost command
handlers previously using C<addSpringCommandHandler> function, when these
handlers are no longer required (for example in the C<onUnload> callback, when
the plugin is unloaded).

C<\@commands> is a reference to an array containing the Spring AutoHost command
names for which the handlers must be removed.

C<$priority> is the priority of the handlers to remove. It must be the same as
the priority used when adding the handlers. If not provided, the plugin name is
used as priority. Usually you don't need to provide priority, unless you use data
managed by other handlers.

=back

=head2 SPADS operations

=over 2

=item C<applyPreset($presetName)>

=item C<cancelCloseBattle()>

=item C<cancelQuit($reason)>

=item C<closeBattle($reason)>

=item C<getUserAccessLevel($user)>

=item C<loadArchives()>

=item C<queueLobbyCommand(\@lobbyCommand)>

=item C<quit($type,$reason)>

=item C<rehost($reason)>

=item C<slog($message,$level)>

This function uses SPADS logging system to write a message in main SPADS log
file.

C<$message> is the log message

C<$level> is the log level of the message: C<0> (critical), C<1> (error), C<2>
(warning), C<3> (notice), C<4> (info), C<5> (debug)

=back

=head2 AutoHost messaging system

=over 2

=item C<answer($message)>

=item C<broadcastMsg($message)>

=item C<invalidSyntax($user,$lowerCaseCommand,$cause='')>

=item C<sayBattle($message)>

=item C<sayBattleAndGame($message)>

=item C<sayBattleUser($user,$message)>

=item C<sayChan($message)>

=item C<sayGame($message)>

=item C<sayPrivate($user,$message)>

=back

=head2 Time utils

=over 2

=item C<getDirModifTime($directory)>

=item C<secToDayAge($seconds)>

=item C<secToTime($seconds)>

=back

=head2 Data formatting

=over 2

=item C<formatArray>

=item C<formatFloat($float)>

=item C<formatInteger($integer)>

=item C<formatList>

=back

=head2 Forking processes

=over 2

=item C<forkProcess(\&processFunction,\&endProcessCallback)>

This function allows plugins to fork a process from main SPADS process, for
parallel processing. It returns the PID of the forked process on success, or 0
if the child process couldn't be forked.

C<\&processFunction> is a reference to a function containing the code to be
executed in the forked process (no parameter is passed to this function). This
function can call C<exit> to end the forked process with a specific exit code.
If it returns without calling exit, then the exit code C<0> will be used.

C<\&endProcessCallback> is a reference to a function containing the code to be
executed in SPADS main process, once the forked process exited. Following
parameters are passed to this function: C<$exitCode> (exit code of the forked
process), C<$signalNb> (signal number responsible for forked process termination
if any), C<$hasCoreDump> (boolean flag indicating if a core dump occured in the
forked process)

=back

=head2 Sockets management

=over 2

=item C<addSocket(\$socketObject,\&readCallback)>

This function allows plugins to add sockets to SPADS asynchronous network
system. It returns 1 if the socket has correctly been added, 0 else.

C<\$socketObject> is a reference to a socket object created by the plugin

C<\&readCallback> is a reference to a plugin function containing the code to
read the data received on the socket. This function will be called automatically
every time data are received on the socket, with the socket object as unique
parameter. It must not block, and only unbuffered Perl functions must be used to
read data from the socket (C<sysread()> or C<recv()> for example).

=item C<removeSocket(\$socketObject)>

This function allows plugins to remove sockets from SPADS asynchronous network
system. It returns 1 if the socket has correctly been removed, 0 else.

C<\$socketObject> is a reference to a socket object previously added by the
plugin

=back

=head1 SHARED DATA

=head2 Constants

Following constants are directly accessible from plugin modules:

=over 2

=item C<$spadsVersion>

=item C<$spadsDir>

=back

=head2 Variables

Following variables are directly accessible from plugin modules, but it is
strongly recommended to use the accessors from the API instead:

=over 2

=item C<$::autohost>

=item C<%::conf>

=item C<%::currentVote>

=item C<%::forkedProcesses>

=item C<$::lobby>

=item C<$::lobbyState>

=item C<$::p_runningBattle>

=item C<%::plugins>

=item C<%::sockets>

=item C<$::spads>

=item C<%::spadsHandlers>

=item C<$::springPid>

=item C<$::springServerType>

=item C<%::timestamps>

=back

=head1 SEE ALSO

L<SPADS plugin development tutorials|http://springrts.com/wiki/SPADS_plugin_development>

Commented SPADS plugin templates: L<Simple plugin|http://planetspads.free.fr/spads/plugins/templates/commented/MySimplePlugin.pm>, L<Configurable plugin|http://planetspads.free.fr/spads/plugins/templates/commented/MyConfigurablePlugin.pm>, L<New command plugin|http://planetspads.free.fr/spads/plugins/templates/commented/MyNewCommandPlugin.pm>

L<SPADS documentation|http://planetspads.free.fr/spads/doc/spadsDoc.html>, especially regarding plugins management: L<pluginsDir setting|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#global:pluginsDir>, L<autoLoadPlugins setting|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#global:autoLoadPlugins>, L<plugin command|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#command:plugin>

L<Spring lobby protocol specifications|http://springrts.com/dl/LobbyProtocol/ProtocolDescription.html>

L<Spring autohost protocol specifications (from source comments)|https://raw.github.com/spring/spring/master/rts/Net/AutohostInterface.cpp>

L<Introduction to Perl|http://perldoc.perl.org/perlintro.html>

=head1 COPYRIGHT

Copyright (C) 2013  Yann Riou <yaribzh@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

=cut
