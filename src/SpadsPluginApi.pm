# SpadsPluginApi: SPADS plugin API
#
# Copyright (C) 2013-2021  Yann Riou <yaribzh@gmail.com>
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

use File::Spec::Functions qw'catdir';
use List::Util qw'any none';

use Exporter 'import';
@EXPORT=qw/$spadsVersion $spadsDir loadPythonPlugin get_flag fix_string getLobbyState getSpringPid getSpringServerType getTimestamps getRunningBattle getConfMacros getCurrentVote getPlugin getPluginList addSpadsCommandHandler removeSpadsCommandHandler addLobbyCommandHandler removeLobbyCommandHandler addSpringCommandHandler removeSpringCommandHandler forkProcess forkCall removeProcessCallback createDetachedProcess addTimer removeTimer addSocket removeSocket getLobbyInterface getSpringInterface getSpadsConf getSpadsConfFull getPluginConf slog updateSetting secToTime secToDayAge formatList formatArray formatFloat formatInteger getDirModifTime applyPreset quit cancelQuit closeBattle rehost cancelCloseBattle getUserAccessLevel broadcastMsg sayBattleAndGame sayPrivate sayBattle sayBattleUser sayChan sayGame answer invalidSyntax queueLobbyCommand loadArchives/;

my $apiVersion='0.31';

our $spadsVersion=$::spadsVer;
our $spadsDir=$::cwd;

sub getVersion {
  return $apiVersion;
}

sub hasEvalError {
  if($@) {
    chomp($@);
    return 1;
  }else{
    return 0;
  }
}

*getCallerPlugin=\&SimpleEvent::getOriginPackage;

################################
# Python plugins specific
################################

my $pythonReloadPrefix;
my $inlinePythonUseByteString;
sub initPythonInterpreter {
  my $spadsConf=shift;
  my $inlinePythonTmpDir=catdir($spadsConf->{conf}{instanceDir},'.InlinePython.tmp');
  if(! -d $inlinePythonTmpDir && ! mkdir($inlinePythonTmpDir)) {
    $spadsConf->{log}->log("Unable to create temporary directory \"$inlinePythonTmpDir\" for Inline::Python used by plugin ".getCallerPlugin().": $!",1);
    return 0;
  }
  my ($escapedPluginsDir,$escapedInlinePythonTmpDir)=map {quotemeta($_)} ($spadsConf->{conf}{pluginsDir},$inlinePythonTmpDir);
  my $pythonBootstrap=<<"PYTHON_BOOTSTRAP_END";
import sys,signal,perl
sys.path.append(r'$escapedPluginsDir')
signal.signal(signal.SIGINT,signal.SIG_DFL)
PYTHON_BOOTSTRAP_END
  eval "use Inline Python => \"$pythonBootstrap\", directory => \"$escapedInlinePythonTmpDir\"";
  if(hasEvalError()) {
    $spadsConf->{log}->log('Unable to initialize Python environement for plugin '.getCallerPlugin().": $@",1);
    return 0;
  }
  $pythonApiFlags{can_fork}=$^O eq 'MSWin32' ? $Inline::Python::Boolean::false : $Inline::Python::Boolean::true;
  $pythonApiFlags{can_add_socket}=$^O eq 'MSWin32' ? $Inline::Python::Boolean::false : $Inline::Python::Boolean::true;
  $inlinePythonUseByteString=Inline::Python::py_eval('hasattr(perl.eval("$0"),"decode")',0)?$Inline::Python::Boolean::true:$Inline::Python::Boolean::false;
  $spadsConf->{log}->log('The version of Inline::Python currently in use converts Perl strings to Python byte strings',2) if($inlinePythonUseByteString);
  my $r_pythonVersion=Inline::Python::py_eval('[sys.version_info[i] for i in range(0,3)]',0);
  if(! defined $r_pythonVersion->[0] || ! defined $r_pythonVersion->[1]) {
    $spadsConf->{log}->log('Unable to initialize Python environement for plugin '.getCallerPlugin().': failed to determine Python version',1);
    return 0;
  }
  if($r_pythonVersion->[0] > 2) {
    $pythonReloadPrefix=$r_pythonVersion->[1]>3?'importlib':'imp';
    Inline::Python::py_eval("import $pythonReloadPrefix");
    $pythonReloadPrefix.='.';
  }else{
    $pythonReloadPrefix='';
  }
  my $pythonGetAttrSub=sub { my ($s,$a)=@_; return $s->{$a}; };
  ${SpadsConf::}{__getattr__}=$pythonGetAttrSub;
  ${SpringAutoHostInterface::}{__getattr__}=$pythonGetAttrSub;
  ${SpringLobbyInterface::}{__getattr__}=$pythonGetAttrSub;
  $spadsConf->{log}->log('Initialized Python interpreter v'.join('.',@{$r_pythonVersion}[0,1,2]),3);
  return 1;
}

sub loadPythonPlugin {
  my $spadsConf=shift;
  return 0 unless(defined($pythonReloadPrefix) || initPythonInterpreter($spadsConf));
  my $pluginName=getCallerPlugin();
  my $pythonModule=lc($pluginName);
  my $pythonLoadModule=<<"PYTHON_LOADMODULE_END";
if '$pythonModule' in dir():
    for attr in dir($pythonModule):
        if attr not in ('__name__', '__file__'):
            delattr($pythonModule, attr)
    $pythonModule = ${pythonReloadPrefix}reload($pythonModule)
else:
    import $pythonModule
PYTHON_LOADMODULE_END
  my $escapedInlinePythonTmpDir=quotemeta(catdir($spadsConf->{conf}{instanceDir},'.InlinePython.tmp'));
  eval "use Inline Python => \"$pythonLoadModule\", directory => \"$escapedInlinePythonTmpDir\", force_build => 1";
  if(hasEvalError()) {
    $spadsConf->{log}->log("Unable to load Python module for plugin $pluginName: $@",1);
    return 0;
  }
  my %pythonModuleNamespace = Inline::Python::py_study_package($pythonModule);
  if(! exists $pythonModuleNamespace{classes}{$pluginName}) {
    $spadsConf->{log}->log("Unable to load Python module for plugin $pluginName: Python class \"$pluginName\" not found",1);
    return 0;
  }
  foreach my $function (@{$pythonModuleNamespace{functions}}) {
    next unless(any {$function eq $_} (qw'getVersion getRequiredSpadsVersion getParams getDependencies'));
    Inline::Python::py_bind_func("${pluginName}::$function",$pythonModule,$function);
  }
  Inline::Python::py_bind_class($pluginName,$pythonModule,$pluginName,@{$pythonModuleNamespace{classes}{$pluginName}});
  return 1;
}

sub get_flag {
  my $flag=shift;
  if($flag eq 'can_fork' || $flag eq 'can_add_socket') {
    return $^O eq 'MSWin32' ? $Inline::Python::Boolean::false : $Inline::Python::Boolean::true;
  }elsif($flag eq 'use_byte_string') {
    return $inlinePythonUseByteString ? $Inline::Python::Boolean::true : $Inline::Python::Boolean::false;
  }else{
    ::slog("SpadsPluginApi::get_flag() called with unknown flag: $flag",2);
    return undef;
  }
}

sub fix_string { map {utf8::upgrade($_)} @_; return @_ }

################################
# Accessors
################################

sub getConfMacros {
  return \%::confMacros;
}

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
  $pluginName=getCallerPlugin() unless(defined $pluginName);
  return $::plugins{$pluginName};
}

sub getPluginConf {
  my $plugin=shift;
  $plugin=getCallerPlugin() unless(defined $plugin);
  return $::spads->{pluginsConf}->{$plugin}->{conf} if(exists $::spads->{pluginsConf}->{$plugin});
}

sub getPluginList {
  return \@::pluginsOrder;
}

################################
# Handlers management
################################

sub addLobbyCommandHandler {
  my ($p_handlers,$priority,$isPreCallback)=@_;
  my $plugin=getCallerPlugin();
  map {$_=SimpleEvent::encapsulateCallback($_,$plugin) unless(ref $_ eq 'CODE')} (values %{$p_handlers});
  $priority//=$plugin;
  if($isPreCallback) {
    $::lobby->addPreCallbacks($p_handlers,$priority);
  }else{
    $::lobby->addCallbacks($p_handlers,0,$priority);
  }
}

