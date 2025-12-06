#!/usr/bin/perl -w
#
# SPADS: Spring Perl Autohost for Dedicated Server
#
# Copyright (C) 2008-2025  Yann Riou <yaribzh@gmail.com>
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


use strict;

use Config;
use Cwd 'cwd';
use Digest::MD5 'md5_base64';
use Fcntl qw':DEFAULT :flock';
use File::Copy;
use File::Spec::Functions qw'catdir catfile file_name_is_absolute';
use FindBin;
use IO::Uncompress::Gunzip '$GunzipError';
use IPC::Cmd 'can_run';
use JSON::PP;
use List::Util qw'first any all none notall shuffle reduce';
use MIME::Base64;
use POSIX qw'ceil uname';
use Storable qw'nfreeze dclone nstore retrieve';
use Symbol qw'delete_package';
use Text::ParseWords;
use Time::HiRes;

use lib $FindBin::Bin;

use SimpleEvent;
use SimpleLog;
use SpadsConf;
use SpadsUpdater;
use SpringAutoHostInterface;

my $SLI_LOADING_ERROR;
BEGIN { eval {require SpringLobbyInterface; 1} or do { $SLI_LOADING_ERROR=$@;chomp($SLI_LOADING_ERROR) } }

use constant {

  MSWIN32 => $^O eq 'MSWin32',
  DARWIN => $^O eq 'darwin',


  EXIT_SUCCESS => 0,
  EXIT_FAILURE => 1,

  # Command/environment problems
  EXIT_USAGE => 2,         # invalid usage
  EXIT_CONFIG => 3,        # invalid configuration
  EXIT_DEPENDENCY => 4,    # missing dependency

  # Data/state problems
  EXIT_CONFLICT => 16,     # instance directory conflict
  EXIT_INPUTDATA => 17,    # inconsistent input data

  # Other local problems
  EXIT_SYSTEM => 32,       # system call failure
  EXIT_SOFTWARE => 33,     # software failure

  # Network/remote system problems
  EXIT_REMOTE => 48,       # network error or deny from remote system
  EXIT_CERTIFICATE => 49,  # invalid/untrusted certificate
  EXIT_LOGIN => 50,        # login failure

  LOBBY_STATE_DISCONNECTED => 0,
  LOBBY_STATE_CONNECTING => 1,
  LOBBY_STATE_CONNECTED => 2,
  LOBBY_STATE_LOGGED_IN => 3,
  LOBBY_STATE_SYNCHRONIZED => 4,
  LOBBY_STATE_OPENING_BATTLE => 5,
  LOBBY_STATE_BATTLE_OPENED => 6,

  LOADARCHIVES_DEFAULT => 0,
  LOADARCHIVES_RELOAD => 1,
  LOADARCHIVES_GAME_ONLY => 2,
};

if(MSWIN32) {
  eval { require Win32; 1; }
      or fatalError("$@Missing dependency: Win32 Perl module",EXIT_DEPENDENCY);
  eval { require Win32::API; 1; }
      or fatalError("$@Missing dependency: Win32::API Perl module",EXIT_DEPENDENCY);
  eval { Win32::API->VERSION(0.73); 1; }
      or fatalError("$@SPADS requires Win32::API module version 0.73 or superior, please update your Perl installation (Perl 5.16.2 or superior is recommended)",EXIT_DEPENDENCY);
  eval { require Win32::TieRegistry; Win32::TieRegistry->import(':KEY_'); 1; }
      or fatalError("$@Missing dependency: Win32::TieRegistry Perl module",EXIT_DEPENDENCY);
  Win32::API->Import('msvcrt', 'int __cdecl _putenv (char* envstring)')
      or fatalError('Failed to import _putenv function from msvcrt.dll ('.getLastWin32Error().')',EXIT_DEPENDENCY);
}else{
  eval { require FFI::Platypus; 1; }
    or fatalError("$@Missing dependency: FFI::Platypus Perl module",EXIT_DEPENDENCY);
}

SimpleEvent::addProxyPackage('SpadsPluginApi');
SimpleEvent::addProxyPackage('Inline');

# Constants ###################################################################

our $SPADS_VERSION='0.13.48';
our $spadsVer=$SPADS_VERSION; # TODO: remove this line when AutoRegister plugin versions < 0.3 are no longer used

our $CWD=cwd();
my $PATH_SEP=MSWIN32?';':':';

my @SPADS_PACKAGES=qw'spads.pl help.dat helpSettings.dat PerlUnitSync.pm springLobbyCertificates.dat SpringAutoHostInterface.pm SpringLobbyProtocol.pm SpringLobbyInterface.pm SimpleEvent.pm SimpleLog.pm SpadsConf.pm SpadsUpdater.pm SpadsPluginApi.pm argparse.py replay_upload.py';
if(MSWIN32) {
  push(@SPADS_PACKAGES,'7za.exe');
}elsif(! DARWIN) {
  push(@SPADS_PACKAGES,'7za');
}

my %IRC_COLORS;
my %NO_COLOR;
for my $i (0..15) {
  $IRC_COLORS{$i}=''.sprintf('%02u',$i);
  $NO_COLOR{$i}='';
}
my @IRC_STYLE=(\%IRC_COLORS,'');
my @NO_IRC_STYLE=(\%NO_COLOR,'');

my %PRIVATE_SETTINGS = map {$_ => 1} (qw'commandsFile endGameCommand endGameCommandEnv');
my %HIDDEN_PRESET_SETTINGS = map {$_ => 1} (qw'description preset hostingPreset battlePreset welcomeMsg welcomeMsgInGame mapLink ghostMapLink advertMsg commandsFile endGameCommand endGameCommandEnv endGameCommandMsg');
my %HIDDEN_HOSTING_SETTINGS = map {$_ => 1} (qw'description battleName');
my %HIDDEN_PLUGIN_SETTINGS = map {$_ => 1} (qw'commandsFile helpFile');
my %HIDDEN_SETTINGS_LOWERCASE = map {lc($_) => 1} (keys %HIDDEN_PRESET_SETTINGS,keys %HIDDEN_HOSTING_SETTINGS);

my @OPTION_TYPES=qw'error bool list number string section';

my %MACOS_SYSTEM_INFO;
if(DARWIN) {
  my $sysctlBin;
  if(-x '/sbin/sysctl') {
    $sysctlBin='/sbin/sysctl';
  }elsif(-x '/usr/sbin/sysctl') {
    $sysctlBin='/usr/sbin/sysctl';
  }else{
    $sysctlBin=can_run('sysctl');
  }
  if(defined $sysctlBin) {
    my @sysctlOut=`$sysctlBin -a 2>/dev/null`;
    foreach my $line (@sysctlOut) {
      if($line =~ /^\s*([^:]*[^\s:])\s*:\s*(.*[^\s])\s*$/) {
        $MACOS_SYSTEM_INFO{$1}=$2;
      }
    }
  }
  my $swVersBin;
  if(-x '/bin/sw_vers') {
    $swVersBin='/bin/sw_vers';
  }elsif(-x '/usr/bin/sw_vers') {
    $swVersBin='/usr/bin/sw_vers';
  }else{
    $swVersBin=can_run('sw_vers');
  }
  if(defined $swVersBin) {
    my @swVersOut=`$swVersBin 2>/dev/null`;
    foreach my $line (@swVersOut) {
      if($line =~ /^\s*([^:]*[^\s:])\s*:\s*(.*[^\s])\s*$/) {
        $MACOS_SYSTEM_INFO{$1}=$2;
      }
    }
  }
}

my %SPADS_CORE_CMD_HANDLERS = (
  addbot => \&hAddBot,
  addbox => \&hAddBox,
  advert => \&hAdvert,
  auth => \&hAuth,
  balance => \&hBalance,
  ban => \&hBan,
  banip => \&hBanIp,
  banips => \&hBanIps,
  bkick => \&hBKick,
  bpreset => \&hBPreset,
  boss => \&hBoss,
  bset => \&hBSet,
  callvote => \&hCallVote,
  cancelquit => \&hCancelQuit,
  cheat => \&hCheat,
  chpasswd => \&hChpasswd,
  chrank => \&hChrank,
  chskill => \&hChskill,
  ckick => \&hCKick,
  clearbox => \&hClearBox,
  closebattle => \&hCloseBattle,
  endvote => \&hEndVote,
  fixcolors => \&hFixColors,
  force => \&hForce,
  forcepreset => \&hForcePreset,
  forcestart => \&hForceStart,
  gkick => \&hGKick,
  help => \&hHelp,
  helpall => \&hHelpAll,
  hoststats => \&hHostStats,
  hpreset => \&hHPreset,
  hset => \&hHSet,
  joinas => \&hJoinAs,
  kick => \&hKick,
  kickban => \&hKickBan,
  learnmaps => \&hLearnMaps,
  list => \&hList,
  loadboxes => \&hLoadBoxes,
  lock => \&hLock,
  maplink => \&hMapLink,
  nextmap => \&hNextMap,
  nextpreset => \&hNextPreset,
  notify => \&hNotify,
  openbattle => \&hOpenBattle,
  plugin => \&hPlugin,
  preset => \&hPreset,
  promote => \&hPromote,
  pset => \&hPSet,
  quit => \&hQuit,
  rebalance => \&hRebalance,
  reloadarchives => \&hReloadArchives,
  reloadconf => \&hReloadConf,
  removebot => \&hRemoveBot,
  rehost => \&hRehost,
  resign => \&hResign,
  restart => \&hRestart,
  ring => \&hRing,
  saveboxes => \&hSaveBoxes,
  say => \&hSay,
  searchuser => \&hSearchUser,
  send => \&hSend,
  sendlobby => \&hSendLobby,
  set => \&hSet,
  smurfs => \&hSmurfs,
  specafk => \&hSpecAfk,
  split => \&hSplit,
  start => \&hStart,
  stats => \&hStats,
  status => \&hStatus,
  stop => \&hStop,
  unban => \&hUnban,
  unbanip => \&hUnbanIp,
  unbanips => \&hUnbanIps,
  unlock => \&hUnlock,
  unlockspec => \&hUnlockSpec,
  update => \&hUpdate,
  version => \&hVersion,
  vote => \&hVote,
  whois => \&hWhois,
  '#skill' => \&hSkill );

my %SPADS_CORE_CMDS_CUSTOM_PARAM_PARSING = (
  addbot => 3,
  advert => 1,
  ban => 4,
  banip => 4,
  banips => 4,
  bset => 2,
  callvote => 1,
  cheat => 1,
  coop => 1,
  hset => 2,
  loadboxes => 1,
  map => 1,
  plugin => 4,
  pset => 2,
  rck => 1,
  reloadconf => 1,
  restart => 1,
  say => 1,
  send => 1,
  sendlobby => 1,
  set => 2,
    );

my %SPADS_CORE_CMD_ALIASES=(
  b => ['vote','b'],
  coop => ['pSet','shareId'],
  cv => ['callVote'],
  ev => ['endVote'],
  fb => ['force','*'],
  h => ['help'],
  map => ['set','map'],
  n => ['vote','n'],
  rc => ['reloadConf'],
  rck => ['reloadConf','keepSettings %1%'],
  s => ['status'],
  sb => ['status','battle'],
  spec => ['force','%1%','spec'],
  su => ['searchUser'],
  us => ['unlockSpec'],
  w => ['whois'],
  y => ['vote','y'],
    );

my %SPADS_CORE_API_HANDLERS = (
  getPreferences => \&hApiGetPreferences,
  getSettings => \&hApiGetSettings,
  getVoteSettings => \&hApiGetVoteSettings,
  status => \&hApiStatus,
    );
my %SPADS_CORE_API_RIGHTS = (
  getPreferences => 'list',
  getSettings => 'list',
  getVoteSettings => 'list',
    );

my %ALERTS=('UPD-001' => 'Unable to check for SPADS update',
            'UPD-002' => 'Major SPADS update available',
            'UPD-003' => 'Unable to apply SPADS update',
            'SPR-001' => 'Spring server crashed');

my %RANK_SKILL=(0 => 10,
                1 => 13,
                2 => 16,
                3 => 20,
                4 => 25,
                5 => 30,
                6 => 35,
                7 => 38);
my %RANK_TRUESKILL=(0 => 20,
                    1 => 22,
                    2 => 23,
                    3 => 24,
                    4 => 25,
                    5 => 26,
                    6 => 28,
                    7 => 30);

our %JSONRPC_ERRORS = ( RATE_LIMIT_EXCEEDED => -1,
                        INSUFFICIENT_PRIVILEGES => -2,
                        UNKNOWN_ERROR => -3,
                        PARSE_ERROR => -32700,
                        INVALID_REQUEST => -32600,
                        METHOD_NOT_FOUND => -32601,
                        INVALID_PARAMS => -32602,
                        INTERNAL_ERROR => -32603,
                        SERVER_ERROR => -32000 );
my %JSONRPC_ERRORMSGS = ( -1 => 'Rate limit exceeded',
                          -2 => 'Insufficient privileges',
                          -3 => 'Unknown error',
                          -32700 => 'Parse error',
                          -32600 => 'Invalid request',
                          -32601 => 'Method not found',
                          -32602 => 'Invalid params',
                          -32603 => 'Internal error' );
map {$JSONRPC_ERRORMSGS{$_}='Server error'} (-32099..-32000);

my @DEFAULT_COLOR_ORDER=(qw'red blue green yellow cyan magenta orange purple teal gold azure pink lime gray');

# Command line parameters handling ############################################

invalidUsage() if($#ARGV < 0 || ! (-f $ARGV[0]));

my ($confFile,$genDoc,$tlsAction,$tlsHost,$tlsCert);
our %confMacros;
{
  my @cmdLineArgs=@ARGV;
  $confFile=shift(@cmdLineArgs);
  my $p_macroData;
  ($p_macroData,$genDoc,$tlsAction,$tlsHost,$tlsCert)=parseCmdLineArgs(@cmdLineArgs);
  invalidUsage() unless(defined $p_macroData);
  %confMacros=%{$p_macroData};
}

# Default logging system ######################################################

my $sLog=SimpleLog->new(prefix => "[SPADS] ");

$SIG{__DIE__} = sub {
  return unless(defined $^S && ! $^S);
  my $msg=shift;
  chomp($msg);
  slog("Fatal error: $msg",0);
  my $nestLevel=1;
  while(my @callerData=caller($nestLevel++)) {
    if($nestLevel>9) {
      slog("Fatal error:         ...",0);
      last;
    }else{
      slog("Fatal error:         $callerData[3] called at $callerData[1] line $callerData[2]",0);
    }
  }
};

$SIG{__WARN__} = sub {
  my $msg=shift;
  chomp($msg);
  slog("PERL WARNING: $msg",1);
  my $nestLevel=1;
  while(my @callerData=caller($nestLevel++)) {
    if($nestLevel>9) {
      slog("PERL WARNING:         ...",1);
      last;
    }else{
      slog("PERL WARNING:         $callerData[3] called at $callerData[1] line $callerData[2]",1);
    }
  }
};

# Configuration loading #######################################################

our $spads=SpadsConf->new($confFile,$sLog,\%confMacros);
fatalError('Unable to load SPADS configuration at startup',EXIT_CONFIG) unless($spads);
$sLog=$spads->{log};

# State variables #############################################################
#
# Already declared:
# . Command line parameters handling:
#     my ($confFile,$genDoc,$tlsAction,$tlsHost,$tlsCert);
#     our %confMacros;
#
# . Default logging system:
#     my $sLog;
#
# . Configuration loading:
#     our $spads;
#

my $masterChannel=$spads->{conf}{masterChannel};
$masterChannel=$1 if($masterChannel =~ /^([^\s]+)\s/);

my $spadsDir=File::Spec->canonpath($FindBin::Bin);
our %conf=%{$spads->{conf}};
my $abortSpadsStartForAutoUpdate=0;
my %quitAfterGame=(
  action => undef, # 0: shutdown, 1: restart
  condition => undef, # 0: no game is running, 1: no game is running and only spectators in battle lobby, 2: no game is running and battle lobby is empty
  exitCode => EXIT_SUCCESS,
    );
my $closeBattleAfterGame=0;
our %timestamps=(connectAttempt => 0,
                 ping => 0,
                 promote => 0,
                 autoRestore => 0,
                 battleChange => 0,
                 balance => 0,
                 autoBalance => 0,
                 fixColors => 0,
                 autoHostStart => time,
                 lastGameStart => 0,
                 lastGameStartPlaying => 0,
                 lastGameEnd => 0,
                 rotationEmpty => time,
                 dataDump => time,
                 autoUpdate => 0,
                 autoRestartCheck => 0,
                 autoForcePossible => 0,
                 archivesLoad => 0,
                 archivesLoadFull => 0,
                 archivesCheck => 0,
                 mapLearned => 0,
                 autoStop => -1,
                 floodPurge => time,
                 advert => time,
                 gameOver => 0,
                 prefCachePurge => time,
                 usLockRequestForGameStart => 0);
my $syncedSpringVersion='';
my $fullSpringVersion='';
our $lobbyState=LOBBY_STATE_DISCONNECTED;
my %pendingRedirect;
my $lobbyBrokenConnection=0;
my $loadArchivesInProgress=0;
my %availableMapsNameToNb;
my @availableMaps;
my %availableModsNameToNb;    # empty unless a game/mod name regex has been used for latest successful load archives operation
my %rapidModResolutionCache;  # empty unless a game/mod rapid tag has been used for latest successful load archives operation
my %cachedMods;
my ($currentNbNonPlayer,$currentLockedStatus)=(0,0);
my $currentMap=$conf{map};
my $targetMod='';
our $p_runningBattle={};
my %inGameAddedUsers;
my %inGameAddedPlayers;
my %runningBattleMapping;
my %runningBattleReversedMapping;
my $cheating=0;
my $p_gameOverResults={};
my %defeatTimes;
my $p_answerFunction;
our %currentVote=();
our $springPid=0;
my $springWin32Process;
my %endGameData;
my $nbEndGameCommandRunning=0;
my %gdr;
my %gdrIPs;
my @gdrQueue;
my $gdrLobbyBot='SpringLobbyMonitor';
my $sldbLobbyBot='SLDB';
my $gdrEnabled=0;
my %teamStats;
my %lastSentMessages;
my @messageQueue=();
my @lowPriorityMessageQueue=();
my %lastBattleMsg;
my %lastBattleStatus;
my %lastFloodKicks;
my %lastCmds;
my %ignoredUsers;
my $balanceState=0; # 0: not balanced, 1: balanced
my $colorsState=0; # 0: not fixed, 1: fixed
my @predefinedColors;
my %advColors;
my %balanceTarget;
my %colorsTarget;
my $manualLockedStatus=0;
my %currentPlayers;
my %currentSpecs;
my %forceSpecTimestamps;
my %pendingLocalBotManual;
my %pendingLocalBotAuto;
my %autoAddedLocalBots;
my %pendingFloodKicks;
my %pendingNotifications;
my %pendingSpecJoin;
my %lastRungUsers;
my $triedGhostWorkaround=0;
my $inGameTime=0;
my $accountInGameTime;
my ($os,$mem,$sysUptime,$cpuModel)=getSysInfo();
my %pendingAlerts;
my %alertedUsers;
my %springPrematureEndData=();
our %bosses=();
my $balRandSeed=intRand();
my %authenticatedUsers;
my $lanMode=0;
our @pluginsOrder;
my %pluginsReverseDeps;
our %plugins;
my %battleSkills;
our %battleSkillsCache;
my %pendingGetSkills;
my $currentGameType='Duel';
our $springServerType=$conf{springServerType};
my $springServerBin=$conf{springServer};
my %autoManagedEngineData=(mode => 'off');
my $failedEngineInstallVersion;
my $engineVersionAutoManagementInProgress;
my ($lockFh,$pidFile,$lockAcquired,$auLockFh,$periodicAutoUpdateLockAcquired,$usLockFhForGameStart);
my %prefCache;
my %prefCacheTs;
our %spadsCmdHandlers=%SPADS_CORE_CMD_HANDLERS;
our %spadsApiHandlers=%SPADS_CORE_API_HANDLERS;
our %spadsApiRights=%SPADS_CORE_API_RIGHTS;
our %spadsCmdsCustomParamParsing=%SPADS_CORE_CMDS_CUSTOM_PARAM_PARSING;
my %nbRelayedApiCalls;
my %ignoredRelayedApiUsers;
my %pendingRelayedJsonRpcChunks;
my %sentPlayersScriptTags;
my $simpleEventLoopStopping;
our $unitsync;
my %unitsyncOptFuncs;
my %unitsyncHostHashes;
my $lobbyReconnectDelay;
my $useTls;
my %hostingParams;

my $lobbySimpleLog=SimpleLog->new(logFiles => [$conf{logDir}."/spads.log",''],
                                  logLevels => [$conf{lobbyInterfaceLogLevel},3],
                                  useANSICodes => [0,-t STDOUT ? 1 : 0],
                                  useTimestamps => [1,-t STDOUT ? 0 : 1],
                                  prefix => "[SpringLobbyInterface] ");

my $autohostSimpleLog=SimpleLog->new(logFiles => [$conf{logDir}."/spads.log"],
                                     logLevels => [$conf{autoHostInterfaceLogLevel}],
                                     useANSICodes => [0],
                                     useTimestamps => [1],
                                     prefix => "[SpringAutoHostInterface] ");

my $updaterSimpleLog=SimpleLog->new(logFiles => [$conf{logDir}."/spads.log",""],
                                    logLevels => [$conf{updaterLogLevel},3],
                                    useANSICodes => [0,-t STDOUT ? 1 : 0],
                                    useTimestamps => [1,-t STDOUT ? 0 : 1],
                                    prefix => "[SpadsUpdater] ");

my $simpleEventSimpleLog=SimpleLog->new(logFiles => [$conf{logDir}.'/spads.log',''],
                                        logLevels => [$conf{simpleEventLogLevel},3],
                                        useANSICodes => [0,-t STDOUT ? 1 : 0],
                                        useTimestamps => [1,-t STDOUT ? 0 : 1],
                                        prefix => "[SimpleEvent] ");

our $lobby;
$lobby = SpringLobbyInterface->new(serverHost => $conf{lobbyHost},
                                   serverPort => $conf{lobbyPort},
                                   simpleLog => $lobbySimpleLog,
                                   warnForUnhandledMessages => 0,
                                   inconsistencyHandler => sub { return $lobbyBrokenConnection=1; } )
    unless($SLI_LOADING_ERROR);

our $autohost = SpringAutoHostInterface->new(autoHostPort => $conf{autoHostPort},
                                             simpleLog => $autohostSimpleLog,
                                             warnForUnhandledMessages => 0);

my $updater = SpadsUpdater->new(sLog => $updaterSimpleLog,
                                repository => "http://planetspads.free.fr/spads/repository",
                                release => $conf{autoUpdateRelease},
                                packages => \@SPADS_PACKAGES,
                                springDir => $conf{autoManagedSpringDir});

# Binaries update (Windows only) ##############################################

if(MSWIN32) {
  if(opendir(BINDIR,$spadsDir)) {
    my @toBeDeletedFiles = grep {/\.toBeDeleted$/} readdir(BINDIR);
    closedir(BINDIR);
    my @toBeDelAbsNames=map("$spadsDir/$_",@toBeDeletedFiles);
    unlink @toBeDelAbsNames;
  }
  my %updatedPackages;
  if(-f "$spadsDir/updateInfo.txt") {
    if(open(UPDATE_INFO,"<$spadsDir/updateInfo.txt")) {
      while(local $_ = <UPDATE_INFO>) {
        $updatedPackages{$1}=$2 if(/^([^:]+):(.+)$/);
      }
      close(UPDATE_INFO);
    }else{
      fatalError("Unable to read \"$spadsDir/updateInfo.txt\" file",EXIT_SYSTEM);
    }
  }
  foreach my $updatedPackage (keys %updatedPackages) {
    my $updatedPackagePath=catfile($spadsDir,$updatedPackage);
    my $versionedUpdatedPackagePath=catfile($spadsDir,$updatedPackages{$updatedPackage});
    next unless($updatedPackage =~ /\.(exe|dll)$/ && -f $versionedUpdatedPackagePath);
    if(-f $updatedPackagePath) {
      my @origStat=stat($versionedUpdatedPackagePath);
      my @destStat=stat($updatedPackagePath);
      next if($origStat[9] <= $destStat[9]);
      unlink($updatedPackagePath);
      renameToBeDeleted($updatedPackagePath) if(-f $updatedPackagePath);
    }
    if(! copy($versionedUpdatedPackagePath,$updatedPackagePath)) {
      fatalError("Unable to copy \"$versionedUpdatedPackagePath\" to \"$updatedPackagePath\", system consistency must be checked manually !",EXIT_SYSTEM);
    }
    slog("Copied \"$versionedUpdatedPackagePath\" to \"$updatedPackagePath\" (Windows binary update mode)",5);
  }
}

# TLS certificates management #################################################

if(defined $tlsAction && ($tlsAction eq 'revoke' || $tlsAction eq 'list' || defined $tlsCert)) {
  $tlsHost//=$conf{lobbyHost} unless($tlsAction eq 'list');
  my $exitCode=EXIT_SUCCESS;
  if($tlsAction eq 'trust') {
    my $res=$spads->addTrustedCertificateHash({lobbyHost => $tlsHost, certHash => $tlsCert});
    if($res) {
      slog("Added trusted certificate hash (SHA-256) $tlsCert for host $tlsHost",3);
    }else{
      $exitCode=EXIT_INPUTDATA;
      slog('Failed to add trusted certificate!',1);
    }
  }elsif($tlsAction eq 'revoke') {
    my $res=$spads->removeTrustedCertificateHash({lobbyHost => $tlsHost, certHash => $tlsCert});
    if($res) {
      slog("Revoked certificate hash (SHA-256) $tlsCert for host $tlsHost",3);
    }else{
      $exitCode=EXIT_INPUTDATA;
      slog('Failed to revoke certificate!',1) unless($res);
    }
  }else{
    my $r_trustedCerts=$spads->getTrustedCertificateHashes();
    my @trustedCerts;
    foreach my $lobbyHost (keys %{$r_trustedCerts}) {
      next if(defined $tlsHost && $lobbyHost ne $tlsHost);
      foreach my $lobbyCert (keys %{$r_trustedCerts->{$lobbyHost}}) {
        push(@trustedCerts,{host => $lobbyHost, hash => $lobbyCert});
      }
    }
    if(@trustedCerts) {
      print 'Trusted lobby certificate hash'.($#trustedCerts>0?'es':'').' (SHA-256)'.(defined $tlsHost ? " for host $tlsHost" : '').":\n";
      foreach my $r_trustedCert (@trustedCerts) {
        if(defined $tlsHost) {
          print "  - $r_trustedCert->{hash}\n";
        }else{
          print "  - host:$r_trustedCert->{host}, hash:$r_trustedCert->{hash}\n";
        }
      }
    }else{
      print 'No trusted lobby certificate'.(defined $tlsHost ? " for host $tlsHost" : '')."!\n";
    }
  }
  exit $exitCode;
}

if($conf{lobbyTls} ne 'off') {
  $useTls = eval {require IO::Socket::SSL; 1};
  fatalError('Module IO::Socket::SSL required for TLS support',EXIT_DEPENDENCY) if($conf{lobbyTls} eq 'on' &&  ! $useTls);
}

# Console title update (Windows only) #########################################

if(MSWIN32) {
  eval {
    require Win32::Console;
    my $title=$conf{lobbyLogin};
    $title.="\@$conf{lobbyHost}" if($conf{lobbyHost} ne 'lobby.springrts.com' || $conf{lobbyPort} != 8200);
    $title.=":$conf{lobbyPort}" if($conf{lobbyPort} != 8200);
    $title.=" (SPADS $SPADS_VERSION)";
    Win32::Console->new()->Title($title);
  };
}

# Subfunctions ################################################################

sub invalidUsage {
  print "usage: perl $0 <configurationFile> [--doc] [<macroName>=<macroValue> [...]]\n";
  print <<EOH;
       perl $0 <configurationFile> --tls-cert-trust
       perl $0 <configurationFile> --tls-cert-trust=<certificateHash>
       perl $0 <configurationFile> --tls-cert-trust=<hostName>:<certificateHash>
       perl $0 <configurationFile> --tls-cert-revoke=<certificateHash>
       perl $0 <configurationFile> --tls-cert-revoke=<hostName>:<certificateHash>
       perl $0 <configurationFile> --tls-cert-list
       perl $0 <configurationFile> --tls-cert-list=<hostName>
EOH
  exit EXIT_USAGE;
}

sub parseCmdLineArgs {
  my $parsedGenDoc=0;
  my ($parsedTlsAction,$parsedTlsHost,$parsedTlsCert);
  my %macros;
  foreach my $arg (@_) {
    if($arg =~ /^--tls-cert-(trust|revoke|list)(?:=(.+))?$/i) {
      return undef if(defined $parsedTlsAction);
      $parsedTlsAction=lc($1);
      my $tlsParam=lc($2) if(defined $2);
      if(defined $tlsParam) {
        if($parsedTlsAction eq 'list') {
          return undef unless($tlsParam =~ /^\w[\w\-\.]*$/);
          $parsedTlsHost=$tlsParam;
        }elsif($tlsParam =~ /^(\w[\w\-\.]*):([\da-f]+)$/) {
          ($parsedTlsHost,$parsedTlsCert)=($1,$2);
        }elsif($tlsParam =~ /^[\da-f]+$/) {
          $parsedTlsCert=$tlsParam;
        }else{
          return undef;
        }
      }else{
        return undef if($parsedTlsAction eq 'revoke');
      }
    }elsif($arg =~ /^([\w\:]+)=(.*)$/) {
      $macros{$1}=$2;
    }elsif($arg eq "--doc") {
      $parsedGenDoc=1;
    }else{
      return undef;
    }
  }
  return (\%macros,$parsedGenDoc,$parsedTlsAction,$parsedTlsHost,$parsedTlsCert);
}

sub parseMacroTokens {
  my %macros;
  foreach my $macroToken (@_) {
    if($macroToken =~ /^([\w\:]+)=(.*)$/) {
      $macros{$1}=$2;
    }else{
      return undef;
    }
  }
  return \%macros;
}

sub slog { $sLog->log(@_) }

sub fatalError {
  my ($m,$ec)=@_;
  $ec//=EXIT_SOFTWARE;
  defined $sLog ? $sLog->log($m,0) : print STDERR $m."\n";
  unlink($pidFile) if($lockAcquired);
  exit $ec;
}

sub intRand {
  rand() =~ /\.(\d+)/;
  return $1 % 99999999;
}

sub renameToBeDeleted {
  my $fileName=shift;
  my $i=1;
  while(-f "$fileName.$i.toBeDeleted" && $i < 100) {
    $i++;
  }
  return move($fileName,"$fileName.$i.toBeDeleted");
}

sub int32 { return unpack('l',pack('l',shift)) }
sub uint32 { return unpack('L',pack('L',shift)) }

sub hasEvalError {
  if($@) {
    chomp($@);
    return 1;
  }else{
    return 0;
  }
}

sub getPerlModuleVersion {
  my @moduleParts=split(/::/,shift);
  my $r_symtab=\%::;
  while (my $nextModulePart=shift(@moduleParts)) {
    return undef unless(exists $r_symtab->{"$nextModulePart\::"});
    $r_symtab=$r_symtab->{"$nextModulePart\::"};
  }
  return undef unless(exists $r_symtab->{VERSION});
  return ${$r_symtab->{VERSION}};
}

sub onSpringProcessExit {
  my (undef,$exitCode,$signalNb,$hasCoreDump)=@_;
  $signalNb//=0;
  $hasCoreDump//=0;
  if($usLockFhForGameStart) {
    close($usLockFhForGameStart);
    undef $usLockFhForGameStart;
  }
  if(%{$p_runningBattle}) {
    %springPrematureEndData=(ec => $exitCode, ts => time, signal => $signalNb, core => $hasCoreDump);
  }else{
    my $gameRunningTime=secToTime(time-$timestamps{lastGameStart});
    if(($exitCode && $exitCode != 255) || $signalNb || $hasCoreDump) {
      $autohost->serverQuitHandler() if($autohost->{state});
      my $logMsg="Spring crashed (running time: $gameRunningTime";
      if($signalNb) {
        $logMsg.=", interrupted by signal $signalNb";
        $logMsg.=", exit code: $exitCode" if($exitCode);
      }else{
        $logMsg.=", exit code: $exitCode";
      }
      $logMsg.=', core dumped' if($hasCoreDump);
      $logMsg.=')';
      slog($logMsg,1);
      broadcastMsg("Spring crashed ! (running time: $gameRunningTime)");
      addAlert('SPR-001');
    }else{
      slog('Spring server detected sync errors during game',2) if($exitCode == 255);
      broadcastMsg("Server stopped (running time: $gameRunningTime)");
      endGameProcessing();
      delete $pendingAlerts{'SPR-001'};
    }
    $inGameTime+=time-$timestamps{lastGameStart};
    setAsOutOfGame();
  }
}

sub onUpdaterCallEnd {
  my ($updateRc,$ignorePackageListDlErr)=@_;
  if($updateRc < 0) {
    if($updateRc > -7 || $updateRc == -12) {
      if(! $ignorePackageListDlErr || $updateRc != -4) {
        delete @pendingAlerts{('UPD-002','UPD-003')};
        addAlert('UPD-001');
      }
    }elsif($updateRc == -7) {
      delete @pendingAlerts{('UPD-001','UPD-003')};
      addAlert('UPD-002');
    }else{
      delete @pendingAlerts{('UPD-001','UPD-002')};
      addAlert('UPD-003');
    }
  }else{
    delete @pendingAlerts{('UPD-001','UPD-002','UPD-003')};
  }
  if(isRestartForUpdateApplicable() && (! $updater->isUpdateInProgress())) {
    autoRestartForUpdateIfNeeded();
  }
}

sub getLastWin32Error {
  my $errorNb=Win32::GetLastError();
  return 'unknown error' unless($errorNb);
  my $errorMsg=Win32::FormatMessage($errorNb)//($^E=$errorNb);
  $errorMsg=~s/\cM?\cJ$//;
  return $errorMsg;
}

sub escapeWin32Parameter {
  my $arg = shift;
  $arg =~ s/(\\*)"/$1$1\\"/g;
  if($arg =~ /[ \t\(]/) {
    $arg =~ s/(\\*)$/$1$1/;
    $arg = "\"$arg\"";
  }
  return $arg;
}

sub portableExec {
  my ($program,@params)=@_;
  my @args=($program,@params);
  @args=map {escapeWin32Parameter($_)} @args if(MSWIN32);
  return exec {$program} @args;
}

sub execError {
  my ($msg,$level)=@_;
  slog($msg,$level);
  exit EXIT_FAILURE;
}

sub autoRetry {
  my ($p_f,$retryNb,$delayMs)=@_;
  $retryNb//=50;
  $delayMs//=100;
  my $delayUs=1000*$delayMs;
  my $res=&{$p_f}();
  while(! $res) {
    return 0 unless($retryNb--);
    Time::HiRes::usleep($delayUs);
    $res=&{$p_f}();
  }
  return $res;
}

sub areSamePaths {
  my ($p1,$p2)=map {File::Spec->canonpath($_)} @_;
  ($p1,$p2)=map {lc($_)} ($p1,$p2) if(MSWIN32);
  return $p1 eq $p2;
}

sub splitPaths {
  my $pathsString=shift;
  return () unless(defined $pathsString);
  return split(/$PATH_SEP/,$pathsString);
}

sub setEnvVarFirstPaths {
  my ($varName,@firstPaths)=@_;
  my $needRestart=0;
  fatalError("Unable to handle path containing \"$PATH_SEP\" character!") if(any {index($_,$PATH_SEP) != -1} @firstPaths);
  $ENV{"SPADS_$varName"}=$ENV{$varName}//'_UNDEF_' unless(exists $ENV{"SPADS_$varName"});
  my @currentPaths=split(/$PATH_SEP/,$ENV{$varName}//'');
  $needRestart=1 if($#currentPaths < $#firstPaths);
  if(! $needRestart) {
    for my $i (0..$#firstPaths) {
      if(! areSamePaths($currentPaths[$i],$firstPaths[$i])) {
        $needRestart=1;
        last;
      }
    }
  }
  if($needRestart) {
    my @origPaths=$ENV{"SPADS_$varName"} eq '_UNDEF_' ? () : split(/$PATH_SEP/,$ENV{"SPADS_$varName"});
    my @newPaths;
    foreach my $path (@origPaths) {
      push(@newPaths,$path) unless(any {areSamePaths($path,$_)} @firstPaths);
    }
    $ENV{$varName}=join($PATH_SEP,@firstPaths,@newPaths);
  }
  return $needRestart;
}

sub exportWin32EnvVar {
  my $envVar=shift;
  my $envVarDef="$envVar=".($ENV{$envVar}//'');
  fatalError("Unable to export environment variable definition \"$envVarDef\"",EXIT_SYSTEM) unless(int32(_putenv($envVarDef)) == 0);
}

sub setSpringEnv {
  my @dataDirs=@_;
  
  setEnvVarFirstPaths('SPRING_DATADIR',@dataDirs);
  exportWin32EnvVar('SPRING_DATADIR') if(MSWIN32);
  
  $ENV{SPRING_WRITEDIR}=$dataDirs[0] unless(areSamePaths($dataDirs[0],$ENV{SPRING_WRITEDIR}//''));
  exportWin32EnvVar('SPRING_WRITEDIR') if(MSWIN32);
  
  eval {require PerlUnitSync};
  fatalError("Unable to load PerlUnitSync module ($@)") if (hasEvalError());

  $unitsync = eval {PerlUnitSync->new($conf{unitsyncDir} eq '' ? $dataDirs[1] : $conf{unitsyncDir})};
  fatalError($@) if (hasEvalError());
  fatalError("Failed to load unitsync library from \"$conf{unitsyncDir}\" - unknown error") unless(defined $unitsync);
  map {$unitsyncOptFuncs{$_}=1 if($unitsync->hasFunc($_))} (qw'GetMapInfoCount GetMacAddrHash GetSysInfoHash');
  $unitsyncHostHashes{macAddr}=$unitsync->GetMacAddrHash() if($unitsyncOptFuncs{GetMacAddrHash});
  $unitsyncHostHashes{sysInfo}=$unitsync->GetSysInfoHash() if($unitsyncOptFuncs{GetSysInfoHash});
}

sub setSpringServerBin {
  my $baseDir=shift;
  $springServerBin=catfile($baseDir,"spring-$springServerType".(MSWIN32?'.exe':''));
}

sub generateGameId {
  my @gameIdChars=split('','1234567890abcdef');
  my $gameId='SPADS-';
  for my $i (1..26) {
    $gameId.=$gameIdChars[int(rand($#gameIdChars+1))];
  }
  return $gameId;
}

sub compareVersionElem {
  my ($v1,$v2)=@_;
  my ($v1Nb,$v1Str,$v2Nb,$v2Str);
  if($v1 =~ /^(\d+)(.*)$/) {
    ($v1Nb,$v1Str)=($1,$2);
  }else{
    ($v1Nb,$v1Str)=(0,$v1);
  }
  if($v2 =~ /^(\d+)(.*)$/) {
    ($v2Nb,$v2Str)=($1,$2);
  }else{
    ($v2Nb,$v2Str)=(0,$v2);
  }
  return 1 if($v1Nb > $v2Nb);
  return -1 if($v1Nb < $v2Nb);
  return 1 if($v1Str gt $v2Str);
  return -1 if($v1Str lt $v2Str);
  return 0;
}

sub compareVersions {
  my ($ver1,$ver2)=@_;
  my @v1=split(/\./,$ver1);
  my @v2=split(/\./,$ver2);
  my $maxSize=$#v1 > $#v2 ? $#v1 : $#v2;
  for my $i (0..$maxSize) {
    my ($val1,$val2)=(0,0);
    $val1=$v1[$i] if(defined $v1[$i]);
    $val2=$v2[$i] if(defined $v2[$i]);
    my $comp=compareVersionElem($val1,$val2);
    return $comp if($comp);
  }
  return 0;
}

sub generatePassword {
  my ($length,$r_passwdChars)=@_;
  if(! ref $r_passwdChars) {
    my $passwdChars = defined $r_passwdChars ? $r_passwdChars : 'abcdefghijklmnopqrstuvwxyz1234567890';
    $r_passwdChars=[split('',$passwdChars)];
  }
  my $passwd='';
  for my $i (1..$length) {
    $passwd.=$r_passwdChars->[int(rand(@{$r_passwdChars}))];
  }
  return $passwd;
}

sub isInvalidRegexp {
  my $pattern=shift;
  my $regex = eval { qr/$pattern/ };
  return $@ if($@);
  return 0;
}

sub convertBanDuration {
  my $duration=shift;
  $duration = $1 * 525600 if($duration =~ /^(\d+)y$/);
  $duration = $1 * 43200 if($duration =~ /^(\d+)m$/);
  $duration = $1 * 10080 if($duration =~ /^(\d+)w$/);
  $duration = $1 * 1440 if($duration =~ /^(\d+)d$/);
  $duration = $1 * 60 if($duration =~ /^(\d+)h$/);
  return $duration;
}

sub secToBriefTime {
  my $sec=shift;
  my @units=qw'y d h min s';
  my @amounts=(gmtime $sec)[5,7,2,1,0];
  $amounts[0]-=70;
  for my $i (0..$#units) {
    return $amounts[$i].$units[$i].'.' if($amounts[$i] > 0);
  }
  return '0s.';
}

sub secToTime {
  my $sec=shift;
  my @units=qw'year day hour minute second';
  my %unitsSeconds = (
    year => 31536000,
    day => 86400,
    hour => 3600,
    minute => 60,
    second => 1,
  );
  my @timeStrings;
  foreach my $unit (@units) {
    my $unitSeconds=$unitsSeconds{$unit};
    next unless($sec >= $unitSeconds);
    my $nbUnits=int($sec/$unitSeconds);
    push(@timeStrings,"$nbUnits $unit".($nbUnits>1?'s':''));
    $sec-=$nbUnits*$unitSeconds;
  }
  return '0 second' unless(@timeStrings);
  my $endString=pop(@timeStrings);
  return $endString unless(@timeStrings);
  return join(', ',@timeStrings).' and '.$endString;
}

sub secToDayAge {
  my $sec=shift;
  return 'Now' if($sec < 60);
  if($sec < 3600) {
    my $nbMin=int($sec/60);
    return "$nbMin min. ago";
  }
  if($sec < 86400) {
    my $nbHours=int($sec/3600);
    return "$nbHours hour".($nbHours > 1 ? 's' : '').' ago';
  }
  my $nbDays=int($sec/86400);
  return "Yesterday" if($nbDays < 2);
  return "$nbDays days ago";
}

sub realLength {
  my $s=shift;
  $s=~s/\d{1,2}(?:,\d{1,2})?//g;
  $s=~s/[]//g;
  return length($s);
}

sub formatList {
  my ($p_list,$maxLength)=@_;
  return '' unless(@{$p_list});
  return '...' if(realLength($p_list->[0]) > $maxLength || ($#{$p_list} > 0 && realLength("$p_list->[0]...") > $maxLength));
  my $result=$p_list->[0];
  for my $i (1..$#{$p_list}) {
    if($i == $#{$p_list}) {
      return "$result..." if(realLength("$result,$p_list->[$i]") > $maxLength);
    }else{
      return "$result..." if(realLength("$result,$p_list->[$i]...") > $maxLength);
    }
    $result.=",$p_list->[$i]";
  }
  return $result;
}

sub rightPadString {
  my ($string,$size)=@_;
  my $length=realLength($string);
  if($length < $size) {
    $string.=' 'x($size-$length);
  }elsif($length > $size) {
    $string=substr($string,0,$size-3);
    $string.='...';
  }
  return $string;
}

sub formatArray {
  my ($p_fields,$p_entries,$title,$maxLength)=@_;
  $title//='';
  $maxLength//=100;
  my @fields=@{$p_fields};
  my @entries=@{$p_entries};
  my @rows;
  my $rowLength=0;
  $#rows=$#entries+3;
  for my $i (0..$#rows) {
    $rows[$i]="";
  }
  for my $i (0..$#fields) {
    my $field=$fields[$i];
    my $length=getMaxLength($field,$p_entries);
    $length=$maxLength if($length > $maxLength);
    $rowLength+=$length;
    for my $j (0..$#rows) {
      if($j==0) {
        $rows[0].=rightPadString($field,$length);
      }elsif($j==1) {
        $rows[1].=('-' x $length);
      }elsif($j==$#rows) {
        $rows[$j].=('=' x $length);
      }elsif(exists $entries[$j-2]{$field} && defined $entries[$j-2]{$field}) {
        $rows[$j].=rightPadString($entries[$j-2]{$field},$length);
      }else{
        $rows[$j].=(' ' x $length);
      }
      if($i != $#fields) {
        if($j == $#rows) {
          $rows[$j].="==";
        }else{
          $rows[$j].="  ";
        }
      }
    }
  }
  if($title) {
    $rowLength+=$#fields * 2 if($#fields > 0);
    if(realLength($title) < $rowLength-3) {
      $title="[ $title ]";
      $title=(' ' x int(($rowLength-realLength($title))/2)).$title.(' ' x ceil(($rowLength-realLength($title))/2));
    }elsif(realLength($title) < $rowLength-1) {
      $title="[$title]";
      $title=(' ' x int(($rowLength-realLength($title))/2)).$title.(' ' x ceil(($rowLength-realLength($title))/2));
    }
    unshift(@rows,$title);
  }
  return \@rows;
}

sub getMaxLength {
  my ($field,$p_entries)=@_;
  my $length=realLength($field);
  foreach my $entry (@{$p_entries}) {
    if(exists $entry->{$field} && defined $entry->{$field} && realLength($entry->{$field}) > $length) {
      $length=realLength($entry->{$field});
    }
  }
  return $length;
}

sub formatNumber {
  my $n=shift;
  if(index($n,'.') != -1) {
    $n=sprintf('%.7f',$n);
    $n=~s/\.?0*$//;
  }
  $n=~s/^0+(\d.*)$/$1/;
  return $n;
}

sub formatInteger {
  my $n=shift;
  if($n >= 100000000) {
    $n=int($n / 1000000);
    $n.='M.';
  }elsif($n >= 100000) {
    $n=int($n / 1000);
    $n.='K.';
  }
  return $n;
}

sub isRange { return $_[0] =~ /^-?\d+(?:\.\d+)?--?\d+(?:\.\d+)?(?:\%\d+(?:\.\d+)?)?$/; }

sub getRangeStepFromBoundaries {
  my $maxNbDecimals=0;
  for my $boundaryValue (@_) {
    if($boundaryValue =~ /\.(\d+)$/) {
      my $nbDecimals=length($1);
      $maxNbDecimals=$nbDecimals if($nbDecimals > $maxNbDecimals);
    }
  }
  return 10**(-$maxNbDecimals);
}

sub matchRange {
  my ($range,$val)=@_;
  return 0 unless($val =~ /^-?\d+(?:\.\d+)?$/ && $val eq formatNumber($val));
  $range=~/^(-?\d+(?:\.\d+)?)-(-?\d+(?:\.\d+)?)(?:\%(\d+(?:\.\d+)?))?$/;
  my ($minValue,$maxValue)=($1,$2);
  my $stepValue=$3//getRangeStepFromBoundaries($minValue,$maxValue);
  return 0 unless($minValue <= $val && $val <= $maxValue);
  return 0 if($stepValue > 0 && ($val / $stepValue) !~ /^-?\d+$/);
  return 1;
}

sub limitLineSize {
  my ($p_data,$maxSize)=@_;
  return [] unless(@{$p_data});
  my @newData=([]);
  my $i=0;
  my $currentSize=0;
  foreach my $d (@{$p_data}) {
    if($currentSize == 0 || $currentSize+length($d)+1 <= $maxSize) {
      push(@{$newData[$i]},$d);
      $currentSize+=length($d)+1;
    }else{
      $newData[++$i]=[$d];
      $currentSize=length($d)+1;
    }
  }
  return \@newData;
}

sub hsvToRgb {
  my ($h,$s,$v)=@_;
  return (0,0,0) if($h < 0 || $h > 359 || $s < 0 || $s > 1 || $v < 0 || $v > 1);
  my $c=$v*$s;
  my $h1=$h/60;
  my $x=$c*(1-abs($h1 - int($h1/2)*2 - 1));
  my ($r,$g,$b);
  if($h1<1) {
    ($r,$g,$b)=($c,$x,0);
  }elsif($h1<2) {
    ($r,$g,$b)=($x,$c,0);
  }elsif($h1<3) {
    ($r,$g,$b)=(0,$c,$x);
  }elsif($h1<4) {
    ($r,$g,$b)=(0,$x,$c);
  }elsif($h1<5) {
    ($r,$g,$b)=($x,0,$c);
  }else{
    ($r,$g,$b)=($c,0,$x);
  }
  my $m=$v-$c;
  return (int(($r+$m)*255+0.5),int(($g+$m)*255+0.5),int(($b+$m)*255+0.5));
}

sub hslToRgb {
  my ($h,$s,$l)=@_;
  return (0,0,0) if($h < 0 || $h > 359 || $s < 0 || $s > 1 || $l < 0 || $l > 1);
  my $c=(1-abs(2*$l-1))*$s;
  my $h1=$h/60;
  my $x=$c*(1-abs($h1 - int($h1/2)*2 - 1));
  my ($r,$g,$b);
  if($h1<1) {
    ($r,$g,$b)=($c,$x,0);
  }elsif($h1<2) {
    ($r,$g,$b)=($x,$c,0);
  }elsif($h1<3) {
    ($r,$g,$b)=(0,$c,$x);
  }elsif($h1<4) {
    ($r,$g,$b)=(0,$x,$c);
  }elsif($h1<5) {
    ($r,$g,$b)=($x,0,$c);
  }else{
    ($r,$g,$b)=($c,0,$x);
  }
  my $m=$l-$c/2;
  return (int(($r+$m)*255+0.5),int(($g+$m)*255+0.5),int(($b+$m)*255+0.5));
}

sub generateBaseColorPanel {
  my ($s,$v)=@_;
  my @predefinedHues=(240,120,0,60,180,300,30,270,200,80,330,45,160,285);
  my @colors;
  foreach my $hue (@predefinedHues) {
    my ($r,$g,$b)=hsvToRgb($hue,$s,$v);
    push(@colors,{red => $r, green => $g, blue => $b});
  }
  return @colors;
} 

sub generateAdvancedColorPanel {
  my %colorDefs=( S => { red => {hue => 0,
                                 sv => { 1 => [[1,1]],
                                         2 => [[1,0.8],[0.6,1]],
                                         3 => [[1,1],[0.5,1],[1,0.6]]}},
                         yellow => {hue => 60,
                                    sv => { 1 => [[1,1]],
                                            2 => [[0.85,1],[1,0.7]],
                                            3 => [[0.8,1],[1,0.73],[1,0.49]]}},
                         green => {hue => 120,
                                   sv => { 1 => [[1,1]],
                                           2 => [[1,1],[1,0.65]],
                                           3 => [[1,0.85],[0.45,1],[1,0.55]]}},
                         cyan => {hue => 180,
                                  sv => { 1 => [[1,1]],
                                          2 => [[0.85,1],[1,0.65]],
                                          3 => [[0.7,1],[1,0.72],[1,0.51]]}},
                         blue => {hue => 220,
                                  sv => { 1 => [[1,1]],
                                          2 => [[1,0.7],[0.6,1]],
                                          3 => [[0.95,1],[0.5,1],[1,0.6]]}},
                         magenta => {hue => 300,
                                     sv => { 1 => [[1,1]],
                                             2 => [[1,0.75],[0.45,1]],
                                             3 => [[1,0.95],[0.45,1],[1,0.6]]}} },
                  M => { red => {hue => 0,
                                 sv => { 1 => [[1,1]],
                                         2 => [[1,0.8],[0.6,1]],
                                         3 => [[1,1],[0.55,1],[1,0.65]]}},
                         orange => {hue => 32,
                                    sv => { 1 => [[1,1]],
                                            2 => [[1,0.9],[0.65,1]],
                                            3 => [[1,1],[0.55,1],[1,0.67]]}},
                         yellow => {hue => 60,
                                    sv => { 1 => [[1,0.95]],
                                            2 => [[1,1],[1,0.73]],
                                            3 => [[0.85,1],[1,0.78],[1,0.5]]}},
                         green => {hue => 105,
                                   sv => { 1 => [[1,0.95]],
                                           2 => [[1,1],[1,0.65]],
                                           3 => [[1,0.93],[0.47,1],[1,0.65]]}},
                         teal => {hue => 165,
                                  sv => { 1 => [[1,0.7]],
                                          2 => [[1,0.85],[1,0.5]],
                                          3 => [[1,1],[1,0.75],[1,0.5]]}},
                         cyan => {hue => 190,
                                  sv => { 1 => [[1,1]],
                                          2 => [[0.85,1],[1,0.7]],
                                          3 => [[0.85,1],[1,0.77],[1,0.5]]}},
                         blue => {hue => 220,
                                  sv => { 1 => [[0.9,1]],
                                          2 => [[1,0.86],[0.6,1]],
                                          3 => [[1,1],[0.5,1],[1,0.7]]}},
                         purple => {hue => 272,
                                    sv => { 1 => [[0.95,1]],
                                            2 => [[1,0.85],[0.6,1]],
                                            3 => [[0.8,1],[0.45,1],[1,0.7]]}},
                         magenta => {hue => 310,
                                     sv => { 1 => [[1,1]],
                                             2 => [[1,0.85],[0.5,1]],
                                             3 => [[1,1],[0.45,1],[1,0.65]]}} },
                  L => { red => {hue => 0,
                                 sv => { 1 => [[1,1]],
                                         2 => [[1,0.8],[0.6,1]],
                                         3 => [[1,1],[0.55,1],[1,0.65]]}},
                         orange => {hue => 27,
                                    sv => { 1 => [[1,1]],
                                            2 => [[1,0.85],[0.65,1]],
                                            3 => [[1,1],[0.55,1],[1,0.67]]}},
                         gold => {hue => 45,
                                  sv => { 1 => [[1,1]],
                                          2 => [[1,0.8],[0.65,1]],
                                          3 => [[1,1],[0.55,1],[1,0.65]]}},
                         yellow => {hue => 60,
                                    sv => { 1 => [[1,1]],
                                            2 => [[0.85,1],[1,0.75]],
                                            3 => [[0.85,1],[1,0.78],[1,0.5]]}},
                         lime => {hue => 80,
                                  sv => { 1 => [[1,0.8]],
                                          2 => [[0.85,1],[1,0.8]],
                                          3 => [[0.85,1],[1,0.8],[1,0.5]]}},
                         green => {hue => 120,
                                   sv => { 1 => [[1,1]],
                                           2 => [[1,1],[1,0.65]],
                                           3 => [[1,0.93],[0.47,1],[1,0.65]]}},
                         teal => {hue => 160,
                                  sv => { 1 => [[1,0.7]],
                                          2 => [[1,0.85],[1,0.5]],
                                          3 => [[1,1],[1,0.75],[1,0.5]]}},
                         cyan => {hue => 185,
                                  sv => { 1 => [[1,1]],
                                          2 => [[0.85,1],[1,0.7]],
                                          3 => [[0.85,1],[1,0.77],[1,0.5]]}},
                         azure => {hue => 205,
                                   sv => { 1 => [[1,1]],
                                           2 => [[0.85,1],[1,0.65]],
                                           3 => [[1,0.95],[0.65,1],[1,0.65]]}},
                         blue => {hue => 240,
                                  sv => { 1 => [[1,1]],
                                          2 => [[1,0.8],[0.6,1]],
                                          3 => [[1,1],[0.55,1],[1,0.65]]}},
                         purple => {hue => 270,
                                    sv => { 1 => [[1,1]],
                                            2 => [[1,0.85],[0.6,1]],
                                            3 => [[1,1],[0.5,1],[1,0.65,275]]}},
                         magenta => {hue => 298,
                                     sv => { 1 => [[1,1]],
                                             2 => [[1,0.85],[0.5,1],],
                                             3 => [[1,1],[0.45,1],[1,0.65]]}},
                         pink => {hue => 325,
                                  sv => { 1 => [[0.9,0.85]],
                                          2 => [[1,0.85],[0.65,1]],
                                          3 => [[1,1],[0.55,1],[1,0.7]]}} } );
  my %grayDefs=(1 => [140],
                2 => [165,100],
                3 => [180,125,75]);

  foreach my $panelSize (qw'S M L') {
    for my $nbShades (1..3) {
      foreach my $colorName (keys %{$colorDefs{$panelSize}}) {
        my $r_colorDef=$colorDefs{$panelSize}{$colorName};
        for my $shadeNb (0..($nbShades-1)) {
          my ($hue,$s,$v,$hueOverride)=($r_colorDef->{hue},@{$r_colorDef->{sv}{$nbShades}[$shadeNb]});
          $hue=$hueOverride if(defined $hueOverride);
          my ($r,$g,$b)=hsvToRgb($hue,$s,$v);
          $advColors{$panelSize.$nbShades}{$colorName.($shadeNb+1)}={red => $r, green => $g, blue => $b};
        }
      }
    }
  }
  for my $nbShades (1..3) {
    for my $shadeNb (0..($nbShades-1)) {
      my $grayValue=$grayDefs{$nbShades}[$shadeNb];
      $advColors{'G'.$nbShades}{'gray'.($shadeNb+1)}={red => $grayValue, green => $grayValue, blue => $grayValue};
    }
  }

}

sub updateTargetMod {
  my $configuredModName=$spads->{hSettings}{modName};

  my ($modRegexp,$modRapidTag);
  if(substr($configuredModName,0,1) eq '~') {
    $modRegexp=substr($configuredModName,1);
  }elsif(substr($configuredModName,0,8) eq 'rapid://') {
    $modRapidTag=substr($configuredModName,8);
  }
  
  if(defined $modRapidTag) {
    my $cachedModRapidName=$rapidModResolutionCache{$modRapidTag};
    if(defined $cachedModRapidName) {
      $targetMod=$cachedModRapidName;
      return 1;
    }
  }else{
    if(%availableModsNameToNb) {
      my $newTargetMod;
      if(defined $modRegexp) {
        $newTargetMod = reduce {$b =~ /^$modRegexp$/ && (! defined $a || $b gt $a) ? $b : $a} (undef,keys %availableModsNameToNb);
      }elsif(exists $availableModsNameToNb{$configuredModName}) {
        $newTargetMod=$configuredModName;
      }
      if(defined $newTargetMod) {
        if(defined $cachedMods{$newTargetMod}) {
          $targetMod=$newTargetMod;
          return 1;
        }
        loadArchives(sub {quitAfterGame('Unable to reload Spring archives for mod change') unless(shift)},0,LOADARCHIVES_GAME_ONLY)
            unless($loadArchivesInProgress);
        return 2;
      }
      slog('Unable to find mod '.(defined $modRegexp ? "matching regular expression \"$modRegexp\"" : "\"$configuredModName\""),1);
      $targetMod='';
      return 0;
    }
    if(! defined $modRegexp && defined $cachedMods{$configuredModName}) {
      $targetMod=$configuredModName;
      return 1;
    }
  }
  
  loadArchives(sub {quitAfterGame('Unable to reload Spring archives for mod change') unless(shift)},0,LOADARCHIVES_GAME_ONLY)
      unless($loadArchivesInProgress);
  
  return 2;
}

sub pingIfNeeded {
  return unless($lobbyState > LOBBY_STATE_CONNECTING);
  my $delay=shift;
  $delay//=5;
  if( ( time - $timestamps{ping} > 5 && time - $lobby->{lastSndTs} > $delay )
      || ( time - $timestamps{ping} > 28 && time - $lobby->{lastRcvTs} > 28 ) ) {
    sendLobbyCommand([['PING']],5);
    $timestamps{ping}=time;
  }
}

sub fetchAndLogUnitsyncErrors {
  my $nbError=0;
  while(my $unitSyncErr=$unitsync->GetNextError()) {
    $nbError++;
    chomp($unitSyncErr);
    slog("unitsync error: $unitSyncErr",2);
  }
  return $nbError;
}

sub unitsyncGetPrimaryModName {
  my $modIdx=shift;
  my $nbModInfo = $unitsync->GetPrimaryModInfoCount($modIdx);
  for my $infoNb (0..($nbModInfo-1)) {
    return $unitsync->GetInfoValueString($infoNb) if($unitsync->GetInfoKey($infoNb) eq 'name');
  }
  return undef;
}

sub loadArchivesBlocking {
  my $mode=shift;

  my $usLockFile = catfile($conf{$conf{sequentialUnitsync} ? 'varDir' : 'instanceDir'},'unitsync.lock');
  open(my $usLockFh,'>',$usLockFile)
      or return {error => "Unable to write unitsync library lock file \"$usLockFile\" ($!)"};
  if(! flock($usLockFh, LOCK_EX|LOCK_NB)) {
    slog('Another process is using unitsync, waiting for lock...',3);
    if(! flock($usLockFh, LOCK_EX)) {
      close($usLockFh);
      return {error => "Unable to acquire unitsync library lock ($!)"};
    }
    slog('Unitsync library lock acquired',3);
  }

  if(! $unitsync->Init(0,0)) {
    fetchAndLogUnitsyncErrors();
    close($usLockFh);
    return {error => 'Unable to initialize UnitSync library'};
  }

  my $nbMods = $unitsync->GetPrimaryModCount();
  if($nbMods <= 0) {
    $unitsync->UnInit();
    close($usLockFh);
    return {error => 'No Spring mod found'};
  }
  
  my (@newAvailableMaps,%newCachedMaps);
  if(! ($mode & LOADARCHIVES_GAME_ONLY)) {
    my $nbMaps = $unitsync->GetMapCount();
    slog("No Spring map found",2) unless($nbMaps > 0);
    my %availableMapsByNames;
    my $nextProgressReportTs=time()+5;
    my $printProgressReport;
    for my $mapNb (0..($nbMaps-1)) {
      my $currentTime=time();
      if($currentTime >= $nextProgressReportTs) {
        $nextProgressReportTs=$currentTime+60;
        $printProgressReport=1;
        slog("Caching Spring map checksums... $mapNb/$nbMaps (".int(100*$mapNb/$nbMaps).'%)',3);
      }
      my $mapName = $unitsync->GetMapName($mapNb);
      if(! ($mode & LOADARCHIVES_RELOAD) && exists $availableMapsNameToNb{$mapName}) {
        $newAvailableMaps[$mapNb]=$availableMaps[$availableMapsNameToNb{$mapName}];
        $availableMapsByNames{$mapName}=$mapNb unless(exists $availableMapsByNames{$mapName});
        next;
      }
      my $mapChecksum = int32($unitsync->GetMapChecksum($mapNb));
      $unitsync->GetMapArchiveCount($mapName);
      my $mapArchive = $unitsync->GetMapArchiveName(0);
      $mapArchive=$1 if($mapArchive =~ /([^\\\/]+)$/);
      $newAvailableMaps[$mapNb]={name=>$mapName,hash=>$mapChecksum,archive=>$mapArchive};
      if(exists $availableMapsByNames{$mapName}) {
        slog("Duplicate archives found for map \"$mapName\" ($mapArchive)",2);
      }else{
        $availableMapsByNames{$mapName}=$mapNb;
      }
    }
    slog("Caching Spring map checksums... $nbMaps/$nbMaps (100%)",3) if($printProgressReport);
    $unitsync->RemoveAllArchives();

    my @invalidMapNbs;
    my @availableMapsNames=sort keys %availableMapsByNames;
    my $p_uncachedMapsNames = $spads->getUncachedMaps(\@availableMapsNames);
    if(@{$p_uncachedMapsNames}) {
      my $nbUncachedMaps=$#{$p_uncachedMapsNames}+1;
      $nextProgressReportTs=time()+5;
      $printProgressReport=0;
      for my $uncachedMapNb (0..($#{$p_uncachedMapsNames})) {
        my $currentTime=time();
        if($currentTime >= $nextProgressReportTs) {
          $nextProgressReportTs=$currentTime+60;
          $printProgressReport=1;
          slog("Caching Spring map info... $uncachedMapNb/$nbUncachedMaps (".int(100*$uncachedMapNb/$nbUncachedMaps).'%)',3);
        }
        my $mapName=$p_uncachedMapsNames->[$uncachedMapNb];
        my $mapNb=$availableMapsByNames{$mapName};
        $newCachedMaps{$mapName}={startPos => [],
                                  options => {}};
        if($unitsyncOptFuncs{GetMapInfoCount}) {
          my $nbMapInfo=$unitsync->GetMapInfoCount($mapNb);
          if($nbMapInfo < 0) {
            fetchAndLogUnitsyncErrors();
            slog("Unable to get map info for \"$mapName\", ignoring map.",2);
            push(@invalidMapNbs,$mapNb);
            delete $newCachedMaps{$mapName};
            $unitsync->RemoveAllArchives();
            next;
          }
          for my $infoNb (0..($nbMapInfo-1)) {
            my $mapInfoKey=$unitsync->GetInfoKey($infoNb);
            if($mapInfoKey eq 'width') {
              $newCachedMaps{$mapName}{width}=$unitsync->GetInfoValueInteger($infoNb);
            }elsif($mapInfoKey eq 'height') {
              $newCachedMaps{$mapName}{height}=$unitsync->GetInfoValueInteger($infoNb);
            }elsif($mapInfoKey eq 'xPos') {
              push(@{$newCachedMaps{$mapName}{startPos}},[$unitsync->GetInfoValueFloat($infoNb)]);
            }elsif($mapInfoKey eq 'zPos') {
              if(! @{$newCachedMaps{$mapName}{startPos}}
                 || $#{$newCachedMaps{$mapName}{startPos}[-1]} != 0) {
                $unitsync->UnInit();
                $spads->cacheMapsInfo({}) if($spads->{sharedDataTs}{mapInfoCache}); # release lock
                close($usLockFh);
                return {error => "Inconsistentcy in start position data for map $mapName"};
              }
              push(@{$newCachedMaps{$mapName}{startPos}[-1]},$unitsync->GetInfoValueFloat($infoNb));
            }
          }
        }else{
          $newCachedMaps{$mapName}{width}=$unitsync->GetMapWidth($mapNb);
          if($newCachedMaps{$mapName}{width} < 0) {
            fetchAndLogUnitsyncErrors();
            slog("Unable to get map info for \"$mapName\", ignoring map.",2);
            push(@invalidMapNbs,$mapNb);
            delete $newCachedMaps{$mapName};
            $unitsync->RemoveAllArchives();
            next;
          }
          $newCachedMaps{$mapName}{height}=$unitsync->GetMapHeight($mapNb);
          my $nbStartPos=$unitsync->GetMapPosCount($mapNb);
          for my $startPosNb (0..($nbStartPos-1)) {
            push(@{$newCachedMaps{$mapName}{startPos}},[$unitsync->GetMapPosX($mapNb,$startPosNb),$unitsync->GetMapPosZ($mapNb,$startPosNb)]);
          }
        }
        $newCachedMaps{$mapName}{nbStartPos}=$#{$newCachedMaps{$mapName}{startPos}}+1;
        $unitsync->AddAllArchives($newAvailableMaps[$mapNb]{archive});
        my $nbMapOptions = $unitsync->GetMapOptionCount($mapName);
        for my $optionIdx (0..($nbMapOptions-1)) {
          my %option=(name => $unitsync->GetOptionName($optionIdx),
                      key => $unitsync->GetOptionKey($optionIdx),
                      description => $unitsync->GetOptionDesc($optionIdx),
                      type => $OPTION_TYPES[$unitsync->GetOptionType($optionIdx)],
                      section => $unitsync->GetOptionSection($optionIdx),
                      default => "");
          next if($option{type} eq "error" || $option{type} eq "section");
          $option{description}=~s/\n/ /g;
          if($option{type} eq "bool") {
            $option{default}=$unitsync->GetOptionBoolDef($optionIdx);
          }elsif($option{type} eq "number") {
            $option{default}=formatNumber($unitsync->GetOptionNumberDef($optionIdx));
            $option{numberMin}=formatNumber($unitsync->GetOptionNumberMin($optionIdx));
            $option{numberMax}=formatNumber($unitsync->GetOptionNumberMax($optionIdx));
            $option{numberStep}=formatNumber($unitsync->GetOptionNumberStep($optionIdx));
            if($option{numberStep} < 0) {
              slog("Invalid step value \"$option{numberStep}\" for number range (map option: \"$option{key}\")",2);
              $option{numberStep}=0;
            }
          }elsif($option{type} eq "string") {
            $option{default}=$unitsync->GetOptionStringDef($optionIdx);
            $option{stringMaxLen}=$unitsync->GetOptionStringMaxLen($optionIdx);
          }elsif($option{type} eq "list") {
            $option{default}=$unitsync->GetOptionListDef($optionIdx);
            $option{listCount}=$unitsync->GetOptionListCount($optionIdx);
            $option{list}={};
            for my $listIdx (0..($option{listCount}-1)) {
              my %item=(name => $unitsync->GetOptionListItemName($optionIdx,$listIdx),
                        description => $unitsync->GetOptionListItemDesc($optionIdx,$listIdx),
                        key => $unitsync->GetOptionListItemKey($optionIdx,$listIdx));
              $item{description}=~s/\n/ /g;
              $option{list}{$item{key}}=\%item;
            }
          }
          $newCachedMaps{$mapName}{options}{$option{key}}=\%option;
        }
        $unitsync->RemoveAllArchives();
      }
      slog("Caching Spring map info... $nbUncachedMaps/$nbUncachedMaps (100%)",3) if($printProgressReport);
      $spads->cacheMapsInfo(\%newCachedMaps) if($spads->{sharedDataTs}{mapInfoCache});
    }
    {
      my $offset=0;
      splice(@newAvailableMaps,$_-$offset++,1) foreach(@invalidMapNbs);
    }
  }

  my $configuredModName=$spads->{hSettings}{modName};
  
  my ($newTargetMod,$targetModIdx,%availableModsByNames);
  if(substr($configuredModName,0,1) eq '~') {
    my $modRegexp=substr($configuredModName,1);
    for my $modIdx (0..($nbMods-1)) {
      my $modName=unitsyncGetPrimaryModName($modIdx);
      if(! defined $modName) {
        slog("Failed to determine name of mod \#$modIdx",2);
        next;
      }
      if(exists $availableModsByNames{$modName}) {
        slog("Duplicate archives found for mod \"$modName\"",2);
        next;
      }
      $availableModsByNames{$modName}=$modIdx;
      ($newTargetMod,$targetModIdx)=($modName,$modIdx)
          if($modName =~ /^$modRegexp$/ && (! defined $newTargetMod || $modName gt $newTargetMod));
    }
    slog("Unable to find mod matching regular expression \"$modRegexp\"",1) unless(defined $newTargetMod);
  }else{
    my $resolvedModName;
    if($configuredModName =~ /^rapid:\/\/([\w\-]+):(\w+)$/) {
      my ($rapidIdent,$rapidRelease)=($1,$2);
      my $rapidTag=substr($configuredModName,8);
      my $rapidTagAndComma=$rapidTag.',';
      my $lengthOfRapidTagAndComma=length($rapidTag)+1;
      my @dataDirs=splitPaths($conf{springDataDir});
      DATADIR_LOOP: foreach my $dataDir (@dataDirs) {
        my $rapidDir=catdir($dataDir,'rapid');
        next unless(-d $rapidDir);
        my $rapidDh;
        if(! opendir($rapidDh,$rapidDir)) {
          slog("Failed to open data directory \"$rapidDir\" ($!)",2);
          next;
        }
        my @rapidReposContainingIdentVersions = sort {
          getModifTime("$rapidDir/$b/$rapidIdent/versions.gz") <=> getModifTime("$rapidDir/$a/$rapidIdent/versions.gz")
        } (grep {substr($_,0,1) ne '.' && -f "$rapidDir/$_/$rapidIdent/versions.gz"} readdir($rapidDh));
        close($rapidDh);
        foreach my $rapidRepo (@rapidReposContainingIdentVersions) {
          my $versionsGzFile=catfile($rapidDir,$rapidRepo,$rapidIdent,'versions.gz');
          my $versionsFh=IO::Uncompress::Gunzip->new($versionsGzFile, Transparent => 0);
          if(! defined $versionsFh) {
            slog("Failed to open compressed rapid versions file \"$versionsGzFile\": ".($GunzipError||'unrecognized compression'),2);
            next;
          }
          while(my $versionLine=<$versionsFh>) {
            next unless(substr($versionLine,0,$lengthOfRapidTagAndComma) eq $rapidTagAndComma);
            chomp($versionLine);
            my $gameName=(split(/,/,$versionLine,4))[3];
            if(defined $gameName && $gameName ne '') {
              $resolvedModName=$gameName;
              close($versionsFh);
              last DATADIR_LOOP;
            }
            slog("Missing game name field for rapid tag \"$rapidTag\" in rapid versions file \"$versionsGzFile\"",2);
            last;
          }
          close($versionsFh);
        }
      }
      slog("Unable to resolve mod version for rapid tag \"$rapidTag\"",1) unless(defined $resolvedModName);
    }else{
      $resolvedModName=$configuredModName;
    }
    if(defined $resolvedModName) {
      my $modIdx=$unitsync->GetPrimaryModIndex($resolvedModName);
      if($modIdx<0) {
        slog("Mod \"$resolvedModName\" not found",1);
      }else{
        ($newTargetMod,$targetModIdx)=($resolvedModName,$modIdx);
      }
    }
  }
  $unitsync->RemoveAllArchives();

  my %modInfo;
  if(defined $targetModIdx) {
    my $modChecksum = int32($unitsync->GetPrimaryModChecksum($targetModIdx));
    if(! ($mode & LOADARCHIVES_RELOAD) && $modChecksum && exists $cachedMods{$newTargetMod} && $cachedMods{$newTargetMod}{hash} && $modChecksum == $cachedMods{$newTargetMod}{hash}) {
      $unitsync->UnInit();
      close($usLockFh);
      return {availableMaps => \@newAvailableMaps, newCachedMaps => \%newCachedMaps, targetMod => $newTargetMod, availableModsNameToNb => \%availableModsByNames};
    }
    %modInfo = ( name => $newTargetMod, hash => $modChecksum, archive => $unitsync->GetPrimaryModArchive($targetModIdx), options => {}, sides => [] );
    $unitsync->AddAllArchives($modInfo{archive});
    my $nbModOptions = $unitsync->GetModOptionCount();
    fetchAndLogUnitsyncErrors() if($nbModOptions < 0);
    for my $optionIdx (0..($nbModOptions-1)) {
      my %option=(name => $unitsync->GetOptionName($optionIdx),
                  key => $unitsync->GetOptionKey($optionIdx),
                  description => $unitsync->GetOptionDesc($optionIdx),
                  type => $OPTION_TYPES[$unitsync->GetOptionType($optionIdx)],
                  section => $unitsync->GetOptionSection($optionIdx),
                  default => "");
      next if($option{type} eq "error" || $option{type} eq "section");
      $option{description}=~s/\n/ /g;
      if($option{type} eq "bool") {
        $option{default}=$unitsync->GetOptionBoolDef($optionIdx);
      }elsif($option{type} eq "number") {
        $option{default}=formatNumber($unitsync->GetOptionNumberDef($optionIdx));
        $option{numberMin}=formatNumber($unitsync->GetOptionNumberMin($optionIdx));
        $option{numberMax}=formatNumber($unitsync->GetOptionNumberMax($optionIdx));
        $option{numberStep}=formatNumber($unitsync->GetOptionNumberStep($optionIdx));
        if($option{numberStep} < 0) {
          slog("Invalid step value \"$option{numberStep}\" for number range (mod option: \"$option{key}\")",2);
          $option{numberStep}=0;
        }
      }elsif($option{type} eq "string") {
        $option{default}=$unitsync->GetOptionStringDef($optionIdx);
        $option{stringMaxLen}=$unitsync->GetOptionStringMaxLen($optionIdx);
      }elsif($option{type} eq "list") {
        $option{default}=$unitsync->GetOptionListDef($optionIdx);
        $option{listCount}=$unitsync->GetOptionListCount($optionIdx);
        $option{list}={};
        for my $listIdx (0..($option{listCount}-1)) {
          my %item=(name => $unitsync->GetOptionListItemName($optionIdx,$listIdx),
                    description => $unitsync->GetOptionListItemDesc($optionIdx,$listIdx),
                    key => $unitsync->GetOptionListItemKey($optionIdx,$listIdx));
          $item{description}=~s/\n/ /g;
          $option{list}{$item{key}}=\%item;
        }
      }
      $modInfo{options}{$option{key}}=\%option;
    }
    my $nbModSides = $unitsync->GetSideCount();
    for my $sideIdx (0..($nbModSides-1)) {
      my $sideName = $unitsync->GetSideName($sideIdx);
      $modInfo{sides}[$sideIdx]=$sideName;
    }
    $unitsync->RemoveAllArchives();
  }

  $unitsync->UnInit();
  close($usLockFh);
  return {availableMaps => \@newAvailableMaps, newCachedMaps => \%newCachedMaps, targetMod => $newTargetMod, modData => \%modInfo, availableModsNameToNb => \%availableModsByNames};
}

sub loadArchivesPostActions {
  my ($r_loadArchivesResult,$configuredModNameDuringReload,$printModUpdateMsg,$mode)=@_;

  chdir($CWD);

  $loadArchivesInProgress=0;

  my $loadArchivesDurationInSeconds=time-$timestamps{archivesLoad};
  my $loadArchivesDuration=secToTime($loadArchivesDurationInSeconds);
  my $loadArchivesMsgLogLevel=5;
  if($loadArchivesDurationInSeconds > 30) {
    $loadArchivesMsgLogLevel=2;
  }elsif($loadArchivesDurationInSeconds > 15) {
    $loadArchivesMsgLogLevel=3;
  }elsif($loadArchivesDurationInSeconds > 5) {
    $loadArchivesMsgLogLevel=4;
  }
  slog("Spring archives loading process took $loadArchivesDuration",$loadArchivesMsgLogLevel);

  my $errorMsg;
  if(! ref $r_loadArchivesResult) {
    $errorMsg='Unitsync library crash ?';
  }elsif(defined $r_loadArchivesResult->{error}) {
    $errorMsg=$r_loadArchivesResult->{error};
  }
  if(defined $errorMsg) {
    slog("Failed to load archives - $errorMsg",1);
    return 0;
  }

  my $nbMapsLoaded;
  if($mode & LOADARCHIVES_GAME_ONLY) {
    $nbMapsLoaded=0;
  }else{
    @availableMaps=@{$r_loadArchivesResult->{availableMaps}};
    $nbMapsLoaded=@availableMaps;
    
    %availableMapsNameToNb=();
    for my $mapNb (0..$#availableMaps) {
      $availableMapsNameToNb{$availableMaps[$mapNb]{name}}=$mapNb unless(exists $availableMapsNameToNb{$availableMaps[$mapNb]{name}});
    }
    
    if($spads->{sharedDataTs}{mapInfoCache}) {
      $spads->refreshSharedDataIfNeeded('mapInfoCache');
    }else{
      my $r_newCachedMaps=$r_loadArchivesResult->{newCachedMaps};
      $spads->cacheMapsInfo($r_newCachedMaps) if(%{$r_newCachedMaps});
    }

    $timestamps{mapLearned}=0;
    $spads->applyMapList(\@availableMaps,$syncedSpringVersion);

  }

  %availableModsNameToNb=%{$r_loadArchivesResult->{availableModsNameToNb}};
  %rapidModResolutionCache=();

  my $nbArchivesLoaded;
  my $newTargetMod=$r_loadArchivesResult->{targetMod};
  if(defined $newTargetMod) {
    %rapidModResolutionCache=(substr($configuredModNameDuringReload,8) => $newTargetMod)
        if(substr($configuredModNameDuringReload,0,8) eq 'rapid://');
    my $r_modData=$r_loadArchivesResult->{modData};
    $cachedMods{$newTargetMod}=$r_modData if(defined $r_modData); # modData is only defined when a new uncached mod is selected
    $nbArchivesLoaded = $nbMapsLoaded + (scalar(%availableModsNameToNb) || 1);
  }else{
    $nbArchivesLoaded = ($nbMapsLoaded + %availableModsNameToNb) || 1;
  }
  
  if($configuredModNameDuringReload eq $spads->{hSettings}{modName}) {
    if(defined $newTargetMod) {
      if($newTargetMod ne $targetMod) {
        broadcastMsg("New version of current mod detected ($newTargetMod), switching when battle is empty (use !rehost to force)")
            if($printModUpdateMsg && $lobbyState >= LOBBY_STATE_BATTLE_OPENED && $lobby->{battles}{$lobby->{battle}{battleId}}{mod} ne $newTargetMod);
        $targetMod=$newTargetMod;
      }
    }else{
      $targetMod='';
    }
  }else{
    updateTargetMod();
  }

  return $nbArchivesLoaded;
}

sub loadArchives {
  my ($r_callback,$printModUpdateMsg,$mode)=@_;
  $mode//=LOADARCHIVES_DEFAULT;
  $loadArchivesInProgress=1;
  my $currentTime=time;
  $timestamps{archivesLoad}=$currentTime;
  $timestamps{archivesLoadFull}=$currentTime unless($mode & LOADARCHIVES_GAME_ONLY);
  $timestamps{archivesCheck}=$currentTime;
  my $configuredModName=$spads->{hSettings}{modName};
  if(defined $r_callback) {
    if(! SimpleEvent::forkCall(
           sub { loadArchivesBlocking($mode) },
           sub { $r_callback->(loadArchivesPostActions($_[0],$configuredModName,$printModUpdateMsg,$mode)) }
           ) ) {
      $r_callback->(loadArchivesPostActions({error => 'Failed to fork for asynchronous Spring archives reload!'},$configuredModName,$printModUpdateMsg,$mode));
    }
  }else{
    return loadArchivesPostActions(loadArchivesBlocking($mode),$configuredModName,$printModUpdateMsg,$mode);
  }
}

sub setDefaultMapOfMaplist {
  my $p_maps=$spads->applySubMapList();
  if(@{$p_maps}) {
    $spads->{conf}{map}=$p_maps->[0];
    $conf{map}=$p_maps->[0];
  }
}

sub getMapHash {
  my $mapName=shift;
  return $availableMaps[$availableMapsNameToNb{$mapName}]{hash} if(exists $availableMapsNameToNb{$mapName});
  return $spads->getMapHash($mapName,$syncedSpringVersion);
}

sub getMapHashAndArchive {
  my $mapName=shift;
  if(exists $availableMapsNameToNb{$mapName}) {
    my $mapNb=$availableMapsNameToNb{$mapName};
    return (uint32($availableMaps[$mapNb]{hash}),$availableMaps[$mapNb]{archive});
  }
  return (uint32($spads->getMapHash($mapName,$syncedSpringVersion)),'');
}

sub getModHash {
  my $modName=shift;
  return ($modName ne '' && exists $cachedMods{$modName}) ? $cachedMods{$modName}{hash} : 0;
}

sub getModOptions {
  my $modName=shift;
  return ($modName ne '' && exists $cachedMods{$modName}) ? $cachedMods{$modName}{options} : {};
}

sub getModSides {
  my $modName=shift;
  return ($modName ne '' && exists $cachedMods{$modName}) ? $cachedMods{$modName}{sides} : [];
}

sub getMapOptions {
  my $mapName=shift;
  my $p_mapInfo=$spads->getCachedMapInfo($mapName);
  my $p_mapOptions={};
  $p_mapOptions=$p_mapInfo->{options} if(defined $p_mapInfo);
  return $p_mapOptions;
}

sub formatMemSize {
  my $rawMem=shift;
  return '' unless(defined $rawMem && $rawMem =~ /^\d+$/);
  return "$rawMem Bytes" if($rawMem < 1024);
  return (sprintf('%.2f',$rawMem/1024)+0).' kB' if(sprintf('%.2f',$rawMem/(1024 ** 2)) < 1);
  return (sprintf('%.2f',$rawMem/(1024 ** 2))+0).' MB' if(sprintf('%.2f',$rawMem/(1024 ** 3)) < 1);
  return (sprintf('%.2f',$rawMem/(1024 ** 3))+0).' GB';
}

sub getSysInfo {
  my ($osVersion,$memAmount,$uptime)=('','',0);
  my @uname=uname();
  if(MSWIN32) {
    $osVersion=Win32::GetOSName();
    $osVersion.=" - $uname[0] $uname[2] - $uname[3]";
    
    Win32::API::Struct->typedef(
      MEMORYSTATUS => qw{
        DWORD Length;
        DWORD MemLoad;
        DWORD TotalPhys;
        DWORD AvailPhys;
        DWORD TotalPage;
        DWORD AvailPage;
        DWORD TotalVirtual;
        DWORD AvailVirtual;
      }
    );
    Win32::API::Struct->typedef(
      MEMORYSTATUSEX => qw{
        DWORD Length;
        DWORD MemLoad;
        DWORD64 TotalPhys;
        DWORD64 AvailPhys;
        DWORD64 TotalPage;
        DWORD64 AvailPage;
        DWORD64 TotalVirtual;
        DWORD64 AvailVirtual;
        DWORD64 AvailExtendedVirtual;
      }
    );
    if(Win32::API->Import( 'kernel32', 'BOOL GlobalMemoryStatusEx(LPMEMORYSTATUSEX lpMemoryStatus)' )) {
      my $memStatus = Win32::API::Struct->new('MEMORYSTATUSEX');
      $memStatus->align('auto');
      $memStatus->{'Length'}     = $memStatus->sizeof();
      $memStatus->{'MemLoad'}      = 0;
      $memStatus->{'TotalPhys'}    = 0;
      $memStatus->{'AvailPhys'}    = 0;
      $memStatus->{'TotalPage'}    = 0;
      $memStatus->{'AvailPage'}    = 0;
      $memStatus->{'TotalVirtual'} = 0;
      $memStatus->{'AvailVirtual'} = 0;
      $memStatus->{'AvailExtendedVirtual'} = 0;
      my $callResult=GlobalMemoryStatusEx($memStatus);
      if($callResult) {
        $memAmount=formatMemSize($memStatus->{'TotalPhys'});
      }else{
        slog('Unable to retrieve total physical memory through GlobalMemoryStatusEx function (Win32 API error: '.(getLastWin32Error()).')',2);
      }
    }elsif(Win32::API->Import( 'kernel32', 'VOID GlobalMemoryStatus(LPMEMORYSTATUS lpMemoryStatus)' )) {
      my $memStatus = Win32::API::Struct->new('MEMORYSTATUS');
      $memStatus->align('auto');
      $memStatus->{'Length'}     = 0;
      $memStatus->{'MemLoad'}      = 0;
      $memStatus->{'TotalPhys'}    = 0;
      $memStatus->{'AvailPhys'}    = 0;
      $memStatus->{'TotalPage'}    = 0;
      $memStatus->{'AvailPage'}    = 0;
      $memStatus->{'TotalVirtual'} = 0;
      $memStatus->{'AvailVirtual'} = 0;
      GlobalMemoryStatus($memStatus);
      if($memStatus->{Length} != 0) {
        $memAmount=formatMemSize($memStatus->{'TotalPhys'});
      }else{
        slog('Unable to retrieve total physical memory through GlobalMemoryStatus function (Win32 API)',2);
      }
    }else{
      slog('Unable to import GlobalMemoryStatusEx and GlobalMemoryStatus from kernel32.dll ('.getLastWin32Error().')',2);
    }

    $uptime=int(Win32::GetTickCount() / 1000);
  }elsif(DARWIN) {
    $osVersion.=$MACOS_SYSTEM_INFO{ProductName}.' ' if(defined $MACOS_SYSTEM_INFO{ProductName});
    $osVersion.=$MACOS_SYSTEM_INFO{ProductVersion}.' ' if(defined $MACOS_SYSTEM_INFO{ProductVersion});
    $osVersion.="- Build $MACOS_SYSTEM_INFO{BuildVersion}" if(defined $MACOS_SYSTEM_INFO{BuildVersion});
    my $kernelVersion="$uname[0] $uname[2]";
    if($kernelVersion ne ' ') {
      if($osVersion ne '') {
        $osVersion.=" [$kernelVersion]";
      }else{
        $osVersion=$kernelVersion;
      }
    }
    $memAmount=formatMemSize($MACOS_SYSTEM_INFO{'hw.memsize'});
    $uptime=time()-$1 if(defined $MACOS_SYSTEM_INFO{'kern.boottime'} && $MACOS_SYSTEM_INFO{'kern.boottime'} =~ /\bsec\s*=\s*(\d+)/);
  }else{
    my $r_osReleaseContent=fileToArray('/etc/os-release');
    if(defined $r_osReleaseContent && @{$r_osReleaseContent}) {
      my %osReleaseContent;
      foreach my $osReleaseLine (@{$r_osReleaseContent}) {
        if($osReleaseLine =~ /^\s*([^\s]+)\s*=\s*(.*[^\s])\s*$/) {
          my ($infoKey,$infoVal)=($1,$2);
          $infoVal=$2 if($infoVal =~ /^([\"\'])(.+)\1$/);
          $osReleaseContent{$infoKey}=$infoVal;
        }
      }
      if(defined $osReleaseContent{PRETTY_NAME}) {
        $osVersion=$osReleaseContent{PRETTY_NAME};
      }elsif(defined $osReleaseContent{NAME}) {
        $osVersion=$osReleaseContent{NAME};
        $osVersion.=" $osReleaseContent{VERSION}" if(defined $osReleaseContent{VERSION});
      }elsif(defined $osReleaseContent{ID}) {
        $osVersion=$osReleaseContent{ID};
        $osVersion.=" $osReleaseContent{VERSION_ID}" if(defined $osReleaseContent{VERSION_ID});
      }
    }
    my $kernelVersion="$uname[0] $uname[2]";
    if($kernelVersion ne ' ') {
      if($osVersion ne '') {
        $osVersion.=" [$kernelVersion]";
      }else{
        $osVersion=$kernelVersion;
      }
    }
    my $r_memInfoContent=fileToArray('/proc/meminfo');
    if(defined $r_memInfoContent) {
      foreach my $line (@{$r_memInfoContent}) {
        if($line =~ /^\s*MemTotal\s*:\s*(\d+\s*\w+)$/) {
          $memAmount=$1;
          last;
        }
      }
    }
    my $r_uptimeContent=fileToArray('/proc/uptime');
    $uptime=$1 if(defined $r_uptimeContent && @{$r_uptimeContent} && $r_uptimeContent->[0] =~ /^\s*(\d+)/);
  }
  my ($procName,$origin);
  if(MSWIN32) {
    $origin='from Windows registry';
    eval {
      if(my $regLMachine=new Win32::TieRegistry('LMachine', { Access => KEY_READ() })) {
        $regLMachine->Delimiter('/');
        my $cpuInfo=$regLMachine->Open('Hardware/Description/System/CentralProcessor/0', { Access => KEY_READ() });
        $procName=$cpuInfo->GetValue('ProcessorNameString') if(defined $cpuInfo);
      }
    };
    slog("Failed to access Windows registry: $@",2) if(hasEvalError());
  }elsif(DARWIN) {
    $origin='using sysctl command';
    $procName=$MACOS_SYSTEM_INFO{'machdep.cpu.brand_string'} if(exists $MACOS_SYSTEM_INFO{'machdep.cpu.brand_string'});
  }elsif(-f '/proc/cpuinfo' && -r _) {
    $origin='from /proc/cpuinfo';
    my $r_cpuInfo=fileToArray('/proc/cpuinfo');
    if(defined $r_cpuInfo) {
      my %cpu;
      foreach my $line (@{$r_cpuInfo}) {
        $cpu{$1}=$2 if($line =~ /^([\w\s]*\w)\s*:\s*(.*)$/);
      }
      $procName=$cpu{'model name'} if(exists $cpu{'model name'});
    }
  }else{
    $origin='(unknown system)';
  }
  slog("Unable to retrieve CPU info $origin",2) unless(defined $procName);
  return ($osVersion,$memAmount,$uptime,$procName);
}

sub fileToArray {
  my $filePath=shift;
  return undef unless(-f $filePath && -r _);
  if(open(my $fh,'<',$filePath)) {
    chomp(my @lines=<$fh>);
    close($fh);
    return \@lines;
  }
  slog("Failed to open file \"$filePath\" for reading: $!",2);
  return undef;
}

sub getLocalLanIp {
  my @ips;
  if(MSWIN32) {
    my $netIntsEntry;
    eval {
      if(my $regLMachine=new Win32::TieRegistry('LMachine', { Access => KEY_READ() })) {
        $regLMachine->Delimiter('/');
        $netIntsEntry=$regLMachine->Open('System/CurrentControlSet/Services/Tcpip/Parameters/Interfaces/', { Access => KEY_READ() });
      }
    };
    slog("Failed to access Windows registry: $@",2) if(hasEvalError());
    if(defined $netIntsEntry) {
      eval {
        my @interfaces=$netIntsEntry->SubKeyNames();
        foreach my $interface (@interfaces) {
          my $netIntEntry=$netIntsEntry->Open($interface, { Access => KEY_READ() });
          my $ipAddr=$netIntEntry->GetValue("IPAddress");
          if(defined $ipAddr && $ipAddr =~ /(\d+\.\d+\.\d+\.\d+)/) {
            push(@ips,$1);
          }else{
            $ipAddr=$netIntEntry->GetValue("DhcpIPAddress");
            push(@ips,$1) if(defined $ipAddr && $ipAddr =~ /(\d+\.\d+\.\d+\.\d+)/);
          }
        }
      };
      slog("Failed to access Windows registry: $@",2) if(hasEvalError());
    }else{
      slog("Unable to find network interfaces in registry, trying ipconfig workaround...",2);
      my @ipConfOut=`ipconfig`;
      foreach my $line (@ipConfOut) {
        next unless($line =~ /IP.*\:\s*(\d+\.\d+\.\d+\.\d+)\s/);
        push(@ips,$1);
      }
    }
  }else{
    $ENV{LANG}='C';
    my $ifconfigBin;
    if(-x '/sbin/ifconfig') {
      $ifconfigBin='/sbin/ifconfig';
    }elsif(-x '/usr/sbin/ifconfig') {
      $ifconfigBin='/usr/sbin/ifconfig';
    }else{
      $ifconfigBin=can_run('ifconfig');
    }
    my @ipConfOut;
    if(defined $ifconfigBin) {
      @ipConfOut=`$ifconfigBin`;
    }elsif(can_run('ip')) {
      @ipConfOut=`ip addr`;
    }else{
      slog('Unable to find "ifconfig" or "ip" utilities to retrieve LAN IP addresses',2);
    }
    foreach my $line (@ipConfOut) {
      push(@ips,$1) if($line =~ /inet\s(?:addr:)?\s*(\d+\.\d+\.\d+\.\d+)/);
    }
  }
  foreach my $ip (@ips) {
    if($ip =~ /^10\./ || $ip =~ /^192\.168\./) {
      slog("Following local LAN IP address detected: $ip",4);
      return $ip;
    }
    if($ip =~ /^172\.(\d+)\./) {
      if($1 > 15 && $1 < 32) {
        slog("Following local LAN IP address detected: $ip",4);
        return $ip;
      }
    }
  }
  slog("No local LAN IP address found",4);
  return "*";
}

sub getModifTime { (stat($_[0]))[9] // 0 }

sub getArchivesChangeTime {
  my @dataDirs=splitPaths($conf{springDataDir});
  my $archivesChangeTs=0;
  my $rapidId;
  $rapidId=$1 if($spads->{hSettings}{modName} =~ /^rapid:\/\/([\w\-]+):/);
  foreach my $dataDir (@dataDirs) {
    foreach my $dataSubDir (qw'base games maps packages') {
      my $dirChangeTs=getModifTime("$dataDir/$dataSubDir");
      $archivesChangeTs=$dirChangeTs if($dirChangeTs > $archivesChangeTs);
    }
    next unless(defined $rapidId);
    my $rapidDir="$dataDir/rapid";
    next unless(-d $rapidDir);
    my $rapidDh;
    next unless(opendir($rapidDh,$rapidDir));
    my @rapidReposWithMatchingVersionsGz = grep {substr($_,0,1) ne '.' && -f "$rapidDir/$_/$rapidId/versions.gz"} readdir($rapidDh);
    close($rapidDh);
    foreach my $rapidRepo (@rapidReposWithMatchingVersionsGz) {
      my $versionsGzChangeTs=getModifTime("$rapidDir/$rapidRepo/$rapidId/versions.gz");
      $archivesChangeTs=$versionsGzChangeTs if($versionsGzChangeTs > $archivesChangeTs);
    }
  }
  return $archivesChangeTs;
}

sub isQuitActionApplicable {
  my ($action,$condition)=@_;
  return 1 if(defined $quitAfterGame{action} != defined $action);
  return 0 if(! defined $action);
  return $action < $quitAfterGame{action} || $condition < $quitAfterGame{condition};
}

sub isRestartForUpdateApplicable {
  return 0 if($conf{autoRestartForUpdate} eq 'off');
  return isQuitActionApplicable(1,{on => 0, whenOnlySpec => 1, whenEmpty => 2}->{$conf{autoRestartForUpdate}});
}

sub applyQuitAction {
  my ($action,$condition,$reason,$exitCode)=@_;
  $exitCode//=EXIT_SUCCESS;
  return 0 unless(isQuitActionApplicable($action,$condition));
  if(defined $action) {
    $quitAfterGame{action}=$action if(! defined $quitAfterGame{action} || $action<$quitAfterGame{action});
    $quitAfterGame{condition}=$condition if(! defined $quitAfterGame{condition} || $condition<$quitAfterGame{condition});
    $quitAfterGame{exitCode}=$exitCode unless($exitCode == EXIT_SUCCESS);
  }
  my $msg='AutoHost '.('shutdown','restart')[$quitAfterGame{action}].' '.(defined $action?'scheduled'.('',' when battle only contains spectators',' when battle is empty')[$quitAfterGame{condition}]:'cancelled')." (reason: $reason)";
  %quitAfterGame=(action => undef, condition => undef, exitCode => EXIT_SUCCESS) unless(defined $action);
  broadcastMsg($msg);
  slog($msg,3);
  checkExit() if(SimpleEvent::getModel());
  return 1;
}

sub quitAfterGame { applyQuitAction(0,0,$_[0],$_[1]//EXIT_SOFTWARE) }
sub quitWhenOnlySpec { applyQuitAction(0,1,@_) }
sub quitWhenEmpty { applyQuitAction(0,2,@_) }
sub restartAfterGame { applyQuitAction(1,0,shift) }
sub restartWhenOnlySpec { applyQuitAction(1,1,shift) }
sub restartWhenEmpty { applyQuitAction(1,2,shift) }

sub closeBattleAfterGame {
  my ($reason,$silentMode)=@_;
  $closeBattleAfterGame=1;
  my $msg="Close battle scheduled (reason: $reason)";
  broadcastMsg($msg) unless($silentMode);
  slog($msg,3);
}

sub rehostAfterGame {
  my ($reason,$silent)=@_;
  $silent//=0;
  $closeBattleAfterGame=2;
  my $msg="Rehost scheduled (reason: $reason)";
  broadcastMsg($msg) unless($silent);
  slog($msg,4);
}

sub cancelCloseBattleAfterGame {
  my $reason=shift;
  $closeBattleAfterGame=0;
  my $msg="Close battle cancelled";
  $msg.=" (reason: $reason)" if(defined $reason);
  broadcastMsg($msg);
  slog($msg,3);
}

sub computeMessageSize {
  my $p_msg=shift;
  my $size=0;
  {
    use bytes;
    foreach my $word (@{$p_msg}) {
      $size+=length($word)+1;
    }
  }
  return $size;
}

sub checkLastSentMessages {
  my $sent=0;
  foreach my $timestamp (keys %lastSentMessages) {
    if(time - $timestamp > $conf{sendRecordPeriod}) {
      delete $lastSentMessages{$timestamp};
    }else{
      foreach my $msgSize (@{$lastSentMessages{$timestamp}}) {
        $sent+=$msgSize;
      }
    }
  }
  return $sent;
}

sub queueLobbyCommand {
  my @params=@_;
  if($params[0][0] =~ /SAYPRIVATE/) {
    push(@lowPriorityMessageQueue,\@params);
  }elsif(@messageQueue) {
    push(@messageQueue,\@params);
  }else{
    my $alreadySent=checkLastSentMessages();
    my $toBeSent=computeMessageSize($params[0]);
    if($alreadySent+$toBeSent+5 >= $conf{maxBytesSent}) {
      slog("Output flood protection: queueing message(s)",2);
      push(@messageQueue,\@params);
    }else{
      sendLobbyCommand(\@params,$toBeSent);
    }
  }
}

sub sendLobbyCommand {
  my ($p_params,$size)=@_;
  $size//=computeMessageSize($p_params->[0]);
  my $timestamp=time;
  $lastSentMessages{$timestamp}=[] unless(exists $lastSentMessages{$timestamp});
  push(@{$lastSentMessages{$timestamp}},$size);
  if(! $lobby->sendCommand(@{$p_params})) {
    $lobbyBrokenConnection=1 if($lobbyState > LOBBY_STATE_DISCONNECTED);
  }
}

sub checkQueuedLobbyCommands {
  return unless($lobbyState > LOBBY_STATE_CONNECTING && (@messageQueue || @lowPriorityMessageQueue));
  my $alreadySent=checkLastSentMessages();
  while(@messageQueue) {
    my $toBeSent=computeMessageSize($messageQueue[0][0]);
    last if($alreadySent+$toBeSent+5 >= $conf{maxBytesSent});
    my $p_command=shift(@messageQueue);
    sendLobbyCommand($p_command,$toBeSent);
    $alreadySent+=$toBeSent;
  }
  my $nbMsgSentInLoop=0;
  while(@lowPriorityMessageQueue && $nbMsgSentInLoop < 100) {
    my $toBeSent=computeMessageSize($lowPriorityMessageQueue[0][0]);
    last if($alreadySent+$toBeSent+5 >= $conf{maxLowPrioBytesSent});
    my $p_command=shift(@lowPriorityMessageQueue);
    sendLobbyCommand($p_command,$toBeSent);
    $alreadySent+=$toBeSent;
    $nbMsgSentInLoop++;
  }
}

sub openBattle {
  my %hSettings=%{$spads->{hSettings}};
  my $password=$hSettings{password};
  my $mapHash=getMapHash($conf{map});
  if(! $mapHash) {
    slog("Unable to retrieve hashcode of map \"$conf{map}\"",1);
    closeBattleAfterGame("unable to retrieve map hashcode");
    return 0;
  }
  if($targetMod eq '') {
    closeBattleAfterGame('game archive not found');
    return 0;
  }
  my $modHash=getModHash($targetMod);
  if(! $modHash) {
    slog("Unable to retrieve hashcode of mod \"$targetMod\"",1);
    closeBattleAfterGame("unable to retrieve mod hashcode");
    return 0;
  }
  if(! %hostingParams || $hostingParams{game} ne $targetMod || $hostingParams{engineVersion} ne $fullSpringVersion) {
    %hostingParams=(
      game => $targetMod,
      engine => 'spring',
      engineVersion => $fullSpringVersion,
        );
    slog("Hosting game \"$targetMod\" using engine version \"$fullSpringVersion\"",3);
  }
  $lobbyState=LOBBY_STATE_OPENING_BATTLE;
  queueLobbyCommand(['OPENBATTLE',
                     0,
                     $hSettings{natType},
                     $password,
                     $hSettings{port},
                     $hSettings{maxPlayers},
                     $modHash,
                     $hSettings{minRank},
                     $mapHash,
                     'spring',
                     $fullSpringVersion,
                     $conf{map},
                     $hSettings{battleName},
                     $targetMod],
                    {OPENBATTLE => \&cbOpenBattle,
                     OPENBATTLEFAILED => \&cbOpenBattleFailed},
                    \&cbOpenBattleTimeout); # lobby command timeouts aren't enabled currently (SpringLobbyInterface::checkTimeouts() is never called)
  $timestamps{autoRestore}=time if($timestamps{autoRestore});
  %bosses=();
  $currentNbNonPlayer=0;
  %currentPlayers=();
  %currentSpecs=();
  %battleSkills=();
  %battleSkillsCache=();
  %forceSpecTimestamps=();
  %pendingFloodKicks=();
  %pendingLocalBotManual=();
  %pendingLocalBotAuto=();
  %autoAddedLocalBots=();
  %sentPlayersScriptTags=();
}

sub closeBattle {
  queueLobbyCommand(["LEAVEBATTLE"]);
  $currentNbNonPlayer=0;
  $lobbyState=LOBBY_STATE_SYNCHRONIZED;
  $closeBattleAfterGame=0 if($closeBattleAfterGame == 2);
  if(%bosses) {
    broadcastMsg("Boss mode disabled");
    %bosses=();
  }
  logMsg("battle","=== $conf{lobbyLogin} left ===") if($conf{logBattleJoinLeave});
}

sub applyMapBoxes {
  return unless(%{$lobby->{battle}});
  foreach my $teamNb (keys %{$lobby->{battle}{startRects}}) {
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]);
  }
  return unless($spads->{bSettings}{startpostype} == 2);
  my $smfMapName=$conf{map};
  $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
  my $p_boxes=$spads->getMapBoxes($smfMapName,$conf{nbTeams},$conf{extraBox});
  foreach my $pluginName (@pluginsOrder) {
    my $overwritten=$plugins{$pluginName}->setMapStartBoxes($p_boxes,$conf{map},$conf{nbTeams},$conf{extraBox}) if($plugins{$pluginName}->can('setMapStartBoxes'));
    if(ref $overwritten) {
      my $r_newBoxes;
      ($overwritten,$r_newBoxes)=@{$overwritten};
      $p_boxes=$r_newBoxes if(ref $r_newBoxes eq 'ARRAY');
    }
    last if(defined $overwritten && $overwritten);
  }
  return unless(@{$p_boxes});
  my $boxId=0;
  foreach my $boxString (@{$p_boxes}) {
    $boxId+=applyMapBox($boxString,$boxId);
  }
}

sub applyMapBox {
  my ($paramsString,$boxId)=@_;
  my @params=split(/ /,$paramsString);
  if($params[0] =~ /^\d+$/) {
    if($#params != 3) {
      slog("Skipping map box, invalid syntax",2);
      return 0;
    }
    for my $i (0..3) {
      if($params[$i] !~ /^\d+$/ || $params[$i] > 200) {
        slog("Skipping map box, invalid coordinate ($params[$i])",2);
        return 0;
      }
    }
    my ($left,$top,$right,$bottom)=@params;
    if($left > $right || $top > $bottom) {
      slog("Skipping map box, inconsistent coordinates",2);
      return 0;
    }

    queueLobbyCommand(["ADDSTARTRECT",$boxId,$left,$top,$right,$bottom]);
    return 1;
  }else{
    if($#params != 1 || none {$params[0] eq $_} qw'h v c1 c2 c s') {
      slog("Skipping map box, invalid syntax",2);
      return 0;
    }
    if($params[1] !~ /^\d+$/ || $params[1] > 50) {
      slog("Skipping map box, invalid box size",2);
      return 0;
    }
    $params[1]*=2;

    my @boxes;
    if($params[0] eq "h") {
      @boxes=([0,0,200,$params[1]],[0,200-$params[1],200,200]);
    }elsif($params[0] eq "v") {
      @boxes=([0,0,$params[1],200],[200-$params[1],0,200,200]);
    }elsif($params[0] eq "c1") {
      @boxes=([0,0,$params[1],$params[1]],[200-$params[1],200-$params[1],200,200]);
    }elsif($params[0] eq "c2") {
      @boxes=([0,200-$params[1],$params[1],200],[200-$params[1],0,200,$params[1]]);
    }elsif($params[0] eq "c") {
      @boxes=([0,0,$params[1],$params[1]],
              [200-$params[1],200-$params[1],200,200],
              [0,200-$params[1],$params[1],200],
              [200-$params[1],0,200,$params[1]]);
    }elsif($params[0] eq "s") {
      @boxes=([100-int($params[1]/2),0,100+int($params[1]/2),$params[1]],
              [100-int($params[1]/2),200-$params[1],100+int($params[1]/2),200],
              [0,100-int($params[1]/2),$params[1],100+int($params[1]/2)],
              [200-$params[1],100-int($params[1]/2),200,100+int($params[1]/2)]);
    }

    for my $teamNb (0..$#boxes) {
      my @box=@{$boxes[$teamNb]};
      queueLobbyCommand(["ADDSTARTRECT",$boxId+$teamNb,@box]);
    }
    return $#boxes+1;
  }
}

sub sendBattleSetting {
  my $bSetting=shift;
  my %bSettings=%{$spads->{bSettings}};
  my $currentModName=$lobby->{battles}{$lobby->{battle}{battleId}}{mod};
  my $p_modOptions=getModOptions($currentModName);
  my $p_mapOptions=getMapOptions($currentMap);
  my $bValue;
  if(exists $bSettings{$bSetting}) {
    $bValue=$bSettings{$bSetting};
  }elsif(exists $p_modOptions->{$bSetting}) {
    $bValue=$p_modOptions->{$bSetting}{default};
  }elsif(exists $p_mapOptions->{$bSetting}) {
    $bValue=$p_mapOptions->{$bSetting}{default};
  }else{
    slog("Unable to send battle setting \"$bSetting\" (unknown setting)\"",2);
    return;
  }
  if(! defined $bValue || $bValue eq '') {
    slog("Unable to send battle setting \"$bSetting\" (value unknown)\"",2);
    return;
  }
  my $optionPath='';
  if(exists $p_modOptions->{$bSetting}) {
    $optionPath='modoptions/';
  }elsif(exists $p_mapOptions->{$bSetting}) {
    $optionPath='mapoptions/';
  }elsif($bSetting ne 'startpostype') {
    slog("Unable to send battle setting \"$bSetting\" (setting invalid for current mod and map)\"",2);
    return;
  }
  queueLobbyCommand(["SETSCRIPTTAGS","game/$optionPath$bSetting=$bValue"]);
}

sub sendBattleMapOptions {
  if(exists $lobby->{battle}{scriptTags}) {
    my @scriptTagsToDelete;
    foreach my $scriptTag (keys %{$lobby->{battle}{scriptTags}}) {
      push(@scriptTagsToDelete,$scriptTag) if($scriptTag =~ /^game\/mapoptions\//i);
    }
    my $p_scriptTagsToDeleteLines=limitLineSize(\@scriptTagsToDelete,900);
    foreach my $p_scriptTagsLine (@{$p_scriptTagsToDeleteLines}) {
      queueLobbyCommand(["REMOVESCRIPTTAGS",@{$p_scriptTagsLine}]);
    }
  }
  my %bSettings=%{$spads->{bSettings}};
  my @scriptTagsSettings;
  my $p_mapOptions=getMapOptions($currentMap);
  foreach my $scriptTagsSetting (keys %{$p_mapOptions}) {
    my $bValue;
    if(exists $bSettings{$scriptTagsSetting}) {
      $bValue=$bSettings{$scriptTagsSetting};
    }else{
      $bValue=$p_mapOptions->{$scriptTagsSetting}{default};
    }
    push(@scriptTagsSettings,"game/mapoptions/$scriptTagsSetting=$bValue");
  }
  my $p_scriptTagsLines=limitLineSize(\@scriptTagsSettings,900);
  foreach my $p_scriptTagsLine (@{$p_scriptTagsLines}) {
    queueLobbyCommand(["SETSCRIPTTAGS",@{$p_scriptTagsLine}]);
  }
}

sub sendBattleSettings {
  my %bSettings=%{$spads->{bSettings}};
  my $currentModName=$lobby->{battles}{$lobby->{battle}{battleId}}{mod};
  my $p_modOptions=getModOptions($currentModName);
  my @scriptTagsSettings=("game/startpostype=$bSettings{startpostype}",'game/hosttype=SPADS');
  foreach my $scriptTagsSetting (keys %{$p_modOptions}) {
    my $bValue;
    if(exists $bSettings{$scriptTagsSetting}) {
      $bValue=$bSettings{$scriptTagsSetting};
    }else{
      $bValue=$p_modOptions->{$scriptTagsSetting}{default};
    }
    push(@scriptTagsSettings,"game/modoptions/$scriptTagsSetting=$bValue");
  }
  my $p_mapOptions=getMapOptions($currentMap);
  foreach my $scriptTagsSetting (keys %{$p_mapOptions}) {
    my $bValue;
    if(exists $bSettings{$scriptTagsSetting}) {
      $bValue=$bSettings{$scriptTagsSetting};
    }else{
      $bValue=$p_mapOptions->{$scriptTagsSetting}{default};
    }
    push(@scriptTagsSettings,"game/mapoptions/$scriptTagsSetting=$bValue");
  }
  my $p_scriptTagsLines=limitLineSize(\@scriptTagsSettings,900);
  foreach my $p_scriptTagsLine (@{$p_scriptTagsLines}) {
    queueLobbyCommand(["SETSCRIPTTAGS",@{$p_scriptTagsLine}]);
  }
  queueLobbyCommand(["ENABLEALLUNITS"]);
  if($bSettings{disabledunits}) {
    my @disabledUnits=split(/;/,$bSettings{disabledunits});
    my $p_disabledUnitsLines=limitLineSize(\@disabledUnits,900);
    foreach my $p_disabledUnitsLine (@{$p_disabledUnitsLines}) {
      queueLobbyCommand(["DISABLEUNITS",@{$p_disabledUnitsLine}]);
    }
  }
}

sub updateBattleInfo {
  my $mapHash=getMapHash($conf{map});
  if(! $mapHash) {
    slog("Unable to retrieve hashcode of map \"$conf{map}\"",1);
    closeBattleAfterGame("unable to retrieve map hashcode");
  }else{
    queueLobbyCommand(["UPDATEBATTLEINFO",$currentNbNonPlayer,$currentLockedStatus,$mapHash,$conf{map}]);
  }
}

sub getNbSpec {
  my $nbSpec=0;
  my %battleUsers=%{$lobby->{battle}{users}};
  foreach my $user (keys %battleUsers) {
    $nbSpec++ if(defined $battleUsers{$user}{battleStatus} && (! $battleUsers{$user}{battleStatus}{mode}));
  }
  return $nbSpec;
}

sub getNbHumanPlayersInBattle {
  my $nbHumanPlayer=0;
  my %battleUsers=%{$lobby->{battle}{users}};
  foreach my $user (keys %battleUsers) {
    $nbHumanPlayer++ if(defined $battleUsers{$user}{battleStatus} && $battleUsers{$user}{battleStatus}{mode});
  }
  return $nbHumanPlayer;
}

sub getNbNonPlayer {
  my $nbNonPlayer=0;
  my %battleUsers=%{$lobby->{battle}{users}};
  foreach my $user (keys %battleUsers) {
    $nbNonPlayer++ unless(defined $battleUsers{$user}{battleStatus} && $battleUsers{$user}{battleStatus}{mode});
  }
  return $nbNonPlayer;
}

sub getTargetBattleInfo {
  my @unlockSpecDelay=split(/;/,$conf{unlockSpecDelay});
  if($unlockSpecDelay[0]) {
    foreach my $pendingUser (keys %pendingSpecJoin) {
      delete $pendingSpecJoin{$pendingUser} unless(time - $pendingSpecJoin{$pendingUser} < $unlockSpecDelay[1]);
    }
  }
  my $nbNonPlayer=getNbNonPlayer();
  my @clients=keys %{$lobby->{battle}{users}};
  $manualLockedStatus=0 if($#clients+1-$nbNonPlayer < $conf{minPlayers});
  my $targetLockedStatus=$manualLockedStatus;
  my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
  my $nbPlayers=$#clients+1-$nbNonPlayer;
  my @bots=keys %{$lobby->{battle}{bots}};
  if($conf{nbTeams} != 1) {
    my $nbAutoAddedLocalBots=keys %autoAddedLocalBots;
    $nbPlayers+=$#bots+1-$nbAutoAddedLocalBots;
  }
  if($conf{autoLock} eq 'off') {
    if($conf{maxSpecs} ne '' && $nbNonPlayer > $conf{maxSpecs}) {
      $targetLockedStatus=1 if($nbPlayers >= $spads->{hSettings}{maxPlayers} || ($conf{autoSpecExtraPlayers} && $nbPlayers >= $targetNbPlayers));
    }
  }else{
    $targetLockedStatus=0;
    if($nbPlayers >= $targetNbPlayers) {
      if($conf{autoLock} eq "on") {
        $targetLockedStatus=1;
      }else{
        $targetLockedStatus=1 unless($nbPlayers % $conf{teamSize});
      }
    }
    $targetLockedStatus=0 if($nbPlayers >= $lobby->{battles}{$lobby->{battle}{battleId}}{maxPlayers} && ! @bots);
    $targetLockedStatus=1 if($conf{maxSpecs} ne '' && $nbNonPlayer > $conf{maxSpecs} && $nbPlayers >= $spads->{hSettings}{maxPlayers});
  }
  if($targetLockedStatus) {
    foreach my $pendingUser (keys %pendingSpecJoin) {
      if(time - $pendingSpecJoin{$pendingUser} < $unlockSpecDelay[0]) {
        $targetLockedStatus=0;
        last;
      }
    }
  }
  $targetLockedStatus=1 if($conf{autoLockClients} && $#clients >= $conf{autoLockClients});
  $targetLockedStatus=1 if($conf{autoLockRunningBattle} && $lobby->{users}{$conf{lobbyLogin}}{status}{inGame});
  return ($nbNonPlayer,$targetLockedStatus);
}

sub updateBattleStates {
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    $balanceState=0;
    $colorsState=0;
  }else{
    $balanceState=isBalanceTargetApplied();
    $colorsState=areColorsApplied();
  }
}

sub updateBattleInfoIfNeeded {

  return if($lobbyState < LOBBY_STATE_BATTLE_OPENED);

  my $updateNeeded=0;
  my ($nbNonPlayer,$lockedStatus)=getTargetBattleInfo();
  if($nbNonPlayer != $currentNbNonPlayer) {
    $currentNbNonPlayer=$nbNonPlayer;
    $updateNeeded=1;
  }
  if($currentMap ne $conf{map}) {
    $currentMap=$conf{map};
    $updateNeeded=1;
  }
  if($currentLockedStatus != $lockedStatus) {
    $currentLockedStatus=$lockedStatus;
    $updateNeeded=1;
  }
  updateBattleInfo() if($updateNeeded);
}

sub answer {
  my $msg=shift;
  &{$p_answerFunction}($msg);
}

sub broadcastMsg {
  my $msg=shift;
  sayBattle($msg);
  my @broadcastChans=split(/;/,$conf{broadcastChannels});
  foreach my $chan (@broadcastChans) {
    $chan=$1 if($chan =~ /^([^\s]+)\s/);
    sayChan($chan,$msg);
  }
  sayGame($msg);
}

sub sayBattleAndGame {
  my $msg=shift;
  sayBattle($msg);
  sayGame($msg);
}
  

sub splitMsg {
  my ($longMsg,$maxSize)=@_;
  my @messages=($longMsg =~ /.{1,$maxSize}/gs);
  return \@messages;
}

sub isUserAuthenticated {
  my $user=shift;
  if(! exists $authenticatedUsers{$user}) {
    return 0 if($lanMode);
    return 1;
  }
  my $passwd=getUserPref($user,"password");
  if($passwd eq "" || $passwd ne $authenticatedUsers{$user}) {
    return 0 if($lanMode);
    return 1;
  }
  return 2;
}

sub isUserAllowedToSpeakInGame {
  my $user=shift;
  return 0 unless($autohost->getState());
  return 1 unless($conf{noSpecChat});
  return 0 unless( exists $inGameAddedPlayers{$user}
                   || ( exists $p_runningBattle->{users}{$user}
                        && defined $p_runningBattle->{users}{$user}{battleStatus}
                        && $p_runningBattle->{users}{$user}{battleStatus}{mode} ) );
  my $r_ahPlayer=$autohost->getPlayer($user);
  return 1 if(! %{$r_ahPlayer} || $r_ahPlayer->{lost} == 0);
  return 0;
}

sub addAlert {
  my $alert=shift;
  if(exists $ALERTS{$alert}) {
    $pendingAlerts{$alert}={occurrences => 0} unless(exists $pendingAlerts{$alert});
    $pendingAlerts{$alert}{occurrences}++;
    $pendingAlerts{$alert}{latest}=time;
    foreach my $alertedUser (keys %alertedUsers) {
      alertUser($alertedUser) if(time-$alertedUsers{$alertedUser} > $conf{alertDelay}*3600);
    }
  }else{
    slog("Invalid alert raised: \"$alert\"",2);
  }
}

sub alertUser {
  my $user=shift;
  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  foreach my $alert (sort {$pendingAlerts{$a}{latest} <=> $pendingAlerts{$b}{latest}} (keys %pendingAlerts)) {
    my $latestOccurrenceDelay=time-$pendingAlerts{$alert}{latest};
    if($latestOccurrenceDelay > $conf{alertDuration}*3600) {
      delete $pendingAlerts{$alert};
      next;
    }
    my $alertMsg="[$B$C{4}ALERT$C{1}$B] - $C{12}$alert$C{1} - $ALERTS{$alert}";
    my $latestOccurrenceDelayString="";
    $latestOccurrenceDelayString=secToTime($latestOccurrenceDelay) if($latestOccurrenceDelay > 0);
    if($pendingAlerts{$alert}{occurrences} > 1) {
      $alertMsg.=" (x$pendingAlerts{$alert}{occurrences}";
      $alertMsg.=", latest: $latestOccurrenceDelayString ago" if($latestOccurrenceDelayString);
      $alertMsg.=")";
    }else{
      $alertMsg.=" ($latestOccurrenceDelayString ago)" if($latestOccurrenceDelayString);
    }
    sayPrivate($user,$alertMsg);
    $alertedUsers{$user}=time;
  }
}

sub sayPrivate {
  my ($user,$msg)=@_;
  my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-12-length($user));
  foreach my $mes (@{$p_messages}) {
    queueLobbyCommand(["SAYPRIVATE",$user,$mes]);
    logMsg("pv_$user","<$conf{lobbyLogin}> $mes") if($conf{logPvChat} && $user ne $gdrLobbyBot && $user ne $sldbLobbyBot && $mes !~ /^!#/);
  }
}

sub sayBattle {
  my $msg=shift;
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-14);
  foreach my $mes (@{$p_messages}) {
    queueLobbyCommand(["SAYBATTLEEX","* $mes"]);
  }
}

sub sayBattleUser {
  my ($user,$msg)=@_;
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-22-length($user));
  foreach my $mes (@{$p_messages}) {
    queueLobbyCommand(["SAYBATTLEPRIVATEEX",$user,"* $mes"]);
    logMsg("battle","(to $user) * $conf{lobbyLogin} * $mes") if($conf{logBattleChat});
  }
}

sub sayChan {
  my ($chan,$msg)=@_;
  $chan//=$masterChannel;
  return unless($lobbyState >= LOBBY_STATE_SYNCHRONIZED && (exists $lobby->{channels}{$chan}));
  my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-9-length($chan));
  foreach my $mes (@{$p_messages}) {
    queueLobbyCommand(["SAYEX",$chan,"* $mes"]);
  }
}

sub sayGame {
  my $msg=shift;
  return unless($autohost->getState());
  my $prompt="$conf{lobbyLogin} * ";
  my $p_messages=splitMsg($msg,$conf{maxAutoHostMsgLength}-length($prompt)-1);
  foreach my $mes (@{$p_messages}) {
    $autohost->sendChatMessage("$prompt$mes");
    logMsg("game","> $prompt$mes") if($conf{logGameChat});
  }
}

sub getCommandLevels {
  my ($source,$user,$cmd)=@_;

  my $gameState='stopped';
  if($autohost->getState()) {
    $gameState='running';
  }elsif(%currentVote && defined $currentVote{command}) {
    my $lcVotedCmd=lc($currentVote{command}[0]);
    $gameState='voting' if(any {$lcVotedCmd eq $_} (qw'start forcestart'));
  }

  my $status="outside";
  if($gameState eq "running" && exists $p_runningBattle->{users}{$user} && %{$autohost->getPlayer($user)}) {
    if(defined $p_runningBattle->{users}{$user}{battleStatus} && $p_runningBattle->{users}{$user}{battleStatus}{mode}) {
      my $p_ahPlayer=$autohost->getPlayer($user);
      if($p_ahPlayer->{disconnectCause} == -1 && $p_ahPlayer->{lost} == 0) {
        $status="playing";
      }else{
        $status="player";
      }
    }else{
      $status="spec";
    }
  }elsif(%{$lobby->{battle}} && exists $lobby->{battle}{users}{$user}) {
    if(defined $lobby->{battle}{users}{$user}{battleStatus} && $lobby->{battle}{users}{$user}{battleStatus}{mode}) {
      $status="player";
    }else{
      $status="spec";
    }
  }

  return $spads->getCommandLevels($cmd,$source,$status,$gameState);

}

sub getUserAccessLevel {
  my $user=shift;
  return $user->{accessLevel} if(ref $user);
  my $p_userData;
  if(! exists $lobby->{users}{$user}) {
    return 0 unless(exists $p_runningBattle->{users} && exists $p_runningBattle->{users}{$user});
    $p_userData=$p_runningBattle->{users}{$user};
  }else{
    $p_userData=$lobby->{users}{$user};
  }
  my $isAuthenticated=isUserAuthenticated($user);
  my $coreUserAccessLevel=$spads->getUserAccessLevel($user,$p_userData,$isAuthenticated);
  foreach my $pluginName (@pluginsOrder) {
    my $newUserAccessLevel=$plugins{$pluginName}->changeUserAccessLevel($user,$p_userData,$isAuthenticated,$coreUserAccessLevel) if($plugins{$pluginName}->can('changeUserAccessLevel'));
    return $newUserAccessLevel if(defined $newUserAccessLevel);
  }
  return $coreUserAccessLevel;
}

sub parseSpadsCmd {
  my $command=shift;
  
  my $paramsStartIdx=index($command,' ');
  my @cmd = ($paramsStartIdx > -1 ? substr($command,0,$paramsStartIdx) : $command);
  my $lcCmd=lc($cmd[0]);

  my $cmdShortcut;
  if($conf{allowSettingsShortcut} && ! exists $spadsCmdHandlers{$lcCmd} && ! $HIDDEN_SETTINGS_LOWERCASE{$lcCmd}) {
    if(any {$lcCmd eq $_} qw'users presets hpresets bpresets settings bsettings hsettings vsettings aliases bans maps pref rotationmaps plugins psettings') {
      $cmdShortcut='list';
    }else{
      my @checkPrefResult=$spads->checkUserPref($lcCmd,'');
      if(! $checkPrefResult[0] && $lcCmd ne 'skillmode' && $lcCmd ne 'rankmode') {
        $cmdShortcut='pSet';
      }elsif(any {$lcCmd eq lc($_)} (keys %{$spads->{values}})) {
        $cmdShortcut='set';
      }elsif(any {$lcCmd eq lc($_)} (keys %{$spads->{hValues}})) {
        $cmdShortcut='hSet';
      }else{
        my $modName = $lobbyState >= LOBBY_STATE_BATTLE_OPENED ? $lobby->{battles}{$lobby->{battle}{battleId}}{mod} : $targetMod;
        my $p_modOptions=getModOptions($modName);
        my $p_mapOptions=getMapOptions($currentMap);
        $cmdShortcut='bSet' if($lcCmd eq 'startpostype' || exists $p_modOptions->{$lcCmd} || exists $p_mapOptions->{$lcCmd});
      }
    }
  }
  my $r_cmdAliases;
  if(defined $cmdShortcut) {
    $r_cmdAliases={};
    substr($command,0,0,' ');
    $paramsStartIdx=0;
    @cmd=($cmdShortcut);
    $lcCmd=lc($cmdShortcut);
  }else{
    $r_cmdAliases=getCmdAliases();
    if(exists $r_cmdAliases->{$lcCmd} && @{$r_cmdAliases->{$lcCmd}} == 1) {
      @cmd=($r_cmdAliases->{$lcCmd}[0]);
      $lcCmd=lc($cmd[0]);
    }
  }

  if($paramsStartIdx > -1 && $paramsStartIdx < length($command)-1) {
    my $paramsString=substr($command,$paramsStartIdx+1);
    my @parsedParams;
    if(exists $spadsCmdsCustomParamParsing{$lcCmd}) {
      my $customParsing=$spadsCmdsCustomParamParsing{$lcCmd};
      if(ref $customParsing eq '') {
        if($customParsing) {
          $paramsString=~s/^ +//;
          if($paramsString ne '') {
            if($customParsing > 1) {
              @parsedParams=split(/ +/,$paramsString,$customParsing);
              pop(@parsedParams) if($parsedParams[-1] eq '');
            }else{
              @parsedParams=($paramsString);
            }
          }
        }else{
          @parsedParams=($paramsString);
        }
      }else{
        @parsedParams=$customParsing->($paramsString);
      }
    }else{
      $paramsString=~s/^ +//;
      @parsedParams=split(/ +/,$paramsString);
    }
    push(@cmd,@parsedParams);
  }

  return ($lcCmd,@cmd) unless(exists $r_cmdAliases->{$lcCmd});
  
  my $paramsReordered=0;
  my @newCmd;
  foreach my $token (@{$r_cmdAliases->{$lcCmd}}) {
    if($token =~ /^(.*)\%(\d)\%(.*)$/) {
      $paramsReordered=1;
      push(@newCmd,$1.($cmd[$2]//'').$3);
    }else{
      push(@newCmd,$token);
    }
  }
  if(! $paramsReordered) {
    for my $i (1..$#cmd) {
      push(@newCmd,$cmd[$i]);
    }
  }
  return (lc($newCmd[0]),@newCmd);
}

sub getCmdAliases {
  my %cmdAliases=%SPADS_CORE_CMD_ALIASES;
  foreach my $pluginName (@pluginsOrder) {
    my $r_newAliases=$plugins{$pluginName}->updateCmdAliases(\%cmdAliases) if($plugins{$pluginName}->can('updateCmdAliases'));
    (map {$cmdAliases{$_}=$r_newAliases->{$_}} (keys %{$r_newAliases})) if(ref $r_newAliases eq 'HASH');
  }
  return \%cmdAliases;
}

sub updateAnswerFunction {
  my ($source,$user)=@_;
  if($source eq 'game') {
    if(isUserAllowedToSpeakInGame($user)) {
      $p_answerFunction = \&sayBattleAndGame;
    }else{
      $p_answerFunction = sub { sayPrivate($user,$_[0]) };
    }
  }else{
    $p_answerFunction = { pv => sub { sayPrivate($user,$_[0]) },
                          battle => \&sayBattle,
                          chan => sub { sayChan($masterChannel,$_[0]) } }->{$source};
  }
}

sub checkCommandRightsOverride {
  my ($lcCmd,$r_cmd,$source,$user,$effectiveUserAccessLevel,$userAccessLevel,$r_requiredAccessLevels)=@_;

  if($lcCmd eq 'set' && $#{$r_cmd} > 0 && defined $r_requiredAccessLevels->{voteLevel} && $r_requiredAccessLevels->{voteLevel} ne '') {
    
    my @freeSettingsEntries=split(/;/,$conf{freeSettings});
    my %freeSettings;
    foreach my $freeSettingEntry (@freeSettingsEntries) {
      if($freeSettingEntry =~ /^([^\(]+)\(([^\)]+)\)$/) {
        $freeSettings{lc($1)}=$2;
      }else{
        $freeSettings{lc($freeSettingEntry)}=undef;
      }
    }

    my $lcSetting=lc($r_cmd->[1]);
    if(exists $freeSettings{$lcSetting}) {
      my $allowed=1;
      if(defined $freeSettings{$lcSetting}) {
        $allowed=0;
        my $value=$r_cmd->[2]//'';
        my @directRanges=split(',',$freeSettings{$lcSetting},-1);
        foreach my $range (@directRanges) {
          if(isRange($range)) {
            $allowed=1 if(matchRange($range,$value));
          }elsif($value eq $range) {
            $allowed=1;
          }
          last if($allowed);
        }
      }
      $r_requiredAccessLevels->{directLevel}=$r_requiredAccessLevels->{voteLevel} if($allowed);
    }
    
  }
  
  foreach my $pluginName (@pluginsOrder) {
    next unless($plugins{$pluginName}->can('commandRightsOverride'));
    my $override=$plugins{$pluginName}->commandRightsOverride($lcCmd,$r_cmd,$source,$user,$effectiveUserAccessLevel,$userAccessLevel,$r_requiredAccessLevels);
    return $override if(defined $override);
  }

  if($lcCmd eq 'endvote') {
    my $r_voteCmd=$currentVote{command};
    return 1 if(defined $r_voteCmd && ($currentVote{user} eq $user || ($#{$r_voteCmd} > 0 && $r_voteCmd->[0] eq 'joinAs' && $r_voteCmd->[1] eq $user)));
  }elsif($lcCmd eq 'boss') {
    return 1 if(@{$r_cmd} == 1 && keys %bosses == 1 && exists $bosses{$user});
  }
  
  return;
}

sub handleRequest {
  my ($source,$user,$command,$floodCheck)=@_;
  $floodCheck//=1;
  
  return if($floodCheck && checkCmdFlood($user));

  updateAnswerFunction($source,$user);

  my ($lcCmd,@cmd)=parseSpadsCmd($command);
  
  return executeCommand($source,$user,\@cmd)
      if($user eq $sldbLobbyBot && substr($lcCmd,0,1) eq '#' && exists $spadsCmdHandlers{$lcCmd});

  if(! exists $spads->{commands}{$lcCmd} && (none {exists $spads->{pluginsConf}{$_}{commands}{$lcCmd}} (keys %{$spads->{pluginsConf}}))) {
    answer("Invalid command \"$cmd[0]\"") unless($source eq 'chan');
    return;
  }

  slog("Start of \"$lcCmd\" command processing",5);

  my $p_levels=getCommandLevels($source,$user,$lcCmd);
  
  my $level=getUserAccessLevel($user);
  my $levelWithoutBoss=$level;
  
  if(%bosses && ! exists $bosses{$user}) {
    my $p_bossLevels=$spads->getCommandLevels("boss","battle","player","stopped");
    $level=0 if(exists $p_bossLevels->{directLevel} && $level < $p_bossLevels->{directLevel});
  }

  my $cmdRightsOverride=checkCommandRightsOverride($lcCmd,\@cmd,$source,$user,$level,$levelWithoutBoss,$p_levels);

  if($cmdRightsOverride || (! defined $cmdRightsOverride && defined $p_levels->{directLevel} && $p_levels->{directLevel} ne "" && $level >= $p_levels->{directLevel})) {
    my @realCmd=@cmd;
    my $rewrittenCommand=executeCommand($source,$user,\@cmd);
    if(defined $rewrittenCommand) {
      if(ref $rewrittenCommand eq 'ARRAY') {
        @realCmd=@{$rewrittenCommand};
      }elsif($rewrittenCommand && $rewrittenCommand ne '1') {
        @realCmd=split(/ /,$rewrittenCommand); # for legacy plugins
      }
    }
    if(%currentVote && exists $currentVote{command} && $#{$currentVote{command}} == $#realCmd) {
      my $isSameCmd=1;
      for my $i (0..$#realCmd) {
        if(lc($realCmd[$i]) ne lc($currentVote{command}[$i])) {
          $isSameCmd=0;
          last;
        }
      }
      if($isSameCmd) {
        foreach my $pluginName (@pluginsOrder) {
          $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
        }
        sayBattleAndGame('Cancelling "'.(join(' ',@{$currentVote{command}}))."\" vote (command executed directly by $user)");
        %currentVote=();
      }
    }
  }elsif(defined $p_levels->{voteLevel} && $p_levels->{voteLevel} ne "" && $level >= $p_levels->{voteLevel}) {
    if($conf{autoCallvote}) {
      executeCommand($source,$user,["callvote",\@cmd]); # array ref is passed as callvote parameter to avoid reparsing command
    }else{
      answer("$user, you are not allowed to call command \"$cmd[0]\" directly in current context (try !callvote $command).");
    }
  }else{
    if((defined $p_levels->{directLevel} && $p_levels->{directLevel} ne "" && $levelWithoutBoss >= $p_levels->{directLevel})
       || (defined $p_levels->{voteLevel} && $p_levels->{voteLevel} ne "" && $levelWithoutBoss >= $p_levels->{voteLevel})) {
      answer("$user, you are not allowed to call command \"$cmd[0]\" in current context (boss mode is enabled).");
    }else{
      answer("$user, you are not allowed to call command \"$cmd[0]\" in current context.");
    }
  }

  slog("End of \"$lcCmd\" command processing",5);
}

sub executeCommand {
  my ($source,$user,$p_cmd,$checkOnly)=@_;
  $checkOnly//=0;

  updateAnswerFunction($source,$user);
  
  my @cmd=@{$p_cmd};
  my $command=lc(shift(@cmd));

  if(exists $spadsCmdHandlers{$command}) {
    my $commandAllowed=1;
    my $r_actualParams = (@cmd == 1 && ref $cmd[0] eq 'ARRAY') ? $cmd[0] : \@cmd;
    if(! $checkOnly) {
      foreach my $pluginName (@pluginsOrder) {
        $commandAllowed=$plugins{$pluginName}->preSpadsCommand($command,$source,$user,$r_actualParams) if($plugins{$pluginName}->can('preSpadsCommand'));
        last unless($commandAllowed);
      }
    }
    return 0 unless($commandAllowed);
    my $spadsCommandRes=&{$spadsCmdHandlers{$command}}($source,$user,\@cmd,$checkOnly);
    if(! $checkOnly) {
      foreach my $pluginName (@pluginsOrder) {
        $plugins{$pluginName}->postSpadsCommand($command,$source,$user,$r_actualParams,$spadsCommandRes) if($plugins{$pluginName}->can('postSpadsCommand'));
      }
    }
    return $spadsCommandRes;
  }else{
    answer("Invalid command \"$command\"");
    return 0;
  }

}

sub handleRelayedJsonRpcChunk {
  my ($user,$chunkIndicator,$jsonString)=@_;
  if($chunkIndicator ne '') {
    $chunkIndicator =~ /^\((\d+)\/(\d+)\)$/;
    my ($currentChunk,$lastChunk)=($1,$2);
    if($currentChunk == 0 || $lastChunk == 0) {
      slog("Ignoring invalid JSONRPC chunk from $user (invalid chunk indicator: $currentChunk/$lastChunk)",5);
      delete $pendingRelayedJsonRpcChunks{$user};
      return;
    }
    if($currentChunk == 1) {
      if($lastChunk != 1) {
        $pendingRelayedJsonRpcChunks{$user} = { data => $jsonString,
                                                nextChunk => 2,
                                                lastChunk => $lastChunk };
        return;
      }
    }else{
      if(! exists $pendingRelayedJsonRpcChunks{$user}) {
        slog("Ignoring invalid JSONRPC chunk from $user (continuation of an unknown request, chunk indicator: $currentChunk/$lastChunk",5);
        return;
      }
      if($currentChunk != $pendingRelayedJsonRpcChunks{$user}{nextChunk} || $lastChunk != $pendingRelayedJsonRpcChunks{$user}{lastChunk}) {
        slog("Ignoring invalid JSONRPC chunk from $user (inconsistent chunk indicator: $currentChunk/$lastChunk, expected $pendingRelayedJsonRpcChunks{$user}{nextChunk}/$pendingRelayedJsonRpcChunks{$user}{lastChunk})",5);
        delete $pendingRelayedJsonRpcChunks{$user};
        return;
      }
      $pendingRelayedJsonRpcChunks{$user}{data}.=$jsonString;
      if($currentChunk == $lastChunk) {
        $jsonString=$pendingRelayedJsonRpcChunks{$user}{data};
        delete $pendingRelayedJsonRpcChunks{$user};
      }else{
        $pendingRelayedJsonRpcChunks{$user}{nextChunk}++;
        return;
      }
    }
  }
  delete $pendingRelayedJsonRpcChunks{$user};

  my $floodCheckStatus=checkRelayedApiFlood($user);
  return if($floodCheckStatus > 1);

  processJsonRpcRequest({source => 'pv',user => $user},$jsonString,$floodCheckStatus);
}

sub processJsonRpcRequest {
  my ($r_origin,$jsonString,$floodCheckStatus)=@_;

  $r_origin->{protocol}='jsonrpc';
  $r_origin->{user}//='<UNAUTHENTICATED USER>';
  if($r_origin->{source} eq 'tcp') {
    $r_origin->{accessLevel}//=0;
    $r_origin->{origin}="$r_origin->{user} [$r_origin->{ipAddr}:$r_origin->{tcpPort}]";
  }else{
    $r_origin->{origin}=$r_origin->{user};
  }
  my ($user,$origin,$level)=@{$r_origin}{qw'user origin accessLevel'};
  
  my $r_jsonReq;
  eval {
    $r_jsonReq=decode_json($jsonString);
  };

  my ($errorCode,$errorData);
  if(hasEvalError()) {
    $errorData=$@;
    $errorData=$1 if($errorData =~ /^(.+) at [^\s]+ line \d+\.$/);
    slog("Received an invalid JSONRPC request from $origin (JSON syntax error: $errorData)",5);
    $errorCode='PARSE_ERROR';
  }elsif($errorData=checkJsonRpcRequest($r_jsonReq)) {
    slog("Received an invalid JSONRPC request from $origin ($errorData)",5);
    $errorCode='INVALID_REQUEST';
    $r_origin->{jsonrpcReqId}=$r_jsonReq->{id} if(ref $r_jsonReq eq 'HASH' && exists $r_jsonReq->{id} && ref $r_jsonReq->{id} eq '');
  }else{
    $r_origin->{jsonrpcReqId}=$r_jsonReq->{id} if(exists $r_jsonReq->{id});
  }

  return sendApiResponse($r_origin,undef,'RATE_LIMIT_EXCEEDED') if($floodCheckStatus);
  return sendApiResponse($r_origin,undef,{code => $errorCode, data => $errorData}) if(defined $errorCode);
  
  my $cmd=$r_jsonReq->{method};
  
  return sendApiResponse($r_origin,undef,'METHOD_NOT_FOUND') unless(exists $spadsApiHandlers{$cmd});
  
  my $requiredLevel=$spadsApiRights{$cmd}//$cmd;
  if(defined $requiredLevel && $requiredLevel !~ /^\d+$/) {
    my $lcEquivCmd=lc($requiredLevel);
    if(exists $spads->{commands}{$lcEquivCmd}) {
      my $r_levels=getCommandLevels('pv',$user,$lcEquivCmd);
      if(defined $r_levels->{directLevel} && $r_levels->{directLevel} ne '') {
        $requiredLevel=$r_levels->{directLevel};
      }else{
        $requiredLevel=undef;
      }
    }else{
      $requiredLevel=undef;
    }
  }

  if($requiredLevel) {
    $level//=getUserAccessLevel($user);
    if(%bosses && ! exists $bosses{$user}) {
      my $r_bossLevels=$spads->getCommandLevels('boss','battle','player','stopped');
      $level=0 unless(defined $r_bossLevels->{directLevel} && $r_bossLevels->{directLevel} ne '' && $level >= $r_bossLevels->{directLevel});
    }
  }

  return sendApiResponse($r_origin,undef,'INSUFFICIENT_PRIVILEGES') if(! defined $requiredLevel || ($requiredLevel > 0 && $level < $requiredLevel));
  
  my ($r_result,$r_error)=&{$spadsApiHandlers{$cmd}}($r_origin,$r_jsonReq->{params});
  sendApiResponse($r_origin,$r_result,$r_error) if(defined $r_result || defined $r_error);
}

sub checkJsonRpcRequest {
  my $r_jsonReq=shift;
  return 'Request has invalid JSON type' unless(ref $r_jsonReq eq 'HASH');
  return 'Missing or invalid value for "jsonrpc" member' unless(defined $r_jsonReq->{jsonrpc} && ref $r_jsonReq->{jsonrpc} eq '' && $r_jsonReq->{jsonrpc} eq '2.0');
  return 'Missing or invalid value for "method" member' unless(defined $r_jsonReq->{method} && ref $r_jsonReq->{method} eq '' && $r_jsonReq->{method} ne '');
  return 'Invalid type for "params" member' unless(! exists $r_jsonReq->{params} || (any {ref $r_jsonReq->{params} eq $_} (qw'ARRAY HASH')));
  return 'Invalid type for "id" member' unless(! exists $r_jsonReq->{id} || ref $r_jsonReq->{id} eq '');
  return 'Invalid members in request' unless(all {my $k=$_; any {$k eq $_} (qw'jsonrpc method params id')} (keys %{$r_jsonReq}));
  return undef;
}

sub sendApiResponse {
  my ($r_origin,$r_result,$r_error)=@_;
  if($r_origin->{protocol} eq 'jsonrpc') {
    my $jsonResponseString;
    if(defined $r_error) {
      my $r_jsonRpcError = ref $r_error ? createJsonRpcError(@{$r_error}{qw'code message data'}) : createJsonRpcError($r_error);
      $jsonResponseString=encodeJsonRpcResponse('error',$r_jsonRpcError,$r_origin->{jsonrpcReqId});
    }elsif(defined $r_result) {
      $jsonResponseString=encodeJsonRpcResponse('result',$r_result,$r_origin->{jsonrpcReqId});
    }else{
      slog('sendApiResponse() called with no result/error',1);
      return;
    }
    if($r_origin->{source} eq 'pv') {
      return unless($lobbyState > LOBBY_STATE_LOGGED_IN && exists $lobby->{users}{$r_origin->{user}});
      my $r_jsonResponseStrings=splitMsg($jsonResponseString,$conf{maxChatMessageLength}-length($r_origin->{user})-31);
      my $nbChunks=@{$r_jsonResponseStrings};
      if($nbChunks==1) {
        sayPrivate($r_origin->{user},'!#JSONRPC '.$r_jsonResponseStrings->[0]);
      }else{
        for my $chunkNb (1..$nbChunks) {
          sayPrivate($r_origin->{user},"!#JSONRPC($chunkNb/$nbChunks) ".$r_jsonResponseStrings->[$chunkNb-1]);
        }
      }
    }else{
      slog("sendApiResponse() called with unsupported source for JSON-RPC protocol: \"$r_origin->{source}\"",1);
      return;
    }
  }else{
    slog("sendApiResponse() called with unsupported protocol \"$r_origin->{protocol}\"",1);
    return;
  }
}

sub createJsonRpcError {
  my ($code,$message,$data)=@_;
  my %jsonError;
  if(defined $code) {
    if($code =~ /^\-?\d+$/) {
      $jsonError{code}=$code;
    }elsif(exists $JSONRPC_ERRORS{$code}) {
      $jsonError{code}=$JSONRPC_ERRORS{$code};
    }else{
      slog("Invalid JSONRPC error \"$code\" requested, creating SERVER_ERROR instead",1);
      $jsonError{code}=$JSONRPC_ERRORS{SERVER_ERROR};
    }
  }else{
    $jsonError{code}=$JSONRPC_ERRORS{UNKNOWN_ERROR}
  }
  $jsonError{message}=$message//$JSONRPC_ERRORMSGS{$jsonError{code}}//'Unknown error';
  $jsonError{data}=$data if(defined $data);
  return \%jsonError;
}

sub encodeJsonRpcResponse {
  my ($type,$response,$id)=@_;
  return encode_json({jsonrpc => '2.0', $type => $response, id => $id});
}

sub encodeJsonRpcRequest {
  my ($method,$r_params,$id)=@_;
  my %jsonReq=(jsonrpc => '2.0', method => $method);
  $jsonReq{params}=$r_params if(defined $r_params);
  $jsonReq{id}=$id if(defined $id);
  return encode_json(\%jsonReq);
}

sub invalidSyntax {
  my ($user,$cmd,$reason)=@_;
  $reason//='';
  $reason=" (".$reason.")" if($reason);
  if(exists $lobby->{users}{$user}) {
    if($lobby->{users}{$user}{status}{inGame}) {
      answer("Invalid $cmd command usage$reason.");
    }else{
      answer("Invalid $cmd command usage$reason. $user, please refer to help sent in private message.");
      executeCommand("pv",$user,["help",$cmd]);
    }
  }
}
  

sub checkTimedEvents {
  checkSpringCrash();
  handleVote();
  updateBattleInfoIfNeeded();
  checkDataDump();
  checkAutoUpdate();
  checkAutoForceStart();
  checkAutoStopTimestamp();
  checkAutoReloadArchives();
  checkCurrentMapListForLearnedMaps();
  checkAntiFloodDataPurge();
  checkAdvertMsg();
  pluginsEventLoop();
  checkPendingGetSkills();
  checkPrefCachePurge();
}

sub checkSpringCrash {
  if(%springPrematureEndData && time - $springPrematureEndData{ts} > 5) {
    my $gameRunningTime=secToTime(time-$timestamps{lastGameStart});
    $autohost->serverQuitHandler() if($autohost->{state});
    my $logMsg="Spring crashed (premature end, running time: $gameRunningTime";
    if($springPrematureEndData{signal}) {
      $logMsg.=", interrupted by signal $springPrematureEndData{signal}";
      $logMsg.=", exit code: $springPrematureEndData{ec}" if($springPrematureEndData{ec});
    }else{
      $logMsg.=", exit code: $springPrematureEndData{ec}";
    }
    $logMsg.=', core dumped' if($springPrematureEndData{core});
    $logMsg.=')';
    slog($logMsg,1);
    broadcastMsg("Spring crashed ! (running time: $gameRunningTime)");
    addAlert('SPR-001');
    $inGameTime+=time-$timestamps{lastGameStart};
    setAsOutOfGame();
  }
}

sub handleVote {
  return unless(%currentVote);
  if(time >= $currentVote{expireTime} + $conf{reCallVoteDelay}) {
    %currentVote=();
  }elsif(exists $currentVote{command}) {
    my $mustPrintVoteState=0;
    if($currentVote{awayVoteTime} && time >= $currentVote{awayVoteTime}) {
      $currentVote{awayVoteTime}=0;
      my @awayVoters;
      foreach my $remainingVoter (keys %{$currentVote{remainingVoters}}) {
        my $voteMode=getUserPref($remainingVoter,"voteMode");
        if($voteMode eq "away") {
          $currentVote{blankCount}++;
          $currentVote{awayVoters}{$remainingVoter}=1;
          delete $currentVote{remainingVoters}{$remainingVoter};
          push(@awayVoters,$remainingVoter);
        }
      }
      if(@awayVoters) {
        my $awayVotersString=join(",",@awayVoters);
        $awayVotersString=($#awayVoters+1)." users" if(length($awayVotersString) > 50);
        sayBattleAndGame("Away vote mode for $awayVotersString");
        $mustPrintVoteState=1;
      }
    }
    my @remainingVoters=keys %{$currentVote{remainingVoters}};
    my $nbRemainingVotes=$#remainingVoters+1;
    my $nbAwayVoters=keys %{$currentVote{awayVoters}};
    my $totalNbVotes=$nbRemainingVotes+$currentVote{yesCount}+$currentVote{noCount};
    my $r_cmdVoteSettings=getCmdVoteSettings(lc($currentVote{command}[0]));
    my $majorityVoteMargin=$r_cmdVoteSettings->{majorityVoteMargin};
    my $nbVotesForVotePart;
    if($majorityVoteMargin) {
      my $nbVotesForVotePartYes=int($currentVote{yesCount}*(100/(50+$majorityVoteMargin)));
      my $nbVotesForVotePartNo = $majorityVoteMargin < 50 ? ceil($currentVote{noCount}*(100/(50-$majorityVoteMargin))-1) : $currentVote{noCount}*1000;
      $nbVotesForVotePart=$nbVotesForVotePartYes>$nbVotesForVotePartNo?$nbVotesForVotePartYes:$nbVotesForVotePartNo;
    }else{
      if($currentVote{yesCount}>$currentVote{noCount}) {
        $nbVotesForVotePart=2*$currentVote{yesCount}-1;
      }elsif($currentVote{yesCount}<$currentVote{noCount}) {
        $nbVotesForVotePart=2*$currentVote{noCount}-1;
      }else{
        $nbVotesForVotePart=$currentVote{yesCount}+$currentVote{noCount};
      }
    }
    $nbVotesForVotePart+=$currentVote{blankCount}-$nbAwayVoters;
    my $minVotePart=$r_cmdVoteSettings->{minVoteParticipation};
    if($minVotePart =~ /^(\d+);(\d+)$/) {
      my ($minVotePartNoGame,$minVotePartRunningGame)=($1,$2);
      if($autohost->getState()) {
        $minVotePart=$minVotePartRunningGame;
      }else{
        $minVotePart=$minVotePartNoGame;
      }
    }
    $minVotePart/=100;
    my $votePart=$nbVotesForVotePart/($totalNbVotes+$currentVote{blankCount});
    my $nbRequiredYesVotes = $majorityVoteMargin ? ceil($totalNbVotes*(50+$majorityVoteMargin)/100) : int($totalNbVotes/2)+1;
    my $nbRequiredNoVotes = $totalNbVotes - $nbRequiredYesVotes + 1;
    if($votePart >= $minVotePart && $currentVote{yesCount} >= $nbRequiredYesVotes) {
      sayBattleAndGame("Vote for command \"".join(" ",@{$currentVote{command}})."\" passed.");
      my ($voteSource,$voteUser,$voteCommand)=($currentVote{source},$currentVote{user},$currentVote{command});
      foreach my $pluginName (@pluginsOrder) {
        $plugins{$pluginName}->onVoteStop(1) if($plugins{$pluginName}->can('onVoteStop'));
      }
      %currentVote=();
      executeCommand($voteSource,$voteUser,$voteCommand);
    }elsif($votePart >= $minVotePart && ($currentVote{noCount} >= $nbRequiredNoVotes || ! $nbRemainingVotes)) {
      sayBattleAndGame("Vote for command \"".join(" ",@{$currentVote{command}})."\" failed.");
      foreach my $pluginName (@pluginsOrder) {
        $plugins{$pluginName}->onVoteStop(-1) if($plugins{$pluginName}->can('onVoteStop'));
      }
      delete @currentVote{(qw'awayVoteTime source command remainingVoters yesCount noCount blankCount awayVoters manualVoters')};
      $currentVote{expireTime}=time;
    }elsif(time >= $currentVote{expireTime}) {
      my @awayVoters;
      my $awayVoteDelay=$r_cmdVoteSettings->{awayVoteDelay};
      if($awayVoteDelay ne '') {
        foreach my $remainingVoter (@remainingVoters) {
          my $autoSetVoteMode=getUserPref($remainingVoter,"autoSetVoteMode");
          if($autoSetVoteMode) {
            setUserPref($remainingVoter,"voteMode","away");
            push(@awayVoters,$remainingVoter);
          }
        }
      }
      my $awayVotersString="";
      if(@awayVoters) {
        $awayVotersString=join(",",@awayVoters);
        if(length($awayVotersString) > 50) {
          $awayVotersString=", away vote mode activated for ".($#awayVoters+1)." users";
        }else{
          $awayVotersString=", away vote mode activated for $awayVotersString";
        }
      }
      my $yesHasMajority;
      if($majorityVoteMargin) {
        $yesHasMajority = $currentVote{noCount} <= $currentVote{yesCount} * (100/(50+$majorityVoteMargin)-1);
      }else{
        $yesHasMajority = $currentVote{noCount} < $currentVote{yesCount};
      }
      if($yesHasMajority && $currentVote{yesCount} > 1 && $votePart >= $minVotePart) {
        sayBattleAndGame("Vote for command \"".join(" ",@{$currentVote{command}})."\" passed (delay expired$awayVotersString).");
        my ($voteSource,$voteUser,$voteCommand)=($currentVote{source},$currentVote{user},$currentVote{command});
        foreach my $pluginName (@pluginsOrder) {
          $plugins{$pluginName}->onVoteStop(1) if($plugins{$pluginName}->can('onVoteStop'));
        }
        %currentVote=();
        executeCommand($voteSource,$voteUser,$voteCommand);
      }else{
        sayBattleAndGame("Vote for command \"".join(" ",@{$currentVote{command}})."\" failed (delay expired$awayVotersString).");
        foreach my $pluginName (@pluginsOrder) {
          $plugins{$pluginName}->onVoteStop(-1) if($plugins{$pluginName}->can('onVoteStop'));
        }
        delete @currentVote{(qw'awayVoteTime source command remainingVoters yesCount noCount blankCount awayVoters manualVoters')};
      }
    }else{
      foreach my $remainingVoter (keys %{$currentVote{remainingVoters}}) {
        if($currentVote{remainingVoters}{$remainingVoter}{ringTime} && time >= $currentVote{remainingVoters}{$remainingVoter}{ringTime}) {
          $currentVote{remainingVoters}{$remainingVoter}{ringTime}=0;
          if(! exists $lastRungUsers{$remainingVoter} || time - $lastRungUsers{$remainingVoter} > getUserPref($remainingVoter,"minRingDelay")) {
            $lastRungUsers{$remainingVoter}=time;
            queueLobbyCommand(["RING",$remainingVoter]);
          }
        }
        if($currentVote{remainingVoters}{$remainingVoter}{notifyTime} && time >= $currentVote{remainingVoters}{$remainingVoter}{notifyTime}) {
          $currentVote{remainingVoters}{$remainingVoter}{notifyTime}=0;
          if(exists $lobby->{users}{$remainingVoter} && (! $lobby->{users}{$remainingVoter}{status}{inGame})) {
            my ($p_C,$B)=initUserIrcColors($remainingVoter);
            my %C=%{$p_C};
            sayPrivate($remainingVoter,"Your vote is awaited for following poll: \"$C{12}".join(" ",@{$currentVote{command}})."$C{1}\" [$C{3}!vote y$C{1}, $C{4}!vote n$C{1}, $C{14}!vote b$C{1}]");
          }
        }
      }
      printVoteState() if($mustPrintVoteState);
    }
  }
}

sub checkDataDump {
  if($conf{dataDumpDelay} && time - $timestamps{dataDump} > 60 * $conf{dataDumpDelay}) {
    pingIfNeeded();
    $spads->dumpDynamicData();
    $timestamps{dataDump}=time;
  }
}

sub checkPrefCachePurge {
  if(time - $timestamps{prefCachePurge} > 5) {
    foreach my $user (keys %prefCacheTs) {
      if(time - $prefCacheTs{$user} > 60) {
        delete $prefCacheTs{$user};
        delete $prefCache{$user};
      }
    }
    $timestamps{prefCachePurge}=time;
  }
}

sub acquireAutoUpdateLock {
  return 1 if($periodicAutoUpdateLockAcquired);
  my $autoUpdateLockFile=catfile($spadsDir,'autoUpdate.lock');
  if(open($auLockFh,'>',$autoUpdateLockFile)) {
    if(flock($auLockFh, LOCK_EX|LOCK_NB)) {
      SimpleEvent::win32HdlDisableInheritance($auLockFh) if(MSWIN32);
      slog('Auto-update has been automatically re-enabled on this instance (auto-update was previously managed by another instance running from same directory)',3) if(defined $periodicAutoUpdateLockAcquired);
      $periodicAutoUpdateLockAcquired=1;
    }else{
      close($auLockFh);
      if(! defined $periodicAutoUpdateLockAcquired) {
        $periodicAutoUpdateLockAcquired=0;
        slog('Auto-update has been automatically disabled on this instance (auto-update is already managed by another instance running from same directory)',3);
      }
    }
  }else{
    slog("Unable to write SPADS auto-update lock file \"$autoUpdateLockFile\", bypassing concurrent auto-update check ($!)",1);
    $periodicAutoUpdateLockAcquired=1;
  }
  return $periodicAutoUpdateLockAcquired;
}

sub checkAutoUpdate {
  if($conf{autoUpdateRelease} ne '' && (substr($conf{autoUpdateRelease},0,4) ne 'git@' || substr($conf{autoUpdateRelease},4,7) eq 'branch=')
     && $conf{autoUpdateDelay} && time - $timestamps{autoUpdate} > 60 * $conf{autoUpdateDelay}) {
    $timestamps{autoUpdate}=time;
    if(acquireAutoUpdateLock()) {
      if($updater->isUpdateInProgress()) {
        slog('Skipping auto-update check, another updater instance is already running',2);
      }else{
        if(! SimpleEvent::forkCall(
               sub { return $updater->update() },
               sub {
                 my $updateRc = shift // -12;
                 if($updateRc < 0) {
                   slog('Unable to check or apply SPADS update',2);
                 }
                 onUpdaterCallEnd($updateRc);
               })) {
          slog('Unable to fork to launch SPADS updater',1);
        }
      }
    }
  }
  if(isRestartForUpdateApplicable() && time - $timestamps{autoRestartCheck} > 300 && (! $updater->isUpdateInProgress())) {
    autoRestartForUpdateIfNeeded();
  }
}

sub engineVersionAutoManagement {
  if($engineVersionAutoManagementInProgress) {
    slog('Skipping engine version auto-management run, previous run is still running...',4);
    return;
  }
  slog('Starting engine version auto-management',5);
  $engineVersionAutoManagementInProgress=1;
  if(! SimpleEvent::forkCall(sub {return $updater->resolveEngineReleaseNameToVersion($autoManagedEngineData{release},$autoManagedEngineData{github})},
                             \&resolveEngineReleaseNameToVersionPostActions)) {
    slog('Unable to fork to perform engine release resolution',1);
    $engineVersionAutoManagementInProgress=0;
  }
}

sub resolveEngineReleaseNameToVersionPostActions {
  my ($autoManagedEngineVersion,$releaseTag)=@_;
  
  $engineVersionAutoManagementInProgress=0;
  my $engineStr = defined $autoManagedEngineData{github} ? 'engine' : 'Spring';
  if(! defined $autoManagedEngineVersion) {
    slog("Unable to identify current version of auto-managed $autoManagedEngineData{release} $engineStr release, skipping $engineStr version auto-management",2);
    return;
  }
  slog("Engine release resolved to version $autoManagedEngineVersion".(defined $releaseTag ? " (GitHub release tag $releaseTag)" : ''),5);
  return if($autoManagedEngineVersion eq $autoManagedEngineData{version});
  if(defined $failedEngineInstallVersion && $failedEngineInstallVersion eq $autoManagedEngineVersion) {
    slog("Installation failed previously for $engineStr version $failedEngineInstallVersion, skipping $engineStr version auto-management",5);
    return;
  }
  slog("New version detected for $autoManagedEngineData{release} $engineStr release: $autoManagedEngineVersion",3);
  if($updater->isEngineSetupInProgress($autoManagedEngineVersion,$autoManagedEngineData{github})) {
    slog("Skipping installation of $engineStr $autoManagedEngineVersion, another process is already installing this version",2);
    return;
  }
  
  $engineVersionAutoManagementInProgress=1;
  if(! SimpleEvent::forkCall(sub {return $updater->setupEngine($autoManagedEngineVersion,$releaseTag,$autoManagedEngineData{github})},
                             sub {setupEnginePostActions($autoManagedEngineVersion,@_)})) {
    slog('Unable to fork to perform engine installation',1);
    $engineVersionAutoManagementInProgress=0;
  }
}

sub setupEnginePostActions {
  my ($autoManagedEngineVersion,$setupResult)=@_;
  $engineVersionAutoManagementInProgress=0;
  my $engineStr = defined $autoManagedEngineData{github} ? 'engine' : 'Spring';
  if(! defined $setupResult) {
    slog("Unknown error during installation of $engineStr $autoManagedEngineVersion",1);
    return;
  }
  if($setupResult < 0) {
    my $setupFailedMsg="Unable to install $engineStr $autoManagedEngineVersion for version auto-management";
    if($setupResult < -9) {
      $failedEngineInstallVersion=$autoManagedEngineVersion;
      $setupFailedMsg.=", keeping current version ($autoManagedEngineData{version})";
    }
    slog($setupFailedMsg,2);
    return;
  }
  broadcastMsg("Installed new version for $autoManagedEngineData{release} $engineStr release: $autoManagedEngineVersion") if($setupResult > 0);
  $autoManagedEngineData{version}=$autoManagedEngineVersion;
  my $autoManagedEngineFile=catfile($conf{instanceDir},'autoManagedEngineVersion.dat');
  nstore(\%autoManagedEngineData,$autoManagedEngineFile)
      or slog("Unable to write auto-managed $engineStr version file \"$autoManagedEngineFile\"",2);
  applyQuitAction(1,{on => 0, whenOnlySpec => 1, whenEmpty => 2}->{$autoManagedEngineData{restart}},$engineStr.' version auto-management') unless($autoManagedEngineData{restart} eq 'off');
}

sub checkAutoForceStart {
  if($timestamps{autoForcePossible} > 0 && time - $timestamps{autoForcePossible} > 5 && $autohost->getState() == 1) {
    $timestamps{autoForcePossible}=-2;
    my $alreadyBroadcasted=0;
    if(%currentVote && exists $currentVote{command} && @{$currentVote{command}}) {
      my $command=lc($currentVote{command}[0]);
      if($command eq "forcestart") {
        foreach my $pluginName (@pluginsOrder) {
          $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
        }
        %currentVote=();
        $alreadyBroadcasted=1;
        broadcastMsg("Cancelling \"forceStart\" vote, auto-forcing game start (only already in-game or unsynced spectators are missing)");
      }
    }
    broadcastMsg("Auto-forcing game start (only already in-game or unsynced spectators are missing)") unless($alreadyBroadcasted);
    $autohost->sendChatMessage("/forcestart");
    logMsg("game","> /forcestart") if($conf{logGameChat});
  }
}

sub checkAutoStopTimestamp {
  if($springPid && $autohost->getState() && $timestamps{autoStop} > 0 && time-$timestamps{autoStop} >= 0) {
    $timestamps{autoStop}=-1;
    $autohost->sendChatMessage("/kill");
  }
}

sub checkAutoReloadArchives {
  if($conf{autoReloadArchivesMinDelay} && time - $timestamps{archivesCheck} > 60 && ! $loadArchivesInProgress) {
    slog("Checking Spring archives for auto-reload",5);
    $timestamps{archivesCheck}=time;
    my $archivesChangeTs=getArchivesChangeTime();
    if($archivesChangeTs > $timestamps{archivesLoadFull} && time - $archivesChangeTs > $conf{autoReloadArchivesMinDelay}) {
      my $archivesChangeDelay=secToTime(time - $archivesChangeTs);
      slog("Spring archives have been modified $archivesChangeDelay ago, auto-reloading archives...",3);
      loadArchives(sub {quitAfterGame('Unable to auto-reload Spring archives') unless(shift)},1);
    }
  }
}

sub checkCurrentMapListForLearnedMaps {
  if($timestamps{mapLearned} && time - $timestamps{mapLearned} > 5) {
    slog("Applying current map list for new maps learned automatically",5);
    $timestamps{mapLearned}=0;
    $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  }
}

sub checkAntiFloodDataPurge {
  if(time - $timestamps{floodPurge} > 3600) {
    $timestamps{floodPurge}=time;
    slog("Purging flood records",5);
    my @msgAutoKickData=split(/;/,$conf{msgFloodAutoKick});
    my @statusAutoKickData=split(/;/,$conf{statusFloodAutoKick});
    my @autoBanData=split(/;/,$conf{kickFloodAutoBan});
    foreach my $u (keys %lastBattleMsg) {
      foreach my $t (keys %{$lastBattleMsg{$u}}) {
        delete $lastBattleMsg{$u}{$t} if(time - $t > $msgAutoKickData[1]);
      }
      delete $lastBattleMsg{$u} unless(%{$lastBattleMsg{$u}});
    }
    foreach my $u (keys %lastBattleStatus) {
      foreach my $t (keys %{$lastBattleStatus{$u}}) {
        delete $lastBattleStatus{$u}{$t} if(time - $t > $statusAutoKickData[1]);
      }
      delete $lastBattleStatus{$u} unless(%{$lastBattleStatus{$u}});
    }
    foreach my $u (keys %lastFloodKicks) {
      foreach my $t (keys %{$lastFloodKicks{$u}}) {
        delete $lastFloodKicks{$u}{$t} if(time - $t > $autoBanData[1]);
      }
      delete $lastFloodKicks{$u} unless(%{$lastFloodKicks{$u}});
    }
    foreach my $u (keys %ignoredUsers) {
      delete $ignoredUsers{$u} if(time > $ignoredUsers{$u});
    }
    foreach my $u (keys %ignoredRelayedApiUsers) {
      delete $ignoredRelayedApiUsers{$u} if(time > $ignoredRelayedApiUsers{$u});
    }
  }
}

sub checkAdvertMsg {
  if($conf{advertDelay} && $conf{advertMsg} ne '' && $lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}}) {
    if(time - $timestamps{advert} > $conf{advertDelay} * 60) {
      my @battleUsers=keys %{$lobby->{battle}{users}};
      if($#battleUsers > 0 && ! $autohost->getState()) {
        my @advertMsgs=@{$spads->{values}{advertMsg}};
        foreach my $advertMsg (@advertMsgs) {
          sayBattle($advertMsg) if($advertMsg);
        }
      }
      $timestamps{advert}=time;
    }
  }
}

sub pluginsEventLoop {
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->eventLoop() if($plugins{$pluginName}->can('eventLoop'));
  }
}

sub checkPendingGetSkills {
  my $needRebalance=0;
  foreach my $accountId (keys %pendingGetSkills) {
    if(time - $pendingGetSkills{$accountId} > 5) {
      delete($pendingGetSkills{$accountId});
      next if($lobbyState < LOBBY_STATE_SYNCHRONIZED || ! exists $lobby->{accounts}{$accountId});
      my $player=$lobby->{accounts}{$accountId};
      next unless(exists $battleSkills{$player});
      my $skillPref=getUserPref($player,'skillMode');
      slog("Timeout for getSkill on player $player (account $accountId)",2) if($skillPref eq 'TrueSkill');
      my $previousPlayerSkill=$battleSkills{$player}{skill};
      pluginsUpdateSkill($battleSkills{$player},$accountId);
      sendPlayerSkill($player);
      checkBattleBansForPlayer($player);
      $needRebalance=1 if($previousPlayerSkill != $battleSkills{$player}{skill} && $lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$player}
                          && defined $lobby->{battle}{users}{$player}{battleStatus} && $lobby->{battle}{users}{$player}{battleStatus}{mode});
    }
  }
  if($needRebalance) {
    $balanceState=0;
    %balanceTarget=();
  }
}

sub autoRestartForUpdateIfNeeded {
  $timestamps{autoRestartCheck}=time;
  my $updateTimestamp=0;
  if(-f "$spadsDir/updateInfo.txt") {
    if(open(UPDATE_INFO,"<$spadsDir/updateInfo.txt")) {
      while(local $_ = <UPDATE_INFO>) {
        if(/^(\d+)$/) {
          $updateTimestamp=$1 if($1 > $updateTimestamp);
        }
      }
      close(UPDATE_INFO);
    }else{
      slog("Unable to read \"$spadsDir/updateInfo.txt\" file",1);
    }
  }
  applyQuitAction(1,{on => 0, whenOnlySpec => 1, whenEmpty => 2}->{$conf{autoRestartForUpdate}},'auto-update') if($updateTimestamp > $timestamps{autoHostStart});
}

sub getVoteStateMsg {
  return (undef,undef,undef) unless(%currentVote && exists $currentVote{command});
  my @remainingVoters=keys %{$currentVote{remainingVoters}};
  my $nbRemainingVotes=$#remainingVoters+1;
  my $nbAwayVoters=keys %{$currentVote{awayVoters}};
  my $totalNbVotes=$nbRemainingVotes+$currentVote{yesCount}+$currentVote{noCount};
  my $r_cmdVoteSettings=getCmdVoteSettings(lc($currentVote{command}[0]));
  my $majorityVoteMargin=$r_cmdVoteSettings->{majorityVoteMargin};
  my $nbVotesForVotePart;
  if($majorityVoteMargin) {
    my $nbVotesForVotePartYes=int($currentVote{yesCount}*(100/(50+$majorityVoteMargin)));
    my $nbVotesForVotePartNo = $majorityVoteMargin < 50 ? ceil($currentVote{noCount}*(100/(50-$majorityVoteMargin))-1) : $currentVote{noCount}*1000;
    $nbVotesForVotePart=$nbVotesForVotePartYes>$nbVotesForVotePartNo?$nbVotesForVotePartYes:$nbVotesForVotePartNo;
  }else{
    if($currentVote{yesCount}>$currentVote{noCount}) {
      $nbVotesForVotePart=2*$currentVote{yesCount}-1;
    }elsif($currentVote{yesCount}<$currentVote{noCount}) {
      $nbVotesForVotePart=2*$currentVote{noCount}-1;
    }else{
      $nbVotesForVotePart=$currentVote{yesCount}+$currentVote{noCount};
    }
  }
  $nbVotesForVotePart+=$currentVote{blankCount}-$nbAwayVoters;
  my $minVotePart=$r_cmdVoteSettings->{minVoteParticipation};
  if($minVotePart =~ /^(\d+);(\d+)$/) {
    my ($minVotePartNoGame,$minVotePartRunningGame)=($1,$2);
    if($autohost->getState()) {
      $minVotePart=$minVotePartRunningGame;
    }else{
      $minVotePart=$minVotePartNoGame;
    }
  }
  my $nbRequiredManualVotes=ceil($minVotePart * ($totalNbVotes+$currentVote{blankCount}) / 100);
  my $nbRequiredYesNoVotes=$nbRequiredManualVotes-($currentVote{blankCount}-$nbAwayVoters);
  my ($reqYesVotes,$maxReqYesVotes,$minReqYesVotes);
  if($majorityVoteMargin) {
    ($reqYesVotes,$maxReqYesVotes,$minReqYesVotes) = map {ceil($_*(50+$majorityVoteMargin)/100)} ($totalNbVotes,$totalNbVotes+$nbAwayVoters,$nbRequiredYesNoVotes);
  }else{
    ($reqYesVotes,$maxReqYesVotes,$minReqYesVotes) = map {int($_/2)+1} ($totalNbVotes,$totalNbVotes+$nbAwayVoters,$nbRequiredYesNoVotes);
  }
  my $reqNoVotes=$totalNbVotes-$reqYesVotes+1;
  my $maxReqNoVotes=$totalNbVotes+$nbAwayVoters-$maxReqYesVotes+1;
  my $minReqNoVotes=$nbRequiredYesNoVotes-$minReqYesVotes+1;
  $reqYesVotes=$minReqYesVotes if($reqYesVotes < $minReqYesVotes);
  $reqNoVotes=$minReqNoVotes if($reqNoVotes < $minReqNoVotes);
  my ($lobbyMsg,$gameMsg,$additionalMsg);
  if($nbVotesForVotePart < $nbRequiredManualVotes || (@remainingVoters && $currentVote{yesCount} < $reqYesVotes && $currentVote{noCount} < $reqNoVotes)) {
    my $maxYesVotesString = $reqYesVotes < $maxReqYesVotes ? "($maxReqYesVotes)" : '';
    my $maxNoVotesString = $reqNoVotes < $maxReqNoVotes ? "($maxReqNoVotes)" : '';
    my $remainingTime=$currentVote{expireTime} - time;
    $lobbyMsg="Vote in progress: \"".join(" ",@{$currentVote{command}})."\" [y:$currentVote{yesCount}/$reqYesVotes$maxYesVotesString, n:$currentVote{noCount}/$reqNoVotes$maxNoVotesString] (${remainingTime}s remaining)";
    my ($pluginLobbyMsg,$pluginGameMsg);
    foreach my $pluginName (@pluginsOrder) {
      ($pluginLobbyMsg,$pluginGameMsg)=$plugins{$pluginName}->setVoteMsg($reqYesVotes,$maxReqYesVotes,$reqNoVotes,$maxReqNoVotes,$nbRequiredManualVotes) if($plugins{$pluginName}->can('setVoteMsg'));
      last if(defined $pluginLobbyMsg && defined $pluginGameMsg);
    }
    if(defined $pluginGameMsg) {
      $gameMsg=$pluginGameMsg;
    }else{
      $gameMsg=$lobbyMsg;
    }
    $lobbyMsg=$pluginLobbyMsg if(defined $pluginLobbyMsg);
    if(@remainingVoters) {
      my $remainingVotersString=join(",",@remainingVoters);
      if(length($remainingVotersString) < 50) {
        $remainingVotersString="Awaiting following vote(s): $remainingVotersString";
        $remainingVotersString.=" (and $nbAwayVoters away-mode vote(s))" if($nbAwayVoters);
        $additionalMsg=$remainingVotersString;
      }
    }
  }
  return ($lobbyMsg,$gameMsg,$additionalMsg);
}

sub printVoteState {
  my ($lobbyMsg,$gameMsg,$additionalMsg)=getVoteStateMsg();
  sayBattle($lobbyMsg) if(defined $lobbyMsg);
  sayGame($gameMsg) if(defined $gameMsg);
  sayBattleAndGame($additionalMsg) if(defined $additionalMsg);
}

sub rotatePreset {
  my ($rotationMode,$verbose)=@_;

  return unless(%{$lobby->{battle}});

  my $nbPlayers=0;
  my %battleUsers=%{$lobby->{battle}{users}};
  foreach my $user (keys %battleUsers) {
    $nbPlayers++ if(defined $battleUsers{$user}{battleStatus} && $battleUsers{$user}{battleStatus}{mode});
  }

  my @allowedPresets=@{$spads->{values}{preset}};
  my %presetsBs;
  foreach my $allowedPreset (@allowedPresets) {
    my ($nbTeams,$teamSize,$nbPlayerById)=getPresetBattleStructure($allowedPreset,$nbPlayers);
    $presetsBs{$allowedPreset}=[$nbTeams,$teamSize,$nbPlayerById] if($nbTeams*$teamSize*$nbPlayerById != 0);
  }
  my @presets=keys %presetsBs;
  if(! @presets) {
    slog("Unable to find any allowed preset compatible with current number of players ($nbPlayers), keeping current preset",2);
    sayBattleAndGame("No allowed preset compatible with current number of player, preset rotation cancelled") if($verbose);
    return;
  }elsif($#presets == 0 && $presets[0] eq $conf{preset}) {
    slog("Unable to find any other allowed preset compatible with current number of players ($nbPlayers), keeping current preset",2);
    sayBattleAndGame("No other allowed preset compatible with current number of player, preset rotation cancelled") if($verbose);
    return;
  }

  my ($oldPreset,$preset)=($conf{preset},$conf{preset});
  my $rotationMsg;
  if($rotationMode eq "random") {
    my $presetIndex=int(rand($#presets+1));
    if($#presets > 0) {
      while($conf{preset} eq $presets[$presetIndex]) {
        $presetIndex=int(rand($#presets+1));
      }
    }
    $preset=$presets[$presetIndex];
    $rotationMsg="Automatic random preset rotation: next preset is \"$preset\"";
  }else{
    my $nextPresetIndex=-1;
    for my $presetIndex (0..$#presets) {
      if($conf{preset} eq $presets[$presetIndex]) {
        $nextPresetIndex=$presetIndex+1;
        $nextPresetIndex=0 if($nextPresetIndex > $#presets);
        last;
      }
    }
    if($nextPresetIndex == -1) {
      if(@presets) {
        slog("Unable to find current preset for preset rotation, using first preset",2);
        $nextPresetIndex=0;
      }else{
        slog("Unable to find current preset for preset rotation, keeping current preset",2);
        return;
      }
    }
    $preset=$presets[$nextPresetIndex];
    $rotationMsg="Automatic preset rotation: next preset is \"$preset\"";
  }
  $spads->applyPreset($preset);
  $spads->{conf}{nbTeams}=$presetsBs{$preset}[0];
  $spads->{conf}{teamSize}=$presetsBs{$preset}[1];
  $spads->{conf}{nbPlayerById}=$presetsBs{$preset}[2];
  $timestamps{mapLearned}=0;
  $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  setDefaultMapOfMaplist() if($spads->{conf}{map} eq '');
  %conf=%{$spads->{conf}};
  applyAllSettings();
  updateTargetMod();
  $rotationMsg.=" (some pending settings need rehosting to be applied)" if(needRehost());
  sayBattleAndGame($rotationMsg) if($verbose);
  pluginsOnPresetApplied($oldPreset,$preset);
}

sub rotateMap {
  my ($rotationMode,$verbose)=@_;

  return unless(%{$lobby->{battle}});

  my $nbPlayers=0;
  my %battleUsers=%{$lobby->{battle}{users}};
  foreach my $user (keys %battleUsers) {
    $nbPlayers++ if(defined $battleUsers{$user}{battleStatus} && $battleUsers{$user}{battleStatus}{mode});
  }

  my $p_maps;
  if($conf{rotationType} =~ /;(.+)$/) {
    my $subMapList=$1;
    $p_maps=$spads->applySubMapList($subMapList);
  }else{
    $p_maps=$spads->applySubMapList();
  }

  my $p_filteredMaps=[];
  my %mapsBs;
  if($conf{autoLoadMapPreset}) {
    my %badMapPresets;
    foreach my $mapName (@{$p_maps}) {
      my $smfMapName=$mapName;
      $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
      my $mapPreset;
      if(exists $spads->{presets}{$smfMapName}) {
        $mapPreset=$smfMapName;
      }elsif(exists $spads->{presets}{"_DEFAULT_.smf"}) {
        $mapPreset="_DEFAULT_.smf";
      }
      if(defined $mapPreset) {
        if(exists $mapsBs{$mapPreset}) {
          push(@{$p_filteredMaps},$mapName);
        }elsif(! exists $badMapPresets{$mapPreset}) {
          my ($nbTeams,$teamSize,$nbPlayerById)=getPresetBattleStructure($mapPreset,$nbPlayers);
          if($nbTeams*$teamSize*$nbPlayerById != 0) {
            $mapsBs{$mapPreset}=[$nbTeams,$teamSize,$nbPlayerById];
            push(@{$p_filteredMaps},$mapName);
          }else{
            $badMapPresets{$mapPreset}=1;
          }
        }
      }else{
        push(@{$p_filteredMaps},$mapName);
      }
    }
  }else{
    $p_filteredMaps=$p_maps;
  }

  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('filterRotationMaps')) {
      $p_filteredMaps=$plugins{$pluginName}->filterRotationMaps($p_filteredMaps);
    }
  }

  if(! @{$p_filteredMaps}) {
    slog("Unable to find any allowed map compatible with current number of players ($nbPlayers), keeping current map",2);
    sayBattleAndGame("No allowed map compatible with current number of player, map rotation cancelled") if($verbose);
    return;
  }elsif($#{$p_filteredMaps} == 0 && $p_filteredMaps->[0] eq $conf{map}) {
    if(@{$p_maps} > 1) {
      slog("Unable to find any other allowed map compatible with current number of players ($nbPlayers), keeping current map",2);
      sayBattleAndGame("No other allowed map compatible with current number of player, map rotation cancelled") if($verbose);
    }
    return;
  }

  if($rotationMode eq "random") {
    my $mapIndex=int(rand($#{$p_filteredMaps}+1));
    if($#{$p_filteredMaps} > 0) {
      while($conf{map} eq $p_filteredMaps->[$mapIndex]) {
        $mapIndex=int(rand($#{$p_filteredMaps}+1));
      }
    }
    $spads->{conf}{map}=$p_filteredMaps->[$mapIndex];
    %conf=%{$spads->{conf}};
    applySettingChange("map");
    sayBattleAndGame("Automatic random map rotation: next map is \"$conf{map}\"") if($verbose);
  }else{
    my $nextMapIndex=-1;
    for my $mapIndex (0..$#{$p_filteredMaps}) {
      if($p_filteredMaps->[$mapIndex] eq $conf{map}) {
        $nextMapIndex=$mapIndex+1;
        $nextMapIndex=0 if($nextMapIndex > $#{$p_filteredMaps});
        last;
      }
    }
    if($nextMapIndex == -1) {
      slog("Unable to find current map for map rotation, using first map",3);
      $nextMapIndex=0;
    }
    $spads->{conf}{map}=$p_filteredMaps->[$nextMapIndex];
    %conf=%{$spads->{conf}};
    applySettingChange("map");
    sayBattleAndGame("Automatic map rotation: next map is \"$conf{map}\"") if($verbose);
  }
  if($conf{autoLoadMapPreset}) {
    my $smfMapName=$conf{map};
    $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
    my $mapPreset;
    if(exists $spads->{presets}{$smfMapName}) {
      $mapPreset=$smfMapName;
    }elsif(exists $spads->{presets}{"_DEFAULT_.smf"}) {
      $mapPreset="_DEFAULT_.smf";
    }
    if(defined $mapPreset) {
      my $oldPreset=$conf{preset};
      $spads->applyPreset($mapPreset);
      $spads->{conf}{nbTeams}=$mapsBs{$mapPreset}[0];
      $spads->{conf}{teamSize}=$mapsBs{$mapPreset}[1];
      $spads->{conf}{nbPlayerById}=$mapsBs{$mapPreset}[2];
      $timestamps{mapLearned}=0;
      $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
      setDefaultMapOfMaplist() if($spads->{conf}{map} eq '');
      %conf=%{$spads->{conf}};
      applyAllSettings();
      updateTargetMod();
      pluginsOnPresetApplied($oldPreset,$mapPreset);
    }
  }
}

sub setAsOutOfGame {
  %springPrematureEndData=();
  if($lobbyState > LOBBY_STATE_LOGGED_IN) {
    my %clientStatus = %{$lobby->{users}{$conf{lobbyLogin}}{status}};
    $clientStatus{inGame}=0;
    queueLobbyCommand(["MYSTATUS",$lobby->marshallClientStatus(\%clientStatus)]);
    queueLobbyCommand(["GETUSERINFO"]);
  }
  queueGDR();
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onSpringStop($springPid) if($plugins{$pluginName}->can('onSpringStop'));
  }
  $p_runningBattle={};
  %runningBattleMapping=();
  %runningBattleReversedMapping=();
  $p_gameOverResults={};
  %defeatTimes=();
  %inGameAddedUsers=();
  %inGameAddedPlayers=();
  $springPid=0;
  $timestamps{lastGameEnd}=time;
  $spads->decreaseGameBasedBans() if($timestamps{lastGameStartPlaying} >= $timestamps{lastGameStart});
  if($lobbyState > LOBBY_STATE_OPENING_BATTLE) {
    if($conf{rotationEndGame} ne "off" && $timestamps{lastGameStartPlaying} >= $timestamps{lastGameStart} && time - $timestamps{lastGameStartPlaying} > $conf{rotationDelay}) {
      $timestamps{autoRestore}=time;
      if($conf{rotationType} eq "preset") {
        rotatePreset($conf{rotationEndGame},1);
      }else{
        rotateMap($conf{rotationEndGame},1);
      }
    }
  }
  foreach my $notifiedUser (keys %pendingNotifications) {
    sayPrivate($notifiedUser,"***** End-game notification *****") if($lobbyState > LOBBY_STATE_LOGGED_IN && exists $lobby->{users}{$notifiedUser});
    delete($pendingNotifications{$notifiedUser});
  }
  $balRandSeed=intRand();
  $balanceState=0;
  %balanceTarget=();
}

sub isBalanceTargetApplied {
  my $p_battle=$lobby->getBattle();

  my $p_players=$p_battle->{users};
  my $p_bots=$p_battle->{bots};

  foreach my $player (keys %{$p_players}) {
    return 0 unless(defined $p_players->{$player}{battleStatus});
    delete($p_players->{$player}) unless($p_players->{$player}{battleStatus}{mode});
  }

  my $p_balancedPlayers=$balanceTarget{players};
  my $p_balancedBots=$balanceTarget{bots};

  my @players = keys %{$p_players};
  my @bots = keys %{$p_bots};
  my @balancedPlayers = keys %{$p_balancedPlayers};
  my @balancedBots = keys %{$p_balancedBots};

  return 0 unless($#players == $#balancedPlayers);
  return 0 unless($#bots == $#balancedBots);

  foreach my $player (@players) {
    return 0 unless(exists $p_balancedPlayers->{$player});
    return 0 unless($p_players->{$player}{battleStatus}{team} == $p_balancedPlayers->{$player}{battleStatus}{team});
    return 0 unless($p_players->{$player}{battleStatus}{id} == $p_balancedPlayers->{$player}{battleStatus}{id});
  }

  foreach my $bot (@bots) {
    return 0 unless(exists $p_balancedBots->{$bot});
    return 0 unless($p_bots->{$bot}{battleStatus}{team} == $p_balancedBots->{$bot}{battleStatus}{team});
    return 0 unless($p_bots->{$bot}{battleStatus}{id} == $p_balancedBots->{$bot}{battleStatus}{id});
  }

  return 1;
}

sub areColorsApplied {
  my $p_battle=$lobby->getBattle();

  my $p_players=$p_battle->{users};
  my $p_bots=$p_battle->{bots};

  foreach my $player (keys %{$p_players}) {
    return 0 unless(defined $p_players->{$player}{battleStatus});
    next unless($p_players->{$player}{battleStatus}{mode});
    my $colorId=$p_players->{$player}{battleStatus}{id};
    return 0 unless exists($colorsTarget{$colorId});
    return 0 unless(colorDistance($colorsTarget{$colorId},$p_players->{$player}{color}) == 0);
  }
  foreach my $bot (keys %{$p_bots}) {
    my $colorId=$p_bots->{$bot}{battleStatus}{id};
    return 0 unless exists($colorsTarget{$colorId});
    return 0 unless(colorDistance($colorsTarget{$colorId},$p_bots->{$bot}{color}) == 0);
  }

  return 1;
}

sub applyBalanceTarget {
  my $p_battle=$lobby->getBattle();

  my $p_players=$p_battle->{users};
  my $p_bots=$p_battle->{bots};

  my $p_balancedPlayers=$balanceTarget{players};
  my $p_balancedBots=$balanceTarget{bots};

  my $newBalanceState=1;
  foreach my $player (keys %{$p_balancedPlayers}) {
    if($p_players->{$player}{battleStatus}{team} != $p_balancedPlayers->{$player}{battleStatus}{team}) {
      $newBalanceState=0;
      queueLobbyCommand(["FORCEALLYNO",$player,$p_balancedPlayers->{$player}{battleStatus}{team}]);
    }
    if($p_players->{$player}{battleStatus}{id} != $p_balancedPlayers->{$player}{battleStatus}{id}) {
      $newBalanceState=0;
      queueLobbyCommand(["FORCETEAMNO",$player,$p_balancedPlayers->{$player}{battleStatus}{id}]);
    }
  }

  foreach my $bot (keys %{$p_balancedBots}) {
    my $updateNeeded=0;
    if($p_bots->{$bot}{battleStatus}{team} != $p_balancedBots->{$bot}{battleStatus}{team}) {
      $updateNeeded=1;
      $newBalanceState=0;
      $p_bots->{$bot}{battleStatus}{team}=$p_balancedBots->{$bot}{battleStatus}{team};
    }
    if($p_bots->{$bot}{battleStatus}{id} != $p_balancedBots->{$bot}{battleStatus}{id}) {
      $updateNeeded=1;
      $newBalanceState=0;
      $p_bots->{$bot}{battleStatus}{id} = $p_balancedBots->{$bot}{battleStatus}{id};
    }
    queueLobbyCommand(["UPDATEBOT",$bot,$lobby->marshallBattleStatus($p_bots->{$bot}{battleStatus}),$lobby->marshallColor($p_bots->{$bot}{color})]) if($updateNeeded);
  }
  
  $timestamps{balance}=time unless($newBalanceState);
  $balanceState=$newBalanceState;
  $colorsState=0 unless($balanceState);

}

sub applyColorsTarget {
  my $autoBalanceInProgress=shift;

  my $p_battle=$lobby->getBattle();

  my $p_players=$p_battle->{users};
  my $p_bots=$p_battle->{bots};

  my ($p_targetPlayers,$p_targetBots);
  if($autoBalanceInProgress) {
    $p_targetPlayers=$balanceTarget{players};
    $p_targetBots=$balanceTarget{bots};
  }else{
    $p_targetPlayers=$p_players;
    $p_targetBots=$p_bots;
  }
  
  my $newColorsState=1;
  foreach my $player (keys %{$p_players}) {
    if(! defined $p_players->{$player}{battleStatus}) {
      $newColorsState=0;
      next;
    }
    next unless($p_players->{$player}{battleStatus}{mode});
    my $colorId=$p_targetPlayers->{$player}{battleStatus}{id};
    if(colorDistance($colorsTarget{$colorId},$p_players->{$player}{color}) != 0) {
      $newColorsState=0;
      queueLobbyCommand(["FORCETEAMCOLOR",$player,$lobby->marshallColor($colorsTarget{$colorId})]);
    }
  }
  foreach my $bot (keys %{$p_bots}) {
    my $colorId=$p_targetBots->{$bot}{battleStatus}{id};
    if(colorDistance($colorsTarget{$colorId},$p_bots->{$bot}{color}) != 0) {
      $newColorsState=0;
      queueLobbyCommand(["UPDATEBOT",
                         $bot,
                         $lobby->marshallBattleStatus($p_targetBots->{$bot}{battleStatus}),
                         $lobby->marshallColor($colorsTarget{$colorId})]);
    }
  }

  $timestamps{fixColors}=time unless($newColorsState);
  $colorsState=$newColorsState;
}

sub balance {
  return (undef,undef) if(%pendingGetSkills);
  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('canBalanceNow')) {
      my $canBalance=$plugins{$pluginName}->canBalanceNow();
      return (undef,undef) unless($canBalance);
      last;
    }
  }
  my ($nbSmurfs,$unbalanceIndicator,$p_players,$p_bots);
  if($conf{nbTeams} == 1) {
    $unbalanceIndicator=0;
    my $p_battle=$lobby->getBattle();
    $p_players=$p_battle->{users};
    $p_bots=$p_battle->{bots};
    ($nbSmurfs)=balanceBattle($p_players,{},$conf{clanMode});
    my $maxId=0;
    foreach my $p (keys %{$p_players}) {
      $maxId=$p_players->{$p}{battleStatus}{id} if($p_players->{$p}{battleStatus}{id} > $maxId);
    }
    foreach my $b (keys %{$p_bots}) {
      $p_bots->{$b}{battleStatus}{team}=1;
      $p_bots->{$b}{battleStatus}{id}=++$maxId;
    }
  }elsif($conf{balanceMode} eq 'clan;skill' && $conf{clanMode} =~ /\(\d+\)/) {
    slog("Balance mode is set to \"clan;skill\" and clan mode \"$conf{clanMode}\" contains unbalance threshold(s)",5);
    my @currentClanModes;
    my $clanModesString='';
    my @remainingClanModes=split(';',$conf{clanMode});
    my $unbalanceIndicatorRef;
    while(@remainingClanModes) {
      my $testClanMode=shift(@remainingClanModes);
      if($testClanMode =~ /^(\w+)\((\d+)\)$/) {
        my ($mode,$maxUnbalance)=($1,$2);
        slog("Testing \"$testClanMode\" (mode=$mode, unbalance threshold=$maxUnbalance\%)",5);
        if(! defined $unbalanceIndicator) {
          my $p_battle=$lobby->getBattle();
          $p_players=$p_battle->{users};
          $p_bots=$p_battle->{bots};
          $clanModesString=join(";",@currentClanModes);
          ($nbSmurfs,$unbalanceIndicator)=balanceBattle($p_players,$p_bots,$clanModesString);
          $unbalanceIndicatorRef//=$unbalanceIndicator;
          slog("Current unbalance for clan mode \"$clanModesString\" is $unbalanceIndicator\% (wasn't processed yet)",5);
        }
        my $p_testBattle=$lobby->getBattle();
        my $p_testPlayers=$p_testBattle->{users};
        my $p_testBots=$p_testBattle->{bots};
        $clanModesString=join(";",@currentClanModes,$mode);
        my (undef,$testUnbalance)=balanceBattle($p_testPlayers,$p_testBots,$clanModesString);
        if($testUnbalance - $unbalanceIndicatorRef <= $maxUnbalance) {
          slog("Unbalance for clan mode \"$clanModesString\" is $testUnbalance\% ($testUnbalance-$unbalanceIndicatorRef<=$maxUnbalance) => clan mode accepted",5);
          ($unbalanceIndicator,$p_players,$p_bots)=($testUnbalance,$p_testPlayers,$p_testBots);
          push(@currentClanModes,$mode);
        }else{
          slog("Unbalance for clan mode \"$clanModesString\" is $testUnbalance\% ($testUnbalance-$unbalanceIndicatorRef>$maxUnbalance) => clan mode rejected",5);
          last;
        }
      }else{
        slog("Adding \"$testClanMode\" to accepted clan modes (no unbalance threshold)",5);
        $unbalanceIndicator=undef;
        push(@currentClanModes,$testClanMode);
      }
    }
    if(! defined $unbalanceIndicator) {
      my $p_battle=$lobby->getBattle();
      $p_players=$p_battle->{users};
      $p_bots=$p_battle->{bots};
      $clanModesString=join(";",@currentClanModes);
      ($nbSmurfs,$unbalanceIndicator)=balanceBattle($p_players,$p_bots,$clanModesString);
      slog("Final unbalance for accepted clan mode \"$clanModesString\" is $unbalanceIndicator\% (wasn't processed yet)",5);
    }else{
      $clanModesString=join(";",@currentClanModes);
      slog("Final unbalance for accepted clan mode \"$clanModesString\" is $unbalanceIndicator\%",5);
    }
  }else{
    my $p_battle=$lobby->getBattle();
    $p_players=$p_battle->{users};
    $p_bots=$p_battle->{bots};
    ($nbSmurfs,$unbalanceIndicator)=balanceBattle($p_players,$p_bots,$conf{clanMode});
    slog("Unbalance for clan mode \"$conf{clanMode}\" (no threshold) is $unbalanceIndicator\%",5);
  }
  %balanceTarget=(players => $p_players,
                  bots => $p_bots);
  applyBalanceTarget();
  return ($nbSmurfs,$unbalanceIndicator);
}

sub fixColors {
  my $autoBalanceInProgress=shift;

  my ($p_players,$p_bots);

  if($autoBalanceInProgress) {
    $p_players=$balanceTarget{players};
    $p_bots=$balanceTarget{bots};
  }else{
    my $p_battle=$lobby->getBattle();
    $p_players=$p_battle->{users};
    $p_bots=$p_battle->{bots};
  }
  
  my $p_colorsTarget=getFixedColorsOf($p_players,$p_bots);
  %colorsTarget=%{$p_colorsTarget};
  applyColorsTarget($autoBalanceInProgress);
}

sub getUserIps {
  my $user=shift;
  my $accountId=getLatestUserAccountId($user);
  return $spads->getAccountIps($accountId) if($accountId ne '');
  return [];
}

sub getLatestUserIp {
  my $user=shift;
  return $lobby->{users}{$user}{ip} if($lobbyState > LOBBY_STATE_LOGGED_IN && exists $lobby->{users}{$user} && defined $lobby->{users}{$user}{ip});
  if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}}) {
    return $lobby->{battle}{users}{$user}{ip} if(exists $lobby->{battle}{users}{$user} && defined $lobby->{battle}{users}{$user}{ip});
  }
  my $accountId=getLatestUserAccountId($user);
  return $spads->getLatestAccountIp($accountId) if($accountId ne '');
  return '';
}

sub getLatestUserAccountId {
  my $user=shift;
  return '' if($lanMode);
  if(exists $lobby->{users}{$user}) {
    my $id=$lobby->{users}{$user}{accountId};
    $id.="($user)" unless($id);
    return $id;
  }
  return $spads->getLatestUserAccountId($user);
}

sub getIpRank {
  my $playerIp=shift;
  my ($rank,$chRanked)=(0,0);
  my $p_ipAccs=$spads->getIpAccounts($playerIp);
  foreach my $id (keys %{$p_ipAccs}) {
    next unless($p_ipAccs->{$id} >= 0);
    my $effectiveRank=getAccountPref($id,'rankMode');
    if($effectiveRank =~ /^\d+$/) {
      ($rank,$chRanked)=($effectiveRank,1) if($effectiveRank > $rank);
    }elsif($p_ipAccs->{$id} > $rank) {
      ($rank,$chRanked)=($p_ipAccs->{$id},0);
    }
  }
  return ($rank,$chRanked);
}

sub getPlayerSkillForBanCheck {
  my $player=shift;
  my ($playerSkill,$playerSigma)=('_UNKNOWN_','_UNKNOWN_');
  return ($playerSkill,$playerSigma) unless(exists $battleSkills{$player});
  return ($playerSkill,$playerSigma) if(getUserPref($player,'skillMode') eq 'TrueSkill'
                                        && $battleSkills{$player}{skillOrigin} ne 'TrueSkill'
                                        && $battleSkills{$player}{skillOrigin} ne 'Plugin');
  $playerSkill=$battleSkills{$player}{skill};
  $playerSigma=$battleSkills{$player}{sigma} if(exists $battleSkills{$player}{sigma} && defined $battleSkills{$player}{sigma});
  if($battleSkills{$player}{skillOrigin} eq 'TrueSkill') {
    my $gameType=getGameTypeForBanCheck();
    ($playerSkill,$playerSigma)=($battleSkillsCache{$player}{$gameType}{skill},$battleSkillsCache{$player}{$gameType}{sigma});
  }
  return ($playerSkill,$playerSigma);
}

sub getGameTypeForBanCheck {
  if($conf{teamSize} < 2) {
    if($conf{nbTeams} < 3) {
      return 'Duel';
    }else{
      return 'FFA';
    }
  }else{
    if($conf{nbTeams} < 3) {
      return 'Team';
    }else{
      return 'TeamFFA';
    }
  }
}

sub getTargetBattleStructure {
  my $nbPlayers=shift;
  return (0,0,'Duel') if($nbPlayers == 0);

  my $nbTeams=$conf{nbTeams};
  my $teamSize=$conf{teamSize};
  my $nbPlayerById = $conf{idShareMode} eq 'auto' ? $conf{nbPlayerById} : 1;

  my $minTeamSize=$conf{minTeamSize};
  $minTeamSize=$teamSize if($minTeamSize > $teamSize || $minTeamSize == 0);

  if($nbPlayers <= $nbTeams*$teamSize) {
    $nbTeams=ceil($nbPlayers/$minTeamSize) if($nbPlayers < $nbTeams*$minTeamSize);
    $teamSize=ceil($nbPlayers/$nbTeams);
  }elsif($nbPlayers > $nbTeams*$teamSize*$nbPlayerById) {
    $teamSize=ceil($nbPlayers/($nbTeams*$nbPlayerById));
  }

  my $gameType;
  if($nbTeams <= 2) {
    if($nbPlayers <= $nbTeams) {
      $gameType='Duel';
    }else{
      $gameType='Team';
    }
  }elsif($nbTeams > 2) {
    if($nbPlayers <= $nbTeams) {
      $gameType='FFA';
    }else{
      $gameType='TeamFFA';
    }
  }

  return ($nbTeams,$teamSize,$gameType);
}

sub balanceBattle {
  my ($p_players,$p_bots,$clanMode)=@_;

  foreach my $player (keys %{$p_players}) {
    delete($p_players->{$player}) if(! (defined $p_players->{$player}{battleStatus}) || $p_players->{$player}{battleStatus}{mode} == 0);
  }

  my $nbPlayers=0;
  $nbPlayers+=(keys %{$p_players});
  $nbPlayers+=(keys %{$p_bots});
  return (0,0) unless($nbPlayers);

  my ($nbTeams,$teamSize)=getTargetBattleStructure($nbPlayers);

  my $nbSmurfs=0;
  my $restoreRandSeed=intRand();
  srand($balRandSeed);
  foreach my $player (sort keys %{$p_players}) {
    if($conf{balanceMode} =~ /skill$/) {
      if(exists $battleSkills{$player}) {
        $p_players->{$player}{skill}=$battleSkills{$player}{skill};
        $p_players->{$player}{sigma}=$battleSkills{$player}{sigma} if(exists $battleSkills{$player}{sigma});
        $nbSmurfs++ if($battleSkills{$player}{rank} > $lobby->{users}{$player}{status}{rank});
      }else{
        slog("Undefined skill for player $player, using direct lobbyRank/skill mapping as a workaround for balancing!",1);
        $p_players->{$player}{skill}=$RANK_SKILL{$lobby->{users}{$player}{status}{rank}};
      }
    }else{
      $p_players->{$player}{skill}=int(rand(39));
    }
  }
  foreach my $bot (sort keys %{$p_bots}) {
    if($conf{balanceMode} =~ /skill$/) {
      $p_bots->{$bot}{skill}=$RANK_SKILL{$conf{botsRank}};
    }else{
      $p_bots->{$bot}{skill}=int(rand(39));
    }
  }

  my $unbalanceIndicator;
  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('balanceBattle')) {
      $unbalanceIndicator=$plugins{$pluginName}->balanceBattle($p_players,$p_bots,$clanMode,$nbTeams,$teamSize);
      if(ref $unbalanceIndicator) {
        my ($r_playerAssignations,$r_botAssignations);
        ($unbalanceIndicator,$r_playerAssignations,$r_botAssignations)=@{$unbalanceIndicator};
        foreach my $playerName (keys %{$r_playerAssignations}) {
          next unless(exists $p_players->{$playerName} && exists $r_playerAssignations->{$playerName}{team} && exists $r_playerAssignations->{$playerName}{id});
          $p_players->{$playerName}{battleStatus}{team}=$r_playerAssignations->{$playerName}{team};
          $p_players->{$playerName}{battleStatus}{id}=$r_playerAssignations->{$playerName}{id};
        }
        foreach my $botName (keys %{$r_botAssignations}) {
          next unless(exists $p_bots->{$botName} && exists $r_botAssignations->{$botName}{team} && exists $r_botAssignations->{$botName}{id});
          $p_bots->{$botName}{battleStatus}{team}=$r_botAssignations->{$botName}{team};
          $p_bots->{$botName}{battleStatus}{id}=$r_botAssignations->{$botName}{id};
        }
      }
      next unless(defined $unbalanceIndicator && $unbalanceIndicator >= 0);
      srand($restoreRandSeed);
      return ($nbSmurfs,$unbalanceIndicator);
    }
  }

  my $p_teams=createGroups(int($nbPlayers/$nbTeams),$nbTeams,$nbPlayers % $nbTeams);
  my @ids;
  if($conf{idShareMode} eq 'auto' || $conf{idShareMode} eq 'off') {
    for my $teamNb (0..$#{$p_teams}) {
      if($p_teams->[$teamNb]{freeSlots} < $teamSize) {
        $ids[$teamNb]=createGroups(1,$p_teams->[$teamNb]{freeSlots},0);
      }else{
        $ids[$teamNb]=createGroups(int($p_teams->[$teamNb]{freeSlots}/$teamSize),$teamSize,$p_teams->[$teamNb]{freeSlots} % $teamSize);
      }
    }
  }
  $unbalanceIndicator=balanceGroups($p_players,$p_bots,$p_teams,$clanMode);
  my $idNb=0;
  for my $teamNb (0..($#{$p_teams})) {
    my %manualSharedIds;
    if($conf{idShareMode} eq 'auto' || $conf{idShareMode} eq 'off') {
      balanceGroups($p_teams->[$teamNb]{players},$p_teams->[$teamNb]{bots},$ids[$teamNb],$clanMode);
    }
    my $p_sortedPlayers=randomRevSort(sub {return $_[0]{skill}},$p_teams->[$teamNb]{players});
    foreach my $player (@{$p_sortedPlayers}) {
      $p_players->{$player}{battleStatus}{team}=$teamNb;
      if($conf{idShareMode} eq 'all') {
        $p_players->{$player}{battleStatus}{id}=$teamNb;
      }elsif($conf{idShareMode} ne 'auto' && $conf{idShareMode} ne 'off') {
        my $userShareId=getUserPref($player,'shareId');
        if($userShareId eq '' && $conf{idShareMode} eq 'clan' && $player =~ /^\[([^\]]+)\]/) {
          $userShareId=$1;
        }
        if($userShareId ne '') {
          $manualSharedIds{$userShareId}=$idNb++ unless(exists $manualSharedIds{$userShareId});
          $p_players->{$player}{battleStatus}{id}=$manualSharedIds{$userShareId};
        }else{
          $p_players->{$player}{battleStatus}{id}=$idNb++;
        }
      }
    }
    foreach my $bot (sort keys %{$p_teams->[$teamNb]{bots}}) {
      $p_bots->{$bot}{battleStatus}{team}=$teamNb;
      if($conf{idShareMode} eq 'all') {
        $p_bots->{$bot}{battleStatus}{id}=$teamNb;
      }elsif($conf{idShareMode} ne 'auto' && $conf{idShareMode} ne 'off') {
        $p_bots->{$bot}{battleStatus}{id}=$idNb++;
      }
    }
    if($conf{idShareMode} eq 'auto' || $conf{idShareMode} eq 'off') {
      for my $subIdNb (0..($#{$ids[$teamNb]})) {
        foreach my $player (keys %{$ids[$teamNb][$subIdNb]{players}}) {
          $p_players->{$player}{battleStatus}{id}=$idNb;
        }
        foreach my $bot (keys %{$ids[$teamNb][$subIdNb]{bots}}) {
          $p_bots->{$bot}{battleStatus}{id}=$idNb;
        }
        $idNb++;
      }
    }
  }
  
  srand($restoreRandSeed);
  return ($nbSmurfs,$unbalanceIndicator);
}

sub balanceGroups {
  my ($p_players,$p_bots,$p_groups,$clanMode)=@_;
  my $totalSkill=0;
  my @players=keys %{$p_players};
  foreach my $player (@players) {
    $totalSkill+=$p_players->{$player}{skill};
  }
  my @bots=keys %{$p_bots};
  foreach my $bot (@bots) {
    $totalSkill+=$p_bots->{$bot}{skill};
  }
  if($conf{balanceMode} =~ /^clan/) {
    if($conf{balanceMode} eq "clan;skill") {
      my $avgSkill=$totalSkill/($#players+$#bots+2);
      balanceClans($p_players,$p_groups,$clanMode,$avgSkill);
    }else{
      balanceClans($p_players,$p_groups,$clanMode);
    }
  }
  my %remainingPlayers=%{$p_players};
  foreach my $p_group (@{$p_groups}) {
    foreach my $player (keys %{$p_group->{players}}) {
      delete $remainingPlayers{$player};
    }
  }
  my $avgGroupSkill=$totalSkill/($#{$p_groups}+1);
  slog("Average group skill is $avgGroupSkill",5);
  balancePlayers(\%remainingPlayers,$p_bots,$p_groups,$avgGroupSkill);
  my ($unbalanceIndicator,$squareDeviations)=(0,0);
  if($conf{balanceMode} =~ /skill$/) {
    for my $groupNb (0..$#{$p_groups}) {
      $squareDeviations+=($p_groups->[$groupNb]{skill}-$avgGroupSkill)**2;
      slog("Skill of group $groupNb is $p_groups->[$groupNb]{skill} => squareDeviations=$squareDeviations",5);
    }
  }
  $unbalanceIndicator=sqrt($squareDeviations/($#{$p_groups}+1))*100/$avgGroupSkill if($avgGroupSkill);
  $unbalanceIndicator=int($unbalanceIndicator + .5);
  return $unbalanceIndicator;
}

sub createGroups {
  my ($minSize,$nbGroups,$nbBigGroups)=@_;
  my @groups=();
  for my $i (0..($nbGroups-1)) {
    my $groupSize=$minSize;
    $groupSize++ if($i < $nbBigGroups);
    push(@groups,{freeSlots => $groupSize, skill => 0, players => {}, bots => {}});
  }
  return \@groups;
}

sub getNextClanGroup {
  my ($p_groups,$clanSize)=@_;
  my @groups=@{$p_groups};
  my $clanGroup=0;
  for my $groupNb (1..$#groups) {
    $clanGroup=$groupNb if($groups[$groupNb]{freeSlots} > $groups[$clanGroup]{freeSlots});
  }
  return $clanGroup unless(defined $clanSize);
  for my $groupNb (0..$#groups) {
    if($groups[$groupNb]{skill} < $groups[$clanGroup]{skill}
       && ($groups[$groupNb]{freeSlots} >= $clanSize || $groups[$groupNb]{freeSlots} == $groups[$clanGroup]{freeSlots})) {
      $clanGroup=$groupNb;
    }elsif($groups[$groupNb]{skill} == $groups[$clanGroup]{skill}
           && $groups[$groupNb]{freeSlots} >= $clanSize
           && $groups[$groupNb]{freeSlots} < $groups[$clanGroup]{freeSlots}) {
      $clanGroup=$groupNb;
    }
  }
  return $clanGroup;
}

sub splitClan {
  my ($p_clan,$size)=@_;
  my (@clan1,@clan2);
  for my $i (0..($size-1)) {
    push(@clan1,$p_clan->[$i]);
  }
  for my $i ($size..$#{$p_clan}) {
    push(@clan2,$p_clan->[$i]);
  }
  return (\@clan1,\@clan2);
}

sub assignPlayer {
  my ($player,$groupNb,$p_players,$p_groups)=@_;
  $p_groups->[$groupNb]{freeSlots}--;
  $p_groups->[$groupNb]{skill}+=$p_players->{$player}{skill};
  $p_groups->[$groupNb]{players}{$player}=$p_players->{$player};
}

sub assignBot {
  my ($bot,$groupNb,$p_bots,$p_groups)=@_;
  $p_groups->[$groupNb]{freeSlots}--;
  $p_groups->[$groupNb]{skill}+=$p_bots->{$bot}{skill};
  $p_groups->[$groupNb]{bots}{$bot}=$p_bots->{$bot};
}

sub randomRevSort {
  my ($p_evalFunc,$p_items)=@_;
  my @sortedItems;
  
  my %itemGroups;
  foreach my $item (sort keys %{$p_items}) {
    my $itemValue=&{$p_evalFunc}($p_items->{$item});
    $itemGroups{$itemValue}=[] unless(exists $itemGroups{$itemValue});
    push(@{$itemGroups{$itemValue}},$item);
  }

  for my $value (sort {$b <=> $a} (keys %itemGroups)) {
    my @randomItems=shuffle(@{$itemGroups{$value}});
    push(@sortedItems,@randomItems);
  }

  return \@sortedItems;
}

sub balanceClans {
  my ($p_players,$p_groups,$clanMode,$avgSkill)=@_;

  my %clans;
  foreach my $player (keys %{$p_players}) {
    my ($tagClan,$prefClan,$clan)=('','');
    $tagClan=":$1" if($clanMode =~/tag/ && $player =~ /^\[([^\]]+)\]/);
    $prefClan=getUserPref($player,'clan') if($clanMode =~/pref/);
    if($prefClan ne '') {
      $clan=$prefClan;
    }else{
      $clan=$tagClan;
    }
    if($clan) {
      $clans{$clan}=[] unless(exists $clans{$clan});
      if($clan eq $tagClan) {
        unshift(@{$clans{$clan}},$player);
      }else{
        push(@{$clans{$clan}},$player);
      }
    }
  }
  foreach my $clan (keys %clans) {
    delete($clans{$clan}) unless($#{$clans{$clan}} > 0);
  }

  my $p_sortedClanNames=randomRevSort(sub {return $#{$_[0]}},\%clans);
  my @sortedClans = map {$clans{$_}} @{$p_sortedClanNames};

  while(@sortedClans) {
    my $p_clan=shift(@sortedClans);
    my @clan=@{$p_clan};
    my $groupNb;
    if(defined $avgSkill) {
      my $clanSkill=0;
      for my $clanPlayer (@clan) {
        $clanSkill+=$p_players->{$clanPlayer}{skill};
      }
      my $clanAvgSkill=$clanSkill/($#clan+1);
      if($clanAvgSkill>$avgSkill) {
        $groupNb=getNextClanGroup($p_groups,$#clan+1);
      }else{
        $groupNb=getNextClanGroup($p_groups);
      }
    }else{
      $groupNb=getNextClanGroup($p_groups);
    }
    my $groupSpace=$p_groups->[$groupNb]{freeSlots};
    return if($groupSpace < 2);
    if($groupSpace <= $#clan) {
      my ($p_clan1,$p_clan2)=splitClan(\@clan,$groupSpace);
      if($#{$p_clan2}>0) {
        push(@sortedClans,$p_clan2);
        @sortedClans=sort {$#{$b} <=> $#{$a}} @sortedClans;
      }
      @clan=@{$p_clan1};
    }
    foreach my $player (@clan) {
      assignPlayer($player,$groupNb,$p_players,$p_groups);
    }
  }
}

sub getNextPlayerGroup {
  my ($p_groups,$avgGroupSkill)=@_;
  my @groups=@{$p_groups};
  my $maxAvgMissingSkill;
  my $playerGroup;
  for my $groupNb (0..$#groups) {
    if($groups[$groupNb]{freeSlots} > 0) {
      $maxAvgMissingSkill=($avgGroupSkill-$groups[$groupNb]{skill})/$groups[$groupNb]{freeSlots};
      $playerGroup=$groupNb;
      last;
    }
  }
  for my $groupNb (1..$#groups) {
    if($groups[$groupNb]{freeSlots} > 0) {
      my $groupAvgMissingSkil=($avgGroupSkill-$groups[$groupNb]{skill})/$groups[$groupNb]{freeSlots};
      if($groupAvgMissingSkil > $maxAvgMissingSkill) {
        $maxAvgMissingSkill=$groupAvgMissingSkil;
        $playerGroup=$groupNb;
      }
    }
  }
  return $playerGroup;
}

sub balancePlayers {
  my ($p_players,$p_bots,$p_groups,$avgGroupSkill)=@_;

  my $optim3v3 = @{$p_groups} == 2
      && (all {$_->{freeSlots} == 3 && ! %{$_->{players}} && ! %{$_->{bots}}} @{$p_groups})
      && (scalar keys %{$p_players}) + (scalar keys %{$p_bots}) == 6;

  my $p_sortedPlayers=randomRevSort(sub {return $_[0]{skill}},$p_players);
  my $p_sortedBots=randomRevSort(sub {return $_[0]{skill}},$p_bots);
  my @sortedPlayers=@{$p_sortedPlayers};
  my @sortedBots=@{$p_sortedBots};
  while(@sortedPlayers || @sortedBots) {
    my $groupNb=getNextPlayerGroup($p_groups,$avgGroupSkill);
    my ($playerSkill,$botSkill);
    $playerSkill=$p_players->{$sortedPlayers[0]}{skill} if(@sortedPlayers);
    $botSkill=$p_bots->{$sortedBots[0]}{skill} if(@sortedBots);
    my $clanEdgeCaseIdealSkill;
    $clanEdgeCaseIdealSkill=$avgGroupSkill-$p_groups->[$groupNb]{skill} if(@{$p_groups} == 2 && $p_groups->[$groupNb]{freeSlots} == 1 && $p_groups->[1-$groupNb]{freeSlots} > 1);
    if(defined $playerSkill && (! defined $botSkill || $playerSkill > $botSkill)) {
      my $player=shift(@sortedPlayers);
      if(defined $clanEdgeCaseIdealSkill) {
        my $nextSkill;
        $nextSkill=$p_players->{$sortedPlayers[0]}{skill} if(@sortedPlayers);
        $nextSkill=$botSkill if(defined $botSkill && (! defined $nextSkill || $botSkill > $nextSkill));
        $groupNb=1-$groupNb if(abs($nextSkill-$clanEdgeCaseIdealSkill) < abs($playerSkill-$clanEdgeCaseIdealSkill));
      }
      assignPlayer($player,$groupNb,$p_players,$p_groups);
    }else{
      my $bot=shift(@sortedBots);
      if(defined $clanEdgeCaseIdealSkill) {
        my $nextSkill;
        $nextSkill=$p_bots->{$sortedBots[0]}{skill} if(@sortedBots);
        $nextSkill=$playerSkill if(defined $playerSkill && (! defined $nextSkill || $playerSkill > $nextSkill));
        $groupNb=1-$groupNb if(abs($nextSkill-$clanEdgeCaseIdealSkill) < abs($botSkill-$clanEdgeCaseIdealSkill));
      }
      assignBot($bot,$groupNb,$p_bots,$p_groups);
    }
    if($optim3v3 && $p_groups->[$groupNb]{freeSlots} == 2) {
      my $nextBestPlayerSkill=$p_players->{$sortedPlayers[0]}{skill} if(@sortedPlayers);
      my $nextBestBotSkill=$p_bots->{$sortedBots[0]}{skill} if(@sortedBots);
      my $nextEntityIsPlayer;
      if(defined $nextBestPlayerSkill) {
        if(defined $nextBestBotSkill) {
          $nextEntityIsPlayer=$nextBestPlayerSkill>$nextBestBotSkill;
        }else{
          $nextEntityIsPlayer=1;
        }
      }else{
        $nextEntityIsPlayer=0;
      }
      my $nextBestSkill=$nextEntityIsPlayer?$nextBestPlayerSkill:$nextBestBotSkill;
      my $nextWorstPlayerSkill=$p_players->{$sortedPlayers[-1]}{skill} if(@sortedPlayers);
      my $nextWorstBotSkill=$p_bots->{$sortedBots[-1]}{skill} if(@sortedBots);
      my $nextWorstSkill;
      if(defined $nextWorstPlayerSkill) {
        if(defined $nextWorstBotSkill) {
          $nextWorstSkill=$nextWorstPlayerSkill<$nextWorstBotSkill?$nextWorstPlayerSkill:$nextWorstBotSkill;
        }else{
          $nextWorstSkill=$nextWorstPlayerSkill;
        }
      }else{
        $nextWorstSkill=$nextWorstBotSkill;
      }
      if($p_groups->[$groupNb]{skill}+$nextBestSkill+$nextWorstSkill<$avgGroupSkill) {
        if($nextEntityIsPlayer) {
          my $player=shift(@sortedPlayers);
          assignPlayer($player,$groupNb,$p_players,$p_groups);
        }else{
          my $bot=shift(@sortedBots);
          assignBot($bot,$groupNb,$p_bots,$p_groups);
        }
      }
      $optim3v3=0;
    }
  }
}

sub colorDistance {
  my ($p_col1,$p_col2)=@_;
  my $meanRed = ( $p_col1->{red} + $p_col2->{red} ) / 2;
  my $deltaRed = $p_col1->{red} - $p_col2->{red};
  my $deltaGreen = $p_col1->{green} - $p_col2->{green};
  my $deltaBlue = $p_col1->{blue} - $p_col2->{blue};
  return (((512+$meanRed)*$deltaRed*$deltaRed)>>8) + 4*$deltaGreen*$deltaGreen + (((767-$meanRed)*$deltaBlue*$deltaBlue)>>8);
}

sub minDistance {
  my ($p_color,$p_idColors)=@_;
  my @colors=values(%{$p_idColors});
  my $minDistance=584970;
  foreach my $p_otherColor (@colors) {
    my $distance=colorDistance($p_color,$p_otherColor);
    $minDistance=$distance if($distance < $minDistance);
  }
  return $minDistance;
}

sub nextColor {
  my $p_idColors=shift;

  my @minDistances;
  foreach my $p_color (@predefinedColors) {
    my $minDistance=minDistance($p_color,$p_idColors);
    return $p_color if($conf{colorSensitivity} > 0 && $minDistance > $conf{colorSensitivity}*1000);
    push(@minDistances,$minDistance);
  }

  my $indexBestColor=0;
  for my $indexColor (1..$#predefinedColors) {
    $indexBestColor=$indexColor if($minDistances[$indexColor] > $minDistances[$indexBestColor]);
  }

  if($minDistances[$indexBestColor] == 0) {
    slog("Unable to find a non-used predefined color, using fallback algorithm: best of 10 random colors...",2);

    my @randomColors;
    for my $i (0..9) {
      push(@randomColors,{red => 25+int(rand(200)), green => 25+int(rand(200)), blue => 25+int(rand(200))});
    }

    my @minRandomDistances;
    foreach my $p_color (@randomColors) {
      my $minDistance=minDistance($p_color,$p_idColors);
      return $p_color if($conf{colorSensitivity} > 0 && $minDistance > $conf{colorSensitivity}*1000);
      push(@minRandomDistances,$minDistance);
    }
    
    my $indexBestRandomColor=0;
    for my $indexColor (1..$#randomColors) {
      $indexBestRandomColor=$indexColor if($minRandomDistances[$indexColor] > $minRandomDistances[$indexBestRandomColor]);
    }

    return $randomColors[$indexBestRandomColor];
  }else{
    return $predefinedColors[$indexBestColor];
  }
}

sub getTeamAdvancedColors {
  my ($teamSize,$r_colorPanels,$r_colorsSortedByTeamOrder,$r_colorsSortedBySelectionOrder)=@_;
  return [] unless($teamSize);
  $r_colorsSortedBySelectionOrder//=\@DEFAULT_COLOR_ORDER;
      
  my %colorsTeamPriority;
  for my $colorIdx (0..$#{$r_colorsSortedByTeamOrder}) {
    $colorsTeamPriority{$r_colorsSortedByTeamOrder->[$colorIdx]}=$colorIdx;
  }
  my %colorsSelectionPriority;
  for my $colorIdx (0..$#{$r_colorsSortedBySelectionOrder}) {
    $colorsSelectionPriority{$r_colorsSortedBySelectionOrder->[$colorIdx]}=$colorIdx;
  }
  
  my ($panelSize,$selectedNbShades,@selectedColorsSortedBySelectionOrder);
  PANEL_LOOP: foreach my $colorPanel (@{$r_colorPanels}) {
    if($colorPanel=~/^([SML])(g?)([1-3]?)$/) {
      my ($grayAllowed,$maxNbShades);
      ($panelSize,$grayAllowed,$maxNbShades)=($1,$2 ? 1 : 0,$3 || 3);
      @selectedColorsSortedBySelectionOrder=sort {$colorsSelectionPriority{$a} <=> $colorsSelectionPriority{$b}} (grep {exists $advColors{$panelSize.1}{$_.1} || ($grayAllowed && $_ eq 'gray')} @{$r_colorsSortedByTeamOrder});
      for my $nbShades (1..$maxNbShades) {
        $selectedNbShades=$nbShades;
        last PANEL_LOOP if($teamSize <= @selectedColorsSortedBySelectionOrder * $nbShades);
      }
    }else{
      slog("Invalid color panel format in getTeamAdvancedColors() call: $colorPanel",0);
      return [];
    }
  }

  $teamSize = @selectedColorsSortedBySelectionOrder * $selectedNbShades if($teamSize > @selectedColorsSortedBySelectionOrder * $selectedNbShades);
  
  my %colorsNbShades = map {$_ => $selectedNbShades} @selectedColorsSortedBySelectionOrder;
  my $nbColorsWithAdditionalShade = $teamSize % @selectedColorsSortedBySelectionOrder;
  my @colorsWithAdditionalShade;
  if($nbColorsWithAdditionalShade) {
    my @patchedSelectedColorsSortedBySelectionOrder;
    if($selectedNbShades > 1) {
      foreach my $selectedColor (@selectedColorsSortedBySelectionOrder) {
        push(@patchedSelectedColorsSortedBySelectionOrder,$selectedColor) unless($selectedColor eq 'yellow');
      }
    }else{
      @patchedSelectedColorsSortedBySelectionOrder=@selectedColorsSortedBySelectionOrder;
    }
    @colorsWithAdditionalShade=@patchedSelectedColorsSortedBySelectionOrder[0..($nbColorsWithAdditionalShade-1)];
    foreach my $color (keys %colorsNbShades) {
      if(none {$color eq $_} @colorsWithAdditionalShade) {
        $colorsNbShades{$color}--;
      }
    }
  }
  
  my @selectedColorsSortedByTeamOrder=sort {$colorsTeamPriority{$a} <=> $colorsTeamPriority{$b}} @selectedColorsSortedBySelectionOrder;

  my @teamColors;
  for my $shadeNb (1..$selectedNbShades) {
    my @colorsToAdd;
    if($shadeNb < $selectedNbShades || ! $nbColorsWithAdditionalShade) {
      @colorsToAdd=@selectedColorsSortedByTeamOrder;
    }else{
      @colorsToAdd=sort {$colorsTeamPriority{$a} <=> $colorsTeamPriority{$b}} @colorsWithAdditionalShade;
    }
    foreach my $colorName (@colorsToAdd) {
      if($colorName eq 'gray') {
        push(@teamColors,$advColors{'G'.$colorsNbShades{'gray'}}{'gray'.$shadeNb});
      }else{
        push(@teamColors,$advColors{$panelSize.$colorsNbShades{$colorName}}{$colorName.$shadeNb});
      }
    }
  }

  return \@teamColors;
}

sub getTeamsColorPanel {
  my ($r_teamsSizes,$r_colorPanels,$r_teamsColors)=@_;
  my $selectedPanel;
  PANEL_LOOP: foreach my $colorPanel (@{$r_colorPanels}) {
    $selectedPanel=$colorPanel;
    if($colorPanel=~/^([SML])(g?)([1-3]?)$/) {
      my ($panelSize,$grayAllowed,$maxNbShades)=($1,$2 ? 1 : 0,$3 || 3);
      for my $teamIdx (0..$#{$r_teamsSizes}) {
        my @allowedColors = grep {exists $advColors{$panelSize.1}{$_.1} || ($grayAllowed && $_ eq 'gray')} @{$r_teamsColors->[$teamIdx]};
        next PANEL_LOOP if($r_teamsSizes->[$teamIdx] > @allowedColors * $maxNbShades);
      }
      return $selectedPanel;
    }else{
      slog("Invalid color panel format in getTeamsColorPanel() call: $colorPanel",0);
      return undef;
    }
  }
  return $selectedPanel;
}

sub getTeamsAdvancedColors {
  my ($r_teamsSizes,$r_colorPanels,$r_teamsColors)=@_;
  my $colorPanelForTeams=getTeamsColorPanel($r_teamsSizes,$r_colorPanels,$r_teamsColors);
  my @teamsColors;
  for my $teamIdx (0..$#{$r_teamsSizes}) {
    push(@teamsColors,getTeamAdvancedColors($r_teamsSizes->[$teamIdx],[$colorPanelForTeams],$r_teamsColors->[$teamIdx]));
  }
  return \@teamsColors; 
}

sub getFixedColorsOf {
  my ($p_players,$p_bots)=@_;

  my %idsTeam;
  my %battleStructure;
  
  my $r_players={};
  foreach my $player (keys %{$p_players}) {
    next unless(defined $p_players->{$player}{battleStatus});
    next unless($p_players->{$player}{battleStatus}{mode});
    my ($pId,$pTeam)=@{$p_players->{$player}{battleStatus}}{qw'id team'};
    $idsTeam{$pId}//=$pTeam;
    $r_players->{$player}={id => $pId,
                           team => $idsTeam{$pId},
                           color => $p_players->{$player}{color}};
    $battleStructure{$idsTeam{$pId}}{$pId}//={players => [], bots => []};
    push(@{$battleStructure{$idsTeam{$pId}}{$pId}{players}},$player);
  }
  my $r_bots={};
  for my $bot (keys %{$p_bots}) {
    my ($bId,$bTeam)=@{$p_bots->{$bot}{battleStatus}}{qw'id team'};
    $idsTeam{$bId}//=$bTeam;
    $r_bots->{$bot}={id => $bId,
                     team => $idsTeam{$bId},
                     color => $p_bots->{$bot}{color}};
    $battleStructure{$idsTeam{$bId}}{$bId}//={players => [], bots => []};
    push(@{$battleStructure{$idsTeam{$bId}}{$bId}{bots}},$bot);
  }
  
  my %idColors;
  foreach my $pluginName (@pluginsOrder) {
    my $r_idColors=$plugins{$pluginName}->fixColors($r_players,$r_bots,\%battleStructure) if($plugins{$pluginName}->can('fixColors'));
    if(defined $r_idColors) {
      %idColors=%{$r_idColors};
      last;
    }
  }
  if(! %idColors && $conf{colorSensitivity} == -1) {
    my @orderedTeamNbs = sort {$a <=> $b} keys %battleStructure;
    my $nbTeams = @orderedTeamNbs;
    my @teamSizes=map {scalar keys %{$battleStructure{$_}}} @orderedTeamNbs;
    if($nbTeams == 2) {
      my ($playerTeam,$aiBotTeam);
      foreach my $teamNb (@orderedTeamNbs) {
        my $r_idsInTeam=$battleStructure{$teamNb};
        if(all {@{$r_idsInTeam->{$_}{players}} && ! @{$r_idsInTeam->{$_}{bots}} } (keys %{$r_idsInTeam})) {
          $playerTeam=$teamNb;
        }elsif(all {@{$r_idsInTeam->{$_}{bots}} && ! @{$r_idsInTeam->{$_}{players}} } (keys %{$r_idsInTeam})) {
          $aiBotTeam=$teamNb;
        }
      }
      if(defined $playerTeam && defined $aiBotTeam) {
        # Player(s) VS AI bot(s)
        my $r_aiColors=getTeamAdvancedColors(scalar keys %{$battleStructure{$aiBotTeam}},[qw'S M L'],[qw'magenta purple pink']);
        foreach my $aiId (sort {$a <=> $b} keys %{$battleStructure{$aiBotTeam}}) {
          last unless(@{$r_aiColors});
          $idColors{$aiId}=shift @{$r_aiColors};
        }
        my $r_playerColors=getTeamAdvancedColors(scalar keys %{$battleStructure{$playerTeam}},[qw'S1 M L Lg'],[qw'red blue green yellow cyan orange teal gold azure lime gray'],[qw'green yellow cyan blue red orange teal gold azure lime gray']);
        foreach my $pId (sort {$a <=> $b} keys %{$battleStructure{$playerTeam}}) {
          last unless(@{$r_playerColors});
          $idColors{$pId}=shift @{$r_playerColors};
        }
      }else{
        # 1v1 or team game
        my @colorsTeam1 = $teamSizes[0] < 19 ? (qw'red pink magenta orange gold yellow') : (qw'red pink magenta purple orange gold yellow');
        my @colorsTeam2 = $teamSizes[1] < 19 ? (qw'blue azure cyan teal green gray') : (qw'blue azure cyan teal green lime gray');
        my $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,[qw'S1 M Lg'],[\@colorsTeam1,\@colorsTeam2]);
        for my $team (@orderedTeamNbs) {
          my $r_teamColors=shift @{$r_teamsColors};
          foreach my $id (sort {$a <=> $b} keys %{$battleStructure{$team}}) {
            last unless(@{$r_teamColors});
            $idColors{$id}=shift @{$r_teamColors};
          }
        }
      }
    }elsif(all {$_ == 1} @teamSizes) {
      # FFA
      my $r_ffaColors=getTeamAdvancedColors($nbTeams,[qw'S1 M1 L Lg'],\@DEFAULT_COLOR_ORDER);
      foreach my $team (@orderedTeamNbs) {
        last unless(@{$r_ffaColors});
        $idColors{(keys %{$battleStructure{$team}})[0]}=shift @{$r_ffaColors};
      }
    }elsif($nbTeams > 2) {
      # Team FFA
      my $r_teamsColors;
      if($nbTeams == 3) {
        $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,[qw'S1 M L'],[[qw'red pink magenta orange'],[qw'blue purple azure cyan'],[qw'green teal lime yellow']]);
      }elsif($nbTeams == 4) {
        $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,[qw'M L'],[[qw'red pink magenta'],[qw'blue azure cyan'],[qw'green teal'],[qw'yellow gold orange']]);
      }elsif($nbTeams == 5) {
        my @colorsTeam1 = $teamSizes[0] < 4 ? ('red') : ('red','magenta');
        my @colorsTeam2 = $teamSizes[1] < 4 ? ('blue') : ('blue','cyan');
        my @colorsTeam3 = $teamSizes[2] < 4 ? ('green') : ('green','teal');
        my @colorsTeam4 = $teamSizes[3] < 4 ? ('yellow') : ('yellow','orange');
        my @colorsTeam5 = ($teamSizes[4] < 4 && $teamSizes[1] < 4) ? ('cyan') : ('purple','gray');
        $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,[qw'S M Mg'],[\@colorsTeam1,\@colorsTeam2,\@colorsTeam3,\@colorsTeam4,\@colorsTeam5]);
      }elsif($nbTeams == 6) {
        my @colorsTeam1 = $teamSizes[0] < 4 ? ('red') : ('red','orange');
        my @colorsTeam2 = $teamSizes[1] < 4 ? ('blue') : ('blue','purple');
        my @colorsTeam3 = $teamSizes[2] < 4 ? ('green') : ('green','teal');
        my @colorsTeam4 = $teamSizes[3] < 4 ? ('yellow') : ('yellow','gold');
        my @colorsTeam5 = $teamSizes[4] < 4 ? ('cyan') : ('cyan','azure');
        my @colorsTeam6 = $teamSizes[5] < 4 ? ('magenta') : ('magenta','pink');
        $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,[qw'S L'],[\@colorsTeam1,\@colorsTeam2,\@colorsTeam3,\@colorsTeam4,\@colorsTeam5,\@colorsTeam6]);
      }elsif($nbTeams == 7) {
        my @colorsTeam1 = $teamSizes[0] < 4 ? ('red') : ('red','orange');
        my @colorsTeam2 = $teamSizes[1] < 4 ? ('blue') : ('blue','azure');
        my @colorsTeam3 = $teamSizes[2] < 4 ? ('green') : ('green','lime');
        my @colorsTeam4 = $teamSizes[3] < 4 ? ('yellow') : ('yellow','gold');
        my @colorsTeam5 = $teamSizes[4] < 4 ? ('cyan') : ('cyan','teal');
        my @colorsTeam6 = $teamSizes[5] < 4 ? ('magenta') : ('magenta','pink');
        my @colorsTeam7 = ($teamSizes[6] < 4 && $teamSizes[0] < 4) ? ('orange') : ('purple','gray');
        $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,[qw'M L Lg'],[\@colorsTeam1,\@colorsTeam2,\@colorsTeam3,\@colorsTeam4,\@colorsTeam5,\@colorsTeam6,\@colorsTeam7]);
      }elsif($nbTeams == 8) {
        if(all {$_ < 4} @teamSizes) {
          $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,['M'],[['red'],['blue'],['green'],['yellow'],['cyan'],['magenta'],['orange'],['purple']]);
        }else{
          $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,['L'],[['red'],['blue'],['green'],['yellow'],['cyan'],['magenta'],['orange'],['purple']]);
          my @additionalColors=(['L2','pink2'],['L1','azure1'],['L1','teal1'],['L1','lime1'],['G2','gray1'],['L2','pink1'],['L1','gold1'],['G2','gray2']);
          for my $teamIdx (0..$#{additionalColors}) {
            push(@{$r_teamsColors->[$teamIdx]},$advColors{$additionalColors[$teamIdx][0]}{$additionalColors[$teamIdx][1]});
          }
        }
      }elsif($nbTeams == 9) {
        $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,['M'],[['red'],['blue'],['green'],['yellow'],['cyan'],['magenta'],['orange'],['purple'],['teal']]);
      }elsif($nbTeams < 15) {
        $r_teamsColors=getTeamsAdvancedColors(\@teamSizes,['Lg'],[['red'],['blue'],['green'],['yellow'],['cyan'],['magenta'],['orange'],['purple'],['teal'],['gold'],['azure'],['pink'],['lime'],['gray']]);
      }elsif($nbTeams == 15) {
        my @teamsColors = map { [map {$advColors{$_->[0]}{$_->[1]}} @{$_}] } ([['L2','red1'],['L2','red2']],
                                                                              [['L3','blue1'],['L3','blue3']],
                                                                              [['L2','green1'],['L2','green2']],
                                                                              [['L2','yellow1'],['L2','yellow2']],
                                                                              [['L2','cyan1'],['L2','cyan2']],
                                                                              [['L2','magenta1'],['L2','magenta2']],
                                                                              [['L2','orange1'],['L2','orange2']],
                                                                              [['L2','purple1'],['L2','purple2']],
                                                                              [['L2','teal1'],['L2','teal2']],
                                                                              [['L2','gold1'],['L2','gold2']],
                                                                              [['L3','azure1'],['L3','azure3']],
                                                                              [['L2','pink1'],['L2','pink2']],
                                                                              [['L2','lime1'],['L2','lime2']],
                                                                              [['G2','gray1'],['G2','gray2']],
                                                                              [['L3','blue2'],['L3','azure2']]);
        $r_teamsColors=\@teamsColors;
      }elsif($nbTeams == 16) {
        my @teamsColors = map { [map {$advColors{$_->[0]}{$_->[1]}} @{$_}] } ([['L2','red1'],['L2','red2']],
                                                                              [['L3','blue1'],['L3','blue3']],
                                                                              [['L2','green1'],['L2','green2']],
                                                                              [['L2','yellow1'],['L2','yellow2']],
                                                                              [['L2','cyan1'],['L2','cyan2']],
                                                                              [['L2','magenta1'],['L2','magenta2']],
                                                                              [['L3','orange1'],['L3','orange3']],
                                                                              [['L2','purple1'],['L2','purple2']],
                                                                              [['L2','teal1'],['L2','teal2']],
                                                                              [['L3','gold1'],['L3','gold3']],
                                                                              [['L3','azure1'],['L3','azure3']],
                                                                              [['L2','pink1'],['L2','pink2']],
                                                                              [['L2','lime1'],['L2','lime2']],
                                                                              [['G2','gray1'],['G2','gray2']],
                                                                              [['L3','blue2'],['L3','azure2']],
                                                                              [['L3','orange2'],['L3','gold2']]);
        $r_teamsColors=\@teamsColors;
      }
      if(defined $r_teamsColors) {
        foreach my $team (@orderedTeamNbs) {
          my $r_teamColors=shift @{$r_teamsColors};
          last unless(defined $r_teamColors);
          foreach my $id (sort {$a <=> $b} keys %{$battleStructure{$team}}) {
            last unless(@{$r_teamColors});
            $idColors{$id}=shift @{$r_teamColors};
          }
        }
      }
    }
  }
  if($conf{colorSensitivity} > 0) {
    foreach my $bot (sort {$r_bots->{$a}{id} <=> $r_bots->{$b}{id}} keys %{$r_bots}) {
      next unless($p_bots->{$bot}{owner} eq $conf{lobbyLogin});
      next if(exists $idColors{$r_bots->{$bot}{id}});
      if(minDistance($r_bots->{$bot}{color},\%idColors) > $conf{colorSensitivity}*1000 && colorDistance($r_bots->{$bot}{color},{red => 255, blue => 255, green => 255}) > 7000) {
        $idColors{$r_bots->{$bot}{id}}=$r_bots->{$bot}{color};
      }
    }
    foreach my $player (sort {$r_players->{$a}{id} <=> $r_players->{$b}{id}} keys %{$r_players}) {
      next if(exists $idColors{$r_players->{$player}{id}});
      if(minDistance($r_players->{$player}{color},\%idColors) > $conf{colorSensitivity}*1000 && colorDistance($r_players->{$player}{color},{red => 255, blue => 255, green => 255}) > 7000) {
        $idColors{$r_players->{$player}{id}}=$r_players->{$player}{color};
      }
    }
    foreach my $bot (sort {$r_bots->{$a}{id} <=> $r_bots->{$b}{id}} keys %{$r_bots}) {
      next if($p_bots->{$bot}{owner} eq $conf{lobbyLogin});
      next if(exists $idColors{$r_bots->{$bot}{id}});
      if(minDistance($r_bots->{$bot}{color},\%idColors) > $conf{colorSensitivity}*1000 && colorDistance($r_bots->{$bot}{color},{red => 255, blue => 255, green => 255}) > 7000) {
        $idColors{$r_bots->{$bot}{id}}=$r_bots->{$bot}{color};
      }
    }
  }

  foreach my $player (sort {$r_players->{$a}{id} <=> $r_players->{$b}{id}} keys %{$r_players}) {
    $idColors{$r_players->{$player}{id}}=nextColor(\%idColors) unless(exists $idColors{$r_players->{$player}{id}});
  }
  foreach my $bot (sort {$r_bots->{$a}{id} <=> $r_bots->{$b}{id}} keys %{$r_bots}) {
    $idColors{$r_bots->{$bot}{id}}=nextColor(\%idColors) unless(exists $idColors{$r_bots->{$bot}{id}});
  }

  return \%idColors;
}

sub getBattleState {
  my $nbPlayers=0;
  my @unsyncedPlayers;
  my @inGamePlayers;
  my @unreadyPlayers;
  my %teams; # used only when idShareMode is set to auto
  my %teamCount;
  my %ids;
  my $nbIds; #  to determine the number of required start pos on map when startPosType != 2
  my $p_bUsers=$lobby->{battle}{users};
  my @bUsers=keys %{$p_bUsers};
  return { battleState => -4 } if($#bUsers > 250);

  my @players;
  foreach my $bUser (@bUsers) {
    if(! defined $p_bUsers->{$bUser}{battleStatus}) {
      push(@unsyncedPlayers,$bUser);
    }elsif($p_bUsers->{$bUser}{battleStatus}{mode}) {
      push(@players,$bUser);
      if($p_bUsers->{$bUser}{battleStatus}{sync} != 1) {
        push(@unsyncedPlayers,$bUser);
      }elsif($lobby->{users}{$bUser}{status}{inGame}) {
        push(@inGamePlayers,$bUser);
      }else{
        $nbPlayers++;
        push(@unreadyPlayers,$bUser) unless($p_bUsers->{$bUser}{battleStatus}{ready});
        my ($id,$team)=@{$p_bUsers->{$bUser}{battleStatus}}{'id','team'};
        if(exists $ids{$id}) {
          return { battleState => -5 } unless($ids{$id} == $team);
        }else{
          $ids{$id}=$team;
        }
        if($conf{idShareMode} eq "auto") {
          $teams{$id}=$team;
        }else{
          $teamCount{$team}=0 unless(exists $teamCount{$team});
          $teamCount{$team}++;
        }
      }
    }
  }

  return { battleState => -3, unsyncedPlayers => \@unsyncedPlayers } if(@unsyncedPlayers);
  return { battleState => -2, inGamePlayers => \@inGamePlayers } if(@inGamePlayers);
  return { battleState => -1, unreadyPlayers => \@unreadyPlayers } if(@unreadyPlayers);

  my $p_bBots=$lobby->{battle}{bots};
  foreach my $bBot (keys %{$p_bBots}) {
    $nbPlayers++;
    my ($id,$team)=@{$p_bBots->{$bBot}{battleStatus}}{'id','team'};
    if(exists $ids{$id}) {
      return { battleState => -5 } unless($ids{$id} == $team);
    }else{
      $ids{$id}=$team;
    }
    if($conf{idShareMode} eq "auto") {
      $teams{$id}=$team;
    }else{
      $teamCount{$team}=0 unless(exists $teamCount{$team});
      $teamCount{$team}++;
    }
  }

  if($conf{idShareMode} eq "auto") {
    foreach my $id (keys %teams) {
      $teamCount{$teams{$id}}=0 unless(exists $teamCount{$teams{$id}});
      $teamCount{$teams{$id}}++;
    }
  }

  $nbIds=keys %ids;

  my @warnings;
  if($nbPlayers < $conf{minPlayers}) {
    push(@warnings,"not enough players (minPlayers=$conf{minPlayers})");
  }else{
    my $nbTeams=keys %teamCount;
    push(@warnings,"not enough teams") if($nbTeams < 2);
  }

  if($conf{nbTeams} != 1) {
    my $teamSize;
    foreach my $team (keys %teamCount) {
      $teamSize//=$teamCount{$team};
      if($teamSize != $teamCount{$team}) {
        push(@warnings,"teams are uneven");
        last;
      }
    }
  }

  return { battleState => @warnings ? 0 : 1,
           nbIds => $nbIds,
           players => \@players,
           warning => join(" and ",@warnings) };
}

sub launchGame {
  my ($force,$checkOnly,$automatic,$checkBypassLevel)=@_;
  $checkBypassLevel//=0;

  if($timestamps{usLockRequestForGameStart}) {
    answer('Game start is already in progress (waiting for exclusive access to archives cache)') unless($automatic);
    return 0;
  }
  
  my $p_battleState = getBattleState();

  if($p_battleState->{battleState} < -$checkBypassLevel) {
    if($p_battleState->{battleState} == -5) {
      answer('Unable to start game, inconsistent team/ID configuration for player or AI bot') unless($automatic);
      return 0;
    }
    
    if($p_battleState->{battleState} == -4) {
      answer("Unable to start game, Spring engine does not support more than 251 clients") unless($automatic);
      return 0;
    }
    
    if($p_battleState->{battleState} == -3) {
      if(! $automatic) {
        my $p_unsyncedPlayers=$p_battleState->{unsyncedPlayers};
        if($#{$p_unsyncedPlayers}) {
          answer("Unable to start game, following players are unsynced: ".join(",",@{$p_unsyncedPlayers}));
        }else{
          answer("Unable to start game, $p_unsyncedPlayers->[0] is unsynced");
        }
      }
      return 0;
    }
    
    if($p_battleState->{battleState} == -2) {
      if(! $automatic) {
        my $p_inGamePlayers=$p_battleState->{inGamePlayers};
        if($#{$p_inGamePlayers}) {
          answer("Unable to start game, following players are already in game: ".join(",",@{$p_inGamePlayers}));
        }else{
          answer("Unable to start game, $p_inGamePlayers->[0] is already in game");
        }
      }
      return 0;
    }
    
    if($p_battleState->{battleState} == -1) {
      if(! $automatic) {
        my $p_unreadyPlayers=$p_battleState->{unreadyPlayers};
        if($#{$p_unreadyPlayers}) {
          answer("Unable to start game, following players are not ready: ".join(",",@{$p_unreadyPlayers}));
        }else{
          answer("Unable to start game, $p_unreadyPlayers->[0] is not ready");
        }
      }
      return 0;
    }
  }

  if((! $force) && $p_battleState->{battleState} == 0) {
    answer("Unable to start game, $p_battleState->{warning} - use !forceStart to bypass") unless($automatic);
    return 0;
  }

  my $mapIsAvailableLocally = exists $availableMapsNameToNb{$currentMap} ? 1 : 0;

  if($spads->{bSettings}{startpostype} == 2) {
    if(! $force && ! %{$lobby->{battle}{startRects}}) {
      answer("Unable to start game, start position type is set to \"Choose in game\" but no start box is set - use !forceStart to bypass") unless($automatic);
      return 0;
    }
  }else{
    if(! $mapIsAvailableLocally) {
      answer("Unable to start game, start position type must be set to \"Choose in game\" when using a map unavailable on server (\"!bSet startPosType 2\")") unless($automatic);
      return 0;
    }

    my $r_mapInfo=$spads->getCachedMapInfo($currentMap);
    if($p_battleState->{nbIds} > $r_mapInfo->{nbStartPos}) {
      my $currentStartPosType=$spads->{bSettings}{startpostype} ? 'random' : 'fixed';
      answer("Unable to start game, not enough start positions on map for $currentStartPosType start position type") unless($automatic);
      return 0;
    }
  }

  if(! $force) {
    if($conf{autoBalance} ne 'off' && ! $balanceState) {
      answer("Unable to start game, autoBalance is enabled but battle hasn't been balanced yet - use !forceStart to bypass");
      return 0;
    }

    if($conf{autoFixColors} ne 'off' && ! $colorsState) {
      answer("Unable to start game, autoFixColors is enabled but colors haven't been fixed yet - use !forceStart to bypass");
      return 0;
    }
  }

  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('preGameCheck')) {
      my $reason=$plugins{$pluginName}->preGameCheck($force,$checkOnly,$automatic//0);
      if($reason) {
        answer("Unable to start game, $reason") unless($automatic || $reason eq '1');
        return 0;
      }
    }
  }

  return 1 if($checkOnly);

  if($conf{autoSaveBoxes}) {
    my $p_startRects=$lobby->{battle}{startRects};
    if(%{$p_startRects}) {
      my $smfMapName=$conf{map};
      $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);

      my $saveBoxes=1;
      if($conf{autoSaveBoxes} == 2) {
        my @ids=keys %{$p_startRects};
        my $nbTeams=$#ids+1;
        $nbTeams.="(-$conf{extraBox})" if($conf{extraBox});
        $saveBoxes=0 if($spads->existSavedMapBoxes($smfMapName,$nbTeams));
      }

      $spads->saveMapBoxes($smfMapName,$p_startRects,$conf{extraBox}) if($saveBoxes);
    }
  }

  my %additionalData=('game/AutohostPort' => $conf{autoHostPort},
                      playerData => {},
                      HOSTOPTIONS => {});
  foreach my $hostOption (qw'autoAddBotNb autoBalance autoBlockBalance autoBlockColors autoFixColors autoSpecExtraPlayers autoStart autoStop balanceMode clanMode extraBox idShareMode maxSpecs minPlayers minTeamSize nbPlayerById nbTeams noSpecChat noSpecDraw rankMode skillMode speedControl teamSize botsRank colorSensitivity') {
    $additionalData{HOSTOPTIONS}{$hostOption}=$conf{$hostOption};
    $additionalData{HOSTOPTIONS}{$hostOption}=~tr/;/:/;
  }
  $additionalData{HOSTOPTIONS}{forceStarted}=$force?1:0;
  $additionalData{HOSTOPTIONS}{springServerType}=$springServerType;
  $additionalData{HOSTOPTIONS}{spadsVersion}=$SPADS_VERSION;
  $additionalData{'game/HostIP'}=$conf{forceHostIp};
  {
    my %clansId;
    my $nextClanId=1;
    foreach my $bUser (keys %{$lobby->{battle}{users}}) {
      next unless(exists $lobby->{users}{$bUser} && exists $lobby->{users}{$bUser}{accountId} && $lobby->{users}{$bUser}{accountId});
      my $accountId=$lobby->{users}{$bUser}{accountId};
      my $clanPref=getUserPref($bUser,'clan');
      if($clanPref ne '') {
        $clansId{$clanPref}=$nextClanId++ unless(exists $clansId{$clanPref});
        $additionalData{playerData}{$accountId}{ClanId}=$clansId{$clanPref};
      }
      next unless(exists $battleSkills{$bUser} && exists $battleSkills{$bUser}{class});
      $additionalData{playerData}{$accountId}{SkillClass}=$battleSkills{$bUser}{class};
    }
  }
  $additionalData{"game/MapHash"}=uint32($spads->getMapHash($currentMap,$syncedSpringVersion)) unless($mapIsAvailableLocally);

  foreach my $pluginName (@pluginsOrder) {
    my $r_newStartScriptTags=$plugins{$pluginName}->addStartScriptTags(\%additionalData) if($plugins{$pluginName}->can('addStartScriptTags'));
    if(ref($r_newStartScriptTags) eq 'HASH') {
      foreach my $startScriptTag (keys %{$r_newStartScriptTags}) {
        if(exists $additionalData{$startScriptTag} && any {$startScriptTag eq $_} (qw'aiData playerData')) {
          foreach my $entityId (keys %{$r_newStartScriptTags->{$startScriptTag}}) {
            if(exists $additionalData{$startScriptTag}{$entityId}) {
              foreach my $tag (keys %{$r_newStartScriptTags->{$startScriptTag}{$entityId}}) {
                if(exists $additionalData{$startScriptTag}{$entityId}{$tag} && ref $r_newStartScriptTags->{$startScriptTag}{$entityId}{$tag} eq 'HASH' && ref $additionalData{$startScriptTag}{$entityId}{$tag} eq 'HASH') {
                  foreach my $subTag (keys %{$r_newStartScriptTags->{$startScriptTag}{$entityId}{$tag}}) {
                    $additionalData{$startScriptTag}{$entityId}{$tag}{$subTag}=$r_newStartScriptTags->{$startScriptTag}{$entityId}{$tag}{$subTag};
                  }
                }else{
                  $additionalData{$startScriptTag}{$entityId}{$tag}=$r_newStartScriptTags->{$startScriptTag}{$entityId}{$tag};
                }
              }
            }else{
              $additionalData{$startScriptTag}{$entityId}=$r_newStartScriptTags->{$startScriptTag}{$entityId};
            }
          }
        }else{
          $additionalData{$startScriptTag}=$r_newStartScriptTags->{$startScriptTag};
        }
      }
    }
  }
  
  my ($p_startData,$p_teamsMap,$p_allyTeamsMap)=$lobby->generateStartData(
    \%additionalData,
    getModSides($lobby->{battles}{$lobby->{battle}{battleId}}{mod}),
    undef,
    $springServerType eq 'dedicated' ? 1 : 2,
      );
  if(! $p_startData) {
    slog("Unable to start game: start script generation failed",1);
    closeBattleAfterGame("Unable to start game (start script generation failed)");
    return 0;
  }

  my $usLockFile = catfile($conf{$conf{sequentialUnitsync} ? 'varDir' : 'instanceDir'},'unitsync.lock');
  open($usLockFhForGameStart,'>',$usLockFile)
      or fatalError("Unable to write unitsync library lock file \"$usLockFile\" for game start ($!)",EXIT_SYSTEM);
  SimpleEvent::win32HdlDisableInheritance($usLockFhForGameStart) if(MSWIN32);
  return startGameServer($p_startData,$p_teamsMap,$p_allyTeamsMap)
      if(flock($usLockFhForGameStart, LOCK_EX|LOCK_NB));
  close($usLockFhForGameStart);
  undef $usLockFhForGameStart;
  if(%currentVote && exists $currentVote{command}) {
    broadcastMsg("Vote cancelled, preparing to launch game... (waiting for exclusive access to archives cache)");
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
    }
    %currentVote=();
  }else{
    broadcastMsg('Preparing to launch game... (waiting for exclusive access to archives cache)');
  }
  slog('Another process is using unitsync, waiting for lock to start game...',3);
  $timestamps{usLockRequestForGameStart}=time;
  return SimpleEvent::requestFileLock(
    'unitsyncLock',
    $usLockFile,
    LOCK_EX,
    sub {
      my $requestDelay=time-$timestamps{usLockRequestForGameStart};
      slog("Acquiring exclusive access to archives cache to start game took $requestDelay seconds",2)
          if($requestDelay > 5);
      $timestamps{usLockRequestForGameStart}=0;
      $usLockFhForGameStart=shift;
      startGameServer($p_startData,$p_teamsMap,$p_allyTeamsMap,$p_battleState->{players});
    },
    30,
    sub {
      $timestamps{usLockRequestForGameStart}=0;
      my $errMsg='Failed to launch game (timeout when acquiring exclusive access to archives cache)';
      slog($errMsg,1);
      broadcastMsg($errMsg);
    },
      );
}

sub startGameServer {
  my ($p_startData,$p_teamsMap,$p_allyTeamsMap,$p_players)=@_;

  if(defined $p_players) {
    my $cancelMsg;
    if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
      $cancelMsg='battle lobby closed';
    }elsif(any {! exists $lobby->{battle}{users}{$_}} @{$p_players}) {
      $cancelMsg='players left battle lobby';
    }
    if(defined $cancelMsg) {
      $cancelMsg="Cancelling game start ($cancelMsg during game launch)";
      broadcastMsg($cancelMsg);
      slog($cancelMsg,2);
      close($usLockFhForGameStart);
      undef $usLockFhForGameStart;
      return;
    }
  }
  
  open(SCRIPT,">$conf{instanceDir}/startscript.txt");
  for my $i (0..$#{$p_startData}) {
    print SCRIPT $p_startData->[$i]."\n";
  }
  close(SCRIPT);

  $timestamps{autoForcePossible}=0;
  $timestamps{lastGameStart}=time;
  $timestamps{lastGameStartPlaying}=0;
  $timestamps{gameOver}=0;
  $timestamps{autoStop}=0;
  %endGameData=();
  $cheating=0;
  if(%gdr) {
    slog("Starting a new game but previous game data report has not been sent!",2);
    %gdr=();
  }
  %gdrIPs=();
  %teamStats=();
  if($lobbyState > LOBBY_STATE_LOGGED_IN && exists $lobby->{users}{$gdrLobbyBot}) {
    $gdrEnabled=1;
  }else{
    $gdrEnabled=0;
  }

  my @springServerCmdParams = ( catfile($conf{instanceDir},'startscript.txt') );
  push(@springServerCmdParams,'--config',$conf{springConfig}) unless($conf{springConfig} eq '');
  my $logFile=catfile($conf{logDir},"spring-$springServerType.log");

  slog('Launching Spring server...',4);
  if($conf{useWin32Process}) {
    $springWin32Process=SimpleEvent::createWin32Process($springServerBin,
                                                        \@springServerCmdParams,
                                                        $conf{instanceDir},
                                                        \&onSpringProcessExit,
                                                        [[STDOUT => ">>$logFile"],[STDERR => '>>&STDOUT']],
                                                        1);
    if(! $springWin32Process) {
      $springWin32Process=undef;
      slog('Unable to create Win32 process to launch Spring',1);
      if($usLockFhForGameStart) {
        close($usLockFhForGameStart);
        undef $usLockFhForGameStart;
      }
      return 0;
    }
    $springPid=$springWin32Process->GetProcessID();
  }else{
    $springPid=SimpleEvent::forkProcess(
      sub {
        chdir($conf{instanceDir});
        if(MSWIN32) {
          exec(join(' ',(map {escapeWin32Parameter($_)} ($springServerBin,@springServerCmdParams)),'>>'.escapeWin32Parameter($logFile),'2>&1'))
              or execError("Unable to launch Spring ($!)",1);
        }else{
          open(my $previousStdout,'>&',\*STDOUT);
          open(my $previousStderr,'>&',\*STDERR);
          open(STDOUT,'>>',$logFile);
          open(STDERR,'>>&',\*STDOUT);
          portableExec($springServerBin,@springServerCmdParams);
          my $execErrorString=$!;
          open(STDOUT,'>&',$previousStdout);
          open(STDERR,'>&',$previousStderr);
          execError("Unable to launch Spring ($execErrorString)",1);
        }
      },
      \&onSpringProcessExit,
      1);
    if(! $springPid) {
      $springPid=0;
      slog('Unable to fork to launch Spring',1);
      if($usLockFhForGameStart) {
        close($usLockFhForGameStart);
        undef $usLockFhForGameStart;
      }
      return 0;
    }
  }
  if(%currentVote && exists $currentVote{command}) {
    broadcastMsg("Vote cancelled, launching game...");
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
    }
    %currentVote=();
  }else{
    broadcastMsg("Launching game...");
  }
  $p_runningBattle=$lobby->getRunningBattle();
  %runningBattleMapping=(teams => $p_teamsMap,
                         allyTeams => $p_allyTeamsMap);
  %runningBattleReversedMapping=(teams => {reverse %{$p_teamsMap}},
                                 allyTeams => {reverse %{$p_allyTeamsMap}});
  $p_gameOverResults={};
  %defeatTimes=();
  %inGameAddedUsers=();
  %inGameAddedPlayers=();
  my %clientStatus = %{$lobby->{users}{$conf{lobbyLogin}}{status}};
  $clientStatus{inGame}=1;
  queueLobbyCommand(["MYSTATUS",$lobby->marshallClientStatus(\%clientStatus)]);
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onSpringStart($springPid) if($plugins{$pluginName}->can('onSpringStart'));
  }
  return 1;
}

sub listBans {
  my ($p_bans,$showIPs,$user,$hashBans)=@_;

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my @banEntries;
  foreach my $p_ban (@{$p_bans}) {
    my %userFilter=%{$p_ban->[0]};
    my %ban=%{$p_ban->[1]};
    my $banString = $hashBans ? '('.$spads->getBanHash($p_ban).') ' : '  ';
    my $index=0;
    foreach my $field (sort keys %userFilter) {
      if(defined $userFilter{$field} && $userFilter{$field} ne '') {
        $banString.=";" if($index);
        if($field eq "ip" && ! $showIPs) {
          $banString.="$C{5}ip$C{1}=$C{12}<hidden>$C{1}";
        }else{
          $banString.="$C{5}$field$C{1}".($userFilter{$field} =~ /^[<>]/ ? '' : '=');
          if($userFilter{$field} =~ /[ ,]/) {
            $banString.="\"$C{12}$userFilter{$field}$C{1}\"";
          }else{
            $banString.="$C{12}$userFilter{$field}$C{1}";
          }
        }
        $index++;
      }
    }
    $banString.=" $C{4}$B-->$B$C{1} ";
    $index=0;
    foreach my $field (sort keys %ban) {
      if(defined $ban{$field} && $ban{$field} ne '') {
        if($field =~ /Date$/) {
          my @time = localtime($ban{$field});
          $time[4]++;
          @time = map(sprintf('%02d',$_),@time);
          $ban{$field}=($time[5]+1900)."-$time[4]-$time[3] $time[2]:$time[1]:$time[0]";
        }elsif($field eq 'banType') {
          my %banTypes = (0 => 'full', 1 => 'battle', 2 => 'force-spec', 3 => 'unbanned');
          $ban{$field}=$banTypes{$ban{$field}} if(exists $banTypes{$ban{$field}});
        }
        $ban{$field}="\"$ban{$field}\"" if($ban{$field} =~ /[ ,]/);
        $banString.=", " if($index);
        $banString.="$C{10}$field$C{1}=$ban{$field}";
        $index++;
      }
    }
    push(@banEntries,$banString);
  }
  return \@banEntries;
}

sub checkUserMsgFlood {
  my $user=shift;

  my $timestamp=time;
  $lastBattleMsg{$user}={} unless(exists $lastBattleMsg{$user});
  $lastBattleMsg{$user}{$timestamp}=0 unless(exists $lastBattleMsg{$user}{$timestamp});
  $lastBattleMsg{$user}{$timestamp}++;

  return 0 if($user eq $conf{lobbyLogin});
  return 0 if(getUserAccessLevel($user) >= $conf{floodImmuneLevel});
  return 1 if(exists $pendingFloodKicks{$user});

  my @autoKickData=split(/;/,$conf{msgFloodAutoKick});

  my $received=0;
  foreach my $timestamp (keys %{$lastBattleMsg{$user}}) {
    if(time - $timestamp > $autoKickData[1]) {
      delete $lastBattleMsg{$user}{$timestamp};
    }else{
      $received+=$lastBattleMsg{$user}{$timestamp};
    }
  }

  if($autoKickData[0] && $received >= $autoKickData[0]) {
    broadcastMsg("Kicking $user from battle (battle lobby message flood protection)");
    queueLobbyCommand(["KICKFROMBATTLE",$user]);
    $pendingFloodKicks{$user}=1;
    checkKickFlood($user);
    return 1;
  }

  return 0;
}

sub checkUserStatusFlood {
  my $user=shift;

  my $timestamp=time;
  $lastBattleStatus{$user}={} unless(exists $lastBattleStatus{$user});
  $lastBattleStatus{$user}{$timestamp}=0 unless(exists $lastBattleStatus{$user}{$timestamp});
  $lastBattleStatus{$user}{$timestamp}++;

  return 0 if($user eq $conf{lobbyLogin});
  return 0 if(getUserAccessLevel($user) >= $conf{floodImmuneLevel});
  return 1 if(exists $pendingFloodKicks{$user});

  my @autoKickData=split(/;/,$conf{statusFloodAutoKick});

  my $received=0;
  foreach my $timestamp (keys %{$lastBattleStatus{$user}}) {
    if(time - $timestamp > $autoKickData[1]) {
      delete $lastBattleStatus{$user}{$timestamp};
    }else{
      $received+=$lastBattleStatus{$user}{$timestamp};
    }
  }

  if($autoKickData[0] && $received >= $autoKickData[0]) {
    broadcastMsg("Kicking $user from battle (battle lobby status flood protection)");
    queueLobbyCommand(["KICKFROMBATTLE",$user]);
    $pendingFloodKicks{$user}=1;
    checkKickFlood($user);
    return 1;
  }

  return 0;
}

sub checkKickFlood {
  my $user=shift;

  my $timestamp=time;
  $lastFloodKicks{$user}={} unless(exists $lastFloodKicks{$user});
  $lastFloodKicks{$user}{$timestamp}=0 unless(exists $lastFloodKicks{$user}{$timestamp});
  $lastFloodKicks{$user}{$timestamp}++;
  
  my @autoBanData=split(/;/,$conf{kickFloodAutoBan});

  my $nbKick=0;
  foreach my $timestamp (keys %{$lastFloodKicks{$user}}) {
    if(time - $timestamp > $autoBanData[1]) {
      delete $lastFloodKicks{$user}{$timestamp};
    }else{
      $nbKick+=$lastFloodKicks{$user}{$timestamp};
    }
  }

  if($autoBanData[0] && $nbKick >= $autoBanData[0]) {
      my $p_user;
      my $accountId=$lobby->{users}{$user}{accountId};
      if($accountId) {
        $p_user={accountId => "$accountId($user)"};
      }else{
        $p_user={name => $user};
      }
      my $p_ban={banType => 1,
                 startDate => time,
                 endDate => time + ($autoBanData[2] * 60),
                 reason => "battle lobby flood protection"};
      $spads->banUser($p_user,$p_ban);
      broadcastMsg("Battle ban added for user $user (duration: $autoBanData[2] minute(s), reason: battle lobby flood protection)");
      return 1;
  }

  return 0;
}

sub checkCmdFlood {
  my $user=shift;

  return 0 if(getUserAccessLevel($user) >= $conf{floodImmuneLevel} || $user eq $sldbLobbyBot);

  my $timestamp=time;
  $lastCmds{$user}={} unless(exists $lastCmds{$user});
  $lastCmds{$user}{$timestamp}=0 unless(exists $lastCmds{$user}{$timestamp});
  $lastCmds{$user}{$timestamp}++;
  
  if(exists $ignoredUsers{$user}) {
    if(time > $ignoredUsers{$user}) {
      delete $ignoredUsers{$user};
    }else{
      return 1;
    }
  }

  my @autoIgnoreData=split(/;/,$conf{cmdFloodAutoIgnore});

  my $received=0;
  foreach my $timestamp (keys %{$lastCmds{$user}}) {
    if(time - $timestamp > $autoIgnoreData[1]) {
      delete $lastCmds{$user}{$timestamp};
    }else{
      $received+=$lastCmds{$user}{$timestamp};
    }
  }

  if($autoIgnoreData[0] && $received >= $autoIgnoreData[0]) {
    broadcastMsg("Ignoring $user for $autoIgnoreData[2] minute(s) (command flood protection)");
    $ignoredUsers{$user}=time+($autoIgnoreData[2] * 60);
    return 1;
  }
  
  return 0;
}

sub checkRelayedApiFlood {
  my $user=shift;

  return 0 if(getUserAccessLevel($user) >= $conf{floodImmuneLevel});

  my $currentTs=time;
  if(exists $nbRelayedApiCalls{$user}{$currentTs}) {
    $nbRelayedApiCalls{$user}{$currentTs}++;
  }else{
    $nbRelayedApiCalls{$user}{$currentTs}=1;
  }
  
  if(exists $ignoredRelayedApiUsers{$user}) {
    if(time > $ignoredRelayedApiUsers{$user}) {
      delete $ignoredRelayedApiUsers{$user};
    }else{
      return 2;
    }
  }

  my @autoIgnoreData=split(/;/,$conf{cmdFloodAutoIgnore});
  return unless($autoIgnoreData[0]);

  my $received=0;
  foreach my $ts (keys %{$nbRelayedApiCalls{$user}}) {
    if($currentTs - $ts > $autoIgnoreData[1]) {
      delete $nbRelayedApiCalls{$user}{$ts};
    }else{
      $received+=$nbRelayedApiCalls{$user}{$ts};
    }
  }

  if($received >= $autoIgnoreData[0]) {
    $ignoredRelayedApiUsers{$user}=time+($autoIgnoreData[2] * 60);
    return 1;
  }
  
  return 0;
}

sub logMsg {
  my ($file,$msg)=@_;
  if(! -d $conf{logDir}."/chat") {
    if(! mkdir($conf{logDir}."/chat")) {
      slog("Unable to create directory \"$conf{logDir}/chat\"",1);
      return;
    }
  }
  if(! open(CHAT,'>>:encoding(utf-8)',"$conf{logDir}/chat/$file.log")) {
    slog("Unable to log chat message into file \"$conf{logDir}/chat/$file.log\"",1);
    return;
  }
  my $dateTime=localtime();
  print CHAT "[$dateTime] $msg\n";
  close(CHAT);
}

sub needRehost {
  return 0 unless($lobbyState >= LOBBY_STATE_BATTLE_OPENED);
  my %params = (
    battleName => 'title',
    port => 'port',
    natType => 'natType',
    minRank => 'rank'
  );
  if(exists $lobby->{users}{$conf{lobbyLogin}} && $lobby->{users}{$conf{lobbyLogin}}{status}{bot}) {
    $params{maxPlayers}='maxPlayers';
  }else{
    return 1 if($spads->{hSettings}{maxPlayers} != $lobby->{battles}{$lobby->{battle}{battleId}}{maxPlayers}
                && ($spads->{hSettings}{maxPlayers} < 9 || $lobby->{battles}{$lobby->{battle}{battleId}}{maxPlayers} != 8));
  }
  foreach my $p (keys %params) {
    return 1 if($spads->{hSettings}{$p} ne $lobby->{battles}{$lobby->{battle}{battleId}}{$params{$p}});
  }
  return 1 if($targetMod ne '' && $targetMod ne $lobby->{battles}{$lobby->{battle}{battleId}}{mod});
  return 1 if($spads->{hSettings}{password} ne $lobby->{battle}{password});
  return 0;
}

sub specExtraPlayers {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});

  my @bots=@{$lobby->{battle}{botList}};
  my @players=sort {$currentPlayers{$a} <=> $currentPlayers{$b}} (keys %currentPlayers);
  my $nbPlayersToSpec=$#players+1-($conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams});
  if($conf{nbTeams} != 1) {
    $nbPlayersToSpec+=$#bots+1;
  }
  
  if($nbPlayersToSpec > 0) {
    my $forceReason="[autoSpecExtraPlayers=1, ";
    if($conf{teamSize} == 1) {
      $forceReason.="nbTeams=$conf{nbTeams}] (use \"!set nbTeams <n>\" to change it)";
    }else{
      $forceReason.="teamSize=$conf{teamSize}] (use \"!set teamSize <n>\" to change it)";
    }
    if(@bots && $conf{nbTeams} != 1) {
      my $nbKickedBots=$nbPlayersToSpec;
      $nbKickedBots=$#bots+1 if($#bots+1 < $nbPlayersToSpec);
      sayBattle("Kicking $nbKickedBots bot(s) $forceReason");
      while($nbPlayersToSpec > 0 && @bots) {
        my $kickedBot=pop(@bots);
        $nbPlayersToSpec--;
        queueLobbyCommand(["REMOVEBOT",$kickedBot]);
      }
    }
    if($nbPlayersToSpec) {
      sayBattle("Forcing spectator mode for $nbPlayersToSpec players(s) $forceReason");
      while($nbPlayersToSpec > 0 && @players) {
        my $spectedPlayer=pop(@players);
        $nbPlayersToSpec--;
        queueLobbyCommand(["FORCESPECTATORMODE",$spectedPlayer]);
      }
    }
  }
}

sub enforceMaxSpecs {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  return if($conf{maxSpecs} eq '');

  my @specs=sort {$currentSpecs{$a} <=> $currentSpecs{$b}} (keys %currentSpecs);
  my $nbSpecsToKick=$#specs-$conf{maxSpecs};

  return if($nbSpecsToKick <= 0);
  for my $i (1..$nbSpecsToKick) {
    my $specToKick=pop(@specs);
    while($specToKick eq $conf{lobbyLogin} || getUserAccessLevel($specToKick) >= $conf{maxSpecsImmuneLevel}) {
      $specToKick=pop(@specs);
      last unless(defined $specToKick);
    }
    last unless(defined $specToKick);
    broadcastMsg("Kicking spectator $specToKick from battle [maxSpecs=$conf{maxSpecs}]");
    queueLobbyCommand(["KICKFROMBATTLE",$specToKick]);
  }
}

sub enforceMaxBots {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});

  
  my @bots=@{$lobby->{battle}{botList}};
  my @localBots;
  my @remoteBots;

  my $nbBots=$#bots+1;
  my $nbLocalBots=0;
  my $nbRemoteBots=0;

  foreach my $botName (@bots) {
    if($lobby->{battle}{bots}{$botName}{owner} eq $conf{lobbyLogin}) {
      push(@localBots,$botName);
      $nbLocalBots++;
    }else{
      push(@remoteBots,$botName);
      $nbRemoteBots++;
    }
  }

  my ($nbLocalBotsToRemove,$nbRemoteBotsToRemove,$nbBotsToRemove)=(0,0,0);
  if($nbLocalBots > $conf{maxLocalBots}) {
    $nbLocalBotsToRemove=$nbLocalBots-$conf{maxLocalBots};
  }
  if($nbRemoteBots > $conf{maxRemoteBots}) {
    $nbRemoteBotsToRemove=$nbRemoteBots-$conf{maxRemoteBots};
  }
  if($nbBots-$nbRemoteBotsToRemove-$nbLocalBotsToRemove > $conf{maxBots}) {
    $nbBotsToRemove=$nbBots-$nbRemoteBotsToRemove-$nbLocalBotsToRemove-$conf{maxBots};
  }

  my %botsToRemove;
  for my $i (1..$nbLocalBotsToRemove) {
    my $removedBot=pop(@localBots);
    $botsToRemove{$removedBot}=1;
  }
  for my $i (1..$nbRemoteBotsToRemove) {
    my $removedBot=pop(@remoteBots);
    $botsToRemove{$removedBot}=1;
  }
  for my $i (1..$nbBotsToRemove) {
    my $removedBot=pop(@bots);
    while(exists $botsToRemove{$removedBot}) {
      $removedBot=pop(@bots);
      last unless(defined $removedBot);
    }
    if(! defined $removedBot) {
      slog("Unable to remove expected number of bots from battle",2);
      last;
    }
    $botsToRemove{$removedBot}=1;
  }

  foreach my $removedBot (keys %botsToRemove) {
    queueLobbyCommand(['REMOVEBOT',$removedBot]);
  }
  
}

sub updateCurrentGameType {
  my $nbPlayers=0;
  $nbPlayers=(keys %{$lobby->{battle}{users}}) - getNbNonPlayer() + (keys %{$lobby->{battle}{bots}}) if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  my $newGameType=(getTargetBattleStructure($nbPlayers))[2];
  return if($newGameType eq $currentGameType);
  $currentGameType=$newGameType;
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  my $needRebalance=0;
  foreach my $user (keys %battleSkills) {
    my $accountId=$lobby->{users}{$user}{accountId};
    my $previousUserSkill=$battleSkills{$user}{skill};
    my $userSkillPref=getUserPref($user,'skillMode');
    if($userSkillPref eq 'TrueSkill') {
      next if(exists $pendingGetSkills{$accountId});
      if(! exists $battleSkillsCache{$user}) {
        slog("Unable to update battle skill of player $user for new game type, no cached skill available!",2)
            if($battleSkills{$user}{skillOrigin} eq 'TrueSkill');
      }else{
        $battleSkills{$user}{skill}=$battleSkillsCache{$user}{$currentGameType}{skill};
        $battleSkills{$user}{sigma}=$battleSkillsCache{$user}{$currentGameType}{sigma};
        $battleSkills{$user}{class}=$battleSkillsCache{$user}{$currentGameType}{class};
        $battleSkills{$user}{skillOrigin}='TrueSkill';
      }
    }
    pluginsUpdateSkill($battleSkills{$user},$accountId);
    sendPlayerSkill($user);
    $needRebalance=1 if($previousUserSkill != $battleSkills{$user}{skill} && exists $lobby->{battle}{users}{$user}
                        && defined $lobby->{battle}{users}{$user}{battleStatus} && $lobby->{battle}{users}{$user}{battleStatus}{mode});
  }
  if($needRebalance) {
    $balanceState=0;
    %balanceTarget=();
  }
}

sub updateBattleSkillsForNewSkillAndRankModes {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  foreach my $user (keys %{$lobby->{battle}{users}}) {
    updateBattleSkillForNewSkillAndRankModes($user);
  }
}

sub updateBattleSkillForNewSkillAndRankModes {
  my $user=shift;
  return if($user eq $conf{lobbyLogin});
  if(! exists $battleSkills{$user}) {
    slog("Unable to update battle skill for user $user, no battle skill available!",2);
    return;
  }
  my $accountId=$lobby->{users}{$user}{accountId};
  my $userLobbyRank=$lobby->{users}{$user}{status}{rank};
  my $userRankPref=getUserPref($user,'rankMode');
  my $userIp=getLatestUserIp($user);
  if($userRankPref eq 'account') {
    $battleSkills{$user}{rank}=$userLobbyRank;
    $battleSkills{$user}{rankOrigin}='account';
  }elsif($userRankPref eq 'ip') {
    if($userIp) {
      my ($ipRank,$chRanked)=getIpRank($userIp);
      $battleSkills{$user}{rank}=$ipRank;
      if($chRanked) {
        $battleSkills{$user}{rankOrigin}='ipManual';
      }else{
        $battleSkills{$user}{rankOrigin}='ip';
      }
    }else{
      $battleSkills{$user}{rank}=$userLobbyRank;
      $battleSkills{$user}{rankOrigin}='account';
    }
  }else{
    $battleSkills{$user}{rank}=$userRankPref;
    $battleSkills{$user}{rankOrigin}='manual';
  }
  my $userSkillPref=getUserPref($user,'skillMode');
  if($userSkillPref eq 'TrueSkill') {
    $battleSkills{$user}{skillOrigin}='TrueSkillDegraded';
    $battleSkills{$user}{skill}=$RANK_TRUESKILL{$battleSkills{$user}{rank}};
    if(exists $battleSkillsCache{$user}) {
      $battleSkills{$user}{skill}=$battleSkillsCache{$user}{$currentGameType}{skill};
      $battleSkills{$user}{sigma}=$battleSkillsCache{$user}{$currentGameType}{sigma};
      $battleSkills{$user}{class}=$battleSkillsCache{$user}{$currentGameType}{class};
      $battleSkills{$user}{skillOrigin}='TrueSkill';
      pluginsUpdateSkill($battleSkills{$user},$accountId);
      sendPlayerSkill($user);
      checkBattleBansForPlayer($user);
    }elsif(! exists $pendingGetSkills{$accountId}) {
      if(exists $lobby->{users}{$sldbLobbyBot} && $accountId) {
        my $getSkillParam=$accountId;
        $getSkillParam.="|$userIp" if($userIp);
        sayPrivate($sldbLobbyBot,"!#getSkill 3 $getSkillParam");
        $pendingGetSkills{$accountId}=time;
      }else{
        pluginsUpdateSkill($battleSkills{$user},$accountId);
        sendPlayerSkill($user);
        checkBattleBansForPlayer($user);
      }
    }
  }else{
    $battleSkills{$user}{skillOrigin}='rank';
    $battleSkills{$user}{skill}=$RANK_SKILL{$battleSkills{$user}{rank}};
    delete $battleSkills{$user}{sigma};
    pluginsUpdateSkill($battleSkills{$user},$accountId);
    sendPlayerSkill($user);
    checkBattleBansForPlayer($user);
  }
}

sub sendPlayerSkill {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  
  my $player=shift;
  if(! exists $lobby->{battle}{users}{$player}) {
    slog("Unable to send skill of player $player to battle lobby, player is not in battle!",2);
    return;
  }
  
  my $skillOrigin=$battleSkills{$player}{skillOrigin};
  
  my $skill;
  if($skillOrigin eq 'rank') {
    $skill="($battleSkills{$player}{skill})";
  }elsif($skillOrigin eq 'TrueSkill') {
    if(exists $battleSkills{$player}{skillPrivacy} && $battleSkills{$player}{skillPrivacy} == 0) {
      $skill=$battleSkills{$player}{skill};
    }else{
      $skill=getRoundedSkill($battleSkills{$player}{skill});
      $skill="~$skill";
    }
  }elsif($skillOrigin eq 'TrueSkillDegraded') {
    $skill="\#$battleSkills{$player}{skill}\#";
  }elsif($skillOrigin eq 'Plugin') {
    $skill="\[$battleSkills{$player}{skill}\]";
  }elsif($skillOrigin eq 'PluginDegraded') {
    $skill="\[\#$battleSkills{$player}{skill}\#\]";
  }else{
    $skill="?$battleSkills{$player}{skill}?";
  }
  my $lcPlayer=lc($player);
  queueLobbyCommand(["SETSCRIPTTAGS","game/players/$lcPlayer/skill=$skill"]);
  $sentPlayersScriptTags{$lcPlayer}{skill}=1;
  
  if(($skillOrigin eq 'TrueSkill' || $skillOrigin eq 'Plugin')
     && exists $battleSkills{$player}{sigma}) {
    my $skillSigma;
    if($skillOrigin eq 'TrueSkill') {
      if($battleSkills{$player}{sigma} > 3) {
        $skillSigma=3;
      }elsif($battleSkills{$player}{sigma} > 2) {
        $skillSigma=2;
      }elsif($battleSkills{$player}{sigma} > 1.5) {
        $skillSigma=1;
      }else{
        $skillSigma=0;
      }
    }else{
      $skillSigma=$battleSkills{$player}{sigma};
    }
    queueLobbyCommand(["SETSCRIPTTAGS","game/players/$lcPlayer/skilluncertainty=$skillSigma"]);
    $sentPlayersScriptTags{$lcPlayer}{skilluncertainty}=1;
  }elsif(exists $sentPlayersScriptTags{$lcPlayer}{skilluncertainty}) {
    queueLobbyCommand(["REMOVESCRIPTTAGS","game/players/$lcPlayer/skilluncertainty"]);
    delete $sentPlayersScriptTags{$lcPlayer}{skilluncertainty};
  }
}

sub getBattleSkills {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  foreach my $user (keys %{$lobby->{battle}{users}}) {
    getBattleSkill($user);
  }
  $balanceState=0;
  %balanceTarget=();
}

sub getBattleSkill {
  my $user=shift;
  return if($user eq $conf{lobbyLogin});
  my $accountId=$lobby->{users}{$user}{accountId};
  my %userSkill;
  my $userLobbyRank=$lobby->{users}{$user}{status}{rank};
  my $userRankPref=getUserPref($user,'rankMode');
  my $userIp=getLatestUserIp($user);
  if($userRankPref eq 'account') {
    $userSkill{rank}=$userLobbyRank;
    $userSkill{rankOrigin}='account';
  }elsif($userRankPref eq 'ip') {
    if($userIp) {
      my ($ipRank,$chRanked)=getIpRank($userIp);
      $userSkill{rank}=$ipRank;
      if($chRanked) {
        $userSkill{rankOrigin}='ipManual';
      }else{
        $userSkill{rankOrigin}='ip';
      }
    }else{
      $userSkill{rank}=$userLobbyRank;
      $userSkill{rankOrigin}='account';
    }
  }else{
    $userSkill{rank}=$userRankPref;
    $userSkill{rankOrigin}='manual';
  }
  my $userSkillPref=getUserPref($user,'skillMode');
  if($userSkillPref eq 'TrueSkill') {
    $userSkill{skillOrigin}='TrueSkillDegraded';
    $userSkill{skill}=$RANK_TRUESKILL{$userSkill{rank}};
  }else{
    $userSkill{skillOrigin}='rank';
    $userSkill{skill}=$RANK_SKILL{$userSkill{rank}};
  }
  if($userSkillPref eq 'TrueSkill' && exists $lobby->{users}{$sldbLobbyBot} && $accountId) {
    my $getSkillParam=$accountId;
    $getSkillParam.="|$userIp" if($userIp);
    sayPrivate($sldbLobbyBot,"!#getSkill 3 $getSkillParam");
    $pendingGetSkills{$accountId}=time;
    $battleSkills{$user}=\%userSkill;
  }else{
    pluginsUpdateSkill(\%userSkill,$accountId);
    $battleSkills{$user}=\%userSkill;
    sendPlayerSkill($user);
    checkBattleBansForPlayer($user);
  }
}

sub applySettingChange {
  my $settingRegExp=shift;
  if('maplist' =~ /^$settingRegExp$/) {
    $timestamps{mapLearned}=0;
    $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  }
  $timestamps{battleChange}=time;
  updateBattleInfoIfNeeded();
  updateBattleStates();
  sendBattleMapOptions() if('map' =~ /^$settingRegExp$/);
  applyMapBoxes() if(any {$_ =~ /^$settingRegExp$/} (qw'map nbteams extrabox'));
  if(any {$_ =~ /^$settingRegExp$/} (qw'nbplayerbyid teamsize minteamsize nbteams balancemode autobalance idsharemode clanmode')) {
    $balanceState=0;
    %balanceTarget=();
  }
  if(any {$_ =~ /^$settingRegExp$/} (qw'autofixcolors colorsensitivity')) {
    $colorsState=0;
    %colorsTarget=();
  }
  enforceMaxBots() if(any {$_ =~ /^$settingRegExp$/} (qw'maxbots maxlocalbots maxremotebots'));
  enforceMaxSpecs() if('maxspecs' =~ /^$settingRegExp$/);
  specExtraPlayers() if($conf{autoSpecExtraPlayers} && (any {$_ =~ /^$settingRegExp$/} (qw'nbteams nbplayerbyid')));
  if($autohost->getState()) {
    if('nospecdraw' =~ /^$settingRegExp$/) {
      my $noSpecDraw=$conf{noSpecDraw};
      $noSpecDraw=1-$noSpecDraw if($syncedSpringVersion =~ /^(\d+)/ && $1 < 96);
      $autohost->sendChatMessage("/nospecdraw $noSpecDraw");
    }
    $autohost->sendChatMessage("/nospectatorchat $conf{noSpecChat}") if('nospecchat' =~ /^$settingRegExp$/);
    if('speedcontrol' =~ /^$settingRegExp$/) {
      my $speedControl=$conf{speedControl};
      $speedControl=2 if($speedControl == 0);
      $autohost->sendChatMessage("/speedcontrol $speedControl");
    }
  }
  updateCurrentGameType() if(any {$_ =~ /^$settingRegExp$/} (qw'nbteams teamsize nbplayerbyid idsharemode minteamSize'));
  if(any {$_ =~ /^$settingRegExp$/} (qw'rankmode skillmode')) {
    updateBattleSkillsForNewSkillAndRankModes();
    $balanceState=0;
    %balanceTarget=();
  }
  applyBattleBans() if(any {$_ =~ /^$settingRegExp$/} (qw'banlist nbteams teamsize'));
}

sub applyBattleBans {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  foreach my $user (keys %{$lobby->{battle}{users}}) {
    checkBattleBansForPlayer($user);
  }
}

sub checkBattleBansForPlayer {
  my $user=shift;
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  my $p_ban=$spads->getUserBan($user,$lobby->{users}{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
  if($p_ban->{banType} < 2) {
    queueLobbyCommand(["KICKFROMBATTLE",$user]);
  }elsif($p_ban->{banType} == 2) {
    if(defined $lobby->{battle}{users}{$user}{battleStatus} && $lobby->{battle}{users}{$user}{battleStatus}{mode}) {
      queueLobbyCommand(["FORCESPECTATORMODE",$user]);
      if(! exists $forceSpecTimestamps{$user} || time - $forceSpecTimestamps{$user} > 60) {
        $forceSpecTimestamps{$user}=time;
        my $forceMessage="Forcing spectator mode for $user [auto-spec mode]";
        $forceMessage.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne '');
        sayBattle($forceMessage);
        checkUserMsgFlood($user);
      }
    }
  }
}

sub applyAllSettings {
  return unless($lobbyState > LOBBY_STATE_OPENING_BATTLE);
  applySettingChange(".*");
  sendBattleSettings();
}

sub applyPreset {
  my $preset=shift;
  my $oldPreset=$conf{preset};
  $spads->applyPreset($preset);
  $timestamps{mapLearned}=0;
  $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  setDefaultMapOfMaplist() if($spads->{conf}{map} eq '');
  %conf=%{$spads->{conf}};
  applyAllSettings();
  updateTargetMod();
  pluginsOnPresetApplied($oldPreset,$preset)
}

sub autoManageBattle {
  return if(time - $timestamps{battleChange} < 2);
  return if($springPid);
  return unless(%{$lobby->{battle}});

  my $nbNonPlayer=getNbNonPlayer();
  my @clients=keys %{$lobby->{battle}{users}};
  my @bots=keys %{$lobby->{battle}{bots}};
  my $nbBots=$#bots+1;
  my $nbPlayers=$#clients+1-$nbNonPlayer;
  $nbPlayers+=$nbBots if($conf{nbTeams} != 1);
  my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};

  my $minTeamSize=$conf{minTeamSize};
  $minTeamSize=$conf{teamSize} if($minTeamSize == 0);

  if($springServerType eq 'headless' && ! (%pendingLocalBotManual || %pendingLocalBotAuto)) {

    my $nbLocalBots=0;
    foreach my $existingBot (@bots) {
      $nbLocalBots++ if($lobby->{battle}{bots}{$existingBot}{owner} eq $conf{lobbyLogin});
    }

    my $deltaLocalBots=0;
    if($conf{nbTeams} == 1) {
      $deltaLocalBots=$conf{autoAddBotNb}-$nbBots;
    }elsif($conf{teamSize} == 1 ) {
      $deltaLocalBots=$conf{autoAddBotNb}-$nbPlayers;
    }elsif($minTeamSize != 1) {
      $deltaLocalBots=$conf{autoAddBotNb}*$minTeamSize-$nbPlayers;
    }else{
      $deltaLocalBots=$conf{autoAddBotNb}*$conf{nbTeams}-$nbPlayers;
    }
    $deltaLocalBots=$conf{maxLocalBots}-$nbLocalBots if($deltaLocalBots > 0 && $conf{maxLocalBots} ne '' && $nbLocalBots + $deltaLocalBots > $conf{maxLocalBots});
    $deltaLocalBots=$conf{maxBots}-$nbBots if($deltaLocalBots > 0 && $conf{maxBots} ne '' && $nbBots + $deltaLocalBots > $conf{maxBots});

    if($conf{nbTeams} != 1 && $conf{autoSpecExtraPlayers}) {
      $deltaLocalBots-=$nbPlayers+$deltaLocalBots-$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams} if($nbPlayers+$deltaLocalBots>$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams});
    }

    if($deltaLocalBots > 0) {
      my ($p_localBotsNames,$p_localBots)=getPresetLocalBots();
      for my $i (1..$deltaLocalBots) {
        my $p_nextLocalBot=getNextLocalBot($p_localBotsNames,$p_localBots);
        if(! %{$p_nextLocalBot}) {
          slog("Unable to auto-add a local AI bot (not enough AI bot definitions in \"localBots\" preset setting)",2);
          last;
        }else{
          my ($botName,$botSide,$botAi,$p_botColor)=($p_nextLocalBot->{name},$p_nextLocalBot->{side},$p_nextLocalBot->{ai},$p_nextLocalBot->{color});
          my $realBotSide=translateSideIfNeeded($botSide);
          if(! defined $realBotSide) {
            slog("Invalid bot side \"$botSide\" for current MOD, using default MOD side instead",2);
            $botSide=0;
          }else{
            $botSide=$realBotSide;
          }
          $pendingLocalBotAuto{$botName}=time;
          queueLobbyCommand(['ADDBOT',$botName,$lobby->marshallBattleStatus({side => $botSide, sync => 0, bonus => 0, mode => 1, team => 0, id => 0, ready => 1}),$lobby->marshallColor($p_botColor),$botAi]);
          $timestamps{battleChange}=time;
        }
      }
    }elsif($deltaLocalBots < 0 && %autoAddedLocalBots) {
      $deltaLocalBots=-$deltaLocalBots;

      my @autoAddedLocalBotNames=sort {$autoAddedLocalBots{$a} <=> $autoAddedLocalBots{$b}} (keys %autoAddedLocalBots);
      my $nbAutoAddedLocalBots=$#autoAddedLocalBotNames+1;
      $deltaLocalBots=$nbAutoAddedLocalBots if($deltaLocalBots>$nbAutoAddedLocalBots);

      for my $i (1..$deltaLocalBots) {
        my $removedBot=pop(@autoAddedLocalBotNames);
        $pendingLocalBotAuto{'-'.$removedBot}=time;
        queueLobbyCommand(['REMOVEBOT',$removedBot]);
      }

      $timestamps{battleChange}=time;
    }
  }

  my $latestPendingBot=0;
  foreach my $pendingBot (keys %pendingLocalBotManual) {
    $latestPendingBot=$pendingLocalBotManual{$pendingBot} if($pendingLocalBotManual{$pendingBot} > $latestPendingBot);
  }
  foreach my $pendingBot (keys %pendingLocalBotAuto) {
    $latestPendingBot=$pendingLocalBotAuto{$pendingBot} if($pendingLocalBotAuto{$pendingBot} > $latestPendingBot);
  }

  return if(time - $timestamps{battleChange} < 2 || time - $latestPendingBot < 5);

  my $battleState=0;
  if((($minTeamSize == 1 && (! ($nbPlayers % $conf{nbTeams}) || $nbPlayers < $conf{nbTeams}))
      || ($minTeamSize > 1 && (! ($nbPlayers % $minTeamSize))))
     && $nbPlayers >= $conf{minPlayers}
     && ($conf{nbTeams} != 1  || @bots)) {
    $battleState=1;
    $battleState=2 if($nbPlayers >= $targetNbPlayers);
  }
  return unless($battleState);

  my $autoBalanceInProgress=0;
  if($conf{autoBalance} ne 'off') {
    return if($conf{autoBalance} eq 'on' && $battleState < 2);
    if(! $balanceState) {
      return if(time - $timestamps{balance} < 5 || time - $timestamps{autoBalance} < 1);
      $timestamps{autoBalance}=time;
      balance();
      $autoBalanceInProgress=1;
    }
  }

  if($conf{autoFixColors} ne 'off') {
    return if($conf{autoFixColors} eq 'on' && $battleState < 2);
    if(! $colorsState) {
      return if(time - $timestamps{fixColors} < 5);
      fixColors($autoBalanceInProgress);
      return;
    }
  }

  return if($autoBalanceInProgress);
  
  if($conf{autoStart} ne 'off') {
    return if(%{$lobby->{battle}{bots}});
    return if($conf{autoStart} eq 'on' && $battleState < 2);
    return if($timestamps{usLockRequestForGameStart});
    launchGame(0,0,1);
  }

}

sub advancedMapSearch {
  my ($val,$p_values,$atEnd)=@_;
  $atEnd//=0;
  my @values=@{$p_values};
  foreach my $value (@values) {
    return $value if(lc($value) eq lc($val) || $value eq $val.'.smf');
  }
  if(! $atEnd) {
    my $value = first {index($_,$val) == 0} @values;
    return $value if(defined $value);
    $value = first {index(lc($_),lc($val)) == 0} @values;
    return $value if(defined $value);
    $value = first {index($_,$val) > 0} @values;
    return $value if(defined $value);
    $value = first {index(lc($_),lc($val)) > 0} @values;
    return $value if(defined $value);
  }else{
    my $quotedVal=quotemeta($val);
    foreach my $value (@values) {
      return $value if($value =~ /$quotedVal$/);
    }
    foreach my $value (@values) {
      return $value if($value =~ /$quotedVal$/i);
    }
  }
  if($val =~ / /) {
    my @vals=split(/ /,$val);
    @vals=map(quotemeta,@vals);
    $vals[$#vals].='$' if($atEnd);
    foreach my $value (@values) {
      my $currentMapString=$value;
      my $match=1;
      foreach my $subVal (@vals) {
        if($currentMapString =~ /$subVal(.*)$/) {
          $currentMapString=$1;
        }else{
          $match=0;
          last;
        }
      }
      return $value if($match);
    }
    foreach my $value (@values) {
      my $currentMapString=$value;
      my $match=1;
      foreach my $subVal (@vals) {
        if($currentMapString =~ /$subVal(.*)$/i) {
          $currentMapString=$1;
        }else{
          $match=0;
          last;
        }
      }
      return $value if($match);
    }
  }
  return '';
}

sub searchMap {
  my $val=shift;
  my %maps=%{$spads->{maps}};
  return $maps{$val} if($val =~ /^\d+$/ && exists $maps{$val});
  my @realMaps;
  foreach my $mapNb (sort keys %maps) {
    push(@realMaps,$maps{$mapNb});
  }
  my $realMapFound=advancedMapSearch($val,\@realMaps);
  return $realMapFound if($realMapFound ne '');
  my @ghostMaps;
  my $ghostMapFound;
  if($conf{allowGhostMaps} && $springServerType eq 'dedicated') {
    @ghostMaps=sort keys %{$spads->{ghostMaps}};
    $ghostMapFound=advancedMapSearch($val,\@ghostMaps);
    return $ghostMapFound if($ghostMapFound ne '');
  }
  if($val =~ /^(.+)\.smf$/) {
    $val=$1;
    $realMapFound=advancedMapSearch($val,\@realMaps,1);
    return $realMapFound if($realMapFound ne '' || ! $conf{allowGhostMaps} || $springServerType ne 'dedicated');
    $ghostMapFound=advancedMapSearch($val,\@ghostMaps,1);
    return $ghostMapFound;
  }
  return '';
}

sub cleverSearch {
  my ($string,$p_values)=@_;
  my @values=@{$p_values};
  return [$string] if(any {$string eq $_} @values);
  my @result=grep {index($_,$string) == 0} @values;
  return \@result if(@result);
  @result=grep {index(lc($_),lc($string)) == 0} @values;
  return \@result if(@result);
  @result=grep {index($_,$string) > 0} @values;
  return \@result if(@result);
  @result=grep {index(lc($_),lc($string)) > 0} @values;
  return \@result;
}

sub getUserPref {
  my ($user,$pref)=@_;
  my $p_prefs;
  if(exists $prefCache{$user}) {
    $p_prefs=$prefCache{$user};
  }else{
    my $aId=getLatestUserAccountId($user);
    $p_prefs=$spads->getUserPrefs($aId,$user);
    if($spads->{sharedDataTs}{preferences} && $lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$user}) {
      $prefCache{$user}=$p_prefs;
      $prefCacheTs{$user}=time;
    }
  }
  return $p_prefs->{$pref} if(exists $p_prefs->{$pref} && $p_prefs->{$pref} ne '');
  return $conf{$pref} if(exists $conf{$pref});
  return '';
}

sub getAccountPref {
  my ($aId,$pref)=@_;
  my $p_prefs=$spads->getAccountPrefs($aId);
  return $p_prefs->{$pref} if(exists $p_prefs->{$pref} && $p_prefs->{$pref} ne '');
  return $conf{$pref} if(exists $conf{$pref});
  return '';
}

sub setUserPref {
  my ($user,$pref,$value)=@_;
  my $aId=getLatestUserAccountId($user);
  setAccountUserPref($aId,$user,$pref,$value);
}

sub setAccountUserPref {
  my ($aId,$user,$pref,$value)=@_;
  $spads->setUserPref($aId,$user,$pref,$value);
  $prefCache{$user}{$pref}=$value if(exists $prefCache{$user});
}

sub getDefaultAndMaxAllowedValues {
  my ($preset,$setting)=@_;
  my @allowedValues;
  if($preset ne "") {
    if(! exists $spads->{presets}{$preset}) {
      slog("Unable to find allowed values for setting \"$setting\", preset \"$preset\" does not exist",1);
      return (0,0);
    }
    return ("undefined","undefined") if(! exists $spads->{presets}{$preset}{$setting});
    @allowedValues=@{$spads->{presets}{$preset}{$setting}};
  }else{
    if(! exists $spads->{values}{$setting}) {
      slog("Unable to find allowed values for setting \"$setting\" in current preset ($conf{preset})",1);
      return (0,0);
    }
    @allowedValues=@{$spads->{values}{$setting}};
  }
  my $defaultValue=$allowedValues[0];
  my $maxAllowedValue=$defaultValue;
  foreach my $allowedValue (@allowedValues) {
    if($allowedValue =~ /^\d+\-(\d+)$/) {
      $maxAllowedValue=$1 if($1 > $maxAllowedValue);
    }elsif($allowedValue =~ /^\d+$/) {
      $maxAllowedValue=$allowedValue if($allowedValue > $maxAllowedValue);
    }
  }
  $preset=$conf{preset} if($preset eq "");
  slog("Default and max allowed values for setting \"$setting\" in preset \"$preset\" are: ($defaultValue,$maxAllowedValue)",5);
  return ($defaultValue,$maxAllowedValue);
}

sub getPresetBattleStructure {
  my ($preset,$nbPlayers)=@_;
  if(! exists $spads->{presets}{$preset}) {
    slog("Unable to test \"$preset\" compatibility with current number of players, it does not exist",1);
    return (0,0,0);
  }
  my ($nbTeams,$maxNbTeams)=getDefaultAndMaxAllowedValues($preset,"nbTeams");
  if($nbTeams eq "undefined") {
    $nbTeams=$conf{nbTeams};
    (undef,$maxNbTeams)=getDefaultAndMaxAllowedValues("","nbTeams");
  }
  my ($teamSize,$maxTeamSize)=getDefaultAndMaxAllowedValues($preset,"teamSize");
  if($teamSize eq "undefined") {
    $teamSize=$conf{teamSize};
    (undef,$maxTeamSize)=getDefaultAndMaxAllowedValues("","teamSize");
  }
  my ($nbPlayerById,$maxNbPlayerById)=getDefaultAndMaxAllowedValues($preset,"nbPlayerById");
  if($nbPlayerById eq "undefined") {
    $nbPlayerById=$conf{nbPlayerById};
    (undef,$maxNbPlayerById)=getDefaultAndMaxAllowedValues("","nbPlayerById");
  }
  return (0,0,0) if($nbPlayers > $maxNbTeams*$maxTeamSize*$maxNbPlayerById);
  while($nbPlayers > $nbTeams*$teamSize*$nbPlayerById) {
    $teamSize++ unless($teamSize == $maxTeamSize);
    $nbTeams++ unless($nbTeams == $maxNbTeams);
    $nbPlayerById++ unless($nbPlayerById == $maxNbPlayerById);
  }
  slog("Battle structure for preset \"$preset\" with \"$nbPlayers\" players (current structure: $conf{nbTeams}x$conf{teamSize}x$conf{nbPlayerById}) is: (${nbTeams}x${teamSize}x$nbPlayerById)",5);
  return ($nbTeams,$teamSize,$nbPlayerById);
}

sub getBSettingAllowedValues {
  my ($bSetting,$p_options,$allowExternalValues)=@_;
  my @allowedValues=();
  
  if(exists $spads->{bValues}{$bSetting}) {
    @allowedValues=@{$spads->{bValues}{$bSetting}};
  }elsif($allowExternalValues) {
    my $p_option=$p_options->{$bSetting};
    my $optionType=$p_option->{type};
    if($optionType eq "bool") {
      @allowedValues=(0,1);
    }elsif($optionType eq "list") {
      @allowedValues=keys %{$p_option->{list}};
    }elsif($optionType eq "number") {
      my $rangeString="$p_option->{numberMin}-$p_option->{numberMax}";
      $rangeString.="\%$p_option->{numberStep}" if(getRangeStepFromBoundaries($p_option->{numberMin},$p_option->{numberMax}) != $p_option->{numberStep});
      push(@allowedValues,$rangeString);
    }
  }

  return @allowedValues;
}

sub seenUserIp {
  my ($user,$ip,$bot)=@_;
  if($conf{userDataRetention} !~ /^0;/ && ! $lanMode) {
    my $userIpRetention=-1;
    $userIpRetention=$1 if($conf{userDataRetention} =~ /;(\d+);/);
    if($userIpRetention != 0) {
      if($ip !~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
        slog("Ignoring invalid IP addresss \"$ip\" for user \"$user\"",2);
        return;
      }
      my $id=getLatestUserAccountId($user);
      $spads->learnAccountIp($id,$ip,$userIpRetention,$bot);
    }
  }
}

sub getSmurfsData {
  my ($smurfUser,$p_C)=@_;
  return ([],[]) if($conf{userDataRetention} =~ /^0;/);

  my $smurfId;
  if($smurfUser =~ /^\#([1-9]\d*)$/) {
    $smurfId=$1;
    return ([],[]) unless($spads->isStoredAccount($smurfId));
  }else{
    return ([],[]) unless($spads->isStoredUser($smurfUser));
    $smurfId=$spads->getLatestUserAccountId($smurfUser);
  }

  my %C=%{$p_C};
  my @ranks=("Newbie","$C{3}Beginner","$C{3}Average","$C{10}Above average","$C{12}Experienced","$C{7}Highly experienced","$C{4}Veteran","$C{13}Ghost");

  my $nbResults=0;
  my @smurfsData;
  my @probableSmurfs;

  my ($p_smurfs)=$spads->getSmurfs($smurfId);
  if(@{$p_smurfs}) {
    foreach my $smurf (@{$p_smurfs->[0]}) {
      my $p_smurfMainData=$spads->getAccountMainData($smurf);
      my $p_smurfNames=$spads->getAccountNamesTs($smurf);
      my $p_smurfIps=$spads->getAccountIpsTs($smurf);
      my ($id,$smurfName)=($smurf,undef);
      ($id,$smurfName)=(0,$1) if($smurf =~ /^0\(([^\)]+)\)$/);
      my @idNames=sort {$p_smurfNames->{$b} <=> $p_smurfNames->{$a}} (keys %{$p_smurfNames});
      my $names=formatList(\@idNames,40);
      if($nbResults > 39) {
        push(@probableSmurfs,"$id($names)");
      }else{
        my @idIps=sort {$p_smurfIps->{$b} <=> $p_smurfIps->{$a}} (keys %{$p_smurfIps});
        my $ips=formatList(\@idIps,40);
        my $confidence=90;
        $confidence=100 if($smurf eq $smurfId);
        my $online;
        if($id) {
          $online=exists $lobby->{accounts}{$smurf} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
        }else{
          $online=exists $lobby->{users}{$smurfName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
        }
        push(@smurfsData,{"$C{5}ID$C{1}" => $id,
                          "$C{5}Name(s)$C{1}" => $names,
                          "$C{5}Online$C{1}" => $online,
                          "$C{5}Country$C{1}" => $p_smurfMainData->{country},
                          "$C{5}LobbyClient$C{1}" => $p_smurfMainData->{lobbyClient},
                          "$C{5}Rank$C{1}" => $ranks[abs($p_smurfMainData->{rank})].$C{1},
                          "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_smurfMainData->{timestamp}),
                          "$C{5}Confidence$C{1}" => "$confidence\%",
                          "$C{5}IP(s)$C{1}" => $ips});
        $nbResults++;
      }
    }
    if($#{$p_smurfs} > 0 && @{$p_smurfs->[1]}) {
      foreach my $smurf (@{$p_smurfs->[1]}) {
        my $p_smurfMainData=$spads->getAccountMainData($smurf);
        my $p_smurfNames=$spads->getAccountNamesTs($smurf);
        my $p_smurfIps=$spads->getAccountIpsTs($smurf);
        my ($id,$smurfName)=($smurf,undef);
        ($id,$smurfName)=(0,$1) if($smurf =~ /^0\(([^\)]+)\)$/);
        my @idNames=sort {$p_smurfNames->{$b} <=> $p_smurfNames->{$a}} (keys %{$p_smurfNames});
        my $names=formatList(\@idNames,40);
        if($nbResults > 39) {
          push(@probableSmurfs,"$id($names)");
        }else{
          my @idIps=sort {$p_smurfIps->{$b} <=> $p_smurfIps->{$a}} (keys %{$p_smurfIps});
          my $ips=formatList(\@idIps,40);
          my $online;
          if($id) {
            $online=exists $lobby->{accounts}{$smurf} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
          }else{
            $online=exists $lobby->{users}{$smurfName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
          }
          push(@smurfsData,{"$C{5}ID$C{1}" => $id,
                            "$C{5}Name(s)$C{1}" => $names,
                            "$C{5}Online$C{1}" => $online,
                            "$C{5}Country$C{1}" => $p_smurfMainData->{country},
                            "$C{5}LobbyClient$C{1}" => $p_smurfMainData->{lobbyClient},
                            "$C{5}Rank$C{1}" => $ranks[abs($p_smurfMainData->{rank})].$C{1},
                            "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_smurfMainData->{timestamp}),
                            "$C{5}Confidence$C{1}" => "80\%",
                            "$C{5}IP(s)$C{1}" => $ips});
          $nbResults++;
        }
      }
    }
    if($#{$p_smurfs} > 1) {
      for my $smurfLevel (2..$#{$p_smurfs}) {
        foreach my $smurf (@{$p_smurfs->[$smurfLevel]}) {
          my $p_smurfMainData=$spads->getAccountMainData($smurf);
          my $p_smurfNames=$spads->getAccountNamesTs($smurf);
          my $p_smurfIps=$spads->getAccountIpsTs($smurf);
          my ($id,$smurfName)=($smurf,undef);
          ($id,$smurfName)=(0,$1) if($smurf =~ /^0\(([^\)]+)\)$/);
          my @idNames=sort {$p_smurfNames->{$b} <=> $p_smurfNames->{$a}} (keys %{$p_smurfNames});
          my $names=formatList(\@idNames,40);
          if($nbResults > 39) {
            push(@probableSmurfs,"$id($names)");
          }else{
            my @idIps=sort {$p_smurfIps->{$b} <=> $p_smurfIps->{$a}} (keys %{$p_smurfIps});
            my $ips=formatList(\@idIps,40);
            my $online;
            if($id) {
              $online=exists $lobby->{accounts}{$smurf} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
            }else{
              $online=exists $lobby->{users}{$smurfName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
            }
            push(@smurfsData,{"$C{5}ID$C{1}" => $id,
                              "$C{5}Name(s)$C{1}" => $names,
                              "$C{5}Online$C{1}" => $online,
                              "$C{5}Country$C{1}" => $p_smurfMainData->{country},
                              "$C{5}LobbyClient$C{1}" => $p_smurfMainData->{lobbyClient},
                              "$C{5}Rank$C{1}" => $ranks[abs($p_smurfMainData->{rank})].$C{1},
                              "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_smurfMainData->{timestamp}),
                              "$C{5}Confidence$C{1}" => "60\%",
                              "$C{5}IP(s)$C{1}" => $ips});
            $nbResults++;
          }
        }
      }
    }
  }

  return (\@smurfsData,\@probableSmurfs);
}

sub checkAutoStop {
  return unless(($conf{autoStop} =~ /^noOpponent/ || $conf{autoStop} =~ /^onlySpec/) && $springPid && $autohost->getState() == 2 && $timestamps{autoStop} == 0);
  my %aliveTeams;
  foreach my $player (keys %{$p_runningBattle->{users}}) {
    next unless(defined $p_runningBattle->{users}{$player}{battleStatus} && $p_runningBattle->{users}{$player}{battleStatus}{mode});
    my $playerTeam=$p_runningBattle->{users}{$player}{battleStatus}{team};
    next if(exists $aliveTeams{$playerTeam});
    my $p_ahPlayer=$autohost->getPlayer($player);
    next unless(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1 && $p_ahPlayer->{lost} == 0);
    $aliveTeams{$playerTeam}=1;
  }
  foreach my $bot (keys %{$p_runningBattle->{bots}}) {
    my $botTeam=$p_runningBattle->{bots}{$bot}{battleStatus}{team};
    next if(exists $aliveTeams{$botTeam});
    my $p_ahPlayer=$autohost->getPlayer($p_runningBattle->{bots}{$bot}{owner});
    next unless(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1);
    $aliveTeams{$botTeam}=1;
  }
  my $nbAliveTeams=keys %aliveTeams;
  $timestamps{autoStop}=time + ($conf{autoStop} =~ /\((\d+)\)$/ ? $1 : 5) if(($conf{autoStop} =~ /^noOpponent/ && $nbAliveTeams < 2) || ($conf{autoStop} =~ /^onlySpec/ && $nbAliveTeams == 0));
}


sub getPresetLocalBots {
  my @localBotsStrings=split(/;/,$conf{localBots});
  my @localBotsNames;
  my %localBots;
  foreach my $localBotString (@localBotsStrings) {
    if($localBotString=~/^([\w\[\]]{2,20}) (\w+(?:#[\da-fA-F]{6})?) ([^ \;][^\;]*)$/) {
      my ($lBotName,$lBotSide,$lBotAi,$p_lBotColor)=($1,$2,$3,{red => 255, green => 0, blue => 0});
      if($lBotSide =~ /^(\w+)#([\da-fA-F]{2})([\da-fA-F]{2})([\da-fA-F]{2})$/) {
        ($lBotSide,$p_lBotColor)=($1,{red => hex $2, green => hex $3, blue => hex $4});
      }
      push(@localBotsNames,$lBotName);
      $localBots{$lBotName}={side => $lBotSide,
                             ai => $lBotAi,
                             color => $p_lBotColor};
    }else{
      slog("Unable to read local bot entry in \"localBots\" preset setting: \"$localBotString\"",2);
    }
  }
  return (\@localBotsNames,\%localBots);
}

sub getNextLocalBot {
  my ($p_localBotsNames,$p_localBots)=@_;
  ($p_localBotsNames,$p_localBots)=getPresetLocalBots() if(! defined $p_localBotsNames);
  my %nextLocalBot;
  return {} unless(@{$p_localBotsNames});
  for my $i ('',2..99) {
    for my $lBotName (@{$p_localBotsNames}) {
      if(length($lBotName.$i) < 21 && ! exists $lobby->{battle}{bots}{$lBotName.$i}
         && ! exists $pendingLocalBotManual{$lBotName.$i} && ! exists $pendingLocalBotAuto{$lBotName.$i}) {
        %nextLocalBot=(name => $lBotName.$i,
                       side => $p_localBots->{$lBotName}{side},
                       ai => $p_localBots->{$lBotName}{ai},
                       color => $p_localBots->{$lBotName}{color});
        last;
      }
    }
    last if(%nextLocalBot);
  }
  return \%nextLocalBot;
}

sub translateSideIfNeeded {
  my $side=shift;
  if($side !~ /^\d+$/) {
    my $p_modSides=getModSides($lobby->{battles}{$lobby->{battle}{battleId}}{mod});
    for my $i (0..$#{$p_modSides}) {
      if(index(lc($p_modSides->[$i]),lc($side)) == 0) {
        $side=$i;
        last;
      }
    }
    if($side !~ /^\d+$/) {
      return undef;
    }
  }
  return $side;
}

sub getGameDataFromLog {
  my $logFile="$conf{instanceDir}/infolog.txt";
  my ($demoFile,$gameId);
  if(open(SPRINGLOG,'<:encoding(utf-8)',$logFile)) {
    while(local $_ = <SPRINGLOG>) {
      $demoFile=$1 if(/recording demo: (.+)$/);
      $gameId=$1 if(/GameID: ([0-9a-f]+)$/);
      last if(defined $demoFile && defined $gameId);
    }
    close(SPRINGLOG);
    if(!defined $demoFile) {
      slog("Unable to find demo name in log file \"$logFile\"",2);
    }
    if(!defined $gameId) {
      slog("Unable to find game ID in log file \"$logFile\"",2);
    }
  }else{
    slog("Unable to read log file \"$logFile\"",2);
  }
  return ($demoFile,$gameId);
}

sub queueGDR {
  if($gdrEnabled) {
    if(! %gdr) {
      slog("Unable to send game data report (no GDR data available)",2);
    }elsif($gdr{duration} < 180) {
      slog("Game data report cancelled, game too short",4);
    }else{
      $gdr{endTs}=time;
      my $gameId;
      $gameId=$autohost->{gameId} if(exists $autohost->{gameId} && $autohost->{gameId});
      if(! defined $gameId) {
        slog("Game ID missing in STARTPLAYING message, using fallback method (log parsing)",2);
        (undef,$gameId)=getGameDataFromLog();
      }
      $gameId=generateGameId() unless(defined $gameId);
      $gdr{gameId}=$gameId;
      my $sGdr=encode_base64(nfreeze(\%gdr),'');
      push(@gdrQueue,$sGdr);
    }
  }
  %gdr=();
  return if($lobbyState < LOBBY_STATE_SYNCHRONIZED || ! exists $lobby->{users}{$gdrLobbyBot});
  while(@gdrQueue) {
    my $serializedGdr=shift(@gdrQueue);
    my $timestamp=time;
    sayPrivate($gdrLobbyBot,"!#startGDR $timestamp");
    sayPrivate($gdrLobbyBot,$serializedGdr);
    sayPrivate($gdrLobbyBot,"!#endGDR");
  }
}

sub uriEscape {
  my $uri=shift;
  $uri =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/eg;
  return $uri;
}

sub endGameProcessing {

  if(! %endGameData) {
    slog('Unable to perform end game processing, no end game data available',2);
    return;
  }

  $endGameData{endTimestamp}=time;
  $endGameData{duration}=time - $endGameData{startTimestamp};
  
  my ($demoFile,$gameId);
  $demoFile=$autohost->{demoName} if(exists $autohost->{demoName} && $autohost->{demoName});
  $gameId=$autohost->{gameId} if(exists $autohost->{gameId} && $autohost->{gameId});

  if(! defined $demoFile) {
    if(! defined $gameId) {
      slog("Demo file name and game ID missing in STARTPLAYING message, using fallback method (log parsing)",2);
      ($demoFile,$gameId)=getGameDataFromLog();
    }else{
      slog("Demo file name missing in STARTPLAYING message, using fallback method (log parsing)",2);
      ($demoFile,undef)=getGameDataFromLog();
    }
  }elsif(! defined $gameId) {
    slog("Game ID missing in STARTPLAYING message, using fallback method (log parsing)",2);
    (undef,$gameId)=getGameDataFromLog();
  }

  if(defined $demoFile) {
    $demoFile=catfile($conf{instanceDir},$demoFile) unless(file_name_is_absolute($demoFile));
  }else{
    $demoFile='UNKNOWN';
  }
  $gameId//='UNKNOWN';

  $endGameData{demoFile}=$demoFile;
  $endGameData{gameId}=$gameId;

  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onGameEnd(\%endGameData) if($plugins{$pluginName}->can('onGameEnd'));
  }
  
  return if($conf{endGameCommand} eq '');
  my $endGameCommand=$conf{endGameCommand};

  foreach my $placeHolder (keys %endGameData) {
    $endGameCommand=~s/\%$placeHolder/$endGameData{$placeHolder}/g;
  }

  if($nbEndGameCommandRunning) {
    my $warningEndMessage='previous end game command is still running';
    $warningEndMessage="$nbEndGameCommandRunning previous end game commands are still running" if($nbEndGameCommandRunning > 1);
    slog("Launching new end game command but the $warningEndMessage",2);
  }
  
  my %endGameCommandData=(startTime => time,
                          engineVersion => $endGameData{engineVersion},
                          mod => $endGameData{mod},
                          map => $endGameData{map},
                          type => $endGameData{type},
                          ahAccountId => $endGameData{ahAccountId},
                          demoFile => $endGameData{demoFile},
                          gameId => $endGameData{gameId},
                          result => $endGameData{result});
  if(my $childPid = SimpleEvent::forkProcess(
       sub {
         if($conf{endGameCommandEnv} ne '') {
           my @envVarDeclarations=split(/;/,$conf{endGameCommandEnv});
           foreach my $envVarDeclaration (@envVarDeclarations) {
             if($envVarDeclaration =~ /^(\w+)=(.*)$/) {
               my ($envVar,$envValue)=($1,$2);
               foreach my $placeHolder (keys %endGameData) {
                 $envValue=~s/\%$placeHolder/$endGameData{$placeHolder}/g;
               }
               $ENV{$envVar}=$envValue;
             }else{
               slog("Ignoring invalid environment variable declaration \"$envVarDeclaration\" in \"endGameCommandEnv\" setting",2)
             }
           }
         }
         slog("End game command: \"$endGameCommand\"",5);
         exec($endGameCommand)
             or execError("Unable to launch endGameCommand ($!)",2);
       },
       sub {
         my ($endGameCommandPid,$exitCode,$signalNb,$hasCoreDump)=@_;
         $nbEndGameCommandRunning--;
         my $executionTime=secToTime(time-$endGameCommandData{startTime});
         if($conf{endGameCommandMsg} ne '' && $lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}}) {
           my @endGameMsgs=@{$spads->{values}{endGameCommandMsg}};
           foreach my $endGameMsg (@endGameMsgs) {
             if($endGameMsg =~ /^\((\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)\)(.+)$/) {
               $endGameMsg=$2;
               my @filters=split(/,/,$1);
               my $match=0;
               foreach my $filter (@filters) {
                 if($filter =~ /^\d+$/ && $exitCode == $filter) {
                   $match=1;
                   last;
                 }
                 if($filter =~ /^(\d+)-(\d+)$/ && $exitCode >= $1 && $exitCode <= $2) {
                   $match=1;
                   last;
                 }
               }
               next unless($match);
             }

             my $escapedMod=uriEscape($endGameCommandData{mod});
             my $escapedMap=uriEscape($endGameCommandData{map});
             my $escapedDemoName=$endGameCommandData{demoFile};
             $escapedDemoName=$1 if($escapedDemoName =~ /[\/\\]([^\/\\]+)$/);
             $escapedDemoName=uriEscape($escapedDemoName);

             $endGameMsg=~s/\%engineVersion/$endGameCommandData{engineVersion}/g;
             $endGameMsg=~s/\%mod/$escapedMod/g;
             $endGameMsg=~s/\%map/$escapedMap/g;
             $endGameMsg=~s/\%type/$endGameCommandData{type}/g;
             $endGameMsg=~s/\%ahName/$conf{lobbyLogin}/g;
             $endGameMsg=~s/\%ahAccountId/$endGameCommandData{ahAccountId}/g;
             $endGameMsg=~s/\%demoName/$escapedDemoName/g;
             $endGameMsg=~s/\%gameId/$endGameCommandData{gameId}/g;
             $endGameMsg=~s/\%result/$endGameCommandData{result}/g;

             sayBattle($endGameMsg);
           }
         }
         slog("End game command finished (pid: $endGameCommandPid, execution time: $executionTime, return code: $exitCode)",4);
         slog("End game commmand exited with non-null return code ($exitCode)",2) if($exitCode);
       })) {
    $nbEndGameCommandRunning++;
    if($childPid == -1) {
      slog("End game command queued...",3);
    }else{
      slog("Executing end game command (pid $childPid)",4);
    }
  }else{
    slog("Unable to fork to launch endGameCommand",2);
  }
}

sub getCmdVoteSettings {
  my $cmd=shift;
  my $r_cmdAttribs=$spads->getCommandAttributes($cmd);
  my %voteSettings;
  foreach my $setting (qw'voteTime minVoteParticipation majorityVoteMargin awayVoteDelay') {
    $voteSettings{$setting}=$r_cmdAttribs->{$setting}//$conf{$setting};
  }
  return \%voteSettings;
}

# SPADS commands handlers #####################################################

sub hAddBot {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to add AI bot, battle lobby is closed");
    return 0;
  }
  if($springServerType ne 'headless') {
    answer("Unable to add bot: local AI bots require headless server (current server type is \"$springServerType\")");
    return 0;
  }

  my @bots=keys %{$lobby->{battle}{bots}};
  my $nbLocalBots=0;
  foreach my $existingBot (@bots) {
    $nbLocalBots++ if($lobby->{battle}{bots}{$existingBot}{owner} eq $conf{lobbyLogin});
  }
  if($conf{maxBots} ne '' && $#bots+1 >= $conf{maxBots}) {
    answer("Unable to add bot [maxBots=$conf{maxBots}]");
    return 0;
  }
  if($conf{maxLocalBots} ne '' && $nbLocalBots >= $conf{maxLocalBots}) {
    answer("Unable to add bot [maxLocalBots=$conf{maxLocalBots}]");
    return 0;
  }

  my ($botName,$botSide,$botAi)=@{$p_params};
  my $p_botColor;

  my ($p_localBotsNames,$p_localBots)=getPresetLocalBots();
  if(! defined $botName || ! defined $botSide || ! defined $botAi) {
    if(! @{$p_localBotsNames}) {
      answer("Unable to add bot: incomplete !addBot command and no local bot defined in \"localBots\" preset setting");
      return 0;
    }
    if(! defined $botName) {
      my $p_nextLocalBot=getNextLocalBot($p_localBotsNames,$p_localBots);
      if(! %{$p_nextLocalBot}) {
        answer("Unable to find an unused local bot in \"localBots\" preset setting, please provide a bot name in !addBot command");
        return 0;
      }
      $botName=$p_nextLocalBot->{name};
      $botSide=$p_nextLocalBot->{side};
      $botAi=$p_nextLocalBot->{ai};
      $p_botColor=$p_nextLocalBot->{color};
    }
    if(! defined $botSide) {
      if(exists $p_localBots->{$botName}) {
        $botSide=$p_localBots->{$botName}{side};
      }else{
        answer("Unable to add bot: bot side is missing and bot name is unknown in \"localBots\" preset setting");
        return 0;
      }
    }
    if(! defined $botAi) {
      if(exists $p_localBots->{$botName}) {
        $botAi=$p_localBots->{$botName}{ai};
      }else{
        answer("Unable to add bot: bot AI is missing and bot name is unknown in \"localBots\" preset setting");
        return 0;
      }
    }
  }
  if(! defined $p_botColor) {
    if(exists $p_localBots->{$botName}) {
      $p_botColor=$p_localBots->{$botName}{color};
    }else{
      $p_botColor={red => 255, green => 0, blue => 0};
    }
  }

  if($botName !~ /^[\w\[\]]{2,20}$/) {
    answer("Unable to add bot: invalid bot name \"$botName\"");
    return 0;
  }
  if(exists $lobby->{battle}{bots}{$botName} || exists $pendingLocalBotManual{$botName} || exists $pendingLocalBotAuto{$botName}) {
    answer("Unable to add bot: $botName has already been added");
    return 0;
  }
  my $realBotSide=translateSideIfNeeded($botSide);
  if(! defined $realBotSide) {
    answer("Unable to add bot: invalid bot side \"$botSide\" for current MOD");
    return 0;
  }else{
    $botSide=$realBotSide;
  }
  if($botAi !~ /^[^ \;][^\;]*$/) {
    answer("Unable to add bot: invalid bot AI \"$botAi\"");
    return 0;
  }

  my @allowedLocalAIs=split(/;/,$conf{allowedLocalAIs});
  if(none {$botAi eq $_} @allowedLocalAIs) {
    answer("Unable to add bot: AI \"$botAi\" unauthorized [allowedLocalAIs=$conf{allowedLocalAIs}]");
    return 0;
  }

  return 1 if($checkOnly);

  sayBattle("Adding local AI bot $botName (by $user)");
  $pendingLocalBotManual{$botName}=time;
  queueLobbyCommand(['ADDBOT',$botName,$lobby->marshallBattleStatus({side => $botSide, sync => 0, bonus => 0, mode => 1, team => 0, id => 0, ready => 1}),$lobby->marshallColor($p_botColor),$botAi]);
  return 1;
}

sub hAddBox {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to add start box, battle lobby is closed");
    return 0;
  }
  if($#{$p_params} < 3 || $#{$p_params} > 4) {
    invalidSyntax($user,"addbox");
    return 0;
  }
  if($spads->{bSettings}{startpostype} != 2) {
    answer("Unable to add start box, start position type must be set to \"Choose in game\" (\"!bSet startPosType 2\")");
    return 0;
  }
  for my $i (0..3) {
    if($p_params->[$i] !~ /^\d+$/ || $p_params->[$i] > 200) {
      invalidSyntax($user,"addbox","invalid coordinates");
      return 0;
    }
  }

  my ($left,$top,$right,$bottom,$teamNb)=@{$p_params};

  if($left > $right || $top > $bottom) {
    invalidSyntax($user,"addbox","inconsistent coordinates");
    return 0;
  }

  if(defined $teamNb) {
    if($teamNb !~ /^\d+$/ || $teamNb < 1 || $teamNb > 251) {
      invalidSyntax($user,"addbox","invalid team number");
      return 0;
    }
    $teamNb-=1;
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]) if(exists $lobby->{battle}{startRects}{$teamNb});
  }else{
    for my $i (0..250) {
      if(! exists $lobby->{battle}{startRects}{$i}) {
        $teamNb=$i;
        last;
      }
    }
  }
  if(! defined $teamNb) {
    answer("Unable to add start box, all start boxes are already created");
    return 0;
  }

  return 1 if($checkOnly);

  queueLobbyCommand(["ADDSTARTRECT",$teamNb,$left,$top,$right,$bottom]);
  return 1;

}

sub hAdvert {
  my ($source,$user,$p_params,$checkOnly)=@_;
  return 1 if($checkOnly);
  my @newAdvertMsgs=split(/\|/,$p_params->[0]//'');
  $spads->{values}{advertMsg}=\@newAdvertMsgs;
  $conf{advertMsg}=$newAdvertMsgs[0];
  answer("Advert message updated.");
  return 1;
}

sub hAuth {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} > 0) {
    invalidSyntax($user,"auth");
    return 0;
  }
  my $oldLevel=getUserAccessLevel($user);
  if($#{$p_params} < 0) {
    if(! exists $authenticatedUsers{$user}) {
      sayPrivate($user,"Cannot un-authenticate you, you are not authenticated");
      return 0;
    }
    return 1 if($checkOnly);
    delete $authenticatedUsers{$user};
  }else{
    my $cryptedPasswd=md5_base64($p_params->[0]);
    if(exists $authenticatedUsers{$user} && $authenticatedUsers{$user} eq $cryptedPasswd) {
      sayPrivate($user,"You are already authenticated with this password");
      return 0;
    }
    return 1 if($checkOnly);
    $authenticatedUsers{$user}=$cryptedPasswd;
  }
  my $oldLevelDescription=$spads->getLevelDescription($oldLevel);
  my $level=getUserAccessLevel($user);
  my $levelDescription=$spads->getLevelDescription($level);
  if(isUserAuthenticated($user) == 2) {
    sayPrivate($user,"Authentication successful");
  }else{
    if(exists $authenticatedUsers{$user}) {
      sayPrivate($user,"Authentication failed");
    }else{
      sayPrivate($user,"Un-authentication successful");
    }
  }
  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  if($oldLevelDescription ne $levelDescription) {
    sayPrivate($user,"Switching from \"$C{4}$oldLevelDescription$C{1}\" to \"$C{3}$levelDescription$C{1}\" access level");
    if($level >= $conf{alertLevel} && %pendingAlerts) {
      alertUser($user) if(! exists $alertedUsers{$user} || time-$alertedUsers{$user} > $conf{alertDelay}*3600);
    }
  }else{
    sayPrivate($user,"Keeping following access level: $C{12}$levelDescription");
  }
  return 1;
}

sub hBalance {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to balance teams, battle lobby is closed");
    return 0;
  }

  if($#{$p_params} != -1) {
    invalidSyntax($user,"balance");
    return 0;
  }

  return 1 if($checkOnly);
  my ($nbSmurfs,$unbalanceIndicator)=balance();
  if(! defined $nbSmurfs) {
    answer("Balance data not ready yet, try again later");
    return 0;
  }
  my $balanceMsg="Balancing according to current balance mode: $conf{balanceMode}";
  my @extraStrings;
  if($balanceState) {
    push(@extraStrings,"teams were already balanced");
  }elsif($conf{autoFixColors} ne 'off' && time - $timestamps{fixColors} > 4) {
    fixColors(1);
  }
  push(@extraStrings,"$nbSmurfs smurf".($nbSmurfs>1 ? 's' : '')." found") if($nbSmurfs);
  push(@extraStrings,"balance deviation: $unbalanceIndicator\%") if($conf{balanceMode} =~ /skill$/);
  my $extraString=join(", ",@extraStrings);
  $balanceMsg.=" ($extraString)" if($extraString);
  answer($balanceMsg);
  return 1;
}

sub hBan {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my ($bannedUser,$banType,$duration,$reason)=@{$p_params};
  
  if(! defined $bannedUser) {
    invalidSyntax($user,"ban");
    return 0;
  }
  my $banMode='user';
  my $id;
  my @banFilters=split(/;/,$bannedUser);
  my $p_user={};
  my @banListsFields=qw'accountId name country rank access bot level ip skill skillUncert';
  foreach my $banFilter (@banFilters) {
    my ($filterName,$filterValue)=("name",$banFilter);
    if($banFilter =~ /^\#([1-9]\d*)$/) {
      $id=$1;
      ($filterName,$filterValue)=('accountId',$id);
      $banMode='account';
    }elsif($banFilter =~ /^([^=<>]+)=(.+)$/) {
      ($filterName,$filterValue)=($1,$2);
      $banMode='filter';
    }elsif($banFilter =~ /^([^=<>]+)([<>]=?.+)$/) {
      ($filterName,$filterValue)=($1,$2);
      $banMode='filter';
    }else{
      my $accountId=getLatestUserAccountId($banFilter);
      ($filterName,$filterValue)=("accountId","$accountId($banFilter)") if($accountId =~ /^\d+$/);
    }
    if(any {$filterName eq $_} @banListsFields) {
      if($filterValue =~ /^~(.+)$/) {
        my $invalidRegexp=isInvalidRegexp($1);
        if($invalidRegexp) {
          if($invalidRegexp =~ /^(.*) at /) {
            $invalidRegexp=$1;
          }
          answer("Invalid regular expression \"$filterValue\" ($invalidRegexp)");
          return 0;
        }
      }
      $p_user->{$filterName}=$filterValue;
    }else{
      invalidSyntax($user,"ban","invalid ban filter name \"$filterName\"");
      return 0;
    }
  }

  my $p_ban={banType => 0,
             startDate => time};

  if(defined $banType) {
    my $lcBanType=lc($banType);
    my %allowedBanTypes = (full => 0, battle => 1, spectator => 2);
    foreach my $allowedBanType (keys %allowedBanTypes) {
      if(index($allowedBanType,$lcBanType) == 0) {
        $banType=$allowedBanTypes{$allowedBanType};
        last;
      }
    }
    if($banType =~ /^[012]$/) {
      $p_ban->{banType}=$banType;
    }else{
      invalidSyntax($user,'ban',"invalid ban type \"$banType\"");
      return 0;
    }
    if(defined $duration) {
      if($duration =~ /^([1-9]\d*)g$/) {
        $p_ban->{remainingGames}=$1;
      }else{
        $duration=convertBanDuration($duration);
        if($duration =~ /^\d+$/) {
          $p_ban->{endDate}=time+($duration * 60) if($duration != 0);
        }else{
          invalidSyntax($user,"ban","invalid ban duration");
          return 0;
        }
      }
      if(defined $reason) {
        $p_ban->{reason}=$reason;
        if($p_ban->{reason} =~ /[\:\|]/) {
          answer("Invalid reason (reason cannot contain ':' or '|' characters)");
          return 0;
        }
      }
    }
  }

  return 1 if($checkOnly);
  my $banRes=$spads->banUser($p_user,$p_ban);

  my $banMsg="Full ";
  $banMsg="Battle " if($p_ban->{banType} == 1);
  $banMsg="Force-spec " if($p_ban->{banType} == 2);
  $banMsg.='ban '.{0 => 'creation failed', 1 => 'added', 2 => 'unchanged'}->{$banRes}." for $banMode \"$bannedUser\" (";
  if(exists $p_ban->{remainingGames}) {
    $banMsg.="duration: $p_ban->{remainingGames} game".($p_ban->{remainingGames} > 1 ? 's' : '').')';
  }elsif(defined $duration && $duration) {
    $duration=secToTime($duration * 60);
    $banMsg.="duration: $duration)";
  }else{
    $banMsg.="perm-ban)";
  }
  answer($banMsg);
  
  if($banMode eq 'account' && exists $lobby->{accounts}{$id}) {
    $banMode='user';
    $bannedUser=$lobby->{accounts}{$id};
  }
  if($banMode eq 'user' && $lobbyState >= LOBBY_STATE_BATTLE_OPENED && exists $lobby->{battle}{users}{$bannedUser}) {
    if($p_ban->{banType} < 2) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }else{
      if(defined $lobby->{battle}{users}{$bannedUser}{battleStatus} && $lobby->{battle}{users}{$bannedUser}{battleStatus}{mode}) {
        my $forceMsg="Forcing spectator mode for $bannedUser [auto-spec mode]";
        $forceMsg.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne "");
        queueLobbyCommand(["FORCESPECTATORMODE",$bannedUser]);
        sayBattle($forceMsg);
      }
    }
  }

  return $banRes == 1 ? 1 : 0;
}

sub hBanIp {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my ($bannedUser,$banType,$duration,$reason)=@{$p_params};
  
  if(! defined $bannedUser) {
    invalidSyntax($user,"banip");
    return 0;
  }

  my $p_ban={banType => 0,
             startDate => time};
  if(defined $banType) {
    my $lcBanType=lc($banType);
    my %allowedBanTypes = (full => 0, battle => 1, spectator => 2);
    foreach my $allowedBanType (keys %allowedBanTypes) {
      if(index($allowedBanType,$lcBanType) == 0) {
        $banType=$allowedBanTypes{$allowedBanType};
        last;
      }
    }
    if($banType =~ /^[012]$/) {
      $p_ban->{banType}=$banType;
    }else{
      invalidSyntax($user,"banip","invalid ban type");
      return 0;
    }
    if(defined $duration) {
      if($duration =~ /^([1-9]\d*)g$/) {
        $p_ban->{remainingGames}=$1;
      }else{
        $duration=convertBanDuration($duration);
        if($duration =~ /^\d+$/) {
          $p_ban->{endDate}=time+($duration * 60) if($duration != 0);
        }else{
          invalidSyntax($user,"banip","invalid ban duration");
          return 0;
        }
      }
      if(defined $reason) {
        $p_ban->{reason}=$reason;
        if($p_ban->{reason} =~ /[\:\|]/) {
          answer("Invalid reason (reason cannot contain ':' or '|' characters)");
          return 0;
        }
      }
    }
  }

  my $userIp;
  my $banMode='user';
  my $id;
  if($bannedUser =~ /^\#([1-9]\d*)$/) {
    $id=$1;
    $banMode='account';
    $userIp=$spads->getLatestAccountIp($id);
    if(! $userIp) {
      if($conf{userDataRetention} !~ /^0;/ && ! $spads->isStoredAccount($id)) {
        answer("Unable to ban account $bannedUser by IP (unknown account ID, try !searchUser first)");
      }else{
        answer("Unable to ban account $bannedUser by IP (IP unknown)");
      }
      return 0;
    }
  }else{
    $userIp=getLatestUserIp($bannedUser);
    if(! $userIp) {
      if($conf{userDataRetention} !~ /^0;/ && ! $spads->isStoredUser($bannedUser)) {
        answer("Unable to ban user \"$bannedUser\" by IP (unknown user, try !searchUser first)");
      }else{
        answer("Unable to ban user \"$bannedUser\" by IP (IP unknown)");
      }
      return 0;
    }
  }

  return 1 if($checkOnly);
  my $banRes=$spads->banUser({ip => $userIp},$p_ban);

  my $banMsg="Battle IP-";
  $banMsg="Force-spec IP-" if($p_ban->{banType} == 2);
  $banMsg.='ban '.{0 => 'creation failed', 1 => 'added', 2 => 'unchanged'}->{$banRes}." for $banMode $bannedUser (";
  if(exists $p_ban->{remainingGames}) {
    $banMsg.="duration: $p_ban->{remainingGames} game".($p_ban->{remainingGames} > 1 ? 's' : '').')';
  }elsif(defined $duration && $duration) {
    $duration=secToTime($duration * 60);
    $banMsg.="duration: $duration)";
  }else{
    $banMsg.="perm-ban)";
  }
  answer($banMsg);
  
  if($banMode eq 'account' && exists $lobby->{accounts}{$id}) {
    $banMode='user';
    $bannedUser=$lobby->{accounts}{$id};
  }
  if($banMode eq 'user' && $lobbyState >= LOBBY_STATE_BATTLE_OPENED && exists $lobby->{battle}{users}{$bannedUser}) {
    if($p_ban->{banType} < 2) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }else{
      if(defined $lobby->{battle}{users}{$bannedUser}{battleStatus} && $lobby->{battle}{users}{$bannedUser}{battleStatus}{mode}) {
        my $forceMsg="Forcing spectator mode for $bannedUser [auto-spec mode]";
        $forceMsg.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne "");
        queueLobbyCommand(["FORCESPECTATORMODE",$bannedUser]);
        sayBattle($forceMsg);
      }
    }
  }

  return $banRes == 1 ? 1 : 0;
}

sub hBanIps {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my ($bannedUser,$banType,$duration,$reason)=@{$p_params};
  
  if(! defined $bannedUser) {
    invalidSyntax($user,"banips");
    return 0;
  }

  my $p_ban={banType => 0,
             startDate => time};
  if(defined $banType) {
    my $lcBanType=lc($banType);
    my %allowedBanTypes = (full => 0, battle => 1, spectator => 2);
    foreach my $allowedBanType (keys %allowedBanTypes) {
      if(index($allowedBanType,$lcBanType) == 0) {
        $banType=$allowedBanTypes{$allowedBanType};
        last;
      }
    }
    if($banType =~ /^[012]$/) {
      $p_ban->{banType}=$banType;
    }else{
      invalidSyntax($user,"banips","invalid ban type");
      return 0;
    }
    if(defined $duration) {
      if($duration =~ /^([1-9]\d*)g$/) {
        $p_ban->{remainingGames}=$1;
      }else{
        $duration=convertBanDuration($duration);
        if($duration =~ /^\d+$/) {
          $p_ban->{endDate}=time+($duration * 60) if($duration != 0);
        }else{
          invalidSyntax($user,"banips","invalid ban duration");
          return 0;
        }
      }
      if(defined $reason) {
        $p_ban->{reason}=$reason;
        if($p_ban->{reason} =~ /[\:\|]/) {
          answer("Invalid reason (reason cannot contain ':' or '|' characters)");
          return 0;
        }
      }
    }
  }

  if($conf{userDataRetention} =~ /^0;/) {
    answer("Unable to ban by IPs (user data retention is disabled on this AutoHost)");
    return 0;
  }

  my $p_userIps;
  my $banMode='user';
  my $id;
  if($bannedUser =~ /^\#([1-9]\d*)$/) {
    $id=$1;
    $banMode='account';
    if(! $spads->isStoredAccount($id)) {
      answer("Unable to ban account $bannedUser by IP (unknown account ID, try !searchUser first)");
      return 0;
    }
    $p_userIps=$spads->getAccountIps($id);
    if(! @{$p_userIps}) {
      answer("Unable to ban account $bannedUser by IP (IP unknown)");
      return 0;
    }
  }else{
    if(! $spads->isStoredUser($bannedUser)) {
      answer("Unable to ban user \"$bannedUser\" by IP (unknown user, try !searchUser first)");
      return 0;
    }
    $p_userIps=getUserIps($bannedUser);
    if(! @{$p_userIps}) {
      answer("Unable to ban user \"$bannedUser\" by IP (IP unknown)");
      return 0;
    }
  }

  return 1 if($checkOnly);
  my $banRes=$spads->banUser({ip => join(",",@{$p_userIps})},$p_ban);

  my $banMsg="Battle IP-";
  $banMsg="Force-spec IP-" if($p_ban->{banType} == 2);
  $banMsg.='ban '.{0 => 'creation failed', 1 => 'added', 2 => 'unchanged'}->{$banRes}." for $banMode $bannedUser (";
  $banMsg.=($#{$p_userIps}+1)." IPs, " if($#{$p_userIps} > 0);
  if(exists $p_ban->{remainingGames}) {
    $banMsg.="duration: $p_ban->{remainingGames} game".($p_ban->{remainingGames} > 1 ? 's' : '').')';
  }elsif(defined $duration && $duration) {
    $duration=secToTime($duration * 60);
    $banMsg.="duration: $duration)";
  }else{
    $banMsg.="perm-ban)";
  }
  answer($banMsg);
  
  if($banMode eq 'account' && exists $lobby->{accounts}{$id}) {
    $banMode='user';
    $bannedUser=$lobby->{accounts}{$id};
  }
  if($banMode eq 'user' && $lobbyState >= LOBBY_STATE_BATTLE_OPENED && exists $lobby->{battle}{users}{$bannedUser}) {
    if($p_ban->{banType} < 2) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }else{
      if(defined $lobby->{battle}{users}{$bannedUser}{battleStatus} && $lobby->{battle}{users}{$bannedUser}{battleStatus}{mode}) {
        my $forceMsg="Forcing spectator mode for $bannedUser [auto-spec mode]";
        $forceMsg.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne "");
        queueLobbyCommand(["FORCESPECTATORMODE",$bannedUser]);
        sayBattle($forceMsg);
      }
    }
  }
  return $banRes == 1 ? 1 : 0;
}

sub hBKick {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"bkick");
    return 0;
  }
  
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer("Unable to kick from battle lobby, battle lobby is closed");
    return 0;
  }

  my @players=keys(%{$lobby->{battle}{users}});
  my $p_kickedUsers=cleverSearch($p_params->[0],\@players);
  if(! @{$p_kickedUsers}) {
    answer("Unable to find matching player for \"$p_params->[0]\" in battle lobby");
    return 0;
  }
  if($#{$p_kickedUsers} > 0) {
    answer("Ambiguous command, multiple matches found for player \"$p_params->[0]\" in battle lobby");
    return 0;
  }

  my $kickedUser=$p_kickedUsers->[0];
  if($kickedUser eq $conf{lobbyLogin}) {
    answer("Nice try ;)");
    return 0;
  }

  return ['bKick',$kickedUser] if($checkOnly);
 
  queueLobbyCommand(["KICKFROMBATTLE",$kickedUser]);
  return ['bKick',$kickedUser];
}

sub hBoss {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 0) {
    invalidSyntax($user,"boss");
    return 0;
  }
  
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer("Unable to modify boss mode, battle lobby is closed");
    return 0;
  }

  if($#{$p_params} == -1) {
    if(%bosses) {
      return 1 if($checkOnly);
      %bosses=();
      broadcastMsg("Boss mode disabled by $user");
      return 1;
    }else{
      answer("Boss mode is already disabled");
      return 0;
    }
  }

  my @players=keys(%{$lobby->{battle}{users}});
  my $p_bossUsers=cleverSearch($p_params->[0],\@players);
  if(! @{$p_bossUsers}) {
    answer("Unable to find matching player for \"$p_params->[0]\" in battle lobby");
    return 0;
  }
  if($#{$p_bossUsers} > 0) {
    answer("Ambiguous command, multiple matches found for player \"$p_params->[0]\" in battle lobby");
    return 0;
  }
  my $bossUser=$p_bossUsers->[0];
  if(exists $bosses{$bossUser}) {
    answer("Boss mode already enabled for $bossUser");
    return 0;
  }

  return ['boss',$bossUser] if($checkOnly);

  if(%bosses) {
    $bosses{$bossUser}=1;
  }else{
    %bosses=($bossUser => 1);
  }
  my $bossMsg="Boss mode enabled for $bossUser";
  $bossMsg.=" (by $user)" if($user ne $bossUser);
  broadcastMsg($bossMsg);
  return ['boss',$bossUser];
}

sub hBPreset {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"bpreset");
    return 0;
  }

  my ($bPreset)=@{$p_params};

  if(! exists $spads->{bPresets}{$bPreset}) {
    answer("\"$bPreset\" is not a valid battle preset (use \"!list bPresets\" to list available battle presets)");
    return 0;
  }

  if(none {$bPreset eq $_} @{$spads->{values}{battlePreset}}) {
    answer("Switching to battle preset \"$bPreset\" is not allowed from current global preset");
    return 0;
  }

  return 1 if($checkOnly);

  $timestamps{autoRestore}=time;
  $spads->applyBPreset($bPreset);
  %conf=%{$spads->{conf}};
  sendBattleSettings() if($lobbyState >= LOBBY_STATE_BATTLE_OPENED);
  sayBattleAndGame("Battle preset \"$bPreset\" ($spads->{bSettings}{description}) applied by $user");
  return 1;
}

sub hBSet {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 0) {
    invalidSyntax($user,"bset");
    return 0;
  }

  my ($bSetting,$val)=@{$p_params};
  $val//='';
  $bSetting=lc($bSetting);

  my $modName = $lobbyState >= LOBBY_STATE_BATTLE_OPENED ? $lobby->{battles}{$lobby->{battle}{battleId}}{mod} : $targetMod;
  my $p_modOptions=getModOptions($modName);
  my $p_mapOptions=getMapOptions($currentMap);

  if($bSetting ne "startpostype" && ! exists $p_modOptions->{$bSetting} && ! exists $p_mapOptions->{$bSetting}) {
    answer("\"$bSetting\" is not a valid battle setting for current mod and map (use \"!list bSettings\" to list available battle settings)");
    return 0;
  }

  my $p_options={};
  my $optionScope='engine';
  my $allowExternalValues=0;
  if(exists $p_modOptions->{$bSetting}) {
    $optionScope='mod';
    $p_options=$p_modOptions;
    $allowExternalValues=$conf{allowModOptionsValues};
  }elsif(exists $p_mapOptions->{$bSetting}) {
    $optionScope='map';
    $p_options=$p_mapOptions;
    $allowExternalValues=$conf{allowMapOptionsValues};
  }
  my @allowedValues=getBSettingAllowedValues($bSetting,$p_options,$allowExternalValues);
  my $optionType = $optionScope eq 'engine' ? 'unknown' : $p_options->{$bSetting}{type};
  if(! @allowedValues && $allowExternalValues) {
    answer("\"$bSetting\" is a $optionScope option of type \"$optionType\", it must be defined in current battle preset to be modifiable");
    return 0;
  }

  my $allowed=0;
  foreach my $allowedValue (@allowedValues) {
    if(isRange($allowedValue)) {
      $allowed=1 if(matchRange($allowedValue,$val));
    }elsif($optionType eq 'string' && substr($allowedValue,0,1) eq '~') {
      my $regexp=substr($allowedValue,1);
      if(eval { qr/^$regexp$/ } && ! $@) {
        $allowed=1 if($val =~ /^$regexp$/);
      }else{
        slog("Ignoring invalid regular expression \"$regexp\" when checking $bSetting battle setting allowed values (string $optionScope option)",2);
      }
    }elsif($val eq $allowedValue) {
      $allowed=1;
    }
    last if($allowed);
  }
  if($allowed) {
    if(exists $spads->{bSettings}{$bSetting}) {
      if($spads->{bSettings}{$bSetting} eq $val) {
        answer("Battle setting \"$bSetting\" is already set to value \"$val\"");
        return 0;
      }
    }elsif($val eq $p_options->{$bSetting}{default}) {
      answer("Battle setting \"$bSetting\" is already set to value \"$val\"");
      return 0;
    }
    return 1 if($checkOnly);
    $spads->{bSettings}{$bSetting}=$val;
    sendBattleSetting($bSetting) if($lobbyState >= LOBBY_STATE_BATTLE_OPENED);
    $timestamps{autoRestore}=time;
    sayBattleAndGame("Battle setting changed by $user ($bSetting=$val)");
    answer("Battle setting changed ($bSetting=$val)") if($source eq "pv");
    applyMapBoxes() if($bSetting eq "startpostype");
    return 1;
  }else{
    answer("Value \"$val\" for battle setting \"$bSetting\" is not allowed with current $optionScope or battle preset"); 
    return 0;
  }

}

sub hCancelQuit {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if(! defined $quitAfterGame{action}) {
    answer("No quit or restart has been scheduled, nothing to cancel");
    return 0;
  }
  return 1 if($checkOnly);

  my %sourceNames = ( pv => "private",
                      chan => "channel #$masterChannel",
                      game => "game",
                      battle => "battle lobby" );

  applyQuitAction(undef,undef,"requested by $user in $sourceNames{$source}");
  return 1;
}

sub isNotAllowedToVoteForResign {
  my ($user,$resignedPlayer)=@_;
  return 1 unless($autohost->getState() == 2);
  return 2 unless(exists $p_runningBattle->{users}{$user}
                  && defined $p_runningBattle->{users}{$user}{battleStatus}
                  && $p_runningBattle->{users}{$user}{battleStatus}{mode});
  return 3 unless($p_runningBattle->{users}{$user}{battleStatus}{team} == $p_runningBattle->{users}{$resignedPlayer}{battleStatus}{team});
  my $p_ahPlayer=$autohost->getPlayer($user);
  return 4 unless(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1);
  return 5 if($p_ahPlayer->{lost});
  return 0;
}

sub hCallVote {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($checkOnly || $#{$p_params} != 0) {
    invalidSyntax($user,'callvote');
    return 0;
  }

  my ($lcCmd,@cmd);
  
  my $fullCmd=$p_params->[0];
  if(ref $fullCmd eq 'ARRAY') { # avoid reparsing command in auto-call vote case
    @cmd=@{$fullCmd};
    $lcCmd=lc($cmd[0]);
  }else{
    $fullCmd =~ s/^!//;
    if($fullCmd !~ /^\w/) {
      invalidSyntax($user,'callvote');
      return 0;
    }
    ($lcCmd,@cmd)=parseSpadsCmd($fullCmd);
  }
  
  my $checkValue=executeCommand($source,$user,\@cmd,1);
  return 0 unless($checkValue);

  if(ref $checkValue eq 'ARRAY') {
    @cmd=@{$checkValue};
    $lcCmd=lc($cmd[0]);
  }elsif($checkValue ne '1') {
    @cmd=split(/ /,$checkValue); # for legacy plugins
    $lcCmd=lc($cmd[0]);
  }

  my $p_levelsForVote=getCommandLevels($source,$user,$lcCmd);

  if(! defined $p_levelsForVote->{voteLevel} || $p_levelsForVote->{voteLevel} eq '') {
    answer("$user, you are not allowed to vote for command \"$cmd[0]\" in current context.");
    return 0;
  }

  my $voterLevel=getUserAccessLevel($user);
  my $voterLevelWithoutBoss=$voterLevel;
  $voterLevel=0 if(%bosses && ! exists $bosses{$user});
  
  if($voterLevel < $p_levelsForVote->{voteLevel}) {
    if($voterLevelWithoutBoss >= $p_levelsForVote->{voteLevel}) {
      answer("$user, you are not allowed to vote for command \"$cmd[0]\" in current context (boss mode is enabled).");
    }else{
      answer("$user, you are not allowed to vote for command \"$cmd[0]\" in current context.");
    }
    return 0;
  }

  if(%currentVote) {
    if(exists $currentVote{command}) {
      if((exists $currentVote{remainingVoters}{$user} || exists $currentVote{awayVoters}{$user}) && $#{$currentVote{command}} == $#cmd) {
        my $isSameCmd=1;
        for my $i (0..$#cmd) {
          if(lc($cmd[$i]) ne lc($currentVote{command}[$i])) {
            $isSameCmd=0;
            last;
          }
        }
        return executeCommand($source,$user,['vote','y']) if($isSameCmd);
      }
      answer("$user, there is already a vote in progress, please wait for it to finish before calling another one.");
      return 0;
    }elsif($user eq $currentVote{user}) {
      answer("$user, please wait ".($currentVote{expireTime} + $conf{reCallVoteDelay} - time)." more second(s) before calling another vote (vote flood protection).");
      return 0;
    }
  }

  my %remainingVoters;
  if(exists $lobby->{battle}{users}) {
    foreach my $bUser (keys %{$lobby->{battle}{users}}) {
      next if($bUser eq $user || $bUser eq $conf{lobbyLogin});
      my $p_levels=getCommandLevels($source,$bUser,$lcCmd);
      my $level=getUserAccessLevel($bUser);
      $level=0 if(%bosses && ! exists $bosses{$bUser});
      if(defined $p_levels->{voteLevel} && $p_levels->{voteLevel} ne "" && $level >= $p_levels->{voteLevel}) {
        my ($voteRingDelay,$votePvMsgDelay)=(getUserPref($bUser,'voteRingDelay'),getUserPref($bUser,'votePvMsgDelay'));
        $remainingVoters{$bUser} = { ringTime => 0,
                                     notifyTime => 0};
        $remainingVoters{$bUser}{ringTime} = time+$voteRingDelay if($voteRingDelay);
        $remainingVoters{$bUser}{notifyTime} = time+$votePvMsgDelay if($votePvMsgDelay);
      }
    }
  }
  if($autohost->getState()) {
    foreach my $gUserNb (keys %{$autohost->{players}}) {
      next if($autohost->{players}{$gUserNb}{disconnectCause} != -1);
      my $gUser=$autohost->{players}{$gUserNb}{name};
      next if($gUser eq $user || $gUser eq $conf{lobbyLogin} || exists $remainingVoters{$gUser});
      my $p_levels=getCommandLevels($source,$gUser,$lcCmd);
      my $level=getUserAccessLevel($gUser);
      $level=0 if(%bosses && ! exists $bosses{$gUser});
      if(defined $p_levels->{voteLevel} && $p_levels->{voteLevel} ne "" && $level >= $p_levels->{voteLevel}) {
        my ($voteRingDelay,$votePvMsgDelay)=(getUserPref($gUser,'voteRingDelay'),getUserPref($gUser,'votePvMsgDelay'));
        $remainingVoters{$gUser} = { ringTime => 0,
                                     notifyTime => 0};
        $remainingVoters{$gUser}{ringTime} = time+$voteRingDelay if($voteRingDelay);
        $remainingVoters{$gUser}{notifyTime} = time+$votePvMsgDelay if($votePvMsgDelay);
      }
    }
    if($lcCmd eq 'resign') {
      map {delete $remainingVoters{$_} if(isNotAllowedToVoteForResign($_,$cmd[1]))} (keys %remainingVoters);
    }
  }

  if(%remainingVoters) {
    my $voteCallAllowed=1;
    foreach my $pluginName (@pluginsOrder) {
      $voteCallAllowed=$plugins{$pluginName}->onVoteRequest($source,$user,\@cmd,\%remainingVoters) if($plugins{$pluginName}->can('onVoteRequest'));
      delete @remainingVoters{@{$voteCallAllowed}} if(ref $voteCallAllowed eq 'ARRAY');
      last unless($voteCallAllowed && %remainingVoters);
    }
    return 0 unless($voteCallAllowed);
    return executeCommand($source,$user,\@cmd) unless(%remainingVoters);
    my $r_cmdVoteSettings=getCmdVoteSettings($lcCmd);
    my $awayVoteDelay=$r_cmdVoteSettings->{awayVoteDelay};
    my $awayVoteTime=0;
    if($awayVoteDelay ne '') {
      $awayVoteDelay=ceil($r_cmdVoteSettings->{voteTime}*$1/100) if($awayVoteDelay =~ /^(\d+)\%$/);
      $awayVoteDelay=$r_cmdVoteSettings->{voteTime} if($awayVoteDelay > $r_cmdVoteSettings->{voteTime});
      $awayVoteTime = time + $awayVoteDelay;
    }
    %currentVote = (expireTime => time + $r_cmdVoteSettings->{voteTime},
                    user => $user,
                    awayVoteTime => $awayVoteTime,
                    source => $source,
                    command => \@cmd,
                    remainingVoters => \%remainingVoters,
                    yesCount => 1,
                    noCount => 0,
                    blankCount => 0,
                    awayVoters => {},
                    manualVoters => { $user => 'yes' });
    my @playersAllowed=keys %remainingVoters;
    my $playersAllowedString=join(",",@playersAllowed);
    if(length($playersAllowedString) > 50) {
      $playersAllowedString=$#playersAllowed+1;
      $playersAllowedString.=" users allowed to vote.";
    }else{
      $playersAllowedString="User(s) allowed to vote: $playersAllowedString";
    }
    sayBattleAndGame("$user called a vote for command \"".join(' ',@cmd)."\" [!vote y, !vote n, !vote b]");
    sayBattleAndGame($playersAllowedString);
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onVoteStart($user,\@cmd) if($plugins{$pluginName}->can('onVoteStart'));
    }
    return 1;
  }else{
    return executeCommand($source,$user,\@cmd);
  }

}

sub hCheat {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($autohost->getState() == 0) {
    answer("Unable to send data on AutoHost interface, game is not running");
    return 0;
  }

  return 1 if($checkOnly);

  $cheating=1;

  if($#{$p_params} == -1) {
    $autohost->sendChatMessage("/cheat");
    logMsg("game","> /cheat") if($conf{logGameChat});
    return 1;
  }
  if($#{$p_params} == 0) {
    if($p_params->[0] eq "0") {
      $autohost->sendChatMessage("/cheat 0");
      logMsg("game","> /cheat 0") if($conf{logGameChat});
      return 1;
    }
    if($p_params->[0] eq "1") {
      $autohost->sendChatMessage("/cheat 1");
      logMsg("game","> /cheat 1") if($conf{logGameChat});
      return 1;
    }
  }
  my $params=$p_params->[0];
  $params="/$params" unless($params =~ /^\//);

  $autohost->sendChatMessage("/cheat 1");
  logMsg("game","> /cheat 1") if($conf{logGameChat});
  $autohost->sendChatMessage($params);
  logMsg("game","> $params") if($conf{logGameChat});
  $autohost->sendChatMessage("/cheat 0");
  logMsg("game","> /cheat 0") if($conf{logGameChat});
  
  return 1;
  
}

sub hChpasswd {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} < 0 || $#{$p_params} > 1) {
    invalidSyntax($user,"chpasswd");
    return 0;
  }
  my $passwdUser=$p_params->[0];
  my $aId=getLatestUserAccountId($passwdUser);
  if($aId eq "" && ! $lanMode) {
    if($conf{userDataRetention} !~ /^0;/ && ! $spads->isStoredUser($passwdUser)) {
      answer("Unable to change password of \"$passwdUser\" (unknown user, try !searchUser first)");
    }else{
      answer("Unable to change password of \"$passwdUser\" (account ID unknown)");
    }
    return 0;
  }
  return 1 if($checkOnly);
  my $oldLevel=0;
  $oldLevel=getUserAccessLevel($passwdUser) if($lobbyState > LOBBY_STATE_LOGGED_IN && exists $lobby->{users}{$passwdUser});
  if($#{$p_params} == 0) {
    setAccountUserPref($aId,$passwdUser,'password','');
    answer("Password removed for user $passwdUser");
  }else{
    setAccountUserPref($aId,$passwdUser,'password',md5_base64($p_params->[1]));
    answer("Password set to \"$p_params->[1]\" for user $passwdUser");
  }
  if($user ne $passwdUser && $lobbyState > LOBBY_STATE_LOGGED_IN && exists $lobby->{users}{$passwdUser}) {
    sayPrivate($passwdUser,"Your AutoHost password has been modified by $user");
  }
  return 1;
}

sub hChrank {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} < 0 || $#{$p_params} > 1) {
    invalidSyntax($user,"chrank");
    return 0;
  }
  my $modifiedUser=$p_params->[0];
  my $aId=getLatestUserAccountId($modifiedUser);
  if($aId eq "" && ! $lanMode) {
    if($conf{userDataRetention} !~ /^0;/ && ! $spads->isStoredUser($modifiedUser)) {
      answer("Unable to change rankMode of \"$modifiedUser\" (unknown user, try !searchUser first)");
    }else{
      answer("Unable to change rankMode of \"$modifiedUser\" (account ID unknown)");
    }
    return 0;
  }
  if($#{$p_params} == 0) {
    return 1 if($checkOnly);
    setAccountUserPref($aId,$modifiedUser,"rankMode","");
    answer("Default rankMode restored for user $modifiedUser");
  }else{
    my $val=$p_params->[1];
    my ($errorMsg)=$spads->checkUserPref("rankMode",$val);
    if($errorMsg) {
      invalidSyntax($user,"chrank",$errorMsg);
      return 0;
    }
    return 1 if($checkOnly);
    setAccountUserPref($aId,$modifiedUser,"rankMode",$val);
    answer("RankMode set to \"$val\" for user $modifiedUser");
  }
  if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$modifiedUser}) {
    updateBattleSkillForNewSkillAndRankModes($modifiedUser);
    if(defined $lobby->{battle}{users}{$modifiedUser}{battleStatus} && $lobby->{battle}{users}{$modifiedUser}{battleStatus}{mode}) {
      $balanceState=0;
      %balanceTarget=();
    }
  }
  return 1;
}

sub hChskill {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} < 0 || $#{$p_params} > 1) {
    invalidSyntax($user,'chskill');
    return 0;
  }
  my $modifiedUser=$p_params->[0];
  my $aId=getLatestUserAccountId($modifiedUser);
  if($aId eq '' && ! $lanMode) {
    if($conf{userDataRetention} !~ /^0;/ && ! $spads->isStoredUser($modifiedUser)) {
      answer("Unable to change skillMode of \"$modifiedUser\" (unknown user, try !searchUser first)");
    }else{
      answer("Unable to change skillMode of \"$modifiedUser\" (account ID unknown)");
    }
    return 0;
  }
  if($#{$p_params} == 0) {
    return 1 if($checkOnly);
    setAccountUserPref($aId,$modifiedUser,'skillMode','');
    answer("Default skillMode restored for user $modifiedUser");
  }else{
    my $val=$p_params->[1];
    my ($errorMsg)=$spads->checkUserPref('skillMode',$val);
    if($errorMsg) {
      invalidSyntax($user,'chskill',$errorMsg);
      return 0;
    }
    return 1 if($checkOnly);
    setAccountUserPref($aId,$modifiedUser,'skillMode',$val);
    answer("SkillMode set to \"$val\" for user $modifiedUser");
  }
  if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$modifiedUser}) {
    updateBattleSkillForNewSkillAndRankModes($modifiedUser);
    if(defined $lobby->{battle}{users}{$modifiedUser}{battleStatus} && $lobby->{battle}{users}{$modifiedUser}{battleStatus}{mode}) {
      $balanceState=0;
      %balanceTarget=();
    }
  }
  return 1;
}

sub hCKick {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"ckick");
    return 0;
  }
  
  if($lobbyState < LOBBY_STATE_SYNCHRONIZED || ! exists $lobby->{channels}{$masterChannel} ) {
    answer("Unable to kick from channel \#$masterChannel (outside of channel)");
    return 0;
  }

  if(! $conf{opOnMasterChannel}) {
    answer("Unable to kick from channel \#$masterChannel (Not operator)");
    return 0;
  }

  my @players=keys(%{$lobby->{channels}{$masterChannel}{users}});
  my $p_kickedUsers=cleverSearch($p_params->[0],\@players);
  if(! @{$p_kickedUsers}) {
    answer("Unable to find matching user for \"$p_params->[0]\" in channel");
    return 0;
  }
  if($#{$p_kickedUsers} > 0) {
    answer("Ambiguous command, multiple matches found for player \"$p_params->[0]\" channel");
    return 0;
  }
  my $kickedUser=$p_kickedUsers->[0];
  if($kickedUser eq $conf{lobbyLogin}) {
    answer("Nice try ;)");
    return 0;
  }

  return ['cKick',$kickedUser] if($checkOnly);

  my %sourceNames = ( pv => "private",
                      chan => "channel \#$masterChannel",
                      game => "game",
                      battle => "battle lobby" );

  sayPrivate("ChanServ","!kick \#$masterChannel $kickedUser requested by $user in $sourceNames{$source}");
  return ['cKick',$kickedUser];
}

sub hClearBox {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to clear start box, battle lobby is closed");
    return 0;
  }
  if($#{$p_params} > 0) {
    invalidSyntax($user,"clearbox");
    return 0;
  }
  my ($teamNb)=@{$p_params};
  my $minNb=0;

  if(defined $teamNb) {
    if($teamNb =~ /^extra$/i) {
      return 1 if($checkOnly);
      $minNb=$conf{nbTeams};
    }elsif($teamNb !~ /^\d+$/ || $teamNb < 1 || $teamNb > 251) {
      invalidSyntax($user,"clearbox","invalid team number");
      return 0;
    }else{
      return 1 if($checkOnly);
      $teamNb-=1;
      queueLobbyCommand(["REMOVESTARTRECT",$teamNb]) if(exists $lobby->{battle}{startRects}{$teamNb});
      return 1;
    }
  }

  return 1 if($checkOnly);
  foreach $teamNb (keys %{$lobby->{battle}{startRects}}) {
    next if($teamNb < $minNb);
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]);
  }
  return 1;
}

sub hCloseBattle {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to close battle lobby, it is already closed");
    return 0;
  }
  if($#{$p_params} != -1) {
    invalidSyntax($user,"closebattle");
    return 0;
  }
  return 1 if($checkOnly);

  my %sourceNames = ( pv => "private",
                      chan => "channel #$masterChannel",
                      game => "game",
                      battle => "battle lobby" );

  closeBattleAfterGame("requested by $user in $sourceNames{$source}");
  return 1;
}

sub hEndVote {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,"endvote");
    return 0;
  }

  if(%currentVote && exists $currentVote{command}) {
    return 1 if($checkOnly);
    sayBattleAndGame("Vote cancelled by $user");
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
    }
    delete @currentVote{(qw'awayVoteTime source command remainingVoters yesCount noCount blankCount awayVoters manualVoters')};
    $currentVote{expireTime}=time;
    return 1;
  }else{
    answer("Unable to cancel vote (no vote in progress)");
    return 0;
  }
}

sub hFixColors {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to fix colors, battle lobby is closed");
    return 0;
  }

  if($#{$p_params} != -1) {
    invalidSyntax($user,"fixcolors");
    return 0;
  }

  return 1 if($checkOnly);
  fixColors();
  return 1;
}

sub hForce {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer('Unable to force player battle status, battle lobby is closed');
    return 0;
  }

  if($#{$p_params} < 1) {
    invalidSyntax($user,'force');
    return 0;
  }

  my @forceOrders;
  if($p_params->[0] eq '*') {
    my (undef,@balanceParams)=@{$p_params};
    my $balanceString=join('',@balanceParams);
    $balanceString=~s/\s+//g;
    my @teamsStrings;
    while($balanceString =~ /^\(([^\)]+)\)(.*)$/) {
      push(@teamsStrings,$1);
      $balanceString=$2;
    }
    if(! @teamsStrings) {
      invalidSyntax($user,'force');
      return 0;
    }
    if($balanceString) {
      invalidSyntax($user,'force',"invalid parameter \"$balanceString\"");
      return 0;
    }
    if($#teamsStrings > 249) {
      answer('Unable to force manual balance, too many teams required');
      return 0;
    }
    my $idNb=0;
    for my $teamNb (0..$#teamsStrings) {
      my @teamPlayers=split(/,/,$teamsStrings[$teamNb]);
      foreach my $teamPlayer (@teamPlayers) {
        my @idPlayers = index($teamPlayer,'+') == -1 ? ($teamPlayer) : (split(/\+/,$teamPlayer));
        foreach my $idPlayer (@idPlayers) {
          push(@forceOrders,[$idPlayer,'team',$teamNb+1]);
          push(@forceOrders,[$idPlayer,'id',$idNb+1]);
        }
        $idNb++;
      }
    }
    if($idNb > 252) {
      answer('Unable to force manual balance, too many ids required');
      return 0;
    }
  }elsif($#{$p_params} > 2) {
    invalidSyntax($user,'force');
    return 0;
  }else{
    push(@forceOrders,$p_params);
  }

  my @fixedForceOrders;
  foreach my $p_forceOrder (@forceOrders) {
    my ($player,$type,$nb)=@{$p_forceOrder};
    $type=lc($type);

    if($type eq 'id' || $type eq 'team') {
      if($conf{autoBalance} ne 'off') {
        answer('Cannot force id/team, autoBalance is enabled');
        return 0;
      }elsif($conf{autoBlockBalance} && $balanceState) {
        answer('Cannot force id/team, teams have been balanced and autoBlockBalance is enabled');
        return 0;
      }else{
        if(! defined $nb || $nb !~ /^\d+$/ || $nb > 251 || $nb < 1) {
          invalidSyntax($user,'force');
          return 0;
        }
        $nb+=0;
      }
    }elsif($type eq 'spec') {
      if(defined $nb) {
        invalidSyntax($user,'force');
        return 0;
      }
    }elsif($type eq 'bonus') {
      if(! defined $nb || $nb !~ /^\d+$/ || $nb > 100) {
        invalidSyntax($user,'force');
        return 0;
      }
      $nb+=0;
    }else{
      invalidSyntax($user,'force');
      return 0;
    }

    my @forcedUsers;
    if($player =~ /^\%(.+)$/) {
      $player=$1;
    }else{
      my @players=keys(%{$lobby->{battle}{users}});
      my $p_forcedUsers=cleverSearch($player,\@players);
      @forcedUsers=grep {$_ ne $conf{lobbyLogin}} @{$p_forcedUsers};
      if($#forcedUsers > 0) {
        answer("Ambiguous command, multiple matches found for player \"$player\" in battle lobby");
        return 0;
      }
    }
    if(@forcedUsers) {
      push(@fixedForceOrders,[$forcedUsers[0],$type,$nb]);
    }else{
      my @bots=keys(%{$lobby->{battle}{bots}});
      my $p_forcedBots=cleverSearch($player,\@bots);
      if(! @{$p_forcedBots}) {
        answer("Unable to find matching player for \"$player\" in battle lobby");
        return 0;
      }
      if($#{$p_forcedBots} > 0) {
        answer("Ambiguous command, multiple matches found for player \"$player\" in battle lobby");
        return 0;
      }
      if($type eq 'spec') {
        invalidSyntax($user,'force');
        return 0;
      }
      push(@fixedForceOrders,["\%$p_forcedBots->[0]",$type,$nb]);
    }
  }

  my @canonicalCommandForm=('force');
  if($#fixedForceOrders == 0) {
    push(@canonicalCommandForm,$fixedForceOrders[0][0],$fixedForceOrders[0][1],$fixedForceOrders[0][1] eq 'spec' ? () : $fixedForceOrders[0][2]);
  }else{
    push(@canonicalCommandForm,'*','');
    my @manualBalance;
    my ($latestTeam,$latestId)=(-1,-1);
    for my $playerIdx (0..(($#fixedForceOrders-1)/2)) {
      my $orderIdx=$playerIdx*2;
      if($fixedForceOrders[$orderIdx][1] ne 'team' || $fixedForceOrders[$orderIdx+1][1] ne 'id' || $fixedForceOrders[$orderIdx][0] ne $fixedForceOrders[$orderIdx+1][0]) {
        answer('Unable to process manual balance (internal error)');
        slog("Unable to process manual balance (internal error, debug data: $fixedForceOrders[$orderIdx][1],$fixedForceOrders[$orderIdx+1][1],$fixedForceOrders[$orderIdx][0],$fixedForceOrders[$orderIdx+1][0])",1);
        return 0;
      }
      my ($player,$team,$id)=($fixedForceOrders[$orderIdx][0],$fixedForceOrders[$orderIdx][2],$fixedForceOrders[$orderIdx+1][2]);
      if($team != $latestTeam) {
        push(@manualBalance,[[$player]]);
      }elsif($id != $latestId) {
        push(@{$manualBalance[$#manualBalance]},[$player]);
      }else{
        my $p_teamArray=$manualBalance[$#manualBalance];
        push(@{$p_teamArray->[$#{$p_teamArray}]},$player);
      }
      ($latestTeam,$latestId)=($team,$id);
    }
    foreach my $p_team (@manualBalance) {
      $canonicalCommandForm[-1].='('.(join(',',map { join('+',@{$_}) } @{$p_team})).')';
    }
  }

  return \@canonicalCommandForm if($checkOnly);
  
  my $p_battle=$lobby->getBattle();
  foreach my $p_forceOrder (@fixedForceOrders) {
    my ($player,$type,$nb)=@{$p_forceOrder};
    if($player =~ /^\%(.+)$/) {
      $player=$1;
      my $p_battleStatus=$p_battle->{bots}{$player}{battleStatus};
      if($type eq 'team') {
        $p_battleStatus->{team}=$nb-1;
      }elsif($type eq 'id') {
        $p_battleStatus->{id}=$nb-1;
      }elsif($type eq 'bonus') {
        $p_battleStatus->{bonus}=$nb;
      }else{
        answer('Unable to process manual balance command (internal error)');
        slog("Unable to process manual balance command (invalid type: $type)",1);
        return 0;
      }
      my $p_color=$p_battle->{bots}{$player}{color};
      queueLobbyCommand(['UPDATEBOT',$player,$lobby->marshallBattleStatus($p_battleStatus),$lobby->marshallColor($p_color)]);
    }else{
      if($type eq 'spec') {
        queueLobbyCommand(['FORCESPECTATORMODE',$player]);
      }elsif($type eq 'id') {
        queueLobbyCommand(['FORCETEAMNO',$player,$nb-1]);
      }elsif($type eq 'team') {
        queueLobbyCommand(['FORCEALLYNO',$player,$nb-1]);
      }elsif($type eq 'bonus') {
        queueLobbyCommand(['HANDICAP',$player,$nb]);
      }else{
        answer('Unable to process manual balance command (internal error)');
        slog("Unable to process manual balance command (invalid type: $type)",1);
        return 0;
      }
    }
  }

  return \@canonicalCommandForm;
}

sub hForcePreset {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"forcepreset");
    return 0;
  }

  my ($preset)=@{$p_params};

  if(! exists $spads->{presets}{$preset}) {
    answer("\"$preset\" is not a valid preset (use \"!list presets\" to list available presets)");
    return 0;
  }

  return 1 if($checkOnly);

  if($preset eq $conf{defaultPreset}) {
    $timestamps{autoRestore}=0;
  }else{
    $timestamps{autoRestore}=time;
  }
  applyPreset($preset);
  my $msg="Preset \"$preset\" ($conf{description}) applied by $user";
  $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
  sayBattleAndGame($msg);
  return 1;
}

sub hForceStart {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,"forcestart");
    return 0;
  }

  my $gameState=$autohost->getState();
  if($gameState == 0) {
    if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
      answer("Unable to start game, battle lobby is closed");
      return 0;
    }
    if($springPid) {
      answer("Unable to start game, it is already running");
      return 0;
    }
    return launchGame(1,$checkOnly);
  }elsif($gameState == 1) {
    return 1 if($checkOnly);
    broadcastMsg("Forcing game start by $user");
    $timestamps{autoForcePossible}=-2;
    $autohost->sendChatMessage("/forcestart");
    logMsg("game","> /forcestart") if($conf{logGameChat});
    return 1;
  }else{
    answer("Unable to force start game, it is already running");
    return 0;
  }

}

sub hGKick {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"gkick");
    return 0;
  }

  my $gameState=$autohost->getState();
  if($gameState == 0) {
    answer("Unable to kick from game, game is not running");
    return 0;
  }

  my $p_ahPlayers=$autohost->getPlayersByNames();
  my @players=grep {%{$p_ahPlayers->{$_}} && $p_ahPlayers->{$_}{disconnectCause} == -1} (keys %{$p_ahPlayers});
  my $p_kickedUsers=cleverSearch($p_params->[0],\@players);
  if(! @{$p_kickedUsers}) {
    answer("Unable to find matching player for \"$p_params->[0]\" in game");
    return 0;
  }
  if($#{$p_kickedUsers} > 0) {
    answer("Ambiguous command, multiple matches found for player \"$p_params->[0]\" in game");
    return 0;
  }
  my $kickedUser=$p_kickedUsers->[0];
  if($kickedUser eq $conf{lobbyLogin}) {
    answer("Nice try ;)");
    return 0;
  }

  return ['gKick',$kickedUser] if($checkOnly);

  $autohost->sendChatMessage("/kickbynum $p_ahPlayers->{$kickedUser}{playerNb}");
  logMsg("game","> /kickbynum $p_ahPlayers->{$kickedUser}{playerNb}") if($conf{logGameChat});

  return ['gKick',$kickedUser];
  
}

sub initUserIrcColors {
  my $user=shift;
  if(ref $user) {
    return @{$user->{ircColors}} if(defined $user->{ircColors});
  }else{
    return @IRC_STYLE if(getUserPref($user,'ircColors'));
  }
  return @NO_IRC_STYLE;
}

sub hHelp {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my ($cmd,$setting)=@{$p_params};

  return 0 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  if(defined $cmd) {
    my $helpCommand=lc($cmd);
    $helpCommand=$1 if($helpCommand =~ /^!(.+)$/);
    if($helpCommand !~ /^\w+$/) {
      invalidSyntax($user,"help");
      return 0;
    }

    my $modName = $lobbyState >= LOBBY_STATE_BATTLE_OPENED ? $lobby->{battles}{$lobby->{battle}{battleId}}{mod} : $targetMod;
    my $p_modOptions=getModOptions($modName);
    my $p_mapOptions=getMapOptions($currentMap);

    if(! exists $spads->{help}{$helpCommand} && $conf{allowSettingsShortcut} && ! $HIDDEN_SETTINGS_LOWERCASE{$helpCommand}) {
      if(exists $spads->{helpSettings}{global}{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="global";
      }elsif(exists $spads->{helpSettings}{set}{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="set";
      }elsif(exists $spads->{helpSettings}{hset}{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="hset";
      }elsif(exists $spads->{helpSettings}{bset}{$helpCommand} || exists $p_modOptions->{$helpCommand} || exists $p_mapOptions->{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="bset";
      }elsif(exists $spads->{helpSettings}{pset}{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="pset";
      }
    }

    if(defined $setting) {
      my %settingTypes=(global => "global setting",
                        set => "setting",
                        hset => "hosting setting",
                        bset => "battle setting",
                        pset => "preference");
      $setting=lc($setting);
      if(! exists $settingTypes{$helpCommand}) {
        invalidSyntax($user,"help");
        return 0;
      }
      if($helpCommand eq "bset" && (exists $p_modOptions->{$setting} || exists $p_mapOptions->{$setting})) {
        my $p_option;
        my $optionScope;
        if(exists $p_modOptions->{$setting}) {
          $p_option=$p_modOptions->{$setting};
          $optionScope='mod';
        }else{
          $p_option=$p_mapOptions->{$setting};
          $optionScope='map';
        }
        sayPrivate($user,"$B********** Help for battle setting \"$C{12}$setting$C{1}\" ($optionScope option) **********");
        sayPrivate($user,"$B$C{10}Explicit name:");
        sayPrivate($user,"  $p_option->{name}");
        sayPrivate($user,"$B$C{10}Description:");
        sayPrivate($user,"  $p_option->{description}");
        sayPrivate($user,"$B$C{10}Allowed values:");
        if($p_option->{type} eq "bool") {
          sayPrivate($user,"  0: false");
          sayPrivate($user,"  1: true");
        }elsif($p_option->{type} eq "list") {
          my %listItems=%{$p_option->{list}};
          foreach my $itemKey (sort keys %listItems) {
            sayPrivate($user,"  $itemKey: $listItems{$itemKey}{name} ($listItems{$itemKey}{description})");
          }
        }elsif($p_option->{type} eq "number") {
          my $allowedRangeString="  $p_option->{numberMin} .. $p_option->{numberMax}";
          if($p_option->{numberStep} > 0) {
            $allowedRangeString.=" (step: $p_option->{numberStep})" if(getRangeStepFromBoundaries($p_option->{numberMin},$p_option->{numberMax}) != $p_option->{numberStep});
          }else{
            $allowedRangeString.=' (no quantization)';
          }
          sayPrivate($user,$allowedRangeString);
        }elsif($p_option->{type} eq "string") {
          sayPrivate($user,"  any string with a maximum length of $p_option->{stringMaxLen}");
        }
        sayPrivate($user,"$B$C{10}Default value:");
        sayPrivate($user,"  $p_option->{default}");
      }elsif(exists $spads->{helpSettings}{$helpCommand}{$setting}) {
        my $settingHelp=$spads->{helpSettings}{$helpCommand}{$setting};
        sayPrivate($user,"$B********** Help for $settingTypes{$helpCommand} \"$C{12}$settingHelp->{name}$C{1}\" **********");
        sayPrivate($user,"$B$C{10}Explicit name:");
        sayPrivateArray($user,$settingHelp->{explicitName});
        sayPrivate($user,"$B$C{10}Description:");
        sayPrivateArray($user,$settingHelp->{description});
        sayPrivate($user,"$B$C{10}Format / allowed values:");
        sayPrivateArray($user,$settingHelp->{format});
        sayPrivate($user,"$B$C{10}Default value:");
        sayPrivateArray($user,$settingHelp->{default});
      }else{
        if($helpCommand eq "bset") {
          sayPrivate($user,"\"$C{12}$setting$C{1}\" is not a valid battle setting for current mod and map (use \"$C{3}!list bSettings$C{1}\" to list available battle settings)");
        }elsif($helpCommand eq "global") {
          sayPrivate($user,"\"$C{12}$setting$C{1}\" is not a valid global setting.");
        }elsif($helpCommand eq "set") {
          sayPrivate($user,"\"$C{12}$setting$C{1}\" is not a valid preset setting (use \"$C{3}!list settings$C{1}\" to list available preset settings).");
        }elsif($helpCommand eq "hset") {
          sayPrivate($user,"\"$C{12}$setting$C{1}\" is not a valid hosting setting (use \"$C{3}!list hSettings$C{1}\" to list available hosting settings).");
        }elsif($helpCommand eq "pset") {
          sayPrivate($user,"\"$C{12}$setting$C{1}\" is not a valid preference (use \"$C{3}!list pref$C{1}\" to list available preferences).");
        }
      }
    }else {
      my $p_help;
      my $moduleString;
      if(exists $spads->{help}{$helpCommand}) {
        $p_help=$spads->{help}{$helpCommand};
        $moduleString='';
      }else{
        foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
          if(exists $spads->{pluginsConf}{$pluginName}{help}{$helpCommand}) {
            $p_help=$spads->{pluginsConf}{$pluginName}{help}{$helpCommand};
            $moduleString=" (plugin $pluginName)";
            last;
          }
        }
      }
      if(defined $p_help) {
        sayPrivate($user,"$B********** Help for command $C{12}$cmd$C{1}$moduleString **********");
        sayPrivate($user,"$B$C{10}Syntax:");
        my $helpLine=$p_help->[0];
        $helpLine="$C{12}$1$C{5}$2$C{1}$3" if($helpLine =~ /^(!\w+)(.*)( - .*)$/);
        sayPrivate($user,'  '.$helpLine);
        sayPrivate($user,"$B$C{10}Example(s):") if($#{$p_help} > 0);
        for my $i (1..$#{$p_help}) {
          $helpLine=$p_help->[$i];
          $helpLine="\"$C{3}$1$C{1}\"$2" if($helpLine =~ /^\"([^\"]+)\"(.+)$/);
          sayPrivate($user,'  '.$helpLine);
        }
      }else{
        sayPrivate($user,"\"$C{12}$cmd$C{1}\" is not a valid command or setting.");
      }
    }
  }else{

    my $level=getUserAccessLevel($user);
    my $p_helpForUser=$spads->getHelpForLevel($level);

    sayPrivate($user,"$B********** Available commands for your access level **********");
    foreach my $i (0..$#{$p_helpForUser->{direct}}) {
      $p_helpForUser->{direct}[$i]="$C{3}$1$C{5}$2$C{1}$3" if($p_helpForUser->{direct}[$i] =~ /^(!\w+)(.*)( - .*)$/);
      sayPrivate($user,$p_helpForUser->{direct}[$i]);
    }
    if(@{$p_helpForUser->{vote}}) {
      sayPrivate($user,"$B********** Additional commands available by vote for your access level **********");
      foreach my $i (0..$#{$p_helpForUser->{vote}}) {
        $p_helpForUser->{vote}[$i]="$C{10}$1$C{5}$2$C{14}$3" if($p_helpForUser->{vote}[$i] =~ /^(!\w+)(.*)( - .*)$/);
        sayPrivate($user,$p_helpForUser->{vote}[$i]);
      }
    }
    sayPrivate($user,"  --> Use \"$C{3}!list aliases$C{1}\" to list available command aliases.");
  }
  
  return 1;
}

sub sayPrivateArray {
  my ($user,$p_array)=@_;
  foreach my $l (@{$p_array}) {
    $l=~s/\[global:(\w+)\]/\"$1\" global setting/g;
    $l=~s/\[set:(\w+)\]/\"$1\" setting/g;
    $l=~s/\[hSet:(\w+)\]/\"$1\" hosting setting/g;
    $l=~s/\[bSet:(\w+)\]/\"$1\" battle setting/g;
    $l=~s/\[pSet:(\w+)\]/\"$1\" preference/g;
    sayPrivate($user,"  $l");
  }
}

sub hHelpAll {
  my (undef,$user,undef,$checkOnly)=@_;
  return 1 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $p_help=$spads->{help};

  sayPrivate($user,"$B********** SPADS commands **********");
  for my $command (sort (keys %{$p_help})) {
    next unless($command);
    my $helpLine=$p_help->{$command}[0];
    $helpLine="$C{3}$1$C{5}$2$C{1}$3" if($helpLine =~ /^(!\w+)(.*)( - .*)$/);
    sayPrivate($user,$helpLine);
  }

  foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
    if(%{$spads->{pluginsConf}{$pluginName}{help}}) {
      $p_help=$spads->{pluginsConf}{$pluginName}{help};
      sayPrivate($user,"$B********** $pluginName plugin commands **********");
      for my $command (sort (keys %{$p_help})) {
        next unless($command);
        my $helpLine=$p_help->{$command}[0];
        $helpLine="$C{3}$1$C{5}$2$C{1}$3" if($helpLine =~ /^(!\w+)(.*)( - .*)$/);
        sayPrivate($user,$helpLine);
      }
    }
  }
  
  return 1;
}

sub hHostStats {
  my ($source,$user,$p_params,$checkOnly)=@_;

  return 1 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $ahUptime=time-$timestamps{autoHostStart};

  sayPrivate($user,"$B$C{5}OS:$B$C{1} $os") if($os ne "");
  sayPrivate($user,"$B$C{5}CPU:$B$C{1} $cpuModel") if(defined $cpuModel);
  sayPrivate($user,"$B$C{5}RAM:$B$C{1} $mem") if($mem ne "");
  if($sysUptime) {
    my $uptime=secToTime($sysUptime+$ahUptime);
    sayPrivate($user,"$B$C{5}UpTime:$B$C{1} $uptime");
  }

  sayPrivate($user,"--");

  sayPrivate($user,"$B$C{5}Total in-game time:$B$C{1} $accountInGameTime") if(defined $accountInGameTime);

  my $ahUptimeString=secToTime($ahUptime);
  sayPrivate($user,"$B$C{5}AutoHost uptime:$B$C{1} $ahUptimeString");

  my $currentRunningTime=0;
  $currentRunningTime=time-$timestamps{lastGameStart} if($springPid && $autohost->getState());
  my $inGameRatio=0;
  $inGameRatio=($inGameTime+$currentRunningTime)*100/$ahUptime if($ahUptime);
  $inGameRatio=sprintf("%.2f",$inGameRatio);
  sayPrivate($user,"$B$C{5}In-game ratio:$B$C{1} $inGameRatio%");

  if($springPid) {
    my $gameRunningTime=secToTime(time-$timestamps{lastGameStart});
    sayPrivate($user,"$B$C{5}Current game running time:$B$C{1} $gameRunningTime");
  }elsif($timestamps{lastGameEnd}) {
    my $lastGameEndTime=secToTime(time-$timestamps{lastGameEnd});
    sayPrivate($user,"$B$C{5}Last game played:$B$C{1} $lastGameEndTime ago");
  }else{
    sayPrivate($user,"No game has been played yet since AutoHost start");
  }

  if($conf{userDataRetention} =~ /^0;/) {
    sayPrivate($user,"User data retention disabled");
  }else{
    my $nbAccounts=$spads->getNbAccounts();
    my $nbNames=$spads->getNbNames();
    my $nbIps=$spads->getNbIps();
    sayPrivate($user,"$B$C{7}$nbAccounts$B$C{1} accounts stored in memory, totaling $B$C{7}$nbNames$B$C{1} names and $B$C{7}$nbIps$B$C{1} IP addresses");
  }
  return 1;
}

sub hHPreset {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"hpreset");
    return 0;
  }

  my ($hPreset)=@{$p_params};

  if(! exists $spads->{hPresets}{$hPreset}) {
    answer("\"$hPreset\" is not a valid hosting preset (use \"!list hPresets\" to list available hosting presets)");
    return 0;
  }

  if(none {$hPreset eq $_} @{$spads->{values}{hostingPreset}}) {
    answer("Switching to hosting preset \"$hPreset\" is not allowed from current global preset");
    return 0;
  }

  return 1 if($checkOnly);

  $timestamps{autoRestore}=time;
  $spads->applyHPreset($hPreset);
  %conf=%{$spads->{conf}};
  updateTargetMod();
  my $msg="Hosting preset \"$hPreset\" ($spads->{hSettings}{description}) applied by $user";
  $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
  sayBattleAndGame($msg);
  return 1;
}

sub hHSet {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 1) {
    invalidSyntax($user,"hset");
    return 0;
  }

  my ($hSetting,$val)=@{$p_params};
  $val//='';
  $hSetting=lc($hSetting);

  foreach my $hParam (keys %{$spads->{hValues}}) {
    next if($HIDDEN_HOSTING_SETTINGS{$hParam});
    if($hSetting eq lc($hParam)) {
      my $allowed=0;
      foreach my $allowedValue (@{$spads->{hValues}{$hParam}}) {
        if(isRange($allowedValue)) {
          $allowed=1 if(matchRange($allowedValue,$val));
        }elsif($val eq $allowedValue) {
          $allowed=1;
        }
        last if($allowed);
      }
      if($allowed) {
        if($spads->{hSettings}{$hParam} eq $val) {
          answer("Hosting setting \"$hParam\" is already set to value \"$val\"");
          return 0;
        }
        return 1 if($checkOnly);
        $spads->{hSettings}{$hParam}=$val;
        my $modAvailable = $hParam eq 'modName' ? updateTargetMod() : 1;
        $timestamps{autoRestore}=time;
        my $msgStart='Hosting setting changed ';
        my $msgEnd="($hParam=$val)";
        if(! $modAvailable) {
          $msgEnd.=', unable to find matching mod archive!';
        }elsif($lobbyState >= LOBBY_STATE_BATTLE_OPENED && $modAvailable == 1) {
          $msgEnd.=', use !rehost to apply new value.';
        }
        sayBattleAndGame($msgStart."by $user ".$msgEnd);
        answer($msgStart.$msgEnd) if($source eq 'pv');
        return 1;
      }else{
        answer("Value \"$val\" for hosting setting \"$hParam\" is not allowed in current hosting preset");
        return 0;
      }
    }
  }

  answer("\"$hSetting\" is not a valid hosting setting (use \"!list hSettings\" to list available hosting settings)");
  return 0;
}

sub hJoinAs {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 0 || $#{$p_params} > 1) {
    invalidSyntax($user,"joinas");
    return 0;
  }
  
  if(! $autohost->getState()) {
    answer("Unable to add in-game player, game is not running");
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer("Unable to add in-game player, battle lobby is closed");
    return 0;
  }

  my ($joinedEntity,$joiningPlayer)=($p_params->[0],$user);
  $joiningPlayer=$p_params->[1] if($#{$p_params} == 1);

  my @battlePlayers=keys(%{$lobby->{battle}{users}});
  my $p_joiningPlayers=cleverSearch($joiningPlayer,\@battlePlayers);
  if(! @{$p_joiningPlayers}) {
    answer("Unable to find player \"$joiningPlayer\" in battle lobby");
    return 0;
  }
  if($#{$p_joiningPlayers} > 0) {
    answer("Ambiguous command, multiple matches found for player \"$joiningPlayer\" in battle lobby");
    return 0;
  }
  $joiningPlayer=$p_joiningPlayers->[0];
  if(exists $p_runningBattle->{users}{$joiningPlayer}) {
    answer("Player \"$joiningPlayer\" has already been added at start");
    return 0;
  }
  if(! defined $lobby->{battle}{users}{$joiningPlayer}{scriptPass}) {
    answer("Unable to add in-game player \"$joiningPlayer\", player didn't send script password");
    return 0;
  }
  if(exists $inGameAddedUsers{$joiningPlayer}) {
    answer("Player \"$joiningPlayer\" has already been added in game");
    return 0;
  }

  if($joinedEntity eq 'spec') {
    return ['joinAs','spec',$joiningPlayer] if($checkOnly);
    $inGameAddedUsers{$joiningPlayer}=$lobby->{battle}{users}{$joiningPlayer}{scriptPass};
    my $joinMsg="Adding user $joiningPlayer as spectator";
    $joinMsg.= " (by $user)" if($user ne $joiningPlayer);
    sayBattle($joinMsg);
    $autohost->sendChatMessage("/adduser $joiningPlayer $inGameAddedUsers{$joiningPlayer}");
    return ['joinAs','spec',$joiningPlayer];
  }elsif($joinedEntity =~ /^\#(\d+)$/) {
    my $joinedId=$1;
    if(! exists $runningBattleReversedMapping{teams}{$joinedId}) {
      answer("Unable to add in-game player in ID $joinedId (invalid in-game ID, use !status to check in-game IDs)");
      return 0;
    }
    return ['joinAs',$joinedEntity,$joiningPlayer] if($checkOnly);
    $inGameAddedPlayers{$joiningPlayer}=$joinedId;
    $inGameAddedUsers{$joiningPlayer}=$lobby->{battle}{users}{$joiningPlayer}{scriptPass};
    my $joinMsg="Adding player $joiningPlayer in ID $joinedId";
    $joinMsg.=" (by $user)" if($user ne $joiningPlayer);
    sayBattleAndGame($joinMsg);
    $autohost->sendChatMessage("/adduser $joiningPlayer $inGameAddedUsers{$joiningPlayer} 0 $joinedId");
    return ['joinAs',$joinedEntity,$joiningPlayer];
  }else{
    my @inGamePlayers=(keys %{$p_runningBattle->{users}},keys %inGameAddedPlayers);
    my $p_joinedPlayers=cleverSearch($joinedEntity,\@inGamePlayers);
    my $isBot=0;
    if(! @{$p_joinedPlayers}) {
      $isBot=1;
      my @bots=keys %{$p_runningBattle->{bots}};
      $p_joinedPlayers=cleverSearch($joinedEntity,\@bots);
      if(! @{$p_joinedPlayers}) {
        answer("Unable to find player \"$joinedEntity\" in game");
        return 0;
      }
    }
    if($#{$p_joinedPlayers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$joinedEntity\" in game");
      return 0;
    }
    $joinedEntity=$p_joinedPlayers->[0];
    my $joinedId;
    if($isBot) {
      $joinedId=$runningBattleMapping{teams}{$p_runningBattle->{bots}{$joinedEntity}{battleStatus}{id}};
    }else{
      if(exists $p_runningBattle->{users}{$joinedEntity}) {
        if(defined $p_runningBattle->{users}{$joinedEntity}{battleStatus} && $p_runningBattle->{users}{$joinedEntity}{battleStatus}{mode}) {
          $joinedId=$runningBattleMapping{teams}{$p_runningBattle->{users}{$joinedEntity}{battleStatus}{id}};
        }else{
          answer("Player \"$joinedEntity\" is a spectator, use \"!joinAs spec\" if you want to add in-game spectators");
          return 0;
        }
      }else{
        $joinedId=$inGameAddedPlayers{$joinedEntity};
      }
    }
    return ['joinAs',$joinedEntity,$joiningPlayer] if($checkOnly);
    $inGameAddedPlayers{$joiningPlayer}=$joinedId;
    $inGameAddedUsers{$joiningPlayer}=$lobby->{battle}{users}{$joiningPlayer}{scriptPass};
    my $joinMsg="Adding player $joiningPlayer in ID $joinedId";
    $joinMsg.=" (by $user)" if($user ne $joiningPlayer);
    sayBattleAndGame($joinMsg);
    $autohost->sendChatMessage("/adduser $joiningPlayer $inGameAddedUsers{$joiningPlayer} 0 $joinedId");
    return ['joinAs',$joinedEntity,$joiningPlayer];
  }
}

sub hKick {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($source eq "battle") {
    return hBKick($source,$user,$p_params,$checkOnly);
  }elsif($source eq "chan") {
    return hCKick($source,$user,$p_params,$checkOnly);
  }elsif($source eq "game") {
    return hGKick($source,$user,$p_params,$checkOnly);
  }else{
    answer("Command !kick cannot be used in private (use !bKick, !cKick, or !gKick)");
    return 0;
  }
}

sub hKickBan {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"kickban");
    return 0;
  }

  my $p_kickBannedUsers=[];
  if($autohost->getState()) {
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my @players=keys %{$p_ahPlayers};
    $p_kickBannedUsers=cleverSearch($p_params->[0],\@players);
    if($#{$p_kickBannedUsers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$p_params->[0]\" in game");
      return 0;
    }
  }
  if(! @{$p_kickBannedUsers} && $lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}}) {
    my @players=keys(%{$lobby->{battle}{users}});
    $p_kickBannedUsers=cleverSearch($p_params->[0],\@players);
    if($#{$p_kickBannedUsers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$p_params->[0]\" in battle lobby");
      return 0;
    }
  }
  if(! @{$p_kickBannedUsers}) {
    my @players=keys(%{$lobby->{users}});
    $p_kickBannedUsers=cleverSearch($p_params->[0],\@players);
    if(! @{$p_kickBannedUsers}) {
      answer("Unable to kick-ban \"$p_params->[0]\", user not found");
      return 0;
    }elsif($#{$p_kickBannedUsers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$p_params->[0]\" in lobby");
      return 0;
    }
  }
  my $bannedUser=$p_kickBannedUsers->[0];

  if($bannedUser eq $conf{lobbyLogin}) {
    answer("Nice try ;)");
    return 0;
  }

  my $bannedUserLevel=getUserAccessLevel($bannedUser);
  my $p_endVoteLevels=$spads->getCommandLevels("endvote","battle","player","stopped");
  if(exists $p_endVoteLevels->{directLevel} && $bannedUserLevel >= $p_endVoteLevels->{directLevel}) {
    answer("Unable to kick-ban privileged user $bannedUser");
    return 0;
  }

  return ['kickBan',$bannedUser] if($checkOnly);

  if($autohost->getState()) {
    my $p_ahPlayers=$autohost->getPlayersByNames();
    if(exists $p_ahPlayers->{$bannedUser} && %{$p_ahPlayers->{$bannedUser}} && $p_ahPlayers->{$bannedUser}{disconnectCause} == -1) {
      $autohost->sendChatMessage("/kickbynum $p_ahPlayers->{$bannedUser}{playerNb}");
    }
  }

  if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}}) {
    if(exists $lobby->{battle}{users}{$bannedUser}) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }
  }

  my $p_user={name => $bannedUser};
  my $accountId=getLatestUserAccountId($bannedUser);
  $p_user={accountId => "$accountId($bannedUser)"} if($accountId =~ /^\d+$/);
  my $p_ban={banType => 1,
             startDate => time,
             reason => "temporary kick-ban by $user"};
  if($conf{kickBanDuration} =~ /^(\d+)g/) {
    $p_ban->{remainingGames}=$1;
  }else{
    $p_ban->{endDate}=time + $conf{kickBanDuration};
  }
  $spads->banUser($p_user,$p_ban);
  my $kickBanDuration;
  if(exists $p_ban->{remainingGames}) {
    $kickBanDuration="$p_ban->{remainingGames} game".($p_ban->{remainingGames} > 1 ? 's' : '');
  }else{
    $kickBanDuration=secToTime($conf{kickBanDuration});
  }
  broadcastMsg("Battle ban added for user \"$bannedUser\" (duration: $kickBanDuration, reason: temporary kick-ban by $user)");
  return ['kickBan',$bannedUser];
}

sub hLearnMaps {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 1) {
    invalidSyntax($user,"learnmaps");
    return 0;
  }

  if($lobbyState < LOBBY_STATE_SYNCHRONIZED) {
    answer("Unable to learn map hashes: not connected to lobby");
    return 0;
  }

  my ($mapFilter,$hostFilter)=@{$p_params};
  $mapFilter//='';
  $mapFilter='' if($mapFilter eq '.');
  $hostFilter//='';

  my %seenMaps;
  foreach my $bId (keys %{$lobby->{battles}}) {
    my $founder=$lobby->{battles}{$bId}{founder};
    my $map=$lobby->{battles}{$bId}{map};
    if(($mapFilter eq '' || index(lc($map),lc($mapFilter)) > -1)
       && ($hostFilter eq '' || index(lc($founder),lc($hostFilter)) > -1)
       && $founder ne $conf{lobbyLogin} && $lobby->{battles}{$bId}{mapHash} != 0) {
      my ($engineName,$engineVersion)=($lobby->{battles}{$bId}{engineName},$lobby->{battles}{$bId}{engineVersion});
      my $quotedVer=quotemeta($syncedSpringVersion);
      if($engineName !~ /^spring$/i || $engineVersion !~ /^$quotedVer(\..*)?$/) {
        slog("Ignoring battle $bId for learnMaps (different game engine: \"$engineName $engineVersion\")",5);
        next;
      }
      if(exists $seenMaps{$map} && $seenMaps{$map} ne $lobby->{battles}{$bId}{mapHash}) {
        slog("Map \"$map\" has been seen with different hashes ($seenMaps{$map} and $lobby->{battles}{$bId}{mapHash}) during map hash learning",2);
      }else{
        $seenMaps{$map}=$lobby->{battles}{$bId}{mapHash};
      }
    }
  }

  if(! %seenMaps) {
    my $filterString="";
    $filterString=" matching map filter \"$mapFilter\"" if($mapFilter);
    $filterString.=" and host filter \"$hostFilter\"" if($hostFilter);
    answer("Unable to find new maps$filterString in currently hosted maps");
    return 0;
  }

  return 1 if($checkOnly);

  foreach my $map (keys %seenMaps) {
    $spads->saveMapHash($map,$syncedSpringVersion,$seenMaps{$map});
  }
  $timestamps{mapLearned}=0;
  $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  
  my @addedMaps=keys %seenMaps;
  my $addedMapsString=join(",",@addedMaps);
  if(length($addedMapsString) > 500) {
    answer(($#addedMaps+1)." maps (re)learned");
  }else{
    answer("Following map(s) (re)learned: $addedMapsString");
  }

  return 1;
}

sub getVoteSettings {
  my @globalVoteSettingNames=(qw'autoSetVoteMode awayVoteDelay majorityVoteMargin minVoteParticipation reCallVoteDelay voteTime');
  my @specificVoteSettingNames=(qw'awayVoteDelay majorityVoteMargin minVoteParticipation voteTime');
  
  my %globalVoteSettings;
  map {$globalVoteSettings{$_}=$conf{$_}} @globalVoteSettingNames;
  
  my %specificVoteSettings;
  foreach my $spadsCmd (keys %{$spads->{commandsAttributes}}) {
    map {$specificVoteSettings{$spadsCmd}{$_}=$spads->{commandsAttributes}{$spadsCmd}{$_} if(exists $spads->{commandsAttributes}{$spadsCmd}{$_})} @specificVoteSettingNames;
  }
  foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
    my $r_pluginCmdAttribs=$spads->{pluginsConf}{$pluginName}{commandsAttributes};
    foreach my $pluginCmd (keys %{$r_pluginCmdAttribs}) {
      next if(exists $specificVoteSettings{$pluginCmd});
      map {$specificVoteSettings{$pluginCmd}{$_}=$r_pluginCmdAttribs->{$pluginCmd}{$_} if(exists $r_pluginCmdAttribs->{$pluginCmd}{$_})} @specificVoteSettingNames;
    }
  }

  return {global => \%globalVoteSettings,
          specific => \%specificVoteSettings};
}

sub hList {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 0) {
    invalidSyntax($user,'list');
    return 0;
  }
  
  my ($data,@filters)=@{$p_params};

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $lcData=lc($data);
  if($lcData eq 'users') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    my %filtersNames=(accountId => "AccountId",
                      name => "Name",
                      country => "Country",
                      cpu => "CPU",
                      rank => "Rank",
                      access => "LobbyMod",
                      bot => "Bot",
                      auth => "Auth");
    my @users=@{$spads->{users}};
    my @usersData;
    my %fields;
    foreach my $p_userData (@users) {
      my %userFilters=%{$p_userData->[0]};
      my %userLevel=%{$p_userData->[1]};
      my %userData;
      foreach my $field (sort keys %userFilters) {
        $userData{$C{5}.$filtersNames{$field}}=$userFilters{$field};
        $fields{$C{5}.$filtersNames{$field}}=1 if($userFilters{$field} ne "");
      }
      if(%userLevel) {
        $userData{"$C{1}-->  $C{5}Level"}="$C{1}-->  $C{3}".$spads->getLevelDescription($userLevel{level})." ($C{12}$userLevel{level}$C{3})";
      }else{
        $userData{"$C{1}-->  $C{5}Level"}="$C{1}-->  $C{3}".$spads->getLevelDescription(0)." ($C{12}0$C{3})";
      }
      push(@usersData,\%userData);
    }
    my @resultFields=((keys %fields),"$C{1}-->  $C{5}Level");
    my $p_resultLines=formatArray(\@resultFields,\@usersData);
    foreach my $resultLine (@{$p_resultLines}) {
      sayPrivate($user,$resultLine);
    }
  }elsif($lcData eq 'presets') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    sayPrivate($user,"$B********** AutoHost global presets **********");
    foreach my $preset (sort keys %{$spads->{presets}}) {
      next unless($preset);
      next if($preset =~ /\.smf$/ && $conf{hideMapPresets});
      my $presetString="    $C{14}";
      if($preset eq $conf{preset}) {
        $presetString="[*] $C{12}";
      }elsif(any {$preset eq $_} @{$spads->{values}{preset}}) {
        $presetString = (exists $spads->{presetsAttributes}{$preset} && $spads->{presetsAttributes}{$preset}{transparent}) ? ' o  ' : '[ ] ';
      }
      $presetString.=$B if($preset eq $conf{defaultPreset});
      $presetString.=$preset;
      $presetString.=" ($spads->{presets}{$preset}{description}[0])" if(exists $spads->{presets}{$preset}{description});
      $presetString.=" $B*** DEFAULT ***" if($preset eq $conf{defaultPreset});
      sayPrivate($user,'| '.$presetString);
    }
    sayPrivate($user,"  --> Use \"$C{3}!preset <presetName>$C{1}\" to change current global preset.");
  }elsif($lcData eq 'bpresets') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    sayPrivate($user,"$B********** Available battle presets **********");
    foreach my $bPreset (sort keys %{$spads->{bPresets}}) {
      next unless($bPreset);
      my $presetString="    $C{14}";
      if($bPreset eq $conf{battlePreset}) {
        $presetString="[*] $C{12}";
      }elsif(any {$bPreset eq $_} @{$spads->{values}{battlePreset}}) {
        $presetString = (exists $spads->{bPresetsAttributes}{$bPreset} && $spads->{bPresetsAttributes}{$bPreset}{transparent}) ? ' o  ' : '[ ] ';
      }
      $presetString.=$bPreset;
      $presetString.=" ($spads->{bPresets}{$bPreset}{description}[0])" if(exists $spads->{bPresets}{$bPreset}{description});
      sayPrivate($user,'| '.$presetString);
    }
    sayPrivate($user,"  --> Use \"$C{3}!bPreset <presetName>$C{1}\" to change current battle preset.");
  }elsif($lcData eq 'hpresets') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    sayPrivate($user,"$B********** Available hosting presets **********");
    foreach my $hPreset (sort keys %{$spads->{hPresets}}) {
      next unless($hPreset);
      my $presetString="    $C{14}";
      if($hPreset eq $conf{hostingPreset}) {
        $presetString="[*] $C{12}";
      }elsif(any {$hPreset eq $_} @{$spads->{values}{hostingPreset}}) {
        $presetString = (exists $spads->{hPresetsAttributes}{$hPreset} && $spads->{hPresetsAttributes}{$hPreset}{transparent}) ? ' o  ' : '[ ] ';
      }
      $presetString.=$hPreset;
      $presetString.=" ($spads->{hPresets}{$hPreset}{description}[0])" if(exists $spads->{hPresets}{$hPreset}{description});
      sayPrivate($user,'| '.$presetString);
    }
    sayPrivate($user,"  --> Use \"$C{3}!hPreset <presetName>$C{1}\" to change current hosting preset.");
  }elsif($lcData eq 'plugins') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    if(! @pluginsOrder) {
      answer("No plugin loaded.");
      return 1;
    }
    sayPrivate($user,"$B********** Currently loaded plugins **********");
    foreach my $pluginName (@pluginsOrder) {
      my $pluginVersion=$plugins{$pluginName}->getVersion();
      sayPrivate($user,"  $C{3}$pluginName$C{1} (version $C{10}$pluginVersion$C{1})");
    }
  }elsif($lcData eq 'psettings') {
    return 1 if($checkOnly);
    my $filterUnmodifiableSettings=1;
    if(@filters) {
      $filterUnmodifiableSettings=0;
      @filters=() if($#filters == 0 && lc($filters[0]) eq 'all');
    }
    my @settingsData;
    foreach my $pluginName (sort keys %{$spads->{pluginsConf}}) {
      my $p_values=$spads->{pluginsConf}{$pluginName}{values};
      foreach my $setting (sort keys %{$p_values}) {
        next if($HIDDEN_PLUGIN_SETTINGS{$setting});
        next if($filterUnmodifiableSettings && $#{$p_values->{$setting}} < 1);
        next unless(all {index(lc("$pluginName $setting"),lc($_)) > -1} @filters);
        my $allowedValues=join(" | ",@{$p_values->{$setting}});
        my $currentVal=$spads->{pluginsConf}{$pluginName}{conf}{$setting};
        my ($coloredSetting,$coloredValue)=($setting,$currentVal);
        if($#{$p_values->{$setting}} < 1) {
          $coloredSetting=$C{14}.$setting;
        }else{
          if($currentVal ne $p_values->{$setting}[0]) {
            $coloredValue=$C{4}.$currentVal.$C{1};
          }else{
            $coloredValue=$C{12}.$currentVal.$C{1};
          }
          $allowedValues="$C{10}$1$C{1}$2" if($allowedValues =~ /^([^|]+)((?: | .*)?)$/);
        }
        push(@settingsData,{"$C{5}Name$C{1}" => $coloredSetting,
                            "$C{5}Plugin$C{1}" => $pluginName,
                            "$C{5}Current value$C{1}" => $coloredValue,
                            "$C{5}Allowed values$C{1}" => $allowedValues});
      }
    }
    if(@settingsData) {
      my $p_resultLines=formatArray(["$C{5}Name$C{1}","$C{5}Plugin$C{1}","$C{5}Current value$C{1}","$C{5}Allowed values$C{1}"],\@settingsData,undef,50);
      foreach my $resultLine (@{$p_resultLines}) {
        sayPrivate($user,$resultLine);
      }
      sayPrivate($user,"  --> Use \"$C{3}!plugin <pluginName> set <settingName> <value>$C{1}\" to change the value of a plugin setting.");
      sayPrivate($user,"  --> Use \"$C{3}!list pSettings all$C{1}\" to list all plugin settings.") if($filterUnmodifiableSettings);
    }else{
      if(@filters) {
        sayPrivate($user,"No plugin setting found matching filter \"$C{12}".(join(' ',@filters))."$C{1}\".");
      }elsif($filterUnmodifiableSettings) {
        sayPrivate($user,"No modifiable plugin setting found.");
        sayPrivate($user,"  --> Use \"$C{3}!list pSettings all$C{1}\" to list all plugin settings.");
      }else{
        sayPrivate($user,"No plugin setting found.");
      }
    }
  }elsif($lcData eq 'settings') {
    return 1 if($checkOnly);
    my $filterUnmodifiableSettings=1;
    if(@filters) {
      $filterUnmodifiableSettings=0;
      @filters=() if($#filters == 0 && lc($filters[0]) eq 'all');
    }
    my @settingsData;
    foreach my $setting (sort keys %{$spads->{values}}) {
      next if($HIDDEN_PRESET_SETTINGS{$setting});
      next if($filterUnmodifiableSettings && $#{$spads->{values}{$setting}} < 1 && $setting ne 'map');
      next unless(all {index(lc($setting),lc($_)) > -1} @filters);
      my $allowedValues=join(" | ",@{$spads->{values}{$setting}});
      my ($coloredSetting,$coloredValue)=($setting,$conf{$setting});
      if($#{$spads->{values}{$setting}} < 1 && $setting ne 'map') {
        $coloredSetting=$C{14}.$setting;
      }else{
        if($conf{$setting} ne $spads->{values}{$setting}[0]) {
          $coloredValue=$C{4}.$conf{$setting}.$C{1};
        }else{
          $coloredValue=$C{12}.$conf{$setting}.$C{1};
        }
        $allowedValues="$C{10}$1$C{1}$2" if($allowedValues =~ /^([^|]+)((?: | .*)?)$/);
        $allowedValues="(use \"$C{3}!list maps$C{1}\")" if($setting eq "map");
      }
      push(@settingsData,{"$C{5}Name$C{1}" => $coloredSetting,
                          "$C{5}Current value$C{1}" => $coloredValue,
                          "$C{5}Allowed values$C{1}" => $allowedValues});
    }
    if(@settingsData) {
      my $p_resultLines=formatArray(["$C{5}Name$C{1}","$C{5}Current value$C{1}","$C{5}Allowed values$C{1}"],\@settingsData,undef,50);
      foreach my $resultLine (@{$p_resultLines}) {
        sayPrivate($user,$resultLine);
      }
      sayPrivate($user,"  --> Use \"$C{3}!help set <settingName>$C{1}\" for help about a setting.");
      sayPrivate($user,"  --> Use \"$C{3}!set <settingName> <value>$C{1}\" to change the value of a setting.");
      sayPrivate($user,"  --> Use \"$C{3}!list settings all$C{1}\" to list all global settings.") if($filterUnmodifiableSettings);
    }else{
      if(@filters) {
        sayPrivate($user,"No global setting found matching filter \"$C{12}".(join(' ',@filters))."$C{1}\".");
      }elsif($filterUnmodifiableSettings) {
        sayPrivate($user,"No modifiable global setting found.");
        sayPrivate($user,"  --> Use \"$C{3}!list settings all$C{1}\" to list all global settings.");
      }else{
        sayPrivate($user,"No global setting found.");
      }
    }
  }elsif($lcData eq 'bsettings') {
    return 1 if($checkOnly);
    my ($filterUnmodifiableSettings,$filterMapSettings,$filterModSettings,$filterEngineSettings)=(1,0,0,0);
    my $settingTypeFilterString='';
    if(@filters) {
      if(lc($filters[0]) eq 'map') {
        $settingTypeFilterString=' map';
        ($filterModSettings,$filterEngineSettings)=(1,1);
        shift(@filters);
      }elsif(lc($filters[0]) eq 'mod') {
        $settingTypeFilterString=' mod';
        ($filterMapSettings,$filterEngineSettings)=(1,1);
        shift(@filters);
      }elsif(lc($filters[0]) eq 'engine') {
        $settingTypeFilterString=' engine';
        ($filterModSettings,$filterMapSettings)=(1,1);
        shift(@filters);
      }
    }
    if(@filters) {
      $filterUnmodifiableSettings=0;
      @filters=() if($#filters == 0 && lc($filters[0]) eq 'all');
    }
    my $modName = $lobbyState >= LOBBY_STATE_BATTLE_OPENED ? $lobby->{battles}{$lobby->{battle}{battleId}}{mod} : $targetMod;
    my $p_modOptions=getModOptions($modName);
    my $p_mapOptions=getMapOptions($currentMap);
    my @bSettings;
    push(@bSettings,'startpostype') unless($filterEngineSettings);
    push(@bSettings,keys %{$p_modOptions}) unless($filterModSettings);
    push(@bSettings,keys %{$p_mapOptions}) unless($filterMapSettings);
    my @settingsData;
    foreach my $setting (sort @bSettings) {
      next unless(all {index(lc($setting),lc($_)) > -1} @filters);
      my $p_options={};
      my $optionScope="$C{13}engine$C{1}";
      my $allowExternalValues=0;
      if(exists $p_modOptions->{$setting}) {
        $optionScope='mod';
        $p_options=$p_modOptions;
        $allowExternalValues=$conf{allowModOptionsValues};
      }elsif(exists $p_mapOptions->{$setting}) {
        $optionScope="$C{7}map$C{1}";
        $p_options=$p_mapOptions;
        $allowExternalValues=$conf{allowMapOptionsValues};
      }
      my @allowedValues=getBSettingAllowedValues($setting,$p_options,$allowExternalValues);
      next if($filterUnmodifiableSettings && (! @allowedValues || ($#allowedValues == 0 && ! isRange($allowedValues[0]))));
      my $currentValue;
      if(exists $spads->{bSettings}{$setting}) {
        $currentValue=$spads->{bSettings}{$setting};
      }else{
        $currentValue=$p_options->{$setting}{default};
      }
      my ($coloredName,$coloredValue)=($setting,$currentValue);
      if(! @allowedValues || ($#allowedValues == 0 && ! isRange($allowedValues[0]))) {
        $coloredName=$C{14}.$setting;
      }else{
        $coloredValue=$C{12}.$coloredValue.$C{1};
      } 
      push(@settingsData,{"$C{5}Name$C{1}" => $coloredName,
                          "$C{5}Scope$C{1}" => $optionScope,
                          "$C{5}Current value$C{1}" => $coloredValue,
                          "$C{5}Allowed values$C{1}" => join(" | ",@allowedValues)});
    }
    if(@settingsData) {
      my $p_resultLines=formatArray(["$C{5}Name$C{1}","$C{5}Scope$C{1}","$C{5}Current value$C{1}","$C{5}Allowed values$C{1}"],\@settingsData,undef,50);
      foreach my $resultLine (@{$p_resultLines}) {
        sayPrivate($user,$resultLine);
      }
      sayPrivate($user,"  --> Use \"$C{3}!help bSet <settingName>$C{1}\" for help about a battle setting.");
      sayPrivate($user,"  --> Use \"$C{3}!bSet <settingName> <value>$C{1}\" to change the value of a battle setting.");
      sayPrivate($user,"  --> Use \"$C{3}!list bSettings$settingTypeFilterString all$C{1}\" to list all$settingTypeFilterString battle settings.") if($filterUnmodifiableSettings);
    }else{
      if(@filters) {
        sayPrivate($user,"No$settingTypeFilterString battle setting found matching filter \"$C{12}".(join(' ',@filters))."$C{1}\".");
      }elsif($filterUnmodifiableSettings) {
        sayPrivate($user,"No modifiable$settingTypeFilterString battle setting found.");
        sayPrivate($user,"  --> Use \"$C{3}!list bSettings$settingTypeFilterString all$C{1}\" to list all$settingTypeFilterString battle settings.");
      }else{
        sayPrivate($user,"No$settingTypeFilterString battle setting found.");
      }
    }
  }elsif($lcData eq 'hsettings') {
    return 1 if($checkOnly);
    my $filterUnmodifiableSettings=1;
    if(@filters) {
      $filterUnmodifiableSettings=0;
      @filters=() if($#filters == 0 && lc($filters[0]) eq 'all');
    }
    my @settingsData;
    foreach my $setting (sort keys %{$spads->{hValues}}) {
      next if($HIDDEN_HOSTING_SETTINGS{$setting});
      next if($filterUnmodifiableSettings && $#{$spads->{hValues}{$setting}} < 1);
      next unless(all {index(lc($setting),lc($_)) > -1} @filters);
      if($setting eq 'password') {
        push(@settingsData,{"$C{5}Name$C{1}" => ($#{$spads->{hValues}{password}} < 1 ? $C{14} : '').'password',
                            "$C{5}Current value$C{1}" => '<hidden>',
                            "$C{5}Allowed values$C{1}" => '<hidden>'});
      }else{
        my $settingValue=$spads->{hSettings}{$setting};
        $settingValue=$targetMod if($setting eq 'modName' && $targetMod ne '');
        my $allowedValues=join(" | ",@{$spads->{hValues}{$setting}});
        my ($coloredSetting,$coloredValue)=($setting,$settingValue);
        if($#{$spads->{hValues}{$setting}} < 1) {
          $coloredSetting=$C{14}.$setting;
        }else{
          if($settingValue ne $spads->{hValues}{$setting}[0] && $setting ne 'modName') {
            $coloredValue=$C{4}.$settingValue.$C{1};
          }else{
            $coloredValue=$C{12}.$settingValue.$C{1};
          }
          $allowedValues="$C{10}$1$C{1}$2" if($allowedValues =~ /^([^|]+)((?: | .*)?)$/);
        }
        push(@settingsData,{"$C{5}Name$C{1}" => $coloredSetting,
                            "$C{5}Current value$C{1}" => $coloredValue,
                            "$C{5}Allowed values$C{1}" => $allowedValues});
      }
    }
    if(@settingsData) {
      my $p_resultLines=formatArray(["$C{5}Name$C{1}","$C{5}Current value$C{1}","$C{5}Allowed values$C{1}"],\@settingsData,undef,50);
      foreach my $resultLine (@{$p_resultLines}) {
        sayPrivate($user,$resultLine);
      }
      sayPrivate($user,"  --> Use \"$C{3}!help hSet <settingName>$C{1}\" for help about a hosting setting.");
      sayPrivate($user,"  --> Use \"$C{3}!hSet <settingName> <value>$C{1}\" to change the value of a hosting setting.");
      sayPrivate($user,"  --> Use \"$C{3}!list hSettings all$C{1}\" to list all hosting settings.") if($filterUnmodifiableSettings);
    }else{
      if(@filters) {
        sayPrivate($user,"No hosting setting found matching filter \"$C{12}".(join(' ',@filters))."$C{1}\".");
      }elsif($filterUnmodifiableSettings) {
        sayPrivate($user,"No modifiable hosting setting found.");
        sayPrivate($user,"  --> Use \"$C{3}!list hSettings all$C{1}\" to list all hosting settings.");
      }else{
        sayPrivate($user,"No hosting setting found.");
      }
    }
  }elsif($lcData eq 'vsettings') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    my @settingsData;
    my $r_voteSettings=getVoteSettings();
    map {push(@settingsData,{"$C{5}Setting$C{1}" => $_, "$C{5}Value$C{1}" => $r_voteSettings->{global}{$_}})} (sort keys %{$r_voteSettings->{global}});
    sayPrivate($user,'.');
    my $p_resultLines=formatArray(["$C{5}Setting$C{1}","$C{5}Value$C{1}"],\@settingsData,"$C{2}Global vote settings$C{1}");
    foreach my $resultLine (@{$p_resultLines}) {
      sayPrivate($user,$resultLine);
    }
    if(%{$r_voteSettings->{specific}}) {
      @settingsData=();
      foreach my $cmd (sort keys %{$r_voteSettings->{specific}}) {
        map {push(@settingsData,{"$C{5}Command$C{1}" => $cmd, "$C{5}Setting$C{1}" => $_, "$C{5}Value$C{1}" => $r_voteSettings->{specific}{$cmd}{$_}})} (sort keys %{$r_voteSettings->{specific}{$cmd}});
      }
      sayPrivate($user,'.');
      $p_resultLines=formatArray(["$C{5}Command$C{1}","$C{5}Setting$C{1}","$C{5}Value$C{1}"],\@settingsData,"$C{2}Specific vote settings$C{1}");
      foreach my $resultLine (@{$p_resultLines}) {
        sayPrivate($user,$resultLine);
      }
    }
  }elsif($lcData eq 'aliases') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    my $p_cmdAliases=getCmdAliases();
    sayPrivate($user,"$B********** Available aliases **********");
    foreach my $alias (sort keys %{$p_cmdAliases}) {
      sayPrivate($user,"!$C{3}$alias$C{1} - !".(join(' ',@{$p_cmdAliases->{$alias}})));
    }
  }elsif($lcData eq 'bans') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    my $p_globalBans=$spads->{banLists}{""};
    my $p_specificBans=[];
    $p_specificBans=$spads->{banLists}{$conf{banList}} if($conf{banList});
    my $p_autoHandledBans=$spads->getDynamicBans();
    if(! @{$p_globalBans} && ! @{$p_specificBans} && ! @{$p_autoHandledBans}) {
      sayPrivate($user,"There is no ban entry currently");
    }else{
      my $userLevel=getUserAccessLevel($user);
      my $showIPs = $userLevel >= $conf{privacyTrustLevel};
      if(@{$p_globalBans}) {
        sayPrivate($user,"$B********** Global bans **********");
        my $p_banEntries=listBans($p_globalBans,$showIPs,$user);
        foreach my $banEntry (@{$p_banEntries}) {
          sayPrivate($user,$banEntry);
        }
      }
      if(@{$p_specificBans}) {
        sayPrivate($user,"$B********** Current banlist: $conf{banList} **********");
        my $p_banEntries=listBans($p_specificBans,$showIPs,$user);
        foreach my $banEntry (@{$p_banEntries}) {
          sayPrivate($user,$banEntry);
        }
      }
      if(@{$p_autoHandledBans}) {
        my $userCanUnban=0;
        my $p_unbanLevels=$spads->getCommandLevels('unban','battle','player','stopped');
        if(exists $p_unbanLevels->{directLevel} && $userLevel >= $p_unbanLevels->{directLevel}) {
          $userCanUnban=1;
        }else{
          $p_unbanLevels=$spads->getCommandLevels('unban','chan','player','stopped');
          $userCanUnban=1 if(exists $p_unbanLevels->{directLevel} && $userLevel >= $p_unbanLevels->{directLevel});
        }
        sayPrivate($user,"$B********** Dynamic bans **********");
        my $p_banEntries=listBans($p_autoHandledBans,$showIPs,$user,$userCanUnban);
        foreach my $banEntry (@{$p_banEntries}) {
          sayPrivate($user,$banEntry);
        }
        if($userCanUnban) {
          sayPrivate($user,"$B**********************************");
          sayPrivate($user,"  --> Dynamic bans can be removed by hash using \"$C{3}!unban (<hash>)$C{1}\".");
        }
      }
    }
  }elsif($lcData eq 'rotationmaps') {
    my $subMapList;
    if($conf{rotationType} =~ /;(.+)$/) {
      $subMapList=$1;
    }else{
      answer("There is no rotation map list enabled (all current maps are used for rotation).");
      return 0;
    }
    return 1 if($checkOnly);
    my $filterString="";
    if(@filters) {
      $filterString=join(" ",@filters);
      $filterString=" (filter: \"$C{12}$filterString$C{1}\")";
    }
    my $p_maps=$spads->applySubMapList($subMapList);
    my @results;
    push(@results,"$B********** Maps in current rotation map list \"$subMapList\"$filterString **********");
    foreach my $mapName (@{$p_maps}) {
      next unless(all {index(lc($mapName),lc($_)) > -1} @filters);
      $mapName=$1 if($mapName =~ /^(.*)\.smf$/);
      push(@results,"$C{10}$mapName");
    }
    if($#results > 200) {
      if(@filters) {
        sayPrivate($user,"Too many results ($C{4}$#results$C{1}), please use a filter string more specific than \"$C{12}".join(" ",@filters)."$C{1}\"");
      }else{
        sayPrivate($user,"Too many results ($C{4}$#results$C{1}), please use a filter string by using \"$C{3}!list rotationMaps <filter>$C{1}\" syntax");
      }
      return 1;
    }
    if($#results == 0) {
      if(@filters) {
        sayPrivate($user,"Unable to find any map matching filter \"$C{12}".join(" ",@filters)."$C{1}\" in current rotation map list");
      }else{
        sayPrivate($user,"No map found in current rotation map list");
      }
      return 1;
    }
    foreach my $result (@results) {
      sayPrivate($user,$result);
    }
    sayPrivate($user,"$B******************** End of rotation map list ********************");
  }elsif($lcData eq 'maps') {
    return 1 if($checkOnly);
    my $filterString="";
    if(@filters) {
      $filterString=join(" ",@filters);
      $filterString=" (filter: \"$C{12}$filterString$C{1}\")";
    }
    my @results;
    push(@results,"$B********** Available maps for current map list$filterString **********");
    my $outputHasLocalMap=0;
    foreach my $mapNb (sort {$a <=> $b} keys %{$spads->{maps}}) {
      my $mapName=$spads->{maps}{$mapNb};
      next unless(all {index(lc($mapName),lc($_)) > -1} @filters);
      $mapName=$1 if($mapName =~ /^(.*)\.smf$/);
      if(! $outputHasLocalMap) {        
        push(@results,"     $C{5}${B}[ Local maps ]") if($conf{allowGhostMaps} && $springServerType eq 'dedicated');
        $outputHasLocalMap=1;
      }
      push(@results,"$C{7}$mapNb$C{1}. $C{12}$mapName");
    }
    my $outputHasGhostMap=0;
    if($conf{allowGhostMaps} && $springServerType eq 'dedicated') {
      foreach my $mapName (sort keys %{$spads->{ghostMaps}}) {
        next unless(all {index(lc($mapName),lc($_)) > -1} @filters);
        $mapName=$1 if($mapName =~ /^(.*)\.smf$/);
        if(! $outputHasGhostMap) {
          push(@results,"     $C{5}${B}[ Ghost maps ]");
          $outputHasGhostMap=1;
        }
        push(@results,"$C{10}$mapName");
      }
    }
    if($#results > 200) {
      if(@filters) {
        sayPrivate($user,"Too many results ($C{4}$#results$C{1}), please use a filter string more specific than \"$C{12}".join(" ",@filters)."$C{1}\"");
      }else{
        sayPrivate($user,"Too many results ($C{4}$#results$C{1}), please use a filter string by using \"$C{3}!list maps <filter>$C{1}\" syntax");
      }
      return 1;
    }
    if($#results == 0) {
      if(@filters) {
        sayPrivate($user,"Unable to find any map matching filter \"$C{12}".join(" ",@filters)."$C{1}\"");
      }else{
        sayPrivate($user,"No map found");
      }
      return 1;
    }
    foreach my $result (@results) {
      sayPrivate($user,$result);
    }
    sayPrivate($user,"$B******************** End of map list ********************");
    sayPrivate($user,"  --> Only \"Choose in game\" start position type is available for ghost maps.") if($outputHasGhostMap);
    sayPrivate($user,"  --> Use \"$C{3}!map <mapName_OR_mapNumber>$C{1}\" to change current map.");
    sayPrivate($user,"  --> Use \"$C{3}!set mapList <mapListName>$C{1}\" to change current map list.");
  }elsif($lcData eq 'pref') {
    if(@filters) {
      invalidSyntax($user,'list');
      return 0;
    }
    return 1 if($checkOnly);
    my @prefData;
    my $aId=getLatestUserAccountId($user);
    my $p_prefs=$spads->getUserPrefs($aId,$user);
    foreach my $pref (sort keys %{$p_prefs}) {
      my $defaultValue="<undefined>";
      $defaultValue=$conf{$pref} if(exists $conf{$pref});
      my $userValue;
      if($pref eq "password") {
        $userValue="<hidden>";
      }else{
        $userValue=$p_prefs->{$pref};
      }
      my $effectiveValue;
      if($userValue eq "") {
        $effectiveValue=$C{10}.$defaultValue.$C{1};
      }else{
        if($userValue eq '<hidden>') {
          $userValue=$C{12}.$userValue.$C{1};
        }elsif($userValue eq $defaultValue) {
          $userValue=$C{12}.$defaultValue.$C{1};
        }else{
          $userValue=$C{4}.$userValue.$C{1};
        }
        $effectiveValue=$userValue;
      }
      $defaultValue=$C{10}.$defaultValue.$C{1};
      push(@prefData,{"$C{5}Name$C{1}" => $pref,
                      "$C{5}User value$C{1}" => $userValue,
                      "$C{5}Default value$C{1}" => $defaultValue,
                      "$C{5}Effective value$C{1}" => $effectiveValue});
    }
    my $p_resultLines=formatArray(["$C{5}Name$C{1}","$C{5}User value$C{1}","$C{5}Default value$C{1}","$C{5}Effective value$C{1}"],\@prefData,undef,50);
    foreach my $resultLine (@{$p_resultLines}) {
      sayPrivate($user,$resultLine);
    }
    sayPrivate($user,"  --> Use \"$C{3}!help pSet <preferenceName>$C{1}\" for help about a preference.");
    sayPrivate($user,"  --> Use \"$C{3}!pSet <preferenceName> <value>$C{1}\" to update your preferences.");
  }else{
    invalidSyntax($user,'list');
    return 0;
  }

}

sub hLoadBoxes {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer("Unable to load start boxes, battle lobby is closed");
    return 0;
  }
  if($spads->{bSettings}{startpostype} != 2) {
    answer("Unable to load start boxes, start position type must be set to \"Choose in game\" (\"!bSet startPosType 2\")");
    return 0;
  }

  my @params=shellwords($p_params->[0]//'');

  if($#params > 2) {
    invalidSyntax($user,"loadboxes");
    return 0;
  }

  my ($mapName,$nbTeams,$nbExtraBox)=@params;
  if(defined $mapName) {
    if(defined $nbTeams) {
      if($nbTeams !~ /^\d+$/) {
        invalidSyntax($user,"loadboxes");
        return 0;
      }
      if(defined $nbExtraBox) {
        if($nbExtraBox !~ /^\d+$/) {
          invalidSyntax($user,"loadboxes");
          return 0;
        }
      }else{
        $nbExtraBox=$conf{extraBox};
      }
    }else{
      $nbTeams=$conf{nbTeams};
      $nbExtraBox=$conf{extraBox};
    }
  }else{
    $mapName=$conf{map};
    $nbTeams=$conf{nbTeams};
    $nbExtraBox=$conf{extraBox};
  }

  my $smfMapName=$mapName;
  $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);

  my $p_boxes=$spads->getMapBoxes($smfMapName,$nbTeams,$nbExtraBox);
  if(! @{$p_boxes}) {
    my $p_savedBoxesMaps=$spads->getSavedBoxesMaps();
    my $p_matchingsSavedBoxesMaps=cleverSearch($smfMapName,$p_savedBoxesMaps);
    if(! @{$p_matchingsSavedBoxesMaps}) {
      $p_matchingsSavedBoxesMaps=cleverSearch($mapName,$p_savedBoxesMaps);
      if(! @{$p_matchingsSavedBoxesMaps}) {
        answer("Unable to find any saved start boxes for map \"$mapName\"");
        return 0;
      }
    }
    if($#{$p_matchingsSavedBoxesMaps} > 0) {
      answer("Ambiguous command, multiple matches found for map \"$mapName\"");
      return 0;
    }
    $smfMapName=$p_matchingsSavedBoxesMaps->[0];
    $p_boxes=$spads->getMapBoxes($smfMapName,$nbTeams,$nbExtraBox);
  }
  foreach my $pluginName (@pluginsOrder) {
    my $overwritten=$plugins{$pluginName}->setMapStartBoxes($p_boxes,$mapName,$nbTeams,$nbExtraBox) if($plugins{$pluginName}->can('setMapStartBoxes'));
    if(ref $overwritten) {
      my $r_newBoxes;
      ($overwritten,$r_newBoxes)=@{$overwritten};
      $p_boxes=$r_newBoxes if(ref $r_newBoxes eq 'ARRAY');
    }
    last if(defined $overwritten && $overwritten);
  }

  my $printedMapName;
  if($smfMapName =~ /^(.*)\.smf$/) {
    $printedMapName=$1;
  }else{
    $printedMapName=$smfMapName;
  }
  my $statusString="map \"$printedMapName\" with $nbTeams teams";
  if($nbExtraBox) {
    $statusString.=" and $nbExtraBox extra box";
    $statusString.='es' if($nbExtraBox > 1);
  }

  if(! @{$p_boxes}) {
    answer("Unable to find saved start boxes for $statusString");
    return 0;
  }

  return 1 if($checkOnly);

  foreach my $teamNb (keys %{$lobby->{battle}{startRects}}) {
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]);
  }

  my $boxId=0;
  foreach my $boxString (@{$p_boxes}) {
    $boxId+=applyMapBox($boxString,$boxId);
  }

  answer("Loaded boxes of $statusString");

}

sub hLock {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,"lock");
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to lock battle lobby, battle is closed");
    return 0;
  }
  if($conf{autoLock} ne "off") {
    answer("Cannot lock battle, autoLock is enabled");
    return 0;
  }
  if($manualLockedStatus) {
    answer("Cannot lock battle, it is already locked");
    return 0;
  }
  my @clients=keys %{$lobby->{battle}{users}};
  my $nbPlayers=$#clients+1-$currentNbNonPlayer;
  if($nbPlayers < $conf{minPlayers}) {
    answer("Cannot lock battle (minPlayers=$conf{minPlayers})");
    return 0;
  }

  return 1 if($checkOnly);
  $manualLockedStatus=1;
  $timestamps{battleChange}=time;
  updateBattleInfoIfNeeded();
}

sub hMapLink {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != -1) {
    invalidSyntax($user,"maplink");
    return 0;
  }

  return 1 if($checkOnly);

  my ($mapHash,$mapArchive)=getMapHashAndArchive($conf{map});

  my $mapLink;
  if($mapArchive eq '') {
    $mapLink=$conf{ghostMapLink};
  }elsif($conf{mapLink}) {
    $mapLink=$conf{mapLink};
    $mapArchive=~s/ /\%20/g;
    $mapLink=~s/\%M/$mapArchive/g;
  }
  if(! defined $mapLink || $mapLink eq '') {
    answer("Map link not available");
    return 0;
  }
  my $mapName=$conf{map};
  $mapName=$1 if($mapName =~ /^(.*)\.smf$/);
  $mapName=~s/ /\%20/g;
  $mapLink=~s/\%m/$mapName/g;
  $mapLink=~s/\%h/$mapHash/g;

  answer("Map link: $mapLink");
}

sub hNextMap {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != -1) {
    invalidSyntax($user,'nextmap');
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to rotate map, battle is closed");
    return 0;
  }
  return 1 if($checkOnly);

  rotateMap($conf{rotationManual},1);
}

sub hNextPreset {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != -1) {
    invalidSyntax($user,'nextpreset');
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to rotate preset, battle is closed");
    return 0;
  }
  return 1 if($checkOnly);

  rotatePreset($conf{rotationManual},1);
}

sub hNotify {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != -1) {
    invalidSyntax($user,"notify");
    return 0;
  }
  return 1 if($checkOnly);
  if(exists($pendingNotifications{$user})) {
    answer("End-game notification cancelled");
    delete $pendingNotifications{$user};
  }else{
    answer("End-game notification activated");
    $pendingNotifications{$user}=1;
  }
}

sub hOpenBattle {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,'openbattle');
    return 0;
  }
  
  if(! $closeBattleAfterGame) {
    my $msg='Unable to open battle lobby';
    if($lobbyState >= LOBBY_STATE_BATTLE_OPENED) {
      $msg='Battle lobby is already opened';
    }elsif($lobbyState == LOBBY_STATE_OPENING_BATTLE) {
      $msg='Opening of the battle lobby is already in progress';
    }elsif($lobbyState < LOBBY_STATE_SYNCHRONIZED) {
      $msg.=', lobby connection is not synchronized yet';
    }elsif($targetMod eq '') {
      $msg.=", no game archive found matching \"$spads->{hSettings}{modName}\"";
      $msg.=' (archives are currently being reloaded)' if($loadArchivesInProgress);
    }
    answer($msg);
    return 0;
  }
  return 1 if($checkOnly);
  
  my %sourceNames = ( pv => 'private',
                      chan => "channel #$masterChannel",
                      game => 'game',
                      battle => 'battle lobby' );

  cancelCloseBattleAfterGame("requested by $user in $sourceNames{$source}");
  if($targetMod eq '') {
    my $msg="No game archive found matching \"$spads->{hSettings}{modName}\"";
    $msg.=' (archives are currently being reloaded)' if($loadArchivesInProgress);
    answer($msg);
  }
}

sub hPlugin {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my ($pluginName,$action,$param,$val)=@{$p_params};
  if(! defined $action) {
    invalidSyntax($user,'plugin');
    return 0;
  }

  if($pluginName !~ /^\w+$/) {
    invalidSyntax($user,'plugin','wrong plugin name format');
    return 0;
  }
  
  my $actionIsAllowed=0;
  foreach my $allowedAction (qw'load unload reload reloadConf set') {
    if(lc($action) eq lc($allowedAction)) {
      $action=$allowedAction;
      $actionIsAllowed=1;
    }
  }
  if(! $actionIsAllowed) {
    invalidSyntax($user,'plugin');
    return 0;
  }

  if($action eq 'load') {
    if(exists $plugins{$pluginName}) {
      answer("Plugin $pluginName is already loaded, use \"!plugin $pluginName reload\" if you want to reload it.");
      return 0;
    }
    return 1 if($checkOnly);
    my $loadRes=loadPlugin($pluginName,'load');
    if($loadRes) {
      answer("Loaded plugin $pluginName.");
      return 1;
    }
    answer("Failed to load plugin $pluginName (plugin names are case sensitive).");
    return 0;
  }
  if(! exists $plugins{$pluginName}) {
    answer("Plugin $pluginName is not loaded, use \"!list plugins\" to check currently loaded plugins.");
    return 0;
  }
  if($action eq 'unload') {
    return 1 if($checkOnly);
    my $p_unloadedPlugins=unloadPlugin($pluginName,'unload');
    answer('Unloaded plugin'.($#{$p_unloadedPlugins} > 0 ? 's ' : ' ').(join(',',@{$p_unloadedPlugins})).'.');
    return 1;
  }
  if($action eq 'reload') {
    return 1 if($checkOnly);
    my ($p_reloadedPlugins,$failedPlugin,$p_notReloadedPlugins)=reloadPlugin($pluginName);
    if(defined $failedPlugin) {
      if($failedPlugin eq $pluginName) {
        answer("Failed to reload plugin $pluginName.");
      }else{
        answer("Error while reloading plugin $pluginName: failed to reload dependent plugin $failedPlugin.");
      }
      answer('Following plugin'.($#{$p_reloadedPlugins} > 0 ? 's have' : ' has').' been reloaded: '.(join(',',@{$p_reloadedPlugins}))) if(@{$p_reloadedPlugins});
      answer('Following dependent plugin'.($#{$p_notReloadedPlugins} > 0 ? 's have' : ' has').' been unloaded: '.(join(',',@{$p_notReloadedPlugins}))) if(@{$p_notReloadedPlugins});
      return 0;
    }
    answer('Reloaded plugin'.($#{$p_reloadedPlugins} > 0 ? 's ' : ' ').(join(',',@{$p_reloadedPlugins})).'.');
    return 1;
  }
  if($action eq 'reloadConf') {
    my $keepSettings;
    if(defined $param) {
      if(lc($param) ne 'keepsettings') {
        invalidSyntax($user,'plugin');
        return 0;
      }
      $keepSettings=1;
    }else{
      $keepSettings=0;
    }
    return 1 if($checkOnly);
    my $p_previousPluginConf=$spads->{pluginsConf}{$pluginName};
    if(! $spads->loadPluginConf($pluginName)) {
      answer("Failed to reload $pluginName plugin configuration.");
      return 0;
    }
    $spads->applyPluginPreset($pluginName,$conf{defaultPreset});
    $spads->applyPluginPreset($pluginName,$conf{preset}) unless($conf{preset} eq $conf{defaultPreset});
    $spads->{pluginsConf}{$pluginName}{conf}=$p_previousPluginConf->{conf} if(exists $spads->{pluginsConf}{$pluginName} && $keepSettings && defined $p_previousPluginConf);
    if($plugins{$pluginName}->can('onReloadConf')) {
      my $reloadConfRes=$plugins{$pluginName}->onReloadConf($keepSettings);
      if(defined $reloadConfRes && ! $reloadConfRes) {
        answer("Failed to reload $pluginName plugin configuration.");
        $spads->{pluginsConf}{$pluginName}=$p_previousPluginConf if(exists $spads->{pluginsConf}{$pluginName} && defined $p_previousPluginConf);
        return 0;
      }
    }
    answer("Configuration reloaded for plugin $pluginName.");

    return 1;
  }
  if($action eq 'set') {
    if(! defined $param) {
      invalidSyntax($user,'plugin');
      return 0;
    }
    if(! exists $spads->{pluginsConf}{$pluginName}) {
      answer("Plugin $pluginName has no modifiable configuration parameters.");
      return 0;
    }
    my $p_pluginConf=$spads->{pluginsConf}{$pluginName};

    my $setting;
    foreach my $pluginSetting (keys %{$p_pluginConf->{values}}) {
      next if($HIDDEN_PLUGIN_SETTINGS{$pluginSetting});
      if(lc($param) eq lc($pluginSetting)) {
        $setting=$pluginSetting;
        last;
      }
    }
    if(! defined $setting) {
      answer("\"$param\" is not a valid setting for plugin \"$pluginName\".");
      return 0;
    }

    $val//='';

    my $allowed=0;
    foreach my $allowedValue (@{$p_pluginConf->{values}{$setting}}) {
      if(isRange($allowedValue)) {
        $allowed=1 if(matchRange($allowedValue,$val));
      }elsif($val eq $allowedValue) {
        $allowed=1;
      }
      last if($allowed);
    }
    if($allowed) {
      if($p_pluginConf->{conf}{$setting} eq $val) {
        answer("$pluginName plugin setting \"$setting\" is already set to value \"$val\".");
        return 0;
      }
      return 1 if($checkOnly);
      my $oldValue=$p_pluginConf->{conf}{$setting};
      $p_pluginConf->{conf}{$setting}=$val;
      $timestamps{autoRestore}=time;
      sayBattleAndGame("$pluginName plugin setting changed by $user ($param=$val)");
      answer("$pluginName plugin setting changed ($setting=$val)") if($source eq "pv");
      $plugins{$pluginName}->onSettingChange($setting,$oldValue,$val) if($plugins{$pluginName}->can('onSettingChange'));
      return;
    }else{
      answer("Value \"$val\" for $pluginName plugin setting \"$setting\" is not allowed in current preset.");
      return 0;
    }
  }
}

sub hPreset {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"preset");
    return 0;
  }

  my ($preset)=@{$p_params};

  if(! exists $spads->{presets}{$preset}) {
    answer("\"$preset\" is not a valid preset (use \"!list presets\" to list available presets)");
    return 0;
  }

  if(none {$preset eq $_} @{$spads->{values}{preset}}) {
    answer("Switching to preset \"$preset\" is not allowed currently (use \"!forcePreset $preset\" to bypass)");
    return 0;
  }

  return 1 if($checkOnly);

  if($preset eq $conf{defaultPreset}) {
    $timestamps{autoRestore}=0;
  }else{
    $timestamps{autoRestore}=time;
  }
  applyPreset($preset);
  my $msg="Preset \"$preset\" ($conf{description}) applied by $user";
  $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
  sayBattleAndGame($msg);
}

sub hPromote {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to promote battle, battle is closed");
    return 0;
  }

  if(! $conf{promoteMsg} || ! $conf{promoteChannels}) {
    answer("Promote command is disabled on this AutoHost");
    return 0;
  }
  
  if(time - $timestamps{promote} < $conf{promoteDelay}) {
    my $delayTime=secToTime($timestamps{promote} + $conf{promoteDelay} - time);
    answer("Please wait $delayTime before promoting battle (promote flood protection)");
    return 0;
  }

  if($currentLockedStatus) {
    answer('Unable to promote battle, battle lobby is locked');
    return 0;
  }
  my $r_battle=$lobby->{battles}{$lobby->{battle}{battleId}};
  my $nbHumanPlayers=getNbHumanPlayersInBattle();
  if($nbHumanPlayers >=  $r_battle->{maxPlayers}) {
    answer('Unable to promote battle, battle lobby is full');
    return 0;
  }
  my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
  if($conf{autoSpecExtraPlayers} && $nbHumanPlayers >= $targetNbPlayers) {
    answer('Unable to promote battle, target number of players already reached');
    return 0;
  }

  return 1 if($checkOnly);

  $timestamps{promote}=time;
  my $promoteMsg=$conf{promoteMsg};
  my %hSettings=%{$spads->{hSettings}};

  my $nbSpecs=getNbSpec()-1;
  my $nbUsers=$nbHumanPlayers+$nbSpecs;
  my $modName = $targetMod eq '' ? $r_battle->{mod} : $targetMod;
  
  my $neededPlayer="";
  if($conf{autoLock} ne "off" || $conf{autoSpecExtraPlayers} || $conf{autoStart} ne "off") {
    my $nbPlayers=0;
    foreach my $player (keys %{$lobby->{battle}{users}}) {
      $nbPlayers++ if(defined $lobby->{battle}{users}{$player}{battleStatus} && $lobby->{battle}{users}{$player}{battleStatus}{mode});
    }
    my @bots=keys %{$lobby->{battle}{bots}};
    $nbPlayers+=$#bots+1 if($conf{nbTeams} != 1);
    $neededPlayer=($targetNbPlayers-$nbPlayers)." " if($targetNbPlayers > $nbPlayers);
  }
  $promoteMsg=~s/\%u/$user/g;
  $promoteMsg=~s/\%p/$neededPlayer/g;
  $promoteMsg=~s/\%b/$hSettings{battleName}/g;
  $promoteMsg=~s/\%o/$modName/g;
  $promoteMsg=~s/\%a/$conf{map}/g;
  $promoteMsg=~s/\%P/$nbHumanPlayers/g;
  $promoteMsg=~s/\%S/$nbSpecs/g;
  $promoteMsg=~s/\%U/$nbUsers/g;
  my @promChans=split(/;/,$conf{promoteChannels});
  foreach my $chan (@promChans) {
    $chan=$1 if($chan =~ /^([^\s]+)\s/);
    sayChan($chan,$promoteMsg);
  }
  my $promChansString=join(', ',map {"#$_"} @promChans);
  answer("Promoting battle in $promChansString");
}

sub hPSet {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} == 0) {
    $p_params->[1]="";
  }

  if($#{$p_params} != 1) {
    invalidSyntax($user,"pset");
    return 0;
  }

  my $val=$p_params->[1];

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my ($errorMsg,$realPrefName)=$spads->checkUserPref($p_params->[0],$val);
  if($errorMsg) {
    invalidSyntax($user,"pset",$errorMsg);
    return 0;
  }
  if($realPrefName eq 'rankMode' || $realPrefName eq 'skillMode') {
    sayPrivate($user,"The \"$C{12}rankMode$C{1}\" and \"$C{12}skillMode$C{1}\" preferences cannot be set by using the $C{12}!pSet$C{1} command, they must be set by a privileged user with $C{3}!chrank$C{1} and $C{3}!chskill$C{1} commands.");
    return 0;
  }
  if($lanMode) {
    my $passwd=getUserPref($user,"password");
    if($passwd eq "") {
      sayPrivate($user,"The Spring lobby server is running in LAN mode, consequently:");
      if($realPrefName eq "password") {
        sayPrivate($user,"- you cannot initialize your password yourself");
        sayPrivate($user,"- only an administrator of this AutoHost can initialize it by using the \"$C{3}!chpasswd <user> <password>$C{1}\" command");
      }else{
        sayPrivate($user,"- you need to protect your account with a password to be able to change your AutoHost preferences");
        sayPrivate($user,"- only an administrator of this AutoHost can initialize your password by using the \"$C{3}!chpasswd <user> <password>$C{1}\" command");
      }
      return 0;
    }
    if(! isUserAuthenticated($user)) {
      answer("The Spring lobby server is running in LAN mode, you need to authenticate yourself first by using the \"$C{3}!auth <password>$C{1}\" command to change your AutoHost preferences");
      return 0;
    }
  }
  return 1 if($checkOnly);
  $val=md5_base64($val) if($realPrefName eq "password" && $val ne "");
  setUserPref($user,$realPrefName,$val);
  if($realPrefName eq "password") {
    if($val eq "") {
      sayPrivate($user,"AutoHost authentication is now disabled for your account");
    }else{
      sayPrivate($user,"Your password has been set to \"$C{12}$p_params->[1]$C{1}\"");
    }
  }else{
    if($realPrefName eq "shareId") {
      my $coopMsg;
      if($val eq "") {
        $coopMsg="Coop group reinitialized";
      }else{
        $coopMsg="You are now in coop group \"$C{12}$val$C{1}\"";
      }
      if(! ($conf{idShareMode} eq 'manual' || $conf{idShareMode} eq 'clan')) {
        $coopMsg.=" (this has no effect currently because the \"$C{3}idShareMode$C{1}\" setting is set to \"$C{7}$conf{idShareMode}$C{1}\")";
      }else{
        $coopMsg.=" (other players who enter \"$C{3}!coop $val$C{1}\" will coop with you if they are in the same team)" if($val ne "");
        if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$user}
           && defined $lobby->{battle}{users}{$user}{battleStatus} && $lobby->{battle}{users}{$user}{battleStatus}{mode}) {
          $balanceState=0;
          %balanceTarget=();
        }
      }
      sayPrivate($user,$coopMsg);
    }elsif($realPrefName eq "clan") {
      my $coopMsg;
      if($val eq "") {
        $coopMsg="Your $C{12}clan$C{1} preference has been removed";
      }else{
        $coopMsg="Your $C{12}clan$C{1} preference has been set to \"$C{12}$val$C{1}\"";
      }
      if($conf{balanceMode} !~ /clan/) {
        $coopMsg.=" (this has no effect currently because the \"$C{3}balanceMode$C{1}\" setting is set to \"$C{7}$conf{balanceMode}$C{1}\", which disables clan management)";
      }elsif($conf{clanMode} !~ /pref/) {
        $coopMsg.=" (this has no effect currently because the \"$C{3}clanMode$C{1}\" setting is set to \"$C{7}$conf{clanMode}$C{1}\", which disables clan preference management)";
      }else{
        if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$user}
           && defined $lobby->{battle}{users}{$user}{battleStatus} && $lobby->{battle}{users}{$user}{battleStatus}{mode}) {
          $balanceState=0;
          %balanceTarget=();
        }
      }
      sayPrivate($user,$coopMsg);
    }else{
      if($val eq "") {
        sayPrivate($user,"Your $C{12}$realPrefName$C{1} preference has been reset to default value");
      }else{
        sayPrivate($user,"Your $C{12}$realPrefName$C{1} preference has been set to \"$C{12}$val$C{1}\"");
      }
    }
  }
}

sub hQuit {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $waitMode='game';
  if($#{$p_params} > 0) {
    invalidSyntax($user,'quit');
    return 0;
  }elsif($#{$p_params} == 0) {
    if($p_params->[0] eq 'empty' || $p_params->[0] eq 'spec') {
      $waitMode=$p_params->[0];
    }else{
      invalidSyntax($user,'quit');
      return 0;
    }
  }

  return 1 if($checkOnly);
  
  my %sourceNames = ( pv => 'private',
                      chan => "channel #$masterChannel",
                      game => 'game',
                      battle => 'battle lobby' );
  applyQuitAction(0,{game => 0, spec => 1, empty => 2}->{$waitMode},"requested by $user in $sourceNames{$source}");
}

sub hRebalance {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to balance teams, battle lobby is closed");
    return 0;
  }

  if($#{$p_params} != -1) {
    invalidSyntax($user,"rebalance");
    return 0;
  }

  return 1 if($checkOnly);
  $balRandSeed=intRand();
  my ($nbSmurfs,$unbalanceIndicator)=balance();
  if(! defined $nbSmurfs) {
    answer("Balance data not ready yet, try again later");
    return 0;
  }
  my $balanceMsg="Rebalancing according to current balance mode: $conf{balanceMode}";
  my @extraStrings;
  push(@extraStrings,"$nbSmurfs smurf".($nbSmurfs>1 ? 's' : '')." found") if($nbSmurfs);
  push(@extraStrings,"balance deviation: $unbalanceIndicator\%") if($conf{balanceMode} =~ /skill$/);
  my $extraString=join(", ",@extraStrings);
  $balanceMsg.=" ($extraString)" if($extraString);
  answer($balanceMsg);
}

sub hReloadArchives {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $loadArchivesMode=LOADARCHIVES_DEFAULT;
  if(@{$p_params}) {
    if($#{$p_params} > 0 || lc($p_params->[0]) ne 'full') {
      invalidSyntax($user,"reloadarchives");
      return 0;
    }
    $loadArchivesMode=LOADARCHIVES_RELOAD;
  }

  if($loadArchivesInProgress) {
    answer('Spring archives are already being reloaded...');
    return 0;
  }

  return 1 if($checkOnly);

  my $r_asyncAnswerFunction=$p_answerFunction;
  loadArchives(
    sub {
      my $nbArchives=shift;
      quitAfterGame('Unable to reload Spring archives') unless($nbArchives);
      $r_asyncAnswerFunction->("$nbArchives Spring archives loaded");
    }, 1, $loadArchivesMode);
}

sub hReloadConf {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $keepSettings=0;
  my %confMacrosReload=%confMacros;
  my $p_macrosUsedForReload=\%confMacrosReload;

  my $paramsString=$p_params->[0];
  if(defined $paramsString && $paramsString ne '') {
    my @params=shellwords($paramsString);
    if(! @params) {
      invalidSyntax($user,"reloadconf");
      return 0;
    }
    my $keepMacros=0;
    my @macroTokens;
    foreach my $param (@params) {
      if(lc($param) eq "keepsettings") {
        $keepSettings=1;
      }elsif(lc($param) eq "keepmacros") {
        $keepMacros=1;
      }else{
        push(@macroTokens,$param);
      }
    }
    $p_macrosUsedForReload=\%confMacros if($keepMacros);
    if(@macroTokens) {
      my $p_macroDataReload=parseMacroTokens(@macroTokens);
      if(! defined $p_macroDataReload) {
        invalidSyntax($user,"reloadconf");
        return 0;
      }
      foreach my $forbiddenOverride (qw'set:springServer set:endGameCommand') {
        if(exists $p_macroDataReload->{$forbiddenOverride}) {
          answer('Unable to reload SPADS configuration: override of "'.(substr($forbiddenOverride,4)).'" setting is forbidden');
          return 0;
        }
      }

      return 1 if($checkOnly);

      foreach my $macroName (keys %{$p_macroDataReload}) {
        $p_macrosUsedForReload->{$macroName}=$p_macroDataReload->{$macroName};
      }
    }
  }

  if($loadArchivesInProgress && ! $keepSettings) {
    answer('Unable to reload SPADS configuration and apply new settings while Spring archives are being reloaded, please wait for reload process to finish or use "keepSettings" parameter');
    return 0;
  }

  return 1 if($checkOnly);

  pingIfNeeded();
  $spads->dumpDynamicData();
  $timestamps{dataDump}=time;

  my $newSpads;
  if($keepSettings) {
    $newSpads=SpadsConf->new($confFile,$sLog,$p_macrosUsedForReload,$spads);
  }else{
    $newSpads=SpadsConf->new($confFile,$sLog,$p_macrosUsedForReload);
  }
  if(! $newSpads) {
    answer("Unable to reload SPADS configuration");
    return 0;
  }

  my ($defaultPreset,$currentPreset)=@{$newSpads->{conf}}{'defaultPreset','preset'};
  foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
    next if(exists $newSpads->{pluginsConf}{$pluginName});
    if(! $newSpads->loadPluginConf($pluginName)) {
      answer("Unable to reload SPADS configuration (failed to reload $pluginName plugin configuration)");
      return 0;
    }
    $newSpads->applyPluginPreset($pluginName,$defaultPreset);
    $newSpads->applyPluginPreset($pluginName,$currentPreset) unless($currentPreset eq $defaultPreset);
    $newSpads->{pluginsConf}{$pluginName}{conf}=$spads->{pluginsConf}{$pluginName}{conf} if($keepSettings);
  }

  $spads=$newSpads;

  if($keepSettings) {
    postReloadConfActions($p_answerFunction,$keepSettings);
  }else{
    $spads->applyMapList(\@availableMaps,$syncedSpringVersion);

    my $previousMap=$conf{map};
    %conf=%{$spads->{conf}};
    $conf{map}=$previousMap if($conf{map} eq '');

    $lobbySimpleLog->setLevels([$conf{lobbyInterfaceLogLevel}]);
    $autohostSimpleLog->setLevels([$conf{autoHostInterfaceLogLevel}]);
    $updaterSimpleLog->setLevels([$conf{updaterLogLevel},3]);
    $sLog->setLevels([$conf{spadsLogLevel},3]);
    $simpleEventSimpleLog->setLevels([$conf{spadsLogLevel},3]);

    my %newlyInstantiatedPlugins;
    if($conf{autoLoadPlugins} ne '') {
      my @pluginNames=split(/;/,$conf{autoLoadPlugins});
      foreach my $pluginName (@pluginNames) {
        next if(exists $plugins{$pluginName});
        instantiatePlugin($pluginName,'autoload');
        $newlyInstantiatedPlugins{$pluginName}=1;
      }
    }

    my $r_asyncAnswerFunction=$p_answerFunction;
    loadArchives(
      sub {
        my $nbArchives=shift;
        quitAfterGame('Unable to reload Spring archives') unless($nbArchives);
        setDefaultMapOfMaplist() if($spads->{conf}{map} eq '');
        applyAllSettings();
        postReloadConfActions($r_asyncAnswerFunction,$keepSettings,\%newlyInstantiatedPlugins);
      } );
  }
}

sub postReloadConfActions {
  my ($r_answerFunction,$keepSettings,$r_newlyInstantiatedPlugins)=@_;
  $r_newlyInstantiatedPlugins//={};
  
  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('onReloadConf') && ! $r_newlyInstantiatedPlugins->{$pluginName}) {
      my $reloadConfRes=$plugins{$pluginName}->onReloadConf($keepSettings);
      $r_answerFunction->("Unable to reload $pluginName plugin configuration.") if(defined $reloadConfRes && ! $reloadConfRes);
    }
  }

  my $msg="SPADS configuration reloaded";
  $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
  $r_answerFunction->($msg);
}

sub hRehost {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != -1) {
    invalidSyntax($user,"rehost");
    return 0;
  }
  my $reason;
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    $reason='battle is closed';
  }elsif($targetMod eq '') {
    $reason="no game archive found matching \"$spads->{hSettings}{modName}\"";
    $reason.=' (archives are currently being reloaded)' if($loadArchivesInProgress);
  }
  if(defined $reason) {
    answer("Unable to rehost battle, $reason");
    return 0;
  }
  return 1 if($checkOnly);

  my %sourceNames = ( pv => "private",
                      chan => "channel #$masterChannel",
                      game => "game",
                      battle => "battle lobby" );

  rehostAfterGame("requested by $user in $sourceNames{$source}");
}

sub hResign {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $ahState=$autohost->getState();
  if($ahState != 2) {
    my $reason='game is not running';
    if($ahState == 1) {
      $reason='game has not started yet';
    }elsif($ahState == 3) {
      $reason='game is already over';
    }
    answer("Unable to resign, $reason!");
    return 0;
  }

  my ($resignedPlayer,$isTeamResign);
  if($#{$p_params} == -1) {
    ($resignedPlayer,$isTeamResign)=($user,1);
  }elsif($#{$p_params} == 0) {
    ($resignedPlayer,$isTeamResign)=($p_params->[0],0);
  }elsif($#{$p_params} == 1) {
    if(lc($p_params->[1]) ne 'team') {
      invalidSyntax($user,'resign');
      return 0;
    }
    ($resignedPlayer,$isTeamResign)=($p_params->[0],1);
  }else{
    invalidSyntax($user,'resign');
    return 0;
  }

  my @bPlayers=grep {defined $p_runningBattle->{users}{$_}{battleStatus} && $p_runningBattle->{users}{$_}{battleStatus}{mode}} (keys %{$p_runningBattle->{users}});

  if($#{$p_params} == -1) {
    if(! grep {$resignedPlayer eq $_} @bPlayers) {
      answer('Only players are allowed to resign!');
      return 0;
    }
  }else{
    my $p_playerFound=::cleverSearch($resignedPlayer,\@bPlayers);
    if(! @{$p_playerFound}) {
      answer("Unable to resign \"$resignedPlayer\", player not found!");
      return 0;
    }elsif($#{$p_playerFound} > 0) {
      answer("Unable to resign \"$resignedPlayer\", ambiguous command! (multiple matches)");
      return 0;
    }
    $resignedPlayer=$p_playerFound->[0];
  }

  if($checkOnly) {
    my $notAllowed=isNotAllowedToVoteForResign($user,$resignedPlayer);
    if($notAllowed) {
      if($notAllowed == 2) {
        answer('Only players are allowed to call vote for resign!');
      }elsif($notAllowed == 3) {
        answer('Only players from same team are allowed to call vote for resign!');
      }elsif($notAllowed == 4) {
        answer('Only connected players are allowed to call vote for resign!');
      }elsif($notAllowed == 5) {
        answer("Only the players who haven't lost yet are allowed to call vote for resign!");
      }
      return 0;
    }
  }

  my @playersToResign;
  if($isTeamResign) {
    my @resignablePlayers;
    foreach my $bPlayer (@bPlayers) {
      my $p_ahPlayer=$autohost->getPlayer($bPlayer);
      push(@resignablePlayers,$bPlayer) if(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1 && $p_ahPlayer->{lost} == 0);
    }
    @playersToResign=grep {$p_runningBattle->{users}{$_}{battleStatus}{team} == $p_runningBattle->{users}{$resignedPlayer}{battleStatus}{team}} @resignablePlayers;
    if(! @playersToResign) {
      answer("Unable to resign ally team of $resignedPlayer, no resignable player found!");
      return 0;
    }
  }else{
    my $p_ahPlayer=$autohost->getPlayer($resignedPlayer);
    if(! %{$p_ahPlayer} || $p_ahPlayer->{disconnectCause} != -1) {
      answer("Unable to resign $resignedPlayer, player is not connected!");
      return 0;
    }
    if($p_ahPlayer->{lost}) {
      answer("Unable to resign $resignedPlayer, player has already lost!");
      return 0;
    }
    @playersToResign=($resignedPlayer);
  }

  if($p_runningBattle->{engineVersion} =~ /^(\d+)/ && $1 < 92) {
    answer('The resign command requires Spring engine version 92 or later!');
    return 0;
  }

  return ['resign',$resignedPlayer,$isTeamResign ? 'TEAM' : ()] if($checkOnly);

  map {$autohost->sendChatMessage('/specbynum '.$autohost->getPlayer($_)->{playerNb})} @playersToResign;

  if($#playersToResign > 0) {
    sayBattleAndGame('Resigned '.($#playersToResign+1)." players (by $user)");
  }else{
    sayBattleAndGame("Resigned player $playersToResign[0] (by $user)");
  }

  return ['resign',$resignedPlayer,$isTeamResign ? 'TEAM' : ()];
}

sub hRemoveBot {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != 0) {
    invalidSyntax($user,'removebot');
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to remove AI bot, battle lobby is closed");
    return 0;
  }

  my @localBots;
  my @bots=keys %{$lobby->{battle}{bots}};
  foreach my $bot (@bots) {
    push(@localBots,$bot) if($lobby->{battle}{bots}{$bot}{owner} eq $conf{lobbyLogin});
  }

  my $p_removedBots=cleverSearch($p_params->[0],\@localBots);
  if(! @{$p_removedBots}) {
    answer("Unable to find any local AI bot matching \"$p_params->[0]\"");
    return 0;
  }
  if($#{$p_removedBots} > 0) {
    answer("Ambiguous command, multiple matches found for local AI bot \"$p_params->[0]\"");
    return 0;
  }
  
  return ['removeBot',$p_removedBots->[0]] if($checkOnly);

  sayBattle("Removing local AI bot $p_removedBots->[0] (by $user)");
  queueLobbyCommand(['REMOVEBOT',$p_removedBots->[0]]);

  return ['removeBot',$p_removedBots->[0]];
}

sub hRestart {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $waitMode='game';

  my $paramsString=$p_params->[0];
  if(defined $paramsString && $paramsString ne '') {
    my @params=shellwords($paramsString);
    if(! @params) {
      invalidSyntax($user,'restart');
      return 0;
    }
    my @macroTokens;
    foreach my $param (@params) {
      if(lc($param) eq 'empty' || lc($param) eq 'spec') {
        $waitMode=lc($param);
      }else{
        push(@macroTokens,$param);
      }
    }
    if(@macroTokens) {
      my $p_macroDataRestart=parseMacroTokens(@macroTokens);
      if(! defined $p_macroDataRestart) {
        invalidSyntax($user,'restart');
        return 0;
      }
      foreach my $forbiddenOverride (qw'set:springServer set:endGameCommand') {
        if(exists $p_macroDataRestart->{$forbiddenOverride}) {
          answer('Unable to restart SPADS: override of "'.(substr($forbiddenOverride,4)).'" setting is forbidden');
          return 0;
        }
      }
      
      return 1 if($checkOnly);

      foreach my $macroName (keys %{$p_macroDataRestart}) {
        $confMacros{$macroName}=$p_macroDataRestart->{$macroName};
      }
    }
  }

  return 1 if($checkOnly);

  my %sourceNames = ( pv => 'private',
                      chan => "channel #$masterChannel",
                      game => 'game',
                      battle => 'battle lobby' );
  applyQuitAction(1,{game => 0, spec => 1, empty => 2}->{$waitMode},"requested by $user in $sourceNames{$source}");
}

sub hRing {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 0) {
    invalidSyntax($user,"ring");
    return 0;
  }

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer("Unable to ring, battle is closed");
    return 0;
  }

  my @players=keys(%{$lobby->{battle}{users}});
  if($#{$p_params} == 0) {
    my $p_rungUsers=cleverSearch($p_params->[0],\@players);
    if(! @{$p_rungUsers}) {
      answer("Unable to find matching player for \"$p_params->[0]\" in battle lobby");
      return 0;
    }
    my $rungUser=$p_rungUsers->[0];
    if(exists $lastRungUsers{$rungUser}) {
      my $minRingDelay=getUserPref($rungUser,"minRingDelay");
      if(time - $lastRungUsers{$rungUser} < $minRingDelay) {
        answer("Unable to ring $rungUser (ring spam protection, please wait ".($lastRungUsers{$rungUser}+$minRingDelay-time)."s)");
        return 0;
      }
    }
    return ['ring',$rungUser] if($checkOnly);
    sayBattleAndGame("Ringing $rungUser (by $user)");
    $lastRungUsers{$rungUser}=time;
    queueLobbyCommand(["RING",$rungUser,$lobby->{protocolExtensions}{'ring:originator'} ? $user : ()]);
    return ['ring',$rungUser];
  }

  my @rungUsers;
  my @alreadyRungUsers;
  my $ringType='unready/unsynced player';

  my $p_bUsers=$lobby->{battle}{users};
  if($autohost->getState() == 1) {
    foreach my $gUserNb (keys %{$autohost->{players}}) {
      my $player=$autohost->{players}{$gUserNb}{name};
      my $minRingDelay=getUserPref($player,"minRingDelay");
      if(exists $currentVote{command}) {
        $ringType='remaining voter';
        if(exists $currentVote{remainingVoters}{$player}) {
          if(exists $lastRungUsers{$player} && time - $lastRungUsers{$player} < $minRingDelay) {
            push(@alreadyRungUsers,$player);
          }else{
            push(@rungUsers,$player);
          }
        }
      }else{
        $ringType='unready player';
        if($autohost->{players}{$gUserNb}{ready} < 1
           && exists $p_bUsers->{$player}
           && exists $p_runningBattle->{users}{$player}
           && (! defined $p_runningBattle->{users}{$player}{battleStatus} 
               || $p_runningBattle->{users}{$player}{battleStatus}{mode})) {
          if(exists $lastRungUsers{$player} && time - $lastRungUsers{$player} < $minRingDelay) {
            push(@alreadyRungUsers,$player);
          }else{
            push(@rungUsers,$player);
          }
        }
      }
    }
  }elsif(! $autohost->getState() || exists $currentVote{command}) {
    foreach my $bUser (keys %{$p_bUsers}) {
      my $minRingDelay=getUserPref($bUser,"minRingDelay");
      if(exists $currentVote{command}) {
        $ringType='remaining voter';
        if(exists $currentVote{remainingVoters}{$bUser}) {
          if(exists $lastRungUsers{$bUser} && time - $lastRungUsers{$bUser} < $minRingDelay) {
            push(@alreadyRungUsers,$bUser);
          }else{
            push(@rungUsers,$bUser);
          }
        }
      }else{
        if(! defined $p_bUsers->{$bUser}{battleStatus}
           || ($p_bUsers->{$bUser}{battleStatus}{mode}
               && (! $p_bUsers->{$bUser}{battleStatus}{ready} || $p_bUsers->{$bUser}{battleStatus}{sync} != 1))) {
          if(exists $lastRungUsers{$bUser} && time - $lastRungUsers{$bUser} < $minRingDelay) {
            push(@alreadyRungUsers,$bUser);
          }else{
            push(@rungUsers,$bUser);
          }
        }
      }
    }
  }

  if(@rungUsers) {
    return 1 if($checkOnly);
    my $rungUsersString=join(",",@rungUsers);
    my $ringMsg;
    if(length($rungUsersString) > 50) {
      $ringMsg="Ringing ".($#rungUsers+1)." ${ringType}s";
    }else{
      $ringMsg="Ringing ${ringType}(s): $rungUsersString";
    }
    sayBattleAndGame("$ringMsg (by $user)");
    foreach my $rungUser (@rungUsers) {
      $lastRungUsers{$rungUser}=time;
      queueLobbyCommand(["RING",$rungUser,$lobby->{protocolExtensions}{'ring:originator'} ? $user : ()]);
    }
  }else{
    my $alreadyRungMsg="";
    if(@alreadyRungUsers) {
      my $alreadyRungUsersString=join(",",@alreadyRungUsers);
      $alreadyRungUsersString=($#alreadyRungUsers+1)." users" if(length($alreadyRungUsersString) > 50);
      $alreadyRungMsg=" (ring spam protection for $alreadyRungUsersString)";
    }
    answer("There is no one to ring$alreadyRungMsg");
    return 0;
  }

}

sub hSaveBoxes {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,"saveboxes");
    return 0;
  }

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer("Unable to save start boxes, battle is closed");
    return 0;
  }

  my $p_startRects=$lobby->{battle}{startRects};
  if(! %{$p_startRects}) {
    answer("No start box to save");
    return 0;
  }

  return 1 if($checkOnly);

  my $smfMapName=$conf{map};
  $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
  $spads->saveMapBoxes($smfMapName,$p_startRects,$conf{extraBox});
  answer("Start boxes saved for map $conf{map}");
  return 1;
}

sub hSay {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 0) {
    invalidSyntax($user,"say");
    return 0;
  }

  if($autohost->getState() == 0) {
    answer("Unable to send data on AutoHost interface, game is not running");
    return 0;
  }

  if(! isUserAllowedToSpeakInGame($user)) {
    my $userLevel=getUserAccessLevel($user);
    my $p_stopLevels=$spads->getCommandLevels('stop','battle','player','running');
    my $p_sendLevels=$spads->getCommandLevels('send','battle','player','running');
    if( (! exists $p_stopLevels->{directLevel} || $userLevel < $p_stopLevels->{directLevel})
        && (! exists $p_sendLevels->{directLevel} || $userLevel < $p_sendLevels->{directLevel}) ) {
      answer('Unable to send message in game from lobby, spectator chat is currently disabled');
      return 0;
    }
  }

  return 1 if($checkOnly);

  my $prompt="<$user> ";
  my $p_messages=splitMsg($p_params->[0],$conf{maxAutoHostMsgLength}-length($prompt)-1);
  foreach my $mes (@{$p_messages}) {
    $autohost->sendChatMessage("$prompt$mes");
    logMsg("game","> $prompt$mes") if($conf{logGameChat});
  }

  return 1;
}

sub hSearchUser {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"searchuser");
    return 0;
  }

  if($conf{userDataRetention} =~ /^0;/) {
    answer("Unable to search for user accounts (user data retention is disabled on this AutoHost)");
    return 0;
  }

  return 1 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $nbMatchingId=0;
  my @matchingAccounts;
  my @resultFields;
  my $search=$p_params->[0];

  my @ranks=("Newbie","$C{3}Beginner","$C{3}Average","$C{10}Above average","$C{12}Experienced","$C{7}Highly experienced","$C{4}Veteran","$C{13}Ghost");
  if($search =~ /^\@([\d\.\*]+)$/) {
    $search=$1;
    if(getUserAccessLevel($user) < $conf{privacyTrustLevel}) {
      answer("Unable to search for user accounts by IP (insufficient privileges)");
      return 0;
    }
    if($spads->isStoredIp($search)) {
      my $p_ipIds=$spads->getIpIdsTs($search);
      my @sortedMatches=sort {$p_ipIds->{$b} <=> $p_ipIds->{$a}} (keys %{$p_ipIds});
      $nbMatchingId=$#sortedMatches+1;
      foreach my $id (@sortedMatches) {
        my $p_accountMainData=$spads->getAccountMainData($id);
        my $p_accountNames=$spads->getAccountNamesTs($id);
        my $D = time-$p_accountMainData->{timestamp} > 1209600 ? $C{14} : $C{1};
        my @idNames=sort {$p_accountNames->{$b} <=> $p_accountNames->{$a}} (keys %{$p_accountNames});
        my $names=formatList(\@idNames,40);
        my ($idOnly,$idName)=($id,undef);
        ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);
        my $online;
        if($idOnly) {
          $online=exists $lobby->{accounts}{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}LobbyClient$C{1}" => $p_accountMainData->{lobbyClient},
                                "$C{5}Rank$C{1}" => $ranks[abs($p_accountMainData->{rank})].$D,
                                "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_accountMainData->{timestamp}),
                                "$C{5}Matching IP(s)$C{1}" => $search});
        last if($#matchingAccounts > 38);
      }
    }else{
      my $p_matchingIds;
      ($p_matchingIds,$nbMatchingId)=$spads->searchIpIds($search);
      if($nbMatchingId > 40) {
        sayPrivate($user,"Too many results, please use a filter more specific than \"\@$search\"");
        return 0;
      }
      my @sortedMatches=sort {$p_matchingIds->{$b}{timestamp} <=> $p_matchingIds->{$a}{timestamp}} (keys %{$p_matchingIds});
      foreach my $id (@sortedMatches) {
        my $p_accountMainData=$spads->getAccountMainData($id);
        my $p_accountNames=$spads->getAccountNamesTs($id);
        my $D = time-$p_accountMainData->{timestamp} > 1209600 ? $C{14} : $C{1};
        my @idIps=sort {$p_matchingIds->{$id}{ips}{$b} <=> $p_matchingIds->{$id}{ips}{$a}} (keys %{$p_matchingIds->{$id}{ips}});
        my $ips=formatList(\@idIps,40);
        my @idNames=sort {$p_accountNames->{$b} <=> $p_accountNames->{$a}} (keys %{$p_accountNames});
        my $names=formatList(\@idNames,40);
        my ($idOnly,$idName)=($id,undef);
        ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);
        my $online;
        if($idOnly) {
          $online=exists $lobby->{accounts}{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}LobbyClient$C{1}" => $p_accountMainData->{lobbyClient},
                                "$C{5}Rank$C{1}" => $ranks[abs($p_accountMainData->{rank})].$D,
                                "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_accountMainData->{timestamp}),
                                "$C{5}Matching IP(s)$C{1}" => $ips});
      }
    }
    @resultFields=("$C{5}ID$C{1}","$C{5}Name(s)$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}LobbyClient$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}","$C{5}Matching IP(s)$C{1}");
  }else{
    my $p_matchingIds;
    ($p_matchingIds,$nbMatchingId)=$spads->searchUserIds($search);
    if($spads->isStoredUser($search)) {
      my $p_userIds=$spads->getUserIds($search);
      my @sortedMatches=sort {$p_matchingIds->{$b}{names}{$search} <=> $p_matchingIds->{$a}{names}{$search}} (@{$p_userIds});
      foreach my $id (@sortedMatches) {
        my $p_accountMainData=$spads->getAccountMainData($id);
        my $p_accountIps=$spads->getAccountIpsTs($id);
        my $D = time-$p_accountMainData->{timestamp} > 1209600 ? $C{14} : $C{1};
        my @idNames=sort {$p_matchingIds->{$id}{names}{$b} <=> $p_matchingIds->{$id}{names}{$a}} (keys %{$p_matchingIds->{$id}{names}});
        my $names=formatList(\@idNames,40);
        my @idIps=sort {$p_accountIps->{$b} <=> $p_accountIps->{$a}} (keys %{$p_accountIps});
        my $ips=formatList(\@idIps,40);
        my ($idOnly,$idName)=($id,undef);
        ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);
        my $online;
        if($idOnly) {
          $online=exists $lobby->{accounts}{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Matching name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}LobbyClient$C{1}" => $p_accountMainData->{lobbyClient},
                                "$C{5}Rank$C{1}" => $ranks[abs($p_accountMainData->{rank})].$D,
                                "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_accountMainData->{timestamp}),
                                "$C{5}IP(s)$C{1}" => $ips});
        delete $p_matchingIds->{$id};
        last if($#matchingAccounts > 38);
      }
    }elsif($nbMatchingId > 40) {
      sayPrivate($user,"Too many results, please use a filter string more specific than \"$search\"");
      return 0;
    }
    if($nbMatchingId < 41) {
      my @sortedMatches=sort {$p_matchingIds->{$b}{timestamp} <=> $p_matchingIds->{$a}{timestamp}} (keys %{$p_matchingIds});
      foreach my $id (@sortedMatches) {
        my $p_accountMainData=$spads->getAccountMainData($id);
        my $p_accountIps=$spads->getAccountIpsTs($id);
        my $D = time-$p_accountMainData->{timestamp} > 1209600 ? $C{14} : $C{1};
        my @idNames=sort {$p_matchingIds->{$id}{names}{$b} <=> $p_matchingIds->{$id}{names}{$a}} (keys %{$p_matchingIds->{$id}{names}});
        my $names=formatList(\@idNames,40);
        my @idIps=sort {$p_accountIps->{$b} <=> $p_accountIps->{$a}} (keys %{$p_accountIps});
        my $ips=formatList(\@idIps,40);
        my ($idOnly,$idName)=($id,undef);
        ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);
        my $online;
        if($idOnly) {
          $online=exists $lobby->{accounts}{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Matching name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}LobbyClient$C{1}" => $p_accountMainData->{lobbyClient},
                                "$C{5}Rank$C{1}" => $ranks[abs($p_accountMainData->{rank})].$D,
                                "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_accountMainData->{timestamp}),
                                "$C{5}IP(s)$C{1}" => $ips});
      }
    }
    @resultFields=("$C{5}ID$C{1}","$C{5}Matching name(s)$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}LobbyClient$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}");
    push(@resultFields,"$C{5}IP(s)$C{1}") if(getUserAccessLevel($user) >= $conf{privacyTrustLevel});
  }
  if(! @matchingAccounts) {
    sayPrivate($user,"Unable to find any user matching \"$search\" filter");
    return 0;
  }
  my $p_resultLines=formatArray(\@resultFields,\@matchingAccounts);
  foreach my $resultLine (@{$p_resultLines}) {
    sayPrivate($user,$resultLine);
  }
  sayPrivate($user,"Too many results, only the first exact matches are shown above") if($nbMatchingId > 40);
}

sub hSend {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 0) {
    invalidSyntax($user,"send");
    return 0;
  }

  if($autohost->getState() == 0) {
    answer("Unable to send data on AutoHost interface, game is not running");
    return 0;
  }

  return 1 if($checkOnly);

  my $params=$p_params->[0];
  $autohost->sendChatMessage($params);
  logMsg("game","> $params") if($conf{logGameChat});

  return 1;
}

sub hSendLobby {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"sendlobby");
    return 0;
  }

  if($lobbyState < LOBBY_STATE_SYNCHRONIZED) {
    answer("Unable to send data to lobby server, lobby is not synchronized yet");
    return 0;
  }

  my @lobbyCmd=parse_line(' ',0,$p_params->[0]);
  if(! @lobbyCmd) {
    answer('Unable to parse lobby command (syntax error)');
    return 0;
  }
  $lobbyCmd[-1]//='';
  
  # SpringLobbyProtocol is assumed to be loaded by SpringLobbyInterface
  # (it can't be loaded by SPADS core as it would block auto-update from SPADS < 0.13.32)
  if(! defined eval { SpringLobbyProtocol::marshallClientCommand(\@lobbyCmd) } ) {
    chomp($@);
    answer("Unable to send command to lobby server ($@)");
    return 0;
  }

  return 1 if($checkOnly);

  sendLobbyCommand([\@lobbyCmd]);

  return 1;
}

sub hSet {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} == 0) {
    $p_params->[1]="";
  }

  if($#{$p_params} < 1) {
    invalidSyntax($user,"set");
    return 0;
  }

  my ($setting,$val)=@{$p_params};
  $setting=lc($setting);

  if($setting eq "map") {
    if($val eq '') {
      if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
        answer('Unable to rotate map, battle is closed');
        return 0;
      }
      return ['nextMap'] if($checkOnly);
      rotateMap($conf{rotationManual},1);
      return ['nextMap'];
    }
    my $realVal=searchMap($val);
    if(! $realVal) {
      answer("Could not find matching map for \"$val\" in current map list");
      return 0;
    }
    if($conf{map} eq $realVal) {
      answer("Map is already set to \"$realVal\"");
      return 0;
    }
    return ['set','map',$realVal] if($checkOnly);
    $spads->{conf}{map}=$realVal;
    %conf=%{$spads->{conf}};
    $timestamps{autoRestore}=time;
    applySettingChange("map");
    my $msg="Map changed by $user: $realVal";
    if($conf{autoLoadMapPreset}) {
      my $smfMapName=$conf{map};
      $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
      if(exists $spads->{presets}{$smfMapName}) {
        applyPreset($smfMapName);
        $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
      }elsif(exists $spads->{presets}{"_DEFAULT_.smf"}) {
        applyPreset("_DEFAULT_.smf");
        $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
      }
    }
    sayBattleAndGame($msg);
    answer("Map changed: $realVal") if($source eq "pv");
    return ['set','map',$realVal];
  }

  foreach my $param (keys %{$spads->{values}}) {
    next if($HIDDEN_PRESET_SETTINGS{$param});
    if($setting eq lc($param)) {
      my $allowed=0;
      foreach my $allowedValue (@{$spads->{values}{$param}}) {
        if(isRange($allowedValue)) {
          $allowed=1 if(matchRange($allowedValue,$val));
        }elsif($val eq $allowedValue) {
          $allowed=1;
        }
        last if($allowed);
      }
      if($allowed) {
        if($conf{$param} eq $val) {
          answer("Global setting \"$param\" is already set to value \"$val\"");
          return 0;
        }
        return 1 if($checkOnly);
        $spads->{conf}{$param}=$val;
        %conf=%{$spads->{conf}};
        $timestamps{autoRestore}=time;
        applySettingChange($setting);
        sayBattleAndGame("Global setting changed by $user ($param=$val)");
        answer("Global setting changed ($param=$val)") if($source eq "pv");
        return;
      }else{
        my $deniedMessage="Value \"$val\" for global setting \"$param\" is not allowed in current preset";
        $deniedMessage.=" or map" if($conf{autoLoadMapPreset});
        answer($deniedMessage);
        return 0;
      }
    }
  }

  answer("\"$setting\" is not a valid global setting (use \"!list settings\" to list available global settings)");
  return 0;
}

sub hSmurfs {
  my ($source,$user,$p_params,$checkOnly)=@_;
  
  if($#{$p_params} > 0) {
    invalidSyntax($user,"smurfs");
    return 0;
  }

  if($conf{userDataRetention} =~ /^0;/) {
    answer("Unable to perform smurf detection (user data retention is disabled on this AutoHost)");
    return 0;
  }

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  if(@{$p_params}) {

    my $smurfUser=$p_params->[0];
    if($smurfUser =~ /^\#([1-9]\d*)$/) {
      my $smurfId=$1;
      if(! $spads->isStoredAccount($smurfId)) {
        answer("Unable to perform smurf detection (unknown account $smurfUser, try !searchUser first)");
        return 0;
      }
    }else{
      if(! $spads->isStoredUser($smurfUser)) {
        answer("Unable to perform smurf detection (unknown user \"$smurfUser\", try !searchUser first)");
        return 0;
      }
    }

    return 1 if($checkOnly);

    my ($p_smurfsData,$p_probableSmurfs)=getSmurfsData($smurfUser,$p_C);
    
    if(@{$p_smurfsData}) {
      my @resultFields=("$C{5}ID$C{1}","$C{5}Name(s)$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}LobbyClient$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}","$C{5}Confidence$C{1}");
      push(@resultFields,"$C{5}IP(s)$C{1}") if(getUserAccessLevel($user) >= $conf{privacyTrustLevel});
      my $p_resultLines=formatArray(\@resultFields,$p_smurfsData);
      foreach my $resultLine (@{$p_resultLines}) {
        sayPrivate($user,$resultLine);
      }
      if(@{$p_probableSmurfs}) {
        sayPrivate($user,"Too many results (only the 40 first accounts are shown above)");
        if(@{$p_probableSmurfs}) {
          sayPrivate($user,"Other probable smurfs:");
          sayPrivate($user,"  ".join(' ',@{$p_probableSmurfs}));
        }
      }
    }else{
      sayPrivate($user,"Unable to perform IP-based smurf detection for $C{12}$smurfUser$C{1} (IP unknown)");
    }

  }else{

    if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
      answer("Unable to perform smurf detection in battle, battle lobby is closed");
      return 0;
    }
    my @smurfUsers=keys(%{$lobby->{battle}{users}});
    if($#smurfUsers < 1) {
      answer("Unable to perform smurf detection in battle, battle lobby is empty");
      return 0;
    }
    return 1 if($checkOnly);
    my @results;
    foreach my $smurfUser (@smurfUsers) {
      next if($smurfUser eq $conf{lobbyLogin});
      my %result=("$C{5}Player$C{1}" => $C{10}.$smurfUser.$C{1}, "$C{5}Smurfs$C{1}" => '');
      my ($p_smurfsData)=getSmurfsData($smurfUser,\%NO_COLOR);
      if($#{$p_smurfsData} < 1) {
        push(@results,\%result);
        next;
      }
      my $isFirst=1;
      foreach my $p_smurfData (@{$p_smurfsData}) {
        if($isFirst) {
          $isFirst=0;
          $result{"$C{5}Smurfs$C{1}"}=$p_smurfData->{'Name(s)'};
        }else{
          $result{"$C{5}Smurfs$C{1}"}.=" $C{4}|$C{1} $p_smurfData->{'Name(s)'}";
        }
        if(realLength($result{"$C{5}Smurfs$C{1}"}) > 80) {
          $result{"$C{5}Smurfs$C{1}"}.="...";
          last;
        }
      }
      push(@results,\%result);
    }
    my $p_resultLines=formatArray(["$C{5}Player$C{1}","$C{5}Smurfs$C{1}"],\@results);
    foreach my $resultLine (@{$p_resultLines}) {
      sayPrivate($user,$resultLine);
    }
    sayPrivate($user,"  --> Use \"$C{3}!smurfs <playerName>$C{1}\" for detailed smurf information about a player");
  }

}

sub hSplit {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 1) {
    invalidSyntax($user,"split");
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to split map, battle lobby is closed");
    return 0;
  }
  if($spads->{bSettings}{startpostype} != 2) {
    answer("Unable to split map, start position type must be set to \"Choose in game\" (\"!bSet startPosType 2\")");
    return 0;
  }
  my $splitType=$p_params->[0];
  my $splitSize=$p_params->[1];
  if(none {$splitType eq $_} qw'h v c1 c2 c s') {
    invalidSyntax($user,"split","invalid split type \"$splitType\"");
    return 0;
  }
  if($splitSize !~ /^\d+$/ || $splitSize > 50) {
    invalidSyntax($user,"split","invalid box size \"$splitSize\"");
    return 0;
  }
  $splitSize*=2;

  return 1 if($checkOnly);

  my @boxes;
  if($splitType eq "h") {
    @boxes=([0,0,200,$splitSize],[0,200-$splitSize,200,200]);
  }elsif($splitType eq "v") {
    @boxes=([0,0,$splitSize,200],[200-$splitSize,0,200,200]);
  }elsif($splitType eq "c1") {
    @boxes=([0,0,$splitSize,$splitSize],[200-$splitSize,200-$splitSize,200,200]);
  }elsif($splitType eq "c2") {
    @boxes=([0,200-$splitSize,$splitSize,200],[200-$splitSize,0,200,$splitSize]);
  }elsif($splitType eq "c") {
    @boxes=([0,0,$splitSize,$splitSize],
            [200-$splitSize,200-$splitSize,200,200],
            [0,200-$splitSize,$splitSize,200],
            [200-$splitSize,0,200,$splitSize]);
  }elsif($splitType eq "s") {
    @boxes=([100-int($splitSize/2),0,100+int($splitSize/2),$splitSize],
            [100-int($splitSize/2),200-$splitSize,100+int($splitSize/2),200],
            [0,100-int($splitSize/2),$splitSize,100+int($splitSize/2)],
            [200-$splitSize,100-int($splitSize/2),200,100+int($splitSize/2)]);
  }

  
  foreach my $teamNb (keys %{$lobby->{battle}{startRects}}) {
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]);
  }

  for my $teamNb (0..$#boxes) {
    my @box=@{$boxes[$teamNb]};
    queueLobbyCommand(["ADDSTARTRECT",$teamNb,@box]);
  }

}

sub hSpecAfk {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,"specafk");
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
    answer("Unable to spec unready AFK players, battle is closed");
    return 0;
  }

  if($springPid || $autohost->getState()) {
    answer("Unable to spec unready AFK players, game is running");
    return 0;
  }

  my @unreadyAfkPlayers;
  my $p_bUsers=$lobby->{battle}{users};
  foreach my $bUser (keys %{$p_bUsers}) {
    next unless(defined $p_bUsers->{$bUser}{battleStatus});
    push(@unreadyAfkPlayers,$bUser) if($p_bUsers->{$bUser}{battleStatus}{mode}
                                       && $lobby->{users}{$bUser}{status}{away}
                                       && ! $p_bUsers->{$bUser}{battleStatus}{ready});
  }

  if(! @unreadyAfkPlayers) {
    answer("Unable to find any unready AFK player to spec");
    return 0;
  }
  
  return 1 if($checkOnly);

  foreach my $unreadyAfkPlayer (@unreadyAfkPlayers) {
    queueLobbyCommand(["FORCESPECTATORMODE",$unreadyAfkPlayer]);
  }
}

sub hStart {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState != LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to start game, battle lobby is closed");
    return 0;
  }

  if($springPid) {
    answer("Unable to start game, it is already running");
    return 0;
  }

  if($#{$p_params} != -1) {
    invalidSyntax($user,"start");
    return 0;
  }

  return launchGame(0,$checkOnly);
}

sub hStats {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if(@{$p_params}) {
    invalidSyntax($user,'stats');
    return 0;
  }

  if($springPid && $autohost->getState()) {
    answer("Game statistics aren't available when game is running.");
    return 0;
  }

  if(! %teamStats) {
    answer("No game statistic available");
    return 0;
  }

  return 1 if($checkOnly);

  my @sortedNames=sort {$teamStats{$b}{damageDealt} <=> $teamStats{$a}{damageDealt}} (keys %teamStats);
  my ($totalDamageDealt,$totalDamageReceived,$totalUnitsProduced,$totalUnitsKilled,$totalMetalProduced,$totalMetalUsed,$totalEnergyProduced,$totalEnergyUsed)=(0,0,0,0,0,0,0,0);
  foreach my $name (@sortedNames) {
    $totalDamageDealt+=$teamStats{$name}{damageDealt};
    $totalDamageReceived+=$teamStats{$name}{damageReceived};
    $totalUnitsProduced+=$teamStats{$name}{unitsProduced};
    $totalUnitsKilled+=$teamStats{$name}{unitsKilled};
    $totalMetalProduced+=$teamStats{$name}{metalProduced};
    $totalMetalUsed+=$teamStats{$name}{metalUsed};
    $totalEnergyProduced+=$teamStats{$name}{energyProduced};
    $totalEnergyUsed+=$teamStats{$name}{energyUsed};
  }
  $totalDamageDealt=1 unless($totalDamageDealt);
  $totalDamageReceived=1 unless($totalDamageReceived);
  $totalUnitsProduced=1 unless($totalUnitsProduced);
  $totalUnitsKilled=1 unless($totalUnitsKilled);
  $totalMetalProduced=1 unless($totalMetalProduced);
  $totalMetalUsed=1 unless($totalMetalUsed);
  $totalEnergyProduced=1 unless($totalEnergyProduced);
  $totalEnergyUsed=1 unless($totalEnergyUsed);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};

  my @stats;
  foreach my $name (@sortedNames) {
    push(@stats,{"$C{5}Name$C{1}" => $name,
                 "$C{5}Team$C{1}" => $teamStats{$name}{allyTeam},
                 "$C{5}DamageDealt$C{1}" => formatInteger(int($teamStats{$name}{damageDealt})).' ('.int($teamStats{$name}{damageDealt}/$totalDamageDealt*100+0.5).'%)',
                 "$C{5}DamageRec.$C{1}" => formatInteger(int($teamStats{$name}{damageReceived})).' ('.int($teamStats{$name}{damageReceived}/$totalDamageReceived*100+0.5).'%)',
                 "$C{5}UnitsProd.$C{1}" => formatInteger(int($teamStats{$name}{unitsProduced})).' ('.int($teamStats{$name}{unitsProduced}/$totalUnitsProduced*100+0.5).'%)',
                 "$C{5}UnitsKilled$C{1}" => formatInteger(int($teamStats{$name}{unitsKilled})).' ('.int($teamStats{$name}{unitsKilled}/$totalUnitsKilled*100+0.5).'%)',
                 "$C{5}MetalProd.$C{1}" => formatInteger(int($teamStats{$name}{metalProduced})).' ('.int($teamStats{$name}{metalProduced}/$totalMetalProduced*100+0.5).'%)',
                 "$C{5}MetalUsed$C{1}" => formatInteger(int($teamStats{$name}{metalUsed})).' ('.int($teamStats{$name}{metalUsed}/$totalMetalUsed*100+0.5).'%)',
                 "$C{5}EnergyProd.$C{1}" => formatInteger(int($teamStats{$name}{energyProduced})).' ('.int($teamStats{$name}{energyProduced}/$totalEnergyProduced*100+0.5).'%)',
                 "$C{5}EnergyUsed$C{1}" => formatInteger(int($teamStats{$name}{energyUsed})).' ('.int($teamStats{$name}{energyUsed}/$totalEnergyUsed*100+0.5).'%)'});
  }
  
  my $p_statsLines=formatArray(["$C{5}Name$C{1}","$C{5}Team$C{1}","$C{5}DamageDealt$C{1}","$C{5}DamageRec.$C{1}","$C{5}UnitsProd.$C{1}","$C{5}UnitsKilled$C{1}","$C{5}MetalProd.$C{1}","$C{5}MetalUsed$C{1}","$C{5}EnergyProd.$C{1}","$C{5}EnergyUsed$C{1}"],\@stats,"$C{2}Game statistics$C{1}");
  foreach my $statsLine (@{$p_statsLines}) {
    sayPrivate($user,$statsLine);
  }
}

sub getRoundedSkill {
  my $skill=shift;
  my ($roundedSkill,$deviation);
  foreach my $rank (sort {$b <=> $a} keys %RANK_SKILL) {
    if(! defined $roundedSkill || abs($skill-$RANK_SKILL{$rank}) < $deviation) {
      $roundedSkill=$RANK_SKILL{$rank};
      $deviation=abs($skill-$roundedSkill);
      next;
    }
    last;
  }
  return $roundedSkill;
}

sub getGameStatus {
  my $user=shift;
  
  my $ahState=$autohost->getState();
  return undef unless($springPid && $ahState);

  my $userLevel=getUserAccessLevel($user);
  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my @clientsStatus;
  my %statusDataFromPlugin;
  {
    my %battleStructure;
    my @spectators;
    foreach my $player (keys %{$p_runningBattle->{users}}) {
      if(defined $p_runningBattle->{users}{$player}{battleStatus} && $p_runningBattle->{users}{$player}{battleStatus}{mode}) {
        my $playerTeam=$p_runningBattle->{users}{$player}{battleStatus}{team};
        my $playerId=$p_runningBattle->{users}{$player}{battleStatus}{id};
        $battleStructure{$playerTeam}={} unless(exists $battleStructure{$playerTeam});
        $battleStructure{$playerTeam}{$playerId}=[] unless(exists $battleStructure{$playerTeam}{$playerId});
        push(@{$battleStructure{$playerTeam}{$playerId}},$player);
      }else{
        push(@spectators,$player) unless($springServerType eq 'dedicated' && $player eq $conf{lobbyLogin});
      }
    }
    foreach my $bot (keys %{$p_runningBattle->{bots}}) {
      my $botTeam=$p_runningBattle->{bots}{$bot}{battleStatus}{team};
      my $botId=$p_runningBattle->{bots}{$bot}{battleStatus}{id};
      $battleStructure{$botTeam}={} unless(exists $battleStructure{$botTeam});
      $battleStructure{$botTeam}{$botId}=[] unless(exists $battleStructure{$botTeam}{$botId});
      push(@{$battleStructure{$botTeam}{$botId}},$bot." (bot)");
    }
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my @midGamePlayers=grep {! exists $p_runningBattle->{users}{$_} && exists $inGameAddedPlayers{$_}} (keys %{$p_ahPlayers});
    my %midGamePlayersById;
    foreach my $midGamePlayer (@midGamePlayers) {
      $midGamePlayersById{$inGameAddedPlayers{$midGamePlayer}}=[] unless(exists $midGamePlayersById{$inGameAddedPlayers{$midGamePlayer}});
      push(@{$midGamePlayersById{$inGameAddedPlayers{$midGamePlayer}}},$midGamePlayer);
    }
    foreach my $teamNb (sort {$a <=> $b} keys %battleStructure) {
      foreach my $idNb (sort {$a <=> $b} keys %{$battleStructure{$teamNb}}) {
        my $internalIdNb=$runningBattleMapping{teams}{$idNb};
        my @midGameIdPlayers;
        @midGameIdPlayers=@{$midGamePlayersById{$internalIdNb}} if(exists $midGamePlayersById{$internalIdNb});
        foreach my $player (sort (@{$battleStructure{$teamNb}{$idNb}},@midGameIdPlayers)) {
          my %clientStatus=(Name => $player,
                            Team => $runningBattleMapping{allyTeams}{$teamNb},
                            Id => $internalIdNb);
          if($player =~ /^(.+) \(bot\)$/) {
            my $botName=$1;
            $clientStatus{Version}="$p_runningBattle->{bots}{$botName}{aiDll} ($p_runningBattle->{bots}{$botName}{owner})";
          }else{
            $clientStatus{Name}="+ $player" unless(exists $p_runningBattle->{users}{$player});
            $clientStatus{Status}="Not connected";
          }
          my $p_ahPlayer=$autohost->getPlayer($player);
          if(%{$p_ahPlayer}) {
            if($p_ahPlayer->{ready} == 0) {
              $clientStatus{Ready}="$C{7}Placed$C{1}";
            }elsif($p_ahPlayer->{ready} > 0) {
              $clientStatus{Ready}="$C{3}Yes$C{1}";
            }else{
              $clientStatus{Ready}="$C{4}No$C{1}";
            }
            if($p_ahPlayer->{disconnectCause} == -2) {
              $clientStatus{Status}="$C{14}Loading$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == 0) {
              $clientStatus{Status}="$C{4}Timeouted$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == 1) {
              $clientStatus{Status}="$C{7}Disconnected$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == 2) {
              $clientStatus{Status}="$C{13}Kicked$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == -1) {
              if($p_ahPlayer->{lost} == 0) {
                if($ahState == 1) {
                  $clientStatus{Status}="$C{10}Waiting$C{1}";
                }else{
                  $clientStatus{Status}="$C{3}Playing$C{1}";
                }
              }else{
                $clientStatus{Status}="$C{12}Spectating$C{1}";
              }
            }else{
              $clientStatus{Status}="$C{6}Unknown$C{1}";
            }
            $clientStatus{Version}=$p_ahPlayer->{version};
            if($userLevel >= $conf{privacyTrustLevel}) {
              $clientStatus{IP}=$p_ahPlayer->{address};
              $clientStatus{IP}=$1 if($clientStatus{IP} =~ /^\[(?:::ffff:)?(\d+(?:\.\d+){3})\]:\d+$/);
            }
            foreach my $pluginName (@pluginsOrder) {
              if($plugins{$pluginName}->can('updateGameStatusInfo')) {
                my $p_pluginColumns=$plugins{$pluginName}->updateGameStatusInfo(\%clientStatus,$userLevel);
                if(ref($p_pluginColumns) eq 'HASH') {
                  my @pluginColumns=keys %{$p_pluginColumns};
                  map {$clientStatus{$_}=$p_pluginColumns->{$_}} @pluginColumns;
                  $p_pluginColumns=\@pluginColumns;
                }
                foreach my $pluginColumn (@{$p_pluginColumns}) {
                  $statusDataFromPlugin{$pluginColumn}=$pluginName unless(exists $statusDataFromPlugin{$pluginColumn});
                }
              }
            }
          }
          my %coloredStatus;
          foreach my $k (keys %clientStatus) {
            if(exists $statusDataFromPlugin{$k}) {
              $coloredStatus{"$C{6}$k$C{1}"}=$clientStatus{$k};
            }else{
              $coloredStatus{"$C{5}$k$C{1}"}=$clientStatus{$k};
            }
          }
          push(@clientsStatus,\%coloredStatus);
        }
      }
    }
    my @midGameSpecs=grep {! exists $p_runningBattle->{users}{$_} && ! exists $inGameAddedPlayers{$_}} (keys %{$p_ahPlayers});
    foreach my $spec (sort (@spectators,@midGameSpecs)) {
      my %clientStatus=(Name => $spec,
                        Status => "Not connected");
      $clientStatus{Name}="+ $spec" unless(exists $p_runningBattle->{users}{$spec});
      my $p_ahPlayer=$autohost->getPlayer($spec);
      if(%{$p_ahPlayer}) {
        if($p_ahPlayer->{disconnectCause} == -2) {
          $clientStatus{Status}="$C{14}Loading$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == 0) {
          $clientStatus{Status}="$C{4}Timeouted$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == 1) {
          $clientStatus{Status}="$C{7}Disconnected$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == 2) {
          $clientStatus{Status}="$C{13}Kicked$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == -1) {
          $clientStatus{Status}="$C{12}Spectating$C{1}";
        }else{
          $clientStatus{Status}="$C{6}Unknown$C{1}";
        }
        $clientStatus{Version}=$p_ahPlayer->{version};
        if($userLevel >= $conf{privacyTrustLevel}) {
          $clientStatus{IP}=$p_ahPlayer->{address};
          $clientStatus{IP}=$1 if($clientStatus{IP} =~ /^\[(?:::ffff:)?(\d+(?:\.\d+){3})\]:\d+$/);
        }
        foreach my $pluginName (@pluginsOrder) {
          if($plugins{$pluginName}->can('updateGameStatusInfo')) {
            my $p_pluginColumns=$plugins{$pluginName}->updateGameStatusInfo(\%clientStatus,$userLevel);
            if(ref($p_pluginColumns) eq 'HASH') {
              my @pluginColumns=keys %{$p_pluginColumns};
              map {$clientStatus{$_}=$p_pluginColumns->{$_}} @pluginColumns;
              $p_pluginColumns=\@pluginColumns;
            }
            foreach my $pluginColumn (@{$p_pluginColumns}) {
              $statusDataFromPlugin{$pluginColumn}=$pluginName unless(exists $statusDataFromPlugin{$pluginColumn});
            }
          }
        }
      }
      my %coloredStatus;
      foreach my $k (keys %clientStatus) {
        if(exists $statusDataFromPlugin{$k}) {
          $coloredStatus{"$C{6}$k$C{1}"}=$clientStatus{$k};
        }else{
          $coloredStatus{"$C{5}$k$C{1}"}=$clientStatus{$k};
        }
      }
      push(@clientsStatus,\%coloredStatus) if(exists $p_runningBattle->{users}{$spec} || (%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} < 0));
    }
  }
  my %globalStatus = ("$B$C{10}Game status$B$C{1}" => $ahState == 1 ? 'waiting for ready in game (since '.secToTime(time-$timestamps{lastGameStart}).')' : 'running since '.secToTime(time-$timestamps{lastGameStartPlaying}),
                      "$B$C{10}Map$B$C{1}" => $p_runningBattle->{map},
                      "$B$C{10}Mod$B$C{1}" => $p_runningBattle->{mod});
  if(ref $user) {
    $globalStatus{gameStatus} = $ahState == 1 ? 'waiting' : 'running';
    $globalStatus{gameTime} = $ahState == 1 ? time-$timestamps{lastGameStart} : time-$timestamps{lastGameStartPlaying};
  }
  return (\@clientsStatus,\%statusDataFromPlugin,\%globalStatus);
}

sub getBattleLobbyStatus {
  my $user=shift;
  
  return undef unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}});
  
  my $userLevel=getUserAccessLevel($user);
  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};

  my $battleStatus;
  if($springPid && $autohost->getState()) {
    $battleStatus='in-game';
  }else{
    $battleStatus='waiting for ';
    $battleStatus .= $timestamps{usLockRequestForGameStart} ? 'exclusive access to archives cache to start game' : 'ready players in battle lobby';
  }
  $battleStatus.=' (last game finished '.secToTime(time-$timestamps{lastGameEnd}).' ago)' if($timestamps{lastGameEnd});
  my %globalStatus = ("$B$C{10}Battle status$B$C{1}" => $battleStatus,
                      "$B$C{10}Game type$B$C{1}" => $currentGameType,
                      "$B$C{10}Map$B$C{1}" => $currentMap,
                      "$B$C{10}Mod$B$C{1}" => $lobby->{battles}{$lobby->{battle}{battleId}}{mod},
                      "$B$C{10}Preset$B$C{1}" => "$conf{preset} ($conf{description})");
  if(ref $user) {
    $globalStatus{battleStatus} = ($springPid && $autohost->getState()) ? 'running' : ($timestamps{usLockRequestForGameStart} ? 'preparing' : 'waiting');
    $globalStatus{delaySinceLastGame} = $timestamps{lastGameEnd} ? time-$timestamps{lastGameEnd} : undef;
  }
  
  my @clientsStatus;
  my %statusDataFromPlugin;
  {
    my %battleStructure;
    my @spectators;
    my $p_bUsers=$lobby->{battle}{users};
    my $p_bBots=$lobby->{battle}{bots};
    my %clansId=('' => '');
    my $userClanPref = ref $user ? '' : getUserPref($user,'clan');
    $clansId{$userClanPref}=$userClanPref if($userClanPref ne '');
    my $nextClanId=1;
    foreach my $player (keys %{$p_bUsers}) {
      if(defined $p_bUsers->{$player}{battleStatus} && $p_bUsers->{$player}{battleStatus}{mode}) {
        my $playerTeam=$p_bUsers->{$player}{battleStatus}{team};
        my $playerId=$p_bUsers->{$player}{battleStatus}{id};
        $battleStructure{$playerTeam}={} unless(exists $battleStructure{$playerTeam});
        $battleStructure{$playerTeam}{$playerId}=[] unless(exists $battleStructure{$playerTeam}{$playerId});
        push(@{$battleStructure{$playerTeam}{$playerId}},$player);
      }else{
        push(@spectators,$player) unless($springServerType eq 'dedicated' && $player eq $conf{lobbyLogin});
      }
      my $clanPref=getUserPref($player,'clan');
      $clansId{$clanPref}=':'.$nextClanId++.':' unless(exists $clansId{$clanPref});
    }
    return (\@clientsStatus,\%statusDataFromPlugin,\%globalStatus) unless(%battleStructure || @spectators);
    foreach my $bot (keys %{$p_bBots}) {
      my $botTeam=$p_bBots->{$bot}{battleStatus}{team};
      my $botId=$p_bBots->{$bot}{battleStatus}{id};
      $battleStructure{$botTeam}={} unless(exists $battleStructure{$botTeam});
      $battleStructure{$botTeam}{$botId}=[] unless(exists $battleStructure{$botTeam}{$botId});
      push(@{$battleStructure{$botTeam}{$botId}},$bot." (bot)");
    }
    foreach my $teamNb (sort {$a <=> $b} keys %battleStructure) {
      foreach my $idNb (sort {$a <=> $b} keys %{$battleStructure{$teamNb}}) {
        foreach my $player (sort @{$battleStructure{$teamNb}{$idNb}}) {
          my %clientStatus=(Name => $player,
                            Team => $teamNb+1,
                            Id => $idNb+1);
          if($player =~ /^(.+) \(bot\)$/) {
            my $botName=$1;
            $clientStatus{Rank}=$conf{botsRank};
            $clientStatus{Skill}="($RANK_SKILL{$conf{botsRank}})";
            $clientStatus{ID}="$p_bBots->{$botName}{aiDll} ($p_bBots->{$botName}{owner})";
          }else{
            $clientStatus{Ready}="$C{4}No$C{1}";
            $clientStatus{Ready}="$C{3}Yes$C{1}" if($p_bUsers->{$player}{battleStatus}{ready});
            if($userLevel >= $conf{privacyTrustLevel}) {
              if(defined $lobby->{users}{$player}{ip}) {
                $clientStatus{IP}=$lobby->{users}{$player}{ip};
              }elsif(defined $p_bUsers->{$player}{ip}) {
                $clientStatus{IP}=$p_bUsers->{$player}{ip};
              }
            }
            my $rank=$lobby->{users}{$player}{status}{rank};
            my $skill="$C{13}!$RANK_SKILL{$rank}!$C{1}";
            if(exists $battleSkills{$player}) {
              if($rank != $battleSkills{$player}{rank}) {
                my $diffRank=$battleSkills{$player}{rank}-$rank;
                $diffRank="+$diffRank" if($diffRank > 0);
                if($battleSkills{$player}{rankOrigin} eq 'ip') {
                  $diffRank="[$diffRank]";
                }elsif($battleSkills{$player}{rankOrigin} eq 'manual') {
                  $diffRank="($diffRank)";
                }elsif($battleSkills{$player}{rankOrigin} eq 'ipManual') {
                  $diffRank="{$diffRank}";
                }else{
                  $diffRank="<$diffRank>";
                }
                $rank="$rank$C{12}$diffRank$C{1}";
              }
              my $skillOrigin=$battleSkills{$player}{skillOrigin};
              my $skillSigma='';
              if(($skillOrigin eq 'TrueSkill' || $skillOrigin eq 'Plugin')
                 && exists $battleSkills{$player}{sigma}) {
                if($battleSkills{$player}{sigma} > 3) {
                  $skillSigma=' ???';
                }elsif($battleSkills{$player}{sigma} > 2) {
                  $skillSigma=' ??';
                }elsif($battleSkills{$player}{sigma} > 1.5) {
                  $skillSigma=' ?';
                }
              }
              if($skillOrigin eq 'rank') {
                $skill="($battleSkills{$player}{skill})";
              }elsif($skillOrigin eq 'TrueSkill') {
                if(exists $battleSkills{$player}{skillPrivacy}
                   && ($battleSkills{$player}{skillPrivacy} == 0
                       || ($battleSkills{$player}{skillPrivacy} == 1 && $userLevel >= $conf{privacyTrustLevel}))) {
                  $skill=$battleSkills{$player}{skill};
                }else{
                  $skill=getRoundedSkill($battleSkills{$player}{skill});
                  $skill="~$skill";
                }
                $skill="$C{6}$skill$skillSigma$C{1}";
              }elsif($skillOrigin eq 'TrueSkillDegraded') {
                $skill="$C{4}\#$battleSkills{$player}{skill}\#$C{1}";
              }elsif($skillOrigin eq 'Plugin') {
                $skill=$battleSkills{$player}{skill};
                $skill="$C{10}\[$skill$skillSigma\]$C{1}";
              }elsif($skillOrigin eq 'PluginDegraded') {
                $skill="$C{4}\[\#$battleSkills{$player}{skill}\#\]$C{1}";
              }else{
                $skill="$C{13}?$battleSkills{$player}{skill}?$C{1}";
              }
            }elsif($player eq $conf{lobbyLogin}) {
              $skill='';
            }else{
              slog("Undefined skill for player $player, using lobby rank instead in status command output!",1);
            }
            $clientStatus{Rank}=$rank;
            $clientStatus{Skill}=$skill;
            $clientStatus{ID}=$lobby->{users}{$player}{accountId};
            my $clanPref=getUserPref($player,'clan');
            $clientStatus{Clan}=$clansId{$clanPref} if($clanPref ne '');
            foreach my $pluginName (@pluginsOrder) {
              if($plugins{$pluginName}->can('updateStatusInfo')) {
                my $p_pluginColumns=$plugins{$pluginName}->updateStatusInfo(\%clientStatus,
                                                                            $lobby->{users}{$player}{accountId},
                                                                            $lobby->{battles}{$lobby->{battle}{battleId}}{mod},
                                                                            $currentGameType,
                                                                            $userLevel);
                if(ref($p_pluginColumns) eq 'HASH') {
                  my @pluginColumns=keys %{$p_pluginColumns};
                  map {$clientStatus{$_}=$p_pluginColumns->{$_}} @pluginColumns;
                  $p_pluginColumns=\@pluginColumns;
                }
                foreach my $pluginColumn (@{$p_pluginColumns}) {
                  $statusDataFromPlugin{$pluginColumn}=$pluginName unless(exists $statusDataFromPlugin{$pluginColumn});
                }
              }
            }
          }
          my %coloredStatus;
          foreach my $k (keys %clientStatus) {
            if(exists $statusDataFromPlugin{$k}) {
              $coloredStatus{"$C{6}$k$C{1}"}=$clientStatus{$k};
            }else{
              $coloredStatus{"$C{5}$k$C{1}"}=$clientStatus{$k};
            }
          }
          push(@clientsStatus,\%coloredStatus);
        }
      }
    }
    foreach my $spec (sort @spectators) {
      my %clientStatus=(Name => $spec);
      if($userLevel >= $conf{privacyTrustLevel}) {
        if(defined $lobby->{users}{$spec}{ip}) {
          $clientStatus{IP}=$lobby->{users}{$spec}{ip};
        }elsif(defined $p_bUsers->{$spec}{ip}) {
          $clientStatus{IP}=$p_bUsers->{$spec}{ip};
        }
      }
      my $rank=$lobby->{users}{$spec}{status}{rank};
      my $skill="$C{13}!$RANK_SKILL{$rank}!$C{1}";
      if(exists $battleSkills{$spec}) {
        if($rank != $battleSkills{$spec}{rank}) {
          my $diffRank=$battleSkills{$spec}{rank}-$rank;
          $diffRank="+$diffRank" if($diffRank > 0);
          if($battleSkills{$spec}{rankOrigin} eq 'ip') {
            $diffRank="[$diffRank]";
          }elsif($battleSkills{$spec}{rankOrigin} eq 'manual') {
            $diffRank="($diffRank)";
          }elsif($battleSkills{$spec}{rankOrigin} eq 'ipManual') {
            $diffRank="{$diffRank}";
          }else{
            $diffRank="<$diffRank>";
          }
          $rank="$rank$C{12}$diffRank$C{1}";
        }
        my $skillOrigin=$battleSkills{$spec}{skillOrigin};
        my $skillSigma='';
        if(($skillOrigin eq 'TrueSkill' || $skillOrigin eq 'Plugin')
           && exists $battleSkills{$spec}{sigma}) {
          if($battleSkills{$spec}{sigma} > 3) {
            $skillSigma=' ???';
          }elsif($battleSkills{$spec}{sigma} > 2) {
            $skillSigma=' ??';
          }elsif($battleSkills{$spec}{sigma} > 1.5) {
            $skillSigma=' ?';
          }
        }
        if($skillOrigin eq 'rank') {
          $skill="($RANK_SKILL{$battleSkills{$spec}{rank}})";
        }elsif($skillOrigin eq 'TrueSkill') {
          if(exists $battleSkills{$spec}{skillPrivacy}
             && ($battleSkills{$spec}{skillPrivacy} == 0
                 || ($battleSkills{$spec}{skillPrivacy} == 1 && $userLevel >= $conf{privacyTrustLevel}))) {
            $skill=$battleSkills{$spec}{skill};
          }else{
            $skill=getRoundedSkill($battleSkills{$spec}{skill});
            $skill="~$skill";
          }
          $skill="$C{6}$skill$skillSigma$C{1}";
        }elsif($skillOrigin eq 'TrueSkillDegraded') {
          $skill="$C{4}\#$battleSkills{$spec}{skill}\#$C{1}";
        }elsif($skillOrigin eq 'Plugin') {
          $skill=$battleSkills{$spec}{skill};
          $skill="$C{10}\[$skill$skillSigma\]$C{1}";
        }elsif($skillOrigin eq 'PluginDegraded') {
          $skill="$C{4}\[\#$battleSkills{$spec}{skill}\#\]$C{1}";
        }else{
          $skill="$C{13}?$battleSkills{$spec}{skill}?$C{1}";
        }
      }elsif($spec eq $conf{lobbyLogin}) {
        $skill='';
      }else{
        slog("Undefined skill for spectator $spec, using lobby rank instead in status command output!",1);
      }
      $clientStatus{Rank}=$rank;
      $clientStatus{Skill}=$skill;
      $clientStatus{ID}=$lobby->{users}{$spec}{accountId};
      my $clanPref=getUserPref($spec,'clan');
      $clientStatus{Clan}=$clansId{$clanPref} if($clanPref ne '');
      foreach my $pluginName (@pluginsOrder) {
        if($plugins{$pluginName}->can('updateStatusInfo')) {
          my $p_pluginColumns=$plugins{$pluginName}->updateStatusInfo(\%clientStatus,
                                                                      $lobby->{users}{$spec}{accountId},
                                                                      $lobby->{battles}{$lobby->{battle}{battleId}}{mod},
                                                                      $currentGameType,
                                                                      $userLevel);
          if(ref($p_pluginColumns) eq 'HASH') {
            my @pluginColumns=keys %{$p_pluginColumns};
            map {$clientStatus{$_}=$p_pluginColumns->{$_}} @pluginColumns;
            $p_pluginColumns=\@pluginColumns;
          }
          foreach my $pluginColumn (@{$p_pluginColumns}) {
            $statusDataFromPlugin{$pluginColumn}=$pluginName unless(exists $statusDataFromPlugin{$pluginColumn});
          }
        }
      }
      my %coloredStatus;
      foreach my $k (keys %clientStatus) {
        if(exists $statusDataFromPlugin{$k}) {
          $coloredStatus{"$C{6}$k$C{1}"}=$clientStatus{$k};
        }else{
          $coloredStatus{"$C{5}$k$C{1}"}=$clientStatus{$k};
        }
      }
      push(@clientsStatus,\%coloredStatus);
    }
  }
  return (\@clientsStatus,\%statusDataFromPlugin,\%globalStatus);
}

sub hStatus {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} == -1) {
    if($springPid && $autohost->getState()) {
      $p_params->[0]="game";
    }else{
      $p_params->[0]="battle";
    }
  }

  if($#{$p_params} != 0) {
    invalidSyntax($user,"status");
    return 0;
  }
  if($p_params->[0] eq "game") {
    if(! ($springPid && $autohost->getState())) {
      answer("Unable to retrieve game status, game is not running");
      return 0;
    }
  }elsif($p_params->[0] eq "battle") {
    if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}}) {
      answer("Unable to retrieve battle status, battle is closed");
      return 0;
    }
  }else{
    invalidSyntax($user,"status");
    return 0;
  }
  return 1 if($checkOnly);

  my $userLevel=getUserAccessLevel($user);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};

  my ($r_clientsStatus,$r_statusDataFromPlugin,$r_globalStatus,@defaultStatusColumns);
  if($p_params->[0] eq 'game') {
    ($r_clientsStatus,$r_statusDataFromPlugin,$r_globalStatus)=getGameStatus($user);
    if(@{$r_clientsStatus}) {
      @defaultStatusColumns=qw'Name Team Id';
      push(@defaultStatusColumns,'Ready') if(($p_runningBattle->{scriptTags}{'game/startpostype'} // 2) == 2);
      push(@defaultStatusColumns,'Status','Version');
    }else{
      sayPrivate($user,"$C{7}Game is empty");
      sayPrivate($user,"=============");
    }
  }else{
    ($r_clientsStatus,$r_statusDataFromPlugin,$r_globalStatus)=getBattleLobbyStatus($user);
    if(@{$r_clientsStatus}) {
      @defaultStatusColumns=qw'Name Team Id Clan Ready Rank Skill ID';
    }else{
      sayPrivate($user,"$C{7}Battle lobby is empty");
      sayPrivate($user,"=====================");
    }
  }
  if(@defaultStatusColumns) {
    my @newPluginStatusColumns;
    foreach my $pluginColumn (keys %{$r_statusDataFromPlugin}) {
      push(@newPluginStatusColumns,$pluginColumn) unless(any {$pluginColumn eq $_} (@defaultStatusColumns,'IP'));
    }
    my @statusFields;
    foreach my $statusField (@defaultStatusColumns,@newPluginStatusColumns,'IP') {
      next if($statusField eq 'IP' && $userLevel < $conf{privacyTrustLevel});
      if(exists $r_statusDataFromPlugin->{$statusField}) {
        push(@statusFields,"$C{6}$statusField$C{1}");
      }else{
        push(@statusFields,"$C{5}$statusField$C{1}");
      }
    }
    my $p_statusLines=formatArray(\@statusFields,$r_clientsStatus);
    foreach my $statusLine (@{$p_statusLines}) {
      sayPrivate($user,$statusLine);
    }
  }
  foreach my $globalStatusField (sort keys %{$r_globalStatus}) {
    sayPrivate($user,"$globalStatusField: $r_globalStatus->{$globalStatusField}");
  }
  if(%bosses) {
    my $bossList=join(",",keys %bosses);
    sayPrivate($user,"$B$C{10}Boss mode activated for$B$C{1}: $bossList");
  }
  my ($voteString)=getVoteStateMsg();
  sayPrivate($user,$voteString) if(defined $voteString);
  sayPrivate($user,"Some pending settings need rehosting to be applied") if(needRehost());
  sayPrivate($user,'Spring archives are being reloaded since '.(secToTime(time-$timestamps{archivesLoad}))) if($loadArchivesInProgress);
  if(defined $quitAfterGame{action}) {
    my $quitAction=('quit','restart')[$quitAfterGame{action}];
    my $quitCondition=('after this game','as soon as the battle only contains spectators and no game is running','as soon as the battle is empty and no game is running')[$quitAfterGame{condition}];
    sayPrivate($user,"SPADS will $quitAction $quitCondition");
  }elsif($closeBattleAfterGame) {
    if($closeBattleAfterGame == 1) {
      sayPrivate($user,"The battle will be closed after this game");
    }elsif($closeBattleAfterGame == 2) {
      sayPrivate($user,"The battle will be rehosted after this game");
    }
  }
  return 1;
}

sub hStop {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($springPid == 0) {
    answer("Unable to stop game, it is not running");
    return 0;
  }else{
    return 1 if($checkOnly);
    if($autohost->getState()) {
      broadcastMsg("Stopping server (by $user)");
      answer("Stopping server") if($source eq "pv");
      $timestamps{autoStop}=-1;
      $autohost->sendChatMessage("/kill");
    }elsif(MSWIN32) {
      if($conf{useWin32Process} && defined $springWin32Process) {
        broadcastMsg("Killing Spring process (by $user)");
        answer("Killing Spring process") if($source eq "pv");
        $springWin32Process->Kill(137);
      }else{
        broadcastMsg("Unable to stop server, a manual process kill may be required!");
        slog("Spring server is in inconsistent state, a manual process kill may be required!",2);
        slog("You can try to use native Win32 process instead of Perl emulated process (useWin32Process setting) if this problem occurs regularly",2) if(! $conf{useWin32Process});
      }
      $autohost->serverQuitHandler() if($autohost->{state});
    }else{
      broadcastMsg("Killing Spring process (by $user)");
      answer("Killing Spring process") if($source eq "pv");
      kill(15,$springPid);
      $autohost->serverQuitHandler() if($autohost->{state});
    }
  }

  return 1;
}

sub hUnban {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"unban");
    return 0;
  }

  my $bannedUser=$p_params->[0];

  if($bannedUser =~ /^\(([a-zA-Z0-9\+\/]{5})\)$/) {
    my $banHash=$1;
    my $res=$spads->removeBanByHash($banHash,$checkOnly);
    if($res) {
      return 1 if($checkOnly);
      sayPrivate($user,"Following dynamic ban entry has been removed:");
      my $p_banEntries=listBans([$res],getUserAccessLevel($user) >= $conf{privacyTrustLevel},$user);
      foreach my $banEntry (@{$p_banEntries}) {
        sayPrivate($user,$banEntry);
      }
      return 1;
    }else{
      answer("Unable to find any dynamic ban entry with hash \"$banHash\"");
      return 0;
    }
  }

  my @banFilters=split(/;/,$bannedUser);
  my $p_filters={};
  my @banListsFields=qw'accountId name country rank access bot level ip skill skillUncert nameOrAccountId';
  foreach my $banFilter (@banFilters) {
    my ($filterName,$filterValue)=('nameOrAccountId',$banFilter);
    if($banFilter =~ /^\#([1-9]\d*)$/) {
      ($filterName,$filterValue)=('accountId',$1);
    }elsif($banFilter =~ /^([^=<>]+)=(.+)$/) {
      ($filterName,$filterValue)=($1,$2);
    }elsif($banFilter =~ /^([^=<>]+)([<>]=?.+)$/) {
      ($filterName,$filterValue)=($1,$2);
    }
    if(any {$filterName eq $_} @banListsFields) {
      $p_filters->{$filterName}=$filterValue;
    }else{
      invalidSyntax($user,"unban","invalid ban filter name \"$filterName\"");
      return 0;
    }
  }

  if(! exists $p_filters->{nameOrAccountId}) {
    if(! $spads->banExists($p_filters)) {
      answer("Unable to find matching dynamic ban entry for \"$bannedUser\"");
      return 0;
    }
    return 1 if($checkOnly);
    $spads->unban($p_filters);
  }else{
    my %instantiatedFilters=%{$p_filters};
    my $nameOrAccountId=delete $instantiatedFilters{nameOrAccountId};
    $instantiatedFilters{name}=$nameOrAccountId;
    my $banExists=0;
    if($spads->banExists(\%instantiatedFilters)) {
      return 1 if($checkOnly);
      $banExists=1;
      $spads->unban(\%instantiatedFilters);
    }
    if(exists $p_filters->{name}) {
      $instantiatedFilters{name}=$p_filters->{name};
    }else{
      delete $instantiatedFilters{name};
    }
    $instantiatedFilters{accountId}="($nameOrAccountId)";
    if($spads->banExists(\%instantiatedFilters)) {
      return 1 if($checkOnly);
      $banExists=1;
      $spads->unban(\%instantiatedFilters);
    }
    my $accountId=getLatestUserAccountId($nameOrAccountId);
    if($accountId) {
      $instantiatedFilters{accountId}=$accountId;
      if($spads->banExists(\%instantiatedFilters)) {
        return 1 if($checkOnly);
        $banExists=1;
        $spads->unban(\%instantiatedFilters);
      }
    }
    if(! $banExists) {
      answer("Unable to find matching dynamic ban entry for \"$bannedUser\"");
      return 0;
    }
  }

  answer("$bannedUser unbanned");
}

sub hUnbanIp {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"unbanip");
    return 0;
  }

  my $bannedUser=$p_params->[0];

  my $userIp;
  my $banMode='user';
  if($bannedUser =~ /^\#([1-9]\d*)$/) {
    my $id=$1;
    $banMode='account';
    $userIp=$spads->getLatestAccountIp($id);
    if(! $userIp) {
      if($conf{userDataRetention} !~ /^0;/ && ! $spads->isStoredAccount($id)) {
        answer("Unable to unban account $bannedUser by IP (unknown account ID, try !searchUser first)");
      }else{
        answer("Unable to unban account $bannedUser by IP (IP unknown)");
      }
      return 0;
    }
  }else{
    $userIp=getLatestUserIp($bannedUser);
    if(! $userIp) {
      if($conf{userDataRetention} !~ /^0;/ && ! $spads->isStoredUser($bannedUser)) {
        answer("Unable to unban user \"$bannedUser\" by IP (unknown user, try !searchUser first)");
      }else{
        answer("Unable to unban user \"$bannedUser\" by IP (IP unknown)");
      }
      return 0;
    }
  }

  if(! $spads->banExists({ip => $userIp})) {
    answer("Unable to find matching dynamic IP ban entry for $banMode $bannedUser");
    return 0;
  }

  return 1 if($checkOnly);

  $spads->unban({ip => $userIp});
  answer("IP of $banMode $bannedUser unbanned");
}

sub hUnbanIps {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"unbanips");
    return 0;
  }

  my $bannedUser=$p_params->[0];

  if($conf{userDataRetention} =~ /^0;/) {
    answer("Unable to unban by IP (user data retention is disabled on this AutoHost)");
    return 0;
  }

  my $p_userIps;
  my $banMode='user';
  if($bannedUser =~ /^\#([1-9]\d*)$/) {
    my $id=$1;
    $banMode='account';
    if(! $spads->isStoredAccount($id)) {
      answer("Unable to unban account $bannedUser by IP (unknown account ID, try !searchUser first)");
      return 0;
    }
    $p_userIps=$spads->getAccountIps($id);
    if(! @{$p_userIps}) {
      answer("Unable to unban account $bannedUser by IP (IP unknown)");
      return 0;
    }
  }else{
    if(! $spads->isStoredUser($bannedUser)) {
      answer("Unable to unban user \"$bannedUser\" by IP (unknown user, try !searchUser first)");
      return 0;
    }
    $p_userIps=getUserIps($bannedUser);
    if(! @{$p_userIps}) {
      answer("Unable to unban user \"$bannedUser\" by IP (IP unknown)");
      return 0;
    }
  }

  my $banExists=0;
  foreach my $userIp (@{$p_userIps}) {
    if($spads->banExists({ip => $userIp})) {
      $banExists=1;
      last;
    }
  }
  if(! $banExists) {
    answer("Unable to find matching dynamic IP ban entry for $banMode $bannedUser");
    return 0;
  }
  return 1 if($checkOnly);

  foreach my $userIp (@{$p_userIps}) {
    $spads->unban({ip => $userIp});
  }
  answer("IPs of $banMode $bannedUser unbanned");
}

sub hUnlock {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,"unlock");
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer("Unable to unlock battle lobby, battle is closed");
    return 0;
  }

  if(! $manualLockedStatus) {
    my $reason='it is not locked manually';
    my @clients=keys %{$lobby->{battle}{users}};
    if($conf{autoLockClients} && $#clients >= $conf{autoLockClients}) {
      $reason="maximum number of clients ($conf{autoLockClients}) reached";
    }elsif($conf{autoLockRunningBattle} && $lobby->{users}{$conf{lobbyLogin}}{status}{inGame}) {
      $reason='battle is running and autoLockRunningBattle is enabled';
    }elsif($conf{autoLock} ne 'off') {
      $reason='autoLock is enabled';
    }else{
      my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
      my @bots=keys %{$lobby->{battle}{bots}};
      my $nbNonPlayer=getNbNonPlayer();
      my $nbPlayers=$#clients+1-$nbNonPlayer;
      if($conf{nbTeams} != 1) {
        $nbPlayers+=$#bots+1;
      }
      if($conf{maxSpecs} ne '' && $nbNonPlayer > $conf{maxSpecs}
         && ($nbPlayers >= $spads->{hSettings}{maxPlayers} || ($conf{autoSpecExtraPlayers} && $nbPlayers >= $targetNbPlayers))) {
        $reason='maximum number of players and spectators reached for this autohost';
      }
    }
    answer('Cannot unlock battle, '.$reason);
    return 0;
  }
  return 1 if($checkOnly);
  $manualLockedStatus=0;
  $timestamps{battleChange}=time;
  updateBattleInfoIfNeeded();
}

sub hUnlockSpec {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,'unlockspec');
    return 0;
  }
  if($lobbyState < LOBBY_STATE_BATTLE_OPENED) {
    answer('Unable to unlock battle lobby for spectator, battle is closed');
    return 0;
  }
  my $nbSpec=getNbSpec();
  my @unlockSpecDelay=split(/;/,$conf{unlockSpecDelay});
  my @clients=keys %{$lobby->{battle}{users}};
  my $reason='';
  if($unlockSpecDelay[0] == 0) {
    $reason='this command is disabled on this autohost';
  }elsif(exists $lobby->{battle}{users}{$user}) {
    $reason='you are already in the battle';
  }elsif(! $currentLockedStatus) {
    $reason='it is not locked currently';
  }elsif($conf{autoLockClients} && $#clients >= $conf{autoLockClients}) {
    $reason="maximum client number ($conf{autoLockClients}) reached for this autohost";
  }elsif($conf{autoLockRunningBattle} && $lobby->{users}{$conf{lobbyLogin}}{status}{inGame}) {
    $reason='battle is running and autoLockRunningBattle is enabled';
  }elsif($manualLockedStatus) {
    $reason='it has been locked manually';
  }elsif($conf{maxSpecs} ne '' && $nbSpec > $conf{maxSpecs}
         && getUserAccessLevel($user) < $conf{maxSpecsImmuneLevel} 
         && ! ($springPid && $autohost->getState()
               && exists $p_runningBattle->{users}{$user} && defined $p_runningBattle->{users}{$user}{battleStatus} && $p_runningBattle->{users}{$user}{battleStatus}{mode}
               && (! %{$autohost->getPlayer($user)} || $autohost->getPlayer($user)->{lost} == 0))) {
    $reason="maximum spectator number ($conf{maxSpecs}) reached for this autohost";
  }elsif(exists $pendingSpecJoin{$user} && time - $pendingSpecJoin{$user} < $unlockSpecDelay[1]) {
    $reason='please wait '.($pendingSpecJoin{$user} + $unlockSpecDelay[1] - time).'s before reusing this command';
  }elsif(! exists $lobby->{users}{$user}) {
    $reason='you are not connected to lobby server';
  }else{
    my $p_ban=$spads->getUserBan($user,$lobby->{users}{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
    $reason='you are banned' if($p_ban->{banType} < 2);
  }
  if($reason) {
    answer("Cannot unlock battle for spectator, $reason");
    return 0;
  }
  return 1 if($checkOnly);
  sayBattle("$user is joining as spectator");
  $pendingSpecJoin{$user}=time;
  $timestamps{battleChange}=time;
  updateBattleInfoIfNeeded();
}

sub hUpdate {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my $release;
  if($#{$p_params} == -1) {
    my $failureReason;
    if($conf{autoUpdateRelease} eq '') {
      $failureReason='undefined';
    }elsif(substr($conf{autoUpdateRelease},0,4) eq 'git@' && substr($conf{autoUpdateRelease},4,7) ne 'branch=') {
      $failureReason='set to a fixed version';
    }
    if(defined $failureReason) {
      answer("Unable to update: release not specified and autoUpdateRelease setting is $failureReason");
      return 0;
    }
    $release=$conf{autoUpdateRelease};
  }elsif($#{$p_params} == 0) {
    $release=$p_params->[0];
    if((none {$release eq $_} qw'stable testing unstable contrib') && $release !~ /^git(?:\@(?:[\da-f]{4,40}|branch=[\w\-\.\/]+|tag=[\w\-\.\/]+))?$/) {
      invalidSyntax($user,"update","invalid release \"$release\"");
      return 0;
    }
  }else{
    invalidSyntax($user,"update");
    return 0;
  }
  return 1 if($checkOnly);
  if($updater->isUpdateInProgress()) {
    answer('Unable to update: another updater instance is already running');
    return 0;
  }
  
  $updater = SpadsUpdater->new(sLog => $updaterSimpleLog,
                               repository => "http://planetspads.free.fr/spads/repository",
                               release => $release,
                               packages => \@SPADS_PACKAGES,
                               springDir => $conf{autoManagedSpringDir});
  if(! SimpleEvent::forkCall(
         sub { return $updater->update() },
         sub {
           my $updateRc = shift // -12;
           my $answerMsg;
           if($updateRc < 0) {
             if($updateRc == -7) {
               $answerMsg="Unable to update SPADS components (manual action required for new major version), please check logs for further information" ;
             }else{
               $answerMsg="Unable to update SPADS components (error code: $updateRc), please check logs for further information";
             }
           }elsif($updateRc == 0) {
             my ($isDynamicVersion,$versionDesc);
             if(substr($release,0,3) eq 'git') {
               if(substr($release,3,1) eq '@') {
                 if(substr($release,4,4) eq 'tag=') {
                   $versionDesc='Git tag "'.substr($release,8).'"';
                 }elsif(substr($release,4,7) eq 'branch=') {
                   $versionDesc='on Git branch "'.substr($release,11).'"';
                   $isDynamicVersion=1;
                 }else{
                   $versionDesc='Git commit "'.substr($release,4).'"';
                 }
               }else{
                 $versionDesc='on Git repository';
                 $isDynamicVersion=1;
               }
             }else{
               $versionDesc="for release \"$release\"";
               $isDynamicVersion=1;
             }
             if($isDynamicVersion) {
               $answerMsg="No update available $versionDesc (SPADS components are already up to date)";
             }else{
               $answerMsg="No local update required for $versionDesc";
             }
           }else{
             $answerMsg="$updateRc SPADS component(s) updated (a restart is needed to apply modifications)";
           }
           sayPrivate($user,$answerMsg);
           onUpdaterCallEnd($updateRc,substr($release,0,3) eq 'git');
         })) {
    answer("Unable to update: cannot fork to launch SPADS updater");
    return 0;
  }
  return 1;
}

sub hVersion {
  my (undef,$user,undef,$checkOnly)=@_;
  
  return 1 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $springVersion=$syncedSpringVersion.$C{1};
  my $autoDlExtraInfo = defined $autoManagedEngineData{github} ? " from GitHub:$autoManagedEngineData{github}{owner}/$autoManagedEngineData{github}{name}" : '';
  if($autoManagedEngineData{mode} eq 'version') {
    my $autoDlInfo='auto-downloaded'.$autoDlExtraInfo;
    $springVersion.=" ($autoDlInfo)";
  }elsif($autoManagedEngineData{mode} eq 'release') {
    my $autoDlInfo="\"$autoManagedEngineData{release}\"".$autoDlExtraInfo;
    $springVersion.=" (auto-download $autoDlInfo)";
  }
  sayPrivate($user,"$C{12}$conf{lobbyLogin}$C{1} is running ${B}$C{5}SPADS $C{10}v$SPADS_VERSION$B$C{1} with following components:");
  my %versionedComponents=(Perl => $^V."$C{1} ($Config{archname})",
                           "Spring $springServerType" => 'v'.$springVersion,
                           SimpleEvent => 'v'.SimpleEvent::getVersion());
  my %components = (SpringLobbyInterface => $lobby,
                    SpringAutoHostInterface => $autohost,
                    SpadsConf => $spads,
                    SimpleLog => $sLog,
                    SpadsUpdater => $updater);
  foreach my $module (keys %components) {
    $versionedComponents{$module}='v'.$components{$module}->getVersion();
  }
  my @sharedData=grep {$spads->{sharedDataTs}{$_}} (keys %{$spads->{sharedDataTs}});
  $versionedComponents{SpadsConf}.=$C{1}.' (shared:'.join(',',sort @sharedData).')' if(@sharedData);
  $versionedComponents{SpringLobbyInterface}.=$C{1}.' (TLS '.($useTls?'enabled':'disabled').')';
  my $simpleEventModel=SimpleEvent::getModel();
  if(defined $simpleEventModel && $simpleEventModel ne 'internal') {
    $versionedComponents{AnyEvent}='v'.$AnyEvent::VERSION."$C{1} ($simpleEventModel)";
  }
  $versionedComponents{'IO::Socket::SSL'}='v'.$IO::Socket::SSL::VERSION if(defined $IO::Socket::SSL::VERSION);
  $versionedComponents{'DBD::SQLite'}="v$DBD::SQLite::VERSION $C{1}(SQLite $spads->{preferences}{sqlite_version})" if($spads->{sharedDataTs}{preferences});
  if(my $inlinePythonVer=getPerlModuleVersion('Inline::Python')) {
    my $inlinePythonVer="v$inlinePythonVer";
    my $r_pythonVer=eval "Inline::Python::py_eval('[sys.version_info[i] for i in range(0,3)]',0)";
    if(! $@ && ref($r_pythonVer) eq 'ARRAY') {
      my $pythonVer=join('.',@{$r_pythonVer}[0,1,2]);
      $inlinePythonVer.=" $C{1}(Python $pythonVer)";
    }
    $versionedComponents{'Inline::Python'}=$inlinePythonVer;
  }
  $versionedComponents{SpringLobbyProtocol}='v'.$SpringLobbyProtocol::VERSION
      if(defined $SpringLobbyProtocol::VERSION);
  foreach my $component (sort keys %versionedComponents) {
    sayPrivate($user,"- $C{5}$component$C{10} $versionedComponents{$component}");
  }
  foreach my $pluginName (@pluginsOrder) {
    my $pluginVersion=$plugins{$pluginName}->getVersion();
    sayPrivate($user,"- $C{3}$pluginName$C{10} v$pluginVersion$C{1} (plugin)");
  }

  if($conf{autoUpdateRelease}) {
    my ($autoUpdateStatus,$autoUpdateDelayString);
    if($conf{autoUpdateDelay} && (substr($conf{autoUpdateRelease},0,4) ne 'git@' || substr($conf{autoUpdateRelease},4,7) eq 'branch=')) {
      my $autoUpdateCheckType;
      if(defined $periodicAutoUpdateLockAcquired) {
        $autoUpdateStatus=$periodicAutoUpdateLockAcquired?"$C{3}enabled$C{1}":"on $C{10}standby$C{1}";
        $autoUpdateCheckType='next';
      }else{
        $autoUpdateStatus="$C{3}enabled$C{1}";
        $autoUpdateCheckType='first periodic';
      }
      my $autoUpdateDelayTime=secToTime($conf{autoUpdateDelay} * 60);
      my $remainingSec=$timestamps{autoUpdate} + ($conf{autoUpdateDelay} * 60) - time;
      $remainingSec=1 if($remainingSec<1);
      $autoUpdateDelayString="$autoUpdateDelayTime ($autoUpdateCheckType check in ".(secToBriefTime($remainingSec)).')';
    }else{
      $autoUpdateStatus="$C{7}enabled at startup only$C{1}";
    }
    
    sayPrivate($user,"$C{12}Auto-update$C{1} is $autoUpdateStatus");
    
    my $autoUpdateRelease;
    if($conf{autoUpdateRelease} eq 'stable') {
      $autoUpdateRelease=$C{3};
    }elsif($conf{autoUpdateRelease} eq 'testing') {
      $autoUpdateRelease=$C{7};
    }elsif($conf{autoUpdateRelease} eq 'unstable') {
      $autoUpdateRelease=$C{4};
    }elsif($conf{autoUpdateRelease} eq 'contrib') {
      $autoUpdateRelease=$C{6};
    }else{
      $autoUpdateRelease=$C{13};
    }
    $autoUpdateRelease.="$conf{autoUpdateRelease}$C{1}";
    
    sayPrivate($user,"- $C{5}release$C{1}: $autoUpdateRelease");
    sayPrivate($user,"- $C{5}check delay$C{1}: $autoUpdateDelayString") if(defined $autoUpdateDelayString);
    
  }else{
    sayPrivate($user,"$C{12}Auto-update$C{1} is $C{4}disabled$C{1}")
  }

  my $autoRestartMode = {off => "$C{4}disabled$C{1}",
                         whenEmpty => 'when no game is running and battle room is empty',
                         whenOnlySpec => 'when no game is running and battle room is empty or contains only spectators',
                         on => 'when no game is running'}->{$conf{autoRestartForUpdate}};
  sayPrivate($user,"- $C{5}auto-restart$C{1}: $autoRestartMode");

}

sub hVote {
  my ($source,$user,$p_params,$checkOnly)=@_;

  return 0 if($checkOnly);

  if($#{$p_params} != 0) {
    invalidSyntax($user,'vote');
    return 0;
  }

  my $vote=lc($p_params->[0]);
  $vote='y' if($vote eq '1');
  $vote='n' if($vote eq '2');
  my $isInvalid=1;
  foreach my $choice (qw'yes no blank') {
    if(index($choice,$vote) == 0) {
      $vote=$choice;
      $isInvalid=0;
      last;
    }
  }
  if($isInvalid) {
    invalidSyntax($user,'vote');
    return 0;
  }

  if(! exists $currentVote{command}) {
    answer("$user, you cannot vote currently, there is no vote in progress.");
    return 0;
  }

  if(! (exists $currentVote{remainingVoters}{$user} || exists $currentVote{awayVoters}{$user} || exists $currentVote{manualVoters}{$user})) {
    answer("$user, you are not allowed to vote for current vote.");
    return 0;
  }

  if(exists $currentVote{remainingVoters}{$user}) {
    delete $currentVote{remainingVoters}{$user};
  }elsif(exists $currentVote{awayVoters}{$user}) {
    delete $currentVote{awayVoters}{$user};
    --$currentVote{blankCount};
  }elsif(exists $currentVote{manualVoters}{$user}) {
    if($currentVote{manualVoters}{$user} eq $vote) {
      answer("$user, you have already voted for current vote.");
      return 0;
    }
    --$currentVote{$currentVote{manualVoters}{$user}.'Count'};
  }

  $currentVote{manualVoters}{$user}=$vote;
  ++$currentVote{$vote.'Count'};

  setUserPref($user,'voteMode','normal') if(getUserPref($user,'autoSetVoteMode'));

  printVoteState();
  return 1;
}

sub hWhois {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,'whois');
    return 0;
  }

  if($conf{userDataRetention} =~ /^0;/) {
    answer("Unable to retrieve account data (user data retention is disabled on this AutoHost)");
    return 0;
  }

  return 1 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $userLevel=getUserAccessLevel($user);
  my $search=$p_params->[0];
  my $id;
  if($search =~ /^\@((?:\d+\.){3}\d+)$/) {
    my $ip=$1;
    if($userLevel < $conf{privacyTrustLevel}) {
      answer("Unable to search for user accounts by IP (insufficient privileges)");
      return 0;
    }
    if($spads->isStoredIp($ip)) {
      $id=$spads->getLatestIpAccountId($ip);
    }else{
      answer("Unable to retrieve account data (IP unknown)");
      return 0;
    }
  }elsif($search =~ /^\#([1-9]\d*)$/) {
    $id=$1;
    if(! $spads->isStoredAccount($id)) {
      answer("Unable to retrieve account data (account ID unknown)");
      return 0;
    }
  }else{
    if($spads->isStoredUser($search)) {
      $id=$spads->getLatestUserAccountId($search);
    }else{
      answer("Unable to retrieve account data (unknown user \"$search\", try !searchUser first)");
      return 0;
    }
  }

  my $p_accountMainData=$spads->getAccountMainData($id);
  my $p_accountNames=$spads->getAccountNamesTs($id);
  my $p_accountIps=$spads->getAccountIpsTs($id);

  my @idNames=sort {$p_accountNames->{$b} <=> $p_accountNames->{$a}} (keys %{$p_accountNames});
  my @idIps=sort {$p_accountIps->{$b} <=> $p_accountIps->{$a}} (keys %{$p_accountIps});
  my $currentName=shift(@idNames);

  my ($idOnly,$idName)=($id,undef);
  ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);

  my $online;
  if($idOnly) {
    $online=exists $lobby->{accounts}{$idOnly} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
  }else{
    $online=exists $lobby->{users}{$idName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
  }

  my $rank=abs($p_accountMainData->{rank});
  if($p_accountMainData->{rank} >= 0) {
    my $effectiveRank=getAccountPref($id,'rankMode');
    if($effectiveRank eq 'ip') {
      my $ip=$spads->getLatestAccountIp($id);
      if($ip) {
        my $chRanked;
        ($effectiveRank,$chRanked)=getIpRank($ip);
        if($effectiveRank > $rank) {
          my $diffRank=$effectiveRank-$rank;
          $diffRank="+$diffRank";
          if($chRanked) {
            $diffRank="\{$diffRank\}";
          }else{
            $diffRank="\[$diffRank\]";
          }
          $rank="$rank$C{12}$diffRank$C{1}";
        }
      }
    }elsif($effectiveRank =~ /^\d+$/ && $rank != $effectiveRank) {
      my $diffRank=$effectiveRank-$rank;
      $diffRank="+$diffRank" if($diffRank > 0);
      $rank="$rank$C{12}($diffRank)$C{1}";
    }
  }

  my %mainData=("$C{5}AccountId$C{1}" => $idOnly,
                "$C{5}Name$C{1}" => $currentName,
                "$C{5}Online$C{1}" => $online,
                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                "$C{5}LobbyClient$C{1}" => $p_accountMainData->{lobbyClient},
                "$C{5}Rank$C{1}" => $rank,
                "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_accountMainData->{timestamp}));

  my @names;
  foreach my $name (@idNames) {
    my $secAge=time-$p_accountNames->{$name};
    my $color;
    if($secAge < 3600) {
      $color=$C{3};
    }elsif($secAge < 86400) {
      $color=$C{10};
    }elsif($secAge < 172800) {
      $color=$C{12};
    }elsif($secAge < 1209600) {
      $color=$C{1};
    }else{
      $color=$C{14};
    }
    push(@names,{"$C{5}Name$C{1}" => $name,
                 "$C{5}LastUpdate$C{1}" => $color.secToDayAge($secAge).$C{1}});
  }

  my @ips;
  foreach my $ip (@idIps) {
    my $secAge=time-$p_accountIps->{$ip};
    my $color;
    if($secAge < 3600) {
      $color=$C{3};
    }elsif($secAge < 86400) {
      $color=$C{10};
    }elsif($secAge < 172800) {
      $color=$C{12};
    }elsif($secAge < 1209600) {
      $color=$C{1};
    }else{
      $color=$C{14};
    }
    push(@ips,{"$C{5}IP$C{1}" => $ip,
               "$C{5}LastUpdate$C{1}" => $color.secToDayAge($secAge).$C{1}});
  }
  
  sayPrivate($user,'.');

  my $p_resultLines=formatArray(["$C{5}AccountId$C{1}","$C{5}Name$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}LobbyClient$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}"],[\%mainData],"$C{2}Account information$C{1}");
  foreach my $resultLine (@{$p_resultLines}) {
    sayPrivate($user,$resultLine);
  }
  
  $p_resultLines=[];
  sayPrivate($user,'.') if(@names || (@ips && $userLevel >= $conf{privacyTrustLevel}));
  
  my $firstArrayWidth=0;
  if(@names) {
    $p_resultLines=formatArray(["$C{5}Name$C{1}","$C{5}LastUpdate$C{1}"],\@names,"$C{2}Previous names$C{1}");
    $firstArrayWidth=realLength($p_resultLines->[1]);
  }
  
  if(@ips && $userLevel >= $conf{privacyTrustLevel}) {
    my $p_resultLines2=formatArray(["$C{5}IP$C{1}","$C{5}LastUpdate$C{1}"],\@ips,"$C{2}IPs$C{1}");
    foreach my $i (0..$#{$p_resultLines2}) {
      $p_resultLines->[$i]=' ' x $firstArrayWidth unless(defined $p_resultLines->[$i]);
      $p_resultLines->[$i].='      ' if($firstArrayWidth);
      $p_resultLines->[$i].=$p_resultLines2->[$i];
    }
  }

  foreach my $resultLine (@{$p_resultLines}) {
    sayPrivate($user,$resultLine);
  }
}

sub hSkill {
  my ($source,$user,$p_params)=@_;
  if($user ne $sldbLobbyBot) {
    slog("Ignoring skill data received from unknown client",1);
    return;
  }
  my $needRebalance=0;
  foreach my $skillParam (@{$p_params}) {
    if($skillParam =~ /^(\d+)\|(\d)(.*)$/) {
      my ($accountId,$status,$skills)=($1,$2,$3);
      delete $pendingGetSkills{$accountId};
      if(! exists $lobby->{accounts}{$accountId}) {
        slog("Ignoring skill data received for offline account ($accountId)",2);
        next;
      }
      my $player=$lobby->{accounts}{$accountId};
      my $skillPref=getUserPref($player,'skillMode');
      if($skillPref ne 'TrueSkill') {
        slog("Ignoring skill data received for player $player with skillMode set to \"$skillPref\" ($accountId)",2);
        next;
      }
      if(! exists $battleSkills{$player}) {
        slog("Ignoring skill data received for player out of battle ($player)",2);
        next;
      }
      my $previousPlayerSkill=$battleSkills{$player}{skill};
      if($status == 0) {
        if($skills =~ /^\|(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)$/) {
          my ($privacyMode,$duelSkill,$duelSigma,$duelClass,$ffaSkill,$ffaSigma,$ffaClass,$teamSkill,$teamSigma,$teamClass,$teamFfaSkill,$teamFfaSigma,$teamFfaClass)=($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13);
          $battleSkillsCache{$player}={Duel => {skill => $duelSkill, sigma => $duelSigma, class => $duelClass},
                                       FFA => {skill => $ffaSkill, sigma => $ffaSigma, class => $ffaClass},
                                       Team => {skill => $teamSkill, sigma => $teamSigma, class => $teamClass},
                                       TeamFFA => {skill => $teamFfaSkill, sigma => $teamFfaSigma, class => $teamFfaClass}};
          $battleSkills{$player}{skill}=$battleSkillsCache{$player}{$currentGameType}{skill};
          $battleSkills{$player}{sigma}=$battleSkillsCache{$player}{$currentGameType}{sigma};
          $battleSkills{$player}{class}=$battleSkillsCache{$player}{$currentGameType}{class};
          $battleSkills{$player}{skillOrigin}='TrueSkill';
          $battleSkills{$player}{skillPrivacy}=$privacyMode;
        }else{
          slog("Ignoring invalid skill data received for player $player ($skills)",2);
        }
      }elsif($status == 1) {
        slog("Unable to get skill of player $player \#$accountId (permission denied)",2);
      }elsif($status == 2) {
        slog("Unable to get skill of player $player \#$accountId (unrated account)",2);
        $battleSkills{$player}{skillOrigin}='rank';
      }else{
        slog("Unable to get skill of player $player \#$accountId (unknown status code: $status)",2);
      }
      pluginsUpdateSkill($battleSkills{$player},$accountId);
      sendPlayerSkill($player);
      checkBattleBansForPlayer($player);
      $needRebalance=1 if($previousPlayerSkill != $battleSkills{$player}{skill} && $lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$player}
                          && defined $lobby->{battle}{users}{$player}{battleStatus} && $lobby->{battle}{users}{$player}{battleStatus}{mode});
    }else{
      slog("Ignoring invalid skill parameter ($skillParam)",2);
    }
  }
  if($needRebalance) {
    $balanceState=0;
    %balanceTarget=();
  }
}

# SPADS JSONRPC commands handlers #############################################

sub hApiGetPreferences {
  my ($r_origin,$r_params)=@_;
  
  return (undef,'INVALID_PARAMS') unless(ref $r_params eq 'ARRAY' && @{$r_params} && (all {defined $_ && ref $_ eq ''} @{$r_params}));

  my $user=$r_origin->{user};
  return (undef,'INSUFFICIENT_PRIVILEGES') if($user eq '<UNAUTHENTICATED USER>');

  my @forbiddenPrefs=qw'password';
  
  my $aId=getLatestUserAccountId($user);
  my $p_prefs=$spads->getUserPrefs($aId,$user);
  my %result;
  if(@{$r_params} == 1 && $r_params->[0] eq '*') {
    foreach my $pref (keys %{$p_prefs}) {
      next if(any {$pref eq $_} @forbiddenPrefs);
      $result{$pref} = $p_prefs->{$pref} eq '' ? ($conf{$pref} // '') : $p_prefs->{$pref};
    }
    return (\%result,undef);
  }
  
  my @invalidPrefs;
  foreach my $pref (@{$r_params}) {
    if(exists $p_prefs->{$pref} && (none {$pref eq $_} @forbiddenPrefs)) {
      $result{$pref} = $p_prefs->{$pref} eq '' ? ($conf{$pref} // '') : $p_prefs->{$pref};
    }else{
      push(@invalidPrefs,$pref);
    }
  }
  if(@invalidPrefs) {
    return (undef,{code => 'INVALID_PARAMS', data => 'Invalid preference'.(@invalidPrefs>1?'s':'').' : '.join(', ',@invalidPrefs)});
  }
  return (\%result,undef);
}

sub hApiGetSettings {
  my ($r_origin,$r_params)=@_;
  
  return (undef,'INVALID_PARAMS') unless(ref $r_params eq 'ARRAY' && @{$r_params} && (all {defined $_ && ref $_ eq ''} @{$r_params}));
  
  my %result;
  if(@{$r_params} == 1 && $r_params->[0] eq '*') {
    foreach my $set (keys %{$spads->{values}}) {
      $result{$set}=$conf{$set} unless($PRIVATE_SETTINGS{$set});
    }
    return (\%result,undef);
  }
  
  my @invalidSettings;
  foreach my $set (@{$r_params}) {
    if(exists $spads->{values}{$set} && ! $PRIVATE_SETTINGS{$set}) {
      $result{$set}=$conf{$set};
    }else{
      push(@invalidSettings,$set);
    }
  }
  if(@invalidSettings) {
    return (undef,{code => 'INVALID_PARAMS', data => 'Invalid setting'.(@invalidSettings>1?'s':'').' : '.join(', ',@invalidSettings)});
  }
  return (\%result,undef);
}

sub hApiGetVoteSettings {
  my ($r_origin,$r_params)=@_;
  
  return (undef,'INVALID_PARAMS') unless(ref $r_params eq 'ARRAY' && @{$r_params} && (all {defined $_ && ref $_ eq ''} @{$r_params}));

  my $r_voteSettings=getVoteSettings();
  return ($r_voteSettings,undef) if(@{$r_params} == 1 && $r_params->[0] eq '*');

  my @invalidSettings = grep {! exists $r_voteSettings->{global}{$_}} @{$r_params};
  if(@invalidSettings) {
    return (undef,{code => 'INVALID_PARAMS', data => 'Invalid vote setting'.(@invalidSettings>1?'s':'').' : '.join(', ',@invalidSettings)});
  }

  my %result=(global => {}, specific => {});
  map {$result{global}{$_}=$r_voteSettings->{global}{$_}} @{$r_params};
  foreach my $cmd (keys %{$r_voteSettings->{specific}}) {
    map {$result{specific}{$cmd}{$_}=$r_voteSettings->{specific}{$cmd}{$_} if(exists $r_voteSettings->{specific}{$cmd}{$_})} @{$r_params};
  }
  return (\%result,undef);
}

sub hApiStatus {
  my ($r_origin,$r_params)=@_;
  
  return (undef,'INVALID_PARAMS') unless(ref $r_params eq 'ARRAY' && @{$r_params} && @{$r_params} < 3 && (all {defined $_ && ref $_ eq ''} @{$r_params}));
  return (undef,'INVALID_PARAMS') if(any {$_ ne 'battle' && $_ ne 'game'} @{$r_params});
  return (undef,'INVALID_PARAMS') if(@{$r_params} == 2 && $r_params->[0] eq $r_params->[1]);
  
  my $battleLobbyStatusRequested = any {$_ eq 'battle'} @{$r_params};
  my $gameStatusRequested = any {$_ eq 'game'} @{$r_params};
  
  my $r_user={accessLevel => $r_origin->{accessLevel} // getUserAccessLevel($r_origin->{user})};
  
  my %result;
  if($battleLobbyStatusRequested) {
    my ($r_clientsStatusBattle,undef,$r_globalStatusBattle)=getBattleLobbyStatus($r_user);
    if(defined $r_globalStatusBattle) {
      foreach my $r_client (@{$r_clientsStatusBattle}) {
        if($r_client->{Name} =~ / \(bot\)$/) {
          $r_client->{Version}=delete $r_client->{ID};
        }else{
          $r_client->{Country}=$lobby->{users}{$r_client->{Name}}{country};
        }
      }
    }else{
      $r_clientsStatusBattle=[];
    }
    $result{battleLobby} = { clients => $r_clientsStatusBattle, status => $r_globalStatusBattle };
  }
  if($gameStatusRequested) {
    my ($r_clientsStatusGame,undef,$r_globalStatusGame)=getGameStatus($r_user);
    if(defined $r_globalStatusGame) {
      foreach my $r_client (@{$r_clientsStatusGame}) {
        next if($r_client->{Name} =~ / \(bot\)$/ || ! exists $p_runningBattle->{users}{$r_client->{Name}});
        $r_client->{ID}=$p_runningBattle->{users}{$r_client->{Name}}{accountId};
        $r_client->{Rank}=$p_runningBattle->{users}{$r_client->{Name}}{status}{rank};
        $r_client->{Skill}=$p_runningBattle->{scriptTags}{'game/players/'.lc($r_client->{Name}).'/skill'};
        $r_client->{Country}=$p_runningBattle->{users}{$r_client->{Name}}{country};
      }
    }else{
      $r_clientsStatusGame=[];
    }
    $result{game} = { clients => $r_clientsStatusGame, status => $r_globalStatusGame };
  }

  return (\%result,undef);
}

# Lobby interface callbacks ###################################################

sub cbLobbyConnect {
  $lobbyState=LOBBY_STATE_CONNECTED;
  my $lobbySyncedSpringVersion=$_[2];
  $lobbySyncedSpringVersion=$1 if($lobbySyncedSpringVersion =~ /^([^\.]+)\./);
  $lanMode=$_[4];

  if($lanMode) {
    slog("Lobby server is running in LAN mode (lobby passwords aren't checked)",3);
    slog("It is highly recommended to use internal SPADS user authentication for privileged accounts",3);
  }

  if($lobbySyncedSpringVersion eq '*') {
    slog("Lobby server has no default engine set, UnitSync is using Spring $syncedSpringVersion",4);
  }else{
    slog("Lobby server default engine is Spring $lobbySyncedSpringVersion, UnitSync is using Spring $syncedSpringVersion",4);
  }

  if($useTls) {
    $lobby->startTls(\&cbStartTls)
        or startTlsFailed();
  }else{
    initLobbyConnection();
  }
}

sub cbStartTls {
  if($_[0] && defined $lobby->{tlsCertifHash}) {
    if($spads->isTrustedCertificateHash($conf{lobbyHost},$lobby->{tlsCertifHash})) {
      initLobbyConnection();
    }else{
      if(defined $tlsAction && $tlsAction eq 'trust') {
        slog("Adding following certificate to the trusted certificates list:\n".($lobby->{lobbySock}->dump_peer_certificate())."SHA-256: $lobby->{tlsCertifHash}",2);
        $spads->addTrustedCertificateHash({lobbyHost => $conf{lobbyHost}, certHash => $lobby->{tlsCertifHash}});
        initLobbyConnection();
      }elsif($lobby->{tlsServerIsAuthenticated}) {
        initLobbyConnection();
      }else{
        slog("Untrusted lobby certificate, lobby server authenticity cannot be verified:\n".($lobby->{lobbySock}->dump_peer_certificate())."SHA-256: $lobby->{tlsCertifHash}",2);
        slog("Restart SPADS with following parameter if you decide to trust this certificate: --tls-cert-trust=$conf{lobbyHost}:$lobby->{tlsCertifHash}",2);
        $lobbyState=LOBBY_STATE_DISCONNECTED;
        SimpleEvent::unregisterSocket($lobby->{lobbySock});
        $lobby->disconnect();
        quitAfterGame('untrusted lobby certificate',EXIT_CERTIFICATE);
      }
    }
  }else{
    startTlsFailed();
  }
}

sub startTlsFailed {
  $lobbyState=LOBBY_STATE_DISCONNECTED;
  slog('Failed to enable TLS !',2);
  SimpleEvent::unregisterSocket($lobby->{lobbySock});
  $lobby->disconnect();
}

sub getLocalSystemHashForLogin {  return ($unitsyncHostHashes{macAddr}//0).' '.(defined $unitsyncHostHashes{sysInfo} ? substr($unitsyncHostHashes{sysInfo},0,16) : 0) }

sub initLobbyConnection {
  $lobby->addCallbacks({CHANNELTOPIC => \&cbChannelTopic,
                        LOGININFOEND => \&cbLoginInfoEnd,
                        JOIN => \&cbJoin,
                        JOINFAILED => \&cbJoinFailed,
                        ADDUSER => \&cbAddUser,
                        REMOVEUSER => \&cbRemoveUser,
                        SAID => \&cbSaid,
                        CHANNELMESSAGE => \&cbChannelMessage,
                        SERVERMSG => \&cbServerMsg,
                        SAIDEX => \&cbSaidEx,
                        SAIDPRIVATE => \&cbSaidPrivate,
                        SAIDPRIVATEEX => \&cbSaidPrivateEx,
                        SAIDBATTLE => \&cbSaidBattle,
                        SAIDBATTLEEX => \&cbSaidBattleEx,
                        CLIENTSTATUS => \&cbClientStatus,
                        REQUESTBATTLESTATUS => \&cbRequestBattleStatus,
                        CLIENTIPPORT => \&cbClientIpPort,
                        CLIENTBATTLESTATUS => \&cbClientBattleStatus,
                        UPDATEBOT => \&cbUpdateBot,
                        JOINBATTLEREQUEST => \&cbJoinBattleRequest,
                        JOINEDBATTLE => \&cbJoinedBattle,
                        ADDBOT => \&cbAddBot,
                        LEFTBATTLE => \&cbLeftBattle,
                        KICKFROMBATTLE => \&cbKickFromBattle,
                        REMOVEBOT => \&cbRemoveBot,
                        BROADCAST => \&cbBroadcast,
                        BATTLECLOSED => \&cbBattleClosed,
                        JOINED => \&cbJoined,
                        LEFT => \&cbLeft,
                        UPDATEBATTLEINFO => \&cbUpdateBattleInfo,
                        BATTLEOPENED => \&cbBattleOpened});

  my $localLanIp=$conf{localLanIp};
  $localLanIp=getLocalLanIp() unless($localLanIp);
  my $legacyFlags = ($lobby->{serverParams}{protocolVersion} =~ /^(\d+\.\d+)/ && $1 > 0.36) ? '' : ' l t cl';
  
  queueLobbyCommand(["LOGIN",$conf{lobbyLogin},$lobby->marshallPasswd($conf{lobbyPassword}),0,$localLanIp,"SPADS v$SPADS_VERSION",getLocalSystemHashForLogin(),'b sp'.$legacyFlags],
                    {ACCEPTED => \&cbLoginAccepted,
                     DENIED => \&cbLoginDenied,
                     AGREEMENTEND => \&cbAgreementEnd},
                    \&cbLoginTimeout); # lobby command timeouts aren't enabled currently (SpringLobbyInterface::checkTimeouts() is never called)
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onLobbyLogin($lobby) if($plugins{$pluginName}->can('onLobbyLogin'));
  }
}

sub cbBroadcast {
  my (undef,$msg)=@_;
  print "Lobby broadcast message: $msg\n";
  slog("Lobby broadcast message: $msg",3);
}

sub cbRedirect {
  my (undef,$ip,$port)=@_;
  $ip//='';
  if($conf{lobbyFollowRedirect}) {
    if($ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ && $1<256 && $2<256 && $3<256 && $4<256) {
      $port//=$conf{lobbyPort};
      if($port !~ /^\d+$/) {
        slog("Invalid port \"$port\" received in REDIRECT command, ignoring redirection",1);
        return;
      }
    }else{
      slog("Invalid IP address \"$ip\" received in REDIRECT command, ignoring redirection",1);
      return;
    }
    slog("Received redirection request to $ip:$port",3);
    %pendingRedirect=(ip => $ip, port => $port);
  }else{
    slog("Ignoring redirection request to address $ip",2);
  }
}

sub cbLobbyDisconnect {
  slog("Disconnected from lobby server (connection reset by peer)",2);
  logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > LOBBY_STATE_OPENING_BATTLE && $conf{logBattleJoinLeave});
  $lobbyState=LOBBY_STATE_DISCONNECTED;
  $currentNbNonPlayer=0;
  if(%currentVote && exists $currentVote{command} && @{$currentVote{command}}) {
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
    }
  }
  %currentVote=();
  %pendingRelayedJsonRpcChunks=();
  foreach my $joinedChan (keys %{$lobby->{channels}}) {
    logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
  }
  SimpleEvent::unregisterSocket($lobby->{lobbySock});
  $lobby->disconnect();
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onLobbyDisconnected() if($plugins{$pluginName}->can('onLobbyDisconnected'));
  }
}

sub cbConnectTimeout {
  $lobbyState=LOBBY_STATE_DISCONNECTED;
  slog("Timeout while connecting to lobby server ($conf{lobbyHost}:$conf{lobbyPort})",2);
  SimpleEvent::unregisterSocket($lobby->{lobbySock});
  $lobby->disconnect();
}

sub cbLoginAccepted {
  $lobbyState=LOBBY_STATE_LOGGED_IN;
  slog("Logged on lobby server",4);
  $triedGhostWorkaround=0;
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onLobbyLoggedIn($lobby) if($plugins{$pluginName}->can('onLobbyLoggedIn'));
  }
}

sub cbLoginInfoEnd {
  $lobbyState=LOBBY_STATE_SYNCHRONIZED;
  queueLobbyCommand(["JOIN",$conf{masterChannel}]) if($conf{masterChannel} ne "");
  my %chansToJoin;
  if($conf{promoteChannels}) {
    my @promChans=split(/;/,$conf{promoteChannels});
    foreach my $chan (@promChans) {
      $chansToJoin{$chan}=1;
    }
  }
  if($conf{broadcastChannels}) {
    my @broadcastChans=split(/;/,$conf{broadcastChannels});
    foreach my $chan (@broadcastChans) {
      $chansToJoin{$chan}=1;
    }
  }
  foreach my $chan (keys %chansToJoin) {
    next if($chan eq $conf{masterChannel});
    queueLobbyCommand(["JOIN",$chan]);
  }
  if($springPid) {
    my %clientStatus = %{$lobby->{users}{$conf{lobbyLogin}}{status}};
    $clientStatus{inGame}=1;
    queueLobbyCommand(["MYSTATUS",$lobby->marshallClientStatus(\%clientStatus)]);
  }
  queueLobbyCommand(["GETUSERINFO"]);
  if(exists $lobby->{users}{$conf{lobbyLogin}} && ! $lobby->{users}{$conf{lobbyLogin}}{status}{bot}) {
    slog('The lobby account currently used by SPADS is not tagged as bot. It is recommended to ask a lobby administrator for bot flag on accounts used by SPADS',2);
  }
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onLobbyConnected($lobby) if($plugins{$pluginName}->can('onLobbyConnected'));
    $plugins{$pluginName}->onLobbySynchronized($lobby) if($plugins{$pluginName}->can('onLobbySynchronized'));
  }
}

sub cbLoginDenied {
  my (undef,$reason)=@_;
  slog("Login denied on lobby server ($reason)",1);
  if(($reason !~ /^Already logged in/ && $reason !~ /^This account has already logged in/) || $triedGhostWorkaround > 2) {
    quitAfterGame("loggin denied on lobby server",EXIT_LOGIN);
  }
  if($reason =~ /^Already logged in/) {
    $triedGhostWorkaround++;
  }else{
    $triedGhostWorkaround=0;
  }
  $lobbyState=LOBBY_STATE_DISCONNECTED;
  SimpleEvent::unregisterSocket($lobby->{lobbySock});
  $lobby->disconnect();
}

sub cbAgreementEnd {
  slog("Spring Lobby agreement has not been accepted for this account yet, please login with a Spring lobby client and accept the agreement",1);
  quitAfterGame("Spring Lobby agreement not accepted yet for this account",EXIT_LOGIN);
  $lobbyState=LOBBY_STATE_DISCONNECTED;
  SimpleEvent::unregisterSocket($lobby->{lobbySock});
  $lobby->disconnect();
}

sub cbLoginTimeout {
  slog("Unable to log on lobby server (timeout)",2);
  logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > LOBBY_STATE_OPENING_BATTLE && $conf{logBattleJoinLeave});
  $lobbyState=LOBBY_STATE_DISCONNECTED;
  foreach my $joinedChan (keys %{$lobby->{channels}}) {
    logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
  }
  SimpleEvent::unregisterSocket($lobby->{lobbySock});
  $lobby->disconnect();
}

sub cbJoin {
  my (undef,$channel)=@_;
  slog("Channel $channel joined",4);
  logMsg("channel_$channel","=== $conf{lobbyLogin} joined ===") if($conf{logChanJoinLeave});
}

sub cbJoinFailed {
  my (undef,$channel,$reason)=@_;
  slog("Unable to join channel $channel ($reason)",2);
}

sub cbJoined {
  my (undef,$chan,$user)=@_;
  logMsg("channel_$chan","=== $user joined ===") if($conf{logChanJoinLeave} && $user ne $conf{lobbyLogin});
}

sub cbLeft {
  my (undef,$chan,$user,$reason)=@_;
  my $reasonString ="";
  $reasonString=" ($reason)" if(defined $reason && $reason ne "");
  logMsg("channel_$chan","=== $user left$reasonString ===") if($conf{logChanJoinLeave});
}

sub cbOpenBattle {
  sendBattleSettings();
  applyMapBoxes();
  $lobbyState=LOBBY_STATE_BATTLE_OPENED;
  $timestamps{rotationEmpty}=time;
  logMsg("battle","=== $conf{lobbyLogin} joined ===") if($conf{logBattleJoinLeave});
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onBattleOpened() if($plugins{$pluginName}->can('onBattleOpened'));
  }
}

sub cbOpenBattleFailed {
  my (undef,$reason)=@_;
  slog("Unable to open battle ($reason)",1);
  $lobbyState=LOBBY_STATE_SYNCHRONIZED;
  closeBattleAfterGame("unable to open battle");
}

sub cbOpenBattleTimeout {
  slog("Unable to open battle (timeout)",1);
  $lobbyState=LOBBY_STATE_SYNCHRONIZED;
  closeBattleAfterGame("timeout while opening battle");
}

sub cbRequestBattleStatus {
  my $p_battleStatus = {
    side => 0,
    sync => 1,
    bonus => 0,
    mode => 0,
    team => 0,
    id => 0,
    ready => 1
  };
  my $p_color = {
    red => 255,
    green => 255,
    blue => 255
  };
  queueLobbyCommand(["MYBATTLESTATUS",$lobby->marshallBattleStatus($p_battleStatus),$lobby->marshallColor($p_color)]);
}

sub cbClientStatus {
  my (undef,$user)=@_;
  if($user eq $conf{lobbyLogin}) {
    $timestamps{battleChange}=time;
    updateBattleInfoIfNeeded();
  }
  if($conf{userDataRetention} !~ /^0;/ && ! $lanMode) {
    if(exists $lobby->{users}{$user}) {
      $spads->learnAccountRank(getLatestUserAccountId($user),
                               $lobby->{users}{$user}{status}{rank},
                               $lobby->{users}{$user}{status}{bot});
    }else{
      slog("Unable to store data for user \"$user\" (user unknown)",2);
    }
  }

  if($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$user} && defined $lobby->{battle}{users}{$user}{scriptPass}
     && $autohost->getState() && $lobby->{users}{$user}{status}{inGame} && ! exists $p_runningBattle->{users}{$user}
     && ! exists $inGameAddedUsers{$user} && getUserAccessLevel($user) >= $conf{midGameSpecLevel}) {
    $inGameAddedUsers{$user}=$lobby->{battle}{users}{$user}{scriptPass};
    $autohost->sendChatMessage("/adduser $user $inGameAddedUsers{$user}");
  }
}

sub cbClientIpPort {
  my (undef,$user,$ip)=@_;
  seenUserIp($user,$ip);
  my $p_ban=$spads->getUserBan($user,$lobby->{users}{$user},isUserAuthenticated($user),$ip,getPlayerSkillForBanCheck($user));
  queueLobbyCommand(["KICKFROMBATTLE",$user]) if($p_ban->{banType} < 2);
}

sub cbClientBattleStatus {
  my (undef,$user)=@_;

  if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! exists $lobby->{battle}{users}{$user}) {
    slog("Ignoring CLIENTBATTLESTATUS command (client \"$user\" out of current battle)",2);
    return;
  }

  return if(checkUserStatusFlood($user));

  my $p_battleStatus=$lobby->{battle}{users}{$user}{battleStatus};
  if($p_battleStatus->{mode}) {
    my $forceReason='';
    if(! exists $currentPlayers{$user}) {
      my $nbNonPlayer=getNbNonPlayer();
      my @clients=keys %{$lobby->{battle}{users}};
      my $nbPlayers=$#clients+1-$nbNonPlayer;
      if($conf{nbTeams} != 1) {
        my @bots=keys %{$lobby->{battle}{bots}};
        $nbPlayers+=$#bots+1;
      }
      my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
      my $p_ban=$spads->getUserBan($user,$lobby->{users}{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
      if($p_ban->{banType} < 2) {
        queueLobbyCommand(["KICKFROMBATTLE",$user]);
        return;
      }elsif($p_ban->{banType} == 2) {
        $forceReason="[auto-spec mode]";
        $forceReason.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne '');
      }elsif($nbPlayers > $targetNbPlayers && $conf{autoSpecExtraPlayers}) {
        if(%autoAddedLocalBots && $conf{nbTeams} != 1) {
          my @autoAddedLocalBotNames=sort {$autoAddedLocalBots{$a} <=> $autoAddedLocalBots{$b}} (keys %autoAddedLocalBots);
          my $removedBot=pop(@autoAddedLocalBotNames);
          $pendingLocalBotAuto{'-'.$removedBot}=time;
          queueLobbyCommand(['REMOVEBOT',$removedBot]);
        }else{
          $forceReason="[autoSpecExtraPlayers=1, ";
          if($conf{teamSize} == 1) {
            $forceReason.="nbTeams=$conf{nbTeams}] (use \"!set nbTeams <n>\" to change it)";
          }else{
            $forceReason.="teamSize=$conf{teamSize}] (use \"!set teamSize <n>\" to change it)";
          }
        }
      }
      $currentPlayers{$user}=time unless($forceReason);
    }
    if($forceReason) {
      queueLobbyCommand(["FORCESPECTATORMODE",$user]);
      if(! exists $forceSpecTimestamps{$user} || time - $forceSpecTimestamps{$user} > 60) {
        $forceSpecTimestamps{$user}=time;
        sayBattle("Forcing spectator mode for $user $forceReason");
        checkUserMsgFlood($user);
      }
    }else{
      delete $currentSpecs{$user};
      if($conf{autoBlockBalance}) {
        if($balanceState) {
          if(! exists $balanceTarget{players}{$user}) {
            $balanceState=0;
          }else{
            my $p_targetBattleStatus=$balanceTarget{players}{$user}{battleStatus};
            if($p_battleStatus->{team} != $p_targetBattleStatus->{team}) {
              queueLobbyCommand(["FORCEALLYNO",$user,$p_targetBattleStatus->{team}])
            }
            if($p_battleStatus->{id} != $p_targetBattleStatus->{id}) {
              queueLobbyCommand(["FORCETEAMNO",$user,$p_targetBattleStatus->{id}]);
            }
          }
        }else{
          $balanceState=isBalanceTargetApplied();
        }
      }else{
        $balanceState=isBalanceTargetApplied();
      }
      if($conf{autoBlockColors}) {
        if($colorsState) {
          my $colorId=$p_battleStatus->{id};
          if(! exists $colorsTarget{$colorId}) {
            $colorsState=0;
          }else{
            my $p_targetColor=$colorsTarget{$colorId};
            my $p_color=$lobby->{battle}{users}{$user}{color};
            if(colorDistance($p_color,$p_targetColor) != 0) {
              queueLobbyCommand(["FORCETEAMCOLOR",$user,$lobby->marshallColor($p_targetColor)]);
            }
          }
        }else{
          $colorsState=areColorsApplied();
        }
      }else{
        $colorsState=areColorsApplied();
      }
      $timestamps{battleChange}=time;
      updateBattleInfoIfNeeded();
    }
  }else{
    delete $currentPlayers{$user};
    if(! exists $currentSpecs{$user}) {
      my $nbSpec=getNbSpec();
      if($conf{maxSpecs} ne '' && $nbSpec > $conf{maxSpecs}+1 && $user ne $conf{lobbyLogin}
         && getUserAccessLevel($user) < $conf{maxSpecsImmuneLevel}
         && ! ($springPid && $autohost->getState()
               && exists $p_runningBattle->{users}{$user} && defined $p_runningBattle->{users}{$user}{battleStatus} && $p_runningBattle->{users}{$user}{battleStatus}{mode}
               && (! %{$autohost->getPlayer($user)} || $autohost->getPlayer($user)->{lost} == 0))) {
        broadcastMsg("Kicking $user from battle [maxSpecs=$conf{maxSpecs}]");
        queueLobbyCommand(["KICKFROMBATTLE",$user]);
      }else{
        $currentSpecs{$user}=time;
        $timestamps{battleChange}=time;
        updateBattleInfoIfNeeded();
        updateBattleStates();
      }
    }
  }

  updateCurrentGameType();
}

sub cbUpdateBot {
  my (undef,undef,$bot)=@_;

  my $p_battle=$lobby->getBattle();
  my $p_bots=$p_battle->{bots};

  my $p_battleStatus=$p_bots->{$bot}{battleStatus};
  my $p_color=$p_bots->{$bot}{color};

  my $updateNeeded=0;
  if($conf{autoBlockBalance}) {
    if($balanceState) {
      if(! exists $balanceTarget{bots}{$bot}) {
        queueLobbyCommand(["REMOVEBOT",$bot]);
      }else{
        my $p_targetBattleStatus=$balanceTarget{bots}{$bot}{battleStatus};
        if($p_battleStatus->{team} != $p_targetBattleStatus->{team}) {
          $updateNeeded=1;
          $p_battleStatus->{team}=$p_targetBattleStatus->{team};
        }
        if($p_battleStatus->{id} != $p_targetBattleStatus->{id}) {
          $updateNeeded=1;
          $p_battleStatus->{id}=$p_targetBattleStatus->{id};
        }
      }
    }else{
      $balanceState=isBalanceTargetApplied();
    }
  }else{
    $balanceState=isBalanceTargetApplied();
  }
  if($conf{autoBlockColors}) {
    if($colorsState) {
      my $colorId=$p_battleStatus->{id};
      if(! exists $colorsTarget{$colorId}) {
        $colorsState=0;
      }else{
        my $p_targetColor=$colorsTarget{$colorId};
        if(colorDistance($p_color,$p_targetColor) != 0) {
          $updateNeeded=1;
          $p_color=$p_targetColor;
        }
      }
    }else{
      $colorsState=areColorsApplied();
    }
  }else{
    $colorsState=areColorsApplied();
  }
  queueLobbyCommand(["UPDATEBOT",$bot,$lobby->marshallBattleStatus($p_battleStatus),$lobby->marshallColor($p_color)]) if($updateNeeded);
}

sub cbJoinBattleRequest {
  my (undef,$user,$ip)=@_;
  seenUserIp($user,$ip);
  my $p_ban=$spads->getUserBan($user,$lobby->{users}{$user},isUserAuthenticated($user),$ip,getPlayerSkillForBanCheck($user));
  if($p_ban->{banType} < 2) {
    if(exists $p_ban->{reason} && defined $p_ban->{reason}) {
      queueLobbyCommand(['JOINBATTLEDENY',$user,$p_ban->{reason}]);
    }else{
      queueLobbyCommand(['JOINBATTLEDENY',$user]);
    }
    slog("Request to join battle denied for user $user",4);
  }else{
    my $pluginReason;
    foreach my $pluginName (@pluginsOrder) {
      $pluginReason=$plugins{$pluginName}->onJoinBattleRequest($user,$ip) if($plugins{$pluginName}->can('onJoinBattleRequest'));
      $pluginReason//=0;
      last if($pluginReason);
    }
    if($pluginReason) {
      if($pluginReason eq '1') {
        queueLobbyCommand(['JOINBATTLEDENY',$user]);
      }else{
        queueLobbyCommand(['JOINBATTLEDENY',$user,$pluginReason]);
      }
      slog("Request to join battle denied by plugin for user $user",4);
    }else{
      queueLobbyCommand(['JOINBATTLEACCEPT',$user]);
    }
  }
}

sub cbJoinedBattle {
  my (undef,$battleId,$user)=@_;

  return unless(%{$lobby->{battle}} && $battleId == $lobby->{battle}{battleId});

  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onJoinedBattle($user) if($plugins{$pluginName}->can('onJoinedBattle'));
  }
  
  delete $pendingSpecJoin{$user} if(exists $pendingSpecJoin{$user});

  my $p_ban=$spads->getUserBan($user,$lobby->{users}{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
  if($p_ban->{banType} < 2) {
    queueLobbyCommand(["KICKFROMBATTLE",$user]);
    logMsg("battle","=== $user joined ===") if($conf{logBattleJoinLeave});
    return;
  }

  $timestamps{battleChange}=time;
  updateBattleInfoIfNeeded();
  updateBattleStates();

  logMsg("battle","=== $user joined ===") if($conf{logBattleJoinLeave});

  my $level=getUserAccessLevel($user);
  my $levelDescription=$spads->getLevelDescription($level);
  my ($mapHash,$mapArchive)=getMapHashAndArchive($conf{map});

  my $mapLink;
  if($mapArchive eq '') {
    $mapLink=$conf{ghostMapLink};
  }elsif($conf{mapLink}) {
    $mapLink=$conf{mapLink};
    $mapArchive=~s/ /\%20/g;
    $mapLink=~s/\%M/$mapArchive/g;
  }
  $mapLink//='';

  my $mapName=$conf{map};
  $mapName=$1 if($mapName =~ /^(.*)\.smf$/);
  $mapName=~s/ /\%20/g;
  $mapLink=~s/\%m/$mapName/g;
  $mapLink=~s/\%h/$mapHash/g;

  my $gameAge='unknown';
  $gameAge=secToTime(time-$timestamps{lastGameStart}) if($timestamps{lastGameStart});

  my @welcomeMsgs=@{$spads->{values}{welcomeMsg}};
  @welcomeMsgs=@{$spads->{values}{welcomeMsgInGame}} if($lobby->{users}{$conf{lobbyLogin}}{status}{inGame});
  foreach my $welcomeMsg (@welcomeMsgs) {
    if($welcomeMsg) {
      my %placeholders=(u => $user,
                        l => $level,
                        d => $levelDescription,
                        m => $mapName,
                        n => $conf{lobbyLogin},
                        v => $SPADS_VERSION,
                        h => $mapHash,
                        a => $mapLink,
                        t => $gameAge,
                        p => $conf{preset},
                        P => $conf{description});
      foreach my $placeholder (keys %placeholders) {
        $welcomeMsg=~s/\%$placeholder/$placeholders{$placeholder}/g;
      }
      if($welcomeMsg =~ /^!(.+)$/) {
        sayBattleUser($user,$1);
      }else{
        sayBattle($welcomeMsg);
      }
    }
  }

  if($autohost->getState() && defined $lobby->{battle}{users}{$user}{scriptPass}) {
    if(exists $p_runningBattle->{users}{$user} && ! exists $inGameAddedUsers{$user}) {
      $inGameAddedUsers{$user}=$lobby->{battle}{users}{$user}{scriptPass};
      $autohost->sendChatMessage("/adduser $user $inGameAddedUsers{$user}");
    }
    if(exists $inGameAddedUsers{$user} && $inGameAddedUsers{$user} ne $lobby->{battle}{users}{$user}{scriptPass}) {
      $inGameAddedUsers{$user}=$lobby->{battle}{users}{$user}{scriptPass};
      $autohost->sendChatMessage("/adduser $user $inGameAddedUsers{$user}");
    }
  }

  getBattleSkill($user);
}

sub cbAddBot {
  my (undef,undef,$bot)=@_;

  my $nbNonPlayer=getNbNonPlayer();
  my $user=$lobby->{battle}{bots}{$bot}{owner};

  delete($pendingLocalBotManual{$bot}) if(exists $pendingLocalBotManual{$bot});
  if(exists $pendingLocalBotAuto{$bot}) {
    $autoAddedLocalBots{$bot}=time if($user eq $conf{lobbyLogin});
    delete($pendingLocalBotAuto{$bot});
  }

  return if(checkUserStatusFlood($user));

  my $p_ban=$spads->getUserBan($user,$lobby->{users}{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
  if($p_ban->{banType} < 2) {
    queueLobbyCommand(["KICKFROMBATTLE",$user]);
    return;
  }
  my @clients=keys %{$lobby->{battle}{users}};
  my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
  my @bots=keys %{$lobby->{battle}{bots}};
  my $nbPlayers=$#clients-$nbNonPlayer+$#bots+2;
  my ($nbLocalBots,$nbRemoteBots)=(0,0);
  foreach my $botName (@bots) {
    if($lobby->{battle}{bots}{$botName}{owner} eq $conf{lobbyLogin}) {
      $nbLocalBots++;
    }else{
      $nbRemoteBots++;
    }
  }
  my $forceReason='';
  if($conf{maxBots} ne '' && $#bots+1 > $conf{maxBots}) {
    $forceReason="[maxBots=$conf{maxBots}]";
  }elsif($user eq $conf{lobbyLogin} && $conf{maxLocalBots} ne '' && $nbLocalBots > $conf{maxLocalBots}) {
    $forceReason="[maxLocalBots=$conf{maxLocalBots}]";
  }elsif($user ne $conf{lobbyLogin} && $conf{maxRemoteBots} ne '' && $nbRemoteBots > $conf{maxRemoteBots}) {
    $forceReason="[maxRemoteBots=$conf{maxRemoteBots}]";
  }elsif($nbPlayers > $targetNbPlayers && $conf{autoSpecExtraPlayers} && $conf{nbTeams} != 1) {
    $forceReason="[autoSpecExtraPlayers=1, ";
    if($conf{teamSize} == 1) {
      $forceReason.="nbTeams=$conf{nbTeams}] (use \"!set nbTeams <n>\" to change it)";
    }else{
      $forceReason.="teamSize=$conf{teamSize}] (use \"!set teamSize <n>\" to change it)";
    }
  }elsif($p_ban->{banType} == 2) {
    $forceReason="[auto-spec mode on owner $user]";
    $forceReason.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne "");
  }
  if($forceReason) {
    queueLobbyCommand(["REMOVEBOT",$bot]);
    if(! exists $forceSpecTimestamps{$user} || time - $forceSpecTimestamps{$user} > 60) {
      $forceSpecTimestamps{$user}=time;
      sayBattle("Kicking bot $bot $forceReason");
      checkUserMsgFlood($user);
    }
  }else{
    $timestamps{battleChange}=time;
    updateBattleInfoIfNeeded();
    updateBattleStates();
    updateCurrentGameType();
  }
}

sub cbLeftBattle {
  my (undef,$battleId,$user)=@_;
  if(%{$lobby->{battle}} && $battleId == $lobby->{battle}{battleId}) {
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onLeftBattle($user) if($plugins{$pluginName}->can('onLeftBattle'));
    }
  
    $timestamps{battleChange}=time;
    $timestamps{rotationEmpty}=time;
    updateBattleInfoIfNeeded();
    updateBattleStates();
    if(exists $currentVote{command} && exists $currentVote{remainingVoters}{$user}) {
      my $userIsStillInGame;
      if($autohost->getState()) {
        my $p_ahUser=$autohost->getPlayer($user);
        $userIsStillInGame=1 if(%{$p_ahUser} && $p_ahUser->{disconnectCause} == -1);
      }
      delete $currentVote{remainingVoters}{$user} unless($userIsStillInGame);
    }
    $timestamps{autoRestore}=time if(! $lobby->{users}{$user}{status}{bot} && $timestamps{autoRestore});
    delete $currentPlayers{$user};
    delete $currentSpecs{$user};
    if(exists $pendingFloodKicks{$user}) {
      delete $pendingFloodKicks{$user};
      delete $lastBattleMsg{$user};
      delete $lastBattleStatus{$user};
    }
    delete $lastRungUsers{$user};
    delete $forceSpecTimestamps{$user};
    delete $battleSkills{$user};
    delete $battleSkillsCache{$user};
    if(%bosses) {
      delete $bosses{$user};
      broadcastMsg("Boss mode disabled") if(! %bosses);
    }
    logMsg("battle","=== $user left ===") if($conf{logBattleJoinLeave});

    if($autohost->getState() && exists($inGameAddedUsers{$user})) {
      my $randomPass=generatePassword(8);
      $autohost->sendChatMessage("/adduser $user $randomPass");
      $inGameAddedUsers{$user}=$randomPass;
    }
    updateCurrentGameType();

    my $lcUser=lc($user);
    if(exists $sentPlayersScriptTags{$lcUser}) {
      my @scriptTagsToRemove=keys %{$sentPlayersScriptTags{$lcUser}};
      delete $sentPlayersScriptTags{$lcUser};
      @scriptTagsToRemove=map {"game/players/$lcUser/$_"} @scriptTagsToRemove;
      queueLobbyCommand(["REMOVESCRIPTTAGS",@scriptTagsToRemove]) if(@scriptTagsToRemove);
    }
  }
}

sub cbKickFromBattle {
  my $bannedUser=$_[2];
  return unless($autohost->getState());
  return unless(exists $p_runningBattle->{users}{$bannedUser} || exists $inGameAddedUsers{$bannedUser});
  return if($bannedUser eq $conf{lobbyLogin});

  my $bannedUserLevel=getUserAccessLevel($bannedUser);
  my $p_endVoteLevels=$spads->getCommandLevels('endvote','battle','player','stopped');
  return if(exists $p_endVoteLevels->{directLevel} && $bannedUserLevel >= $p_endVoteLevels->{directLevel});

  my $p_ahPlayers=$autohost->getPlayersByNames();
  if(exists $p_ahPlayers->{$bannedUser} && %{$p_ahPlayers->{$bannedUser}} && $p_ahPlayers->{$bannedUser}{disconnectCause} == -1) {
    $autohost->sendChatMessage("/kickbynum $p_ahPlayers->{$bannedUser}{playerNb}");
  }

  my $p_ban={banType => 1,
             startDate => time,
             reason => 'kicked from lobby server',
             remainingGames => 1};
  $spads->banUser({name => $bannedUser},$p_ban);
  broadcastMsg("Battle ban added for user \"$bannedUser\" (duration: 1 game, reason: kicked from lobby server)");
}

sub cbRemoveBot {
  my (undef,undef,$bot)=@_;
  $timestamps{battleChange}=time;
  delete($autoAddedLocalBots{$bot}) if(exists $autoAddedLocalBots{$bot});
  delete($pendingLocalBotAuto{'-'.$bot}) if(exists $pendingLocalBotAuto{'-'.$bot});
  updateBattleInfoIfNeeded();
  updateBattleStates();
  updateCurrentGameType();
}

sub cbBattleClosed {
  if(! %{$lobby->{battle}} && $lobbyState >= LOBBY_STATE_BATTLE_OPENED) {
    $currentNbNonPlayer=0;
    $lobbyState=LOBBY_STATE_SYNCHRONIZED;
    %currentPlayers=();
    %currentSpecs=();
    %battleSkills=();
    %battleSkillsCache=();
    %lastRungUsers=();
    %forceSpecTimestamps=();
    %pendingFloodKicks=();
    %pendingLocalBotManual=();
    %pendingLocalBotAuto=();
    %autoAddedLocalBots=();
    %sentPlayersScriptTags=();
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onBattleClosed() if($plugins{$pluginName}->can('onBattleClosed'));
    }
  }
}

sub cbAddUser {
  my (undef,$user,$country,$id,$lobbyClient)=@_;
  if($conf{userDataRetention} !~ /^0;/ && ! $lanMode) {
    $id=0 unless(defined $id && $id ne 'None');
    $id.="($user)" unless($id);
    if(! defined $country) {
      slog("Received an invalid ADDUSER command from server (country field not provided for user $user)",2);
      $country='??';
    }
    $spads->learnUserData($user,$country,$id,$lobbyClient);
  }
  my $joinedUserLevel=getUserAccessLevel($user);
  if($joinedUserLevel >= $conf{alertLevel}) {
    if(%pendingAlerts) {
      alertUser($user);
    }else{
      $alertedUsers{$user}=0;
    }
  }
  if($user eq $sldbLobbyBot) {
    slog("TrueSkill service available",3);
    getBattleSkills();
  }
}

sub cbRemoveUser {
  my (undef,$user)=@_;
  delete $alertedUsers{$user};
  delete $authenticatedUsers{$user};
  delete $pendingRelayedJsonRpcChunks{$user};
  if($user eq $sldbLobbyBot) {
    slog("TrueSkill service unavailable!",2);
  }
}

sub cbSaid {
  my (undef,$chan,$user,$msg)=@_;
  if(! exists $lobby->{users}{$user}) {
    slog("Ignoring SAID command (unknown user: \"$user\")",2);
    $lobbyBrokenConnection=1;
    return;
  }
  logMsg("channel_$chan","<$user> $msg") if($conf{logChanChat});
  if($chan eq $masterChannel && $msg =~ /^!(\w.*)$/) {
    handleRequest("chan",$user,$1);
  }
}

sub cbChannelMessage {
  my (undef,$chan,$msg)=@_;
  logMsg("channel_$chan","* Channel message: $msg") if($conf{logChanChat});
}

sub cbServerMsg {
  my (undef,$msg)=@_;
  if($msg =~ /^Your in-?game time is (\d+) minutes/) {
    $accountInGameTime=secToTime($1*60);
  }elsif($msg =~ /^Ingame time: (.+)$/) {
    $accountInGameTime=$1;
  }elsif($lobbyState == LOBBY_STATE_OPENING_BATTLE && $msg =~ /^A TLS connection is required to host battles/) {
    cbOpenBattleFailed(undef,'lobby server requires TLS connection to host battles');
  }
}

sub cbSaidEx {
  my (undef,$chan,$user,$msg)=@_;
  logMsg("channel_$chan","* $user $msg") if($conf{logChanChat});
}

sub cbSaidPrivate {
  my (undef,$user,$msg)=@_;
  if(! exists $lobby->{users}{$user}) {
    slog("Ignoring SAIDPRIVATE command (unknown user: \"$user\")",2);
    $lobbyBrokenConnection=1;
    return;
  }
  foreach my $pluginName (@pluginsOrder) {
    return if($plugins{$pluginName}->can('onPrivateMsg') && $plugins{$pluginName}->onPrivateMsg($user,$msg) == 1);
  }
  logMsg("pv_$user","<$user> $msg") if($conf{logPvChat} && $user ne $sldbLobbyBot && $msg !~ /^!#/);
  if($msg =~ /^!([\#\w].*)$/) {
    my $cmdMsg=$1;
    if($cmdMsg =~ /^#JSONRPC((?:\(\d{1,3}\/\d{1,3}\))?) (.+)$/) {
      handleRelayedJsonRpcChunk($user,$1,$2);
    }else{
      handleRequest("pv",$user,$cmdMsg);
    }
  }
}

sub cbSaidPrivateEx {
  my (undef,$user,$msg)=@_;
  logMsg("pv_$user","* $user $msg") if($conf{logPvChat});
}

sub cbSaidBattle {
  my (undef,$user,$msg)=@_;
  my $protocolError;
  if(! exists $lobby->{users}{$user}) {
    $protocolError="unknown user: \"$user\"";
  }elsif(! %{$lobby->{battle}}) {
    $protocolError='currently out of any battle';
  }
  if(defined $protocolError) {
    slog("Ignoring SAIDBATTLE command ($protocolError)",2);
    $lobbyBrokenConnection=1;
    return;
  }
  logMsg("battle","<$user> $msg") if($conf{logBattleChat});
  return if(checkUserMsgFlood($user));
  if($msg =~ /^!(\w.*)$/) {
    handleRequest("battle",$user,$1);
  }elsif($autohost->{state} && $conf{forwardLobbyToGame} && $user ne $conf{lobbyLogin} && isUserAllowedToSpeakInGame($user)) {
    my $prompt="<$user> ";
    my $p_messages=splitMsg($msg,$conf{maxAutoHostMsgLength}-length($prompt)-1);
    foreach my $mes (@{$p_messages}) {
      $autohost->sendChatMessage("$prompt$mes");
      logMsg("game","> $prompt$mes") if($conf{logGameChat});
    }
  }
}

sub cbSaidBattleEx {
  my (undef,$user,$msg)=@_;
  my $protocolError;
  if(! exists $lobby->{users}{$user}) {
    $protocolError="unknown user: \"$user\"";
  }elsif(! %{$lobby->{battle}}) {
    $protocolError='currently out of any battle';
  }
  if(defined $protocolError) {
    slog("Ignoring SAIDBATTLEEX command ($protocolError)",2);
    $lobbyBrokenConnection=1;
    return;
  }
  logMsg("battle","* $user $msg") if($conf{logBattleChat});
  return if(checkUserMsgFlood($user));
  if($msg =~ /^suggests that (.+)$/) {
    my $suggestion=$1;
    if(getUserPref($user,"handleSuggestions")) {
      if($suggestion =~ /^([^ ]+) changes to team \#(\d+)\.$/) {
        handleRequest("battle",$user,"force $1 id $2");
      }elsif($suggestion =~ /^([^ ]+) changes to ally \#(\d+)\.$/) {
        handleRequest("battle",$user,"force $1 team $2");
      }elsif($suggestion =~ /^([^ ]+) becomes a spectator\.$/) {
        handleRequest("battle",$user,"force $1 spec");
      }
    }
  }elsif($msg =~ /^suggests (.+)$/) {
    my $mapSuggestion=$1;
    handleRequest("battle",$user,"map $mapSuggestion") if(getUserPref($user,"handleSuggestions"));
  }elsif($autohost->{state} && $conf{forwardLobbyToGame} && $user ne $conf{lobbyLogin} && isUserAllowedToSpeakInGame($user)) {
    my $prompt="* $user ";
    my $p_messages=splitMsg($msg,$conf{maxAutoHostMsgLength}-length($prompt)-1);
    foreach my $mes (@{$p_messages}) {
      $autohost->sendChatMessage("$prompt$mes");
      logMsg("game","> $prompt$mes") if($conf{logGameChat});
    }
  }
}

sub cbChannelTopic {
  my (undef,$chan,$user,$topic)=@_;
  if($conf{logChanChat}) {
    if(defined $topic && $topic ne '') {
      logMsg("channel_$chan","* Topic is '$topic' (set by $user)");
    }else{
      logMsg("channel_$chan","* No topic is set");
    }
  }
}

sub cbBattleOpened {
  my ($bId,$type,$founder,$ip,$mapHash)=($_[1],$_[2],$_[4],$_[5],$_[10]);
  my $mapName=$lobby->{battles}{$bId}{map};
  seenUserIp($founder,$ip,$lobby->{users}{$founder}{status}{bot});
  return if($type || ! $conf{autoLearnMaps} || getMapHash($mapName) || !$mapHash);
  my ($engineName,$engineVersion)=($lobby->{battles}{$bId}{engineName},$lobby->{battles}{$bId}{engineVersion});
  my $quotedVer=quotemeta($syncedSpringVersion);
  if($engineName !~ /^spring$/i || $engineVersion !~ /^$quotedVer(\..*)?$/) {
    slog("Ignoring battle $bId for automatic map learning (different game engine: \"$engineName $engineVersion\")",5);
    return;
  }
  $timestamps{mapLearned}=time;
  $spads->saveMapHash($mapName,$syncedSpringVersion,$mapHash);
}

sub cbUpdateBattleInfo {
  my ($battleId,$mapHash,$mapName)=($_[1],$_[4],$_[5]);
  return if(! $conf{autoLearnMaps} || ! defined $mapName || getMapHash($mapName) || !$mapHash);
  my ($engineName,$engineVersion)=($lobby->{battles}{$battleId}{engineName},$lobby->{battles}{$battleId}{engineVersion});
  my $quotedVer=quotemeta($syncedSpringVersion);
  if($engineName !~ /^spring$/i || $engineVersion !~ /^$quotedVer(\..*)?$/) {
    slog("Ignoring battle $battleId for automatic map learning (different game engine: \"$engineName $engineVersion\")",5);
    return;
  }
  $timestamps{mapLearned}=time;
  $spads->saveMapHash($mapName,$syncedSpringVersion,$mapHash);
}

# AutoHost interface callbacks ################################################

sub cbAhPlayerJoined {
  my (undef,undef,$name)=@_;
  logMsg("game","=== $name joined ===") if($conf{logGameJoinLeave});
  if($autohost->getState() == 1 && $timestamps{autoForcePossible} == 0 && exists($p_runningBattle->{scriptTags}{"game/startpostype"})) {
    if(%{$p_runningBattle->{bots}}) {
      slog("Game is using AI bots, cancelling auto-force start check.",5);
      $timestamps{autoForcePossible}=-1;
      return;
    }
    my $startPosType=$p_runningBattle->{scriptTags}{"game/startpostype"};
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my $p_rBUsers=$p_runningBattle->{users};
    foreach my $user (keys %{$p_rBUsers}) {
      next if($user eq $conf{lobbyLogin});
      if(! defined $p_rBUsers->{$user}{battleStatus}) {
        slog("Player \"$user\" has an undefined battleStatus in lobby, cancelling auto-force start check.",5);
        $timestamps{autoForcePossible}=-1;
        return;
      }
      if($p_rBUsers->{$user}{battleStatus}{mode}) {
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}{disconnectCause} == -2) {
          slog("Player \"$user\" hasn't joined yet, auto-force start isn't possible.",5);
          return;
        }
        if($startPosType == 2 && $p_ahPlayers->{$user}{ready} < 1) {
          slog("Player \"$user\" isn't ready yet, auto-force start isn't possible.",5);
          return;
        }
      }else{
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}{disconnectCause} == -2) {
          if($p_rBUsers->{$user}{battleStatus}{sync} != 1) {
            slog("Ignoring unsynced spectator \"$user\" for auto-force start check.",5);
          }elsif($p_rBUsers->{$user}{status}{inGame} == 1) {
            slog("Ignoring already in-game spectator \"$user\" for auto-force start check.",5);
          }else{
            slog("Spectator \"$user\" hasn't joined yet, auto-force start isn't possible.",5);
            return;
          }
        }
      }
    }
    $timestamps{autoForcePossible}=time;
  }
}

sub cbAhPlayerReady {
  my (undef,$playerNb,$readyState)=@_;
  return unless(exists $autohost->{players}{$playerNb});
  my $name=$autohost->{players}{$playerNb}{name};
  return unless($readyState > 0);
  logMsg("game","=== $name is ready ===") if($conf{logGameServerMsg});

  if($autohost->getState() == 1 && $timestamps{autoForcePossible} == 0 && exists($p_runningBattle->{scriptTags}{"game/startpostype"})) {
    if(%{$p_runningBattle->{bots}}) {
      slog("Game is using AI bots, cancelling auto-force start check.",5);
      $timestamps{autoForcePossible}=-1;
      return;
    }
    my $startPosType=$p_runningBattle->{scriptTags}{"game/startpostype"};
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my $p_rBUsers=$p_runningBattle->{users};
    foreach my $user (keys %{$p_rBUsers}) {
      next if($user eq $conf{lobbyLogin});
      if(! defined $p_rBUsers->{$user}{battleStatus}) {
        slog("Player \"$user\" has an undefined battleStatus in lobby, cancelling auto-force start check.",5);
        $timestamps{autoForcePossible}=-1;
        return;
      }
      if($p_rBUsers->{$user}{battleStatus}{mode}) {
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}{disconnectCause} == -2) {
          slog("Player \"$user\" hasn't joined yet, auto-force start isn't possible.",5);
          return;
        }
        if($startPosType == 2 && $p_ahPlayers->{$user}{ready} < 1) {
          slog("Player \"$user\" isn't ready yet, auto-force start isn't possible.",5);
          return;
        }
      }else{
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}{disconnectCause} == -2) {
          if($p_rBUsers->{$user}{battleStatus}{sync} != 1) {
            slog("Ignoring unsynced spectator \"$user\" for auto-force start check.",5);
          }elsif($p_rBUsers->{$user}{status}{inGame} == 1) {
            slog("Ignoring already in-game spectator \"$user\" for auto-force start check.",5);
          }else{
            slog("Spectator \"$user\" hasn't joined yet, auto-force start isn't possible.",5);
            return;
          }
        }
      }
    }
    $timestamps{autoForcePossible}=time;
  }
}

sub cbAhPlayerDefeated {
  my (undef,$playerNb)=@_;
  checkAutoStop();
  return unless(exists $autohost->{players}{$playerNb});
  $defeatTimes{$autohost->{players}{$playerNb}{name}}=time;
}

sub cbAhPlayerLeft {
  my (undef,$playerNb)=@_;
  if(exists $autohost->{players}{$playerNb}) {
    my $name=$autohost->{players}{$playerNb}{name};
    logMsg("game","=== $name left ===") if($conf{logGameJoinLeave});
    if(exists $currentVote{command} && exists $currentVote{remainingVoters}{$name}) {
      delete $currentVote{remainingVoters}{$name} unless($lobbyState > LOBBY_STATE_OPENING_BATTLE && %{$lobby->{battle}} && exists $lobby->{battle}{users}{$name});
    }
  }else{
    logMsg("game","=== \#$playerNb (unknown) left ===")  if($conf{logGameJoinLeave});
  }
  if($springServerType eq 'dedicated' && $autohost->{state} == 3 && $timestamps{gameOver} == 0) {
    $timestamps{gameOver}=time;
    $timestamps{autoStop}=time + ($conf{autoStop} =~ /\((\d+)\)$/ ? $1 : 5) if($timestamps{autoStop} == 0 && $conf{autoStop} ne 'off');
  }else{
    checkAutoStop();
  }
}

sub cbAhPlayerChat {
  my (undef,$playerNb,$dest,$msg)=@_;
  $msg =~ s/\cJ/<LF>/g;
  $msg =~ s/\cM/<CR>/g;
  my $player=$autohost->{players}{$playerNb}{name};
  my $destString;
  if($dest eq '') {
    $destString=isUserAllowedToSpeakInGame($player)?'':'(to spectators, forced) '
  }else{
    $destString="(to $dest) ";
  }
  logMsg("game","$destString<$player> $msg") if($conf{logGameChat});
  if($destString eq '') {
    my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-13-length($player));
    foreach my $mes (@{$p_messages}) {
      queueLobbyCommand(["SAYBATTLE","<$player> $mes"]);
    }
  }
  if($dest eq '' && "$msg" =~ /^!(\w.*)$/) {
    handleRequest("game",$player,$1);
  }
}

sub cbAhServerStarted {
  slog("Spring server started",4);
  if($usLockFhForGameStart) {
    close($usLockFhForGameStart);
    undef $usLockFhForGameStart;
  }
  if($conf{noSpecDraw}) {
    if($syncedSpringVersion =~ /^(\d+)/ && $1 < 96) {
      $autohost->sendChatMessage('/nospecdraw 0') ;
    }else{
      $autohost->sendChatMessage('/nospecdraw 1') ;
    }
  }
  my $speedControl=$conf{speedControl};
  $speedControl=2 if($speedControl == 0);
  $autohost->sendChatMessage("/speedcontrol $speedControl");
}

sub cbAhServerStartPlayingHandler {
  slog("Game started",4);
  logMsg('game','Game started') if($conf{logGameServerMsg});
  if(%currentVote && exists $currentVote{command} && @{$currentVote{command}}) {
    my $command=lc($currentVote{command}[0]);
    if($command eq "forcestart") {
      foreach my $pluginName (@pluginsOrder) {
        $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
      }
      %currentVote=();
      sayBattleAndGame("Game starting, cancelling \"forceStart\" vote");
    }
  }
  $timestamps{lastGameStartPlaying}=time;
  $autohost->sendChatMessage('/nospectatorchat 1') if($conf{noSpecChat});
  checkAutoStop();
}

sub cbAhGameTeamStat {
  my (undef,$teamNb,$frameNb,
      $metalUsed,$energyUsed,$metalProduced,$energyProduced,$metalExcess,$energyExcess,$metalReceived,$energyReceived,$metalSent,$energySent,
      $damageDealt,$damageReceived,$unitsProduced,$unitsDied,$unitsReceived,$unitsSent,$unitsCaptured,$unitsOutCaptured,$unitsKilled)=@_;
  if(! exists $runningBattleReversedMapping{teams}{$teamNb}) {
    slog("Received a GAME_TEAMSTAT message for an invalid team ID ($teamNb)",2);
    return;
  }
  my $lobbyTeam=$runningBattleReversedMapping{teams}{$teamNb};
  my $lobbyAllyTeam;
  my @names;
  foreach my $player (keys %{$p_runningBattle->{users}}) {
    if(defined $p_runningBattle->{users}{$player}{battleStatus} && $p_runningBattle->{users}{$player}{battleStatus}{mode}
       && $p_runningBattle->{users}{$player}{battleStatus}{id} == $lobbyTeam) {
      $lobbyAllyTeam=$p_runningBattle->{users}{$player}{battleStatus}{team};
      push(@names,$player);
    }
  }
  foreach my $bot (keys %{$p_runningBattle->{bots}}) {
    if($p_runningBattle->{bots}{$bot}{battleStatus}{id} == $lobbyTeam) {
      $lobbyAllyTeam=$p_runningBattle->{bots}{$bot}{battleStatus}{team};
      push(@names,"$bot (bot)");
    }
  }
  if(! defined $lobbyAllyTeam) {
    slog("Received a GAME_TEAMSTAT message for a team ID unknown in lobby ($teamNb -> $lobbyTeam)",2);
    return;
  }
  my $nameString=join(',',@names);

  $teamStats{$nameString}={allyTeam => $lobbyAllyTeam,
                           frameNb => $frameNb,
                           metalUsed => $metalUsed,
                           energyUsed => $energyUsed,
                           metalProduced => $metalProduced,
                           energyProduced => $energyProduced,
                           metalExcess => $metalExcess,
                           energyExcess => $energyExcess,
                           metalReceived => $metalReceived,
                           energyReceived => $energyReceived,
                           metalSent => $metalSent,
                           energySent => $energySent,
                           damageDealt => $damageDealt,
                           damageReceived => $damageReceived,
                           unitsProduced => $unitsProduced,
                           unitsDied => $unitsDied,
                           unitsReceived => $unitsReceived,
                           unitsSent => $unitsSent,
                           unitsCaptured => $unitsCaptured,
                           unitsOutCaptured => $unitsOutCaptured,
                           unitsKilled => $unitsKilled};
}

sub cbAhServerGameOver {
  my (undef,undef,$playerNb,@winningAllyTeams)=@_;
  if(! exists $autohost->{players}{$playerNb}) {
    slog("Ignoring Game Over message from unknown player number $playerNb",2);
    return;
  }
  $p_gameOverResults->{$autohost->{players}{$playerNb}{name}}=\@winningAllyTeams;
  slog("Game over ($autohost->{players}{$playerNb}{name})",4);
  return if(($springServerType eq 'dedicated' && $autohost->{state} < 3)
            || ($springServerType eq 'headless' && $autohost->{players}{$playerNb}{name} ne $conf{lobbyLogin}));
  $timestamps{autoStop}=time + ($conf{autoStop} =~ /\((\d+)\)$/ ? $1 : 5) if($timestamps{autoStop} == 0 && $conf{autoStop} ne 'off');
  $timestamps{gameOver}=time if($timestamps{gameOver} == 0);
}

sub cbAhServerQuit {
  my $serverQuitTime=time;
  my $gameDuration=$serverQuitTime-$timestamps{lastGameStart};

  my $gameRunningTime=secToTime($gameDuration);
  slog("Spring server shutting down (running time: $gameRunningTime)...",4);

  my %gameOverResults;
  my $nbOfGameOvers=0;
  foreach my $playerGameOver (keys %{$p_gameOverResults}) {
    $nbOfGameOvers++;
    my %processedAllyTeams;
    foreach my $winningAllyTeam (@{$p_gameOverResults->{$playerGameOver}}) {
      next if(exists $processedAllyTeams{$winningAllyTeam});
      $processedAllyTeams{$winningAllyTeam}=1;
      if(exists $gameOverResults{$winningAllyTeam}) {
        $gameOverResults{$winningAllyTeam}++;
      }else{
        $gameOverResults{$winningAllyTeam}=1;
      }
    }
  }

  my $inconsistentResults=0;
  foreach my $winningAllyTeam (keys %gameOverResults) {
    $inconsistentResults=1 if($gameOverResults{$winningAllyTeam} != $nbOfGameOvers);
    delete $gameOverResults{$winningAllyTeam} unless($gameOverResults{$winningAllyTeam} > $nbOfGameOvers/2);
  }

  my @winningAllyTeams;
  if($springServerType eq 'headless') {
    if(exists $p_gameOverResults->{$conf{lobbyLogin}}) {
      @winningAllyTeams=@{$p_gameOverResults->{$conf{lobbyLogin}}};
    }elsif(%gameOverResults) {
      slog('Unable to compute GameOver results from headless autohost (GameOver message not received), trusting clients instead...',2);
      @winningAllyTeams=keys %gameOverResults;
    }
  }else{
    @winningAllyTeams=keys %gameOverResults;
  }

  slog('Got inconsistent GameOver results',2) if($inconsistentResults);

  my %winningTeams;
  foreach my $winningAllyTeam (@winningAllyTeams) {
    if(! exists $runningBattleReversedMapping{allyTeams}{$winningAllyTeam}) {
      slog("Unknown internal ally team found ($winningAllyTeam) when computing game over result",1);
      next;
    }
    $winningTeams{$runningBattleReversedMapping{allyTeams}{$winningAllyTeam}}=[];
  }

  foreach my $player (keys %{$p_runningBattle->{users}}) {
    if(defined $p_runningBattle->{users}{$player}{battleStatus}
       && $p_runningBattle->{users}{$player}{battleStatus}{mode}) {
      $cheating=1 if($p_runningBattle->{users}{$player}{battleStatus}{bonus});
      if(exists $winningTeams{$p_runningBattle->{users}{$player}{battleStatus}{team}}) {
        push(@{$winningTeams{$p_runningBattle->{users}{$player}{battleStatus}{team}}},$player);
      }
    }
  }
  my @bots=keys %{$p_runningBattle->{bots}};
  foreach my $bot (@bots) {
    if(exists $winningTeams{$p_runningBattle->{bots}{$bot}{battleStatus}{team}}) {
      push(@{$winningTeams{$p_runningBattle->{bots}{$bot}{battleStatus}{team}}},$bot.' (bot)');
    }
  }

  my $gameResult='gameOver';
  my @winningTeamsList=keys %winningTeams;
  if($#winningTeamsList < 0) {
    if($nbOfGameOvers) {
      sayBattle('Draw game!');
    }else{
      sayBattle("Game result undecided!");
      $gameResult='undecided';
    }
  }elsif($#winningTeamsList == 0) {
    my @winningPlayers=@{$winningTeams{$winningTeamsList[0]}};
    if($#winningPlayers == 0) {
      sayBattle("$winningPlayers[0] won!");
    }else{
      my $playersString=join(', ',@winningPlayers);
      sayBattle("Ally team $winningTeamsList[0] won! ($playersString)");
    }
  }else{
    slog("Got multiple winning teams when computing game over result",2);
  }

  my @teamStatsNames;
  if($conf{nbTeams} == 1) {
    foreach my $name (keys %teamStats) {
      push(@teamStatsNames,$name) unless($name =~ / \(bot\)$/);
    }
  }else{
    @teamStatsNames=keys %teamStats;
  }
  my $nbTeamStats=$#teamStatsNames+1;
  if(($nbTeamStats > 2 && $conf{endGameAwards}) || ($nbTeamStats == 2 && $conf{endGameAwards} > 1)) {
    my %awardStats;
    foreach my $name (@teamStatsNames) {
      $awardStats{$name}={damage => $teamStats{$name}{damageDealt},
                          eco => 50 * $teamStats{$name}{metalProduced} + $teamStats{$name}{energyProduced},
                          micro => $teamStats{$name}{damageDealt}/($teamStats{$name}{damageReceived} ? $teamStats{$name}{damageReceived} : 1)};
    }
    my @sortedDamages=sort {$awardStats{$b}{damage} <=> $awardStats{$a}{damage}} (keys %awardStats);
    my @sortedEcos=sort {$awardStats{$b}{eco} <=> $awardStats{$a}{eco}} (keys %awardStats);
    my @bestDamages;
    for my $i (0..($nbTeamStats == 2 ? 1 : int($nbTeamStats/2-0.5))) {
      push(@bestDamages,$sortedDamages[$i]);
    }
    my @sortedMicros=sort {$awardStats{$b}{micro} <=> $awardStats{$a}{micro}} (@bestDamages);

    my ($damageWinner,$ecoWinner,$microWinner)=($sortedDamages[0],$sortedEcos[0],$sortedMicros[0]);
    my ($bestDamage,$bestEco,$bestMicro)=($awardStats{$damageWinner}{damage},$awardStats{$ecoWinner}{eco},$awardStats{$microWinner}{micro});
    my ($secondBestDamage,$secondBestEco,$secondBestMicro)=($awardStats{$sortedDamages[1]}{damage},$awardStats{$sortedEcos[1]}{eco},$awardStats{$sortedMicros[1]}{micro});
    my $maxLength=length($damageWinner);
    $maxLength=length($ecoWinner) if(length($ecoWinner) > $maxLength);
    $maxLength=length($microWinner) if(length($microWinner) > $maxLength);
    $damageWinner=rightPadString($damageWinner,$maxLength);
    $ecoWinner=rightPadString($ecoWinner,$maxLength);
    $microWinner=rightPadString($microWinner,$maxLength);

    my $formattedDamage=formatInteger(int($bestDamage));
    my $formattedResources=formatInteger(int($bestEco));

    my $damageAwardMsg="  Damage award:  $damageWinner  (total damage: $formattedDamage)";
    my $ecoAwardMsg="  Eco award:     $ecoWinner  (resources produced: $formattedResources)";
    my $microAwardMsg="  Micro award:   $microWinner  (damage efficiency: ".int($bestMicro*100).'%)';
    
    $maxLength=length($damageAwardMsg);
    $maxLength=length($ecoAwardMsg) if(length($ecoAwardMsg) > $maxLength);
    $maxLength=length($microAwardMsg) if(length($microAwardMsg) > $maxLength);
    $damageAwardMsg=rightPadString($damageAwardMsg,$maxLength);
    $ecoAwardMsg=rightPadString($ecoAwardMsg,$maxLength);
    $microAwardMsg=rightPadString($microAwardMsg,$maxLength);
    $damageAwardMsg.='  [ OWNAGE! ]' if($bestDamage >= 2*$secondBestDamage);
    $ecoAwardMsg.='  [ OWNAGE! ]' if($bestEco >= 2*$secondBestEco);
    $microAwardMsg.='  [ OWNAGE! ]' if($bestMicro >= $secondBestMicro+0.5);
    sayBattle($damageAwardMsg) if($bestDamage > $secondBestDamage);
    sayBattle($ecoAwardMsg) if($bestEco > $secondBestEco);
    sayBattle($microAwardMsg) if($bestMicro > $secondBestMicro);
  }

  my %teamCounts;
  foreach my $player (keys %{$p_runningBattle->{users}}) {
    if(defined $p_runningBattle->{users}{$player}{battleStatus} && $p_runningBattle->{users}{$player}{battleStatus}{mode}) {
      my $playerTeam=$p_runningBattle->{users}{$player}{battleStatus}{team};
      $teamCounts{$playerTeam}=0 unless(exists $teamCounts{$playerTeam});
      $teamCounts{$playerTeam}++;
    }
  }
  foreach my $bot (@bots) {
    my $botTeam=$p_runningBattle->{bots}{$bot}{battleStatus}{team};
    $teamCounts{$botTeam}=0 unless(exists $teamCounts{$botTeam});
    $teamCounts{$botTeam}++;
  }
  my $maxTeamSize=0;
  my $nbTeams=0;
  my @teamSizes;
  foreach my $teamNb (sort keys %teamCounts) {
    $nbTeams++;
    $maxTeamSize=$teamCounts{$teamNb} if($teamCounts{$teamNb} > $maxTeamSize);
    push(@teamSizes,$teamCounts{$teamNb});
  }
  my $gameStructure=join('v',@teamSizes);
  
  my $gameType='Solo';
  if($nbTeams == 2) {
    if($maxTeamSize == 1) {
      $gameType='Duel';
    }else{
      $gameType='Team';
    }
  }elsif($nbTeams > 2) {
    if($maxTeamSize == 1) {
      $gameType='FFA';
      $gameStructure=$nbTeams.'-way';
    }else{
      $gameType='TeamFFA';
    }
  }

  my @gdrPlayers;
  foreach my $player (keys %{$p_runningBattle->{users}}) {
    my %gdrPlayer=(accountId => $p_runningBattle->{users}{$player}{accountId},
                   name => $player,
                   ip => '',
                   team => '',
                   allyTeam => '',
                   win => 0,
                   loseTime => '');
    $gdrPlayer{loseTime}=$defeatTimes{$player}-$timestamps{lastGameStart} if(exists $defeatTimes{$player});
    $gdrPlayer{ip}=$gdrIPs{$player} if(exists $gdrIPs{$player});
    if(defined $p_runningBattle->{users}{$player}{battleStatus}
       && $p_runningBattle->{users}{$player}{battleStatus}{mode}) {
      $gdrPlayer{team}=$p_runningBattle->{users}{$player}{battleStatus}{id};
      $gdrPlayer{allyTeam}=$p_runningBattle->{users}{$player}{battleStatus}{team};
      if(! %winningTeams) {
        $gdrPlayer{win}=2;
      }elsif(exists $winningTeams{$gdrPlayer{allyTeam}}) {
        $gdrPlayer{win}=1;
      }
    }
    push(@gdrPlayers,\%gdrPlayer);
  }
  %gdrIPs=();
  my @gdrBots;
  foreach my $bot (@bots) {
    my %gdrBot=(accountId => $p_runningBattle->{users}{$p_runningBattle->{bots}{$bot}{owner}}{accountId},
                name => $bot,
                ai => $p_runningBattle->{bots}{$bot}{aiDll},
                team => $p_runningBattle->{bots}{$bot}{battleStatus}{id},
                allyTeam => $p_runningBattle->{bots}{$bot}{battleStatus}{team},
                win => 0);
    if(! %winningTeams) {
      $gdrBot{win}=2;
    }elsif(exists $winningTeams{$gdrBot{allyTeam}}) {
      $gdrBot{win}=1;
    }
    push(@gdrBots,\%gdrBot);
  }
  %gdr = (startTs => $timestamps{lastGameStart},
          duration => 0,
          engine => $syncedSpringVersion,
          type => $gameType,
          structure => $gameStructure,
          players => \@gdrPlayers,
          bots => \@gdrBots,
          result => $gameResult,
          cheating => $cheating);
  if($timestamps{lastGameStartPlaying} > 0) {
    if($timestamps{gameOver} > 0) {
      $gdr{duration}=$timestamps{gameOver} - $timestamps{lastGameStartPlaying};
    }else{
      $gdr{duration}=$serverQuitTime - $timestamps{lastGameStartPlaying};
    }
  }

  %endGameData=( startTimestamp => $timestamps{lastGameStart},
                 startPlayingTimestamp => $timestamps{lastGameStartPlaying},
                 endPlayingTimestamp => $timestamps{gameOver},
                 gameDuration => 0,
                 engineVersion => $syncedSpringVersion,
                 mod => $p_runningBattle->{mod},
                 map => $p_runningBattle->{map},
                 type => $gameType,
                 structure => $gameStructure,
                 nbBots => $#bots+1,
                 ahName => $conf{lobbyLogin},
                 ahAccountId => getLatestUserAccountId($conf{lobbyLogin}),
                 ahPassword => $conf{lobbyPassword},
                 ahPassHash => $lobby->marshallPasswd($conf{lobbyPassword}),
                 result => $gameResult,
                 cheating => $cheating,
                 players => dclone(\@gdrPlayers),
                 bots => dclone(\@gdrBots),
                 teamStats => dclone(\%teamStats),
                 battleContext => dclone($p_runningBattle));
  if($timestamps{lastGameStartPlaying} > 0) {
    if($timestamps{gameOver} > 0) {
      $endGameData{gameDuration}=$timestamps{gameOver} - $timestamps{lastGameStartPlaying};
    }else{
      $endGameData{gameDuration}=$serverQuitTime - $timestamps{lastGameStartPlaying};
    }
  }
  
  $p_runningBattle={};
  %runningBattleMapping=();
  %runningBattleReversedMapping=();
  $p_gameOverResults={};
  %defeatTimes=();
  %inGameAddedUsers=();
  %inGameAddedPlayers=();

  if(%springPrematureEndData) {
    if(($springPrematureEndData{ec} && $springPrematureEndData{ec} != 255) || $springPrematureEndData{signal} || $springPrematureEndData{core}) {
      my $logMsg="Spring crashed (running time: $gameRunningTime";
      if($springPrematureEndData{signal}) {
        $logMsg.=", interrupted by signal $springPrematureEndData{signal}";
        $logMsg.=", exit code: $springPrematureEndData{ec}" if($springPrematureEndData{ec});
      }else{
        $logMsg.=", exit code: $springPrematureEndData{ec}";
      }
      $logMsg.=', core dumped' if($springPrematureEndData{core});
      $logMsg.=')';
      slog($logMsg,1);
      broadcastMsg("Spring crashed ! (running time: $gameRunningTime)");
      addAlert('SPR-001');
    }else{
      slog('Spring server detected sync errors during game',2) if($springPrematureEndData{ec} == 255);
      broadcastMsg("Server stopped (running time: $gameRunningTime)");
      endGameProcessing();
      delete $pendingAlerts{'SPR-001'};
    }
    $inGameTime+=time-$timestamps{lastGameStart};
    setAsOutOfGame();
  }
}

sub cbAhServerWarning {
  my (undef,$msg)=@_;
  logMsg("game",$msg) if($conf{logGameServerMsg});
}

sub cbAhServerMessage {
  my (undef,$msg)=@_;
  logMsg("game",$msg) if($conf{logGameServerMsg});
  if($msg =~ /^ -> Connection established \(given id (\d+)\)$/) {

    my $playerNb=$1;
    if(! exists $autohost->{players}{$playerNb}) {
      slog("Received a connection established message for an unknown user, cancelling checks on in-game IP",2);
      return;
    }
    my $name=$autohost->{players}{$playerNb}{name};
    my $gameIp=$autohost->{players}{$playerNb}{address};
    if(! $gameIp) {
      slog("Unable to retrieve in-game IP for user $name, cancelling checks on in-game IP",2);
      return;
    }
    $gameIp=$1 if($gameIp =~ /^\[(?:::ffff:)?(\d+(?:\.\d+){3})\]:\d+$/);
    $gdrIPs{$name}=$gameIp;

    my $p_battleUserData;
    $p_battleUserData=$lobby->{battle}{users}{$name} if(%{$lobby->{battle}} && exists $lobby->{battle}{users}{$name});
    if((defined $p_battleUserData && defined $p_battleUserData->{scriptPass})
       || (exists $p_runningBattle->{users}{$name} && defined $p_runningBattle->{users}{$name}{scriptPass})) {
      if($gameIp =~ /^\d+(?:\.\d+){3}$/) {
        seenUserIp($name,$gameIp);
      }else{
        slog("Invalid in-game IP format ($gameIp) for player \"$name\"",2);
      }
    }

    my $p_lobbyUserData;
    $p_lobbyUserData=$lobby->{users}{$name} if(exists $lobby->{users}{$name});
    my $lobbyIp;
    if(defined $p_lobbyUserData && $p_lobbyUserData->{ip}) {
      $lobbyIp=$p_lobbyUserData->{ip};
    }elsif(defined $p_battleUserData && $p_battleUserData->{ip}) {
      $lobbyIp=$p_battleUserData->{ip};
    }
    if(defined $lobbyIp) {
      my $spoofProtec=getUserPref($name,'spoofProtection');
      if($spoofProtec ne 'off') {
        if($gameIp ne $lobbyIp) {
          if($spoofProtec eq 'warn') {
            sayBattleAndGame("Warning: in-game IP address does not match lobby IP address for user $name (spoof protection)");
          }else{
            sayBattleAndGame("Kicking $name from game, in-game IP address does not match lobby IP address (spoof protection)");
            $autohost->sendChatMessage("/kickbynum $playerNb");
            logMsg("game","> /kickbynum $playerNb") if($conf{logGameChat});
            return;
          }
        }
      }
    }else{
      slog("Unable to perform spoof protection for user $name, unknown lobby IP address",2) unless($name eq $conf{lobbyLogin});
    }

    $p_lobbyUserData=$p_runningBattle->{users}{$name} if(! defined $p_lobbyUserData && exists $p_runningBattle->{users}{$name});
    if(defined $p_lobbyUserData) {
      my $p_ban=$spads->getUserBan($name,$p_lobbyUserData,isUserAuthenticated($name),$gameIp,getPlayerSkillForBanCheck($name));
      if($p_ban->{banType} < 2) {
        sayBattleAndGame("Kicking $name from game (banned)");
        $autohost->sendChatMessage("/kickbynum $playerNb");
        logMsg("game","> /kickbynum $playerNb") if($conf{logGameChat});
      }elsif($p_ban->{banType} == 2 && exists $p_runningBattle->{users}{$name}
             && defined($p_runningBattle->{users}{$name}{battleStatus})
             && $p_runningBattle->{users}{$name}{battleStatus}{mode}) {
        sayBattleAndGame("Kicking $name from game (force-spec ban)");
        $autohost->sendChatMessage("/kickbynum $playerNb");
        logMsg("game","> /kickbynum $playerNb") if($conf{logGameChat});
      }
    }else{
      slog("Unable to perform in-game IP ban check for user $name, unknown user",2);
    }
  }
}

sub cbAhHookCheat {
  my $cheatMode=$_[1];
  $cheating=1 unless(defined $cheatMode && any {$cheatMode eq $_} (qw'0 n no f false off'));
}

# Plugins #####################################################################

sub removePluginFromList {
  my $pluginName=shift;
  my @newPluginOrders;
  for my $i (0..$#pluginsOrder) {
    push(@newPluginOrders,$pluginsOrder[$i]) unless($pluginsOrder[$i] eq $pluginName);
  }
  @pluginsOrder=@newPluginOrders;
}

sub reloadPlugin {
  my $pluginName=shift;
  my $p_unloadedPlugins=unloadPlugin($pluginName,'reload');
  my (@reloadedPlugins,$failedPlugin,@notReloadedPlugins);
  while(@{$p_unloadedPlugins}) {
    my $pluginToLoad=pop(@{$p_unloadedPlugins});
    if(loadPlugin($pluginToLoad,'reload')) {
      push(@reloadedPlugins,$pluginToLoad);
    }else{
      $failedPlugin=$pluginToLoad;
      @notReloadedPlugins=reverse(@{$p_unloadedPlugins});
      last;
    }
  }
  return (\@reloadedPlugins,$failedPlugin,\@notReloadedPlugins);
}

sub unloadPlugin {
  my ($pluginName,$reason)=@_;
  if(! exists $plugins{$pluginName}) {
    slog("Ignoring unloadPlugin call for plugin $pluginName (plugin is not loaded!)",2);
    return [];
  }

  my @unloadedPlugins;
  if(exists $pluginsReverseDeps{$pluginName}) {
    my @dependentPlugins=keys %{$pluginsReverseDeps{$pluginName}};
    foreach my $dependentPlugin (@dependentPlugins) {
      if(! exists $pluginsReverseDeps{$pluginName}{$dependentPlugin}) {
        slog("Ignoring already unloaded dependent plugin ($dependentPlugin) during $pluginName plugin unload operation",5);
        next;
      }
      my $p_unloadedPlugins=unloadPlugin($dependentPlugin,$reason);
      push(@unloadedPlugins,@{$p_unloadedPlugins});
    }
    slog("Plugin dependent tree not cleared during $pluginName plugin unload operation",2) if(%{$pluginsReverseDeps{$pluginName}});
    delete $pluginsReverseDeps{$pluginName};
  }

  my @dependencyPlugins;
  @dependencyPlugins=$plugins{$pluginName}->getDependencies() if($plugins{$pluginName}->can('getDependencies'));
  foreach my $dependencyPlugin (@dependencyPlugins) {
    if(! exists $pluginsReverseDeps{$dependencyPlugin}) {
      slog("Inconsistent plugin dependency state: $dependencyPlugin was not marked as having any dependent plugins whereas $pluginName is a dependent plugin",2);
      next;
    }
    if(! exists $pluginsReverseDeps{$dependencyPlugin}{$pluginName}) {
      slog("Inconsistent plugin dependency state: $pluginName was not marked as being a dependent plugin of $dependencyPlugin",2);
      next;
    }
    delete $pluginsReverseDeps{$dependencyPlugin}{$pluginName};
  }

  $plugins{$pluginName}->onUnload($reason) if($plugins{$pluginName}->can('onUnload'));
  cancelPluginLoad($pluginName);
  removePluginFromList($pluginName);
  delete($plugins{$pluginName});

  push(@unloadedPlugins,$pluginName);
  return \@unloadedPlugins;
}

sub loadPlugin {
  my ($pluginName,$reason)=@_;
  $spads->loadPluginModuleAndConf($pluginName)
      or return 0;
  $spads->applyPluginPreset($pluginName,$conf{defaultPreset});
  $spads->applyPluginPreset($pluginName,$conf{preset}) unless($conf{preset} eq $conf{defaultPreset});
  return instantiatePlugin($pluginName,$reason);
}

sub cancelPluginLoad {
  my $pluginName=shift;
  SimpleEvent::removeAllCallbacks(undef,$pluginName);
  delete $spads->{pluginsConf}{$pluginName};
  delete_package($pluginName);
  delete $INC{"$pluginName.pm"};
}

sub instantiatePlugin {
  my ($pluginName,$reason)=@_;

  my $requiredSpadsVersion=eval "$pluginName->getRequiredSpadsVersion()";
  if(hasEvalError()) {
    slog("Unable to instantiate plugin $pluginName, failed to call getRequiredSpadsVersion() function: $@",1);
    cancelPluginLoad($pluginName);
    return 0;
  }
  if(compareVersions($SPADS_VERSION,$requiredSpadsVersion) < 0) {
    slog("Unable to instantiate plugin $pluginName, this plugin requires a SPADS version >= $requiredSpadsVersion (current is $SPADS_VERSION)",1);
    cancelPluginLoad($pluginName);
    return 0;
  }

  my $hasDependencies=eval "$pluginName->can('getDependencies')";
  my @pluginDeps;
  if($hasDependencies) {
    eval "\@pluginDeps=$pluginName->getDependencies()";
    if(hasEvalError()) {
      slog("Unable to instantiate plugin $pluginName, failed to call getDependencies() function: $@",1);
      cancelPluginLoad($pluginName);
      return 0;
    }
    my @missingDeps;
    foreach my $pluginDep (@pluginDeps) {
      push(@missingDeps,$pluginDep) unless(exists $plugins{$pluginDep});
    }
    if(@missingDeps) {
      slog("Unable to instantiate plugin $pluginName, dependenc".($#missingDeps > 0 ? 'ies' : 'y').' missing: '.join(',',@missingDeps),1);
      cancelPluginLoad($pluginName);
      return 0;
    }
  }

  my $plugin=eval "$pluginName->new(\$reason)";
  if(hasEvalError()) {
    slog("Unable to instantiate plugin $pluginName: $@",1);
    cancelPluginLoad($pluginName);
    return 0;
  }
  if(! defined $plugin) {
    slog("Unable to initialize plugin $pluginName",1);
    cancelPluginLoad($pluginName);
    return 0;
  }

  foreach my $pluginDep (@pluginDeps) {
    if(! exists $pluginsReverseDeps{$pluginDep}) {
      $pluginsReverseDeps{$pluginDep}={$pluginName => 1};
    }else{
      $pluginsReverseDeps{$pluginDep}{$pluginName}=1;
    }
  }

  push(@pluginsOrder,$pluginName);
  $plugins{$pluginName}=$plugin;
  
  return 1;
}

sub pluginsOnPresetApplied {
  my ($oldPreset,$newPreset)=@_;
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onPresetApplied($oldPreset,$newPreset) if($plugins{$pluginName}->can('onPresetApplied'));
  }
}

sub pluginsUpdateSkill {
  my ($p_userSkill,$accountId)=@_;
  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('updatePlayerSkill')) {
      my $pluginResult=$plugins{$pluginName}->updatePlayerSkill($p_userSkill,
                                                                $accountId,
                                                                $lobby->{battles}{$lobby->{battle}{battleId}}{mod},
                                                                $currentGameType);
      if(ref $pluginResult eq 'ARRAY') {
        my ($newPlayerSkill,$newPlayerSigma);
        ($pluginResult,$newPlayerSkill,$newPlayerSigma)=@{$pluginResult};
        $p_userSkill->{skill}=$newPlayerSkill if(defined $newPlayerSkill);
        $p_userSkill->{sigma}=$newPlayerSigma if(defined $newPlayerSigma);
      }
      if($pluginResult) {
        if($pluginResult == 2) {
          slog("Using degraded mode for skill retrieving by plugin $pluginName ($accountId, $lobby->{battles}{$lobby->{battle}{battleId}}{mod}, $currentGameType)",2);
          $p_userSkill->{skillOrigin}='PluginDegraded';
        }else{
          $p_userSkill->{skillOrigin}='Plugin';
        }
        last;
      }
    }
  }
}

# Main ########################################################################

# Documentation ########################

if($genDoc) {
  slog("Generating SPADS documentation",3);

  *encodeHtmlEntities = eval { require HTML::Entities; 1 } ? \&HTML::Entities::encode_entities : sub { my $html=shift; $html =~ s/</\&lt\;/g; $html =~ s/>/\&gt\;/g; return $html };
  
  my $p_comHelp=$spads->getFullCommandsHelp();
  my $p_setHelp=$spads->{helpSettings};
  my %allHelp=();
  foreach my $com (keys %{$p_comHelp}) {
    $allHelp{$com}={} unless(exists $allHelp{$com});
    my @comHelp=@{$p_comHelp->{$com}};
    my $comDesc=shift(@comHelp);
    $allHelp{$com}{command}={desc => $comDesc, examples => \@comHelp};
  }
  foreach my $settingType (keys %{$p_setHelp}) {
    foreach my $setting (keys %{$p_setHelp->{$settingType}}) {
      my $settingName=$p_setHelp->{$settingType}{$setting}{name};
      $allHelp{$settingName}={} unless(exists $allHelp{$settingName});
      $allHelp{$settingName}{$settingType}=$p_setHelp->{$settingType}{$setting};
    }
  }

  my $genTime=gmtime();
  open(CSS,">$conf{instanceDir}/spadsDoc.css");
  print CSS <<EOF;
/* SPADS doc style sheet */

/* Page background color */
body { background-color: #FFFFFF }

/* Headings */
h1 { font-size: 145% }

/* Table colors */
.TableHeadingColor     { background: #CCCCFF } /* Dark mauve */
.TableSubHeadingColor  { background: #EEEEFF } /* Light mauve */
.TableRowColor         { background: #FFFFFF } /* White */

/* Font used in left-hand frame lists */
.FrameTitleFont   { font-size: 100%; font-family: Helvetica, Arial, sans-serif }
.FrameHeadingFont { font-size:  90%; font-family: Helvetica, Arial, sans-serif }
.FrameItemFont    { font-size:  90%; font-family: Helvetica, Arial, sans-serif }
.FrameCommandFont    { font-size:  90%; font-family: Helvetica, Arial, sans-serif; background-color:#E8E8FF; }
.FrameGlobalSettingFont    { font-size:  90%; font-family: Helvetica, Arial, sans-serif; background-color:#D0FFD0; }
.FrameSettingFont    { font-size:  90%; font-family: Helvetica, Arial, sans-serif; background-color:#BBFFEE; }
.FrameHostingSettingFont    { font-size:  90%; font-family: Helvetica, Arial, sans-serif; background-color:#FFE8E8; }
.FrameBattleSettingFont    { font-size:  90%; font-family: Helvetica, Arial, sans-serif; background-color:#FEFE9C; }
.FramePreferenceFont    { font-size:  90%; font-family: Helvetica, Arial, sans-serif; background-color:#FFDD88; }

/* Navigation bar fonts and colors */
.NavBarCell1    { background-color:#EEEEFF;} /* Light mauve */
.NavBarCell1Rev { background-color:#00008B;} /* Dark Blue */
.NavBarFont1    { font-family: Arial, Helvetica, sans-serif; color:#000000;}
.NavBarFont1Rev { font-family: Arial, Helvetica, sans-serif; color:#FFFFFF;}

.NavBarCell2    { font-family: Arial, Helvetica, sans-serif; background-color:#FFFFFF;}
.NavBarCell3    { font-family: Arial, Helvetica, sans-serif; background-color:#FFFFFF;}

.FormattedText  { font-family: monospace;}
EOF
  close(CSS);

  open(HTML,">$conf{instanceDir}/spadsDoc.html");
  print HTML <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Frameset//EN" "http://www.w3.org/TR/html4/frameset.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$SPADS_VERSION on $genTime GMT-->
<TITLE>SPADS Doc</TITLE>
</HEAD>

<FRAMESET cols="20%,80%" title="">
<FRAMESET rows="30%,70%" title="">
<FRAME src="spadsDoc_index.html" name="indexFrame" title="Index">
<FRAME src="spadsDoc_listAll.html" name="listFrame" title="All commands and settings">
</FRAMESET>
<FRAME src="spadsDoc_All.html" name="mainFrame" title="All commands and settings help" scrolling="yes">
<NOFRAMES>
<H2>Frame Alert</H2>
<P>
This document is designed to be viewed using the frames feature. If you see this message, you are using a non-frame-capable web client.
</NOFRAMES>
</FRAMESET>
</HTML>
EOF
  close(HTML);

  open(HTML,">$conf{instanceDir}/spadsDoc_index.html");
  print HTML <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$SPADS_VERSION on $genTime GMT-->
<TITLE>SPADS doc index</TITLE>
<LINK REL="stylesheet" TYPE="text/css" HREF="spadsDoc.css" TITLE="Style">
</HEAD>

<BODY BGCOLOR="white">

<TABLE BORDER="0" WIDTH="100%" SUMMARY="">
<TR>
<TH ALIGN="left" NOWRAP><FONT size="+1" CLASS="FrameTitleFont">
<B>SPADS v$SPADS_VERSION</B></FONT></TH>
</TR>
</TABLE>

<TABLE BORDER="0" WIDTH="100%" SUMMARY="">
<TR>
<TD NOWRAP>
<FONT CLASS="FrameItemFont"><A HREF="spadsDoc_listAll.html" target="listFrame">All commands and settings</A></FONT><BR>
<FONT CLASS="FrameCommandFont"><A HREF="spadsDoc_listCommands.html" target="listFrame">All commands</A></FONT><BR>
<FONT CLASS="FrameItemFont"><A HREF="spadsDoc_listSettings.html" target="listFrame">All settings</A></FONT><BR>
</FONT>
<P>
<FONT size="+1" CLASS="FrameHeadingFont">
Settings</FONT>
<BR>
<FONT CLASS="FrameGlobalSettingFont"><A HREF="spadsDoc_listGlobalSettings.html" target="listFrame">Global settings</A></FONT>
<BR>
<FONT CLASS="FrameSettingFont"><A HREF="spadsDoc_listPresetSettings.html" target="listFrame">Preset settings</A></FONT>
<BR>
<FONT CLASS="FrameHostingSettingFont"><A HREF="spadsDoc_listHostingSettings.html" target="listFrame">Hosting settings</A></FONT>
<BR>
<FONT CLASS="FrameBattleSettingFont"><A HREF="spadsDoc_listBattleSettings.html" target="listFrame">Battle settings</A></FONT>
<BR>
<FONT CLASS="FramePreferenceFont"><A HREF="spadsDoc_listPreferences.html" target="listFrame">Preferences</A></FONT>
<BR>
</TD>
</TR>
</TABLE>

</BODY>
</HTML>
EOF
  close(HTML);

  my %listContents = (All => ["All commands and settings","(command|global|set|hset|bset|pset)"],
                      Commands => ["All commands","command"],
                      Settings => ["All settings","(global|set|hset|bset|pset)"],
                      GlobalSettings => ["Global settings","global"],
                      PresetSettings => ["Preset settings","set"],
                      HostingSettings => ["Hosting settings","hset"],
                      BattleSettings => ["Battle settings","bset"],
                      Preferences => ["Preferences","pset"]);
  my %items = (command => ["command","FrameCommandFont","E8E8FF"],
               global => ["global setting","FrameGlobalSettingFont","D0FFD0"],
               set => ["preset setting","FrameSettingFont","BBFFEE"],
               hset => ["hosting setting","FrameHostingSettingFont","FFE8E8"],
               bset => ["battle setting","FrameBattleSettingFont","FEFE9C"],
               pset => ["preference","FramePreferenceFont","FFDD88"]);

  foreach my $listType (keys %listContents) {
    open(HTML,">$conf{instanceDir}/spadsDoc_list$listType.html");
    print HTML <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$SPADS_VERSION on $genTime GMT-->
<TITLE>$listContents{$listType}[0]</TITLE>
<LINK REL="stylesheet" TYPE="text/css" HREF="spadsDoc.css" TITLE="Style">
</HEAD>

<BODY BGCOLOR="white">

<FONT size="+1" CLASS="FrameHeadingFont">
<B>$listContents{$listType}[0]</B></FONT>
<BR>

<TABLE BORDER="0" WIDTH="100%" SUMMARY="">
<TR>
<TD NOWRAP>
EOF

    open(HTML2,">$conf{instanceDir}/spadsDoc_$listType.html");
    print HTML2 <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$SPADS_VERSION on $genTime GMT-->
<TITLE>$listContents{$listType}[0] help</TITLE>
<LINK REL="stylesheet" TYPE="text/css" HREF="spadsDoc.css" TITLE="Style">
</HEAD>

<BODY BGCOLOR="white">
EOF

    foreach my $item (sort keys %allHelp) {
      next if($item eq "");
      foreach my $itemType (sort keys %{$allHelp{$item}}) {
        next unless($itemType =~ /^$listContents{$listType}[1]$/);
        print HTML "<FONT CLASS=\"$items{$itemType}[1]\"><A HREF=\"spadsDoc_$listType.html\#$itemType:$item\" target=\"mainFrame\">$item</A></FONT><BR>\n";
        print HTML2 <<EOF;
<A NAME="$itemType:$item"></a>
<TABLE BORDER="1" WIDTH="100%" CELLPADDING="3" CELLSPACING="0" SUMMARY="">
<TR BGCOLOR="#$items{$itemType}[2]" ><TD COLSPAN=2><FONT SIZE="+2"><B>$item ($items{$itemType}[0])</B></FONT></TD></TR>
EOF
        if($itemType eq "command") {
          my $comSyntax=$allHelp{$item}{$itemType}{desc};
          $comSyntax=encodeHtmlEntities($comSyntax);
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Syntax</B></TD><TD>$comSyntax</TD></TR>\n";
          if(@{$allHelp{$item}{$itemType}{examples}}) {
            print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Example(s)</B></TD><TD>";
            foreach my $example (@{$allHelp{$item}{$itemType}{examples}}) {
              my $exampleString=encodeHtmlEntities($example);
              print HTML2 "$exampleString<BR>";
            }
            print HTML2 "</TD></TR>\n";
          }
        }else{
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Explicit name</B></TD><TD>";
          foreach my $helpLine (@{$allHelp{$item}{$itemType}{explicitName}}) {
            my $lineHtml=encodeHtmlHelp($helpLine);
            print HTML2 "$lineHtml<BR>";
          }
          print HTML2 "</TD></TR>\n";
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Description</B></TD><TD>";
          foreach my $helpLine (@{$allHelp{$item}{$itemType}{description}}) {
            my $lineHtml=encodeHtmlHelp($helpLine);
            print HTML2 "$lineHtml<BR>";
          }
          print HTML2 "</TD></TR>\n";
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Format / Allowed values</B></TD><TD CLASS=\"FormattedText\">";
          foreach my $helpLine (@{$allHelp{$item}{$itemType}{format}}) {
            my $lineHtml=encodeHtmlHelp($helpLine);
            print HTML2 "$lineHtml<BR>";
          }
          print HTML2 "</TD></TR>\n";
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Default value</B></TD><TD>";
          foreach my $helpLine (@{$allHelp{$item}{$itemType}{default}}) {
            my $lineHtml=encodeHtmlHelp($helpLine);
            print HTML2 "$lineHtml<BR>";
          }
          print HTML2 "</TD></TR>\n";
        }
        print HTML2 "</TABLE><P>\n";
      }
    }

    print HTML <<EOF;
</TD>
</TR>
</TABLE>

</BODY>
</HTML>
EOF
    close(HTML);

    print HTML2 <<EOF;
</BODY>
</HTML>
EOF
    close(HTML2);
  }

  exit EXIT_SUCCESS;
}

sub encodeHtmlHelp {
  my $line=shift;
  my %items = (command => ["command","FrameCommandFont","E8E8FF"],
               global => ["global setting","FrameGlobalSettingFont","D0FFD0"],
               set => ["preset setting","FrameSettingFont","BBFFEE"],
               hset => ["hosting setting","FrameHostingSettingFont","FFE8E8"],
               bset => ["battle setting","FrameBattleSettingFont","FEFE9C"],
               pset => ["preference","FramePreferenceFont","FFDD88"]);
  $line=encodeHtmlEntities($line);
  $line=~s/^( +)/'&nbsp' x length $1/e;
  $line=~s/\[global:(\w+)\]/<FONT CLASS=\"FrameGlobalSettingFont\"><A HREF=\"spadsDoc_GlobalSettings.html\#global:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[set:(\w+)\]/<FONT CLASS=\"FrameSettingFont\"><A HREF=\"spadsDoc_PresetSettings.html\#set:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[hSet:(\w+)\]/<FONT CLASS=\"FrameHostingSettingFont\"><A HREF=\"spadsDoc_HostingSettings.html\#hset:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[bSet:(\w+)\]/<FONT CLASS=\"FrameBattleSettingFont\"><A HREF=\"spadsDoc_BattleSettings.html\#bset:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[pSet:(\w+)\]/<FONT CLASS=\"FramePreferenceFont\"><A HREF=\"spadsDoc_Preferences.html\#pset:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  return $line;
}

sub useFallbackEngineVersion {
  my $reason=shift;
  my $autoManagedEngineFile="$conf{instanceDir}/autoManagedEngineVersion.dat";
  fatalError("$reason, and couldn't find the previous auto-installed version as fallback solution") unless(-f $autoManagedEngineFile);
  my $r_fallbackAutoManagedEngineData=retrieve($autoManagedEngineFile)
      or fatalError("$reason, and couldn't read the previous auto-installed version file \"$autoManagedEngineFile\" as fallback solution");
  $autoManagedEngineData{version}=$r_fallbackAutoManagedEngineData->{version};
  my $engineDir=$updater->getEngineDir($r_fallbackAutoManagedEngineData->{version},$r_fallbackAutoManagedEngineData->{github});
  setSpringEnv($conf{instanceDir},$engineDir,splitPaths($conf{springDataDir}));
  setSpringServerBin($engineDir);
  slog("$reason, using previous auto-installed version ($r_fallbackAutoManagedEngineData->{version}".(defined $r_fallbackAutoManagedEngineData->{github} ? ' from GitHub' : '').') as fallback solution',2);
}

# Auto-update ##########################

$timestamps{autoUpdate}=time if($conf{autoUpdateRelease} ne '');

slog("Initializing SPADS $SPADS_VERSION (PID: $$)",3);
slog('SPADS process is currently running as root!',2) unless(MSWIN32 || $>);

if($conf{autoUpdateRelease} ne "") {
  if($updater->isUpdateInProgress()) {
    slog('Skipping auto-update at start, another updater instance is already running',2);
  }else{
    my $updateRc=$updater->update();
    if($updateRc < 0) {
      slog("Unable to check or apply SPADS update",2);
      if($updateRc > -7 || $updateRc == -12) {
        addAlert("UPD-001");
      }elsif($updateRc == -7) {
        addAlert("UPD-002");
      }else{
        addAlert("UPD-003");
      }
    }elsif($updateRc > 0) {
      sleep(1); # Avoid CPU eating loop in case auto-update is broken (fork bomb protection)
      restartAfterGame("auto-update");
      $abortSpadsStartForAutoUpdate=1;
    }
  }
}

if(! $abortSpadsStartForAutoUpdate) {

  fatalError($SLI_LOADING_ERROR) if($SLI_LOADING_ERROR);
  
# Concurrent instances check ###########

  my $lockFile="$conf{instanceDir}/spads.lock";
  if(open($lockFh,'>',$lockFile)) {
    $pidFile="$conf{instanceDir}/spads.pid";
    if(autoRetry(sub {flock($lockFh, LOCK_EX|LOCK_NB)})) {
      $lockAcquired=1;
      if(open(my $pidFh,'>',$pidFile)) {
        print $pidFh $$;
        close($pidFh);
      }else{
        slog("Unable to write SPADS PID file \"$pidFile\" ($!)",2);
      }
    }else{
      my $spadsPid='unknown';
      if(-f $pidFile) {
        if(open(my $pidFh,'<',$pidFile)) {
          $spadsPid=<$pidFh>;
          close($pidFh);
          $spadsPid//='unknown';
          chomp($spadsPid);
        }else{
          slog("Unable to read SPADS PID file \"$pidFile\" ($!)",2);
        }
      }
      fatalError("Another SPADS instance (PID $spadsPid) is already running using same instanceDir ($conf{instanceDir}), please use a different instanceDir for every SPADS instance",EXIT_CONFLICT);
    }
  }else{
    fatalError("Unable to write SPADS lock file \"$lockFile\" ($!)",EXIT_SYSTEM);
  }

# Spring environment setup #############

  if($conf{autoManagedSpringVersion} ne '') {
    %autoManagedEngineData=%{SpadsConf::parseAutoManagedSpringVersion($conf{autoManagedSpringVersion})};
    fatalError("The \"autoManagedSpringVersion\" setting is configured to enable auto-download of engine using GitHub, but TLS support is missing (IO::Socket::SSL version 1.42 or superior and Net::SSLeay version 1.49 or superior are required)",EXIT_DEPENDENCY)
        if(defined $autoManagedEngineData{github} && ! SpadsUpdater::checkHttpsSupport());
    my $engineStr = defined $autoManagedEngineData{github} ? 'engine' : 'Spring';
    if($autoManagedEngineData{mode} eq 'version') {
      fatalError("Unable to auto-install $engineStr version \"$autoManagedEngineData{version}\"")
          if($updater->setupEngine($autoManagedEngineData{version},undef,$autoManagedEngineData{github}) < 0);
      my $engineDir=$updater->getEngineDir($autoManagedEngineData{version},$autoManagedEngineData{github});
      setSpringEnv($conf{instanceDir},$engineDir,splitPaths($conf{springDataDir}));
      setSpringServerBin($engineDir);
    }elsif($autoManagedEngineData{mode} eq 'release') {
      my ($autoManagedEngineVersion,$releaseTag)=$updater->resolveEngineReleaseNameToVersionWithFallback($autoManagedEngineData{release},$autoManagedEngineData{github});
      if(! defined $autoManagedEngineVersion) {
        useFallbackEngineVersion("Unable to identify the auto-managed $engineStr release");
      }else{
        my $setupResult=$updater->setupEngine($autoManagedEngineVersion,$releaseTag,$autoManagedEngineData{github});
        if($setupResult < 0) {
          $failedEngineInstallVersion=$autoManagedEngineVersion if($setupResult < -9);
          useFallbackEngineVersion("Unable to auto-install $autoManagedEngineData{release} $engineStr release (version $autoManagedEngineVersion)");
        }else{
          $autoManagedEngineData{version}=$autoManagedEngineVersion;
          my $engineDir=$updater->getEngineDir($autoManagedEngineVersion,$autoManagedEngineData{github});
          setSpringEnv($conf{instanceDir},$engineDir,splitPaths($conf{springDataDir}));
          setSpringServerBin($engineDir);
          my $autoManagedEngineFile="$conf{instanceDir}/autoManagedEngineVersion.dat";
          unlink("$conf{instanceDir}/autoManagedSpringVersion.dat"); #TODO: remove this line when this code has been in stable SPADS long enough
          nstore(\%autoManagedEngineData,$autoManagedEngineFile)
              or slog("Unable to write auto-managed $engineStr version file \"$autoManagedEngineFile\"",2);
        }
      }
    }else{
      fatalError("Invalid value of \"autoManagedSpringVersion\" setting: $conf{autoManagedSpringVersion}",EXIT_CONFIG);
    }
  }else{
    setSpringEnv($conf{instanceDir},splitPaths($conf{springDataDir}));
  }

# Spring archives loading ##############

  $syncedSpringVersion=$unitsync->GetSpringVersion();
  $fullSpringVersion=$syncedSpringVersion;
  if(! ($fullSpringVersion =~ /^(\d+)/ && $1 > 105)) {
    my $buggedUnitsync=0;
    if(! MSWIN32) {
      my $fileBin;
      if(-x '/usr/bin/file') {
        $fileBin='/usr/bin/file';
      }elsif(-x '/bin/file') {
        $fileBin='/bin/file';
      }
      $buggedUnitsync=1 if(! defined $fileBin || `$fileBin $spadsDir/PerlUnitSync.so` !~ /64\-bit/);
    }
    my $isSpringReleaseVersion;
    if($buggedUnitsync) {
      if($syncedSpringVersion =~ /^\d+$/) {
        $isSpringReleaseVersion=1;
      }else{
        $isSpringReleaseVersion=0;
      }
    }else{
      $isSpringReleaseVersion=$unitsync->IsSpringReleaseVersion();
    }
    if($isSpringReleaseVersion) {
      my $springVersionPatchset=$unitsync->GetSpringVersionPatchset();
      $fullSpringVersion.='.'.$springVersionPatchset;
    }
  }
  slog("Loading Spring archives using unitsync library version $syncedSpringVersion ...",3);
  fatalError('Unable to load Spring archives at startup') unless(loadArchives());
  setDefaultMapOfMaplist() if($conf{map} eq '');

# Init #################################

  if($springServerType eq '') {
    if($conf{springServer} =~ /spring-dedicated(?:\.exe)?$/i) {
      $springServerType='dedicated';
    }elsif($conf{springServer} =~ /spring-headless(?:\.exe)?$/i) {
      $springServerType='headless';
    }else{
      fatalError("Unable to determine server type (dedicated or headless) automatically from Spring server binary name ($conf{springServer}), please update 'springServerType' setting manually",EXIT_CONFIG);
    }
  }
  slog("Spring server mode: $springServerType",3);

  @predefinedColors=(generateBaseColorPanel(1,1),
                     {red => 100, green => 100, blue => 100},
                     generateBaseColorPanel(0.45,1),
                     {red => 150, green => 150, blue => 150},
                     generateBaseColorPanel(1,0.6),
                     {red => 50, green => 50, blue => 50},
                     generateBaseColorPanel(0.25,1),
                     {red => 200, green => 200, blue => 200},
                     generateBaseColorPanel(1,0.25));

  generateAdvancedColorPanel();

  $autohost->addCallbacks({SERVER_STARTED => \&cbAhServerStarted,
                           SERVER_GAMEOVER => \&cbAhServerGameOver,
                           SERVER_QUIT => \&cbAhServerQuit,
                           SERVER_STARTPLAYING => \&cbAhServerStartPlayingHandler,
                           PLAYER_JOINED => \&cbAhPlayerJoined,
                           PLAYER_READY => \&cbAhPlayerReady,
                           PLAYER_DEFEATED => \&cbAhPlayerDefeated,
                           PLAYER_LEFT => \&cbAhPlayerLeft,
                           PLAYER_CHAT => \&cbAhPlayerChat,
                           SERVER_WARNING => \&cbAhServerWarning,
                           SERVER_MESSAGE => \&cbAhServerMessage,
                           GAME_TEAMSTAT => \&cbAhGameTeamStat,
                           HOOK_CHEAT => \&cbAhHookCheat});

  $conf{eventModel}=~/^(auto|internal|AnyEvent)(?:\(([1-9]\d?\d?)\))?$/;
  my ($eventModel,$eventLoopTimeSlice)=($1,($2//50)/100);
  fatalError('Unable to initialize SimpleEvent module') unless(SimpleEvent::init(mode => ($eventModel eq 'auto' ? undef : $eventModel), timeSlice => $eventLoopTimeSlice, sLog => $simpleEventSimpleLog, maxChildProcesses => $conf{maxChildProcesses}));
  fatalError('Unable to register SIGTERM') unless(MSWIN32 || SimpleEvent::registerSignal('TERM', sub { quitAfterGame('SIGTERM signal received',EXIT_SUCCESS); } ));
  fatalError('Unable to create socket for Spring AutoHost interface',EXIT_SYSTEM) unless($autohost->open());
  fatalError('Unable to register Spring AutoHost interface socket') unless(SimpleEvent::registerSocket($autohost->{autoHostSock},sub { $autohost->receiveCommand() }));
  SimpleEvent::addAutoCloseOnFork(\$lockFh,\$auLockFh,\$usLockFhForGameStart);
  SimpleEvent::win32HdlDisableInheritance($lockFh) if(MSWIN32);

  if($conf{autoLoadPlugins} ne '') {
    my @pluginNames=split(/;/,$conf{autoLoadPlugins});
    foreach my $pluginName (@pluginNames) {
      instantiatePlugin($pluginName,'autoload');
    }
  }

  SimpleEvent::addTimer('SpadsMainLoop',0,0.5,\&mainLoop);
  SimpleEvent::addTimer('EngineVersionAutoManagement',$autoManagedEngineData{delay}*60,$autoManagedEngineData{delay}*60,\&engineVersionAutoManagement)
      if($autoManagedEngineData{mode} eq 'release' && $autoManagedEngineData{delay});
  SimpleEvent::addTimer('RefreshSharedData',$conf{sharedDataRefreshDelay},$conf{sharedDataRefreshDelay},sub {$spads->refreshSharedDataIfNeeded()})
      if($conf{sharedDataRefreshDelay});
  SimpleEvent::startLoop(\&postMainLoop);
}

# Main loop ############################

sub mainLoop {
  checkLobbyConnection();
  checkQueuedLobbyCommands();
  checkTimedEvents();
  manageBattle();
  checkExit();
}

sub checkLobbyConnection {
  if(! $lobbyState && ! defined $quitAfterGame{action}) {
    if($timestamps{connectAttempt} != 0 && index($conf{lobbyReconnectDelay},'-') == -1 && $conf{lobbyReconnectDelay} == 0) {
      quitAfterGame('disconnected from lobby server, no reconnection delay configured',EXIT_REMOTE);
    }else{
      if(! defined $lobbyReconnectDelay) {
        if(index($conf{lobbyReconnectDelay},'-') == -1) {
          $lobbyReconnectDelay=$conf{lobbyReconnectDelay};
        }else{
          $conf{lobbyReconnectDelay}=~/^(\d+)-(\d+)$/;
          my ($delayMin,$delayMax) = $1 > $2 ? ($2,$1) : ($1,$2);
          $lobbyReconnectDelay=$delayMin+int(rand($delayMax+1-$delayMin));
        }
      }
      if(time-$timestamps{connectAttempt} > $lobbyReconnectDelay) {
        $lobbyReconnectDelay=undef unless(index($conf{lobbyReconnectDelay},'-') == -1);
        $timestamps{connectAttempt}=time;
        $lobbyState=LOBBY_STATE_CONNECTING;
        $lobby->addCallbacks({REDIRECT => \&cbRedirect});
        $lobbyBrokenConnection=0;
        if($lobby->connect(\&cbLobbyDisconnect,{TASSERVER => \&cbLobbyConnect},\&cbConnectTimeout)) {
          if(! SimpleEvent::registerSocket($lobby->{lobbySock},sub { $lobby->receiveCommand(); checkQueuedLobbyCommands(); })) {
            quitAfterGame('unable to register Spring lobby interface socket');
          }
        }else{
          $lobby->removeCallbacks(['REDIRECT']);
          $lobbyState=LOBBY_STATE_DISCONNECTED;
          slog("Connection to lobby server failed",1);
        }
      }
    }
  }

  if($lobbyState > LOBBY_STATE_DISCONNECTED && ( (time - $timestamps{connectAttempt} > 30 && time - $lobby->{lastRcvTs} > 60) || $lobbyBrokenConnection ) ) {
    if($lobbyBrokenConnection) {
      $lobbyBrokenConnection=0;
      slog("Disconnecting from lobby server (broken connection detected)",2);
    }else{
      slog("Disconnected from lobby server (timeout)",2);
    }
    logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > LOBBY_STATE_OPENING_BATTLE && $conf{logBattleJoinLeave});
    $lobbyState=LOBBY_STATE_DISCONNECTED;
    $currentNbNonPlayer=0;
    if(%currentVote && exists $currentVote{command} && @{$currentVote{command}}) {
      foreach my $pluginName (@pluginsOrder) {
        $plugins{$pluginName}->onVoteStop(0) if($plugins{$pluginName}->can('onVoteStop'));
      }
    }
    %currentVote=();
    foreach my $joinedChan (keys %{$lobby->{channels}}) {
      logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
    }
    SimpleEvent::unregisterSocket($lobby->{lobbySock});
    $lobby->disconnect();
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onLobbyDisconnected() if($plugins{$pluginName}->can('onLobbyDisconnected'));
    }
  }

  pingIfNeeded(28);

  if(%pendingRedirect) {
    my ($ip,$port)=($pendingRedirect{ip},$pendingRedirect{port});
    %pendingRedirect=();
    slog("Following redirection to $ip:$port",3);
    if($lobbyState > LOBBY_STATE_DISCONNECTED) {
      logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > LOBBY_STATE_OPENING_BATTLE && $conf{logBattleJoinLeave});
      $lobbyState=LOBBY_STATE_DISCONNECTED;
      foreach my $joinedChan (keys %{$lobby->{channels}}) {
        logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
      }
      SimpleEvent::unregisterSocket($lobby->{lobbySock});
      $lobby->disconnect();
    }
    $conf{lobbyHost}=$ip;
    $conf{lobbyPort}=$port;
    $lobby = SpringLobbyInterface->new(serverHost => $conf{lobbyHost},
                                       serverPort => $conf{lobbyPort},
                                       simpleLog => $lobbySimpleLog,
                                       warnForUnhandledMessages => 0,
                                       inconsistencyHandler => sub { return $lobbyBrokenConnection=1; } );
    $timestamps{connectAttempt}=0;
  }
}

sub manageBattle {

  if($lobbyState == LOBBY_STATE_SYNCHRONIZED
     && ! $closeBattleAfterGame
     && $targetMod ne ''
     && exists $cachedMods{$targetMod}
     && defined $cachedMods{$targetMod}{hash}) {
    openBattle();
    return;
  }

  if($lobbyState >= LOBBY_STATE_BATTLE_OPENED
     && $closeBattleAfterGame
     && $autohost->getState() == 0) {
    closeBattle();
    return;
  }

  return if($lobbyState < LOBBY_STATE_BATTLE_OPENED || ! %{$lobby->{battle}});

  if(! $springPid && ! $loadArchivesInProgress && all {$_ eq $conf{lobbyLogin} || $lobby->{users}{$_}{status}{bot}} (keys %{$lobby->{battle}{users}}) ) {
    if($conf{restoreDefaultPresetDelay} && $timestamps{autoRestore} && time-$timestamps{autoRestore} > $conf{restoreDefaultPresetDelay}) {
      my $restoreDefaultPresetDelayTime=secToTime($conf{restoreDefaultPresetDelay});
      broadcastMsg("Battle empty for $restoreDefaultPresetDelayTime, restoring default settings");
      applyPreset($conf{defaultPreset});
      $timestamps{autoRestore}=0;
      $timestamps{rotationEmpty}=time;
      rehostAfterGame('restoring default hosting settings') if(needRehost() && ! $closeBattleAfterGame);
    }
    if($conf{rotationEmpty} ne 'off' && time - $timestamps{rotationEmpty} > $conf{rotationDelay}) {
      $timestamps{rotationEmpty}=time;
      if($conf{rotationType} eq 'preset') {
        rotatePreset($conf{rotationEmpty},0);
      }else{
        rotateMap($conf{rotationEmpty},0);
      }
    }
    if(needRehost() && ! $closeBattleAfterGame && $targetMod ne '') {
      rehostAfterGame('applying pending hosting settings while battle is empty',1);
      $timestamps{autoRestore}=time if($timestamps{autoRestore});
    }
  }

  autoManageBattle();
}

sub checkExit {
  return if($simpleEventLoopStopping);
  return unless($autohost->getState() == 0 && $springPid == 0 && defined $quitAfterGame{action});
  if($loadArchivesInProgress || $engineVersionAutoManagementInProgress || (any {$plugins{$_}->can('delayShutdown') && $plugins{$_}->delayShutdown()} @pluginsOrder)) {
    return if($closeBattleAfterGame == 1);
    if($quitAfterGame{condition} == 0) {
      slog('Game is not running, closing battle (preparing to shutdown)',3);
      $closeBattleAfterGame=1;
    }elsif($lobbyState > LOBBY_STATE_OPENING_BATTLE) {
      my @players=grep {$_ ne $conf{lobbyLogin} && ! $lobby->{users}{$_}{status}{bot}} (keys %{$lobby->{battle}{users}});
      if(! @players) {
        slog('Game is not running and battle is empty, closing battle (preparing to shutdown)',3);
        $closeBattleAfterGame=1;
      }elsif($quitAfterGame{condition} == 1) {
        if(none {defined $lobby->{battle}{users}{$_}{battleStatus} && $lobby->{battle}{users}{$_}{battleStatus}{mode}} @players) {
          slog('Game is not running and battle only contains spectators, closing battle (preparing to shutdown)',3);
          $closeBattleAfterGame=1;
        }
      }
    }    
  }else{
    if($quitAfterGame{condition} == 0) {
      slog("Game is not running, exiting",3);
      $simpleEventLoopStopping=1;
      SimpleEvent::stopLoop();
    }elsif($lobbyState > LOBBY_STATE_OPENING_BATTLE) {
      my @players=grep {$_ ne $conf{lobbyLogin} && ! $lobby->{users}{$_}{status}{bot}} (keys %{$lobby->{battle}{users}});
      if(! @players) {
        slog("Game is not running and battle is empty, exiting",3);
        $simpleEventLoopStopping=1;
        SimpleEvent::stopLoop();
      }elsif($quitAfterGame{condition} == 1) {
        if(none {defined $lobby->{battle}{users}{$_}{battleStatus} && $lobby->{battle}{users}{$_}{battleStatus}{mode}} @players) {
          slog("Game is not running and battle only contains spectators, exiting",3);
          $simpleEventLoopStopping=1;
          SimpleEvent::stopLoop();
        }
      }
    }else{
      slog("Game is not running and battle is closed, exiting",3);
      $simpleEventLoopStopping=1;
      SimpleEvent::stopLoop();
    }
  }
}

# Exit handling ########################

sub postMainLoop {
  while(@pluginsOrder) {
    my $pluginName=pop(@pluginsOrder);
    unloadPlugin($pluginName,$quitAfterGame{action} == 1 ? 'restarting' : 'exiting');
  }
  if($lobbyState) {
    foreach my $joinedChan (keys %{$lobby->{channels}}) {
      logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
    }
    logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > LOBBY_STATE_OPENING_BATTLE && $conf{logBattleJoinLeave});
    $lobbyState=LOBBY_STATE_DISCONNECTED;
    if($quitAfterGame{action} == 1) {
      sendLobbyCommand([['EXIT','AutoHost restarting']]);
    }else{
      sendLobbyCommand([['EXIT','AutoHost shutting down']]);
    }
    SimpleEvent::unregisterSocket($lobby->{lobbySock});
    $lobby->disconnect();
  }
  SimpleEvent::unregisterSignal('TERM') unless(MSWIN32);
  SimpleEvent::unregisterSocket($autohost->{autoHostSock});
  $autohost->close();
  SimpleEvent::removeTimer('SpadsMainLoop');
  SimpleEvent::removeTimer('EngineVersionAutoManagement') if($autoManagedEngineData{mode} eq 'release' && $autoManagedEngineData{delay});
  SimpleEvent::removeTimer('RefreshSharedData') if($conf{sharedDataRefreshDelay});
  SimpleEvent::removeFileLockRequest('unitsyncLock') if($timestamps{usLockRequestForGameStart});
}

$spads->dumpDynamicData();
unlink($pidFile) if(defined $pidFile);
close($lockFh) if(defined $lockFh);
if($quitAfterGame{action} == 1) {
  if(MSWIN32) {
    if(! -t STDIN && ! -t STDOUT && ! -t STDERR) {
      SimpleEvent::createDetachedProcess($^X,
                                         [$0,$confFile,map {"$_=$confMacros{$_}"} (keys %confMacros)],
                                         $CWD);
      exit EXIT_SUCCESS;
    }
    close(STDIN);
  }
  SimpleEvent::closeAllUserFds();
  portableExec($^X,$0,$confFile,map {"$_=$confMacros{$_}"} (keys %confMacros))
      or fatalError("Unable to restart SPADS ($!)");
}

exit $quitAfterGame{exitCode};