sub addSpadsCommandHandler {
  my ($p_handlers,$replace)=@_;
  my $plugin=getCallerPlugin();
  map {$_=SimpleEvent::encapsulateCallback($_,$plugin) unless(ref $_ eq 'CODE')} (values %{$p_handlers});
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
  my $plugin=getCallerPlugin();
  map {$_=SimpleEvent::encapsulateCallback($_,$plugin) unless(ref $_ eq 'CODE')} (values %{$p_handlers});
  $priority//=$plugin;
  $::autohost->addCallbacks($p_handlers,0,$priority);
}

sub removeLobbyCommandHandler {
  my ($p_commands,$priority,$isPreCallback)=@_;
  $priority//=getCallerPlugin();
  if($isPreCallback) {
    $::lobby->removePreCallbacks($p_commands,$priority);
  }else{
    $::lobby->removeCallbacks($p_commands,$priority);
  }
}

sub removeSpadsCommandHandler {
  my $p_commands=shift;
  my $plugin=getCallerPlugin();
  foreach my $commandName (@{$p_commands}) {
    my $lcName=lc($commandName);
    delete $::spadsHandlers{$lcName};
  }
}

sub removeSpringCommandHandler {
  my ($p_commands,$priority)=@_;
  $priority//=getCallerPlugin();
  $::autohost->removeCallbacks($p_commands,$priority);
}

################################
# Forking processes
################################

sub forkProcess {
  my ($p_processFunction,$p_endCallback,$preventQueuing)=@_;
  $preventQueuing//=1;
  my ($childPid,$procHdl) = SimpleEvent::forkProcess($p_processFunction, sub { &{$p_endCallback}($_[1],$_[2],$_[3],$_[0]) },$preventQueuing);
  ::slog('Failed to fork process for plugin '.getCallerPlugin().' !',1) if($childPid == 0);
  return wantarray() ? ($childPid,$procHdl) : $childPid;
}

sub forkCall {
  my ($childPid,$procHdl) = SimpleEvent::forkCall(@_);
  ::slog('Failed to fork process for function call by plugin '.getCallerPlugin().' !',1) if($childPid == 0);
  return wantarray() ? ($childPid,$procHdl) : $childPid;
}

sub removeProcessCallback {
  my $res=SimpleEvent::removeProcessCallback(@_);
  ::slog('Failed to remove process callback for plugin '.getCallerPlugin().' !',1) unless($res);
  return $res;
}

sub createDetachedProcess {
  my $res = SimpleEvent::createDetachedProcess(@_);
  ::slog('Failed to create detached process for plugin '.getCallerPlugin().' !',1) unless($res);
  return $res;
}

################################
# Timers management
################################

sub addTimer {
  my ($name,$delay,$interval,$p_callback)=@_;
  $name=getCallerPlugin().'::'.$name;
  return SimpleEvent::addTimer($name,$delay,$interval,$p_callback);
}

sub removeTimer {
  my $name=shift;
  $name=getCallerPlugin().'::'.$name;
  return SimpleEvent::removeTimer($name);
}

################################
# Sockets management
################################

sub addSocket {
  if(my $rc=SimpleEvent::registerSocket(@_)) {
    return $rc;
  }else{
    ::slog('Unable to add socket for plugin '.getCallerPlugin().' !',2);
    return 0;
  }
}

sub removeSocket {
  if(SimpleEvent::unregisterSocket(@_)) {
    return 1;
  }else{
    ::slog('Unable to remove socket for plugin '.getCallerPlugin().' !',2);
    return 0;
  }
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
  my ($m,$l)=@_;
  my $plugin=getCallerPlugin();
  $m="<$plugin> $m";
  ::slog($m,$l);
}

sub updateSetting {
  my ($type,$name,$value)=@_;
  my $plugin=getCallerPlugin();
  if(none {$type eq $_} (qw'set bSet hSet')) {
    ::slog("Ignoring updateSetting call from plugin $plugin: unknown setting type \"$type\"",2);
    return 0;
  }
  if($type eq 'set') {
    if(! exists $::spads->{conf}{$name}) {
      ::slog("Ignoring updateSetting call from plugin $plugin: unknown setting \"$name\"",2);
      return 0;
    }
    $::spads->{conf}{$name}=$value;
    %::conf=%{$::spads->{conf}};
    ::applySettingChange($name);
  }elsif($type eq 'bSet') {
    my $lcName=lc($name);
    $::spads->{bSettings}{$lcName}=$value;
    if($::lobbyState >= 6) {
      ::sendBattleSetting($lcName);
      ::applyMapBoxes() if($lcName eq 'startpostype');
    }
  }elsif($type eq 'hSet') {
    if(! exists $::spads->{hSettings}{$name}) {
      ::slog("Ignoring updateSetting call from plugin $plugin: unknown hosting setting \"$name\"",2);
      return 0;
    }
    $::spads->{hSettings}{$name}=$value;
    ::updateTargetMod() if($name eq 'modName');
  }else{
    return 0;
  }
  $::timestamps{autoRestore}=time;
  return 1;
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

Perl:

  package MyPlugin;

  use SpadsPluginApi;

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

Python:

  import perl
  spads=perl.MyPlugin

  pluginVersion = '0.1'
  requiredSpadsVersion = '0.12.29'

  def getVersion(pluginObject):
      return pluginVersion

  def getRequiredSpadsVersion(pluginName):
      return requiredSpadsVersion


  class MyPlugin:

      def __init__(self,context):
          spads.slog("MyPlugin plugin loaded (version %s)" % pluginVersion,3)

=head1 DESCRIPTION

C<SpadsPluginApi> is a Perl module implementing the plugin API for SPADS. This
API allows anyone to add new features as well as customize existing SPADS
features (such as balancing algorithms, battle status presentation, players
skills management, command aliases...).

This API relies on plugin callback functions (implemented by SPADS plugins),
which can in turn call plugin API functions (implemented by SPADS core) and
access shared SPADS data.

Plugins can be coded in Perl (since SPADS 0.11) or Python (since SPADS 0.12.29).

=head1 PYTHON SPECIFIC NOTES

=head2 How to read the documentation

This documentation was written when SPADS was only supporting plugins coded in
Perl, so types for function parameters and return values are described using
Perl terminology, with Perl sigils (C<%> for hash, C<@> for array, C<$>  for
scalars). Python plugins just need to ignore these sigils and use their
equivalent internal Python types instead (Python dictionaries instead of Perl
hashes, Python lists instead of Perl arrays, Python tuples instead of Perl
lists, Python None value instead of Perl undef value...).

In order to call functions from the plugin API, Python plugin modules must first
import the special C<perl> module, and then use the global variable of this
module named after the plugin name to call the functions (refer to the SYNOPSYS
for an example of a Python plugin named C<MyPlugin> calling the C<slog> API
function).

=head2 Perl strings conversions

SPADS uses the C<Inline::Python> Perl module to interface Perl code with Python
code. Unfortunately, some versions of this module don't auto-convert Perl
strings entirely when used with Python 3 (Python 2 is unaffected): depending on
the version of Python and the version of the C<Inline::Python> Perl module used
by your system, it is possible that the Python plugin callbacks receive Python
byte strings as parameters instead of normal Python strings. In order to
mitigate this problem, the plugin API offers both a way to detect from the
Python plugin code if current system is affected (by calling the C<get_flag>
function with parameter C<'use_byte_string'>), and a way to workaround the
problem by calling a dedicated C<fix_string> function which fixes the string
values if needed. For additional information regarding these Python specific
functions of the plugin API, refer to the L<API FUNCTIONS - Python specific|/"Python specific">
section. Python plugins can also choose to implement their own pure Python function which
fixes strings coming from SPADS if needed like this for example:

  def fix_spads_string(spads_string):
      if hasattr(spads_string,'decode'):
          return spads_string.decode('utf-8')
      return spads_string
  
  def fix_spads_strings(*spads_strings):
      fixed_strings=[]
      for spads_string in spads_strings:
          fixed_strings.append(fix_spads_string(spads_string))
      return fixed_strings

=head2 Windows limitations

On Windows systems, Perl emulates the C<fork> functionality using threads. As
the C<Inline::Python> Perl module used by SPADS to interface with Python code
isn't thread-safe, the fork functions of the plugin API (C<forkProcess> and
C<forkCall>) aren't available from Python plugins when running on a Windows
system. On Windows systems, using native Win32 processes for parallel processing
is recommended anyway. Plugins can check if the fork functions of the plugin API
are available by calling the C<get_flag> Python specific plugin API function
with parameter C<'can_fork'>, instead of checking by themselves if the current
system is Windows. Refer to the L<API FUNCTIONS - Python specific|/"Python specific">
section for more information regarding this function.

Automatic asynchronous socket management (C<addSocket> plugin API function) is
also unavailable for Python plugins on Windows systems (this is due to the file
descriptor numbers being thread-specific on Windows, preventing SPADS from
accessing sockets opened in Python interpreter scope). However, it is still
possible to manage asynchronous sockets manually, for example by hooking the
SPADS event loop (C<eventLoop> plugin callback) to perform non-blocking
C<select> with 0 timeout (refer to L<Python select documentation|https://docs.python.org/3/library/select.html#select.select>).
Plugins can check if the C<addSocket> function of the plugin API is available by
calling the C<get_flag> Python specific plugin API function with parameter
C<'can_add_socket'>, instead of checking by themselves if the current system is
Windows. Refer to the L<API FUNCTIONS - Python specific|/"Python specific">
section for more information regarding this function.

=head1 CALLBACK FUNCTIONS

The callback functions are called from SPADS core and implemented by SPADS
plugins. SPADS plugins are actually Perl or Python classes instanciated as
objects. So most callback functions are called as object methods and receive a
reference to the plugin object as first parameter. The exceptions are the
constructor (Perl: C<new> receives the class/plugin name as first parameter,
Python: C<__init__> receives the plugin object being created as first
parameter), and a few other callbacks which are called/checked before the plugin
object is actually created: C<getVersion> and C<getRequiredSpadsVersion>
(mandatory callbacks), C<getParams> and C<getDependencies> (optional callbacks).

=head2 Mandatory callbacks

To be valid, a SPADS plugin must implement at least these 3 callbacks:

=over 2

=item [Perl] C<new($pluginName,$context)> . . . . [Python] C<__init__(self,context)>

This is the plugin constructor, it is called when SPADS (re)loads the plugin.

The C<$context> parameter is a string which indicates in which context the
plugin constructor has been called: C<"autoload"> means the plugin is being
loaded automatically at startup, C<"load"> means the plugin is being loaded
manually using C<< !plugin <pluginName> load >> command, C<"reload"> means the
plugin is being reloaded manually using C<< !plugin <pluginName> reload >>
command.

=item C<getVersion($self)>

returns the plugin version number (example: C<"0.1">).

=item C<getRequiredSpadsVersion($pluginName)>

returns the required minimum SPADS version number (example: C<"0.11">).

=back

=head2 Configuration callback

SPADS plugins can use the core SPADS configuration system to manage their own
configuration parameters. This way, all configuration management tools in place
(parameter values checking, C<!reloadconf> etc.) can be reused by the plugins. To
do so, the plugin must implement following configuration callback:

=over 2

=item C<getParams($pluginName)>

This callback must return a reference to an array containing 2 elements. The
first element is a reference to a hash containing the global plugin settings
declarations, the second one is the same but for plugin preset settings
declarations. These hashes use setting names as keys, and references to array of
allowed types as values. The types must match the keys of C<%paramTypes> defined
in SpadsConf.pm.

Example of implementation in Perl:

  my %globalPluginParams = ( MyGlobalSetting1 => ['integer'],
                             MyGlobalSetting2 => ['ipAddr']);
  my %presetPluginParams = ( MyPresetSetting1 => ['readableDir','null'],
                             MyPresetSetting2 => ['bool'] );

  sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

Example of implementation in Python:

  globalPluginParams = { 'MyGlobalSetting1': ['integer'],
                         'MyGlobalSetting2': ['ipAddr'] }
  presetPluginParams = { 'MyPresetSetting1': ['readableDir','null'],
                         'MyPresetSetting2': ['bool'] };

  def getParams(pluginName):
      return [ globalPluginParams , presetPluginParams ]

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

=item C<getDependencies($pluginName)>

This callback must return the plugin dependencies (list of plugin names).

Example of implementation in Perl:

  sub getDependencies { return ('SpringForumInterface','MailAlerts'); }

Example of implementation in Python:

  def getDependencies(pluginName):
      return ('SpringForumInterface','MailAlerts')

=back

=head2 Event-based callbacks

Following callbacks are triggered by events from various sources (SPADS, Spring
lobby, Spring server...):

=over 2

=item C<onBattleClosed($self)>

This callback is called when the battle lobby of the autohost is closed.

=item C<onBattleOpened($self)>

This callback is called when the battle lobby of the autohost is opened.

=item C<onGameEnd($self,\%endGameData)>

This callback is called each time a game hosted by the autohost ends.

The C<\%endGameData> parameter is a reference to a hash containing all the data
stored by SPADS concerning the game that just ended. It is recommended to use a
data printing function (such as the C<Dumper> function from the standard
C<Data::Dumper> module included in Perl core) to check the content of this hash
for the desired data.

=item C<onJoinBattleRequest($self,$userName,$ipAddr)>

This callback is called each time a client requests to join the battle lobby
managed by the autohost.

C<$userName> is the name of the user requesting to join the battle

C<$ipAddr> is the IP address of the user requesting to join the battle

This callback must return:

C<0> if the user is allowed to join the battle

C<1> if the user isn't allowed to join the battle (without explicit reason)

C<< "<explicit reason string>" >> if the user isn't allowed to join the battle,
with explicit reason

=item C<onJoinedBattle($self,$userName)>

This callback is called each time a user joins the battle lobby of the autohost.

C<$userName> is the name of the user who just joined the battle lobby

=item C<onLeftBattle($self,$userName)>

This callback is called each time a user leaves the battle lobby of the autohost.

C<$userName> is the name of the user who just left the battle lobby

=item C<onLobbyConnected($self,$lobbyInterface)>

This callback is called each time the autohost successfully logged in on the
lobby server, after all login info has been received from lobby server (this
callback is called after the C<onLobbyLogin($lobbyInterface)> callback).

The C<$lobbyInterface> parameter is the instance of the
 L<SpringLobbyInterface|https://github.com/Yaribz/SpringLobbyInterface> module
used by SPADS.

=item C<onLobbyDisconnected($self)>

This callback is called each time the autohost is disconnected from the lobby
server.

=item C<onLobbyLogin($self,$lobbyInterface)>

This callback is called each time the autohost tries to login on the lobby
server, just after the LOGIN command has been sent to the lobby server (this
callback is called before the C<onLobbyConnected($lobbyInterface)> callback).

The C<$lobbyInterface> parameter is the instance of the
 L<SpringLobbyInterface|https://github.com/Yaribz/SpringLobbyInterface> module
used by SPADS.

=item C<onPresetApplied($self,$oldPresetName,$newPresetName)>

This callback is called each time a global preset is applied.

C<$oldPresetName> is the name of the previous global preset

C<$newPresetName> is the name of the new global preset

=item C<onPrivateMsg($self,$userName,$message)>

This callback is called each time the autohost receives a private message.

C<$userName> is the name of the user who sent a private message to the autohost

C<$message> is the private message received by the autohost

This callback must return:

C<0> if the message can be processed by other plugins and SPADS core

C<1> if the message must not be processed by other plugins and SPADS core (this
prevents logging)

=item C<onReloadConf($self,$keepSettings)>

This callback is called each time the SPADS configuration is reloaded.

C<$keepSettings> is a boolean parameter indicating if current settings must be
kept.

This callback must return:

C<0> if an error occured while reloading the plugin configuration

C<1> if the plugin configuration has been reloaded correctly

=item C<onSettingChange($self,$settingName,$oldValue,$newValue)>

This callback is called each time a setting of the plugin configuration is
changed (using C<< !plugin <pluginName> set ... >> command).

C<$settingName> is the name of the updated setting

C<$oldValue> is the previous value of the setting

C<$newValue> is the new value of the setting

=item C<onSpringStart($self,$springPid)>

This callback is called each time a Spring process is launched to host a game.

C<$springPid> is the PID of the Spring process that has just been launched.

=item C<onSpringStop($self,$springPid)>

This callback is called each time the Spring process ends.

C<$springPid> is the PID of the Spring process that just ended.

=item C<onUnload($self,$context)>

This callback is called when the plugin is unloaded. If the plugin has added
handlers for SPADS command, lobby commands, or Spring commands, then they must
be removed here. If the plugin has added timers or forked process callbacks,
they should also be removed here. If the plugin handles persistent data, then
these data must be serialized and written to persistent storage here.

The C<$context> parameter is a string which indicates in which context the
callback has been called: C<"exiting"> means the plugin is being unloaded
because SPADS is exiting, C<"restarting"> means the plugin is being unloaded
because SPADS is restarting, C<"unload"> means the plugin is being unloaded
manually using C<< !plugin <pluginName> unload >> command, C<"reload"> means the
plugin is being reloaded manually using C<< !plugin <pluginName> reload >>
command.

=item C<onVoteRequest($self,$source,$user,\@command,\%remainingVoters)>

This callback is called each time a vote is requested by a player.

C<$source> indicates the way the vote has been requested (C<"pv">: private lobby
message, C<"battle">: battle lobby message, C<"chan">: master lobby channel
message, C<"game">: in game message)

C<$user> is the name of the user requesting the vote

C<\@command> is an array reference containing the command for which a vote is
requested

C<\%remainingVoters> is a reference to a hash containing the players allowed to
vote. This hash is indexed by player names. Perl plugins can filter these
players by removing the corresponding entries from the hash directly, but Python
plugins must use the alternate method based on the return value described below.

This callback must return C<0> to prevent the vote call from happening, or C<1>
to allow it without changing the remaining voters list, or an array reference
containing the player names that should be removed from the remaining voters
list.

=item C<onVoteStart($self,$user,\@command)>

This callback is called each time a new vote poll is started.

C<$user> is the name of the user who started the vote poll

C<\@command> is an array reference containing the command for which a vote is
started

=item C<onVoteStop($self,$voteResult)>

This callback is called each time a vote poll is stoped.

C<$voteResult> indicates the result of the vote: C<-1> (vote failed), C<0> (vote
cancelled), C<1> (vote passed)

=item C<postSpadsCommand($self,$command,$source,$user,\@params,$commandResult)>

This callback is called each time a SPADS command has been called.

C<$command> is the name of the command (without the parameters)

C<$source> indicates the way the command has been called (C<"pv">: private lobby
message, C<"battle">: battle lobby message, C<"chan">: master lobby channel
message, C<"game">: in game message)

C<$user> is the name of the user who called the command

C<\@params> is a reference to an array containing the parameters of the command

C<$commandResult> indicates the result of the command (if it is defined and set
to C<0> then the command failed, in all other cases the command succeeded)

=item C<preGameCheck($self,$force,$checkOnly,$automatic)>

This callback is called each time a game is going to be launched, to allow
plugins to perform pre-game checks and prevent the game from starting if needed.

C<$force> is C<1> if the game is being launched using C<!forceStart> command,
C<0> else

C<$checkOnly> is C<1> if the callback is being called in the context of a vote
call, C<0> else

C<$automatic> is C<1> if the game is being launched automatically through
autoStart functionality, C<0> else

The return value must be the reason for preventing the game from starting (for
example C<"too many players for current map">), or C<1> if no reason can be given,
or undef to allow the game to start.

=item C<preSpadsCommand($self,$command,$source,$user,\@params)>

This callback is called each time a SPADS command is called, just before it is
actually executed.

C<$command> is the name of the command (without the parameters)

C<$source> indicates the way the command has been called (C<"pv">: private lobby
message, C<"battle">: battle lobby message, C<"chan">: master lobby channel
message, C<"game">: in game message)

C<$user> is the name of the user who called the command

C<\@params> is a reference to an array containing the parameters of the command

This callback must return C<0> to prevent the command from being processed by
other plugins and SPADS core, or C<1> to allow it.

=back

=head2 Customization callbacks

Following callbacks are called by SPADS during specific operations to allow
plugins to customize features (more callbacks can be added on request):

=over 2

=item C<addStartScriptTags($self,\%additionalData)>

This callback is called when a Spring start script is generated, just before
launching the game. It allows plugins to declare additional scrip tags which
will be written in the start script.

C<\%additionalData> is a reference to a hash which must be updated by Perl
plugins by adding the desired keys/values. For example a Perl plugin can add a
modoption named C<hiddenoption> with value C<test> like this:
C<$additionalData{"game/modoptions/hiddenoption"}="test">. For tags to be added
in player sections, the special key C<playerData> must be used. This special key
must point to a hash associating each account ID to a hash containing the tags
to add in the corresponding player section (subsections can be created by using
nested hashes). For tags to be added in AI bot sections, the special key
C<aiData> must be used. This special key must point to a hash associating each
AI bot name to a hash containing the tags to add in the corresponding AI bot
section (subsections can be created by using nested hashes).

Note for Python plugins: As Python plugins cannot modify the data structures
passed as parameters to the callbacks, an alternate way to implement this
callback is offered. Instead of modifying the C<additionnalData> dictionary
directly, the callback can return a new dictionary containing the entries which
must be added. For example a Python plugin can add a tag named C<CommanderLevel>
set to value C<8> in the player section of the player whose account ID is
C<1234> like this: C<return {'playerData': { '1234': { 'CommanderLevel': 8 } } }>

=item C<balanceBattle($self,\%players,\%bots,$clanMode,$nbTeams,$teamSize)>

This callback is called each time SPADS needs to balance a battle and evaluate
the resulting balance quality. It allows plugins to replace the built-in balance
algorithm.

C<\%players> is a reference to a hash containing the players in the battle
lobby. This hash is indexed by player names, and the values are references to a
hash containing player data. For balancing, you should only need to access the
players skill as follows: C<< $players->{<playerName>}->{skill} >>

C<\%bots> is a reference to a hash containing the bots in the battle lobby. This
hash has the exact same structure as C<\%players>.

C<$clanMode> is the current clan mode which must be applied to the balance. Clan
modes are specified L<here|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#set:clanMode>.
C<< <maxUnbalance> >> thresholds are automatically managed by SPADS, plugins
don't need to handle them. So basically, plugins only need to check if C<tag>
and/or C<pref> clan modes are enabled and apply them to their balance algorithm.

C<$nbTeams> and C<$teamSize> are the target battle structue computed by SPADS.
The number of entities to balance is the number of entries in C<\%players> +
number of entries in C<\%bots>. The number of entities to balance is always
C<< > $nbTeams*($teamSize-1) >>, and C<< <= $nbTeams*$teamSize >>.

If the plugin is unable to balance the battle, it must not update C<\%players>
and C<\%bots>. The callback must return undef or a negative value so that SPADS
knows it has to use another plugin or the internal balance algorithm instead.

If the plugin is able to balance the battle, it can use two methods to transmit
the desired balance to SPADS (Python plugins can only use the second method):

The first method consists in updating directly the C<\%players> and C<\%bots>
hash references with the team and id information. Assigned player teams must be
written in C<< $players->{<playerName>}->{battleStatus}->{team} >>, and assigned
player ids must be written in C<< $players->{<playerName>}->{battleStatus}->{id} >>.
The C<\%bots> hash reference works the same way. The return value is the
unbalance indicator, defined as follows:
C<standardDeviationOfTeamSkills * 100 / averageTeamSkill>.

The second method consists in returning an array reference containing the
balance information instead of directly editing the C<\%players> and C<\%bots>
parameters. The returned array must contain 3 items: the unbalance indicator (as
defined in first method description above), the player assignation hash and the
bot assignation hash. The player assignation hash and the bot assignation hash
have exactly the same structure: the keys are the player/bot names and the
values are hashes containing C<team> and C<id> items with the corresponding
values for the  balanced battle.

=item C<canBalanceNow($self)>

This callback allows plugins to delay the battle balance operation. It is called
each time a battle balance operation is required (either automatic if
autoBalance is enabled, either manual if C<!balance> command is called). If the
plugin is ready for balance, it must return C<1>. Else, it can delay the
operation by returning C<0> (the balance algorithm won't be launched as long as
the plugin didn't return C<1>).

=item C<changeUserAccessLevel($self,$userName,\%userData,$isAuthenticated,$currentAccessLevel)>

This callback is called by SPADS each time it needs to get the access level of a
user. It allows plugins to overwrite this level. Don't call the
C<getUserAccessLevel($user)> function from this callback, or the program will be
locked in recursive loop! (and it would give you the same value as
C<$currentAccessLevel> anyway).

C<\%userData> is a reference to a hash containing the lobby data of the user

C<$isAuthenticated> indicates if the user has been authenticated (0: lobby
server in LAN mode and not authenticated at autohost level, 1: authenticated by
lobby server only, 2: authenticated by autohost)

The callback must return the new access level value if changed, or undef if not
changed.

=item C<filterRotationMaps($self,\@rotationMaps)>

This callback is called by SPADS each time a new map must be picked up for
rotation. It allows plugins to remove some maps from the rotation maps list
just before the new map is picked up.

C<\@rotationMaps> is a reference to an array containing the names of the maps
currently allowed for rotation.

The callback must return a reference to a new array containing the filtered map
names.

=item C<fixColors($self,\%players,\%bots,\%battleStructure)>

This callback is called each time SPADS needs to fix the teams colors. It allows
plugins to replace the built-in color fixing algorithm.

C<\%players> is a reference to a hash containing the players currently in the
battle lobby. This hash is indexed by player names, and the values are
references to hashes containing following player data: C<team> (team number),
C<id> (id number) and C<color> (current color configured in lobby, i.e. a hash
containing keys C<"red">, C<"green">, C<"blue"> and whose values are numbers
between 0 and 255 included).

C<\%bots> is a reference to a hash containing the bots currently in the battle
lobby. This hash has the exact same structure as C<\%players>.

C<\%battleStructure> is a reference to a hash containing data concerning the
battle structure. This parameter is provided to plugins for ease of use but
actually these data are redundant with the data already provided in the two
previous parameters (the C<%players> and C<%bots> hashes), they are just
organized in a different way. The C<%battleStructure> hash is indexed by team
numbers. For each team number, the associated value is a reference to a hash
indexed by the ID numbers contained in the team. For each ID number, the
associated value is a reference to a hash containing the two following keys:
C<players> (the associated value is a reference to an array containing the names
of the players belonging to this ID) and C<bots> (the associated value is a
reference to an array containing the names of the AI bots belonging to this ID).

If the plugin is unable to fix colors, then it must return C<undef> so that
SPADS knows it has to use another plugin or the internal color fixing algorithm
instead.

If the plugin is able to fix the players and AI bots colors, then it must return
a reference to a hash containing all colors assignations, indexed by ID numbers.
The keys must be the ID numbers and the values are references to hash whose keys
are C<"red">, C<"green"> and C<"blue"> and values are the corresponding RGB
values (between 0 and 255 included) of the color assigned to the ID.

=item C<setMapStartBoxes($self,\@boxes,$mapName,$nbTeams,$nbExtraBox)>

This callback allows plugins to set map start boxes (for "Choose in game" start
position type).

C<\@boxes> is a reference to an array containing the start boxes definitions.
A start box definition is a string containing the box coordinates separated by
spaces, in following order: left, top, right, bottom (0,0 is top left corner
and 200,200 is bottom right corner). If the array already contains box
definitions, it means SPADS already knows boxes for this map.

C<$mapName> is the name of the map for which start boxes are requested

C<$nbTeams> is the current number of teams configured (at least this number of
start boxes must be provided)

C<$nbExtraBox> is the number of extra box required. Usually this is 0, unless a
special game mode is enabled such as King Of The Hill.

If the plugin isn't able or doesn't need to provide/override start boxes, it must
not update the C<\@boxes> array. It must return C<0> so that SPADS knows it has
to check other plugins for possible start boxes.

If the plugin needs to provide/override start boxes, it can use two methods to
transmit the start box definitions (Python plugins can only use the second
method):

The first method consists in replacing the C<\@boxes> array content directly
with the new desired start box definitions. If other plugins should be allowed
to replace the start box definitions, the callback must return C<0>, else it
must return C<1>.

The second method consists in returning an array reference containing the new
start box definitions instead of directly updating the C<\@boxes> parameter. The
returned array must contain 2 items: the normal return value as first item (C<0>
to allow other plugins to replace the start boxes, or C<1> else), and an array
reference containg the new start box definitions as second item.

=item C<setVoteMsg($self,$reqYesVotes,$maxReqYesVotes,$reqNoVotes,$maxReqNoVotes,$nbRequiredManualVotes)>

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

=item C<updateCmdAliases($self,\%aliases)>

This callback allows plugins to add new SPADS command aliases by adding new
entries in the C<\%aliases> hash reference. This hash is indexed by alias names
and the values are references to an array containing the associated command. For
example, a Perl plugin can add an alias "C<!cvmap ...>" for "C<!callVote map ...>"
like this: C<< $aliases->{cvmap}=['callVote','map'] >>

C<< "%<N>%" >> can be used as placeholders for original alias command
parameters. For example, a Perl plugin can add an alias "C<< !iprank <playerName> >>"
for "C<< !chrank <playerName> ip >>" like this:
C<< $aliases->{iprank}=['chrank','%1%','ip'] >>

Note for Python plugins: As Python plugins cannot modify the data structures
passed as parameters to the callbacks, an alternate way to implement this
callback is offered. Instead of modifying the C<aliases> dictionary directly,
the callback can return a new dictionary containing the alias entries which must
be added.

=item C<updatePlayerSkill($self,\%playerSkill,$accountId,$modName,$gameType)>

This callback is called by SPADS each time it needs to get or update the skill
of a player (on battle join, on game type change...). This allows plugins to
replace the built-in skill estimations (rank, TrueSkill...) with custom skill
estimations (ELO, Glicko ...).

C<\%playerSkill> is a reference to a hash containing the skill data of the
player. A Perl plugin can update the C<skill> entry as follows:
C<< $playerSkill->{skill}=<skillValue> >>

C<$accountId> is the account ID of the player for whom skill value is requested.

C<$modName> is the currently hosted MOD (example: C<"Balanced Annihilation
V7.72">)

C<$gameType> is the current game type (C<"Duel">, C<"Team">, C<"FFA"> or
C<"TeamFFA">)

The return value is the skill update status: C<0> (skill not updated by the
plugin), C<1> (skill updated by the plugin), C<2> (skill updated by the plugin
in degraded mode)

Note for Python plugins: As Python plugins cannot modify the data structures
passed as parameters to the callbacks, an alternate way to implement this
callback is offered. Instead of modifying the C<playerSkill> dictionary
directly, the callback can return a list contaning the normal return value as
first item (described above), and the new skill value as second item.

=item C<updateGameStatusInfo($self,\%playerStatus,$accessLevel)>

This callback is called by SPADS for each player in game when the C<!status>
command is called, to allow plugins to update and/or add data which will be
presented to the user issuing the command.

C<\%playerStatus> is a reference to the hash containing current player status
data. A Perl plugin can update existing data or add new data in this hash. For
example: C<< $playerStatus->{myPluginData}=<myPluginValue> >>

C<$accessLevel> is the autohost access level of the user issuing the C<!status>
command.

The return value must be a reference to an array containing the names of the
status information updated or added by the plugin.

Note for Python plugins: As Python plugins cannot modify the data structures
passed as parameters to the callbacks, an alternate way to implement this
callback is offered. Instead of modifying the C<playerStatus> dictionary
directly, the callback can return a new dictionary containing the data to
add/modify in the C<playerStatus> dictionary.

=item C<updateStatusInfo($self,\%playerStatus,$accountId,$modName,$gameType,$accessLevel)>

This callback is called by SPADS for each player in the battle lobby when the
C<!status> command is called, to allow plugins to update and/or add data which
will be presented to the user issuing the command.

C<\%playerStatus> is a reference to the hash containing current player status
data. A Perl plugin can update existing data or add new data in this hash. For
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

Note for Python plugins: As Python plugins cannot modify the data structures
passed as parameters to the callbacks, an alternate way to implement this
callback is offered. Instead of modifying the C<playerStatus> dictionary
directly, the callback can return a new dictionary containing the data to
add/modify in the C<playerStatus> dictionary.

=back

=head2 Event loop callback

SPADS uses the asynchronous programming paradigm, so it is based on a main event
loop. The following callback is called during each iteration of this event loop:

=over 2

=item C<eventLoop($self)>

Warning: this callback is called very frequently (during each iteration of SPADS
main event loop), so performing complex operations here can be very intensive on
the CPU. It is recommended to use timers (C<addTimer>/C<removeTimer> functions)
instead for all time related operations (timeouts, scheduled actions, regular
serialization of persistent data to avoid data loss...). This callback shouldn't
be blocking, otherwise SPADS may become unstable.

=back

=head1 API FUNCTIONS

The API functions are implemented by SPADS core and can be called by SPADS
plugins (directly from Perl plugins, or via C<spads.[...]> from Python plugins).

=head2 Accessors

=over 2

=item C<getConfMacros()>

This accessor returns a reference to the hash containing the configuration
macros used to (re)start SPADS.

=item C<getCurrentVote()>

This accessor returns a reference to a hash containing information regarding
votes.

If there is no vote in progress and the last vote succeeded, then the returned
hash is always empty.

If there is no vote in progress and the last vote failed, then the content of
the returned hash depends on the delay since the last vote ended. If the delay
is greater than the
L<reCallVoteDelay|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#global:reCallVoteDelay>,
then the returned hash is empty, else it contains the two following keys:

=over 3

=item * C<user>: the name of the user who started the last vote

=item * C<expireTime>: the time when the last vote failed (in UNIX timestamp
format)

=back

If there is a vote in progress, then the returned hash contains following keys:

=over 3

=item * C<user>: the name of the user who started the vote

=item * C<expireTime>: the time when the vote will timeout, in UNIX timestamp
format

=item * C<awayVoteTime>: the time when the automatic votes for away users (see
L<voteMode|http://planetspads.free.fr/spads/doc/spadsDoc_Preferences.html#pset:voteMode>
preference) will be taken into account, in UNIX timestamp format

=item * C<source>: the source of the message which started the vote (either
C<"pv">, C<"chan">, C<"game"> or C<"battle">)

=item * C<command>: a reference to an array containg the command being voted
(the first element is the command name, the other elements are the command
parameters)

=item * C<remainingVoters>: a reference to a hash whose keys are the names of
the players allowed to vote who didn't vote yet

=item * C<yesCount>: current number of "yes" votes

=item * C<noCount>: current number of "no" votes

=item * C<blankCount>: current number of "blank" votes

=item * C<awayVoters>: a reference to a hash whose keys are the names of the
players who auto-voted blank due to being away (see 
L<voteMode|http://planetspads.free.fr/spads/doc/spadsDoc_Preferences.html#pset:voteMode>
preference)

=item * C<manualVoters>: a reference to a hash whose keys are the names of the
players who voted manually, and the values are the actual votes (C<"yes">,
C<"no"> or C<"blank">)

=back

Note: An easy way to check if a vote is currently in progress consists in
calling C<getCurrentVote()> and checking if the returned hash contains the
C<command> key. If the hash contains the C<command> key then it means a vote is
in progress, else it means no vote is in progress.

=item C<getLobbyInterface()>

This accessor returns the instance of the
L<SpringLobbyInterface|https://github.com/Yaribz/SpringLobbyInterface> module
used by SPADS.

Following methods, called on the C<SpringLobbyInterface> object, can be useful
to plugins for accessing various lobby data:

=over 3

=item * - C<getUsers()>

This method returns a reference to a hash containing the data regarding all the
online users. The hash is indexed by player names and the values are references
to hashes with following content:

=over 4

=item * C<accountId>: the lobby account ID of the user

=item * C<country>: the country code of the user (2 characters)

=item * C<ip>: the IP address of the user, if known (C<undef> else)

=item * C<lobbyClient>: the name of the lobby client software used by the user

=item * C<status>: the lobby status of the user, which is itself a reference to
another hash, containing following content: C<access> (C<0>: normal user, C<1>:
moderator), C<away> (C<0>: active, C<1>: away), C<bot> (C<0>: human, C<1>: bot),
C<inGame> (C<0>: out of game, C<1>: in game), C<rank> (integer between 0 and 7
included)

=back

Note 1: this method performs a deep copy of the data to prevent external code
from corrupting internal data. However it is also possible to read the same data
directly without triggering a deep copy by accessing the C<users> field of the
C<SpringLobbyInterface> object.

Note 2: if you need to retrieve users indexed by lobby account IDs instead of
names, you can access the C<accounts> field of the C<SpringLobbyInterface>
object. It contains a reference to a hash whose keys are the lobby account IDs
and values are the lobby user names.

=item * - C<getChannels()>

This method returns a reference to a hash containing the data regarding all the
lobby channels joined by SPADS. The hash is indexed by channel names and the
values are references to hashes with following content:

=over 4

=item * C<topic>: a reference to a hash with following content: C<author> (the
name of the user who set the topic), C<content> (the topic content)

=item * C<users>: a reference to a hash whose keys are the names of the users in
the lobby channel

=back

Note: this method performs a deep copy of the data to prevent external code from
corrupting internal data. However it is also possible to read the same data
directly without triggering a deep copy by accessing the C<channels> field of
the C<SpringLobbyInterface> object.

=item * - C<getBattles()>

This method returns a reference to a hash containing the data regarding all the
battle lobbies currently hosted on the lobby server. The hash is indexed by
battle ID and the values are references to hashes with following content:

=over 4

=item * C<engineName>: the name of the engine used by the battle lobby (usually
C<"spring">)

=item * C<engineVersion>: the version of the engine used by the battle lobby
(example: C<"105.0">)

=item * C<founder>: the name of the user who created the battle lobby

=item * C<ip>: the IP address used by the battle lobby for game hosting

=item * C<locked>: the lock status of the battle lobby (C<0>: unlocked, C<1>:
locked)

=item * C<map>: the map currently selected in the battle lobby

=item * C<mapHash>: the hash of the map currently selected in the battle lobby
(computed by the unitsync library)

=item * C<maxPlayers>: the battle lobby size (maximum number of players who can
be in the battle lobby, ignoring spectators)

=item * C<mod>: the mod (game name) used by the battle lobby

=item * C<natType>: the type of NAT traversal method used by the host (C<0>:
none, C<1>: hole punching, C<2>: fixed source ports)

=item * C<nbSpec>: the number of spectators currently in the battle lobby

=item * C<passworded>: the password status of the battle lobby (C<0>: not
password protected, C<1>: password protected)

=item * C<port>: the port used by the battle lobby for game hosting

=item * C<rank>: the minimum rank limit used by the battle lobby

=item * C<title>: the description of the battle lobby

=item * C<userList>: a reference to an array containing the names of the users
currently in the battle lobby

=back

Note: this method performs a deep copy of the data to prevent external code from
corrupting internal data. However it is also possible to read the same data
directly without triggering a deep copy by accessing the C<battles> field of the
C<SpringLobbyInterface> object.

=item * - C<getBattle()>

This method returns a reference to a hash containing the data regarding the
battle lobby currently hosted by SPADS. This hash has following content:

=over 4

=item * C<battleId>: the battle ID of the battle lobby

=item * C<botList>: a reference to an array containing the names of the AI bots
currently in the battle lobby

=item * C<bots>: a reference to a hash containing the data regarding the AI bots
currently in the battle lobby. This hash is indexed by AI bot names and the
values are references to hashes with following content: C<aiDll> (details
regarding the AI bot, usually the AI name and version, or the AI DLL),
C<battleStatus> (data representing the status of the AI bot in the battle lobby,
see BATTLESTATUS hash description below), C<color> (data specifying the team
color of the AI bot using RGB model, see COLOR hash description below), C<owner>
(name of the user hosting the AI bot)

=item * C<disabledUnits>: a reference to an array containing the names of the
game units currently disabled

=item * C<modHash>: the hash of the mod (game) used by the battle lobby

=item * C<password>: the password used to protect the battle lobby (C<"*"> if no
password is set)

=item * C<scriptTags>: a reference to a hash containing all the script tags (in
lower case) and their associated values (used to generate the start script)

=item * C<startRects>: a reference to a hash containing the start box
definitions. This hash is indexed by box numbers and the values are references
to hashes containing the box coordinates (C<top>, C<left>, C<bottom> and
C<right>) in the C<0-200> range (C<0,0> is the top left corner and C<200,200> is
the bottom right corner).

=item * C<users>: a reference to a hash containing the data regarding the users
currently in the battle lobby. This hash is indexed by user names and the values
are references to hashes with following content: C<battleStatus> (data
representing the status of the player in the battle lobby, see BATTLESTATUS hash
description below), C<color> (data specifying the team color of the player using
RGB model, see COLOR hash description below), C<ip> (IP address of the user if
known, C<undef> else), C<port> (client port of the user if known, C<undef>
else), and optionally C<scriptPass> if the client provided a script password
when joining the battle lobby.

=back

BATTLESTATUS hash description:

=over 4

=item * C<bonus>: resource bonus value (integer in C<0-100> range, C<0> means no
bonus)

=item * C<id>: player team number (starting at C<0>)

=item * C<mode>: player/spectator mode (C<0>: spectator, C<1>: player)

=item * C<ready>: ready state (C<0>: not ready, C<1>: ready)

=item * C<side>: game faction number

=item * C<sync>: synchronization status (C<0>: unsynchronized, C<1>:
synchronized)

=item * C<team> (ally team number, starting at C<0>)

=back

COLOR hash description:

=over 4

=item * C<red>: red component intensity (integer in C<0-255> range)

=item * C<green>: green component intensity (integer in C<0-255> range)

=item * C<blue>: blue component intensity (integer in C<0-255> range)

=back

Note: this method performs a deep copy of the data to prevent external code from
corrupting internal data. However it is also possible to read the same data
directly without triggering a deep copy by accessing the C<battle> field of the
C<SpringLobbyInterface> object.

=back

=item C<getLobbyState()>

This accessor returns an integer describing current lobby state (C<0>: not
connected, C<1>: connecting, C<2>: connected, C<3>: just logged in, C<4>:
initial lobby data received, C<5>: opening battle, C<6>: battle opened)

=item C<getPluginList()>

This accessor returns a reference to an array containing the names of the
plugins currently loaded (in load order).

=item C<getRunningBattle()>

This accessor returns a reference to a hash representing the state of the battle
lobby hosted by SPADS when the game currently running was launched. This is
useful to find the actual characteristics of the currently running game (battle
structure, settings...), because things might have changed in the battle lobby
since the game started (players joined/left, map changed...) so the current
battle lobby data aren't necessarily consistent with the game currently running.

If no game is in progress, this hash is empty.

If a game is in progress, the hash contains the same data as the data returned
by the C<getBattle()> and C<getBattles()> methods of the C<SpringLobbyInterface>
object (see C<getLobbyInterface()> accessor) when the game was launched.
Concerning the C<getBattles()> data, only the data related to the battle lobby
hosted by SPADS are included in the hash.

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

=item C<addLobbyCommandHandler(\%handlers,$priority=caller(),$isPreCallback)>

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

C<$isPreCallback> specifies whether the command handlers must be called before
or after the lobby interface module handlers. If this parameter is set to a true
value, the command handlers will be called before the lobby interface module
handlers. If this parameter is not provided or set to a false value, the command
handlers will be called after the lobby interface module handlers.

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
parameters. Refer to L<Spring autohost protocol specifications
(from source comments)|https://raw.github.com/spring/spring/master/rts/Net/AutohostInterface.cpp>
for more information.

C<$priority> is the priority of the handlers. Lowest priority number actually
means higher priority. If not provided, the plugin name is used as priority,
which means it is executed after handlers having priority < 1000, and before
handlers having priority > 1000. Usually you don't need to provide priority,
unless you use data managed by other handlers.

=item C<removeLobbyCommandHandler(\@commands,$priority=caller(),$isPreCallback)>

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

C<$isPreCallback> specifies the type of command handlers to remove (must match
the value used for the C<addLobbyCommandHandler> function call for these
handlers)

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
used as priority. Usually you don't need to provide priority, unless you use
data managed by other handlers.

=back

=head2 SPADS operations

=over 2

=item C<applyPreset($presetName)>

=item C<cancelCloseBattle()>

=item C<cancelQuit($reason)>

=item C<closeBattle($reason,$silentMode=0)>

This function makes SPADS close current battle lobby.

The C<$reason> parameter must be a string containing the reason for closing the
battle lobby.

The C<$silentMode> parameter is an optional boolean parameter specifying if the
broadcast message (which is normally sent when the battle lobby is closed) must
be prevented.

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

=item C<updateSetting($type,$name,$value)>

This function updates current SPADS configuration in memory by changing the
value of a setting and applying it immediatly. This function does not modify
configuration files on disk. The new value provided by the plugin is not
checked: the plugin is reponsible for providing only correct values.

C<$type> is the type of setting to update (C<"set"> for preset setting,
C<"hSet"> for hosting setting, or C<"bSet"> for battle setting)

C<$name> is the name of the setting to update

C<$value> is the new value of the setting

=back

=head2 AutoHost messaging system

=over 2

=item C<answer($message)>

=item C<broadcastMsg($message)>

=item C<invalidSyntax($user,$lowerCaseCommand,$cause='')>

=item C<sayBattle($message)>

=item C<sayBattleAndGame($message)>

=item C<sayBattleUser($user,$message)>

=item C<sayChan($channel,$message)>

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

=item C<createDetachedProcess($applicationPath,\@commandParams,$workingDirectory,$createNewConsole)>

This function allows plugins to create a new detached/daemon process, which can
keep running even if the main SPADS process exits. It returns C<1> if the new
process has correctly been created, C<0> else.

C<$applicationPath> is the absolute path of the application that will be
executed in the detached process.

C<\@commandParams> is a reference to an array containing the parameters passed
to the application.

C<$workingDirectory> is the working directory for the detached process.

C<$createNewConsole> indicates if a console must be created for the detached
process: C<0> means no console is created for the process (daemon mode) C<1>
means a new console will be created for the detached process (this mode is only
available on Windows system)

=item C<forkProcess(\&processFunction,\&endProcessCallback,$preventQueuing=1)>

This function allows plugins to fork a process from main SPADS process, for
parallel processing. In scalar context it returns the PID of the forked process
on success, C<-1> if the fork request has been queued, or C<0> if the fork
request failed. In list context it returns the PID as first parameter and a
handle as second parameter. This handle can be passed as parameter to the
C<removeProcessCallback> function to remove the C<endProcessCallback> callback.

Note: this function cannot be used by Python plugins on Windows system (refer to
section L<PYTHON SPECIFIC NOTES - Windows limitations|/"Windows limitations">
for details).

C<\&processFunction> is a reference to a function containing the code to be
executed in the forked process (no parameter is passed to this function). This
function can call C<exit> to end the forked process with a specific exit code.
If it returns without calling exit, then the exit code C<0> will be used.

C<\&endProcessCallback> is a reference to a function containing the code to be
executed in main SPADS process, once the forked process exited. Following
parameters are passed to this function: C<$exitCode> (exit code of the forked
process), C<$signalNb> (signal number responsible for forked process termination
if any), C<$hasCoreDump> (boolean flag indicating if a core dump occured in the
forked process), C<$pid> (PID of the forked process that just exited).

C<$preventQueuing> is an optional boolean parameter (default value: 1)
indicating if the fork request must not be queued (i.e., the fork request will
fail instead of being queued if too many forked processes are already running)

=item C<forkCall(\&processFunction,\&endProcessCallback,$preventQueuing=0)>

This function allows plugins to call a function asynchronously and retrieve the
data returned by this function (this is done internally by forking a process to
execute the function and use a socketpair to transmit the result back to the
parent process). In scalar context it returns the PID of the forked process on
success, C<-1> if the fork request has been queued, or C<0> on error. In list
context it returns the PID as first parameter and a handle as second parameter.
This handle can be passed as parameter to the C<removeProcessCallback> function
to remove the C<endProcessCallback> callback.

Note: this function cannot be used by Python plugins on Windows system (refer to
section L<PYTHON SPECIFIC NOTES - Windows limitations|/"Windows limitations">
for details).

C<\&processFunction> is a reference to a function containing the code to be
executed in the forked process (no parameter is passed to this function). This
function must not call C<exit>, it should use C<return> instead to return
values (scalars, arrays, hashes...) that will be passed to the callback.

C<\&endProcessCallback> is a reference to a function containing the code to be
executed in main SPADS process, once the forked function call
(C<\&processFunction>) returned. The values returned by the forked function call
will be passed as parameters to this callback.

C<$preventQueuing> is an optional boolean parameter (default value: 0)
indicating if the fork request must not be queued (i.e., the fork request will
fail instead of being queued if too many forked processes are already running)

=item C<removeProcessCallback($processHandle)>

This function can be used by plugins to remove the callbacks on forked processes
added beforehand with the C<forkProcess> and C<forkCall> functions, if the 
callback hasn't been called yet (i.e. the corresponding forked process didn't
exit yet). It returns C<1> if the callback could be removed, C<0> else.

C<$processHandle> is an internal process handle, returned as second return value
by the C<forkProcess> and C<forkCall> functions.

=back

=head2 Timers management

=over 2

=item C<addTimer($name,$delay,$interval,\&callback)>

This function allows plugins to add timed events (timers) in order to delay
and/or repeat code execution. It returns C<1> if the timer has correctly been
added, C<0> else.

C<$name> is a unique name given by the plugin for this timer.

C<$delay> is the delay in seconds before executing the C<\&callback> function.

C<$interval> is the interval in seconds between each execution of the
C<\&callback> function. If this value is set to 0, the C<\&callback> function
will be executed only once.

C<\&callback> is a reference to a function containing the code to be executed
when the timed event occurs. This callback must not be blocking, otherwise SPADS
may become unstable.

=item C<removeTimer($name)>

This function must be used by plugins to remove timed events (timers) added
previously with the C<addTimer> function. It returns C<1> if the timer could be
removed, C<0> else. Note: Non-repeating timers (i.e. having null interval value)
are automatically removed once they are triggered. 

C<$name> is the unique timer name given by the plugin when the timer was added
using the C<addTimer> function.

=back

=head2 Sockets management

=over 2

=item C<addSocket(\$socketObject,\&readCallback)>

This function allows plugins to add sockets to SPADS asynchronous network
system. It returns C<1> if the socket has correctly been added, C<0> else.

Note: this function cannot be used by Python plugins on Windows system (refer to
section L<PYTHON SPECIFIC NOTES - Windows limitations|/"Windows limitations">
for details).

C<\$socketObject> is a reference to a socket object created by the plugin

C<\&readCallback> is a reference to a plugin function containing the code to
read the data received on the socket. This function will be called automatically
every time data are received on the socket, with the socket object as unique
parameter. It must not block, and only unbuffered functions must be used to read
data from the socket (C<sysread()> or C<recv()> for example).

=item C<removeSocket(\$socketObject)>

This function allows plugins to remove sockets from SPADS asynchronous network
system. It returns C<1> if the socket has correctly been removed, C<0> else.

C<\$socketObject> is a reference to a socket object previously added by the
plugin

=back

=head2 Python specific

=over 2

=item C<fix_string(spads_string[,...])>

This function allows Python plugins to automatically convert byte strings to
normal strings if needed. The function takes any number of byte strings or
normal strings as parameters, and returns them converted to normal strings if
needed (parameters which are already normal strings are returned without any
modification). Refer to section L<PYTHON SPECIFIC NOTES - Perl strings conversions|/"Perl strings conversions">
for the use case of this function. Here is an example of usage:

  import perl
  spads=perl.ExamplePlugin
  
  [...]
  
  class ExamplePlugin:

  [...]
  
      def onPrivateMsg(self,userName,message):
          (userName,message)=spads.fix_string(userName,message)

  [...]
  
  def hMyCommand(source,user,params,checkOnly):
      user=spads.fix_string(user)
      for i in range(len(params)):
          params[i]=spads.fix_string(params[i])

=item C<get_flag(flag_name)>

This function allows Python plugins to retrieve indicators (boolean flags)
regarding the behavior of the plugin API and the availability of
functionalities on current system.

Currently 3 flags are supported:

=over 3

=item * C<can_add_socket> : indicates if the C<addSocket> function of the plugin API is available from Python plugin on this system

=item * C<can_fork> : indicates if the fork functions of the plugin API (C<forkProcess> and C<forkCall>) are available from Python plugins on this system

=item * C<use_byte_string> : indicates if the strings passed as parameters to Python plugin callbacks on this system are Python byte strings or normal Python strings

=back

Here is an example of usage:

  import perl
  spads=perl.ExamplePlugin
  
  [...]
  
      if spads.get_flag('can_add_socket'):
          spads.addSocket(socket,readSocketCallback)
      else:
          spads.slog("This plugin requires the addSocket function",1)
          return False

=back

=head1 SHARED DATA

=head2 Constants

Following constants are directly accessible from Perl plugin modules (accessible
via C<perl.eval('$::SpadsPluginApi::...')> from Python plugin modules):

=over 2

=item C<$spadsVersion>

=item C<$spadsDir>

=back

=head2 Variables

Following variables are directly accessible from Perl plugin modules (accessible
via C<perl.eval('...')> from Python plugin modules), but it is strongly
recommended to use the accessors from the API instead:

=over 2

=item C<$::autohost>

=item C<%::conf>

=item C<%::confMacros>

=item C<%::currentVote>

=item C<$::lobby>

=item C<$::lobbyState>

=item C<$::p_runningBattle>

=item C<%::plugins>

=item C<@::pluginsOrder>

=item C<$::spads>

=item C<%::spadsHandlers>

=item C<$::springPid>

=item C<$::springServerType>

=item C<%::timestamps>

=back

=head1 SEE ALSO

L<SPADS plugin development tutorials (Perl)|http://springrts.com/wiki/SPADS_plugin_development>

L<SPADS plugin development tutorials (Python)|http://springrts.com/wiki/SPADS_plugin_development_(Python)>

Commented SPADS plugin templates (Perl): L<Simple plugin|http://planetspads.free.fr/spads/plugins/templates/commented/MySimplePlugin.pm>, L<Configurable plugin|http://planetspads.free.fr/spads/plugins/templates/commented/MyConfigurablePlugin.pm>, L<New command plugin|http://planetspads.free.fr/spads/plugins/templates/commented/MyNewCommandPlugin.pm>

Commented SPADS plugin templates (Python): L<Simple plugin|http://planetspads.free.fr/spads/plugins/templates/commented/mysimpleplugin.py>, L<Configurable plugin|http://planetspads.free.fr/spads/plugins/templates/commented/myconfigurableplugin.py>, L<New command plugin|http://planetspads.free.fr/spads/plugins/templates/commented/mynewcommandPlugin.py>

L<SPADS documentation|http://planetspads.free.fr/spads/doc/spadsDoc.html>, especially regarding plugins management: L<pluginsDir setting|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#global:pluginsDir>, L<autoLoadPlugins setting|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#global:autoLoadPlugins>, L<plugin command|http://planetspads.free.fr/spads/doc/spadsDoc_All.html#command:plugin>

L<Spring lobby protocol specifications|http://springrts.com/dl/LobbyProtocol/ProtocolDescription.html>

L<Spring autohost protocol specifications (from source comments)|https://raw.github.com/spring/spring/master/rts/Net/AutohostInterface.cpp>

L<Introduction to Perl|http://perldoc.perl.org/perlintro.html>

Inline::Python Perl module (the bridge between Perl and Python): L<documentation from meta::cpan|https://metacpan.org/pod/Inline::Python>, L<GitHub repository|https://github.com/niner/inline-python-pm>

=head1 COPYRIGHT

Copyright (C) 2013-2020  Yann Riou <yaribzh@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

=cut
