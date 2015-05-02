#!/usr/bin/perl -w
#
# SPADS: Spring Perl Autohost for Dedicated Server
#
# Copyright (C) 2008-2015  Yann Riou <yaribzh@gmail.com>
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

use Cwd;
use Digest::MD5 'md5_base64';
use Fcntl qw':DEFAULT :flock';
use File::Copy;
use File::Spec::Functions qw'catfile file_name_is_absolute';
use IO::Select;
use IO::Socket::INET;
use IPC::Cmd 'can_run';
use List::Util qw'first shuffle';
use MIME::Base64;
use POSIX qw':sys_wait_h ceil uname';
use Storable qw'nfreeze dclone';
use Text::ParseWords;
use Tie::RefHash;
use Time::HiRes;

use SimpleLog;
use SpadsConf;
use SpadsUpdater;
use SpringAutoHostInterface;
use SpringLobbyInterface;

$SIG{TERM} = \&sigTermHandler;

my $MAX_SIGNEDINTEGER=2147483647;
my $MAX_UNSIGNEDINTEGER=4294967296;

our $spadsVer='0.11.30b';

my %optionTypes = (
  0 => "error",
  1 => "bool",
  2 => "list",
  3 => "number",
  4 => "string",
  5 => "section"
);

my %ircColors;
my %noColor;
for my $i (0..15) {
  $ircColors{$i}=''.sprintf('%02u',$i);
  $noColor{$i}='';
}
my @ircStyle=(\%ircColors,'');
my @noIrcStyle=(\%noColor,'');
my @readOnlySettings=qw'description commandsfile battlepreset hostingpreset welcomemsg welcomemsgingame maplink ghostmaplink preset battlename advertmsg endgamecommand endgamecommandenv endgamecommandmsg';

my @packagesSpads=qw'help.dat helpSettings.dat SpringAutoHostInterface.pm SpringLobbyInterface.pm SimpleLog.pm spads.pl SpadsConf.pm SpadsUpdater.pm SpadsPluginApi.pm argparse.py replay_upload.py';
my @packagesWinUnitSync=qw'PerlUnitSync.pm PerlUnitSync.dll';
my @packagesWinServer=qw'spring-dedicated.exe spring-headless.exe';
my $win=$^O eq 'MSWin32' ? 1 : 0;

eval "use HTML::Entities";
my $htmlEntitiesUnavailable=$@;

our $cwd=cwd();
my $perlExecPrefix="";
my $regLMachine;
my $STILL_ACTIVE=259;
my $NORMAL_PRIORITY_CLASS=32;
if($win) {
  eval "use Win32";
  eval "use Win32::API";
  eval "use Win32::TieRegistry ':KEY_'";
  eval "use Win32::Process";
  eval "use Win32::Process 'STILL_ACTIVE'; \$STILL_ACTIVE=STILL_ACTIVE; \$NORMAL_PRIORITY_CLASS=NORMAL_PRIORITY_CLASS;";
  $regLMachine=new Win32::TieRegistry("LMachine");
  $regLMachine->Delimiter("/") if(defined $regLMachine);
  $perlExecPrefix="perl ";
}

our %spadsHandlers = (
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
                     pass => \&hPass,
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
                     '#skill' => \&hSkill
                     );

my %alerts=('UPD-001' => 'Unable to check for SPADS update',
            'UPD-002' => 'Major SPADS update available',
            'UPD-003' => 'Unable to apply SPADS update',
            'SPR-001' => 'Spring server crashed');

my %rankSkill=(0 => 10,
               1 => 13,
               2 => 16,
               3 => 20,
               4 => 25,
               5 => 30,
               6 => 35,
               7 => 38);
my %rankTrueSkill=(0 => 20,
                   1 => 22,
                   2 => 23,
                   3 => 24,
                   4 => 25,
                   5 => 26,
                   6 => 28,
                   7 => 30);

# Basic checks ################################################################

sub invalidUsage {
  print "usage: $perlExecPrefix$0 <configurationFile> [--doc] [<macroName>=<macroValue> [...]]\n";
  exit 1;
}

invalidUsage() if($#ARGV < 0 || ! (-f $ARGV[0]));

my $genDoc=0;
sub parseMacroTokens {
  my @macroTokens=@_;
  my %macros;
  foreach my $macroToken (@macroTokens) {
    if($macroToken =~ /^([^=]+)=(.*)$/) {
      $macros{$1}=$2;
    }elsif($macroToken eq "--doc") {
      $genDoc=1;
    }else{
      return undef;
    }
  }
  return \%macros;
}

my @macroDefinitions=@ARGV;
my $confFile=shift(@macroDefinitions);
my $p_macroData=parseMacroTokens(@macroDefinitions);
invalidUsage() unless(defined $p_macroData);
my %confMacros=%{$p_macroData};


my $sLog=SimpleLog->new(prefix => "[SPADS] ");
our $spads=SpadsConf->new($confFile,$sLog,\%confMacros);

sub slog {
  $sLog->log(@_);
}

sub intRand {
  rand() =~ /\.(\d+)/;
  return $1 % 99999999;
}

if(! $spads) {
  slog("Unable to load SPADS configuration at startup",0);
  exit 1;
}

my $masterChannel=$spads->{conf}->{masterChannel};
$masterChannel=$1 if($masterChannel =~ /^([^\s]+)\s/);

unshift(@INC,$cwd);

# State variables #############################################################

our %conf=%{$spads->{conf}};
my ($lSock,$ahSock);
our %sockets;
tie %sockets, 'Tie::RefHash';
my $running=1;
my ($quitAfterGame,$closeBattleAfterGame)=(0,0);
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
                 archivesChange => 0,
                 archivesCheck => 0,
                 mapLearned => 0,
                 autoStop => -1,
                 floodPurge => time,
                 advert => time,
                 gameOver => 0);
my $syncedSpringVersion='';
my $fullSpringVersion='';
our $lobbyState=0; # (0:not_connected, 1:connecting, 2: connected, 3:logged_in, 4:start_data_received, 5:opening_battle, 6:battle_opened)
my %pendingRedirect;
my $lobbyBrokenConnection=0;
my @availableMaps;
my @availableMods;
my ($currentNbNonPlayer,$currentLockedStatus)=(0,0);
my $currentMap=$conf{map};
my $targetMod="";
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
my $updaterPid=0;
my %endGameData;
my %endGameCommandPids;
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
my $balanceState=0; # (0: not balanced, 1: balanced)
my $colorsState=0; # (0: not fixed, 1: fixed)
my @predefinedColors;
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
my $advertTime;
my $accountInGameTime;
my $cpuModel;
my ($os,$mem,$sysUptime)=getSysInfo();
my %pendingAlerts;
my %alertedUsers;
my %springPrematureEndData=();
my %bosses=();
my $balRandSeed=intRand();
my %authenticatedUsers;
my $lanMode=0;
my @pluginsOrder;
my %pluginsReverseDeps;
our %plugins;
my %battleSkills;
our %battleSkillsCache;
my %pendingGetSkills;
my $currentGameType='Duel';
our %forkedProcesses;
my ($lockFh,$pidFile);

my $lobbySimpleLog=SimpleLog->new(logFiles => [$conf{logDir}."/spads.log"],
                                  logLevels => [$conf{lobbyInterfaceLogLevel}],
                                  useANSICodes => [0],
                                  useTimestamps => [1],
                                  prefix => "[SpringLobbyInterface] ");

my $autohostSimpleLog=SimpleLog->new(logFiles => [$conf{logDir}."/spads.log"],
                                     logLevels => [$conf{autoHostInterfaceLogLevel}],
                                     useANSICodes => [0],
                                     useTimestamps => [1],
                                     prefix => "[SpringAutoHostInterface] ");

my $updaterSimpleLog=SimpleLog->new(logFiles => [$conf{logDir}."/spads.log",""],
                                    logLevels => [$conf{updaterLogLevel},3],
                                    useANSICodes => [0,1],
                                    useTimestamps => [1,0],
                                    prefix => "[SpadsUpdater] ");

our $lobby = SpringLobbyInterface->new(serverHost => $conf{lobbyHost},
                                       serverPort => $conf{lobbyPort},
                                       simpleLog => $lobbySimpleLog,
                                       warnForUnhandledMessages => 0);

our $autohost = SpringAutoHostInterface->new(autoHostPort => $conf{autoHostPort},
                                             simpleLog => $autohostSimpleLog,
                                             warnForUnhandledMessages => 0);

my @packages=@packagesSpads;
push(@packages,@packagesWinUnitSync) if($conf{autoUpdateBinaries} eq "yes" || $conf{autoUpdateBinaries} eq "unitsync");

my $updater = SpadsUpdater->new(sLog => $updaterSimpleLog,
                                localDir => $conf{binDir},
                                repository => "http://planetspads.free.fr/spads/repository",
                                release => $conf{autoUpdateRelease},
                                packages => \@packages);


our $springServerType=$conf{springServerType};
if($springServerType eq '') {
  if($conf{springServer} =~ /spring-dedicated(?:\.exe)?$/i) {
    $springServerType='dedicated';
  }elsif($conf{springServer} =~ /spring-headless(?:\.exe)?$/i) {
    $springServerType='headless';
  }else{
    slog("Unable to determine server type (dedicated or headless) automatically from Spring server binary name ($conf{springServer}), please update 'springServerType' setting manually",0);
    exit 1;
  }
}


# Binaries update (Windows only) ##############################################

$sLog=$spads->{log};

sub renameToBeDeleted {
  my $fileName=shift;
  my $i=1;
  while(-f "$fileName.$i.toBeDeleted" && $i < 100) {
    $i++;
  }
  return move($fileName,"$fileName.$i.toBeDeleted");
}

if($win) {
  if(opendir(BINDIR,$conf{binDir})) {
    my @toBeDeletedFiles = grep {/\.toBeDeleted$/} readdir(BINDIR);
    closedir(BINDIR);
    my @toBeDelAbsNames=map("$conf{binDir}/$_",@toBeDeletedFiles);
    unlink @toBeDelAbsNames;
  }
  my %updatedPackages;
  if(-f "$conf{binDir}/updateInfo.txt") {
    if(open(UPDATE_INFO,"<$conf{binDir}/updateInfo.txt")) {
      while(<UPDATE_INFO>) {
        $updatedPackages{$1}=$2 if(/^([^:]+):(.+)$/);
      }
      close(UPDATE_INFO);
    }else{
      slog("Unable to read \"$conf{binDir}/updateInfo.txt\" file",0);
      exit 1;
    }
  }
  foreach my $updatedPackage (keys %updatedPackages) {
    next unless($updatedPackage =~ /\.(exe|dll)$/);
    if(-f "$conf{binDir}/$updatedPackages{$updatedPackage}" && -f "$conf{binDir}/$updatedPackage") {
      my @origStat=stat("$conf{binDir}/$updatedPackages{$updatedPackage}");
      my @destStat=stat("$conf{binDir}/$updatedPackage");
      next if($origStat[9] <= $destStat[9]);
    }
    unlink("$conf{binDir}/$updatedPackage");
    renameToBeDeleted("$conf{binDir}/$updatedPackage") if(-f "$conf{binDir}/$updatedPackage");
    if(! copy("$conf{binDir}/$updatedPackages{$updatedPackage}","$conf{binDir}/$updatedPackage")) {
      slog("Unable to copy \"$conf{binDir}/$updatedPackages{$updatedPackage}\" to \"$conf{binDir}/$updatedPackage\", system consistency must be checked manually !",0);
      exit 1;
    }
    slog("Copying \"$conf{binDir}/$updatedPackages{$updatedPackage}\" to \"$conf{binDir}/$updatedPackage\" (Windows binary update mode)",5);
  }
  $ENV{PATH}="$ENV{PATH};$cwd;$conf{springDataDir}";
}

# Subfunctions ################################################################

sub sigTermHandler {
  quitAfterGame("SIGTERM signal received");
}

sub sigChldHandler {
  my $childPid;
  while($childPid = waitpid(-1,WNOHANG)) {
    last if($childPid == -1);
    my $exitCode=$? >> 8;
    my $signalNb=$? & 127;
    my $hasCoreDump=$? & 128;
    handleSigChld($childPid,$exitCode,$signalNb,$hasCoreDump);
  }
  $SIG{CHLD} = \&sigChldHandler;
}

sub handleSigChld {
  my ($childPid,$exitCode,$signalNb,$hasCoreDump)=@_;
  $signalNb//=0;
  $hasCoreDump//=0;
  if($childPid == $springPid) {
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
  }elsif($childPid == $updaterPid) {
    $exitCode-=256 if($exitCode > 128);
    if($exitCode || $signalNb || $hasCoreDump) {
      if($exitCode > -7) {
        delete @pendingAlerts{('UPD-002','UPD-003')};
        addAlert('UPD-001');
      }elsif($exitCode == -7) {
        delete @pendingAlerts{('UPD-001','UPD-003')};
        addAlert('UPD-002');
      }else{
        delete @pendingAlerts{('UPD-001','UPD-002')};
        addAlert('UPD-003');
      }
    }else{
      delete @pendingAlerts{('UPD-001','UPD-002','UPD-003')};
    }
    if($conf{autoRestartForUpdate} ne "off" && (! $quitAfterGame) && (! $updater->isUpdateInProgress())) {
      autoRestartForUpdate();
    }
    $updaterPid=0;
  }elsif(exists $endGameCommandPids{$childPid}) {
    my $executionTime=secToTime(time-$endGameCommandPids{$childPid}->{startTime});
    if($conf{endGameCommandMsg} ne '' && $lobbyState > 5 && %{$lobby->{battle}}) {
      my @endGameMsgs=@{$spads->{values}->{endGameCommandMsg}};
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

        my $escapedMod=$endGameCommandPids{$childPid}->{mod};
        $escapedMod=~s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/eg;
        my $escapedMap=$endGameCommandPids{$childPid}->{map};
        $escapedMap=~s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/eg;
        my $escapedDemoName=$endGameCommandPids{$childPid}->{demoFile};
        $escapedDemoName=$1 if($escapedDemoName =~ /[\/\\]([^\/\\]+)$/);
        $escapedDemoName=~s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/eg;

        $endGameMsg=~s/\%engineVersion/$endGameCommandPids{$childPid}->{engineVersion}/g;
        $endGameMsg=~s/\%mod/$escapedMod/g;
        $endGameMsg=~s/\%map/$escapedMap/g;
        $endGameMsg=~s/\%type/$endGameCommandPids{$childPid}->{type}/g;
        $endGameMsg=~s/\%ahName/$conf{lobbyLogin}/g;
        $endGameMsg=~s/\%ahAccountId/$endGameCommandPids{$childPid}->{ahAccountId}/g;
        $endGameMsg=~s/\%demoName/$escapedDemoName/g;
        $endGameMsg=~s/\%gameId/$endGameCommandPids{$childPid}->{gameId}/g;
        $endGameMsg=~s/\%result/$endGameCommandPids{$childPid}->{result}/g;

        sayBattle($endGameMsg);
      }
    }
    delete $endGameCommandPids{$childPid};
    slog("End game command finished (pid: $childPid, execution time: $executionTime, return code: $exitCode)",4);
    slog("End game commmand exited with non-null return code ($exitCode)",2) if($exitCode);
  }elsif(exists $forkedProcesses{$childPid}) {
    &{$forkedProcesses{$childPid}}($exitCode,$signalNb,$hasCoreDump);
    delete $forkedProcesses{$childPid};
  }
}

sub forkedError {
  my ($msg,$level)=@_;
  slog($msg,$level);
  exit 1;
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

sub any (&@) {
  my $code = shift;
  return defined first {&{$code}} @_;
}

sub none (&@) {
  my $code = shift;
  return ! defined first {&{$code}} @_;
}

sub all (&@) {
  my $code = shift;
  return ! defined first {! &{$code}} @_;
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
  my $length=shift;
  my @passwdChars=split("","abcdefghijklmnopqrstuvwxyz1234567890");
  my $passwd="";
  for my $i (0..($length-1)) {
    $passwd.=$passwdChars[int(rand($#passwdChars+1))];
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

sub secToTime {
  my $sec=shift;
  my @units=qw'year day hour minute second';
  my @amounts=(gmtime $sec)[5,7,2,1,0];
  $amounts[0]-=70;
  my @strings;
  for my $i (0..$#units) {
    if($amounts[$i] == 1) {
      push(@strings,"1 $units[$i]");
    }elsif($amounts[$i] > 1) {
      push(@strings,"$amounts[$i] $units[$i]s");
    }
  }
  @strings=("0 second") unless(@strings);
  return $strings[0] if($#strings == 0);
  my $endString=pop(@strings);
  my $startString=join(", ",@strings);
  return "$startString and $endString";
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
      }elsif(exists $entries[$j-2]->{$field} && defined $entries[$j-2]->{$field}) {
        $rows[$j].=rightPadString($entries[$j-2]->{$field},$length);
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
  $n=sprintf("%.1f",$n) if($n=~/^-?\d+\.\d+$/);
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

sub isRange { return $_[0] =~ /^-?\d+(?:\.\d+)?--?\d+(?:\.\d+)?$/; }

sub matchRange {
  my ($range,$val)=@_;
  return 0 unless($val =~ /^-?\d+(?:\.\d)?$/);
  $range=~/^(-?\d+(?:\.\d+)?)-(-?\d+(?:\.\d+)?)$/;
  my ($minValue,$maxValue)=($1,$2);
  if(index($val,'.') > 0) {
    return 0 if(index($minValue,'.') < 0 && index($maxValue,'.') < 0);
  }else{
    return 0 if($val ne $val+0);
  }
  return 1 if($minValue <= $val && $val <= $maxValue);
  return 0;
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

sub generateColorPanel {
  my ($s,$v)=@_;
  my @predefinedHues=(240,120,0,60,180,300,30,270,200,80,330,45,160,285);
  my @colors;
  foreach my $hue (@predefinedHues) {
    my ($r,$g,$b)=hsvToRgb($hue,$s,$v);
    push(@colors,{red => $r, green => $g, blue => $b});
  }
  return @colors;
} 

sub updateTargetMod {
  my $verbose=shift;
  $verbose//=0;
  if($spads->{hSettings}->{modName} =~ /^~(.+)$/) {
    my $modFilter=$1;
    my $newMod="";
    foreach my $availableMod (@availableMods) {
      my $modName=$availableMod->{name};
      $newMod=$modName if($modName =~ /^$modFilter$/ && $modName gt $newMod);
    }
    if($newMod) {
      if($newMod ne $targetMod) {
        broadcastMsg("New version of current mod detected ($newMod), switching when battle is empty (use !rehost to force)") if($verbose);
        $targetMod=$newMod;
      }
    }else{
      slog("Unable to find mod matching \"$modFilter\" regular expression",1);
    }
  }else{
    $targetMod=$spads->{hSettings}->{modName};
  }
}

sub pingIfNeeded {
  return unless($lobbyState > 1);
  my $delay=shift;
  $delay//=5;
  if( ( time - $timestamps{ping} > 5 && time - $lobby->{lastSndTs} > $delay )
      || ( time - $timestamps{ping} > 28 && time - $lobby->{lastRcvTs} > 28 ) ) {
    sendLobbyCommand([['PING']],5);
    $timestamps{ping}=time;
  }
}

sub loadArchives {
  my $verbose=shift;
  $verbose//=0;
  pingIfNeeded();
  $ENV{SPRING_DATADIR}=$conf{springDataDir};
  $ENV{SPRING_WRITEDIR}=$conf{varDir};
  chdir($conf{springDataDir});
  if(! PerlUnitSync::Init(0,0)) {
    slog("Unable to initialize UnitSync library",1);
    chdir($cwd);
    return 0;
  }
  my $nbMaps = PerlUnitSync::GetMapCount();
  slog("No Spring map found",2) unless($nbMaps);
  my $nbMods = PerlUnitSync::GetPrimaryModCount();
  if(! $nbMods) {
    slog("No Spring mod found",1);
    PerlUnitSync::UnInit();
    chdir($cwd);
    return 0;
  }
  @availableMaps=();
  my %availableMapsByNames=();
  for my $mapNb (0..($nbMaps-1)) {
    my $mapName = PerlUnitSync::GetMapName($mapNb);
    my $mapChecksum = PerlUnitSync::GetMapChecksum($mapNb);
    PerlUnitSync::GetMapArchiveCount($mapName);
    my $mapArchive = PerlUnitSync::GetMapArchiveName(0);
    $mapArchive=$1 if($mapArchive =~ /([^\\\/]+)$/);
    $mapChecksum-=$MAX_UNSIGNEDINTEGER if($mapChecksum > $MAX_SIGNEDINTEGER);
    $availableMaps[$mapNb]={name=>$mapName,hash=>$mapChecksum,archive=>$mapArchive,options=>{}};
    if(exists $availableMapsByNames{$mapName}) {
      slog("Duplicate archives found for map \"$mapName\" ($mapArchive)",2)
    }else{
      $availableMapsByNames{$mapName}=$mapNb;
    }
  }

  my @availableMapsNames=sort keys %availableMapsByNames;
  my $p_uncachedMapsNames = $spads->getUncachedMaps(\@availableMapsNames);
  if(@{$p_uncachedMapsNames}) {
    my %newCachedMaps;
    my $nbUncachedMaps=$#{$p_uncachedMapsNames}+1;
    my $latestProgressReportTs=0;
    for my $uncachedMapNb (0..($#{$p_uncachedMapsNames})) {
      pingIfNeeded();
      if(time - $latestProgressReportTs > 60 && $nbUncachedMaps > 4) {
        $latestProgressReportTs=time;
        slog("Caching Spring map info... $uncachedMapNb/$nbUncachedMaps (".(int(100*$uncachedMapNb/$nbUncachedMaps)).'%)',3);
      }
      my $mapName=$p_uncachedMapsNames->[$uncachedMapNb];
      my $mapNb=$availableMapsByNames{$mapName};
      $newCachedMaps{$mapName}={};
      PerlUnitSync::RemoveAllArchives();
      $newCachedMaps{$mapName}->{width}=PerlUnitSync::GetMapWidth($mapNb);
      $newCachedMaps{$mapName}->{height}=PerlUnitSync::GetMapHeight($mapNb);
      my $nbStartPos=PerlUnitSync::GetMapPosCount($mapNb);
      $newCachedMaps{$mapName}->{nbStartPos}=$nbStartPos;
      $newCachedMaps{$mapName}->{startPos}=[];
      for my $startPosNb (0..($nbStartPos-1)) {
        push(@{$newCachedMaps{$mapName}->{startPos}},[PerlUnitSync::GetMapPosX($mapNb,$startPosNb),PerlUnitSync::GetMapPosZ($mapNb,$startPosNb)]);
      }
      $newCachedMaps{$mapName}->{options}={};
      PerlUnitSync::AddAllArchives($availableMaps[$mapNb]->{archive});
      my $nbMapOptions = PerlUnitSync::GetMapOptionCount($mapName);
      for my $optionIdx (0..($nbMapOptions-1)) {
        my %option=(name => PerlUnitSync::GetOptionName($optionIdx),
                    key => PerlUnitSync::GetOptionKey($optionIdx),
                    description => PerlUnitSync::GetOptionDesc($optionIdx),
                    type => $optionTypes{PerlUnitSync::GetOptionType($optionIdx)},
                    section => PerlUnitSync::GetOptionSection($optionIdx),
                    default => "");
        next if($option{type} eq "error" || $option{type} eq "section");
        $option{description}=~s/\n/ /g;
        if($option{type} eq "bool") {
          $option{default}=PerlUnitSync::GetOptionBoolDef($optionIdx);
        }elsif($option{type} eq "number") {
          $option{default}=formatNumber(PerlUnitSync::GetOptionNumberDef($optionIdx));
          $option{numberMin}=formatNumber(PerlUnitSync::GetOptionNumberMin($optionIdx));
          $option{numberMax}=formatNumber(PerlUnitSync::GetOptionNumberMax($optionIdx));
        }elsif($option{type} eq "string") {
          $option{default}=PerlUnitSync::GetOptionStringDef($optionIdx);
          $option{stringMaxLen}=PerlUnitSync::GetOptionStringMaxLen($optionIdx);
        }elsif($option{type} eq "list") {
          $option{default}=PerlUnitSync::GetOptionListDef($optionIdx);
          $option{listCount}=PerlUnitSync::GetOptionListCount($optionIdx);
          $option{list}={};
          for my $listIdx (0..($option{listCount}-1)) {
            my %item=(name => PerlUnitSync::GetOptionListItemName($optionIdx,$listIdx),
                      description => PerlUnitSync::GetOptionListItemDesc($optionIdx,$listIdx),
                      key => PerlUnitSync::GetOptionListItemKey($optionIdx,$listIdx));
            $item{description}=~s/\n/ /g;
            $option{list}->{$item{key}}=\%item;
          }
        }
        $newCachedMaps{$mapName}->{options}->{$option{key}}=\%option;
      }
    }
    $spads->cacheMapsInfo(\%newCachedMaps);
    slog("Caching Spring map info... $nbUncachedMaps/$nbUncachedMaps (100%)",3) if($nbUncachedMaps > 4);
  }

  my @newAvailableMods=();
  for my $modNb (0..($nbMods-1)) {
    my $nbInfo = PerlUnitSync::GetPrimaryModInfoCount($modNb);
    my $modName='';
    for my $infoNb (0..($nbInfo-1)) {
      next if(PerlUnitSync::GetInfoKey($infoNb) ne 'name');
      $modName=PerlUnitSync::GetInfoValueString($infoNb);
      last;
    }
    my $modArchive = PerlUnitSync::GetPrimaryModArchive($modNb);
    my $modChecksum = PerlUnitSync::GetPrimaryModChecksum($modNb);
    $modChecksum-=$MAX_UNSIGNEDINTEGER if($modChecksum > $MAX_SIGNEDINTEGER);
    my $cachedMod=getMod($modName);
    if(defined $cachedMod && $modChecksum && $modChecksum == $cachedMod->{hash}) {
      $newAvailableMods[$modNb]=$cachedMod;
    }else{
      $newAvailableMods[$modNb]={name=>$modName,hash=>$modChecksum,archive=>$modArchive,options=>{},sides=>[]};
    }
  }
  
  for my $modNb (0..($nbMods-1)) {
    next if(@{$newAvailableMods[$modNb]->{sides}});
    pingIfNeeded();
    PerlUnitSync::RemoveAllArchives();
    PerlUnitSync::AddAllArchives($newAvailableMods[$modNb]->{archive});
    my $nbModOptions = PerlUnitSync::GetModOptionCount();
    for my $optionIdx (0..($nbModOptions-1)) {
      my %option=(name => PerlUnitSync::GetOptionName($optionIdx),
                  key => PerlUnitSync::GetOptionKey($optionIdx),
                  description => PerlUnitSync::GetOptionDesc($optionIdx),
                  type => $optionTypes{PerlUnitSync::GetOptionType($optionIdx)},
                  section => PerlUnitSync::GetOptionSection($optionIdx),
                  default => "");
      next if($option{type} eq "error" || $option{type} eq "section");
      $option{description}=~s/\n/ /g;
      if($option{type} eq "bool") {
        $option{default}=PerlUnitSync::GetOptionBoolDef($optionIdx);
      }elsif($option{type} eq "number") {
        $option{default}=formatNumber(PerlUnitSync::GetOptionNumberDef($optionIdx));
        $option{numberMin}=formatNumber(PerlUnitSync::GetOptionNumberMin($optionIdx));
        $option{numberMax}=formatNumber(PerlUnitSync::GetOptionNumberMax($optionIdx));
      }elsif($option{type} eq "string") {
        $option{default}=PerlUnitSync::GetOptionStringDef($optionIdx);
        $option{stringMaxLen}=PerlUnitSync::GetOptionStringMaxLen($optionIdx);
      }elsif($option{type} eq "list") {
        $option{default}=PerlUnitSync::GetOptionListDef($optionIdx);
        $option{listCount}=PerlUnitSync::GetOptionListCount($optionIdx);
        $option{list}={};
        for my $listIdx (0..($option{listCount}-1)) {
          my %item=(name => PerlUnitSync::GetOptionListItemName($optionIdx,$listIdx),
                    description => PerlUnitSync::GetOptionListItemDesc($optionIdx,$listIdx),
                    key => PerlUnitSync::GetOptionListItemKey($optionIdx,$listIdx));
          $item{description}=~s/\n/ /g;
          $option{list}->{$item{key}}=\%item;
        }
      }
      $newAvailableMods[$modNb]->{options}->{$option{key}}=\%option;
    }
    my $nbModSides = PerlUnitSync::GetSideCount();
    for my $sideIdx (0..($nbModSides-1)) {
      my $sideName = PerlUnitSync::GetSideName($sideIdx);
      $newAvailableMods[$modNb]->{sides}->[$sideIdx]=$sideName;
    }
  }

  PerlUnitSync::UnInit();

  @availableMods=@newAvailableMods;

  $timestamps{archivesChange}=time;
  $timestamps{archivesCheck}=time;
  updateTargetMod($verbose);

  $timestamps{mapLearned}=0;
  $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  chdir($cwd);
  return $nbMaps+$nbMods;
}

sub setDefaultMapOfMaplist {
  my $p_maps=$spads->applySubMapList();
  if(@{$p_maps}) {
    $spads->{conf}->{map}=$p_maps->[0];
    $conf{map}=$p_maps->[0];
  }
}

sub getMapHash {
  my $mapName=shift;
  for my $mapNb (0..$#availableMaps) {
    return $availableMaps[$mapNb]->{hash} if($availableMaps[$mapNb]->{name} eq $mapName);
  }
  return $spads->getMapHash($mapName,$syncedSpringVersion);
}

sub getMapHashAndArchive {
  my $mapName=shift;
  for my $mapNb (0..$#availableMaps) {
    return ($availableMaps[$mapNb]->{hash},$availableMaps[$mapNb]->{archive}) if($availableMaps[$mapNb]->{name} eq $mapName);
  }
  return ($spads->getMapHash($mapName,$syncedSpringVersion),'');
}

sub getMod {
  my $modName=shift;
  for my $modNb (0..$#availableMods) {
    return $availableMods[$modNb] if($availableMods[$modNb]->{name} eq $modName);
  }
  return undef;
}

sub getModHash {
  my $modName=shift;
  for my $modNb (0..$#availableMods) {
    return $availableMods[$modNb]->{hash} if($availableMods[$modNb]->{name} eq $modName);
  }
  return 0;
}

sub getModArchive {
  my $modName=shift;
  for my $modNb (0..$#availableMods) {
    return $availableMods[$modNb]->{archive} if($availableMods[$modNb]->{name} eq $modName);
  }
  return 0;
}

sub getModOptions {
  my $modName=shift;
  for my $modNb (0..$#availableMods) {
    return $availableMods[$modNb]->{options} if($availableMods[$modNb]->{name} eq $modName);
  }
  return {};
}

sub getModSides {
  my $modName=shift;
  for my $modNb (0..$#availableMods) {
    return $availableMods[$modNb]->{sides} if($availableMods[$modNb]->{name} eq $modName);
  }
  return [];
}

sub getMapOptions {
  my $mapName=shift;
  my $p_mapInfo=$spads->getCachedMapInfo($mapName);
  my $p_mapOptions={};
  $p_mapOptions=$p_mapInfo->{options} if(defined $p_mapInfo);
  return $p_mapOptions;
}

sub getSysInfo {
  my ($osVersion,$memAmount,$uptime)=("","",0);
  my @uname=uname();
  if($win) {
    $osVersion=Win32::GetOSName();
    $osVersion.=" - $uname[0] $uname[2] - $uname[3]";
    
    Win32::API::Struct->typedef(
      MEMORYSTATUS => qw{
        DWORD dwLength;
        DWORD MemLoad;
        DWORD TotalPhys;
        DWORD AvailPhys;
        DWORD TotalPage;
        DWORD AvailPage;
        DWORD TotalVirtual;
        DWORD AvailVirtual;
      }
    );
    if(Win32::API->Import( 'kernel32', 'VOID GlobalMemoryStatus(LPMEMORYSTATUS lpMemoryStatus)' )) {
      my $memStatus = Win32::API::Struct->new('MEMORYSTATUS');
      $memStatus->align('auto');
      $memStatus->{'dwLength'}     = 0;
      $memStatus->{'MemLoad'}      = 0;
      $memStatus->{'TotalPhys'}    = 0;
      $memStatus->{'AvailPhys'}    = 0;
      $memStatus->{'TotalPage'}    = 0;
      $memStatus->{'AvailPage'}    = 0;
      $memStatus->{'TotalVirtual'} = 0;
      $memStatus->{'AvailVirtual'} = 0;      
      GlobalMemoryStatus($memStatus);
      if($memStatus->{dwLength} != 0) {
        $memAmount=int($memStatus->{'TotalPhys'} / (1024 * 1024));
        $memAmount.=" MB";
      }else{
        slog("Unable to retrieve total physical memory through GlobalMemoryStatus function (Win32 API)",2);
      }
    }else{
      slog("Unable to retrieve total physical memory through GlobalMemoryStatus function (Win32 API)",2);
    }

    $uptime=int(Win32::GetTickCount() / 1000);
  }else{
    if(-f "/etc/issue.net") {
      $osVersion=`cat /etc/issue.net`;
      chomp($osVersion);
    }
    my $kernelVersion="$uname[0] $uname[2]";
    if($kernelVersion ne "") {
      if($osVersion ne "") {
        $osVersion.=" ($kernelVersion)";
      }else{
        $osVersion=$kernelVersion;
      }
    }
    if(-f "/proc/meminfo") {
      my @memInfo=`cat /proc/meminfo 2>/dev/null`;
      foreach my $line (@memInfo) {
        if($line =~ /^\s*MemTotal\s*:\s*(\d+\s*\w+)$/) {
          $memAmount=$1;
          last;
        }
      }
    }
    if(-f "/proc/uptime") {
      my $uptimeInfo=`cat /proc/uptime 2>/dev/null`;
      if($uptimeInfo =~ /^\s*(\d+)/) {
        $uptime=$1;
      }
    }
  }
  return ($osVersion,$memAmount,$uptime);
}

sub getCpuSpeed {
  my $realCpuSpeed=getRealCpuSpeed();
  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('forceCpuSpeedValue')) {
      my $cpuPlugin=$plugins{$pluginName}->forceCpuSpeedValue();
      return $cpuPlugin if(defined $cpuPlugin);
    }
  }
  return $realCpuSpeed;
}

sub getRealCpuSpeed {
  if($win) {
    my $cpuInfo;
    $cpuInfo=$regLMachine->Open("Hardware/Description/System/CentralProcessor/0", { Access => KEY_READ() }) if(defined $regLMachine);
    if(defined $cpuInfo) {
      my $procName=$cpuInfo->GetValue("ProcessorNameString");
      if(defined $procName) {
        $cpuModel=$procName;
        return $1 if($cpuModel =~ /(\d+)\+/);
      }
      my $procMhz=hex($cpuInfo->GetValue("~MHz"));
      return $procMhz if(defined $procMhz);
    }
    slog("Unable to retrieve CPU info from Windows registry",2);
    return 0;
  }elsif(-f "/proc/cpuinfo" && -r "/proc/cpuinfo") {
    my @cpuInfo=`cat /proc/cpuinfo 2>/dev/null`;
    my %cpu;
    foreach my $line (@cpuInfo) {
      if($line =~ /^([\w\s]*\w)\s*:\s*(.*)$/) {
        $cpu{$1}=$2;
      }
    }
    $cpuModel=$cpu{"model name"} if(exists $cpu{"model name"});
    if(defined $cpu{"model name"} && $cpu{"model name"} =~ /(\d+)\+/) {
      return $1;
    }
    if(defined $cpu{"cpu MHz"} && $cpu{"cpu MHz"} =~ /^(\d+)(?:\.\d*)?$/) {
      return $1;
    }
    if(defined $cpu{bogomips} && $cpu{bogomips} =~ /^(\d+)(?:\.\d*)?$/) {
      return $1;
    }
    slog("Unable to parse CPU info from /proc/cpuinfo",2);
    return 0;
  }else{
    slog("Unable to retrieve CPU info from /proc/cpuinfo",2);
    return 0;
  }
}

sub getLocalLanIp {
  my @ips;
  if($win) {
    my $netIntsEntry;
    $netIntsEntry=$regLMachine->Open("System/CurrentControlSet/Services/Tcpip/Parameters/Interfaces/", { Access => KEY_READ() }) if(defined $regLMachine);
    if(defined $netIntsEntry) {
      my @interfaces=$netIntsEntry->SubKeyNames();
      foreach my $interface (@interfaces) {
        my $netIntEntry=$netIntsEntry->Open($interface, { Access => KEY_READ() });
        my $ipAddr=$netIntEntry->GetValue("IPAddress");
        push(@ips,$1) if(defined $ipAddr && $ipAddr =~ /(\d+\.\d+\.\d+\.\d+)/);
      }
    }else{
      slog("Unable to find network interfaces in registry, trying ipconfig workaround...",2);
      my @ipConfOut=`ipconfig`;
      foreach my $line (@ipConfOut) {
        next unless($line =~ /IP.*\:\s*(\d+\.\d+\.\d+\.\d+)\s/);
        push(@ips,$1);
      }
    }    
  }else{
    $ENV{LANG}="C";
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
      if(defined $ifconfigBin) {
        push(@ips,$1) if($line =~ /inet addr:\s*(\d+\.\d+\.\d+\.\d+)\s/);
      }else{
        push(@ips,$1) if($line =~ /inet\s+(\d+\.\d+\.\d+\.\d+)/);
      }
    }
  }
  foreach my $ip (@ips) {
    if($ip =~ /^10\./ || $ip =~ /192\.168\./) {
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

sub getDirModifTime {
  return (stat(shift))[9] // 0;
}

sub getArchivesChangeTime {
  my $archivesChangeTs=getDirModifTime("$conf{springDataDir}/base");
  my $dirChangeTs=getDirModifTime("$conf{springDataDir}/games");
  $archivesChangeTs=$dirChangeTs if($dirChangeTs > $archivesChangeTs);
  $dirChangeTs=getDirModifTime("$conf{springDataDir}/maps");
  $archivesChangeTs=$dirChangeTs if($dirChangeTs > $archivesChangeTs);
  $dirChangeTs=getDirModifTime("$conf{springDataDir}/packages");
  $archivesChangeTs=$dirChangeTs if($dirChangeTs > $archivesChangeTs);
  return $archivesChangeTs;
}

sub quitAfterGame {
  my $reason=shift;
  $quitAfterGame=1;
  my $msg="AutoHost shutdown scheduled (reason: $reason)";
  broadcastMsg($msg);
  slog($msg,3);
}

sub restartAfterGame {
  my $reason=shift;
  $quitAfterGame=2;
  my $msg="AutoHost restart scheduled (reason: $reason)";
  broadcastMsg($msg);
  slog($msg,3);
}

sub quitWhenEmpty {
  my $reason=shift;
  $quitAfterGame=3;
  my $msg="AutoHost shutdown scheduled when battle is empty (reason: $reason)";
  broadcastMsg($msg);
  slog($msg,3);
}

sub restartWhenEmpty {
  my $reason=shift;
  $quitAfterGame=4;
  my $msg="AutoHost restart scheduled when battle is empty (reason: $reason)";
  broadcastMsg($msg);
  slog($msg,3);
}

sub quitWhenOnlySpec {
  my $reason=shift;
  $quitAfterGame=5;
  my $msg="AutoHost shutdown scheduled when battle only contains spectators (reason: $reason)";
  broadcastMsg($msg);
  slog($msg,3);
}

sub restartWhenOnlySpec {
  my $reason=shift;
  $quitAfterGame=6;
  my $msg="AutoHost restart scheduled when battle only contains spectators (reason: $reason)";
  broadcastMsg($msg);
  slog($msg,3);
}

sub cancelQuitAfterGame {
  my $reason=shift;
  my $msg;
  if($quitAfterGame == 1 || $quitAfterGame == 3 || $quitAfterGame == 5) {
    $msg="AutoHost shutdown cancelled (reason: $reason)";
  }else{
    $msg="AutoHost restart cancelled (reason: $reason)";
  }
  $quitAfterGame=0;
  broadcastMsg($msg);
  slog($msg,3);
}

sub closeBattleAfterGame {
  my $reason=shift;
  $closeBattleAfterGame=1;
  my $msg="Close battle scheduled (reason: $reason)";
  broadcastMsg($msg);
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
  $closeBattleAfterGame=0;
  my $msg="Close battle cancelled";
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
  if($params[0]->[0] =~ /SAYPRIVATE/) {
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
    $lobbyBrokenConnection=1 if($lobbyState > 0);
  }
}

sub checkQueuedLobbyCommands {
  return unless($lobbyState > 1 && (@messageQueue || @lowPriorityMessageQueue));
  my $alreadySent=checkLastSentMessages();
  while(@messageQueue) {
    my $toBeSent=computeMessageSize($messageQueue[0]->[0]);
    last if($alreadySent+$toBeSent+5 >= $conf{maxBytesSent});
    my $p_command=shift(@messageQueue);
    sendLobbyCommand($p_command,$toBeSent);
    $alreadySent+=$toBeSent;
  }
  my $nbMsgSentInLoop=0;
  while(@lowPriorityMessageQueue && $nbMsgSentInLoop < 100) {
    my $toBeSent=computeMessageSize($lowPriorityMessageQueue[0]->[0]);
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
  $password=generatePassword(8) if($password eq "_RANDOM_");
  my $mapHash=getMapHash($conf{map});
  if(! $mapHash) {
    slog("Unable to retrieve hashcode of map \"$conf{map}\"",1);
    closeBattleAfterGame("unable to retrieve map hashcode");
    return 0;
  }
  my $modHash=getModHash($targetMod);
  if(! $modHash) {
    slog("Unable to retrieve hashcode of mod \"$targetMod\"",1);
    closeBattleAfterGame("unable to retrieve mod hashcode");
    return 0;
  }
  $lobbyState=5;
  if($fullSpringVersion eq '') {
    queueLobbyCommand(['OPENBATTLE',
                       0,
                       $hSettings{natType},
                       $password,
                       $hSettings{port},
                       $hSettings{maxPlayers},
                       $modHash,
                       $hSettings{minRank},
                       $mapHash,
                       $conf{map},
                       $hSettings{battleName},
                       $targetMod],
                      {OPENBATTLE => \&cbOpenBattle,
                       OPENBATTLEFAILED => \&cbOpenBattleFailed},
                      \&cbOpenBattleTimeout);
  }else{
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
                      \&cbOpenBattleTimeout);
  }
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
}

sub closeBattle {
  queueLobbyCommand(["LEAVEBATTLE"]);
  $currentNbNonPlayer=0;
  $lobbyState=4;
  $closeBattleAfterGame=0 if($closeBattleAfterGame == 2);
  if(%bosses) {
    broadcastMsg("Boss mode disabled");
    %bosses=();
  }
  logMsg("battle","=== $conf{lobbyLogin} left ===") if($conf{logBattleJoinLeave});
}

sub applyMapBoxes {
  return unless(%{$lobby->{battle}});
  foreach my $teamNb (keys %{$lobby->{battle}->{startRects}}) {
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]);
  }
  return unless($spads->{bSettings}->{startpostype} == 2);
  my $smfMapName=$conf{map};
  $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
  my $p_boxes=$spads->getMapBoxes($smfMapName,$conf{nbTeams},$conf{extraBox});
  foreach my $pluginName (@pluginsOrder) {
    my $overwritten=$plugins{$pluginName}->setMapStartBoxes($p_boxes,$conf{map},$conf{nbTeams},$conf{extraBox}) if($plugins{$pluginName}->can('setMapStartBoxes'));
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
  my $currentModName=$lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod};
  my $p_modOptions=getModOptions($currentModName);
  my $p_mapOptions=getMapOptions($currentMap);
  my $bValue;
  if(exists $bSettings{$bSetting}) {
    $bValue=$bSettings{$bSetting};
  }elsif(exists $p_modOptions->{$bSetting}) {
    $bValue=$p_modOptions->{$bSetting}->{default};
  }elsif(exists $p_mapOptions->{$bSetting}) {
    $bValue=$p_mapOptions->{$bSetting}->{default};
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
  if(exists $lobby->{battle}->{scriptTags}) {
    my @scriptTagsToDelete;
    foreach my $scriptTag (keys %{$lobby->{battle}->{scriptTags}}) {
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
      $bValue=$p_mapOptions->{$scriptTagsSetting}->{default};
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
  my $currentModName=$lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod};
  my $p_modOptions=getModOptions($currentModName);
  my @scriptTagsSettings=("game/startPosType=$bSettings{startpostype}",'game/hosttype=SPADS');
  foreach my $scriptTagsSetting (keys %{$p_modOptions}) {
    my $bValue;
    if(exists $bSettings{$scriptTagsSetting}) {
      $bValue=$bSettings{$scriptTagsSetting};
    }else{
      $bValue=$p_modOptions->{$scriptTagsSetting}->{default};
    }
    push(@scriptTagsSettings,"game/modoptions/$scriptTagsSetting=$bValue");
  }
  my $p_mapOptions=getMapOptions($currentMap);
  foreach my $scriptTagsSetting (keys %{$p_mapOptions}) {
    my $bValue;
    if(exists $bSettings{$scriptTagsSetting}) {
      $bValue=$bSettings{$scriptTagsSetting};
    }else{
      $bValue=$p_mapOptions->{$scriptTagsSetting}->{default};
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
  my %battleUsers=%{$lobby->{battle}->{users}};
  foreach my $user (keys %battleUsers) {
    $nbSpec++ if(defined $battleUsers{$user}->{battleStatus} && (! $battleUsers{$user}->{battleStatus}->{mode}));
  }
  return $nbSpec;
}

sub getNbNonPlayer {
  my $nbNonPlayer=0;
  my %battleUsers=%{$lobby->{battle}->{users}};
  foreach my $user (keys %battleUsers) {
    $nbNonPlayer++ unless(defined $battleUsers{$user}->{battleStatus} && $battleUsers{$user}->{battleStatus}->{mode});
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
  my @clients=keys %{$lobby->{battle}->{users}};
  $manualLockedStatus=0 if($#clients+1-$nbNonPlayer < $conf{minPlayers});
  my $targetLockedStatus=$manualLockedStatus;
  my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
  my $nbPlayers=$#clients+1-$nbNonPlayer;
  my @bots=keys %{$lobby->{battle}->{bots}};
  if($conf{nbTeams} != 1) {
    my $nbAutoAddedLocalBots=keys %autoAddedLocalBots;
    $nbPlayers+=$#bots+1-$nbAutoAddedLocalBots;
  }
  if($conf{autoLock} eq 'off') {
    if($conf{maxSpecs} ne '' && $nbNonPlayer > $conf{maxSpecs}) {
      $targetLockedStatus=1 if($nbPlayers >= $spads->{hSettings}->{maxPlayers} || ($conf{autoSpecExtraPlayers} && $nbPlayers >= $targetNbPlayers));
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
    $targetLockedStatus=0 if($nbPlayers >= $lobby->{battles}->{$lobby->{battle}->{battleId}}->{maxPlayers} && ! @bots);
    $targetLockedStatus=1 if($conf{maxSpecs} ne '' && $nbNonPlayer > $conf{maxSpecs} && $nbPlayers >= $spads->{hSettings}->{maxPlayers});
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
  $targetLockedStatus=1 if($conf{autoLockRunningBattle} && $lobby->{users}->{$conf{lobbyLogin}}->{status}->{inGame});
  return ($nbNonPlayer,$targetLockedStatus);
}

sub updateBattleStates {
  if($lobbyState < 6) {
    $balanceState=0;
    $colorsState=0;
  }else{
    $balanceState=isBalanceTargetApplied();
    $colorsState=areColorsApplied();
  }
}

sub updateBattleInfoIfNeeded {

  return if($lobbyState < 6);

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

sub addAlert {
  my $alert=shift;
  if(exists $alerts{$alert}) {
    $pendingAlerts{$alert}={occurrences => 0} unless(exists $pendingAlerts{$alert});
    $pendingAlerts{$alert}->{occurrences}++;
    $pendingAlerts{$alert}->{latest}=time;
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
  foreach my $alert (sort {$pendingAlerts{$a}->{latest} <=> $pendingAlerts{$b}->{latest}} (keys %pendingAlerts)) {
    my $latestOccurrenceDelay=time-$pendingAlerts{$alert}->{latest};
    if($latestOccurrenceDelay > $conf{alertDuration}*3600) {
      delete $pendingAlerts{$alert};
      next;
    }
    my $alertMsg="[$B$C{4}ALERT$C{1}$B] - $C{12}$alert$C{1} - $alerts{$alert}";
    my $latestOccurrenceDelayString="";
    $latestOccurrenceDelayString=secToTime($latestOccurrenceDelay) if($latestOccurrenceDelay > 0);
    if($pendingAlerts{$alert}->{occurrences} > 1) {
      $alertMsg.=" (x$pendingAlerts{$alert}->{occurrences}";
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
    logMsg("pv_$user","<$conf{lobbyLogin}> $mes") if($conf{logPvChat} && $user ne $gdrLobbyBot && $user ne $sldbLobbyBot);
  }
}

sub sayBattle {
  my $msg=shift;
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-14);
  foreach my $mes (@{$p_messages}) {
    queueLobbyCommand(["SAYBATTLEEX","* $mes"]);
  }
}

sub sayBattleUser {
  my ($user,$msg)=@_;
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-22-length($user));
  foreach my $mes (@{$p_messages}) {
    queueLobbyCommand(["SAYBATTLEPRIVATEEX",$user,"* $mes"]);
    logMsg("battle","(to $user) * $conf{lobbyLogin} * $mes") if($conf{logBattleChat});
  }
}

sub sayChan {
  my ($chan,$msg)=@_;
  return unless($lobbyState >= 4 && (exists $lobby->{channels}->{$chan}));
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

  my $gameState="stopped";
  $gameState="running" if($autohost->getState());

  my $status="outside";
  if($gameState eq "running" && exists $p_runningBattle->{users}->{$user} && %{$autohost->getPlayer($user)}) {
    if(defined $p_runningBattle->{users}->{$user}->{battleStatus} && $p_runningBattle->{users}->{$user}->{battleStatus}->{mode}) {
      my $p_ahPlayer=$autohost->getPlayer($user);
      if($p_ahPlayer->{disconnectCause} == -1 && $p_ahPlayer->{lost} == 0) {
        $status="playing";
      }else{
        $status="player";
      }
    }else{
      $status="spec";
    }
  }elsif(%{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$user}) {
    if(defined $lobby->{battle}->{users}->{$user}->{battleStatus} && $lobby->{battle}->{users}->{$user}->{battleStatus}->{mode}) {
      $status="player";
    }else{
      $status="spec";
    }
  }

  return $spads->getCommandLevels($cmd,$source,$status,$gameState);

}

sub getUserAccessLevel {
  my $user=shift;
  my $p_userData;
  if(! exists $lobby->{users}->{$user}) {
    return 0 unless(exists $p_runningBattle->{users} && exists $p_runningBattle->{users}->{$user});
    $p_userData=$p_runningBattle->{users}->{$user};
  }else{
    $p_userData=$lobby->{users}->{$user};
  }
  my $isAuthenticated=isUserAuthenticated($user);
  my $coreUserAccessLevel=$spads->getUserAccessLevel($user,$p_userData,$isAuthenticated);
  foreach my $pluginName (@pluginsOrder) {
    my $newUserAccessLevel=$plugins{$pluginName}->changeUserAccessLevel($user,$p_userData,$isAuthenticated,$coreUserAccessLevel) if($plugins{$pluginName}->can('changeUserAccessLevel'));
    return $newUserAccessLevel if(defined $newUserAccessLevel);
  }
  return $coreUserAccessLevel;
}

sub deprecatedMsg {
  my ($user,$cmd,$action)=@_;
  if($conf{springieEmulation} eq "warn" && exists $lobby->{users}->{$user} && (! $lobby->{users}->{$user}->{status}->{inGame})) {
    sayPrivate($user,getDeprecatedMsg($cmd,$action));
  }
}

sub getDeprecatedMsg {
  my ($cmd,$action)=@_;
  return "The !$cmd command is deprecated on this AutoHost, please $action";
}

sub processAliases {
  my ($user,$p_cmd)=@_;
  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  my @cmd=@{$p_cmd};
  my $lcCmd=lc($cmd[0]);
  if($conf{springieEmulation} ne "off") {
    if($lcCmd eq "admins") {
      return (["list","users"],getDeprecatedMsg($lcCmd,"use the unified command \"$C{3}!list users$C{1}\" instead"));
    }
    if($lcCmd eq "autolock") {
      if($#cmd == 0) {
        deprecatedMsg($user,$lcCmd,"use \"$C{3}!set autoLock off$C{1}\" to disable autolocking");
        return (["set","autoLock","off"],0);
      }
      if($cmd[1] =~ /^\d+$/) {
        if($conf{autoLock} eq "on" || $conf{autoSpecExtraPlayers}) {
          my $newTeamSize=ceil($cmd[1]/($conf{nbTeams}*$conf{nbPlayerById}));
          deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!set teamSize $newTeamSize$C{1}\" instead to set the wanted team size");
          return (["set","teamSize",$newTeamSize],0);
        }else{
          deprecatedMsg($user,$lcCmd,"use \"$C{3}!set autoLock on$C{1}\" to enable autolocking");
          return (["set","autoLock","on"],0);
        }
      }
    }
    if($lcCmd eq "cbalance") {
      if($conf{balanceMode} eq "clan;skill") {
        sayPrivate($user,"The $C{12}!$lcCmd$C{1} command is deprecated on this AutoHost. Balance mode is already set to \"$C{12}clan;skill$C{1}\": standard $C{3}!balance$C{1} command already manages clans") if($conf{springieEmulation} eq "warn");
        return (["balance"],0);
      }else{
        deprecatedMsg($user,$lcCmd,"adjust the balance mode to your needs using \"$C{3}!set balanceMode <mode>$C{1}\" command instead (refer to \"$C{3}!list settings$C{1}\" for allowed values)");
        return (["set","balanceMode","clan;skill"],0);
      }
    }
    if($lcCmd eq "corners") {
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!split c <size>$C{1}\" instead (refer to \"$C{3}!help split$C{1}\")");
      if($#cmd > 1 && $cmd[2] =~ /^\d+$/) {
        return (["split","c",$cmd[2]*2],0);
      }
    }
    if($lcCmd eq "exit") {
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!stop$C{1}\" instead");
      return (["stop"],0);
    }
    if($lcCmd eq "fix") {
      sayPrivate($user,"The $C{12}!$lcCmd$C{1} command is deprecated on this AutoHost. IDs are automatically fixed during balance, according to the nbPlayerById setting (refer to \"$C{3}!list settings$C{1}\")");
    }
    if($lcCmd eq "listbans") {
      return (["list","bans"],getDeprecatedMsg($lcCmd,"use the unified command \"$C{3}!list bans$C{1}\" instead"));
    }
    if($lcCmd eq "listmaps") {
      my @filters=@cmd;
      shift(@filters);
      return (["list","maps",@filters],getDeprecatedMsg($lcCmd,"use the unified command \"$C{3}!list maps$C{1}\" instead"));
    }
    if($lcCmd eq "listoptions") {
      return (["list","bSettings"],getDeprecatedMsg($lcCmd,"use the unified command \"$C{3}!list bSettings$C{1}\" instead"));
    }
    if($lcCmd eq "listpresets") {
      return (["list","presets"],getDeprecatedMsg($lcCmd,"use the unified command \"$C{3}!list presets$C{1}\" instead"));
    }
    if($lcCmd eq "manage") {
      deprecatedMsg($user,$lcCmd,"adjust the auto* settings to your needs, using $C{3}!set$C{1} command instead (refer to \"$C{3}!list settings$C{1}\" for allowed values");
    }
    if($lcCmd eq "presetdetails") {
      return (["list","settings"],getDeprecatedMsg($lcCmd,"use the unified command \"$C{3}!list settings$C{1}\" instead to list the current preset details"));
    }
    if($lcCmd eq "random") {
      if($conf{balanceMode} eq "random") {
        sayPrivate($user,"Balance mode is already set to \"$C{12}random$C{1}\": standard $C{3}!balance$C{1} command already performs random balance") if($conf{springieEmulation} eq "warn");
        return (["balance"],0);
      }else{
        deprecatedMsg($user,$lcCmd,"adjust the balance mode to your needs using \"$C{3}!set balanceMode <mode>$C{1}\" command instead (refer to \"$C{3}!list settings$C{1}\" for allowed values)");
        return (["set","balanceMode","random"],0);
      }
    }
    if($lcCmd eq "voteboss") {
      my @realCmd=("callVote","boss");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString [<player>]$C{1}\" instead");
      if($#cmd > 0) {
        return ([@realCmd,$cmd[1]],0);
      }else{
        return ([@realCmd],0);
      }
    }
    if($lcCmd eq "voteexit") {
      my @realCmd=("callVote","stop");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString$C{1}\" instead");
      return ([@realCmd],0);
    }
    if($lcCmd eq "voteforce" || $lcCmd eq "voteforcestart") {
      my @realCmd=("callVote","forceStart");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString$C{1}\" instead");
      return ([@realCmd],0);
    }
    if($lcCmd eq "votekick") {
      my @realCmd=("callVote","kick");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString <player>$C{1}\" instead");
      return ([@realCmd,$cmd[1]],0) if($#cmd > 0);
    }
    if($lcCmd eq "votekickspec") {
      my @realCmd=("callVote","set","maxSpecs","0");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString$C{1}\" instead");
      return ([@realCmd],0);
    }
    if($lcCmd eq "votemap") {
      my @realCmd=("callVote","map");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString <map>$C{1}\" instead");
      my @filters=@cmd;
      shift(@filters);
      return ([@realCmd,@filters],0);
    }
    if($lcCmd eq "votepreset") {
      my @realCmd=("callVote","preset");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString <preset>$C{1}\" instead");
      return ([@realCmd,$cmd[1]],0) if($#cmd > 0);
    }
    if($lcCmd eq "voterehost") {
      my @realCmd=("callVote","rehost");
      my $realCmdString=join(" ",@realCmd);
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!$realCmdString$C{1}\" instead");
      return ([@realCmd],0);
    }
    if($lcCmd eq "votesetoptions") {
      deprecatedMsg($user,$lcCmd,"use the unified command \"$C{3}!callVote bSet <setting> <value>$C{1}\" instead");
    }
  }

  if($conf{allowSettingsShortcut} && ! exists $spads->{commands}->{$lcCmd} && none {$lcCmd eq $_} @readOnlySettings) {
    if(any {$lcCmd eq $_} qw'users presets hpresets bpresets settings bsettings hsettings aliases bans maps pref rotationmaps plugins psettings') {
      unshift(@cmd,"list");
      return (\@cmd,0);
    }else{
      my @checkPrefResult=$spads->checkUserPref($lcCmd,'');
      if(! $checkPrefResult[0] && $lcCmd ne 'skillmode' && $lcCmd ne 'rankmode') {
        unshift(@cmd,"pSet");
        return (\@cmd,0);
      }elsif(any {$lcCmd eq lc($_)} (keys %{$spads->{values}})) {
        unshift(@cmd,"set");
        return (\@cmd,0);
      }elsif(any {$lcCmd eq lc($_)} (keys %{$spads->{hValues}})) {
        unshift(@cmd,"hSet");
        return (\@cmd,0);
      }else{
        my $modName=$targetMod;
        $modName=$lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod} if($lobbyState >= 6);
        my $p_modOptions=getModOptions($modName);
        my $p_mapOptions=getMapOptions($currentMap);
        if($lcCmd eq "startpostype" || exists $p_modOptions->{$lcCmd} || exists $p_mapOptions->{$lcCmd}) {
          unshift(@cmd,"bSet");
          return (\@cmd,0);
        }
      }
    }
  }

  my $p_cmdAliases=getCmdAliases();
  if(exists $p_cmdAliases->{$lcCmd}) {
    my $paramsReordered=0;
    my @newCmd;
    foreach my $token (@{$p_cmdAliases->{$lcCmd}}) {
      if($token =~ /^\%(\d)\%$/) {
        $paramsReordered=1;
        push(@newCmd,$cmd[$1] // '');
      }else{
        push(@newCmd,$token);
      }
    }
    if(! $paramsReordered) {
      for my $i (1..$#cmd) {
        push(@newCmd,$cmd[$i]);
      }
    }
    return (\@newCmd,0);
  }

  return (0,0);
}

sub getCmdAliases {
  my %cmdAliases=(b => ['vote','b'],
                  coop => ['pSet','shareId'],
                  cv => ['callVote'],
                  ev => ['endVote'],
                  h => ['help'],
                  map => ['set','map'],
                  n => ['vote','n'],
                  rc => ['reloadConf'],
                  rck => ['reloadConf','keepSettings'],
                  s => ['status'],
                  sb => ['status','battle'],
                  spec => ['force','%1%','spec'],
                  su => ['searchUser'],
                  us => ['unlockSpec'],
                  w => ['whois'],
                  y => ['vote','y']);
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->updateCmdAliases(\%cmdAliases) if($plugins{$pluginName}->can('updateCmdAliases'));
  }
  return \%cmdAliases;
}

sub handleRequest {
  my ($source,$user,$command,$floodCheck)=@_;
  $floodCheck//=1;
  
  return if($floodCheck && checkCmdFlood($user));
  
  my %answerFunctions = ( pv => sub { sayPrivate($user,$_[0]) },
                          battle => \&sayBattle,
                          chan => sub { sayChan($masterChannel,$_[0]) },
                          game => sub { sayGame($_[0]) ; sayBattle($_[0]) } );
  $p_answerFunction=$answerFunctions{$source};
  
  my @cmd=grep {$_ ne ''} (split(/ /,$command));
  
  my ($p_cmd,$warnMes)=processAliases($user,\@cmd);
  @cmd=@{$p_cmd} if($p_cmd);
  
  my $lcCmd=lc($cmd[0]);

  if($lcCmd eq '#skill' && $user eq $sldbLobbyBot) {
    executeCommand($source,$user,\@cmd);
    return;
  }

  if($lcCmd eq 'sendlobby') {
    @cmd=($1,$2) if($command =~ /^(\w+) +(.+)$/);
  }
  
  slog("Start of \"$lcCmd\" command processing",5);
  my $commandExists=0;
  $commandExists=1 if(exists $spads->{commands}->{$lcCmd});
  if(! $commandExists) {
    foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
      if(exists $spads->{pluginsConf}->{$pluginName}->{commands}->{$lcCmd}) {
        $commandExists=1;
        last;
      }
    }
  }
  if($commandExists) {
    
    if($lcCmd eq "endvote") {
      if(%currentVote && exists $currentVote{command}) {
        my $p_voteCmd=$currentVote{command};
        if($currentVote{user} eq $user || ($#{$p_voteCmd} > 0 && $p_voteCmd->[0] eq 'joinAs' && $p_voteCmd->[1] eq $user)) {
          executeCommand($source,$user,\@cmd);
          slog("End of \"$lcCmd\" command processing",5);
          return;
        }
      }else{
        answer("Unable to end vote, there is no vote in progress");
        slog("End of \"$lcCmd\" command processing",5);
        return;
      }
    }
    
    my $p_levels=getCommandLevels($source,$user,$lcCmd);
    
    if($lcCmd eq 'set' && $#cmd > 0 &&  defined $p_levels->{voteLevel} && $p_levels->{voteLevel} ne '') {

      my @freeSettingsEntries=split(/;/,$conf{freeSettings});
      my %freeSettings;
      foreach my $freeSettingEntry (@freeSettingsEntries) {
        if($freeSettingEntry =~ /^([^\(]+)\(([^\)]+)\)$/) {
          $freeSettings{lc($1)}=$2;
        }else{
          $freeSettings{lc($freeSettingEntry)}=undef;
        }
      }

      my $lcSetting=lc($cmd[1]);
      if(exists $freeSettings{$lcSetting}) {
        my $allowed=1;
        if(defined $freeSettings{$lcSetting}) {
          $allowed=0;
          my $value='';
          $value=$cmd[2] if($#cmd > 1);
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
        $p_levels->{directLevel}=$p_levels->{voteLevel} if($allowed);
      }
    }
    
    my $level=getUserAccessLevel($user);
    my $levelWithoutBoss=$level;
    
    if(%bosses && ! exists $bosses{$user}) {
      my $p_bossLevels=$spads->getCommandLevels("boss","battle","player","stopped");
      $level=0 if(exists $p_bossLevels->{directLevel} && $level < $p_bossLevels->{directLevel});
    }

    if(defined $p_levels->{directLevel} && $p_levels->{directLevel} ne "" && $level >= $p_levels->{directLevel}) {
      my @realCmd=@cmd;
      my $rewrittenCommand=executeCommand($source,$user,\@cmd);
      @realCmd=split(/ /,$rewrittenCommand) if(defined $rewrittenCommand && $rewrittenCommand && $rewrittenCommand ne '1');
      if(%currentVote && exists $currentVote{command} && $#{$currentVote{command}} == $#realCmd) {
        my $isSameCmd=1;
        for my $i (0..$#realCmd) {
          if(lc($realCmd[$i]) ne lc($currentVote{command}->[$i])) {
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
        executeCommand($source,$user,["callvote",@cmd]);
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

    if($warnMes && $conf{springieEmulation} eq "warn" && exists $lobby->{users}->{$user} && (! $lobby->{users}->{$user}->{status}->{inGame})) {
      sayPrivate($user,"********************");
      sayPrivate($user,$warnMes);
    }

  }else{
    answer("Invalid command \"$cmd[0]\"") unless($source eq "chan");
  }
  slog("End of \"$lcCmd\" command processing",5);
}

sub executeCommand {
  my ($source,$user,$p_cmd,$checkOnly)=@_;
  $checkOnly//=0;

  my %answerFunctions = ( pv => sub { sayPrivate($user,$_[0]) },
                          battle => \&sayBattle,
                          chan => sub { sayChan($masterChannel,$_[0]) },
                          game => sub { sayGame($_[0]) ; sayBattle($_[0]) } );
  $p_answerFunction=$answerFunctions{$source};

  my @cmd=@{$p_cmd};
  my $command=lc(shift(@cmd));

  if(exists $spadsHandlers{$command}) {
    my $commandAllowed=1;
    if(! $checkOnly) {
      foreach my $pluginName (@pluginsOrder) {
        $commandAllowed=$plugins{$pluginName}->preSpadsCommand($command,$source,$user,\@cmd) if($plugins{$pluginName}->can('preSpadsCommand'));
        last unless($commandAllowed);
      }
    }
    return 0 unless($commandAllowed);
    my $spadsCommandRes=&{$spadsHandlers{$command}}($source,$user,\@cmd,$checkOnly);
    if(! $checkOnly) {
      foreach my $pluginName (@pluginsOrder) {
        $plugins{$pluginName}->postSpadsCommand($command,$source,$user,\@cmd,$spadsCommandRes) if($plugins{$pluginName}->can('postSpadsCommand'));
      }
    }
    return $spadsCommandRes;
  }else{
    answer("Invalid command \"$command\"");
    return 0;
  }

}

sub invalidSyntax {
  my ($user,$cmd,$reason)=@_;
  $reason//='';
  $reason=" (".$reason.")" if($reason);
  if(exists $lobby->{users}->{$user}) {
    if($lobby->{users}->{$user}->{status}->{inGame}) {
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
  checkWinProcessStop();
  pluginsEventLoop();
  checkPendingGetSkills();
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
  if(%currentVote) {
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
            $currentVote{awayVoters}->{$remainingVoter}=1;
            delete $currentVote{remainingVoters}->{$remainingVoter};
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
      my $nbVotesForVotePart;
      if($currentVote{yesCount}>$currentVote{noCount}) {
        $nbVotesForVotePart=2*$currentVote{yesCount}-1;
      }elsif($currentVote{yesCount}<$currentVote{noCount}) {
        $nbVotesForVotePart=2*$currentVote{noCount}-1;
      }else{
        $nbVotesForVotePart=$currentVote{yesCount}+$currentVote{noCount};
      }
      my $votePart=($nbVotesForVotePart+$currentVote{blankCount}-$nbAwayVoters)/($totalNbVotes+$currentVote{blankCount});
      my $minVotePart=$conf{minVoteParticipation}/100;
      if($votePart >= $minVotePart && $currentVote{yesCount} > $totalNbVotes / 2) {
        sayBattleAndGame("Vote for command \"".join(" ",@{$currentVote{command}})."\" passed.");
        my ($voteSource,$voteUser,$voteCommand)=($currentVote{source},$currentVote{user},$currentVote{command});
        foreach my $pluginName (@pluginsOrder) {
          $plugins{$pluginName}->onVoteStop(1) if($plugins{$pluginName}->can('onVoteStop'));
        }
        %currentVote=();
        executeCommand($voteSource,$voteUser,$voteCommand);
      }elsif($votePart >= $minVotePart && ($currentVote{noCount} >= $totalNbVotes / 2 || ! $nbRemainingVotes)) {
        sayBattleAndGame("Vote for command \"".join(" ",@{$currentVote{command}})."\" failed.");
        foreach my $pluginName (@pluginsOrder) {
          $plugins{$pluginName}->onVoteStop(-1) if($plugins{$pluginName}->can('onVoteStop'));
        }
        delete @currentVote{(qw'awayVoteTime source command remainingVoters yesCount noCount blankCount awayVoters manualVoters')};
        $currentVote{expireTime}=time;
      }elsif(time >= $currentVote{expireTime}) {
        my @awayVoters;
        foreach my $remainingVoter (@remainingVoters) {
          my $autoSetVoteMode=getUserPref($remainingVoter,"autoSetVoteMode");
          if($autoSetVoteMode) {
            setUserPref($remainingVoter,"voteMode","away");
            push(@awayVoters,$remainingVoter);
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
        if($currentVote{yesCount} > $currentVote{noCount} && $currentVote{yesCount} > 1 && $votePart >= $minVotePart) {
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
          if($currentVote{remainingVoters}->{$remainingVoter}->{ringTime} && time >= $currentVote{remainingVoters}->{$remainingVoter}->{ringTime}) {
            $currentVote{remainingVoters}->{$remainingVoter}->{ringTime}=0;
            if(! exists $lastRungUsers{$remainingVoter} || time - $lastRungUsers{$remainingVoter} > getUserPref($remainingVoter,"minRingDelay")) {
              $lastRungUsers{$remainingVoter}=time;
              queueLobbyCommand(["RING",$remainingVoter]);
            }
          }
          if($currentVote{remainingVoters}->{$remainingVoter}->{notifyTime} && time >= $currentVote{remainingVoters}->{$remainingVoter}->{notifyTime}) {
            $currentVote{remainingVoters}->{$remainingVoter}->{notifyTime}=0;
            if(exists $lobby->{users}->{$remainingVoter} && (! $lobby->{users}->{$remainingVoter}->{status}->{inGame})) {
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
}

sub checkDataDump {
  if($conf{dataDumpDelay} && time - $timestamps{dataDump} > 60 * $conf{dataDumpDelay}) {
    pingIfNeeded();
    $spads->dumpDynamicData();
    $timestamps{dataDump}=time;
  }
}

sub checkAutoUpdate {
  if($conf{autoUpdateRelease} ne "" && $conf{autoUpdateDelay} && time - $timestamps{autoUpdate} > 60 * $conf{autoUpdateDelay}) {
    $timestamps{autoUpdate}=time;
    if($updater->isUpdateInProgress()) {
      slog('Skipping auto-update, another updater instance is already running',2);
    }else{
      my $childPid = fork();
      if(! defined $childPid) {
        slog("Unable to fork to launch SPADS updater",1);
      }elsif($childPid == 0) {
        $SIG{CHLD}="" unless($win);
        chdir($cwd);
        my $updateRc=$updater->update();
        if($updateRc < 0) {
          slog("Unable to check or apply SPADS update",2);
          exit $updateRc;
        }
        exit 0;
      }else{
        $updaterPid=$childPid;
      }
    }
  }
  if($conf{autoRestartForUpdate} ne "off" && (! $quitAfterGame) && (! $updater->isUpdateInProgress()) && time - $timestamps{autoRestartCheck} > 300) {
    autoRestartForUpdate();
  }
}

sub checkAutoForceStart {
  if($timestamps{autoForcePossible} > 0 && time - $timestamps{autoForcePossible} > 5 && $autohost->getState() == 1) {
    $timestamps{autoForcePossible}=-2;
    my $alreadyBroadcasted=0;
    if(%currentVote && exists $currentVote{command} && @{$currentVote{command}}) {
      my $command=lc($currentVote{command}->[0]);
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
  if($springPid && $autohost->getState() && $timestamps{autoStop} > 0 && time-$timestamps{autoStop} > 4) {
    $timestamps{autoStop}=-1;
    $autohost->sendChatMessage("/kill");
  }
}

sub checkAutoReloadArchives {
  if($conf{autoReloadArchivesMinDelay} && time - $timestamps{archivesCheck} > 60) {
    slog("Checking Spring archives for auto-reload",5);
    $timestamps{archivesCheck}=time;
    my $archivesChangeTs=getArchivesChangeTime();
    if($archivesChangeTs > $timestamps{archivesChange} && time - $archivesChangeTs > $conf{autoReloadArchivesMinDelay}) {
      my $archivesChangeDelay=secToTime(time - $archivesChangeTs);
      slog("Spring archives have been modified $archivesChangeDelay ago, auto-reloading archives...",3);
      my $nbArchives=loadArchives(1);
      quitAfterGame("Unable to auto-reload Spring archives") unless($nbArchives);
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
        delete $lastBattleMsg{$u}->{$t} if(time - $t > $msgAutoKickData[1]);
      }
      delete $lastBattleMsg{$u} unless(%{$lastBattleMsg{$u}});
    }
    foreach my $u (keys %lastBattleStatus) {
      foreach my $t (keys %{$lastBattleStatus{$u}}) {
        delete $lastBattleStatus{$u}->{$t} if(time - $t > $statusAutoKickData[1]);
      }
      delete $lastBattleStatus{$u} unless(%{$lastBattleStatus{$u}});
    }
    foreach my $u (keys %lastFloodKicks) {
      foreach my $t (keys %{$lastFloodKicks{$u}}) {
        delete $lastFloodKicks{$u}->{$t} if(time - $t > $autoBanData[1]);
      }
      delete $lastFloodKicks{$u} unless(%{$lastFloodKicks{$u}});
    }
    foreach my $u (keys %ignoredUsers) {
      delete $ignoredUsers{$u} if(time > $ignoredUsers{$u});
    }
  }
}

sub checkAdvertMsg {
  if($conf{advertDelay} && $conf{advertMsg} ne '' && $lobbyState > 5 && %{$lobby->{battle}}) {
    if(time - $timestamps{advert} > $conf{advertDelay} * 60) {
      my @battleUsers=keys %{$lobby->{battle}->{users}};
      if($#battleUsers > 0 && ! $autohost->getState()) {
        my @advertMsgs=@{$spads->{values}->{advertMsg}};
        foreach my $advertMsg (@advertMsgs) {
          sayBattle($advertMsg) if($advertMsg);
        }
      }
      $timestamps{advert}=time;
    }
  }
}

sub checkWinProcessStop {
  if($win) {
    my $childPid;
    while($childPid = waitpid(-1,WNOHANG)) {
      last if($childPid == -1);
      my $exitCode=$? >> 8;
      my $signalNb=$? & 127;
      my $hasCoreDump=$? & 128;
      handleSigChld($childPid,$exitCode,$signalNb,$hasCoreDump);
    }
    if($conf{useWin32Process} && defined $springWin32Process) {
      my $exitCode;
      $springWin32Process->GetExitCode($exitCode);
      if($exitCode != $STILL_ACTIVE) {
        $springWin32Process=undef;
        handleSigChld($springPid,$exitCode);
      }
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
      next if($lobbyState < 4 || ! exists $lobby->{accounts}->{$accountId});
      my $player=$lobby->{accounts}->{$accountId};
      next unless(exists $battleSkills{$player});
      my $skillPref=getUserPref($player,'skillMode');
      slog("Timeout for getSkill on player $player (account $accountId)",2) if($skillPref eq 'TrueSkill');
      my $previousPlayerSkill=$battleSkills{$player}->{skill};
      pluginsUpdateSkill($battleSkills{$player},$accountId);
      sendPlayerSkill($player);
      checkBattleBansForPlayer($player);
      $needRebalance=1 if($previousPlayerSkill != $battleSkills{$player}->{skill} && $lobbyState > 5 && %{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$player}
                          && defined $lobby->{battle}->{users}->{$player}->{battleStatus} && $lobby->{battle}->{users}->{$player}->{battleStatus}->{mode});
    }
  }
  if($needRebalance) {
    $balanceState=0;
    %balanceTarget=();
  }
}

sub autoRestartForUpdate {
  $timestamps{autoRestartCheck}=time;
  my $updateTimestamp=0;
  if(-f "$conf{binDir}/updateInfo.txt") {
    if(open(UPDATE_INFO,"<$conf{binDir}/updateInfo.txt")) {
      while(<UPDATE_INFO>) {
        if(/^(\d+)$/) {
          $updateTimestamp=$1 if($1 > $updateTimestamp);
        }
      }
      close(UPDATE_INFO);
    }else{
      slog("Unable to read \"$conf{binDir}/updateInfo.txt\" file",1);
    }
  }
  if($updateTimestamp > $timestamps{autoHostStart}) {
    if($conf{autoRestartForUpdate} eq "on") {
      restartAfterGame("auto-update");
    }elsif($conf{autoRestartForUpdate} eq "whenOnlySpec") {
      restartWhenOnlySpec("auto-update");
    }else{
      restartWhenEmpty("auto-update");
    }
  }
}

sub getVoteStateMsg {
  return (undef,undef,undef) unless(%currentVote && exists $currentVote{command});
  my ($lobbyMsg,$gameMsg,$additionalMsg);
  my @remainingVoters=keys %{$currentVote{remainingVoters}};
  my @awayVoters=keys %{$currentVote{awayVoters}};
  my $nbRemainingVotes=$#remainingVoters+1;
  my $nbAwayVoters=$#awayVoters+1;
  my $totalNbVotes=$nbRemainingVotes+$currentVote{yesCount}+$currentVote{noCount};
  my $reqYesVotes=int($totalNbVotes/2)+1;
  my $reqNoVotes=$totalNbVotes-$reqYesVotes+1;
  my $maxReqYesVotes=int(($totalNbVotes+$nbAwayVoters)/2)+1;
  my $maxReqNoVotes=$totalNbVotes+$nbAwayVoters-$maxReqYesVotes+1;
  my ($maxYesVotesString,$maxNoVotesString)=('','');
  $maxYesVotesString="($maxReqYesVotes)" if($reqYesVotes != $maxReqYesVotes);
  $maxNoVotesString="($maxReqNoVotes)" if($reqNoVotes != $maxReqNoVotes);
  my $remainingTime=$currentVote{expireTime} - time;
  my $nbVotesForVotePart;
  if($currentVote{yesCount}>$currentVote{noCount}) {
    $nbVotesForVotePart=2*$currentVote{yesCount}-1;
  }elsif($currentVote{yesCount}<$currentVote{noCount}) {
    $nbVotesForVotePart=2*$currentVote{noCount}-1;
  }else{
    $nbVotesForVotePart=$currentVote{yesCount}+$currentVote{noCount};
  }
  my $nbRequiredManualVotes=ceil($conf{minVoteParticipation} * ($totalNbVotes+$currentVote{blankCount}) / 100);
  if($nbVotesForVotePart < $nbRequiredManualVotes || (@remainingVoters && $currentVote{yesCount} < $reqYesVotes && $currentVote{noCount} < $reqNoVotes)) {
    my $nbManualVotes=$currentVote{yesCount}+$currentVote{noCount}+$currentVote{blankCount}-$nbAwayVoters;
    my $requiredVotesString='';
    $requiredVotesString=", votes:$nbManualVotes/$nbRequiredManualVotes" if($nbVotesForVotePart < $nbRequiredManualVotes && $nbRequiredManualVotes-$nbManualVotes > $reqYesVotes-$currentVote{yesCount});
    $lobbyMsg="Vote in progress: \"".join(" ",@{$currentVote{command}})."\" [y:$currentVote{yesCount}/$reqYesVotes$maxYesVotesString, n:$currentVote{noCount}/$reqNoVotes$maxNoVotesString$requiredVotesString] (${remainingTime}s remaining)";
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
  my %battleUsers=%{$lobby->{battle}->{users}};
  foreach my $user (keys %battleUsers) {
    $nbPlayers++ if(defined $battleUsers{$user}->{battleStatus} && $battleUsers{$user}->{battleStatus}->{mode});
  }

  my @allowedPresets=@{$spads->{values}->{preset}};
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
  $spads->{conf}->{nbTeams}=$presetsBs{$preset}->[0];
  $spads->{conf}->{teamSize}=$presetsBs{$preset}->[1];
  $spads->{conf}->{nbPlayerById}=$presetsBs{$preset}->[2];
  $timestamps{mapLearned}=0;
  $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  setDefaultMapOfMaplist() if($spads->{conf}->{map} eq '');
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
  my %battleUsers=%{$lobby->{battle}->{users}};
  foreach my $user (keys %battleUsers) {
    $nbPlayers++ if(defined $battleUsers{$user}->{battleStatus} && $battleUsers{$user}->{battleStatus}->{mode});
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
      if(exists $spads->{presets}->{$smfMapName}) {
        $mapPreset=$smfMapName;
      }elsif(exists $spads->{presets}->{"_DEFAULT_.smf"}) {
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
    slog("Unable to find any other allowed map compatible with current number of players ($nbPlayers), keeping current map",2);
    sayBattleAndGame("No other allowed map compatible with current number of player, map rotation cancelled") if($verbose);
    return;
  }

  if($rotationMode eq "random") {
    my $mapIndex=int(rand($#{$p_filteredMaps}+1));
    if($#{$p_filteredMaps} > 0) {
      while($conf{map} eq $p_filteredMaps->[$mapIndex]) {
        $mapIndex=int(rand($#{$p_filteredMaps}+1));
      }
    }
    $spads->{conf}->{map}=$p_filteredMaps->[$mapIndex];
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
    $spads->{conf}->{map}=$p_filteredMaps->[$nextMapIndex];
    %conf=%{$spads->{conf}};
    applySettingChange("map");
    sayBattleAndGame("Automatic map rotation: next map is \"$conf{map}\"") if($verbose);
  }
  if($conf{autoLoadMapPreset}) {
    my $smfMapName=$conf{map};
    $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
    my $mapPreset;
    if(exists $spads->{presets}->{$smfMapName}) {
      $mapPreset=$smfMapName;
    }elsif(exists $spads->{presets}->{"_DEFAULT_.smf"}) {
      $mapPreset="_DEFAULT_.smf";
    }
    if(defined $mapPreset) {
      my $oldPreset=$conf{preset};
      $spads->applyPreset($mapPreset);
      $spads->{conf}->{nbTeams}=$mapsBs{$mapPreset}->[0];
      $spads->{conf}->{teamSize}=$mapsBs{$mapPreset}->[1];
      $spads->{conf}->{nbPlayerById}=$mapsBs{$mapPreset}->[2];
      $timestamps{mapLearned}=0;
      $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
      setDefaultMapOfMaplist() if($spads->{conf}->{map} eq '');
      %conf=%{$spads->{conf}};
      applyAllSettings();
      updateTargetMod();
      pluginsOnPresetApplied($oldPreset,$mapPreset);
    }
  }
}

sub setAsOutOfGame {
  %springPrematureEndData=();
  if($lobbyState > 3) {
    my %clientStatus = %{$lobby->{users}->{$conf{lobbyLogin}}->{status}};
    $clientStatus{inGame}=0;
    queueLobbyCommand(["MYSTATUS",$lobby->marshallClientStatus(\%clientStatus)]);
    queueLobbyCommand(["GETINGAMETIME"]);
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
  if($lobbyState > 5) {
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
    sayPrivate($notifiedUser,"***** End-game notification *****") if($lobbyState > 3 && exists $lobby->{users}->{$notifiedUser});
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
    return 0 unless(defined $p_players->{$player}->{battleStatus});
    delete($p_players->{$player}) unless($p_players->{$player}->{battleStatus}->{mode});
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
    return 0 unless($p_players->{$player}->{battleStatus}->{team} == $p_balancedPlayers->{$player}->{battleStatus}->{team});
    return 0 unless($p_players->{$player}->{battleStatus}->{id} == $p_balancedPlayers->{$player}->{battleStatus}->{id});
  }

  foreach my $bot (@bots) {
    return 0 unless(exists $p_balancedBots->{$bot});
    return 0 unless($p_bots->{$bot}->{battleStatus}->{team} == $p_balancedBots->{$bot}->{battleStatus}->{team});
    return 0 unless($p_bots->{$bot}->{battleStatus}->{id} == $p_balancedBots->{$bot}->{battleStatus}->{id});
  }

  return 1;
}

sub areColorsApplied {
  my $p_battle=$lobby->getBattle();

  my $p_players=$p_battle->{users};
  my $p_bots=$p_battle->{bots};

  foreach my $player (keys %{$p_players}) {
    return 0 unless(defined $p_players->{$player}->{battleStatus});
    next unless($p_players->{$player}->{battleStatus}->{mode});
    my $colorId=$conf{idShareMode} eq "off" ? $player : $p_players->{$player}->{battleStatus}->{id};
    return 0 unless exists($colorsTarget{$colorId});
    return 0 unless(colorDistance($colorsTarget{$colorId},$p_players->{$player}->{color}) == 0);
  }
  foreach my $bot (keys %{$p_bots}) {
    my $colorId=$conf{idShareMode} eq "off" ? $bot.' (bot)' : $p_bots->{$bot}->{battleStatus}->{id};
    return 0 unless exists($colorsTarget{$colorId});
    return 0 unless(colorDistance($colorsTarget{$colorId},$p_bots->{$bot}->{color}) == 0);
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
    if($p_players->{$player}->{battleStatus}->{team} != $p_balancedPlayers->{$player}->{battleStatus}->{team}) {
      $newBalanceState=0;
      queueLobbyCommand(["FORCEALLYNO",$player,$p_balancedPlayers->{$player}->{battleStatus}->{team}]);
    }
    if($p_players->{$player}->{battleStatus}->{id} != $p_balancedPlayers->{$player}->{battleStatus}->{id}) {
      $newBalanceState=0;
      queueLobbyCommand(["FORCETEAMNO",$player,$p_balancedPlayers->{$player}->{battleStatus}->{id}]);
    }
  }

  foreach my $bot (keys %{$p_balancedBots}) {
    my $updateNeeded=0;
    if($p_bots->{$bot}->{battleStatus}->{team} != $p_balancedBots->{$bot}->{battleStatus}->{team}) {
      $updateNeeded=1;
      $newBalanceState=0;
      $p_bots->{$bot}->{battleStatus}->{team}=$p_balancedBots->{$bot}->{battleStatus}->{team};
    }
    if($p_bots->{$bot}->{battleStatus}->{id} != $p_balancedBots->{$bot}->{battleStatus}->{id}) {
      $updateNeeded=1;
      $newBalanceState=0;
      $p_bots->{$bot}->{battleStatus}->{id} = $p_balancedBots->{$bot}->{battleStatus}->{id};
    }
    queueLobbyCommand(["UPDATEBOT",$bot,$lobby->marshallBattleStatus($p_bots->{$bot}->{battleStatus}),$lobby->marshallColor($p_bots->{$bot}->{color})]) if($updateNeeded);
  }
  
  $timestamps{balance}=time unless($newBalanceState);
  $balanceState=$newBalanceState;

}

sub applyColorsTarget {
  my $p_battle=$lobby->getBattle();

  my $p_players=$p_battle->{users};
  my $p_bots=$p_battle->{bots};

  my $newColorsState=1;
  foreach my $player (keys %{$p_players}) {
    if(! defined $p_players->{$player}->{battleStatus}) {
      $newColorsState=0;
      next;
    }
    next unless($p_players->{$player}->{battleStatus}->{mode});
    my $colorId=$conf{idShareMode} eq "off" ? $player : $p_players->{$player}->{battleStatus}->{id};
    if(colorDistance($colorsTarget{$colorId},$p_players->{$player}->{color}) != 0) {
      $newColorsState=0;
      queueLobbyCommand(["FORCETEAMCOLOR",$player,$lobby->marshallColor($colorsTarget{$colorId})]);
    }
  }
  foreach my $bot (keys %{$p_bots}) {
    my $colorId=$conf{idShareMode} eq "off" ? $bot.' (bot)' : $p_bots->{$bot}->{battleStatus}->{id};
    if(colorDistance($colorsTarget{$colorId},$p_bots->{$bot}->{color}) != 0) {
      $newColorsState=0;
      queueLobbyCommand(["UPDATEBOT",
                         $bot,
                         $lobby->marshallBattleStatus($p_bots->{$bot}->{battleStatus}),
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
      $maxId=$p_players->{$p}->{battleStatus}->{id} if($p_players->{$p}->{battleStatus}->{id} > $maxId);
    }
    foreach my $b (keys %{$p_bots}) {
      $p_bots->{$b}->{battleStatus}->{team}=1;
      $p_bots->{$b}->{battleStatus}->{id}=++$maxId % 16;
    }
    slog("Too many IDs for chicken-mode balancing",2) if($maxId > 15 && $conf{idShareMode} ne "off");
  }elsif($conf{balanceMode} eq 'clan;skill' && $conf{clanMode} =~ /\(\d+\)/) {
    slog("Balance mode is set to \"clan;skill\" and clan mode \"$conf{clanMode}\" contains unbalance threshold(s)",5);
    my @currentClanModes;
    my $clanModesString='';
    my @remainingClanModes=split(';',$conf{clanMode});
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
          slog("Current unbalance for clan mode \"$clanModesString\" is $unbalanceIndicator\% (wasn't processed yet)",5);
        }
        my $p_testBattle=$lobby->getBattle();
        my $p_testPlayers=$p_testBattle->{users};
        my $p_testBots=$p_testBattle->{bots};
        $clanModesString=join(";",@currentClanModes,$mode);
        my (undef,$testUnbalance)=balanceBattle($p_testPlayers,$p_testBots,$clanModesString);
        if($testUnbalance - $unbalanceIndicator <= $maxUnbalance) {
          slog("Unbalance for clan mode \"$clanModesString\" is $testUnbalance\% ($testUnbalance-$unbalanceIndicator<=$maxUnbalance) => clan mode accepted",5);
          ($unbalanceIndicator,$p_players,$p_bots)=($testUnbalance,$p_testPlayers,$p_testBots);
          push(@currentClanModes,$mode);
        }else{
          slog("Unbalance for clan mode \"$clanModesString\" is $testUnbalance\% ($testUnbalance-$unbalanceIndicator>$maxUnbalance) => clan mode rejected",5);
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
  my $p_battle=$lobby->getBattle();

  my $p_players=$p_battle->{users};
  my $p_bots=$p_battle->{bots};

  my $p_colorsTarget=getFixedColorsOf($p_players,$p_bots);
  %colorsTarget=%{$p_colorsTarget};
  applyColorsTarget();
}

sub getUserIps {
  my $user=shift;
  my $accountId=getLatestUserAccountId($user);
  return $spads->getAccountIps($accountId) if($accountId ne '');
  return [];
}

sub getLatestUserIp {
  my $user=shift;
  return $lobby->{users}->{$user}->{ip} if($lobbyState > 3 && exists $lobby->{users}->{$user} && defined $lobby->{users}->{$user}->{ip});
  if($lobbyState > 5 && %{$lobby->{battle}}) {
    return $lobby->{battle}->{users}->{$user}->{ip} if(exists $lobby->{battle}->{users}->{$user} && defined $lobby->{battle}->{users}->{$user}->{ip});
  }
  my $accountId=getLatestUserAccountId($user);
  return $spads->getLatestAccountIp($accountId) if($accountId ne '');
  return '';
}

sub getLatestUserAccountId {
  my $user=shift;
  return '' if($lanMode);
  if(exists $lobby->{users}->{$user}) {
    my $id=$lobby->{users}->{$user}->{accountId};
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
                                        && $battleSkills{$player}->{skillOrigin} ne 'TrueSkill'
                                        && $battleSkills{$player}->{skillOrigin} ne 'Plugin');
  $playerSkill=$battleSkills{$player}->{skill};
  $playerSigma=$battleSkills{$player}->{sigma} if(exists $battleSkills{$player}->{sigma} && defined $battleSkills{$player}->{sigma});
  if($battleSkills{$player}->{skillOrigin} eq 'TrueSkill') {
    my $gameType=getGameTypeForBanCheck();
    ($playerSkill,$playerSigma)=($battleSkillsCache{$player}->{$gameType}->{skill},$battleSkillsCache{$player}->{$gameType}->{sigma});
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
  my $nbPlayerById=$conf{nbPlayerById};
  $nbPlayerById=1 if($conf{idShareMode} ne 'auto');
  $nbTeams=16 if($nbTeams > 16);
  $nbTeams=1 if($nbTeams < 1);
  $teamSize=16 if($teamSize > 16);
  $teamSize=1 if($teamSize < 1);
  $nbPlayerById=1 if($nbPlayerById < 1);

  my $minTeamSize=$conf{minTeamSize};
  $minTeamSize=$teamSize if($minTeamSize > $teamSize || $minTeamSize == 0);

  if($teamSize*$nbTeams > 16) {
    $teamSize=int(16/$nbTeams);
    $teamSize=$minTeamSize if($teamSize < $minTeamSize);
  }

  if($nbPlayers <= $nbTeams*$teamSize) {
    $nbTeams=ceil($nbPlayers/$minTeamSize) if($nbPlayers < $nbTeams*$minTeamSize);
    $teamSize=ceil($nbPlayers/$nbTeams);
  }elsif($nbPlayers > $nbTeams*$teamSize*$nbPlayerById) {
    $teamSize=ceil($nbPlayers/($nbTeams*$nbPlayerById));
    $teamSize=int(16/$nbTeams) if($teamSize*$nbTeams > 16);
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
    delete($p_players->{$player}) if(! (defined $p_players->{$player}->{battleStatus}) || $p_players->{$player}->{battleStatus}->{mode} == 0);
  }

  my $nbPlayers=0;
  $nbPlayers+=(keys %{$p_players});
  $nbPlayers+=(keys %{$p_bots});
  return (0,0) unless($nbPlayers);

  my ($nbTeams,$teamSize)=getTargetBattleStructure($nbPlayers);

  my $nbSmurfs=0;
  my $restoreRandSeed=intRand();
  srand($balRandSeed);
  foreach my $player (keys %{$p_players}) {
    if($conf{balanceMode} =~ /skill$/) {
      if(exists $battleSkills{$player}) {
        $p_players->{$player}->{skill}=$battleSkills{$player}->{skill};
        $p_players->{$player}->{sigma}=$battleSkills{$player}->{sigma} if(exists $battleSkills{$player}->{sigma});
        $nbSmurfs++ if($battleSkills{$player}->{rank} > $lobby->{users}->{$player}->{status}->{rank});
      }else{
        slog("Undefined skill for player $player, using direct lobbyRank/skill mapping as a workaround for balancing!",1);
        $p_players->{$player}->{skill}=$rankSkill{$lobby->{users}->{$player}->{status}->{rank}};
      }
    }else{
      $p_players->{$player}->{skill}=int(rand(39));
    }
  }
  foreach my $bot (keys %{$p_bots}) {
    if($conf{balanceMode} =~ /skill$/) {
      $p_bots->{$bot}->{skill}=$rankSkill{$conf{botsRank}};
    }else{
      $p_bots->{$bot}->{skill}=int(rand(39));
    }
  }

  my $unbalanceIndicator;
  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('balanceBattle')) {
      $unbalanceIndicator=$plugins{$pluginName}->balanceBattle($p_players,$p_bots,$clanMode,$nbTeams,$teamSize);
      next unless(defined $unbalanceIndicator && $unbalanceIndicator >= 0);
      srand($restoreRandSeed);
      return ($nbSmurfs,$unbalanceIndicator);
    }
  }

  my $p_teams=createGroups(int($nbPlayers/$nbTeams),$nbTeams,$nbPlayers % $nbTeams);
  my @ids;
  if($conf{idShareMode} eq 'auto' || $conf{idShareMode} eq 'off') {
    for my $teamNb (0..$#{$p_teams}) {
      if($p_teams->[$teamNb]->{freeSlots} < $teamSize) {
        $ids[$teamNb]=createGroups(1,$p_teams->[$teamNb]->{freeSlots},0);
      }else{
        $ids[$teamNb]=createGroups(int($p_teams->[$teamNb]->{freeSlots}/$teamSize),$teamSize,$p_teams->[$teamNb]->{freeSlots} % $teamSize);
      }
    }
  }
  $unbalanceIndicator=balanceGroups($p_players,$p_bots,$p_teams,$clanMode);
  my $idNb=0;
  for my $teamNb (0..($#{$p_teams})) {
    my %manualSharedIds;
    if($conf{idShareMode} eq 'auto' || $conf{idShareMode} eq 'off') {
      balanceGroups($p_teams->[$teamNb]->{players},$p_teams->[$teamNb]->{bots},$ids[$teamNb],$clanMode);
    }
    my $p_sortedPlayers=randomRevSort(sub {return $_[0]->{skill}},$p_teams->[$teamNb]->{players});
    foreach my $player (@{$p_sortedPlayers}) {
      $p_players->{$player}->{battleStatus}->{team}=$teamNb;
      if($conf{idShareMode} eq 'all') {
        $p_players->{$player}->{battleStatus}->{id}=$teamNb;
      }elsif($conf{idShareMode} ne 'auto' && $conf{idShareMode} ne 'off') {
        my $userShareId=getUserPref($player,'shareId');
        if($userShareId eq '' && $conf{idShareMode} eq 'clan' && $player =~ /^\[([^\]]+)\]/) {
          $userShareId=$1;
        }
        if($userShareId ne '') {
          $manualSharedIds{$userShareId}=$idNb++ % 16 unless(exists $manualSharedIds{$userShareId});
          $p_players->{$player}->{battleStatus}->{id}=$manualSharedIds{$userShareId};
        }else{
          $p_players->{$player}->{battleStatus}->{id}=$idNb++ % 16;
        }
      }
    }
    foreach my $bot (keys %{$p_teams->[$teamNb]->{bots}}) {
      $p_bots->{$bot}->{battleStatus}->{team}=$teamNb;
      if($conf{idShareMode} eq 'all') {
        $p_bots->{$bot}->{battleStatus}->{id}=$teamNb;
      }elsif($conf{idShareMode} ne 'auto' && $conf{idShareMode} ne 'off') {
        $p_bots->{$bot}->{battleStatus}->{id}=$idNb++ % 16;
      }
    }
    if($conf{idShareMode} eq 'auto' || $conf{idShareMode} eq 'off') {
      for my $subIdNb (0..($#{$ids[$teamNb]})) {
        foreach my $player (keys %{$ids[$teamNb]->[$subIdNb]->{players}}) {
          $p_players->{$player}->{battleStatus}->{id}=$idNb % 16;
        }
        foreach my $bot (keys %{$ids[$teamNb]->[$subIdNb]->{bots}}) {
          $p_bots->{$bot}->{battleStatus}->{id}=$idNb % 16;
        }
        $idNb++;
      }
    }
  }
  
  slog("Too many IDs required ($idNb) to balance current battle [nbPlayers=$nbPlayers,nbTeams=$conf{nbTeams},teamSize=$conf{teamSize},nbPlayerById=$conf{nbPlayerById},idShareMode=$conf{idShareMode}]",2) if($idNb > 16);

  srand($restoreRandSeed);
  return ($nbSmurfs,$unbalanceIndicator);
}

sub balanceGroups {
  my ($p_players,$p_bots,$p_groups,$clanMode)=@_;
  my $totalSkill=0;
  my @players=keys %{$p_players};
  foreach my $player (@players) {
    $totalSkill+=$p_players->{$player}->{skill};
  }
  my @bots=keys %{$p_bots};
  foreach my $bot (@bots) {
    $totalSkill+=$p_bots->{$bot}->{skill};
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
      $squareDeviations+=($p_groups->[$groupNb]->{skill}-$avgGroupSkill)**2;
      slog("Skill of group $groupNb is $p_groups->[$groupNb]->{skill} => squareDeviations=$squareDeviations",5);
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
    $clanGroup=$groupNb if($groups[$groupNb]->{freeSlots} > $groups[$clanGroup]->{freeSlots});
  }
  return $clanGroup unless(defined $clanSize);
  for my $groupNb (0..$#groups) {
    if($groups[$groupNb]->{skill} < $groups[$clanGroup]->{skill}
       && ($groups[$groupNb]->{freeSlots} >= $clanSize || $groups[$groupNb]->{freeSlots} == $groups[$clanGroup]->{freeSlots})) {
      $clanGroup=$groupNb;
    }elsif($groups[$groupNb]->{skill} == $groups[$clanGroup]->{skill}
           && $groups[$groupNb]->{freeSlots} >= $clanSize
           && $groups[$groupNb]->{freeSlots} < $groups[$clanGroup]->{freeSlots}) {
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
  $p_groups->[$groupNb]->{freeSlots}--;
  $p_groups->[$groupNb]->{skill}+=$p_players->{$player}->{skill};
  $p_groups->[$groupNb]->{players}->{$player}=$p_players->{$player};
}

sub assignBot {
  my ($bot,$groupNb,$p_bots,$p_groups)=@_;
  $p_groups->[$groupNb]->{freeSlots}--;
  $p_groups->[$groupNb]->{skill}+=$p_bots->{$bot}->{skill};
  $p_groups->[$groupNb]->{bots}->{$bot}=$p_bots->{$bot};
}

sub randomRevSort {
  my ($p_evalFunc,$p_items)=@_;
  my @sortedItems;
  
  my %itemGroups;
  foreach my $item (keys %{$p_items}) {
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
        $clanSkill+=$p_players->{$clanPlayer}->{skill};
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
    my $groupSpace=$p_groups->[$groupNb]->{freeSlots};
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
    if($groups[$groupNb]->{freeSlots} > 0) {
      $maxAvgMissingSkill=($avgGroupSkill-$groups[$groupNb]->{skill})/$groups[$groupNb]->{freeSlots};
      $playerGroup=$groupNb;
      last;
    }
  }
  for my $groupNb (1..$#groups) {
    if($groups[$groupNb]->{freeSlots} > 0) {
      my $groupAvgMissingSkil=($avgGroupSkill-$groups[$groupNb]->{skill})/$groups[$groupNb]->{freeSlots};
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

  my $p_sortedPlayers=randomRevSort(sub {return $_[0]->{skill}},$p_players);
  my $p_sortedBots=randomRevSort(sub {return $_[0]->{skill}},$p_bots);
  my @sortedPlayers=@{$p_sortedPlayers};
  my @sortedBots=@{$p_sortedBots};
  while(@sortedPlayers || @sortedBots) {
    my $groupNb=getNextPlayerGroup($p_groups,$avgGroupSkill);
    my ($playerSkill,$botSkill);
    $playerSkill=$p_players->{$sortedPlayers[0]}->{skill} if(@sortedPlayers);
    $botSkill=$p_bots->{$sortedBots[0]}->{skill} if(@sortedBots);
    if(defined $playerSkill && (! defined $botSkill || $playerSkill > $botSkill)) {
      my $player=shift(@sortedPlayers);
      assignPlayer($player,$groupNb,$p_players,$p_groups);
    }else{
      my $bot=shift(@sortedBots);
      assignBot($bot,$groupNb,$p_bots,$p_groups);
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
    return $p_color if($conf{colorSensitivity} && $minDistance > $conf{colorSensitivity}*1000);
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
      return $p_color if($conf{colorSensitivity} && $minDistance > $conf{colorSensitivity}*1000);
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

sub getFixedColorsOf {
  my ($p_players,$p_bots)=@_;

  my %idColors;
  if($conf{colorSensitivity}) {
    for my $player (keys %{$p_players}) {
      next unless(defined $p_players->{$player}->{battleStatus});
      next unless($p_players->{$player}->{battleStatus}->{mode});
      my $colorId=$conf{idShareMode} eq "off" ? $player : $p_players->{$player}->{battleStatus}->{id};
      if(! exists $idColors{$colorId}) {
        if(minDistance($p_players->{$player}->{color},\%idColors) > $conf{colorSensitivity}*1000 && colorDistance($p_players->{$player}->{color},{red => 255, blue => 255, green => 255}) > 7000) {
          $idColors{$colorId}=$p_players->{$player}->{color};
        }
      }
    }
    for my $bot (keys %{$p_bots}) {
      my $colorId=$conf{idShareMode} eq "off" ? $bot.' (bot)' : $p_bots->{$bot}->{battleStatus}->{id};
      if(! exists $idColors{$colorId}) {
        if(minDistance($p_bots->{$bot}->{color},\%idColors) > $conf{colorSensitivity}*1000 && colorDistance($p_bots->{$bot}->{color},{red => 255, blue => 255, green => 255}) > 7000) {
          $idColors{$colorId}=$p_bots->{$bot}->{color};
        }
      }
    }
  }

  for my $player (keys %{$p_players}) {
    next unless(defined $p_players->{$player}->{battleStatus});
    next unless($p_players->{$player}->{battleStatus}->{mode});
    my $colorId=$conf{idShareMode} eq "off" ? $player : $p_players->{$player}->{battleStatus}->{id};
    $idColors{$colorId}=nextColor(\%idColors) unless(exists $idColors{$colorId});
  }
  for my $bot (keys %{$p_bots}) {
    my $colorId=$conf{idShareMode} eq "off" ? $bot.' (bot)' : $p_bots->{$bot}->{battleStatus}->{id};
    $idColors{$colorId}=nextColor(\%idColors) unless(exists $idColors{$colorId});
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
  my %ids; # used only when idShareMode is not set to off
  my $nbIds; #  to determine the number of required start pos on map when startPosType != 2
  my $p_bUsers=$lobby->{battle}->{users};
  my @bUsers=keys %{$p_bUsers};
  return { battleState => -4 } if($#bUsers > 250);

  foreach my $bUser (@bUsers) {
    if(! defined $p_bUsers->{$bUser}->{battleStatus}) {
      push(@unsyncedPlayers,$bUser);
    }elsif($p_bUsers->{$bUser}->{battleStatus}->{mode}) {
      if($p_bUsers->{$bUser}->{battleStatus}->{sync} != 1) {
        push(@unsyncedPlayers,$bUser);
      }elsif($lobby->{users}->{$bUser}->{status}->{inGame}) {
        push(@inGamePlayers,$bUser);
      }else{
        $nbPlayers++;
        push(@unreadyPlayers,$bUser) unless($p_bUsers->{$bUser}->{battleStatus}->{ready});
        $ids{$p_bUsers->{$bUser}->{battleStatus}->{id}}=1;
        if($conf{idShareMode} eq "auto") {
          $teams{$p_bUsers->{$bUser}->{battleStatus}->{id}}=$p_bUsers->{$bUser}->{battleStatus}->{team};
        }else{
          $teamCount{$p_bUsers->{$bUser}->{battleStatus}->{team}}=0 unless(exists $teamCount{$p_bUsers->{$bUser}->{battleStatus}->{team}});
          $teamCount{$p_bUsers->{$bUser}->{battleStatus}->{team}}++;
        }
      }
    }
  }

  return { battleState => -3, unsyncedPlayers => \@unsyncedPlayers } if(@unsyncedPlayers);
  return { battleState => -2, inGamePlayers => \@inGamePlayers } if(@inGamePlayers);
  return { battleState => -1, unreadyPlayers => \@unreadyPlayers } if(@unreadyPlayers);

  my $p_bBots=$lobby->{battle}->{bots};
  foreach my $bBot (keys %{$p_bBots}) {
    $nbPlayers++;
    $ids{$p_bBots->{$bBot}->{battleStatus}->{id}}=1;
    if($conf{idShareMode} eq "auto") {
      $teams{$p_bBots->{$bBot}->{battleStatus}->{id}}=$p_bBots->{$bBot}->{battleStatus}->{team};
    }else{
      $teamCount{$p_bBots->{$bBot}->{battleStatus}->{team}}=0 unless(exists $teamCount{$p_bBots->{$bBot}->{battleStatus}->{team}});
      $teamCount{$p_bBots->{$bBot}->{battleStatus}->{team}}++;
    }
  }

  if($conf{idShareMode} eq "auto") {
    foreach my $id (keys %teams) {
      $teamCount{$teams{$id}}=0 unless(exists $teamCount{$teams{$id}});
      $teamCount{$teams{$id}}++;
    }
  }

  if($conf{idShareMode} eq 'off') {
    $nbIds=$nbPlayers;
  }else{
    $nbIds=keys %ids;
  }

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

  return { battleState => 0,
           nbIds => $nbIds,
           warning => join(" and ",@warnings) } if(@warnings);

  return { battleState => 1,
           nbIds => $nbIds };
}

sub launchGame {
  my ($force,$checkOnly,$automatic,$checkBypassLevel)=@_;
  $checkBypassLevel//=0;

  my $p_battleState = getBattleState();

  if($p_battleState->{battleState} < -$checkBypassLevel) {
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

  my %additionalData=('game/AutohostPort' => $conf{autoHostPort},
                      'playerData' => {});
  $additionalData{'game/HostIP'}=$conf{forceHostIp};
  foreach my $bUser (keys %{$lobby->{battle}->{users}}) {
    next unless(exists $battleSkills{$bUser} && exists $battleSkills{$bUser}->{class}
                && exists $lobby->{users}->{$bUser} && exists $lobby->{users}->{$bUser}->{accountId} && $lobby->{users}->{$bUser}->{accountId});
    $additionalData{playerData}->{$lobby->{users}->{$bUser}->{accountId}}={skillclass => $battleSkills{$bUser}->{class}};
  }

  my $mapAvailableLocally=0;
  for my $mapNb (0..$#availableMaps) {
    if($availableMaps[$mapNb]->{name} eq $currentMap) {
      $mapAvailableLocally=1;
      last;
    }
  }

  if($spads->{bSettings}->{startpostype} == 2) {
    if(! $force && ! %{$lobby->{battle}->{startRects}}) {
      answer("Unable to start game, start position type is set to \"Choose in game\" but no start box is set - use !forceStart to bypass") unless($automatic);
      return 0;
    }
  }else{
    if(! $mapAvailableLocally) {
      answer("Unable to start game, start position type must be set to \"Choose in game\" when using a map unavailable on server (\"!bSet startPosType 2\")") unless($automatic);
      return 0;
    }
    if($p_battleState->{nbIds} > $spads->getCachedMapInfo($currentMap)->{nbStartPos}) {
      my $currentStartPosType=$spads->{bSettings}->{startpostype} ? 'random' : 'fixed';
      answer("Unable to start game, not enough start positions on map for $currentStartPosType start position type") unless($automatic);
      return 0;
    }
  }

  if((! $force) && $conf{autoBalance} ne 'off' && ! $balanceState) {
    answer("Unable to start game, autoBalance is enabled but battle hasn't been balanced yet - use !forceStart to bypass");
    return 0;
  }

  if((! $force) && $conf{autoFixColors} ne 'off' && ! $colorsState) {
    answer("Unable to start game, autoFixColors is enabled but colors haven't been fixed yet - use !forceStart to bypass");
    return 0;
  }

  return 1 if($checkOnly);

  if(! $mapAvailableLocally) {
    $additionalData{"game/MapHash"}=$spads->getMapHash($currentMap,$syncedSpringVersion);
    $additionalData{"game/MapHash"}+=$MAX_UNSIGNEDINTEGER if($additionalData{"game/MapHash"} < 0);
  }

  if($conf{autoSaveBoxes}) {
    my $p_startRects=$lobby->{battle}->{startRects};
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

  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->addStartScriptTags(\%additionalData) if($plugins{$pluginName}->can('addStartScriptTags'));
  }
  my $p_modSides=getModSides($lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod});
  my ($p_startData,$p_teamsMap,$p_allyTeamsMap)=$lobby->generateStartData(\%additionalData,$p_modSides,undef,$springServerType eq 'dedicated' ? 1 : 2,$conf{idShareMode} eq 'off');
  if(! $p_startData) {
    slog("Unable to start game: start script generation failed",1);
    closeBattleAfterGame("Unable to start game (start script generation failed)");
    return 0;
  }
  my %reversedTeamsMap=reverse %{$p_teamsMap};
  my %reversedAllyTeamsMap=reverse %{$p_allyTeamsMap};
  open(SCRIPT,">$conf{varDir}/startscript.txt");
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
  if($lobbyState > 3 && exists $lobby->{users}->{$gdrLobbyBot}) {
    $gdrEnabled=1;
  }else{
    $gdrEnabled=0;
  }

  my $configString='';
  if($conf{springConfig} ne '') {
    $configString="--config \"$conf{springConfig}\"";
  }

  if($conf{useWin32Process}) {
    my $rc=Win32::Process::Create($springWin32Process,
                                  $conf{springServer},
                                  "Spring-$springServerType \"$conf{varDir}\\startscript.txt\" $configString>>\"$conf{logDir}\\spring-$springServerType.log\" 2>\&1",
                                  0,
                                  $NORMAL_PRIORITY_CLASS,
                                  $conf{springDataDir});
    if(! $rc) {
      $springWin32Process=undef;
      slog("Unable to create Win32 process to launch Spring (".Win32::FormatMessage(Win32::GetLastError()).")",1);
      return;
    }
    $springPid=$springWin32Process->GetProcessID();
  }else{
    my $childPid = fork();
    if(! defined $childPid) {
      slog("Unable to fork to launch Spring",1);
      return;
    }
    
    if($childPid == 0) {
      $SIG{CHLD}="" unless($win);
      $ENV{SPRING_DATADIR}=$conf{springDataDir};
      $ENV{SPRING_WRITEDIR}=$conf{varDir};
      if($win) {
        chdir($conf{springDataDir});
        exec("\"$conf{springServer}\" \"$conf{varDir}/startscript.txt\" $configString>>\"$conf{logDir}/spring-$springServerType.log\" 2>\&1") || forkedError("Unable to launch Spring",1);
      }else{
        chdir($conf{varDir});
        if($conf{springConfig} ne '') {
          exec($conf{springServer},"$conf{varDir}/startscript.txt",'--config',$conf{springConfig}) || forkedError("Unable to launch Spring",1);
        }else{
          exec($conf{springServer},"$conf{varDir}/startscript.txt") || forkedError("Unable to launch Spring",1);
        }
      }
    }else{
      $springPid=$childPid;
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
  %runningBattleReversedMapping=(teams => \%reversedTeamsMap,
                                 allyTeams => \%reversedAllyTeamsMap);
  $p_gameOverResults={};
  %defeatTimes=();
  %inGameAddedUsers=();
  %inGameAddedPlayers=();
  my %clientStatus = %{$lobby->{users}->{$conf{lobbyLogin}}->{status}};
  $clientStatus{inGame}=1;
  queueLobbyCommand(["MYSTATUS",$lobby->marshallClientStatus(\%clientStatus)]);
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onSpringStart($springPid) if($plugins{$pluginName}->can('onSpringStart'));
  }
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
  $lastBattleMsg{$user}->{$timestamp}=0 unless(exists $lastBattleMsg{$user}->{$timestamp});
  $lastBattleMsg{$user}->{$timestamp}++;

  return 0 if($user eq $conf{lobbyLogin});
  return 0 if(getUserAccessLevel($user) >= $conf{floodImmuneLevel});
  return 1 if(exists $pendingFloodKicks{$user});

  my @autoKickData=split(/;/,$conf{msgFloodAutoKick});

  my $received=0;
  foreach my $timestamp (keys %{$lastBattleMsg{$user}}) {
    if(time - $timestamp > $autoKickData[1]) {
      delete $lastBattleMsg{$user}->{$timestamp};
    }else{
      $received+=$lastBattleMsg{$user}->{$timestamp};
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
  $lastBattleStatus{$user}->{$timestamp}=0 unless(exists $lastBattleStatus{$user}->{$timestamp});
  $lastBattleStatus{$user}->{$timestamp}++;

  return 0 if($user eq $conf{lobbyLogin});
  return 0 if(getUserAccessLevel($user) >= $conf{floodImmuneLevel});
  return 1 if(exists $pendingFloodKicks{$user});

  my @autoKickData=split(/;/,$conf{statusFloodAutoKick});

  my $received=0;
  foreach my $timestamp (keys %{$lastBattleStatus{$user}}) {
    if(time - $timestamp > $autoKickData[1]) {
      delete $lastBattleStatus{$user}->{$timestamp};
    }else{
      $received+=$lastBattleStatus{$user}->{$timestamp};
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
  $lastFloodKicks{$user}->{$timestamp}=0 unless(exists $lastFloodKicks{$user}->{$timestamp});
  $lastFloodKicks{$user}->{$timestamp}++;
  
  my @autoBanData=split(/;/,$conf{kickFloodAutoBan});

  my $nbKick=0;
  foreach my $timestamp (keys %{$lastFloodKicks{$user}}) {
    if(time - $timestamp > $autoBanData[1]) {
      delete $lastFloodKicks{$user}->{$timestamp};
    }else{
      $nbKick+=$lastFloodKicks{$user}->{$timestamp};
    }
  }

  if($autoBanData[0] && $nbKick >= $autoBanData[0]) {
      my $p_user;
      my $accountId=$lobby->{users}->{$user}->{accountId};
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

  my $timestamp=time;
  $lastCmds{$user}={} unless(exists $lastCmds{$user});
  $lastCmds{$user}->{$timestamp}=0 unless(exists $lastCmds{$user}->{$timestamp});
  $lastCmds{$user}->{$timestamp}++;
  
  return 0 if(getUserAccessLevel($user) >= $conf{floodImmuneLevel} || $user eq $sldbLobbyBot);

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
      delete $lastCmds{$user}->{$timestamp};
    }else{
      $received+=$lastCmds{$user}->{$timestamp};
    }
  }

  if($autoIgnoreData[0] && $received >= $autoIgnoreData[0]) {
    broadcastMsg("Ignoring $user for $autoIgnoreData[2] minute(s) (command flood protection)");
    $ignoredUsers{$user}=time+($autoIgnoreData[2] * 60);
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
  if(! open(CHAT,">>$conf{logDir}/chat/$file.log")) {
    slog("Unable to log chat message into file \"$conf{logDir}/chat/$file.log\"",1);
    return;
  }
  my $dateTime=localtime();
  print CHAT "[$dateTime] $msg\n";
  close(CHAT);
}

sub needRehost {
  return 0 unless($lobbyState >= 6);
  my %params = (
    battleName => "title",
    port => "port",
    natType => "natType",
    maxPlayers => "maxPlayers",
    minRank => "rank"
  );
  foreach my $p (keys %params) {
    return 1 if($spads->{hSettings}->{$p} ne $lobby->{battles}->{$lobby->{battle}->{battleId}}->{$params{$p}});
  }
  return 1 if($targetMod ne $lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod});
  return 1 if($spads->{hSettings}->{password} ne $lobby->{battle}->{password} && $spads->{hSettings}->{password} ne "_RANDOM_");
  return 0;
}

sub specExtraPlayers {
  return unless($lobbyState > 5 && %{$lobby->{battle}});

  my @bots=@{$lobby->{battle}->{botList}};
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
  return unless($lobbyState > 5 && %{$lobby->{battle}});
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
  return unless($lobbyState > 5 && %{$lobby->{battle}});

  
  my @bots=@{$lobby->{battle}->{botList}};
  my @localBots;
  my @remoteBots;

  my $nbBots=$#bots+1;
  my $nbLocalBots=0;
  my $nbRemoteBots=0;

  foreach my $botName (@bots) {
    if($lobby->{battle}->{bots}->{$botName}->{owner} eq $conf{lobbyLogin}) {
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
  $nbPlayers=(keys %{$lobby->{battle}->{users}}) - getNbNonPlayer() + (keys %{$lobby->{battle}->{bots}}) if($lobbyState > 5 && %{$lobby->{battle}});
  my $newGameType=(getTargetBattleStructure($nbPlayers))[2];
  return if($newGameType eq $currentGameType);
  $currentGameType=$newGameType;
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  my $needRebalance=0;
  foreach my $user (keys %battleSkills) {
    my $accountId=$lobby->{users}->{$user}->{accountId};
    my $previousUserSkill=$battleSkills{$user}->{skill};
    my $userSkillPref=getUserPref($user,'skillMode');
    if($userSkillPref eq 'TrueSkill') {
      next if(exists $pendingGetSkills{$accountId});
      if(! exists $battleSkillsCache{$user}) {
        slog("Unable to update battle skill of player $user for new game type, no cached skill available!",2);
      }else{
        $battleSkills{$user}->{skill}=$battleSkillsCache{$user}->{$currentGameType}->{skill};
        $battleSkills{$user}->{sigma}=$battleSkillsCache{$user}->{$currentGameType}->{sigma};
        $battleSkills{$user}->{class}=$battleSkillsCache{$user}->{$currentGameType}->{class};
        $battleSkills{$user}->{skillOrigin}='TrueSkill';
      }
    }
    pluginsUpdateSkill($battleSkills{$user},$accountId);
    sendPlayerSkill($user);
    $needRebalance=1 if($previousUserSkill != $battleSkills{$user}->{skill} && exists $lobby->{battle}->{users}->{$user}
                        && defined $lobby->{battle}->{users}->{$user}->{battleStatus} && $lobby->{battle}->{users}->{$user}->{battleStatus}->{mode});
  }
  if($needRebalance) {
    $balanceState=0;
    %balanceTarget=();
  }
}

sub updateBattleSkillsForNewSkillAndRankModes {
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  foreach my $user (keys %{$lobby->{battle}->{users}}) {
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
  my $accountId=$lobby->{users}->{$user}->{accountId};
  my $userLobbyRank=$lobby->{users}->{$user}->{status}->{rank};
  my $userRankPref=getUserPref($user,'rankMode');
  my $userIp=getLatestUserIp($user);
  if($userRankPref eq 'account') {
    $battleSkills{$user}->{rank}=$userLobbyRank;
    $battleSkills{$user}->{rankOrigin}='account';
  }elsif($userRankPref eq 'ip') {
    if($userIp) {
      my ($ipRank,$chRanked)=getIpRank($userIp);
      $battleSkills{$user}->{rank}=$ipRank;
      if($chRanked) {
        $battleSkills{$user}->{rankOrigin}='ipManual';
      }else{
        $battleSkills{$user}->{rankOrigin}='ip';
      }
    }else{
      $battleSkills{$user}->{rank}=$userLobbyRank;
      $battleSkills{$user}->{rankOrigin}='account';
    }
  }else{
    $battleSkills{$user}->{rank}=$userRankPref;
    $battleSkills{$user}->{rankOrigin}='manual';
  }
  my $userSkillPref=getUserPref($user,'skillMode');
  if($userSkillPref eq 'TrueSkill') {
    $battleSkills{$user}->{skillOrigin}='TrueSkillDegraded';
    $battleSkills{$user}->{skill}=$rankTrueSkill{$battleSkills{$user}->{rank}};
    if(exists $battleSkillsCache{$user}) {
      $battleSkills{$user}->{skill}=$battleSkillsCache{$user}->{$currentGameType}->{skill};
      $battleSkills{$user}->{sigma}=$battleSkillsCache{$user}->{$currentGameType}->{sigma};
      $battleSkills{$user}->{class}=$battleSkillsCache{$user}->{$currentGameType}->{class};
      $battleSkills{$user}->{skillOrigin}='TrueSkill';
      pluginsUpdateSkill($battleSkills{$user},$accountId);
      sendPlayerSkill($user);
      checkBattleBansForPlayer($user);
    }elsif(! exists $pendingGetSkills{$accountId}) {
      if(exists $lobby->{users}->{$sldbLobbyBot} && $accountId) {
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
    $battleSkills{$user}->{skillOrigin}='rank';
    $battleSkills{$user}->{skill}=$rankSkill{$battleSkills{$user}->{rank}};
    pluginsUpdateSkill($battleSkills{$user},$accountId);
    sendPlayerSkill($user);
    checkBattleBansForPlayer($user);
  }
}

sub sendPlayerSkill {
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  my $player=shift;
  if(! exists $lobby->{battle}->{users}->{$player}) {
    slog("Unable to send skill of player $player to battle lobby, player is not in battle!",2);
    return;
  }
  my $skill;
  my $skillSigma;
  if($battleSkills{$player}->{skillOrigin} eq 'rank') {
    $skill="($battleSkills{$player}->{skill})";
  }elsif($battleSkills{$player}->{skillOrigin} eq 'TrueSkill') {
    if(exists $battleSkills{$player}->{skillPrivacy} && $battleSkills{$player}->{skillPrivacy} == 0) {
      $skill=$battleSkills{$player}->{skill};
    }else{
      $skill=getRoundedSkill($battleSkills{$player}->{skill});
      $skill="~$skill";
    }
    if(exists $battleSkills{$player}->{sigma}) {
      if($battleSkills{$player}->{sigma} > 3) {
        $skillSigma=3;
      }elsif($battleSkills{$player}->{sigma} > 2) {
        $skillSigma=2;
      }elsif($battleSkills{$player}->{sigma} > 1.5) {
        $skillSigma=1;
      }else{
        $skillSigma=0;
      }
    }
  }elsif($battleSkills{$player}->{skillOrigin} eq 'TrueSkillDegraded') {
    $skill="\#$battleSkills{$player}->{skill}\#";
  }elsif($battleSkills{$player}->{skillOrigin} eq 'Plugin') {
    $skill="\[$battleSkills{$player}->{skill}\]";
  }elsif($battleSkills{$player}->{skillOrigin} eq 'PluginDegraded') {
    $skill="\[\#$battleSkills{$player}->{skill}\#\]";
  }else{
    $skill="?$battleSkills{$player}->{skill}?";
  }
  queueLobbyCommand(["SETSCRIPTTAGS",'game/players/'.lc($player)."/skill=$skill"]);
  queueLobbyCommand(["SETSCRIPTTAGS",'game/players/'.lc($player)."/skilluncertainty=$skillSigma"]) if(defined $skillSigma);
}

sub getBattleSkills {
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  foreach my $user (keys %{$lobby->{battle}->{users}}) {
    getBattleSkill($user);
  }
  $balanceState=0;
  %balanceTarget=();
}

sub getBattleSkill {
  my $user=shift;
  return if($user eq $conf{lobbyLogin});
  my $accountId=$lobby->{users}->{$user}->{accountId};
  my %userSkill;
  my $userLobbyRank=$lobby->{users}->{$user}->{status}->{rank};
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
    $userSkill{skill}=$rankTrueSkill{$userSkill{rank}};
  }else{
    $userSkill{skillOrigin}='rank';
    $userSkill{skill}=$rankSkill{$userSkill{rank}};
  }
  if($userSkillPref eq 'TrueSkill' && exists $lobby->{users}->{$sldbLobbyBot} && $accountId) {
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
  if("maplist" =~ /^$settingRegExp$/) {
    $timestamps{mapLearned}=0;
    $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  }
  $timestamps{battleChange}=time;
  updateBattleInfoIfNeeded();
  updateBattleStates();
  sendBattleMapOptions() if('map' =~ /^$settingRegExp$/);
  applyMapBoxes() if("map" =~ /^$settingRegExp$/ || "nbteams" =~ /^$settingRegExp$/ || "extrabox" =~ /^$settingRegExp$/);
  if("nbplayerbyid" =~ /^$settingRegExp$/ || "teamsize" =~ /^$settingRegExp$/ || "minteamsize" =~ /^$settingRegExp$/ || "nbteams" =~ /^$settingRegExp$/
     || "balancemode" =~ /^$settingRegExp$/ || "autobalance" =~ /^$settingRegExp$/ || "idsharemode" =~ /^$settingRegExp$/
     || 'clanmode' =~ /^$settingRegExp$/) {
    $balanceState=0;
    %balanceTarget=();
  }
  if("autofixcolors" =~ /^$settingRegExp$/ || "idsharemode" =~ /^$settingRegExp$/) {
    $colorsState=0;
    %colorsTarget=();
  }
  enforceMaxBots() if('maxbots' =~ /^$settingRegExp$/ || 'maxlocalbots' =~ /^$settingRegExp$/ || 'maxremotebots' =~ /^$settingRegExp$/);
  enforceMaxSpecs() if('maxspecs' =~ /^$settingRegExp$/);
  specExtraPlayers() if($conf{autoSpecExtraPlayers} && ("nbteams" =~ /^$settingRegExp$/ || "nbplayerbyid" =~ /^$settingRegExp$/));
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
  updateCurrentGameType() if('nbteams' =~ /^$settingRegExp$/ || 'teamsize' =~ /^$settingRegExp$/ || 'nbplayerbyid' =~ /^$settingRegExp$/
                             || 'idsharemode' =~ /^$settingRegExp$/ || 'minteamSize' =~ /^$settingRegExp$/);
  if('rankmode' =~ /^$settingRegExp$/ || 'skillmode' =~ /^$settingRegExp$/) {
    updateBattleSkillsForNewSkillAndRankModes();
    $colorsState=0;
    %colorsTarget=();
  }
  applyBattleBans() if('banlist' =~ /^$settingRegExp$/ || 'nbteams' =~ /^$settingRegExp$/ || 'teamsize' =~ /^$settingRegExp$/);
}

sub applyBattleBans {
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  foreach my $user (keys %{$lobby->{battle}->{users}}) {
    checkBattleBansForPlayer($user);
  }
}

sub checkBattleBansForPlayer {
  my $user=shift;
  return unless($lobbyState > 5 && %{$lobby->{battle}});
  my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
  if($p_ban->{banType} < 2) {
    queueLobbyCommand(["KICKFROMBATTLE",$user]);
  }elsif($p_ban->{banType} == 2) {
    if(defined $lobby->{battle}->{users}->{$user}->{battleStatus} && $lobby->{battle}->{users}->{$user}->{battleStatus}->{mode}) {
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
  return unless($lobbyState > 5);
  applySettingChange(".*");
  sendBattleSettings();
}

sub applyPreset {
  my $preset=shift;
  my $oldPreset=$conf{preset};
  $spads->applyPreset($preset);
  $timestamps{mapLearned}=0;
  $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  setDefaultMapOfMaplist() if($spads->{conf}->{map} eq '');
  %conf=%{$spads->{conf}};
  applyAllSettings();
  updateTargetMod();
  pluginsOnPresetApplied($oldPreset,$preset)
}

sub autoManageBattle {
  return if(time - $timestamps{battleChange} < 2);
  return if($springPid);
  return unless(%{$lobby->{battle}});

  my $battleState=0;

  my $nbNonPlayer=getNbNonPlayer();
  my @clients=keys %{$lobby->{battle}->{users}};
  my @bots=keys %{$lobby->{battle}->{bots}};
  my $nbBots=$#bots+1;
  my $nbPlayers=$#clients+1-$nbNonPlayer;
  $nbPlayers+=$nbBots if($conf{nbTeams} != 1);
  my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};

  my $minTeamSize=$conf{minTeamSize};
  $minTeamSize=$conf{teamSize} if($minTeamSize == 0);

  if($springServerType eq 'headless' && ! (%pendingLocalBotManual || %pendingLocalBotAuto)) {

    my $nbLocalBots=0;
    foreach my $existingBot (@bots) {
      $nbLocalBots++ if($lobby->{battle}->{bots}->{$existingBot}->{owner} eq $conf{lobbyLogin});
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
          my ($botName,$botSide,$botAi)=($p_nextLocalBot->{name},$p_nextLocalBot->{side},$p_nextLocalBot->{ai});
          my $realBotSide=translateSideIfNeeded($botSide);
          if(! defined $realBotSide) {
            slog("Invalid bot side \"$botSide\" for current MOD, using default MOD side instead",2);
            $botSide=0;
          }else{
            $botSide=$realBotSide;
          }
          $pendingLocalBotAuto{$botName}=time;
          queueLobbyCommand(['ADDBOT',$botName,$lobby->marshallBattleStatus({side => $botSide, sync => 0, bonus => 0, mode => 1, team => 0, id => 0, ready => 1}),0,$botAi]);
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

  if((($minTeamSize == 1 && (! ($nbPlayers % $conf{nbTeams}) || $nbPlayers < $conf{nbTeams}))
      || ($minTeamSize > 1 && (! ($nbPlayers % $minTeamSize))))
     && $nbPlayers >= $conf{minPlayers}
     && ($conf{nbTeams} != 1  || @bots)) {
    $battleState=1;
    $battleState=2 if($nbPlayers >= $targetNbPlayers);
  }
  if($conf{autoBalance} ne 'off') {
    return if($battleState < 1);
    return if($conf{autoBalance} eq 'on' && $battleState < 2);
    if(! $balanceState) {
      return if(time - $timestamps{balance} < 5 || time - $timestamps{autoBalance} < 1);
      $timestamps{autoBalance}=time;
      balance();
    }
  }
  if($conf{autoFixColors} ne 'off') {
    return if($battleState < 1);
    return if($conf{autoFixColors} eq 'on' && $battleState < 2);
    if(! $colorsState) {
      return if(time - $timestamps{fixColors} < 5);
      fixColors();
    }
  }
  return unless(($conf{autoBalance} eq 'off' || $balanceState) && ($conf{autoFixColors} eq 'off' || $colorsState));

  if($conf{autoStart} ne 'off') {
    return if($battleState < 1 || %{$lobby->{battle}->{bots}});
    return if($conf{autoStart} eq 'on' && $battleState < 2);
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
  my $aId=getLatestUserAccountId($user);
  my $p_prefs=$spads->getUserPrefs($aId,$user);
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
  $spads->setUserPref($aId,$user,$pref,$value);
}

sub getDefaultAndMaxAllowedValues {
  my ($preset,$setting)=@_;
  my @allowedValues;
  if($preset ne "") {
    if(! exists $spads->{presets}->{$preset}) {
      slog("Unable to find allowed values for setting \"$setting\", preset \"$preset\" does not exist",1);
      return (0,0);
    }
    return ("undefined","undefined") if(! exists $spads->{presets}->{$preset}->{$setting});
    @allowedValues=@{$spads->{presets}->{$preset}->{$setting}};
  }else{
    if(! exists $spads->{values}->{$setting}) {
      slog("Unable to find allowed values for setting \"$setting\" in current preset ($conf{preset})",1);
      return (0,0);
    }
    @allowedValues=@{$spads->{values}->{$setting}};
  }
  my $defaultValue=$allowedValues[0];
  my $maxAllowedValue=$defaultValue;;
  foreach my $allowedValue (@allowedValues) {
    if($allowedValue =~ /^\d+\-(\d+)$/) {
      $maxAllowedValue=$1 if($1 > $maxAllowedValue);
    }elsif($allowedValue =~ /^\d+$/){
      $maxAllowedValue=$allowedValue if($allowedValue > $maxAllowedValue);
    }
  }
  $preset=$conf{preset} if($preset eq "");
  slog("Default and max allowed values for setting \"$setting\" in preset \"$preset\" are: ($defaultValue,$maxAllowedValue)",5);
  return ($defaultValue,$maxAllowedValue);
}

sub getPresetBattleStructure {
  my ($preset,$nbPlayers)=@_;
  if(! exists $spads->{presets}->{$preset}) {
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
  
  if(exists $spads->{bValues}->{$bSetting}) {
    @allowedValues=@{$spads->{bValues}->{$bSetting}};
  }elsif($allowExternalValues) {
    my $p_option=$p_options->{$bSetting};
    my $optionType=$p_option->{type};
    if($optionType eq "bool") {
      @allowedValues=(0,1);
    }elsif($optionType eq "list") {
      @allowedValues=keys %{$p_option->{list}};
    }elsif($optionType eq "number") {
      push(@allowedValues,"$p_option->{numberMin}-$p_option->{numberMax}");
    }
  }

  return @allowedValues;
}

sub seenUserIp {
  my ($user,$ip)=@_;
  if($conf{userDataRetention} !~ /^0;/ && ! $lanMode) {
    my $userIpRetention=-1;
    $userIpRetention=$1 if($conf{userDataRetention} =~ /;(\d+);/);
    if($userIpRetention != 0) {
      if($ip !~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
        slog("Ignoring invalid IP addresss \"$ip\" for user \"$user\"",2);
        return;
      }
      my $id=getLatestUserAccountId($user);
      $spads->learnAccountIp($id,$ip,$userIpRetention);
    }
  }
}

sub getSmurfsData {
  my ($smurfUser,$full,$p_C)=@_;
  return (0,[],[],[]) if($conf{userDataRetention} =~ /^0;/);

  my $smurfId;
  if($smurfUser =~ /^\#([1-9]\d*)$/) {
    $smurfId=$1;
    return (0,[],[],[]) unless($spads->isStoredAccount($smurfId));
  }else{
    return (0,[],[],[]) unless($spads->isStoredUser($smurfUser));
    $smurfId=$spads->getLatestUserAccountId($smurfUser);
  }

  my %C=%{$p_C};
  my @ranks=("Newbie","$C{3}Beginner","$C{3}Average","$C{10}Above average","$C{12}Experienced","$C{7}Highly experienced","$C{4}Veteran","$C{13}Ghost");

  my $p_accountMainData=$spads->getAccountMainData($smurfId);
  my $smurfCountry=$p_accountMainData->{country};
  my $smurfCpu=$p_accountMainData->{cpu};

  my $p_similarAccounts=$spads->getSimilarAccounts($smurfCountry,$smurfCpu);
  my @similarAccounts=sort {$p_similarAccounts->{$b} <=> $p_similarAccounts->{$a}} (keys %{$p_similarAccounts});
  my $nbResults=0;
  my @smurfsData;
  my @probableSmurfs;
  my @otherCandidates;
  my %processedSmurfs;
  my $rc=2;

  my ($p_smurfs)=$spads->getSmurfs($smurfId);
  if(@{$p_smurfs}) {
    $rc=1;
    foreach my $smurf (@{$p_smurfs->[0]}) {
      $processedSmurfs{$smurf}=1;
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
        $confidence=95 if($p_smurfMainData->{cpu} == $smurfCpu);
        $confidence=100 if($smurf eq $smurfId);
        my $online;
        if($id) {
          $online=exists $lobby->{accounts}->{$smurf} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
        }else{
          $online=exists $lobby->{users}->{$smurfName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
        }
        push(@smurfsData,{"$C{5}ID$C{1}" => $id,
                          "$C{5}Name(s)$C{1}" => $names,
                          "$C{5}Online$C{1}" => $online,
                          "$C{5}Country$C{1}" => $p_smurfMainData->{country},
                          "$C{5}CPU$C{1}" => $p_smurfMainData->{cpu},
                          "$C{5}Rank$C{1}" => $ranks[abs($p_smurfMainData->{rank})].$C{1},
                          "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_smurfMainData->{timestamp}),
                          "$C{5}Confidence$C{1}" => "$confidence\%",
                          "$C{5}IP(s)$C{1}" => $ips});
        $nbResults++;
      }
    }
    if($#{$p_smurfs} > 0 && @{$p_smurfs->[1]}) {
      foreach my $smurf (@{$p_smurfs->[1]}) {
        $processedSmurfs{$smurf}=1;
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
          my $confidence=80;
          $confidence=85 if($p_smurfMainData->{cpu} == $smurfCpu);
          my $online;
          if($id) {
            $online=exists $lobby->{accounts}->{$smurf} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
          }else{
            $online=exists $lobby->{users}->{$smurfName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
          }
          push(@smurfsData,{"$C{5}ID$C{1}" => $id,
                            "$C{5}Name(s)$C{1}" => $names,
                            "$C{5}Online$C{1}" => $online,
                            "$C{5}Country$C{1}" => $p_smurfMainData->{country},
                            "$C{5}CPU$C{1}" => $p_smurfMainData->{cpu},
                            "$C{5}Rank$C{1}" => $ranks[abs($p_smurfMainData->{rank})].$C{1},
                            "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_smurfMainData->{timestamp}),
                            "$C{5}Confidence$C{1}" => "$confidence\%",
                            "$C{5}IP(s)$C{1}" => $ips});
          $nbResults++;
        }
      }
    }
    if($#{$p_smurfs} > 1) {
      for my $smurfLevel (2..$#{$p_smurfs}) {
        foreach my $smurf (@{$p_smurfs->[$smurfLevel]}) {
          $processedSmurfs{$smurf}=1;
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
            my $confidence=60;
            $confidence=70 if($p_smurfMainData->{cpu} == $smurfCpu);
            my $online;
            if($id) {
              $online=exists $lobby->{accounts}->{$smurf} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
            }else{
              $online=exists $lobby->{users}->{$smurfName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
            }
            push(@smurfsData,{"$C{5}ID$C{1}" => $id,
                              "$C{5}Name(s)$C{1}" => $names,
                              "$C{5}Online$C{1}" => $online,
                              "$C{5}Country$C{1}" => $p_smurfMainData->{country},
                              "$C{5}CPU$C{1}" => $p_smurfMainData->{cpu},
                              "$C{5}Rank$C{1}" => $ranks[abs($p_smurfMainData->{rank})].$C{1},
                              "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_smurfMainData->{timestamp}),
                              "$C{5}Confidence$C{1}" => "$confidence\%",
                              "$C{5}IP(s)$C{1}" => $ips});
            $nbResults++;
          }
        }
      }
    }
  }
     
  if($full) {
    foreach my $smurf (@similarAccounts) {
      next if(exists $processedSmurfs{$smurf});
      my $p_smurfMainData=$spads->getAccountMainData($smurf);
      my $p_smurfNames=$spads->getAccountNamesTs($smurf);
      my $p_smurfIps=$spads->getAccountIpsTs($smurf);
      my @idNames=sort {$p_smurfNames->{$b} <=> $p_smurfNames->{$a}} (keys %{$p_smurfNames});
      my $names=formatList(\@idNames,40);
      my ($id,$smurfName)=($smurf,undef);
      ($id,$smurfName)=(0,$1) if($smurf =~ /^0\(([^\)]+)\)$/);
      if($nbResults > 39) {
        push(@otherCandidates,"$id($names)");
      }else{
        my $confidence=10;
        my $D=$C{14};
        if($smurf eq $smurfId) {
          $confidence=100;
          $D=$C{1};
        }elsif(@{$p_smurfs} && %{$p_smurfIps}) {
          $confidence=5;
        }
        my $online;
        if($id) {
          $online=exists $lobby->{accounts}->{$smurf} ? "$C{3}Yes$D" : "$C{4}No$D";
        }else{
          $online=exists $lobby->{users}->{$smurfName} ? "$C{3}Yes$D" : "$C{4}No$D";
        }
        my @idIps=sort {$p_smurfIps->{$b} <=> $p_smurfIps->{$a}} (keys %{$p_smurfIps});
        my $ips=formatList(\@idIps,40);
        push(@smurfsData,{"$C{5}ID$C{1}" => $D.$id,
                          "$C{5}Name(s)$C{1}" => $names,
                          "$C{5}Online$C{1}" => $online,
                          "$C{5}Country$C{1}" => $p_smurfMainData->{country},
                          "$C{5}CPU$C{1}" => $p_smurfMainData->{cpu},
                          "$C{5}Rank$C{1}" => $ranks[abs($p_smurfMainData->{rank})].$D,
                          "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_smurfMainData->{timestamp}),
                          "$C{5}Confidence$C{1}" => "$confidence\%",
                          "$C{5}IP(s)$C{1}" => $ips});
        $nbResults++;
      }
    }
  }

  return ($rc,\@smurfsData,\@probableSmurfs,\@otherCandidates);
}

sub checkAutoStop {
  return unless(($conf{autoStop} eq 'noOpponent' || $conf{autoStop} eq 'onlySpec') && $springPid && $autohost->getState() == 2 && $timestamps{autoStop} == 0);
  my %aliveTeams;
  foreach my $player (keys %{$p_runningBattle->{users}}) {
    next unless(defined $p_runningBattle->{users}->{$player}->{battleStatus} && $p_runningBattle->{users}->{$player}->{battleStatus}->{mode});
    my $playerTeam=$p_runningBattle->{users}->{$player}->{battleStatus}->{team};
    next if(exists $aliveTeams{$playerTeam});
    my $p_ahPlayer=$autohost->getPlayer($player);
    next unless(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1 && $p_ahPlayer->{lost} == 0);
    $aliveTeams{$playerTeam}=1;
  }
  foreach my $bot (keys %{$p_runningBattle->{bots}}) {
    my $botTeam=$p_runningBattle->{bots}->{$bot}->{battleStatus}->{team};
    next if(exists $aliveTeams{$botTeam});
    my $p_ahPlayer=$autohost->getPlayer($p_runningBattle->{bots}->{$bot}->{owner});
    next unless(%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} == -1);
    $aliveTeams{$botTeam}=1;
  }
  my $nbAliveTeams=keys %aliveTeams;
  $timestamps{autoStop}=time if(($conf{autoStop} eq 'noOpponent' && $nbAliveTeams < 2) || ($conf{autoStop} eq 'onlySpec' && $nbAliveTeams == 0));
}


sub getPresetLocalBots {
  my @localBotsStrings=split(/;/,$conf{localBots});
  my @localBotsNames;
  my %localBots;
  foreach my $localBotString (@localBotsStrings) {
    if($localBotString=~/^([\w\[\]]{2,20}) (\w+) ([^ \;][^\;]*)$/) {
      my ($lBotName,$lBotSide,$lBotAi)=($1,$2,$3);
      push(@localBotsNames,$lBotName);
      $localBots{$lBotName}={side => $lBotSide,
                             ai => $lBotAi};
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
      if(length($lBotName.$i) < 21 && ! exists $lobby->{battle}->{bots}->{$lBotName.$i}
         && ! exists $pendingLocalBotManual{$lBotName.$i} && ! exists $pendingLocalBotAuto{$lBotName.$i}) {
        %nextLocalBot=(name => $lBotName.$i,
                       side => $p_localBots->{$lBotName}->{side},
                       ai => $p_localBots->{$lBotName}->{ai});
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
    my $p_modSides=getModSides($lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod});
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
  my $logFile="$conf{varDir}/infolog.txt";
  $logFile="$conf{springDataDir}/infolog.txt" if($win && $syncedSpringVersion =~ /^(\d+)/ && $1 < 95);
  my ($demoFile,$gameId);
  if(open(SPRINGLOG,"<$logFile")) {
    while(<SPRINGLOG>) {
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
  return if($lobbyState < 4 || ! exists $lobby->{users}->{$gdrLobbyBot});
  while(@gdrQueue) {
    my $serializedGdr=shift(@gdrQueue);
    my $timestamp=time;
    sayPrivate($gdrLobbyBot,"!#startGDR $timestamp");
    sayPrivate($gdrLobbyBot,$serializedGdr);
    sayPrivate($gdrLobbyBot,"!#endGDR");
  }
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
    if(! file_name_is_absolute($demoFile)) {
      if($syncedSpringVersion =~ /^(\d+)/ && $1 < 95) {
        $demoFile=catfile($conf{springDataDir},$demoFile);
      }else{
        $demoFile=catfile($conf{varDir},$demoFile);
      }
    }
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

  if(%endGameCommandPids) {
    my @pidList=keys %endGameCommandPids;
    my $warningEndMessage='previous end game command is still running';
    $warningEndMessage="the ".($#pidList+1)." previous end game commands are still running" if($#pidList > 0);
    slog("Launching new end game command but $warningEndMessage",2);
  }
  
  my $childPid = fork();
  if(! defined $childPid) {
    slog("Unable to fork to launch endGameCommand",2);
  }else{
    if($childPid == 0) {
      $SIG{CHLD}="" unless($win);
      chdir($cwd);
      
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
      exec($endGameCommand) || forkedError("Unable to launch endGameCommand",2);;
    }else{
      slog("Executing end game command (pid $childPid)",4);
      $endGameCommandPids{$childPid}={startTime => time,
                                      engineVersion => $endGameData{engineVersion},
                                      mod => $endGameData{mod},
                                      map => $endGameData{map},
                                      type => $endGameData{type},
                                      ahAccountId => $endGameData{ahAccountId},
                                      demoFile => $endGameData{demoFile},
                                      gameId => $endGameData{gameId},
                                      result => $endGameData{result}};
    }
  }

}

# SPADS commands handlers #####################################################

sub hAddBot {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < 6) {
    answer("Unable to add AI bot, battle lobby is closed");
    return 0;
  }
  if($springServerType ne 'headless') {
    answer("Unable to add bot: local AI bots require headless server (current server type is \"$springServerType\")");
    return 0;
  }

  my @bots=keys %{$lobby->{battle}->{bots}};
  my $nbLocalBots=0;
  foreach my $existingBot (@bots) {
    $nbLocalBots++ if($lobby->{battle}->{bots}->{$existingBot}->{owner} eq $conf{lobbyLogin});
  }
  if($conf{maxBots} ne '' && $#bots+1 >= $conf{maxBots}) {
    answer("Unable to add bot [maxBots=$conf{maxBots}]");
    return 0;
  }
  if($conf{maxLocalBots} ne '' && $nbLocalBots >= $conf{maxLocalBots}) {
    answer("Unable to add bot [maxLocalBots=$conf{maxLocalBots}]");
    return 0;
  }

  my ($botName,$botSide,@botAiStrings)=@{$p_params};
  my $botAi;
  $botAi=join(' ',@botAiStrings) if(@botAiStrings);

  if(! defined $botName || ! defined $botSide || ! defined $botAi) {
    my ($p_localBotsNames,$p_localBots)=getPresetLocalBots();
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
    }
    if(! defined $botSide) {
      if(exists $p_localBots->{$botName}) {
        $botSide=$p_localBots->{$botName}->{side};
      }else{
        answer("Unable to add bot: bot side is missing and bot name is unknown in \"localBots\" preset setting");
        return 0;
      }
    }
    if(! defined $botAi) {
      if(exists $p_localBots->{$botName}) {
        $botAi=$p_localBots->{$botName}->{ai};
      }else{
        answer("Unable to add bot: bot AI is missing and bot name is unknown in \"localBots\" preset setting");
        return 0;
      }
    }
  }

  if($botName !~ /^[\w\[\]]{2,20}$/) {
    answer("Unable to add bot: invalid bot name \"$botName\"");
    return 0;
  }
  if(exists $lobby->{battle}->{bots}->{$botName} || exists $pendingLocalBotManual{$botName} || exists $pendingLocalBotAuto{$botName}) {
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
  queueLobbyCommand(['ADDBOT',$botName,$lobby->marshallBattleStatus({side => $botSide, sync => 0, bonus => 0, mode => 1, team => 0, id => 0, ready => 1}),0,$botAi]);
}

sub hAddBox {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < 6) {
    answer("Unable to add start box, battle lobby is closed");
    return 0;
  }
  if($#{$p_params} < 3 || $#{$p_params} > 4) {
    invalidSyntax($user,"addbox");
    return 0;
  }
  if($spads->{bSettings}->{startpostype} != 2) {
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
    if($teamNb !~ /^\d+$/ || $teamNb < 1 || $teamNb > 16) {
      invalidSyntax($user,"addbox","invalid team number");
      return 0;
    }
    $teamNb-=1;
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]) if(exists $lobby->{battle}->{startRects}->{$teamNb});
  }else{
    for my $i (0..15) {
      if(! exists $lobby->{battle}->{startRects}->{$i}) {
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

}

sub hAdvert {
  my ($source,$user,$p_params,$checkOnly)=@_;
  return 1 if($checkOnly);
  my $newAdvertMsg='';
  $newAdvertMsg=join(' ',@{$p_params}) if(@{$p_params});
  my @newAdvertMsgs=split(/\|/,$newAdvertMsg);
  $spads->{values}->{advertMsg}=\@newAdvertMsgs;
  $conf{advertMsg}=$newAdvertMsgs[0];
  answer("Advert message updated.");
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
    if(%bosses && exists $lobby->{battle}->{users}->{$user}) {
      my $p_bossLevels=$spads->getCommandLevels("boss","battle","player","stopped");
      if(exists $p_bossLevels->{directLevel}) {
        my $requiredLevel=$p_bossLevels->{directLevel};
        if($level >= $requiredLevel) {
          $bosses{$user}=1;
        }else{
          delete($bosses{$user});
        }
      }
      broadcastMsg("Boss mode disabled") if(! %bosses);
    }
    if($level >= $conf{alertLevel} && %pendingAlerts) {
      alertUser($user) if(! exists $alertedUsers{$user} || time-$alertedUsers{$user} > $conf{alertDelay}*3600);
    }
  }else{
    sayPrivate($user,"Keeping following access level: $C{12}$levelDescription");
  }
}

sub hBalance {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < 6) {
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
  push(@extraStrings,"teams were already balanced") if($balanceState);
  push(@extraStrings,"$nbSmurfs smurf".($nbSmurfs>1 ? 's' : '')." found") if($nbSmurfs);
  push(@extraStrings,"balance deviation: $unbalanceIndicator\%") if($conf{balanceMode} =~ /skill$/);
  my $extraString=join(", ",@extraStrings);
  $balanceMsg.=" ($extraString)" if($extraString);
  answer($balanceMsg);
}

sub hBan {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my ($bannedUser,$banType,$duration,@reason)=@{$p_params};
  
  if(! defined $bannedUser) {
    invalidSyntax($user,"ban");
    return 0;
  }
  my $banMode='user';
  my $id;
  my @banFilters=split(/;/,$bannedUser);
  my $p_user={};
  my @banListsFields=qw'accountId name country cpu rank access bot level ip skill skillUncert';
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
      if(@reason) {
        $p_ban->{reason}=join(" ",@reason);
        if($p_ban->{reason} =~ /[\:\|]/) {
          answer("Invalid reason (reason cannot contain ':' or '|' characters)");
          return 0;
        }
      }
    }
  }

  return 1 if($checkOnly);

  my $banMsg="Full ";
  $banMsg="Battle " if($p_ban->{banType} == 1);
  $banMsg="Force-spec " if($p_ban->{banType} == 2);
  $banMsg.="ban added for $banMode \"$bannedUser\" (";
  if(exists $p_ban->{remainingGames}) {
    $banMsg.="duration: $p_ban->{remainingGames} game".($p_ban->{remainingGames} > 1 ? 's' : '').')';
  }elsif(defined $duration && $duration) {
    $duration=secToTime($duration * 60);
    $banMsg.="duration: $duration)";
  }else{
    $banMsg.="perm-ban)";
  }
  $spads->banUser($p_user,$p_ban);
  answer($banMsg);
  
  if($banMode eq 'account' && exists $lobby->{accounts}->{$id}) {
    $banMode='user';
    $bannedUser=$lobby->{accounts}->{$id};
  }
  if($banMode eq 'user' && $lobbyState >= 6 && exists $lobby->{battle}->{users}->{$bannedUser}) {
    if($p_ban->{banType} < 2) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }else{
      if(defined $lobby->{battle}->{users}->{$bannedUser}->{battleStatus} && $lobby->{battle}->{users}->{$bannedUser}->{battleStatus}->{mode}) {
        my $forceMsg="Forcing spectator mode for $bannedUser [auto-spec mode]";
        $forceMsg.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne "");
        queueLobbyCommand(["FORCESPECTATORMODE",$bannedUser]);
        sayBattle($forceMsg);
      }
    }
  }
}

sub hBanIp {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my ($bannedUser,$banType,$duration,@reason)=@{$p_params};
  
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
      if(@reason) {
        $p_ban->{reason}=join(" ",@reason);
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

  my $banMsg="Battle IP-";
  $banMsg="Force-spec IP-" if($p_ban->{banType} == 2);
  $banMsg.="ban added for $banMode $bannedUser (";
  if(exists $p_ban->{remainingGames}) {
    $banMsg.="duration: $p_ban->{remainingGames} game".($p_ban->{remainingGames} > 1 ? 's' : '').')';
  }elsif(defined $duration && $duration) {
    $duration=secToTime($duration * 60);
    $banMsg.="duration: $duration)";
  }else{
    $banMsg.="perm-ban)";
  }
  $spads->banUser({ip => $userIp},$p_ban);
  answer($banMsg);
  
  if($banMode eq 'account' && exists $lobby->{accounts}->{$id}) {
    $banMode='user';
    $bannedUser=$lobby->{accounts}->{$id};
  }
  if($banMode eq 'user' && $lobbyState >= 6 && exists $lobby->{battle}->{users}->{$bannedUser}) {
    if($p_ban->{banType} < 2) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }else{
      if(defined $lobby->{battle}->{users}->{$bannedUser}->{battleStatus} && $lobby->{battle}->{users}->{$bannedUser}->{battleStatus}->{mode}) {
        my $forceMsg="Forcing spectator mode for $bannedUser [auto-spec mode]";
        $forceMsg.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne "");
        queueLobbyCommand(["FORCESPECTATORMODE",$bannedUser]);
        sayBattle($forceMsg);
      }
    }
  }
}

sub hBanIps {
  my ($source,$user,$p_params,$checkOnly)=@_;
  my ($bannedUser,$banType,$duration,@reason)=@{$p_params};
  
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
      if(@reason) {
        $p_ban->{reason}=join(" ",@reason);
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

  my $banMsg="Battle IP-";
  $banMsg="Force-spec IP-" if($p_ban->{banType} == 2);
  $banMsg.="ban added for $banMode $bannedUser (";
  $banMsg.=($#{$p_userIps}+1)." IPs, " if($#{$p_userIps} > 0);
  if(exists $p_ban->{remainingGames}) {
    $banMsg.="duration: $p_ban->{remainingGames} game".($p_ban->{remainingGames} > 1 ? 's' : '').')';
  }elsif(defined $duration && $duration) {
    $duration=secToTime($duration * 60);
    $banMsg.="duration: $duration)";
  }else{
    $banMsg.="perm-ban)";
  }
  $spads->banUser({ip => join(",",@{$p_userIps})},$p_ban);
  answer($banMsg);
  
  if($banMode eq 'account' && exists $lobby->{accounts}->{$id}) {
    $banMode='user';
    $bannedUser=$lobby->{accounts}->{$id};
  }
  if($banMode eq 'user' && $lobbyState >= 6 && exists $lobby->{battle}->{users}->{$bannedUser}) {
    if($p_ban->{banType} < 2) {
      queueLobbyCommand(["KICKFROMBATTLE",$bannedUser]);
    }else{
      if(defined $lobby->{battle}->{users}->{$bannedUser}->{battleStatus} && $lobby->{battle}->{users}->{$bannedUser}->{battleStatus}->{mode}) {
        my $forceMsg="Forcing spectator mode for $bannedUser [auto-spec mode]";
        $forceMsg.=" (reason: $p_ban->{reason})" if(exists $p_ban->{reason} && defined $p_ban->{reason} && $p_ban->{reason} ne "");
        queueLobbyCommand(["FORCESPECTATORMODE",$bannedUser]);
        sayBattle($forceMsg);
      }
    }
  }
}

sub hBKick {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"bkick");
    return 0;
  }
  
  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
    answer("Unable to kick from battle lobby, battle lobby is closed");
    return 0;
  }

  my @players=keys(%{$lobby->{battle}->{users}});
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

  return "bKick $kickedUser" if($checkOnly);
 
  queueLobbyCommand(["KICKFROMBATTLE",$kickedUser]);
  return "bKick $kickedUser";
}

sub hBoss {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 0) {
    invalidSyntax($user,"boss");
    return 0;
  }
  
  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
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

  my @players=keys(%{$lobby->{battle}->{users}});
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

  return "boss $bossUser" if($checkOnly);

  if(%bosses) {
    $bosses{$bossUser}=1;
  }else{
    %bosses=($bossUser => 1);
    my $p_bossLevels=$spads->getCommandLevels("boss","battle","player","stopped");
    if(exists $p_bossLevels->{directLevel}) {
      my $requiredLevel=$p_bossLevels->{directLevel};
      foreach my $player (@players) {
        my $playerLevel=getUserAccessLevel($player);
        $bosses{$player}=1 if($playerLevel >= $requiredLevel);
      }
    }
  }
  my $bossMsg="Boss mode enabled for $bossUser";
  $bossMsg.=" (by $user)" if($user ne $bossUser);
  broadcastMsg($bossMsg);
  return "boss $bossUser";
}

sub hBPreset {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"bpreset");
    return 0;
  }

  my ($bPreset)=@{$p_params};

  if(! exists $spads->{bPresets}->{$bPreset}) {
    answer("\"$bPreset\" is not a valid battle preset (use \"!list bPresets\" to list available battle presets)");
    return 0;
  }

  if(none {$bPreset eq $_} @{$spads->{values}->{battlePreset}}) {
    answer("Switching to battle preset \"$bPreset\" is not allowed from current global preset");
    return 0;
  }

  return 1 if($checkOnly);

  $timestamps{autoRestore}=time;
  $spads->applyBPreset($bPreset);
  %conf=%{$spads->{conf}};
  sendBattleSettings() if($lobbyState >= 6);
  sayBattleAndGame("Battle preset \"$bPreset\" ($spads->{bSettings}->{description}) applied by $user");
}

sub hBSet {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != 1) {
    invalidSyntax($user,"bset");
    return 0;
  }

  my ($bSetting,$val)=@{$p_params};
  $bSetting=lc($bSetting);

  my $modName=$targetMod;
  $modName=$lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod} if($lobbyState >= 6);
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
  if(! @allowedValues && $allowExternalValues) {
    answer("\"$bSetting\" is a $optionScope option of type \"$p_options->{$bSetting}->{type}\", it must be defined in current battle preset to be modifiable");
    return 0;
  }

  my $allowed=0;
  foreach my $allowedValue (@allowedValues) {
    if(isRange($allowedValue)) {
      $allowed=1 if(matchRange($allowedValue,$val));
    }elsif($val eq $allowedValue) {
      $allowed=1;
    }
    last if($allowed);
  }
  if($allowed) {
    if(exists $spads->{bSettings}->{$bSetting}) {
      if($spads->{bSettings}->{$bSetting} eq $val) {
        answer("Battle setting \"$bSetting\" is already set to value \"$val\"");
        return 0;
      }
    }elsif($val eq $p_options->{$bSetting}->{default}) {
      answer("Battle setting \"$bSetting\" is already set to value \"$val\"");
      return 0;
    }
    return 1 if($checkOnly);
    $spads->{bSettings}->{$bSetting}=$val;
    sendBattleSetting($bSetting) if($lobbyState >= 6);
    $timestamps{autoRestore}=time;
    sayBattleAndGame("Battle setting changed by $user ($bSetting=$val)");
    answer("Battle setting changed ($bSetting=$val)") if($source eq "pv");
    applyMapBoxes() if($bSetting eq "startpostype");
    return;
  }else{
    answer("Value \"$val\" for battle setting \"$bSetting\" is not allowed with current $optionScope or battle preset"); 
    return 0;
  }

}

sub hCancelQuit {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if(! $quitAfterGame) {
    answer("No quit or restart has been scheduled, nothing to cancel");
    return 0;
  }
  return 1 if($checkOnly);

  my %sourceNames = ( pv => "private",
                      chan => "channel #$masterChannel",
                      game => "game",
                      battle => "battle lobby" );

  cancelQuitAfterGame("requested by $user in $sourceNames{$source}");
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
  my $params=join(" ",@{$p_params});
  $params="/$params" unless($params =~ /^\//);

  $autohost->sendChatMessage("/cheat 1");
  logMsg("game","> /cheat 1") if($conf{logGameChat});
  $autohost->sendChatMessage($params);
  logMsg("game","> $params") if($conf{logGameChat});
  $autohost->sendChatMessage("/cheat 0");
  logMsg("game","> /cheat 0") if($conf{logGameChat});
  
  return 1;
  
}

sub hCallVote {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($checkOnly || ! @{$p_params}) {
    invalidSyntax($user,'callvote');
    return 0;
  }

  $p_params->[0]=$1 if($p_params->[0] =~ /^!(.+)$/);

  my ($p_cmd,$warnMes)=processAliases($user,$p_params);
  $p_params=$p_cmd if($p_cmd);

  sayPrivate($user,$warnMes) if($warnMes && $conf{springieEmulation} eq "warn" && exists $lobby->{users}->{$user} && (! $lobby->{users}->{$user}->{status}->{inGame}));

  my $checkValue=executeCommand($source,$user,$p_params,1);
  return unless($checkValue);

  if($checkValue ne '1') {
    my @rewrittenCommand=split(/ /,$checkValue);
    $p_params=\@rewrittenCommand;
  }

  my $p_bossLevels=$spads->getCommandLevels("boss","battle","player","stopped");
  my $p_levelsForVote=getCommandLevels($source,$user,lc($p_params->[0]));
  my $voterLevel=getUserAccessLevel($user);
  $voterLevel=0 if(%bosses && ! exists $bosses{$user} && exists $p_bossLevels->{directLevel} && $voterLevel < $p_bossLevels->{directLevel});

  if(! (defined $p_levelsForVote->{voteLevel} && $p_levelsForVote->{voteLevel} ne "" && $voterLevel >= $p_levelsForVote->{voteLevel})) {
    answer("$user, you are not allowed to vote for command \"$p_params->[0]\" in current context.");
    return;
  }

  if(%currentVote) {
    if(exists $currentVote{command}) {
      if((exists $currentVote{remainingVoters}->{$user} || exists $currentVote{awayVoters}->{$user}) && $#{$currentVote{command}} == $#{$p_params}) {
        my $isSameCmd=1;
        for my $i (0..$#{$p_params}) {
          if(lc($p_params->[$i]) ne lc($currentVote{command}->[$i])) {
            $isSameCmd=0;
            last;
          }
        }
        if($isSameCmd) {
          executeCommand($source,$user,['vote','y']);
          return;
        }
      }
      answer("$user, there is already a vote in progress, please wait for it to finish before calling another one.");
      return;
    }elsif($user eq $currentVote{user}) {
      answer("$user, please wait ".($currentVote{expireTime} + $conf{reCallVoteDelay} - time)." more second(s) before calling another vote (vote flood protection).");
      return;
    }
  }

  my %remainingVoters;
  if(exists $lobby->{battle}->{users}) {
    foreach my $bUser (keys %{$lobby->{battle}->{users}}) {
      next if($bUser eq $user || $bUser eq $conf{lobbyLogin});
      my $p_levels=getCommandLevels($source,$bUser,lc($p_params->[0]));
      my $level=getUserAccessLevel($bUser);
      $level=0 if(%bosses && ! exists $bosses{$bUser} && exists $p_bossLevels->{directLevel} && $level < $p_bossLevels->{directLevel});
      if(defined $p_levels->{voteLevel} && $p_levels->{voteLevel} ne "" && $level >= $p_levels->{voteLevel}) {
        my ($voteRingDelay,$votePvMsgDelay)=(getUserPref($bUser,'voteRingDelay'),getUserPref($bUser,'votePvMsgDelay'));
        $remainingVoters{$bUser} = { ringTime => 0,
                                     notifyTime => 0};
        $remainingVoters{$bUser}->{ringTime} = time+$voteRingDelay if($voteRingDelay);
        $remainingVoters{$bUser}->{notifyTime} = time+$votePvMsgDelay if($votePvMsgDelay);
      }
    }
  }
  if($autohost->getState()) {
    foreach my $gUserNb (keys %{$autohost->{players}}) {
      next if($autohost->{players}->{$gUserNb}->{disconnectCause} != -1);
      my $gUser=$autohost->{players}->{$gUserNb}->{name};
      next if($gUser eq $user || $gUser eq $conf{lobbyLogin} || exists $remainingVoters{$gUser});
      my $p_levels=getCommandLevels($source,$gUser,lc($p_params->[0]));
      my $level=getUserAccessLevel($gUser);
      $level=0 if(%bosses && ! exists $bosses{$gUser} && exists $p_bossLevels->{directLevel} && $level < $p_bossLevels->{directLevel});
      if(defined $p_levels->{voteLevel} && $p_levels->{voteLevel} ne "" && $level >= $p_levels->{voteLevel}) {
        my ($voteRingDelay,$votePvMsgDelay)=(getUserPref($gUser,'voteRingDelay'),getUserPref($gUser,'votePvMsgDelay'));
        $remainingVoters{$gUser} = { ringTime => 0,
                                     notifyTime => 0};
        $remainingVoters{$gUser}->{ringTime} = time+$voteRingDelay if($voteRingDelay);
        $remainingVoters{$gUser}->{notifyTime} = time+$votePvMsgDelay if($votePvMsgDelay);
      }
    }
  }

  if(%remainingVoters) {
    my $voteCallAllowed=1;
    foreach my $pluginName (@pluginsOrder) {
      $voteCallAllowed=$plugins{$pluginName}->onVoteRequest($source,$user,$p_params,\%remainingVoters) if($plugins{$pluginName}->can('onVoteRequest'));
      last unless($voteCallAllowed && %remainingVoters);
    }
    return unless($voteCallAllowed);
    if(! %remainingVoters) {
      executeCommand($source,$user,$p_params);
      return;
    }
    %currentVote = (expireTime => time + $conf{voteTime},
                    user => $user,
                    awayVoteTime => time + 20,
                    source => $source,
                    command => $p_params,
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
    sayBattleAndGame("$user called a vote for command \"".join(' ',@{$p_params})."\" [!vote y, !vote n, !vote b]");
    sayBattleAndGame($playersAllowedString);
    foreach my $pluginName (@pluginsOrder) {
      $plugins{$pluginName}->onVoteStart($user,$p_params) if($plugins{$pluginName}->can('onVoteStart'));
    }
  }else{
    executeCommand($source,$user,$p_params);
  }

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
  $oldLevel=getUserAccessLevel($passwdUser) if($lobbyState > 3 && exists $lobby->{users}->{$passwdUser});
  if($#{$p_params} == 0) {
    $spads->setUserPref($aId,$passwdUser,'password','');
    answer("Password removed for user $passwdUser");
  }else{
    $spads->setUserPref($aId,$passwdUser,'password',md5_base64($p_params->[1]));
    answer("Password set to \"$p_params->[1]\" for user $passwdUser");
  }
  if($lobbyState > 3 && exists $lobby->{users}->{$passwdUser}) {
    my $level=getUserAccessLevel($passwdUser);
    if($level != $oldLevel) {
      if(%bosses && exists $lobby->{battle}->{users}->{$passwdUser}) {
        my $p_bossLevels=$spads->getCommandLevels("boss","battle","player","stopped");
        if(exists $p_bossLevels->{directLevel}) {
          my $requiredLevel=$p_bossLevels->{directLevel};
          if($level >= $requiredLevel) {
            $bosses{$passwdUser}=1;
          }else{
            delete($bosses{$passwdUser});
          }
        }
        broadcastMsg("Boss mode disabled") if(! %bosses);
      }
    }
    sayPrivate($passwdUser,"Your AutoHost password has been modified by $user");
  }
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
  return 1 if($checkOnly);
  if($#{$p_params} == 0) {
    return 1 if($checkOnly);
    $spads->setUserPref($aId,$modifiedUser,"rankMode","");
    answer("Default rankMode restored for user $modifiedUser");
  }else{
    my $val=$p_params->[1];
    my ($errorMsg)=$spads->checkUserPref("rankMode",$val);
    if($errorMsg) {
      invalidSyntax($user,"chrank",$errorMsg);
      return 0;
    }
    return 1 if($checkOnly);
    $spads->setUserPref($aId,$modifiedUser,"rankMode",$val);
    answer("RankMode set to \"$val\" for user $modifiedUser");
  }
  if($lobbyState > 5 && %{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$modifiedUser}) {
    updateBattleSkillForNewSkillAndRankModes($modifiedUser);
    if(defined $lobby->{battle}->{users}->{$modifiedUser}->{battleStatus} && $lobby->{battle}->{users}->{$modifiedUser}->{battleStatus}->{mode}) {
      $balanceState=0;
      %balanceTarget=();
    }
  }
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
  return 1 if($checkOnly);
  if($#{$p_params} == 0) {
    return 1 if($checkOnly);
    $spads->setUserPref($aId,$modifiedUser,'skillMode','');
    answer("Default skillMode restored for user $modifiedUser");
  }else{
    my $val=$p_params->[1];
    my ($errorMsg)=$spads->checkUserPref('skillMode',$val);
    if($errorMsg) {
      invalidSyntax($user,'chskill',$errorMsg);
      return 0;
    }
    return 1 if($checkOnly);
    $spads->setUserPref($aId,$modifiedUser,'skillMode',$val);
    answer("SkillMode set to \"$val\" for user $modifiedUser");
  }
  if($lobbyState > 5 && %{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$modifiedUser}) {
    updateBattleSkillForNewSkillAndRankModes($modifiedUser);
    if(defined $lobby->{battle}->{users}->{$modifiedUser}->{battleStatus} && $lobby->{battle}->{users}->{$modifiedUser}->{battleStatus}->{mode}) {
      $balanceState=0;
      %balanceTarget=();
    }
  }
}

sub hCKick {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"ckick");
    return 0;
  }
  
  if($lobbyState < 4 || ! exists $lobby->{channels}->{$masterChannel} ) {
    answer("Unable to kick from channel \#$masterChannel (outside of channel)");
    return 0;
  }

  if(! $conf{opOnMasterChannel}) {
    answer("Unable to kick from channel \#$masterChannel (Not operator)");
    return 0;
  }

  my @players=keys(%{$lobby->{channels}->{$masterChannel}});
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

  return "cKick $kickedUser" if($checkOnly);

  my %sourceNames = ( pv => "private",
                      chan => "channel \#$masterChannel",
                      game => "game",
                      battle => "battle lobby" );

  sayPrivate("ChanServ","!kick \#$masterChannel $kickedUser requested by $user in $sourceNames{$source}");
  return "cKick $kickedUser";
}

sub hClearBox {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < 6) {
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
    }elsif($teamNb !~ /^\d+$/ || $teamNb < 1 || $teamNb > 16) {
      invalidSyntax($user,"clearbox","invalid team number");
      return 0;
    }else{
      return 1 if($checkOnly);
      $teamNb-=1;
      queueLobbyCommand(["REMOVESTARTRECT",$teamNb]) if(exists $lobby->{battle}->{startRects}->{$teamNb});
      return 1;
    }
  }

  return 1 if($checkOnly);
  foreach $teamNb (keys %{$lobby->{battle}->{startRects}}) {
    next if($teamNb < $minNb);
    queueLobbyCommand(["REMOVESTARTRECT",$teamNb]);
  }
}

sub hCloseBattle {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($lobbyState < 6) {
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
  }else{
    answer("Unable to cancel vote (no vote in progress)");
    return 0;
  }
}

sub hFixColors {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < 6) {
    answer("Unable to fix colors, battle lobby is closed");
    return 0;
  }

  if($#{$p_params} != -1) {
    invalidSyntax($user,"fixcolors");
    return 0;
  }

  return 1 if($checkOnly);
  fixColors();
}

sub hForce {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
    answer("Unable to force player battle status, battle lobby is closed");
    return 0;
  }

  if($#{$p_params} != 1 && $#{$p_params} != 2) {
    invalidSyntax($user,"force");
    return 0;
  }

  my ($player,$type,$nb)=@{$p_params};

  if(lc($type) eq "id" || lc($type) eq "team") {
    if($conf{autoBalance} ne "off") {
      answer("Cannot force id/team, autoBalance is enabled");
      return 0;
    }elsif($conf{autoBlockBalance} && $balanceState) {
      answer("Cannot force id/team, teams are balanced and autoBlockBalance is enabled");
      return 0;
    }
  }

  my $p_forcedUsers=[];
  if($player =~ /^\%(.+)$/) {
    $player=$1;
  }else{
    my @players=keys(%{$lobby->{battle}->{users}});
    $p_forcedUsers=cleverSearch($player,\@players);
    if($#{$p_forcedUsers} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$player\" in battle lobby");
      return 0;
    }
  }
  if(! @{$p_forcedUsers}) {
    my @bots=keys(%{$lobby->{battle}->{bots}});
    my $p_forcedBots=cleverSearch($player,\@bots);
    if(! @{$p_forcedBots}) {
      answer("Unable to fing matching player for \"$player\" in battle lobby");
      return 0;
    }
    if($#{$p_forcedBots} > 0) {
      answer("Ambiguous command, multiple matches found for player \"$player\" in battle lobby");
      return 0;
    }
    my $forcedBot=$p_forcedBots->[0];
    if(lc($type) eq "id") {
      if(defined $nb && $nb =~ /^\d+$/ && $nb > 0 || $nb < 17) {
        return "force $forcedBot id $nb" if($checkOnly);
        my $p_battle=$lobby->getBattle();
        my $p_battleStatus=$p_battle->{bots}->{$forcedBot}->{battleStatus};
        $p_battleStatus->{id}=$nb-1;
        my $p_color=$p_battle->{bots}->{$forcedBot}->{color};
        queueLobbyCommand(["UPDATEBOT",$forcedBot,$lobby->marshallBattleStatus($p_battleStatus),$lobby->marshallColor($p_color)]);
        return "force $forcedBot id $nb";
      }else{
        invalidSyntax($user,"force");
        return 0;
      }
    }elsif(lc($type) eq "team") {
      if(defined $nb && $nb =~ /^\d+$/ && $nb > 0 || $nb < 17) {
        return "force $forcedBot team $nb" if($checkOnly);
        my $p_battle=$lobby->getBattle();
        my $p_battleStatus=$p_battle->{bots}->{$forcedBot}->{battleStatus};
        $p_battleStatus->{team}=$nb-1;
        my $p_color=$p_battle->{bots}->{$forcedBot}->{color};
        queueLobbyCommand(["UPDATEBOT",$forcedBot,$lobby->marshallBattleStatus($p_battleStatus),$lobby->marshallColor($p_color)]);
        return "force $forcedBot team $nb";
      }else{
        invalidSyntax($user,"force");
        return 0;
      }
    }else{
      invalidSyntax($user,"force");
      return 0;
    }
  }else{
    my $forcedUser=$p_forcedUsers->[0];
    if(lc($type) eq "spec") {
      return "force $forcedUser spec" if($checkOnly);
      queueLobbyCommand(["FORCESPECTATORMODE",$forcedUser]);
      return "force $forcedUser spec";
    }elsif(lc($type) eq "id") {
      if(defined $nb && $nb =~ /^\d+$/ && $nb > 0 || $nb < 17) {
        return "force $forcedUser id $nb" if($checkOnly);
        queueLobbyCommand(["FORCETEAMNO",$forcedUser,$nb-1]);
        return "force $forcedUser id $nb";
      }else{
        invalidSyntax($user,"force");
        return 0;
      }
    }elsif(lc($type) eq "team") {
      if(defined $nb && $nb =~ /^\d+$/ && $nb > 0 || $nb < 17) {
        return "force $forcedUser team $nb" if($checkOnly);
        queueLobbyCommand(["FORCEALLYNO",$forcedUser,$nb-1]);
        return "force $forcedUser team $nb";
      }else{
        invalidSyntax($user,"force");
        return 0;
      }
    }else{
      invalidSyntax($user,"force");
      return 0;
    }
  }

}

sub hForcePreset {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"forcepreset");
    return 0;
  }

  my ($preset)=@{$p_params};

  if(! exists $spads->{presets}->{$preset}) {
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
}

sub hForceStart {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != -1) {
    invalidSyntax($user,"forcestart");
    return 0;
  }

  my $gameState=$autohost->getState();
  if($gameState == 0) {
    if($lobbyState < 6) {
      answer("Unable to launch game, battle lobby is closed");
      return 0;
    }
    return launchGame(1,$checkOnly);
  }elsif($gameState == 1) {
    return 1 if($checkOnly);
    broadcastMsg("Forcing game start by $user");
    $timestamps{autoForcePossible}=-2;
    $autohost->sendChatMessage("/forcestart");
    logMsg("game","> /forcestart") if($conf{logGameChat});
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
  my @players=grep {%{$p_ahPlayers->{$_}} && $p_ahPlayers->{$_}->{disconnectCause} == -1} (keys %{$p_ahPlayers});
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

  return "gKick $kickedUser" if($checkOnly);

  $autohost->sendChatMessage("/kickbynum $p_ahPlayers->{$kickedUser}->{playerNb}");
  logMsg("game","> /kickbynum $p_ahPlayers->{$kickedUser}->{playerNb}") if($conf{logGameChat});

  return "gKick $kickedUser";
  
}

sub initUserIrcColors {
  my $user=shift;
  return @ircStyle if(getUserPref($user,'ircColors'));
  return @noIrcStyle;
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

    my $modName=$targetMod;
    $modName=$lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod} if($lobbyState >= 6);
    my $p_modOptions=getModOptions($modName);
    my $p_mapOptions=getMapOptions($currentMap);

    if(! exists $spads->{help}->{$helpCommand} && $conf{allowSettingsShortcut} && none {$helpCommand eq $_} @readOnlySettings) {
      if(exists $spads->{helpSettings}->{global}->{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="global";
      }elsif(exists $spads->{helpSettings}->{set}->{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="set";
      }elsif(exists $spads->{helpSettings}->{hset}->{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="hset";
      }elsif(exists $spads->{helpSettings}->{bset}->{$helpCommand} || exists $p_modOptions->{$helpCommand} || exists $p_mapOptions->{$helpCommand}) {
        $setting=$helpCommand;
        $helpCommand="bset";
      }elsif(exists $spads->{helpSettings}->{pset}->{$helpCommand}) {
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
            sayPrivate($user,"  $itemKey: $listItems{$itemKey}->{name} ($listItems{$itemKey}->{description})");
          }
        }elsif($p_option->{type} eq "number") {
          sayPrivate($user,"  $p_option->{numberMin} .. $p_option->{numberMax}");
        }elsif($p_option->{type} eq "string") {
          sayPrivate($user,"  any string with a maximum length of $p_option->{stringMaxLen}");
        }
        sayPrivate($user,"$B$C{10}Default value:");
        sayPrivate($user,"  $p_option->{default}");
      }elsif(exists $spads->{helpSettings}->{$helpCommand}->{$setting}) {
        my $settingHelp=$spads->{helpSettings}->{$helpCommand}->{$setting};
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
      if(exists $spads->{help}->{$helpCommand}) {
        $p_help=$spads->{help}->{$helpCommand};
        $moduleString='';
      }else{
        foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
          if(exists $spads->{pluginsConf}->{$pluginName}->{help}->{$helpCommand}) {
            $p_help=$spads->{pluginsConf}->{$pluginName}->{help}->{$helpCommand};
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
      $p_helpForUser->{direct}->[$i]="$C{3}$1$C{5}$2$C{1}$3" if($p_helpForUser->{direct}->[$i] =~ /^(!\w+)(.*)( - .*)$/);
      sayPrivate($user,$p_helpForUser->{direct}->[$i]);
    }
    if(@{$p_helpForUser->{vote}}) {
      sayPrivate($user,"$B********** Additional commands available by vote for your access level **********");
      foreach my $i (0..$#{$p_helpForUser->{vote}}) {
        $p_helpForUser->{vote}->[$i]="$C{10}$1$C{5}$2$C{14}$3" if($p_helpForUser->{vote}->[$i] =~ /^(!\w+)(.*)( - .*)$/);
        sayPrivate($user,$p_helpForUser->{vote}->[$i]);
      }
    }
    sayPrivate($user,"  --> Use \"$C{3}!list aliases$C{1}\" to list available command aliases.");
  }

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
    my $helpLine=$p_help->{$command}->[0];
    $helpLine="$C{3}$1$C{5}$2$C{1}$3" if($helpLine =~ /^(!\w+)(.*)( - .*)$/);
    sayPrivate($user,$helpLine);
  }

  foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
    if(%{$spads->{pluginsConf}->{$pluginName}->{help}}) {
      $p_help=$spads->{pluginsConf}->{$pluginName}->{help};
      sayPrivate($user,"$B********** $pluginName plugin commands **********");
      for my $command (sort (keys %{$p_help})) {
        next unless($command);
        my $helpLine=$p_help->{$command}->[0];
        $helpLine="$C{3}$1$C{5}$2$C{1}$3" if($helpLine =~ /^(!\w+)(.*)( - .*)$/);
        sayPrivate($user,$helpLine);
      }
    }
  }
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

  if(! exists $spads->{hPresets}->{$hPreset}) {
    answer("\"$hPreset\" is not a valid hosting preset (use \"!list hPresets\" to list available hosting presets)");
    return 0;
  }

  if(none {$hPreset eq $_} @{$spads->{values}->{hostingPreset}}) {
    answer("Switching to hosting preset \"$hPreset\" is not allowed from current global preset");
    return 0;
  }

  return 1 if($checkOnly);

  $timestamps{autoRestore}=time;
  $spads->applyHPreset($hPreset);
  %conf=%{$spads->{conf}};
  updateTargetMod();
  my $msg="Hosting preset \"$hPreset\" ($spads->{hSettings}->{description}) applied by $user";
  $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
  sayBattleAndGame($msg);
}

sub hHSet {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 1) {
    invalidSyntax($user,"hset");
    return 0;
  }

  my ($hSetting,@vals)=@{$p_params};
  my $val=join(" ",@vals);
  $hSetting=lc($hSetting);

  foreach my $hParam (keys %{$spads->{hValues}}) {
    next if(any {$hParam eq $_} qw'description battleName');
    if($hSetting eq lc($hParam)) {
      my $allowed=0;
      foreach my $allowedValue (@{$spads->{hValues}->{$hParam}}) {
        if(isRange($allowedValue)) {
          $allowed=1 if(matchRange($allowedValue,$val));
        }elsif($val eq $allowedValue) {
          $allowed=1;
        }
        last if($allowed);
      }
      if($allowed) {
        if($spads->{hSettings}->{$hParam} eq $val) {
          answer("Hosting setting \"$hParam\" is already set to value \"$val\"");
          return 0;
        }
        return 1 if($checkOnly);
        $spads->{hSettings}->{$hParam}=$val;
        updateTargetMod() if($hParam eq "modName");
        $timestamps{autoRestore}=time;
        sayBattleAndGame("Hosting setting changed by $user ($hParam=$val), use !rehost to apply new value.");
        answer("Hosting setting changed ($hParam=$val)") if($source eq "pv");
        return;
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
  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
    answer("Unable to add in-game player, battle lobby is closed");
    return 0;
  }

  my ($joinedEntity,$joiningPlayer)=($p_params->[0],$user);
  $joiningPlayer=$p_params->[1] if($#{$p_params} == 1);

  my @battlePlayers=keys(%{$lobby->{battle}->{users}});
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
  if(exists $p_runningBattle->{users}->{$joiningPlayer}) {
    answer("Player \"$joiningPlayer\" has already been added at start");
    return 0;
  }
  if(! defined $lobby->{battle}->{users}->{$joiningPlayer}->{scriptPass}) {
    answer("Unable to add in-game player \"$joiningPlayer\", player didn't send script password");
    return 0;
  }
  if(exists $inGameAddedUsers{$joiningPlayer}) {
    answer("Player \"$joiningPlayer\" has already been added in game");
    return 0;
  }

  if($joinedEntity eq 'spec') {
    return "joinAs spec $joiningPlayer" if($checkOnly);
    $inGameAddedUsers{$joiningPlayer}=$lobby->{battle}->{users}->{$joiningPlayer}->{scriptPass};
    my $joinMsg="Adding user $joiningPlayer as spectator";
    $joinMsg.= " (by $user)" if($user ne $joiningPlayer);
    sayBattle($joinMsg);
    $autohost->sendChatMessage("/adduser $joiningPlayer $inGameAddedUsers{$joiningPlayer}");
    return "joinAs spec $joiningPlayer";
  }elsif($joinedEntity =~ /^\#(\d+)$/) {
    my $joinedId=$1;
    if(! exists $runningBattleReversedMapping{teams}->{$joinedId}) {
      answer("Unable to add in-game player in ID $joinedId (invalid in-game ID, use !status to check in-game IDs)");
      return 0;
    }
    return "joinAs $joinedEntity $joiningPlayer" if($checkOnly);
    $inGameAddedPlayers{$joiningPlayer}=$joinedId;
    $inGameAddedUsers{$joiningPlayer}=$lobby->{battle}->{users}->{$joiningPlayer}->{scriptPass};
    my $joinMsg="Adding player $joiningPlayer in ID $joinedId";
    $joinMsg.=" (by $user)" if($user ne $joiningPlayer);
    sayBattleAndGame($joinMsg);
    $autohost->sendChatMessage("/adduser $joiningPlayer $inGameAddedUsers{$joiningPlayer} 0 $joinedId");
    return "joinAs $joinedEntity $joiningPlayer";
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
      $joinedId=$runningBattleMapping{teams}->{$p_runningBattle->{bots}->{$joinedEntity}->{battleStatus}->{id}};
    }else{
      if(exists $p_runningBattle->{users}->{$joinedEntity}) {
        if(defined $p_runningBattle->{users}->{$joinedEntity}->{battleStatus} && $p_runningBattle->{users}->{$joinedEntity}->{battleStatus}->{mode}) {
          $joinedId=$runningBattleMapping{teams}->{$p_runningBattle->{users}->{$joinedEntity}->{battleStatus}->{id}};
        }else{
          answer("Player \"$joinedEntity\" is a spectator, use \"!joinAs spec\" if you want to add in-game spectators");
          return 0;
        }
      }else{
        $joinedId=$inGameAddedPlayers{$joinedEntity};
      }
    }
    return "joinAs $joinedEntity $joiningPlayer" if($checkOnly);
    $inGameAddedPlayers{$joiningPlayer}=$joinedId;
    $inGameAddedUsers{$joiningPlayer}=$lobby->{battle}->{users}->{$joiningPlayer}->{scriptPass};
    my $joinMsg="Adding player $joiningPlayer in ID $joinedId";
    $joinMsg.=" (by $user)" if($user ne $joiningPlayer);
    sayBattleAndGame($joinMsg);
    $autohost->sendChatMessage("/adduser $joiningPlayer $inGameAddedUsers{$joiningPlayer} 0 $joinedId");
    return "joinAs $joinedEntity $joiningPlayer";
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
  if(! @{$p_kickBannedUsers} && $lobbyState > 5 && %{$lobby->{battle}}) {
    my @players=keys(%{$lobby->{battle}->{users}});
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

  return "kickBan $bannedUser" if($checkOnly);

  if($autohost->getState()) {
    my $p_ahPlayers=$autohost->getPlayersByNames();
    if(exists $p_ahPlayers->{$bannedUser} && %{$p_ahPlayers->{$bannedUser}} && $p_ahPlayers->{$bannedUser}->{disconnectCause} == -1) {
      $autohost->sendChatMessage("/kickbynum $p_ahPlayers->{$bannedUser}->{playerNb}");
    }
  }

  if($lobbyState > 5 && %{$lobby->{battle}}) {
    if(exists $lobby->{battle}->{users}->{$bannedUser}) {
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
  return "kickBan $bannedUser";
}

sub hLearnMaps {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 1) {
    invalidSyntax($user,"learnmaps");
    return 0;
  }

  if($lobbyState < 4) {
    answer("Unable to learn map hashes: not connected to lobby");
    return 0;
  }

  my ($mapFilter,$hostFilter)=@{$p_params};
  $mapFilter//='';
  $mapFilter='' if($mapFilter eq '.');
  $hostFilter//='';

  my %seenMaps;
  foreach my $bId (keys %{$lobby->{battles}}) {
    my $founder=$lobby->{battles}->{$bId}->{founder};
    my $map=$lobby->{battles}->{$bId}->{map};
    if(($mapFilter eq '' || index(lc($map),lc($mapFilter)) > -1)
       && ($hostFilter eq '' || index(lc($founder),lc($hostFilter)) > -1)
       && $founder ne $conf{lobbyLogin} && $lobby->{battles}->{$bId}->{mapHash} != 0) {
      my ($engineName,$engineVersion)=($lobby->{battles}->{$bId}->{engineName},$lobby->{battles}->{$bId}->{engineVersion});
      my $quotedVer=quotemeta($syncedSpringVersion);
      if($engineName !~ /^spring$/i || $engineVersion !~ /^$quotedVer(\..*)?$/) {
        slog("Ignoring battle $bId for learnMaps (different game engine: \"$engineName $engineVersion\")",5);
        next;
      }
      if(exists $seenMaps{$map} && $seenMaps{$map} ne $lobby->{battles}->{$bId}->{mapHash}) {
        slog("Map \"$map\" has been seen with different hashes ($seenMaps{$map} and $lobby->{battles}->{$bId}->{mapHash}) during map hash learning",2);
      }else{
        $seenMaps{$map}=$lobby->{battles}->{$bId}->{mapHash};
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
      }elsif(any {$preset eq $_} @{$spads->{values}->{preset}}) {
        $presetString="[ ] ";
      }
      $presetString.=$B if($preset eq $conf{defaultPreset});
      $presetString.=$preset;
      $presetString.=" ($spads->{presets}->{$preset}->{description}->[0])" if(exists $spads->{presets}->{$preset}->{description});
      $presetString.=" $B*** DEFAULT ***" if($preset eq $conf{defaultPreset});
      sayPrivate($user,$presetString);
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
      }elsif(any {$bPreset eq $_} @{$spads->{values}->{battlePreset}}) {
        $presetString="[ ] ";
      }
      $presetString.=$bPreset;
      $presetString.=" ($spads->{bPresets}->{$bPreset}->{description}->[0])" if(exists $spads->{bPresets}->{$bPreset}->{description});
      sayPrivate($user,$presetString);
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
      }elsif(any {$hPreset eq $_} @{$spads->{values}->{hostingPreset}}) {
        $presetString="[ ] ";
      }
      $presetString.=$hPreset;
      $presetString.=" ($spads->{hPresets}->{$hPreset}->{description}->[0])" if(exists $spads->{hPresets}->{$hPreset}->{description});
      sayPrivate($user,$presetString);
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
      my $p_values=$spads->{pluginsConf}->{$pluginName}->{values};
      foreach my $setting (sort keys %{$p_values}) {
        next if(any {$setting eq $_} qw'commandsFile helpFile');
        next if($filterUnmodifiableSettings && $#{$p_values->{$setting}} < 1);
        next unless(all {index(lc("$pluginName $setting"),lc($_)) > -1} @filters);
        my $allowedValues=join(" | ",@{$p_values->{$setting}});
        my $currentVal=$spads->{pluginsConf}->{$pluginName}->{conf}->{$setting};
        my ($coloredSetting,$coloredValue)=($setting,$currentVal);
        if($#{$p_values->{$setting}} < 1) {
          $coloredSetting=$C{14}.$setting;
        }else{
          if($currentVal ne $p_values->{$setting}->[0]) {
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
      next if(any {$setting eq $_} qw'description commandsFile battlePreset hostingPreset welcomeMsg welcomeMsgInGame preset mapLink ghostMapLink advertMsg endGameCommand endGameCommandEnv endGameCommandMsg');
      next if($filterUnmodifiableSettings && $#{$spads->{values}->{$setting}} < 1 && $setting ne 'map');
      next unless(all {index(lc($setting),lc($_)) > -1} @filters);
      my $allowedValues=join(" | ",@{$spads->{values}->{$setting}});
      my ($coloredSetting,$coloredValue)=($setting,$conf{$setting});
      if($#{$spads->{values}->{$setting}} < 1 && $setting ne 'map') {
        $coloredSetting=$C{14}.$setting;
      }else{
        if($conf{$setting} ne $spads->{values}->{$setting}->[0]) {
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
    my $modName=$targetMod;
    $modName=$lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod} if($lobbyState >= 6);
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
      if(exists $spads->{bSettings}->{$setting}) {
        $currentValue=$spads->{bSettings}->{$setting};
      }else{
        $currentValue=$p_options->{$setting}->{default};
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
      next if(any {$setting eq $_} qw'description battleName');
      next if($filterUnmodifiableSettings && $#{$spads->{hValues}->{$setting}} < 1);
      next unless(all {index(lc($setting),lc($_)) > -1} @filters);
      if($setting eq 'password') {
        push(@settingsData,{"$C{5}Name$C{1}" => ($#{$spads->{hValues}->{password}} < 1 ? $C{14} : '').'password',
                            "$C{5}Current value$C{1}" => '<hidden>',
                            "$C{5}Allowed values$C{1}" => '<hidden>'});
      }else{
        my $settingValue=$spads->{hSettings}->{$setting};
        $settingValue=$targetMod if($setting eq 'modName');
        my $allowedValues=join(" | ",@{$spads->{hValues}->{$setting}});
        my ($coloredSetting,$coloredValue)=($setting,$settingValue);
        if($#{$spads->{hValues}->{$setting}} < 1) {
          $coloredSetting=$C{14}.$setting;
        }else{
          if($settingValue ne $spads->{hValues}->{$setting}->[0] && $setting ne 'modName') {
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
    my $p_globalBans=$spads->{banLists}->{""};
    my $p_specificBans=[];
    $p_specificBans=$spads->{banLists}->{$conf{banList}} if($conf{banList});
    my $p_autoHandledBans=$spads->getDynamicBans();
    if(! @{$p_globalBans} && ! @{$p_specificBans} && ! @{$p_autoHandledBans}) {
      sayPrivate($user,"There is no ban entry currently");
    }else{
      my $userLevel=getUserAccessLevel($user);
      my $showIPs = $userLevel >= $conf{minLevelForIpAddr};
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
      my $mapName=$spads->{maps}->{$mapNb};
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
  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
    answer("Unable to load start boxes, battle lobby is closed");
    return 0;
  }
  if($spads->{bSettings}->{startpostype} != 2) {
    answer("Unable to load start boxes, start position type must be set to \"Choose in game\" (\"!bSet startPosType 2\")");
    return 0;
  }

  my @params;
  my $paramsString=join(' ',@{$p_params});
  @params=shellwords($paramsString) if($paramsString);

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

  foreach my $teamNb (keys %{$lobby->{battle}->{startRects}}) {
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
  if($lobbyState < 6) {
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
  my @clients=keys %{$lobby->{battle}->{users}};
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
  $mapHash+=$MAX_UNSIGNEDINTEGER if($mapHash < 0);

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
  if($lobbyState < 6) {
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
  if($lobbyState < 6) {
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

  if($lobbyState >= 6 && ! $closeBattleAfterGame) {
    answer("Unable to open battle lobby, it is already opened");
    return 0;
  }
  if($#{$p_params} != -1) {
    invalidSyntax($user,"openbattle");
    return 0;
  }
  return 1 if($checkOnly);
  cancelCloseBattleAfterGame();
}

sub hPlugin {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my ($pluginName,$action,$param,@vals)=@{$p_params};
  if(! defined $action) {
    invalidSyntax($user,'plugin');
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
    my $loadRes=loadPlugin($pluginName);
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
    my $p_unloadedPlugins=unloadPlugin($pluginName);
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
    if(defined $param && lc($param) ne 'keepsettings') {
      invalidSyntax($user,'plugin');
      return 0;
    }
    return 1 if($checkOnly);
    my $p_previousConf;
    $p_previousConf=$spads->{pluginsConf}->{$pluginName}->{conf} if(exists $spads->{pluginsConf}->{$pluginName} && defined $param);
    if(! $spads->loadPluginConf($pluginName)) {
      answer("Failed to reload $pluginName plugin configuration.");
      return 0;
    }
    $spads->applyPluginPreset($pluginName,$conf{defaultPreset});
    $spads->applyPluginPreset($pluginName,$conf{preset}) unless($conf{preset} eq $conf{defaultPreset});
    $spads->{pluginsConf}->{$pluginName}->{conf}=$p_previousConf if(exists $spads->{pluginsConf}->{$pluginName} && defined $p_previousConf);
    if($plugins{$pluginName}->can('onReloadConf')) {
      my $reloadConfRes=$plugins{$pluginName}->onReloadConf(defined $param);
      if(defined $reloadConfRes && ! $reloadConfRes) {
        answer("Failed to reload $pluginName plugin configuration.");
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
    if(! exists $spads->{pluginsConf}->{$pluginName}) {
      answer("Plugin $pluginName has no modifiable configuration parameters.");
      return 0;
    }
    my $p_pluginConf=$spads->{pluginsConf}->{$pluginName};

    my $setting;
    foreach my $pluginSetting (keys %{$p_pluginConf->{values}}) {
      next if(any {$pluginSetting eq $_} qw'commandsFile helpFile');
      if(lc($param) eq lc($pluginSetting)) {
        $setting=$pluginSetting;
        last;
      }
    }
    if(! defined $setting) {
      answer("\"$param\" is not a valid setting for plugin \"$pluginName\".");
      return 0;
    }

    my $val='';
    $val=join(' ',@vals) if(@vals);

    my $allowed=0;
    foreach my $allowedValue (@{$p_pluginConf->{values}->{$setting}}) {
      if(isRange($allowedValue)) {
        $allowed=1 if(matchRange($allowedValue,$val));
      }elsif($val eq $allowedValue) {
        $allowed=1;
      }
      last if($allowed);
    }
    if($allowed) {
      if($p_pluginConf->{conf}->{$setting} eq $val) {
        answer("$pluginName plugin setting \"$setting\" is already set to value \"$val\".");
        return 0;
      }
      return 1 if($checkOnly);
      my $oldValue=$p_pluginConf->{conf}->{$setting};
      $p_pluginConf->{conf}->{$setting}=$val;
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

sub hPass {
  my ($source,$user,$p_params,$checkOnly)=@_;

  return 0 if($checkOnly);

  if($#{$p_params} != -1) {
    invalidSyntax($user,"pass");
    return 0;
  }

  if(! exists $lobby->{users}->{$user}) {
    answer("You must be connected to lobby server to receive the password in private message");
    return 0;
  }

  if($conf{minRankForPasswd} && $lobby->{users}->{$user}->{status}->{rank} < $conf{minRankForPasswd}) {
    answer("Sorry, your rank is below the rank limit for password");
    return 0;
  }
  if($conf{minLevelForPasswd}) {
    my $level=getUserAccessLevel($user);
    if($level < $conf{minLevelForPasswd}) {
      answer("Sorry, your access level is below the limit for password");
      return 0;
    }
  }
  my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
  if($p_ban->{banType} < 2) {
    answer("Sorry, you are banned");
    return 0;
  }

  sayPrivate($user,"Battle pasword: \"$spads->{hSettings}->{password}\"");

}

sub hPreset {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} != 0) {
    invalidSyntax($user,"preset");
    return 0;
  }

  my ($preset)=@{$p_params};

  if(! exists $spads->{presets}->{$preset}) {
    answer("\"$preset\" is not a valid preset (use \"!list presets\" to list available presets)");
    return 0;
  }

  if(none {$preset eq $_} @{$spads->{values}->{preset}}) {
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

  if($lobbyState < 6) {
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

  return 1 if($checkOnly);

  $timestamps{promote}=time;
  my $promoteMsg=$conf{promoteMsg};
  my %hSettings=%{$spads->{hSettings}};
  my $neededPlayer="";
  if($conf{autoLock} ne "off" || $conf{autoSpecExtraPlayers} || $conf{autoStart} ne "off") {
    my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
    my $nbPlayers=0;
    foreach my $player (keys %{$lobby->{battle}->{users}}) {
      $nbPlayers++ if(defined $lobby->{battle}->{users}->{$player}->{battleStatus} && $lobby->{battle}->{users}->{$player}->{battleStatus}->{mode});
    }
    my @bots=keys %{$lobby->{battle}->{bots}};
    $nbPlayers+=$#bots+1 if($conf{nbTeams} != 1);
    $neededPlayer=($targetNbPlayers-$nbPlayers)." " if($targetNbPlayers > $nbPlayers);
  }
  $promoteMsg=~s/\%u/$user/g;
  $promoteMsg=~s/\%p/$neededPlayer/g;
  $promoteMsg=~s/\%b/$hSettings{battleName}/g;
  $promoteMsg=~s/\%o/$targetMod/g;
  $promoteMsg=~s/\%a/$conf{map}/g;
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
        if($lobbyState > 5 && %{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$user}
           && defined $lobby->{battle}->{users}->{$user}->{battleStatus} && $lobby->{battle}->{users}->{$user}->{battleStatus}->{mode}) {
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
        if($lobbyState > 5 && %{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$user}
           && defined $lobby->{battle}->{users}->{$user}->{battleStatus} && $lobby->{battle}->{users}->{$user}->{battleStatus}->{mode}) {
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

  if($waitMode eq 'game') {
    quitAfterGame("requested by $user in $sourceNames{$source}");
  }elsif($waitMode eq 'spec') {
    quitWhenOnlySpec("requested by $user in $sourceNames{$source}");
  }else{
    quitWhenEmpty("requested by $user in $sourceNames{$source}");
  }
}

sub hRebalance {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($lobbyState < 6) {
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

  if($#{$p_params} != -1) {
    invalidSyntax($user,"reloadarchives");
    return 0;
  }

  return 1 if($checkOnly);

  my $nbArchives=loadArchives(1);
  quitAfterGame("Unable to reload Spring archives") unless($nbArchives);

  answer("$nbArchives Spring archives loaded");
}

sub hReloadConf {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $keepSettings=0;
  my %confMacrosReload=%confMacros;
  my $p_macrosUsedForReload=\%confMacrosReload;

  my $paramsString=join(" ",@{$p_params});
  if($paramsString) {
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

      return 1 if($checkOnly);

      foreach my $macroName (keys %{$p_macroDataReload}) {
        $p_macrosUsedForReload->{$macroName}=$p_macroDataReload->{$macroName};
      }
    }
  }

  return 1 if($checkOnly);

  pingIfNeeded();
  $spads->dumpDynamicData();
  $timestamps{dataDump}=time;

  chdir($cwd);
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

  foreach my $pluginName (keys %{$spads->{pluginsConf}}) {
    $newSpads->{pluginsConf}->{$pluginName}=$spads->{pluginsConf}->{$pluginName} unless(exists $newSpads->{pluginsConf}->{$pluginName});
  }

  $spads=$newSpads;

  if(! $keepSettings) {
    %conf=%{$spads->{conf}};

    $lobbySimpleLog->setLevels([$conf{lobbyInterfaceLogLevel}]);
    $autohostSimpleLog->setLevels([$conf{autoHostInterfaceLogLevel}]);
    $updaterSimpleLog->setLevels([$conf{updaterLogLevel},3]);
    $sLog->setLevels([$conf{spadsLogLevel},3]);

    quitAfterGame("Unable to reload Spring archives") unless(loadArchives());
    setDefaultMapOfMaplist() if($spads->{conf}->{map} eq '');

    applyAllSettings();
  }

  foreach my $pluginName (@pluginsOrder) {
    if($plugins{$pluginName}->can('onReloadConf')) {
      my $reloadConfRes=$plugins{$pluginName}->onReloadConf($keepSettings);
      answer("Unable to reload $pluginName plugin configuration.") if(defined $reloadConfRes && ! $reloadConfRes);
    }
  }

  my $msg="Spads configuration reloaded";
  $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
  answer($msg);
}

sub hRehost {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != -1) {
    invalidSyntax($user,"rehost");
    return 0;
  }
  if($lobbyState < 6) {
    answer("Unable to rehost battle, battle is closed");
    return 0;
  }
  return 1 if($checkOnly);

  my %sourceNames = ( pv => "private",
                      chan => "channel #$masterChannel",
                      game => "game",
                      battle => "battle lobby" );

  rehostAfterGame("requested by $user in $sourceNames{$source}");
}

sub hRemoveBot {
  my ($source,$user,$p_params,$checkOnly)=@_;
  if($#{$p_params} != 0) {
    invalidSyntax($user,'removebot');
    return 0;
  }
  if($lobbyState < 6) {
    answer("Unable to remove AI bot, battle lobby is closed");
    return 0;
  }

  my @localBots;
  my @bots=keys %{$lobby->{battle}->{bots}};
  foreach my $bot (@bots) {
    push(@localBots,$bot) if($lobby->{battle}->{bots}->{$bot}->{owner} eq $conf{lobbyLogin});
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
  
  return "removeBot $p_removedBots->[0]" if($checkOnly);

  sayBattle("Removing local AI bot $p_removedBots->[0] (by $user)");
  queueLobbyCommand(['REMOVEBOT',$p_removedBots->[0]]);

  return "removeBot $p_removedBots->[0]";
}

sub hRestart {
  my ($source,$user,$p_params,$checkOnly)=@_;

  my $waitMode='game';

  my $paramsString=join(' ',@{$p_params});
  if($paramsString) {
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

  if($waitMode eq 'game') {
    restartAfterGame("requested by $user in $sourceNames{$source}");
  }elsif($waitMode eq 'spec') {
    restartWhenOnlySpec("requested by $user in $sourceNames{$source}");
  }else{
    restartWhenEmpty("requested by $user in $sourceNames{$source}");
  }

}

sub hRing {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 0) {
    invalidSyntax($user,"ring");
    return 0;
  }

  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
    answer("Unable to ring, battle is closed");
    return 0;
  }

  my @players=keys(%{$lobby->{battle}->{users}});
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
    return "ring $rungUser" if($checkOnly);
    sayBattleAndGame("Ringing $rungUser (by $user)");
    $lastRungUsers{$rungUser}=time;
    queueLobbyCommand(["RING",$rungUser]);
    return "ring $rungUser";
  }

  my @rungUsers;
  my @alreadyRungUsers;
  my $ringType='unready/unsynced player';

  my $p_bUsers=$lobby->{battle}->{users};
  if($autohost->getState() == 1) {
    foreach my $gUserNb (keys %{$autohost->{players}}) {
      my $player=$autohost->{players}->{$gUserNb}->{name};
      my $minRingDelay=getUserPref($player,"minRingDelay");
      if(exists $currentVote{command}) {
        $ringType='remaining voter';
        if(exists $currentVote{remainingVoters}->{$player}) {
          if(exists $lastRungUsers{$player} && time - $lastRungUsers{$player} < $minRingDelay) {
            push(@alreadyRungUsers,$player);
          }else{
            push(@rungUsers,$player);
          }
        }
      }else{
        $ringType='unready player';
        if($autohost->{players}->{$gUserNb}->{ready} != 1
           && exists $p_bUsers->{$player}
           && exists $p_runningBattle->{users}->{$player}
           && (! defined $p_runningBattle->{users}->{$player}->{battleStatus} 
               || $p_runningBattle->{users}->{$player}->{battleStatus}->{mode})) {
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
        if(exists $currentVote{remainingVoters}->{$bUser}) {
          if(exists $lastRungUsers{$bUser} && time - $lastRungUsers{$bUser} < $minRingDelay) {
            push(@alreadyRungUsers,$bUser);
          }else{
            push(@rungUsers,$bUser);
          }
        }
      }else{
        if(! defined $p_bUsers->{$bUser}->{battleStatus}
           || ($p_bUsers->{$bUser}->{battleStatus}->{mode}
               && (! $p_bUsers->{$bUser}->{battleStatus}->{ready} || $p_bUsers->{$bUser}->{battleStatus}->{sync} != 1))) {
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
      queueLobbyCommand(["RING",$rungUser]);
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

  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
    answer("Unable to save start boxes, battle is closed");
    return 0;
  }

  my $p_startRects=$lobby->{battle}->{startRects};
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

  return 1 if($checkOnly);

  my $msg=join(" ",@{$p_params});
  my $prompt="<$user> ";
  my $p_messages=splitMsg($msg,$conf{maxAutoHostMsgLength}-length($prompt)-1);
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
    if(getUserAccessLevel($user) < $conf{minLevelForIpAddr}) {
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
          $online=exists $lobby->{accounts}->{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}->{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}CPU$C{1}" => $p_accountMainData->{cpu},
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
      my @sortedMatches=sort {$p_matchingIds->{$b}->{timestamp} <=> $p_matchingIds->{$a}->{timestamp}} (keys %{$p_matchingIds});
      foreach my $id (@sortedMatches) {
        my $p_accountMainData=$spads->getAccountMainData($id);
        my $p_accountNames=$spads->getAccountNamesTs($id);
        my $D = time-$p_accountMainData->{timestamp} > 1209600 ? $C{14} : $C{1};
        my @idIps=sort {$p_matchingIds->{$id}->{ips}->{$b} <=> $p_matchingIds->{$id}->{ips}->{$a}} (keys %{$p_matchingIds->{$id}->{ips}});
        my $ips=formatList(\@idIps,40);
        my @idNames=sort {$p_accountNames->{$b} <=> $p_accountNames->{$a}} (keys %{$p_accountNames});
        my $names=formatList(\@idNames,40);
        my ($idOnly,$idName)=($id,undef);
        ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);
        my $online;
        if($idOnly) {
          $online=exists $lobby->{accounts}->{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}->{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}CPU$C{1}" => $p_accountMainData->{cpu},
                                "$C{5}Rank$C{1}" => $ranks[abs($p_accountMainData->{rank})].$D,
                                "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_accountMainData->{timestamp}),
                                "$C{5}Matching IP(s)$C{1}" => $ips});
      }
    }
    @resultFields=("$C{5}ID$C{1}","$C{5}Name(s)$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}CPU$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}","$C{5}Matching IP(s)$C{1}");
  }else{
    my $p_matchingIds;
    ($p_matchingIds,$nbMatchingId)=$spads->searchUserIds($search);
    if($spads->isStoredUser($search)) {
      my $p_userIds=$spads->getUserIds($search);
      my @sortedMatches=sort {$p_matchingIds->{$b}->{names}->{$search} <=> $p_matchingIds->{$a}->{names}->{$search}} (@{$p_userIds});
      foreach my $id (@sortedMatches) {
        my $p_accountMainData=$spads->getAccountMainData($id);
        my $p_accountIps=$spads->getAccountIpsTs($id);
        my $D = time-$p_accountMainData->{timestamp} > 1209600 ? $C{14} : $C{1};
        my @idNames=sort {$p_matchingIds->{$id}->{names}->{$b} <=> $p_matchingIds->{$id}->{names}->{$a}} (keys %{$p_matchingIds->{$id}->{names}});
        my $names=formatList(\@idNames,40);
        my @idIps=sort {$p_accountIps->{$b} <=> $p_accountIps->{$a}} (keys %{$p_accountIps});
        my $ips=formatList(\@idIps,40);
        my ($idOnly,$idName)=($id,undef);
        ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);
        my $online;
        if($idOnly) {
          $online=exists $lobby->{accounts}->{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}->{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Matching name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}CPU$C{1}" => $p_accountMainData->{cpu},
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
      my @sortedMatches=sort {$p_matchingIds->{$b}->{timestamp} <=> $p_matchingIds->{$a}->{timestamp}} (keys %{$p_matchingIds});
      foreach my $id (@sortedMatches) {
        my $p_accountMainData=$spads->getAccountMainData($id);
        my $p_accountIps=$spads->getAccountIpsTs($id);
        my $D = time-$p_accountMainData->{timestamp} > 1209600 ? $C{14} : $C{1};
        my @idNames=sort {$p_matchingIds->{$id}->{names}->{$b} <=> $p_matchingIds->{$id}->{names}->{$a}} (keys %{$p_matchingIds->{$id}->{names}});
        my $names=formatList(\@idNames,40);
        my @idIps=sort {$p_accountIps->{$b} <=> $p_accountIps->{$a}} (keys %{$p_accountIps});
        my $ips=formatList(\@idIps,40);
        my ($idOnly,$idName)=($id,undef);
        ($idOnly,$idName)=(0,$1) if($id =~ /^0\(([^\)]+)\)$/);
        my $online;
        if($idOnly) {
          $online=exists $lobby->{accounts}->{$idOnly} ? "$C{3}Yes" : "$C{4}No";
        }else{
          $online=exists $lobby->{users}->{$idName} ? "$C{3}Yes" : "$C{4}No";
        }
        push(@matchingAccounts,{"$C{5}ID$C{1}" => $D.$idOnly,
                                "$C{5}Matching name(s)$C{1}" => $names,
                                "$C{5}Online$C{1}" => $online.$D,
                                "$C{5}Country$C{1}" => $p_accountMainData->{country},
                                "$C{5}CPU$C{1}" => $p_accountMainData->{cpu},
                                "$C{5}Rank$C{1}" => $ranks[abs($p_accountMainData->{rank})].$D,
                                "$C{5}LastUpdate$C{1}" => secToDayAge(time-$p_accountMainData->{timestamp}),
                                "$C{5}IP(s)$C{1}" => $ips});
      }
    }
    @resultFields=("$C{5}ID$C{1}","$C{5}Matching name(s)$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}CPU$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}");
    push(@resultFields,"$C{5}IP(s)$C{1}") if(getUserAccessLevel($user) >= $conf{minLevelForIpAddr});
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

  my $params=join(" ",@{$p_params});
  $autohost->sendChatMessage($params);
  logMsg("game","> $params") if($conf{logGameChat});

  return 1;
}

sub hSendLobby {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} < 0) {
    invalidSyntax($user,"sendlobby");
    return 0;
  }

  if($lobbyState < 4) {
    answer("Unable to send data to lobby server, not connected");
    return 0;
  }

  return 1 if($checkOnly);

  sendLobbyCommand([$p_params]);

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

  my ($setting,@vals)=@{$p_params};
  my $val=join(" ",@vals);
  $setting=lc($setting);

  if($setting eq "map") {
    if($val eq '' && $lobbyState > 5) {
      return 'nextMap' if($checkOnly);
      rotateMap($conf{rotationManual},1);
      return 'nextMap';
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
    return "set map $realVal" if($checkOnly);
    $spads->{conf}->{map}=$realVal;
    %conf=%{$spads->{conf}};
    $timestamps{autoRestore}=time;
    applySettingChange("map");
    my $msg="Map changed by $user: $realVal";
    if($conf{autoLoadMapPreset}) {
      my $smfMapName=$conf{map};
      $smfMapName.='.smf' unless($smfMapName =~ /\.smf$/);
      if(exists $spads->{presets}->{$smfMapName}) {
        applyPreset($smfMapName);
        $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
      }elsif(exists $spads->{presets}->{"_DEFAULT_.smf"}) {
        applyPreset("_DEFAULT_.smf");
        $msg.=" (some pending settings need rehosting to be applied)" if(needRehost());
      }
    }
    sayBattleAndGame($msg);
    answer("Map changed: $realVal") if($source eq "pv");
    return "set map $realVal";
  }

  foreach my $param (keys %{$spads->{values}}) {
    next if(any {$param eq $_} qw'description commandsFile battlePreset hostingPreset welcomeMsg welcomeMsgInGame mapLink ghostMapLink preset advertMsg endGameCommand endGameCommandEnv endGameCommandMsg');
    if($setting eq lc($param)) {
      my $allowed=0;
      foreach my $allowedValue (@{$spads->{values}->{$param}}) {
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
        $spads->{conf}->{$param}=$val;
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
  
  if($#{$p_params} > 1 || ($#{$p_params} == 1 && $p_params->[1] !~ /^all$/i)) {
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

    my $full=0;
    $full=1 if($#{$p_params} == 1);
    
    my ($rc,$p_smurfsData,$p_probableSmurfs,$p_otherCandidates)=getSmurfsData($smurfUser,$full,$p_C);
    
    if(@{$p_smurfsData}) {
      my @resultFields=("$C{5}ID$C{1}","$C{5}Name(s)$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}CPU$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}","$C{5}Confidence$C{1}");
      push(@resultFields,"$C{5}IP(s)$C{1}") if(getUserAccessLevel($user) >= $conf{minLevelForIpAddr});
      my $p_resultLines=formatArray(\@resultFields,$p_smurfsData);
      foreach my $resultLine (@{$p_resultLines}) {
        sayPrivate($user,$resultLine);
      }
      if(@{$p_probableSmurfs} || @{$p_otherCandidates}) {
        sayPrivate($user,"Too many results (only the 40 first accounts are shown above)");
        if(@{$p_probableSmurfs}) {
          sayPrivate($user,"Other probable smurfs:");
          sayPrivate($user,"  ".join(' ',@{$p_probableSmurfs}));
        }
        if(@{$p_otherCandidates}) {
          sayPrivate($user,"Other smurf candidates:");
          sayPrivate($user,"  $C{14}".join(' ',@{$p_otherCandidates}));
        }
      }
    }

    sayPrivate($user,"Unable to perform IP-based smurf detection for $C{12}$smurfUser$C{1} (IP unknown)") if($rc == 2);

  }else{

    if($lobbyState < 6 || ! %{$lobby->{battle}}) {
      answer("Unable to perform smurf detection in battle, battle lobby is closed");
      return 0;
    }
    my @smurfUsers=keys(%{$lobby->{battle}->{users}});
    if($#smurfUsers < 1) {
      answer("Unable to perform smurf detection in battle, battle lobby is empty");
      return 0;
    }
    return 1 if($checkOnly);
    my @results;
    foreach my $smurfUser (@smurfUsers) {
      next if($smurfUser eq $conf{lobbyLogin});
      my %result=("$C{5}Player$C{1}" => $C{10}.$smurfUser.$C{1}, "$C{5}Smurfs$C{1}" => '');
      my (undef,$p_smurfsData)=getSmurfsData($smurfUser,0,\%noColor);
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
  if($lobbyState < 6) {
    answer("Unable to split map, battle lobby is closed");
    return 0;
  }
  if($spads->{bSettings}->{startpostype} != 2) {
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

  
  foreach my $teamNb (keys %{$lobby->{battle}->{startRects}}) {
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
  if($lobbyState < 6 || ! %{$lobby->{battle}}) {
    answer("Unable to spec unready AFK players, battle is closed");
    return 0;
  }

  if($springPid || $autohost->getState()) {
    answer("Unable to spec unready AFK players, game is running");
    return 0;
  }

  my @unreadyAfkPlayers;
  my $p_bUsers=$lobby->{battle}->{users};
  foreach my $bUser (keys %{$p_bUsers}) {
    next unless(defined $p_bUsers->{$bUser}->{battleStatus});
    push(@unreadyAfkPlayers,$bUser) if($p_bUsers->{$bUser}->{battleStatus}->{mode}
                                       && $lobby->{users}->{$bUser}->{status}->{away}
                                       && ! $p_bUsers->{$bUser}->{battleStatus}->{ready});
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

  if($lobbyState != 6) {
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

  my @sortedNames=sort {$teamStats{$b}->{damageDealt} <=> $teamStats{$a}->{damageDealt}} (keys %teamStats);
  my ($totalDamageDealt,$totalDamageReceived,$totalUnitsProduced,$totalUnitsKilled,$totalMetalProduced,$totalMetalUsed,$totalEnergyProduced,$totalEnergyUsed)=(0,0,0,0,0,0,0,0);
  foreach my $name (@sortedNames) {
    $totalDamageDealt+=$teamStats{$name}->{damageDealt};
    $totalDamageReceived+=$teamStats{$name}->{damageReceived};
    $totalUnitsProduced+=$teamStats{$name}->{unitsProduced};
    $totalUnitsKilled+=$teamStats{$name}->{unitsKilled};
    $totalMetalProduced+=$teamStats{$name}->{metalProduced};
    $totalMetalUsed+=$teamStats{$name}->{metalUsed};
    $totalEnergyProduced+=$teamStats{$name}->{energyProduced};
    $totalEnergyUsed+=$teamStats{$name}->{energyUsed};
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
                 "$C{5}Team$C{1}" => $teamStats{$name}->{allyTeam},
                 "$C{5}DamageDealt$C{1}" => formatInteger(int($teamStats{$name}->{damageDealt})).' ('.int($teamStats{$name}->{damageDealt}/$totalDamageDealt*100+0.5).'%)',
                 "$C{5}DamageRec.$C{1}" => formatInteger(int($teamStats{$name}->{damageReceived})).' ('.int($teamStats{$name}->{damageReceived}/$totalDamageReceived*100+0.5).'%)',
                 "$C{5}UnitsProd.$C{1}" => formatInteger(int($teamStats{$name}->{unitsProduced})).' ('.int($teamStats{$name}->{unitsProduced}/$totalUnitsProduced*100+0.5).'%)',
                 "$C{5}UnitsKilled$C{1}" => formatInteger(int($teamStats{$name}->{unitsKilled})).' ('.int($teamStats{$name}->{unitsKilled}/$totalUnitsKilled*100+0.5).'%)',
                 "$C{5}MetalProd.$C{1}" => formatInteger(int($teamStats{$name}->{metalProduced})).' ('.int($teamStats{$name}->{metalProduced}/$totalMetalProduced*100+0.5).'%)',
                 "$C{5}MetalUsed$C{1}" => formatInteger(int($teamStats{$name}->{metalUsed})).' ('.int($teamStats{$name}->{metalUsed}/$totalMetalUsed*100+0.5).'%)',
                 "$C{5}EnergyProd.$C{1}" => formatInteger(int($teamStats{$name}->{energyProduced})).' ('.int($teamStats{$name}->{energyProduced}/$totalEnergyProduced*100+0.5).'%)',
                 "$C{5}EnergyUsed$C{1}" => formatInteger(int($teamStats{$name}->{energyUsed})).' ('.int($teamStats{$name}->{energyUsed}/$totalEnergyUsed*100+0.5).'%)'});
  }
  
  my $p_statsLines=formatArray(["$C{5}Name$C{1}","$C{5}Team$C{1}","$C{5}DamageDealt$C{1}","$C{5}DamageRec.$C{1}","$C{5}UnitsProd.$C{1}","$C{5}UnitsKilled$C{1}","$C{5}MetalProd.$C{1}","$C{5}MetalUsed$C{1}","$C{5}EnergyProd.$C{1}","$C{5}EnergyUsed$C{1}"],\@stats,"$C{2}Game statistics$C{1}");
  foreach my $statsLine (@{$p_statsLines}) {
    sayPrivate($user,$statsLine);
  }
}

sub getRoundedSkill {
  my $skill=shift;
  my ($roundedSkill,$deviation);
  foreach my $rank (sort {$b <=> $a} keys %rankSkill) {
    if(! defined $roundedSkill || abs($skill-$rankSkill{$rank}) < $deviation) {
      $roundedSkill=$rankSkill{$rank};
      $deviation=abs($skill-$roundedSkill);
      next;
    }
    last;
  }
  return $roundedSkill;
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
    if($lobbyState < 6 || ! %{$lobby->{battle}}) {
      answer("Unable to retrieve battle status, battle is closed");
      return 0;
    }
  }else{
    invalidSyntax($user,"status");
    return 0;
  }
  return 1 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  if($p_params->[0] eq "game") {
    my @spectators;
    my %runningBattleStatus;
    my @clientsStatus;
    my $startPosType=2;
    $startPosType=$p_runningBattle->{scriptTags}->{"game/startpostype"} if(exists($p_runningBattle->{scriptTags}->{"game/startpostype"}));
    my $ahState=$autohost->getState();
    foreach my $player (keys %{$p_runningBattle->{users}}) {
      if(defined $p_runningBattle->{users}->{$player}->{battleStatus} && $p_runningBattle->{users}->{$player}->{battleStatus}->{mode}) {
        my $playerTeam=$p_runningBattle->{users}->{$player}->{battleStatus}->{team};
        my $playerId=$p_runningBattle->{users}->{$player}->{battleStatus}->{id};
        $runningBattleStatus{$playerTeam}={} unless(exists $runningBattleStatus{$playerTeam});
        $runningBattleStatus{$playerTeam}->{$playerId}=[] unless(exists $runningBattleStatus{$playerTeam}->{$playerId});
        push(@{$runningBattleStatus{$playerTeam}->{$playerId}},$player);
      }else{
        push(@spectators,$player) unless($springServerType eq 'dedicated' && $player eq $conf{lobbyLogin});
      }
    }
    foreach my $bot (keys %{$p_runningBattle->{bots}}) {
      my $botTeam=$p_runningBattle->{bots}->{$bot}->{battleStatus}->{team};
      my $botId=$p_runningBattle->{bots}->{$bot}->{battleStatus}->{id};
      $runningBattleStatus{$botTeam}={} unless(exists $runningBattleStatus{$botTeam});
      $runningBattleStatus{$botTeam}->{$botId}=[] unless(exists $runningBattleStatus{$botTeam}->{$botId});
      push(@{$runningBattleStatus{$botTeam}->{$botId}},$bot." (bot)");
    }
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my @midGamePlayers=grep {! exists $p_runningBattle->{users}->{$_} && exists $inGameAddedPlayers{$_}} (keys %{$p_ahPlayers});
    my %midGamePlayersById;
    foreach my $midGamePlayer (@midGamePlayers) {
      $midGamePlayersById{$inGameAddedPlayers{$midGamePlayer}}=[] unless(exists $midGamePlayersById{$inGameAddedPlayers{$midGamePlayer}});
      push(@{$midGamePlayersById{$inGameAddedPlayers{$midGamePlayer}}},$midGamePlayer);
    }
    foreach my $teamNb (sort {$a <=> $b} keys %runningBattleStatus) {
      foreach my $idNb (sort {$a <=> $b} keys %{$runningBattleStatus{$teamNb}}) {
        my $internalIdNb=$runningBattleMapping{teams}->{$idNb};
        my @midGameIdPlayers;
        @midGameIdPlayers=@{$midGamePlayersById{$internalIdNb}} if(exists $midGamePlayersById{$internalIdNb});
        foreach my $player (sort (@{$runningBattleStatus{$teamNb}->{$idNb}},@midGameIdPlayers)) {
          my %clientStatus=("$C{5}Name$C{1}" => $player,
                            "$C{5}Team$C{1}" => $runningBattleMapping{allyTeams}->{$teamNb},
                            "$C{5}Id$C{1}" => $internalIdNb);
          if($player =~ /^(.+) \(bot\)$/) {
            my $botName=$1;
            $clientStatus{"$C{5}Version$C{1}"}="$p_runningBattle->{bots}->{$botName}->{aiDll} ($p_runningBattle->{bots}->{$botName}->{owner})";
          }else{
            $clientStatus{"$C{5}Name$C{1}"}="+ $player" unless(exists $p_runningBattle->{users}->{$player});
            $clientStatus{"$C{5}Status$C{1}"}="Not connected";
          }
          my $p_ahPlayer=$autohost->getPlayer($player);
          if(%{$p_ahPlayer}) {
            if($p_ahPlayer->{ready} == 0) {
              $clientStatus{"$C{5}Ready$C{1}"}="$C{7}Placed$C{1}";
            }elsif($p_ahPlayer->{ready} == 1) {
              $clientStatus{"$C{5}Ready$C{1}"}="$C{3}Yes$C{1}";
            }elsif($p_ahPlayer->{ready} == 2) {
              $clientStatus{"$C{5}Ready$C{1}"}="$C{4}No$C{1}";
            }else{
              $clientStatus{"$C{5}Ready$C{1}"}="!";
            }
            if($p_ahPlayer->{disconnectCause} == -2) {
              $clientStatus{"$C{5}Status$C{1}"}="$C{14}Loading$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == 0) {
              $clientStatus{"$C{5}Status$C{1}"}="$C{4}Timeouted$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == 1) {
              $clientStatus{"$C{5}Status$C{1}"}="$C{7}Disconnected$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == 2) {
              $clientStatus{"$C{5}Status$C{1}"}="$C{13}Kicked$C{1}";
            }elsif($p_ahPlayer->{disconnectCause} == -1) {
              if($p_ahPlayer->{lost} == 0) {
                if($ahState == 1) {
                  $clientStatus{"$C{5}Status$C{1}"}="$C{10}Waiting$C{1}";
                }else{
                  $clientStatus{"$C{5}Status$C{1}"}="$C{3}Playing$C{1}";
                }
              }else{
                $clientStatus{"$C{5}Status$C{1}"}="$C{12}Spectating$C{1}";
              }
            }else{
              $clientStatus{"$C{5}Status$C{1}"}="$C{6}Unknown$C{1}";
            }
            $clientStatus{"$C{5}Version$C{1}"}=$p_ahPlayer->{version};
            $clientStatus{"$C{5}IP$C{1}"}=$p_ahPlayer->{address};
            $clientStatus{"$C{5}IP$C{1}"}=$1 if($clientStatus{"$C{5}IP$C{1}"} =~ /^\[(?:::ffff:)?(\d+(?:\.\d+){3})\]:\d+$/);
          }
          push(@clientsStatus,\%clientStatus);
        }
      }
    }
    my @midGameSpecs=grep {! exists $p_runningBattle->{users}->{$_} && ! exists $inGameAddedPlayers{$_}} (keys %{$p_ahPlayers});
    foreach my $spec (sort (@spectators,@midGameSpecs)) {
      my %clientStatus=("$C{5}Name$C{1}" => $spec,
                        "$C{5}Status$C{1}" => "Not connected");
      $clientStatus{"$C{5}Name$C{1}"}="+ $spec" unless(exists $p_runningBattle->{users}->{$spec});
      my $p_ahPlayer=$autohost->getPlayer($spec);
      if(%{$p_ahPlayer}) {
        if($p_ahPlayer->{disconnectCause} == -2) {
          $clientStatus{"$C{5}Status$C{1}"}="$C{14}Loading$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == 0) {
          $clientStatus{"$C{5}Status$C{1}"}="$C{4}Timeouted$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == 1) {
          $clientStatus{"$C{5}Status$C{1}"}="$C{7}Disconnected$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == 2) {
          $clientStatus{"$C{5}Status$C{1}"}="$C{13}Kicked$C{1}";
        }elsif($p_ahPlayer->{disconnectCause} == -1) {
          $clientStatus{"$C{5}Status$C{1}"}="$C{12}Spectating$C{1}";
        }else{
          $clientStatus{"$C{5}Status$C{1}"}="$C{6}Unknown$C{1}";
        }
        $clientStatus{"$C{5}Version$C{1}"}=$p_ahPlayer->{version};
        $clientStatus{"$C{5}IP$C{1}"}=$p_ahPlayer->{address};
        $clientStatus{"$C{5}IP$C{1}"}=$1 if($clientStatus{"$C{5}IP$C{1}"} =~ /^\[(?:::ffff:)?(\d+(?:\.\d+){3})\]:\d+$/);
      }
      push(@clientsStatus,\%clientStatus) if(exists $p_runningBattle->{users}->{$spec} || (%{$p_ahPlayer} && $p_ahPlayer->{disconnectCause} < 0));
    }
    my @fields=("$C{5}Name$C{1}","$C{5}Team$C{1}","$C{5}Id$C{1}","$C{5}Ready$C{1}","$C{5}Status$C{1}","$C{5}Version$C{1}");
    @fields=("$C{5}Name$C{1}","$C{5}Team$C{1}","$C{5}Id$C{1}","$C{5}Status$C{1}","$C{5}Version$C{1}") if($startPosType != 2);
    push(@fields,"$C{5}IP$C{1}") if(getUserAccessLevel($user) >= $conf{minLevelForIpAddr});
    my $p_statusLines=formatArray(\@fields,\@clientsStatus);
    foreach my $statusLine (@{$p_statusLines}) {
      sayPrivate($user,$statusLine);
    }
    if($ahState == 1) {
      my $gameRunningTime=secToTime(time-$timestamps{lastGameStart});
      sayPrivate($user,"$B$C{10}Game state:$B$C{1} waiting for ready in game (since $gameRunningTime)");
    }else{
      my $gameRunningTime=secToTime(time-$timestamps{lastGameStartPlaying});
      sayPrivate($user,"$B$C{10}Game state:$B$C{1} running since $gameRunningTime");
    }
    sayPrivate($user,"$B$C{10}Map:$B$C{1} $p_runningBattle->{map}");
    sayPrivate($user,"$B$C{10}Mod:$B$C{1} $p_runningBattle->{mod}");
  }else{
    my @spectators;
    my %currentBattleStatus;
    my @clientsStatus;
    my $p_bUsers=$lobby->{battle}->{users};
    my $p_bBots=$lobby->{battle}->{bots};
    my $nextRemappedId=0;
    if($conf{idShareMode} eq 'off') {
      foreach my $player (keys %{$p_bUsers}) {
        if(defined $p_bUsers->{$player}->{battleStatus} && $p_bUsers->{$player}->{battleStatus}->{mode}) {
          $nextRemappedId=$p_bUsers->{$player}->{battleStatus}->{id}+1 if($p_bUsers->{$player}->{battleStatus}->{id} >= $nextRemappedId);
        }
      }
      foreach my $bot (keys %{$p_bBots}) {
        $nextRemappedId=$p_bBots->{$bot}->{battleStatus}->{id}+1 if($p_bBots->{$bot}->{battleStatus}->{id} >= $nextRemappedId);
      }
    }
    my %usedIds;
    my %clansId=('' => '');
    my $userClanPref=getUserPref($user,'clan');
    $clansId{$userClanPref}=$userClanPref if($userClanPref ne '');
    my $nextClanId=1;
    foreach my $player (keys %{$p_bUsers}) {
      if(defined $p_bUsers->{$player}->{battleStatus} && $p_bUsers->{$player}->{battleStatus}->{mode}) {
        my $playerTeam=$p_bUsers->{$player}->{battleStatus}->{team};
        my $playerId=$p_bUsers->{$player}->{battleStatus}->{id};
        if($conf{idShareMode} eq 'off') {
          $playerId=$nextRemappedId++ if(exists $usedIds{$playerId});
          $usedIds{$playerId}=1;
        }
        $currentBattleStatus{$playerTeam}={} unless(exists $currentBattleStatus{$playerTeam});
        $currentBattleStatus{$playerTeam}->{$playerId}=[] unless(exists $currentBattleStatus{$playerTeam}->{$playerId});
        push(@{$currentBattleStatus{$playerTeam}->{$playerId}},$player);
      }else{
        push(@spectators,$player) unless($springServerType eq 'dedicated' && $player eq $conf{lobbyLogin});
      }
      my $clanPref=getUserPref($player,'clan');
      $clansId{$clanPref}=':'.$nextClanId++.':' unless(exists $clansId{$clanPref});
    }
    if(! %currentBattleStatus && ! @spectators) {
      sayPrivate($user,"$C{7}Battle is empty");
      sayPrivate($user,"===============");
    }else{
      my $userLevel=getUserAccessLevel($user);
      foreach my $bot (keys %{$p_bBots}) {
        my $botTeam=$p_bBots->{$bot}->{battleStatus}->{team};
        my $botId=$p_bBots->{$bot}->{battleStatus}->{id};
        if($conf{idShareMode} eq 'off') {
          $botId=$nextRemappedId++ if(exists $usedIds{$botId});
          $usedIds{$botId}=1;
        }
        $currentBattleStatus{$botTeam}={} unless(exists $currentBattleStatus{$botTeam});
        $currentBattleStatus{$botTeam}->{$botId}=[] unless(exists $currentBattleStatus{$botTeam}->{$botId});
        push(@{$currentBattleStatus{$botTeam}->{$botId}},$bot." (bot)");
      }
      my %pluginStatusInfo;
      foreach my $teamNb (sort {$a <=> $b} keys %currentBattleStatus) {
        foreach my $idNb (sort {$a <=> $b} keys %{$currentBattleStatus{$teamNb}}) {
          foreach my $player (sort @{$currentBattleStatus{$teamNb}->{$idNb}}) {
            my %clientStatus=(Name => $player,
                              Team => $teamNb+1,
                              Id => $idNb+1);
            if($player =~ /^(.+) \(bot\)$/) {
              my $botName=$1;
              $clientStatus{Rank}=$conf{botsRank};
              $clientStatus{Skill}="($rankSkill{$conf{botsRank}})";
              $clientStatus{ID}="$p_bBots->{$botName}->{aiDll} ($p_bBots->{$botName}->{owner})";
            }else{
              $clientStatus{Ready}="$C{4}No$C{1}";
              $clientStatus{Ready}="$C{3}Yes$C{1}" if($p_bUsers->{$player}->{battleStatus}->{ready});
              if(defined $lobby->{users}->{$player}->{ip}) {
                $clientStatus{IP}=$lobby->{users}->{$player}->{ip};
              }elsif(defined $p_bUsers->{$player}->{ip}) {
                $clientStatus{IP}=$p_bUsers->{$player}->{ip};
              }
              my $rank=$lobby->{users}->{$player}->{status}->{rank};
              my $skill="$C{13}!$rankSkill{$rank}!$C{1}";
              if(exists $battleSkills{$player}) {
                if($rank != $battleSkills{$player}->{rank}) {
                  my $diffRank=$battleSkills{$player}->{rank}-$rank;
                  $diffRank="+$diffRank" if($diffRank > 0);
                  if($battleSkills{$player}->{rankOrigin} eq 'ip') {
                    $diffRank="[$diffRank]";
                  }elsif($battleSkills{$player}->{rankOrigin} eq 'manual') {
                    $diffRank="($diffRank)";
                  }elsif($battleSkills{$player}->{rankOrigin} eq 'ipManual') {
                    $diffRank="{$diffRank}";
                  }else{
                    $diffRank="<$diffRank>";
                  }
                  $rank="$rank$C{12}$diffRank$C{1}";
                }
                if($battleSkills{$player}->{skillOrigin} eq 'rank') {
                  $skill="($battleSkills{$player}->{skill})";
                }elsif($battleSkills{$player}->{skillOrigin} eq 'TrueSkill') {
                  if(exists $battleSkills{$player}->{skillPrivacy}
                     && ($battleSkills{$player}->{skillPrivacy} == 0
                         || ($battleSkills{$player}->{skillPrivacy} == 1 && $userLevel >= $conf{minLevelForIpAddr}))) {
                    $skill=$battleSkills{$player}->{skill};
                  }else{
                    $skill=getRoundedSkill($battleSkills{$player}->{skill});
                    $skill="~$skill";
                  }
                  if(exists $battleSkills{$player}->{sigma}) {
                    if($battleSkills{$player}->{sigma} > 3) {
                      $skill.=' ???';
                    }elsif($battleSkills{$player}->{sigma} > 2) {
                      $skill.=' ??';
                    }elsif($battleSkills{$player}->{sigma} > 1.5) {
                      $skill.=' ?';
                    }
                  }
                  $skill="$C{6}$skill$C{1}";
                }elsif($battleSkills{$player}->{skillOrigin} eq 'TrueSkillDegraded') {
                  $skill="$C{4}\#$battleSkills{$player}->{skill}\#$C{1}";
                }elsif($battleSkills{$player}->{skillOrigin} eq 'Plugin') {
                  $skill="$C{10}\[$battleSkills{$player}->{skill}\]$C{1}";
                }elsif($battleSkills{$player}->{skillOrigin} eq 'PluginDegraded') {
                  $skill="$C{4}\[\#$battleSkills{$player}->{skill}\#\]$C{1}";
                }else{
                  $skill="$C{13}?$battleSkills{$player}->{skill}?$C{1}";
                }
              }else{
                slog("Undefined skill for player $player, using lobby rank instead in status command output!",1) unless($player eq $conf{lobbyLogin});
              }
              $clientStatus{Rank}=$rank;
              $clientStatus{Skill}=$skill;
              $clientStatus{ID}=$lobby->{users}->{$player}->{accountId};
              my $clanPref=getUserPref($player,'clan');
              $clientStatus{Clan}=$clansId{$clanPref} if($clanPref ne '');
              foreach my $pluginName (@pluginsOrder) {
                if($plugins{$pluginName}->can('updateStatusInfo')) {
                  my $p_pluginColumns=$plugins{$pluginName}->updateStatusInfo(\%clientStatus,
                                                                              $lobby->{users}->{$player}->{accountId},
                                                                              $lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod},
                                                                              $currentGameType,
                                                                              $userLevel);
                  foreach my $pluginColumn (@{$p_pluginColumns}) {
                    $pluginStatusInfo{$pluginColumn}=$pluginName unless(exists $pluginStatusInfo{$pluginColumn});
                  }
                }
              }
            }
            my %coloredStatus;
            foreach my $k (keys %clientStatus) {
              if(exists $pluginStatusInfo{$k}) {
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
        if(defined $lobby->{users}->{$spec}->{ip}) {
          $clientStatus{IP}=$lobby->{users}->{$spec}->{ip};
        }elsif(defined $p_bUsers->{$spec}->{ip}) {
          $clientStatus{IP}=$p_bUsers->{$spec}->{ip};
        }
        my $rank=$lobby->{users}->{$spec}->{status}->{rank};
        my $skill="$C{13}!$rankSkill{$rank}!$C{1}";
        if(exists $battleSkills{$spec}) {
          if($rank != $battleSkills{$spec}->{rank}) {
            my $diffRank=$battleSkills{$spec}->{rank}-$rank;
            $diffRank="+$diffRank" if($diffRank > 0);
            if($battleSkills{$spec}->{rankOrigin} eq 'ip') {
              $diffRank="[$diffRank]";
            }elsif($battleSkills{$spec}->{rankOrigin} eq 'manual') {
              $diffRank="($diffRank)";
            }elsif($battleSkills{$spec}->{rankOrigin} eq 'ipManual') {
              $diffRank="{$diffRank}";
            }else{
              $diffRank="<$diffRank>";
            }
            $rank="$rank$C{12}$diffRank$C{1}";
          }
          if($battleSkills{$spec}->{skillOrigin} eq 'rank') {
            $skill="($rankSkill{$battleSkills{$spec}->{rank}})";
          }elsif($battleSkills{$spec}->{skillOrigin} eq 'TrueSkill') {
            if(exists $battleSkills{$spec}->{skillPrivacy}
               && ($battleSkills{$spec}->{skillPrivacy} == 0
                   || ($battleSkills{$spec}->{skillPrivacy} == 1 && $userLevel >= $conf{minLevelForIpAddr}))) {
              $skill=$battleSkills{$spec}->{skill};
            }else{
              $skill=getRoundedSkill($battleSkills{$spec}->{skill});
              $skill="~$skill";
            }
            if(exists $battleSkills{$spec}->{sigma}) {
              if($battleSkills{$spec}->{sigma} > 3) {
                $skill.=' ???';
              }elsif($battleSkills{$spec}->{sigma} > 2) {
                $skill.=' ??';
              }elsif($battleSkills{$spec}->{sigma} > 1.5) {
                $skill.=' ?';
              }
            }
            $skill="$C{6}$skill$C{1}";
          }elsif($battleSkills{$spec}->{skillOrigin} eq 'TrueSkillDegraded') {
            $skill="$C{4}\#$battleSkills{$spec}->{skill}\#$C{1}";
          }elsif($battleSkills{$spec}->{skillOrigin} eq 'Plugin') {
            $skill="$C{10}\[$battleSkills{$spec}->{skill}\]$C{1}";
          }elsif($battleSkills{$spec}->{skillOrigin} eq 'PluginDegraded') {
            $skill="$C{4}\[\#$battleSkills{$spec}->{skill}\#\]$C{1}";
          }else{
            $skill="$C{13}?$battleSkills{$spec}->{skill}?$C{1}";
          }
        }else{
          slog("Undefined skill rank for spectator $spec, using lobby rank instead in status command output!",1);
        }
        $clientStatus{Rank}=$rank;
        $clientStatus{Skill}=$skill;
        $clientStatus{ID}=$lobby->{users}->{$spec}->{accountId};
        my $clanPref=getUserPref($spec,'clan');
        $clientStatus{Clan}=$clansId{$clanPref} if($clanPref ne '');
        foreach my $pluginName (@pluginsOrder) {
          if($plugins{$pluginName}->can('updateStatusInfo')) {
            my $p_pluginColumns=$plugins{$pluginName}->updateStatusInfo(\%clientStatus,
                                                                        $lobby->{users}->{$spec}->{accountId},
                                                                        $lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod},
                                                                        $currentGameType,
                                                                        $userLevel);
            foreach my $pluginColumn (@{$p_pluginColumns}) {
              $pluginStatusInfo{$pluginColumn}=$pluginName unless(exists $pluginStatusInfo{$pluginColumn});
            }
          }
        }
        my %coloredStatus;
        foreach my $k (keys %clientStatus) {
          if(exists $pluginStatusInfo{$k}) {
            $coloredStatus{"$C{6}$k$C{1}"}=$clientStatus{$k};
          }else{
            $coloredStatus{"$C{5}$k$C{1}"}=$clientStatus{$k};
          }
        }
        push(@clientsStatus,\%coloredStatus);
      }
      my @defaultStatusColumns=qw'Name Team Id Clan Ready Rank Skill ID';
      my %defaultStatusColumnsHash;
      @defaultStatusColumnsHash{@defaultStatusColumns}=(1) x @defaultStatusColumns;
      my @newPluginStatusColumns;
      foreach my $pluginColumn (keys %pluginStatusInfo) {
        push(@newPluginStatusColumns,$pluginColumn) unless(exists $defaultStatusColumnsHash{$pluginColumn});
      }
      my @statusFields;
      foreach my $statusField (@defaultStatusColumns,@newPluginStatusColumns) {
        if(exists $pluginStatusInfo{$statusField}) {
          push(@statusFields,"$C{6}$statusField$C{1}");
        }else{
          push(@statusFields,"$C{5}$statusField$C{1}");
        }
      }
      push(@statusFields,"$C{5}IP$C{1}") if($userLevel >= $conf{minLevelForIpAddr});
      my $p_statusLines=formatArray(\@statusFields,\@clientsStatus);
      foreach my $statusLine (@{$p_statusLines}) {
        sayPrivate($user,$statusLine);
      }
    }
    my $battleStateMsg="$B$C{10}Battle state:$B$C{1} ";
    if($springPid && $autohost->getState()) {
      $battleStateMsg.="in-game";
    }else{
      $battleStateMsg.="waiting for ready players in battle lobby";
    }
    if($timestamps{lastGameEnd}) {
      my $lastGameEndTime=secToTime(time-$timestamps{lastGameEnd});
      $battleStateMsg.=" (last game finished $lastGameEndTime ago)";
    }
    sayPrivate($user,$battleStateMsg);
    sayPrivate($user,"$B$C{10}Map:$B$C{1} $currentMap");
    sayPrivate($user,"$B$C{10}Mod:$B$C{1} $lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod}");
    sayPrivate($user,"$B$C{10}Game type:$B$C{1} $currentGameType");
  }
  if(%bosses) {
    my $bossList=join(",",keys %bosses);
    sayPrivate($user,"$B$C{10}Boss mode activated for$B$C{1}: $bossList");
  }
  my ($voteString)=getVoteStateMsg();
  sayPrivate($user,$voteString) if(defined $voteString);
  sayPrivate($user,"Some pending settings need rehosting to be applied") if(needRehost());
  if($quitAfterGame) {
    if($quitAfterGame == 1) {
      sayPrivate($user,"SPADS will quit after this game");
    }elsif($quitAfterGame == 2) {
      sayPrivate($user,"SPADS will restart after this game");
    }elsif($quitAfterGame == 3) {
      sayPrivate($user,"SPADS will quit as soon as the battle is empty and no game is running");
    }elsif($quitAfterGame == 4) {
      sayPrivate($user,"SPADS will restart as soon as the battle is empty and no game is running");
    }elsif($quitAfterGame == 5) {
      sayPrivate($user,"SPADS will quit as soon as the battle only contains spectators and no game is running");
    }elsif($quitAfterGame == 6) {
      sayPrivate($user,"SPADS will restart as soon as the battle only contains spectators and no game is running");
    }
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
    }elsif($win) {
      if($conf{useWin32Process} && defined $springWin32Process) {
        broadcastMsg("Killing Spring process (by $user)");
        answer("Killing Spring process") if($source eq "pv");
        $springWin32Process->Kill(100);
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
      my $p_banEntries=listBans([$res],getUserAccessLevel($user) >= $conf{minLevelForIpAddr},$user);
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
  my @banListsFields=qw'accountId name country cpu rank access bot level ip skill skillUncert nameOrAccountId';
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
    my %instanciatedFilters=%{$p_filters};
    my $nameOrAccountId=delete $instanciatedFilters{nameOrAccountId};
    $instanciatedFilters{name}=$nameOrAccountId;
    my $banExists=0;
    if($spads->banExists(\%instanciatedFilters)) {
      return 1 if($checkOnly);
      $banExists=1;
      $spads->unban(\%instanciatedFilters);
    }
    if(exists $p_filters->{name}) {
      $instanciatedFilters{name}=$p_filters->{name};
    }else{
      delete $instanciatedFilters{name};
    }
    $instanciatedFilters{accountId}="($nameOrAccountId)";
    if($spads->banExists(\%instanciatedFilters)) {
      return 1 if($checkOnly);
      $banExists=1;
      $spads->unban(\%instanciatedFilters);
    }
    my $accountId=getLatestUserAccountId($nameOrAccountId);
    if($accountId) {
      $instanciatedFilters{accountId}=$accountId;
      if($spads->banExists(\%instanciatedFilters)) {
        return 1 if($checkOnly);
        $banExists=1;
        $spads->unban(\%instanciatedFilters);
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
  if($lobbyState < 6) {
    answer("Unable to unlock battle lobby, battle is closed");
    return 0;
  }

  if(! $manualLockedStatus) {
    my $reason='it is not locked manually';
    my @clients=keys %{$lobby->{battle}->{users}};
    if($conf{autoLockClients} && $#clients >= $conf{autoLockClients}) {
      $reason="maximum number of clients ($conf{autoLockClients}) reached";
    }elsif($conf{autoLockRunningBattle} && $lobby->{users}->{$conf{lobbyLogin}}->{status}->{inGame}) {
      $reason='battle is running and autoLockRunningBattle is enabled';
    }elsif($conf{autoLock} ne 'off') {
      $reason='autoLock is enabled';
    }else{
      my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
      my @bots=keys %{$lobby->{battle}->{bots}};
      my $nbNonPlayer=getNbNonPlayer();
      my $nbPlayers=$#clients+1-$nbNonPlayer;
      if($conf{nbTeams} != 1) {
        $nbPlayers+=$#bots+1;
      }
      if($conf{maxSpecs} ne '' && $nbNonPlayer > $conf{maxSpecs}
         && ($nbPlayers >= $spads->{hSettings}->{maxPlayers} || ($conf{autoSpecExtraPlayers} && $nbPlayers >= $targetNbPlayers))) {
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
  if($lobbyState < 6) {
    answer('Unable to unlock battle lobby for spectator, battle is closed');
    return 0;
  }
  my $nbSpec=getNbSpec();
  my @unlockSpecDelay=split(/;/,$conf{unlockSpecDelay});
  my @clients=keys %{$lobby->{battle}->{users}};
  my $reason='';
  if($unlockSpecDelay[0] == 0) {
    $reason='this command is disabled on this autohost';
  }elsif(exists $lobby->{battle}->{users}->{$user}) {
    $reason='you are already in the battle';
  }elsif(! $currentLockedStatus) {
    $reason='it is not locked currently';
  }elsif($conf{autoLockClients} && $#clients >= $conf{autoLockClients}) {
    $reason="maximum client number ($conf{autoLockClients}) reached for this autohost";
  }elsif($conf{autoLockRunningBattle} && $lobby->{users}->{$conf{lobbyLogin}}->{status}->{inGame}) {
    $reason='battle is running and autoLockRunningBattle is enabled';
  }elsif($manualLockedStatus) {
    $reason='it has been locked manually';
  }elsif($conf{maxSpecs} ne '' && $nbSpec > $conf{maxSpecs}
         && getUserAccessLevel($user) < $conf{maxSpecsImmuneLevel} 
         && ! ($springPid && $autohost->getState()
               && exists $p_runningBattle->{users}->{$user} && defined $p_runningBattle->{users}->{$user}->{battleStatus} && $p_runningBattle->{users}->{$user}->{battleStatus}->{mode}
               && (! %{$autohost->getPlayer($user)} || $autohost->getPlayer($user)->{lost} == 0))) {
    $reason="maximum spectator number ($conf{maxSpecs}) reached for this autohost";
  }elsif(exists $pendingSpecJoin{$user} && time - $pendingSpecJoin{$user} < $unlockSpecDelay[1]) {
    $reason='please wait '.($pendingSpecJoin{$user} + $unlockSpecDelay[1] - time).'s before reusing this command';
  }elsif(! exists $lobby->{users}->{$user}) {
    $reason='you are not connected to lobby server';
  }else{
    my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
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
    if($conf{autoUpdateRelease} eq "") {
      answer("Unable to update: release not specified and autoUpdateRelease is disabled");
      return 0;
    }
    $release=$conf{autoUpdateRelease};
  }elsif($#{$p_params} == 0) {
    $release=$p_params->[0];
    if(none {$release eq $_} qw'stable testing unstable contrib') {
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
  
  my @updatePackages=@packagesSpads;
  push(@updatePackages,@packagesWinUnitSync) if($conf{autoUpdateBinaries} eq "yes" || $conf{autoUpdateBinaries} eq "unitsync");
  push(@updatePackages,@packagesWinServer) if($conf{autoUpdateBinaries} eq "yes" || $conf{autoUpdateBinaries} eq "server");

  $updater = SpadsUpdater->new(sLog => $updaterSimpleLog,
                               localDir => $conf{binDir},
                               repository => "http://planetspads.free.fr/spads/repository",
                               release => $release,
                               packages => \@updatePackages,
                               syncedSpringVersion => $syncedSpringVersion);
  my $childPid = fork();
  if(! defined $childPid) {
    answer("Unable to update: cannot fork to launch SPADS updater");
    return 0;
  }
  if($childPid == 0) {
    $SIG{CHLD}="" unless($win);
    chdir($cwd);
    my $updateRc=$updater->update();
    my ($answerMsg,$exitCode);
    if($updateRc < 0) {
      if($updateRc == -7) {
        $answerMsg="Unable to update SPADS components (manual action required for new major version), please check logs for further information" ;
      }else{
        $answerMsg="Unable to update SPADS components (error code: $updateRc), please check logs for further information";
      }
      $exitCode=$updateRc;
    }elsif($updateRc == 0) {
      $answerMsg="No update available for $release release (SPADS components are already up to date)";
      $exitCode=0;
    }else{
      $answerMsg="$updateRc SPADS component(s) updated (a restart is needed to apply modifications)";
      $exitCode=0;
    }
    if($source eq "pv") {
      logMsg("pv_$user","<$conf{lobbyLogin}> $answerMsg") if($conf{logPvChat});
      sendLobbyCommand([["SAYPRIVATE",$user,$answerMsg]]);
    }else{
      answer($answerMsg);
    }
    exit $exitCode;
  }else{
    $updaterPid=$childPid;
  }
}

sub hVersion {
  my (undef,$user,undef,$checkOnly)=@_;
  
  return 1 if($checkOnly);

  my ($p_C,$B)=initUserIrcColors($user);
  my %C=%{$p_C};
  
  my $autoUpdateString="auto-update disabled";
  $autoUpdateString="auto-restart for update: $conf{autoRestartForUpdate}" if($conf{autoRestartForUpdate} ne "off");
  if($conf{autoUpdateRelease}) {
    my $autoUpdateRelease;
    if($conf{autoUpdateRelease} eq "stable") {
      $autoUpdateRelease=$C{3};
    }elsif($conf{autoUpdateRelease} eq 'testing') {
      $autoUpdateRelease=$C{7};
    }elsif($conf{autoUpdateRelease} eq 'unstable') {
      $autoUpdateRelease=$C{4};
    }else{
      $autoUpdateRelease=$C{6};
    }
    $autoUpdateRelease.="$conf{autoUpdateRelease}$C{1}";
    $autoUpdateString="auto-update: $autoUpdateRelease";
  }

  sayPrivate($user,"$C{12}$conf{lobbyLogin}$C{1} is running ${B}$C{5}SPADS $C{10}v$spadsVer$B$C{1} ($autoUpdateString), with following components:");
  sayPrivate($user,"- $C{5}Perl$C{10} $^V");
  sayPrivate($user,"- $C{5}Spring$C{10} v$syncedSpringVersion");
  my %components = (SpringLobbyInterface => $lobby,
                    SpringAutoHostInterface => $autohost,
                    SpadsConf => $spads,
                    SimpleLog => $sLog,
                    SpadsUpdater => $updater);
  foreach my $module (keys %components) {
    my $ver=$components{$module}->getVersion();
    sayPrivate($user,"- $C{5}$module$C{10} v$ver");
  }

  foreach my $pluginName (@pluginsOrder) {
    my $pluginVersion=$plugins{$pluginName}->getVersion();
    sayPrivate($user,"- $C{3}$pluginName$C{10} v$pluginVersion$C{1} (plugin)");
  }
}

sub hVote {
  my ($source,$user,$p_params,$checkOnly)=@_;

  return 0 if($checkOnly);

  if($#{$p_params} != 0) {
    invalidSyntax($user,'vote');
    return;
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
    return;
  }

  if(! exists $currentVote{command}) {
    answer("$user, you cannot vote currently, there is no vote in progress.");
    return;
  }

  if(! (exists $currentVote{remainingVoters}->{$user} || exists $currentVote{awayVoters}->{$user} || exists $currentVote{manualVoters}->{$user})) {
    answer("$user, you are not allowed to vote for current vote.");
    return;
  }

  if(exists $currentVote{remainingVoters}->{$user}) {
    delete $currentVote{remainingVoters}->{$user};
  }elsif(exists $currentVote{awayVoters}->{$user}) {
    delete $currentVote{awayVoters}->{$user};
    --$currentVote{blankCount};
  }elsif(exists $currentVote{manualVoters}->{$user}) {
    if($currentVote{manualVoters}->{$user} eq $vote) {
      answer("$user, you have already voted for current vote.");
      return;
    }
    --$currentVote{$currentVote{manualVoters}->{$user}.'Count'};
  }

  $currentVote{manualVoters}->{$user}=$vote;
  ++$currentVote{$vote.'Count'};

  setUserPref($user,'voteMode','normal') if(getUserPref($user,'autoSetVoteMode'));

  printVoteState();
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
    if($userLevel < $conf{minLevelForIpAddr}) {
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
    $online=exists $lobby->{accounts}->{$idOnly} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
  }else{
    $online=exists $lobby->{users}->{$idName} ? "$C{3}Yes$C{1}" : "$C{4}No$C{1}";
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
                "$C{5}CPU$C{1}" => $p_accountMainData->{cpu},
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

  my $p_resultLines=formatArray(["$C{5}AccountId$C{1}","$C{5}Name$C{1}","$C{5}Online$C{1}","$C{5}Country$C{1}","$C{5}CPU$C{1}","$C{5}Rank$C{1}","$C{5}LastUpdate$C{1}"],[\%mainData],"$C{2}Account information$C{1}");
  foreach my $resultLine (@{$p_resultLines}) {
    sayPrivate($user,$resultLine);
  }
  
  $p_resultLines=[];
  sayPrivate($user,'.') if(@names || (@ips && $userLevel >= $conf{minLevelForIpAddr}));
  
  my $firstArrayWidth=0;
  if(@names) {
    $p_resultLines=formatArray(["$C{5}Name$C{1}","$C{5}LastUpdate$C{1}"],\@names,"$C{2}Previous names$C{1}");
    $firstArrayWidth=realLength($p_resultLines->[1]);
  }
  
  if(@ips && $userLevel >= $conf{minLevelForIpAddr}) {
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
      if(! exists $lobby->{accounts}->{$accountId}) {
        slog("Ignoring skill data received for offline account ($accountId)",2);
        next;
      }
      my $player=$lobby->{accounts}->{$accountId};
      my $skillPref=getUserPref($player,'skillMode');
      if($skillPref ne 'TrueSkill') {
        slog("Ignoring skill data received for player $player with skillMode set to \"$skillPref\" ($accountId)",2);
        next;
      }
      if(! exists $battleSkills{$player}) {
        slog("Ignoring skill data received for player out of battle ($player)",2);
        next;
      }
      my $previousPlayerSkill=$battleSkills{$player}->{skill};
      if($status == 0) {
        if($skills =~ /^\|(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)\|(-?\d+(?:\.\d*)?),(\d+(?:\.\d*)?),(\d)$/) {
          my ($privacyMode,$duelSkill,$duelSigma,$duelClass,$ffaSkill,$ffaSigma,$ffaClass,$teamSkill,$teamSigma,$teamClass,$teamFfaSkill,$teamFfaSigma,$teamFfaClass)=($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13);
          $battleSkillsCache{$player}={Duel => {skill => $duelSkill, sigma => $duelSigma, class => $duelClass},
                                       FFA => {skill => $ffaSkill, sigma => $ffaSigma, class => $ffaClass},
                                       Team => {skill => $teamSkill, sigma => $teamSigma, class => $teamClass},
                                       TeamFFA => {skill => $teamFfaSkill, sigma => $teamFfaSigma, class => $teamFfaClass}};
          $battleSkills{$player}->{skill}=$battleSkillsCache{$player}->{$currentGameType}->{skill};
          $battleSkills{$player}->{sigma}=$battleSkillsCache{$player}->{$currentGameType}->{sigma};
          $battleSkills{$player}->{class}=$battleSkillsCache{$player}->{$currentGameType}->{class};
          $battleSkills{$player}->{skillOrigin}='TrueSkill';
          $battleSkills{$player}->{skillPrivacy}=$privacyMode;
        }else{
          slog("Ignoring invalid skill data received for player $player ($skills)",2);
        }
      }elsif($status == 1) {
        slog("Unable to get skill of player $player \#$accountId (permission denied)",2);
      }elsif($status == 2) {
        slog("Unable to get skill of player $player \#$accountId (unrated account)",2);
        $battleSkills{$player}->{skillOrigin}='rank';
      }else{
        slog("Unable to get skill of player $player \#$accountId (unknown status code: $status)",2);
      }
      pluginsUpdateSkill($battleSkills{$player},$accountId);
      sendPlayerSkill($player);
      checkBattleBansForPlayer($player);
      $needRebalance=1 if($previousPlayerSkill != $battleSkills{$player}->{skill} && $lobbyState > 5 && %{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$player}
                          && defined $lobby->{battle}->{users}->{$player}->{battleStatus} && $lobby->{battle}->{users}->{$player}->{battleStatus}->{mode});
    }else{
      slog("Ignoring invalid skill parameter ($skillParam)",2);
    }
  }
  if($needRebalance) {
    $balanceState=0;
    %balanceTarget=();
  }
}

# Lobby interface callbacks ###################################################

sub cbLobbyConnect {
  $lobbyState=2;
  $lobbyBrokenConnection=0;
  my $lobbySyncedSpringVersion=$_[2];
  $lobbySyncedSpringVersion=$1 if($lobbySyncedSpringVersion =~ /^([^\.]+)\./);
  $lanMode=$_[4];

  if($lanMode) {
    slog("Lobby server is running in LAN mode (lobby passwords aren't checked)",3);
    slog("It is highly recommended to use internal SPADS user authentication for privileged accounts",3);
  }

  $timestamps{mapLearned}=0;
  $spads->applyMapList(\@availableMaps,$syncedSpringVersion);
  setDefaultMapOfMaplist() if($conf{map} eq '');

  my $multiEngineFlag='';
  if($syncedSpringVersion ne $lobbySyncedSpringVersion) {
    $fullSpringVersion=$syncedSpringVersion;
    my $buggedUnitsync=0;
    if(! $win) {
      my $fileBin;
      if(-x '/usr/bin/file') {
        $fileBin='/usr/bin/file';
      }elsif(-x '/bin/file') {
        $fileBin='/bin/file';
      }
      $buggedUnitsync=1 if(! defined $fileBin || `$fileBin $conf{binDir}/PerlUnitSync.so` !~ /64\-bit/);
    }
    my $isSpringReleaseVersion;
    if($buggedUnitsync) {
      if($syncedSpringVersion =~ /^\d+$/) {
        $isSpringReleaseVersion=1;
      }else{
        $isSpringReleaseVersion=0;
      }
    }else{
      $isSpringReleaseVersion=PerlUnitSync::IsSpringReleaseVersion();
    }
    if($isSpringReleaseVersion) {
      my $springVersionPatchset=PerlUnitSync::GetSpringVersionPatchset();
      $fullSpringVersion.='.'.$springVersionPatchset;
    }
    $multiEngineFlag=' cl';
    if($lobbySyncedSpringVersion eq '*') {
      slog("Lobby server has no default engine set, UnitSync is using Spring $syncedSpringVersion",3);
    }else{
      slog("Lobby server default engine is Spring $lobbySyncedSpringVersion, UnitSync is using Spring $syncedSpringVersion",3);
      if($conf{onBadSpringVersion} eq 'closeBattle') {
        closeBattleAfterGame("Lobby server default engine is Spring $lobbySyncedSpringVersion, UnitSync is using Spring $syncedSpringVersion");
      }elsif($conf{onBadSpringVersion} eq 'quit') {
        quitAfterGame("Lobby server default engine is Spring $lobbySyncedSpringVersion, UnitSync is using Spring $syncedSpringVersion");
      }
    }
  }

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
                        REMOVEBOT => \&cbRemoveBot,
                        BROADCAST => \&cbBroadcast,
                        BATTLECLOSED => \&cbBattleClosed,
                        JOINED => \&cbJoined,
                        LEFT => \&cbLeft,
                        UPDATEBATTLEINFO => \&cbUpdateBattleInfo,
                        BATTLEOPENED => \&cbBattleOpened});

  my $localLanIp=$conf{localLanIp};
  $localLanIp=getLocalLanIp() unless($localLanIp);
  queueLobbyCommand(["LOGIN",$conf{lobbyLogin},$lobby->marshallPasswd($conf{lobbyPassword}),getCpuSpeed(),$localLanIp,"SPADS v$spadsVer",0,"a b sp$multiEngineFlag"],
                    {ACCEPTED => \&cbLoginAccepted,
                     DENIED => \&cbLoginDenied,
                     AGREEMENTEND => \&cbAgreementEnd},
                    \&cbLoginTimeout);
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
    %pendingRedirect=(ip => $ip, port => $port);
  }else{
    slog("Ignoring redirection request to address $ip",2);
  }
}

sub cbLobbyDisconnect {
  slog("Disconnected from lobby server (connection reset by peer)",2);
  logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > 5 && $conf{logBattleJoinLeave});
  $lobbyState=0;
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
  $lobby->disconnect();
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onLobbyDisconnected() if($plugins{$pluginName}->can('onLobbyDisconnected'));
  }
}

sub cbConnectTimeout {
  $lobbyState=0;
  slog("Timeout while connecting to lobby server ($conf{lobbyHost}:$conf{lobbyPort})",2);
}

sub cbLoginAccepted {
  $lobbyState=3;
  slog("Logged on lobby server",4);
  $triedGhostWorkaround=0;
}

sub cbLoginInfoEnd {
  $lobbyState=4;
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
    my %clientStatus = %{$lobby->{users}->{$conf{lobbyLogin}}->{status}};
    $clientStatus{inGame}=1;
    queueLobbyCommand(["MYSTATUS",$lobby->marshallClientStatus(\%clientStatus)]);
  }
  queueLobbyCommand(["GETINGAMETIME"]);
  if(exists $lobby->{users}->{$conf{lobbyLogin}} && ! $lobby->{users}->{$conf{lobbyLogin}}->{status}->{bot}) {
    slog('The lobby account currently used by SPADS is not tagged as bot. It is recommended to ask a lobby administrator for bot flag on accounts used by SPADS',2);
  }
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onLobbyConnected($lobby) if($plugins{$pluginName}->can('onLobbyConnected'));
  }
}

sub cbLoginDenied {
  my (undef,$reason)=@_;
  slog("Login denied on lobby server ($reason)",1);
  if(($reason !~ /^Already logged in/ && $reason !~ /^This account has already logged in/) || $triedGhostWorkaround > 2) {
    quitAfterGame("loggin denied on lobby server");
  }
  if($reason =~ /^Already logged in/) {
    $triedGhostWorkaround++;
  }else{
    $triedGhostWorkaround=0;
  }
  $lobbyState=0;
  $lobby->disconnect();
}

sub cbAgreementEnd {
  slog("Spring Lobby agreement has not been accepted for this account yet, please login with a Spring lobby client and accept the agreement",1);
  quitAfterGame("Spring Lobby agreement not accepted yet for this account");
  $lobbyState=0;
  $lobby->disconnect();
}

sub cbLoginTimeout {
  slog("Unable to log on lobby server (timeout)",2);
  logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > 5 && $conf{logBattleJoinLeave});
  $lobbyState=0;
  foreach my $joinedChan (keys %{$lobby->{channels}}) {
    logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
  }
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
  logMsg("channel_$chan","=== $user joined ===") if($conf{logChanJoinLeave});
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
  $lobbyState=6;
  logMsg("battle","=== $conf{lobbyLogin} joined ===") if($conf{logBattleJoinLeave});
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onBattleOpened() if($plugins{$pluginName}->can('onBattleOpened'));
  }
}

sub cbOpenBattleFailed {
  my (undef,$reason)=@_;
  slog("Unable to open battle ($reason)",1);
  $lobbyState=4;
  closeBattleAfterGame("unable to open battle");
}

sub cbOpenBattleTimeout {
  slog("Unable to open battle (timeout)",1);
  $lobbyState=4;
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
    if(exists $lobby->{users}->{$user}) {
      $spads->learnAccountRank(getLatestUserAccountId($user),
                               $lobby->{users}->{$user}->{status}->{rank},
                               $lobby->{users}->{$user}->{status}->{bot});
    }else{
      slog("Unable to store data for user \"$user\" (user unknown)",2);
    }
  }

  if($lobbyState > 5 && %{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$user} && defined $lobby->{battle}->{users}->{$user}->{scriptPass}
     && $autohost->getState() && $lobby->{users}->{$user}->{status}->{inGame} && ! exists $p_runningBattle->{users}->{$user}
     && ! exists $inGameAddedUsers{$user} && getUserAccessLevel($user) >= $conf{midGameSpecLevel}) {
    $inGameAddedUsers{$user}=$lobby->{battle}->{users}->{$user}->{scriptPass};
    $autohost->sendChatMessage("/adduser $user $inGameAddedUsers{$user}");
  }
}

sub cbClientIpPort {
  my (undef,$user,$ip)=@_;
  seenUserIp($user,$ip);
  my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),$ip,getPlayerSkillForBanCheck($user));
  queueLobbyCommand(["KICKFROMBATTLE",$user]) if($p_ban->{banType} < 2);
}

sub cbClientBattleStatus {
  my (undef,$user)=@_;

  if($lobbyState < 6 || ! exists $lobby->{battle}->{users}->{$user}) {
    slog("Ignoring CLIENTBATTLESTATUS command (client \"$user\" out of current battle)",2);
    return;
  }

  return if(checkUserStatusFlood($user));

  my $p_battleStatus=$lobby->{battle}->{users}->{$user}->{battleStatus};
  if($p_battleStatus->{mode}) {
    my $forceReason='';
    if(! exists $currentPlayers{$user}) {
      my $nbNonPlayer=getNbNonPlayer();
      my @clients=keys %{$lobby->{battle}->{users}};
      my $nbPlayers=$#clients+1-$nbNonPlayer;
      if($conf{nbTeams} != 1) {
        my @bots=keys %{$lobby->{battle}->{bots}};
        $nbPlayers+=$#bots+1;
      }
      my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
      my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
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
          if(! exists $balanceTarget{players}->{$user}) {
            $balanceState=0;
          }else{
            my $p_targetBattleStatus=$balanceTarget{players}->{$user}->{battleStatus};
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
          my $colorId=$conf{idShareMode} eq "off" ? $user : $p_battleStatus->{id};
          if(! exists $colorsTarget{$colorId}) {
            $colorsState=0;
          }else{
            my $p_targetColor=$colorsTarget{$colorId};
            my $p_color=$lobby->{battle}->{users}->{$user}->{color};
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
               && exists $p_runningBattle->{users}->{$user} && defined $p_runningBattle->{users}->{$user}->{battleStatus} && $p_runningBattle->{users}->{$user}->{battleStatus}->{mode}
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

  my $p_battleStatus=$p_bots->{$bot}->{battleStatus};
  my $p_color=$p_bots->{$bot}->{color};

  my $updateNeeded=0;
  if($conf{autoBlockBalance}) {
    if($balanceState) {
      if(! exists $balanceTarget{bots}->{$bot}) {
        queueLobbyCommand(["REMOVEBOT",$bot]);
      }else{
        my $p_targetBattleStatus=$balanceTarget{bots}->{$bot}->{battleStatus};
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
      my $colorId=$conf{idShareMode} eq "off" ? $bot.' (bot)' : $p_battleStatus->{id};
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
  my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),$ip,getPlayerSkillForBanCheck($user));
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

  return unless(%{$lobby->{battle}} && $battleId == $lobby->{battle}->{battleId});

  delete $pendingSpecJoin{$user} if(exists $pendingSpecJoin{$user});

  my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
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
  $mapHash+=$MAX_UNSIGNEDINTEGER if($mapHash < 0);

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

  my @welcomeMsgs=@{$spads->{values}->{welcomeMsg}};
  @welcomeMsgs=@{$spads->{values}->{welcomeMsgInGame}} if($lobby->{users}->{$conf{lobbyLogin}}->{status}->{inGame});
  foreach my $welcomeMsg (@welcomeMsgs) {
    if($welcomeMsg) {
      $welcomeMsg=~s/\%u/$user/g;
      $welcomeMsg=~s/\%l/$level/g;
      $welcomeMsg=~s/\%d/$levelDescription/g;
      $welcomeMsg=~s/\%m/$mapName/g;
      $welcomeMsg=~s/\%n/$conf{lobbyLogin}/g;
      $welcomeMsg=~s/\%v/$spadsVer/g;
      $welcomeMsg=~s/\%h/$mapHash/g;
      $welcomeMsg=~s/\%a/$mapLink/g;
      $welcomeMsg=~s/\%t/$gameAge/g;
      if($welcomeMsg =~ /^!(.+)$/) {
        sayBattleUser($user,$1);
      }else{
        sayBattle($welcomeMsg);
      }
    }
  }

  if(%bosses) {
    my $p_bossLevels=$spads->getCommandLevels("boss","battle","player","stopped");
    if(exists $p_bossLevels->{directLevel}) {
      my $requiredLevel=$p_bossLevels->{directLevel};
      $bosses{$user}=1 if($level >= $requiredLevel);
    }
  }
  
  if($autohost->getState() && defined $lobby->{battle}->{users}->{$user}->{scriptPass}) {
    if(exists $p_runningBattle->{users}->{$user} && ! exists $inGameAddedUsers{$user}) {
      $inGameAddedUsers{$user}=$lobby->{battle}->{users}->{$user}->{scriptPass};
      $autohost->sendChatMessage("/adduser $user $inGameAddedUsers{$user}");
    }
    if(exists $inGameAddedUsers{$user} && $inGameAddedUsers{$user} ne $lobby->{battle}->{users}->{$user}->{scriptPass}) {
      $inGameAddedUsers{$user}=$lobby->{battle}->{users}->{$user}->{scriptPass};
      $autohost->sendChatMessage("/adduser $user $inGameAddedUsers{$user}");
    }
  }

  getBattleSkill($user);
}

sub cbAddBot {
  my (undef,undef,$bot)=@_;

  my $nbNonPlayer=getNbNonPlayer();
  my $user=$lobby->{battle}->{bots}->{$bot}->{owner};

  delete($pendingLocalBotManual{$bot}) if(exists $pendingLocalBotManual{$bot});
  if(exists $pendingLocalBotAuto{$bot}) {
    $autoAddedLocalBots{$bot}=time if($user eq $conf{lobbyLogin});
    delete($pendingLocalBotAuto{$bot});
  }

  return if(checkUserStatusFlood($user));

  my $p_ban=$spads->getUserBan($user,$lobby->{users}->{$user},isUserAuthenticated($user),undef,getPlayerSkillForBanCheck($user));
  if($p_ban->{banType} < 2) {
    queueLobbyCommand(["KICKFROMBATTLE",$user]);
    return;
  }
  my @clients=keys %{$lobby->{battle}->{users}};
  my $targetNbPlayers=$conf{nbPlayerById}*$conf{teamSize}*$conf{nbTeams};
  my @bots=keys %{$lobby->{battle}->{bots}};
  my $nbPlayers=$#clients-$nbNonPlayer+$#bots+2;
  my ($nbLocalBots,$nbRemoteBots)=(0,0);
  foreach my $botName (@bots) {
    if($lobby->{battle}->{bots}->{$botName}->{owner} eq $conf{lobbyLogin}) {
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
  if(%{$lobby->{battle}} && $battleId == $lobby->{battle}->{battleId}) {
    $timestamps{battleChange}=time;
    $timestamps{rotationEmpty}=time;
    updateBattleInfoIfNeeded();
    updateBattleStates();
    if(exists $currentVote{command} && exists $currentVote{remainingVoters}->{$user}) {
      delete $currentVote{remainingVoters}->{$user};
    }
    my @players=keys %{$lobby->{battle}->{users}};
    $timestamps{autoRestore}=time if($#players == 0 && $timestamps{autoRestore});
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

    queueLobbyCommand(["REMOVESCRIPTTAGS",'game/players/'.lc($user).'/skill']);
    queueLobbyCommand(["REMOVESCRIPTTAGS",'game/players/'.lc($user).'/skilluncertainty']);
  }
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
  if(! %{$lobby->{battle}} && $lobbyState >= 6) {
    $currentNbNonPlayer=0;
    $lobbyState=4;
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
  }
  foreach my $pluginName (@pluginsOrder) {
    $plugins{$pluginName}->onBattleClosed() if($plugins{$pluginName}->can('onBattleClosed'));
  }
}

sub cbAddUser {
  my (undef,$user,$country,$cpu,$id)=@_;
  if($conf{userDataRetention} !~ /^0;/ && ! $lanMode) {
    $id//=0;
    $id.="($user)" unless($id);
    if(! defined $country) {
      slog("Received an invalid ADDUSER command from server (country field not provided for user $user)",2);
      $country='??';
    }
    if(! defined $cpu) {
      slog("Received an invalid ADDUSER command from server (cpu field not provided for user $user)",2);
      $cpu=0;
    }
    $spads->learnUserData($user,$country,$cpu,$id);
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
  if($user eq $sldbLobbyBot) {
    slog("TrueSkill service unavailable!",2);
  }
}

sub cbSaid {
  my (undef,$chan,$user,$msg)=@_;
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
  }
}

sub cbSaidEx {
  my (undef,$chan,$user,$msg)=@_;
  logMsg("channel_$chan","* $user $msg") if($conf{logChanChat});
}

sub cbSaidPrivate {
  my (undef,$user,$msg)=@_;
  foreach my $pluginName (@pluginsOrder) {
    return if($plugins{$pluginName}->can('onPrivateMsg') && $plugins{$pluginName}->onPrivateMsg($user,$msg) == 1);
  }
  logMsg("pv_$user","<$user> $msg") if($conf{logPvChat} && $user ne $sldbLobbyBot);
  if($msg =~ /^!([\#\w].*)$/) {
    handleRequest("pv",$user,$1);
  }
}

sub cbSaidBattle {
  my (undef,$user,$msg)=@_;
  logMsg("battle","<$user> $msg") if($conf{logBattleChat});
  return if(checkUserMsgFlood($user));
  if($msg =~ /^!(\w.*)$/) {
    handleRequest("battle",$user,$1);
  }elsif($autohost->{state} && $conf{forwardLobbyToGame} && $user ne $conf{lobbyLogin}) {
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
  }elsif($autohost->{state} && $conf{forwardLobbyToGame} && $user ne $conf{lobbyLogin}) {
    my $prompt="* $user ";
    my $p_messages=splitMsg($msg,$conf{maxAutoHostMsgLength}-length($prompt)-1);
    foreach my $mes (@{$p_messages}) {
      $autohost->sendChatMessage("$prompt$mes");
      logMsg("game","> $prompt$mes") if($conf{logGameChat});
    }
  }
}

sub cbChannelTopic {
  my (undef,$chan,$user,$time,$topic)=@_;
  logMsg("channel_$chan","* Topic is '$topic' (set by $user)") if($conf{logChanChat});
}

sub cbBattleOpened {
  my ($bId,$type,$founder,$ip,$mapHash)=($_[1],$_[2],$_[4],$_[5],$_[10]);
  my $mapName=$lobby->{battles}->{$bId}->{map};
  seenUserIp($founder,$ip);
  return if($type || ! $conf{autoLearnMaps} || getMapHash($mapName) || !$mapHash);
  my ($engineName,$engineVersion)=($lobby->{battles}->{$bId}->{engineName},$lobby->{battles}->{$bId}->{engineVersion});
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
  my ($engineName,$engineVersion)=($lobby->{battles}->{$battleId}->{engineName},$lobby->{battles}->{$battleId}->{engineVersion});
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
  if($autohost->getState() == 1 && $timestamps{autoForcePossible} == 0 && exists($p_runningBattle->{scriptTags}->{"game/startpostype"})) {
    if(%{$p_runningBattle->{bots}}) {
      slog("Game is using AI bots, cancelling auto-force start check.",5);
      $timestamps{autoForcePossible}=-1;
      return;
    }
    my $startPosType=$p_runningBattle->{scriptTags}->{"game/startpostype"};
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my $p_rBUsers=$p_runningBattle->{users};
    foreach my $user (keys %{$p_rBUsers}) {
      next if($user eq $conf{lobbyLogin});
      if(! defined $p_rBUsers->{$user}->{battleStatus}) {
        slog("Player \"$user\" has an undefined battleStatus in lobby, cancelling auto-force start check.",5);
        $timestamps{autoForcePossible}=-1;
        return;
      }
      if($p_rBUsers->{$user}->{battleStatus}->{mode}) {
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}->{disconnectCause} == -2) {
          slog("Player \"$user\" hasn't joined yet, auto-force start isn't possible.",5);
          return;
        }
        if($startPosType == 2 && $p_ahPlayers->{$user}->{ready} != 1) {
          slog("Player \"$user\" isn't ready yet, auto-force start isn't possible.",5);
          return;
        }
      }else{
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}->{disconnectCause} == -2) {
          if($p_rBUsers->{$user}->{battleStatus}->{sync} != 1) {
            slog("Ignoring unsynced spectator \"$user\" for auto-force start check.",5);
          }elsif($p_rBUsers->{$user}->{status}->{inGame} == 1) {
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
  return unless(exists $autohost->{players}->{$playerNb});
  my $name=$autohost->{players}->{$playerNb}->{name};
  return unless($readyState == 1);
  logMsg("game","=== $name is ready ===") if($conf{logGameServerMsg});

  if($autohost->getState() == 1 && $timestamps{autoForcePossible} == 0 && exists($p_runningBattle->{scriptTags}->{"game/startpostype"})) {
    if(%{$p_runningBattle->{bots}}) {
      slog("Game is using AI bots, cancelling auto-force start check.",5);
      $timestamps{autoForcePossible}=-1;
      return;
    }
    my $startPosType=$p_runningBattle->{scriptTags}->{"game/startpostype"};
    my $p_ahPlayers=$autohost->getPlayersByNames();
    my $p_rBUsers=$p_runningBattle->{users};
    foreach my $user (keys %{$p_rBUsers}) {
      next if($user eq $conf{lobbyLogin});
      if(! defined $p_rBUsers->{$user}->{battleStatus}) {
        slog("Player \"$user\" has an undefined battleStatus in lobby, cancelling auto-force start check.",5);
        $timestamps{autoForcePossible}=-1;
        return;
      }
      if($p_rBUsers->{$user}->{battleStatus}->{mode}) {
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}->{disconnectCause} == -2) {
          slog("Player \"$user\" hasn't joined yet, auto-force start isn't possible.",5);
          return;
        }
        if($startPosType == 2 && $p_ahPlayers->{$user}->{ready} != 1) {
          slog("Player \"$user\" isn't ready yet, auto-force start isn't possible.",5);
          return;
        }
      }else{
        if(! exists $p_ahPlayers->{$user} || $p_ahPlayers->{$user}->{disconnectCause} == -2) {
          if($p_rBUsers->{$user}->{battleStatus}->{sync} != 1) {
            slog("Ignoring unsynced spectator \"$user\" for auto-force start check.",5);
          }elsif($p_rBUsers->{$user}->{status}->{inGame} == 1) {
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
  return unless(exists $autohost->{players}->{$playerNb});
  $defeatTimes{$autohost->{players}->{$playerNb}->{name}}=time;
}

sub cbAhPlayerLeft {
  my (undef,$playerNb)=@_;
  if(exists $autohost->{players}->{$playerNb}) {
    my $name=$autohost->{players}->{$playerNb}->{name};
    logMsg("game","=== $name left ===") if($conf{logGameJoinLeave});
  }else{
    logMsg("game","=== \#$playerNb (unknown) left ===")  if($conf{logGameJoinLeave});
  }
  if($springServerType eq 'dedicated' && $autohost->{state} == 3 && $timestamps{gameOver} == 0) {
    $timestamps{gameOver}=time;
    $timestamps{autoStop}=time if($timestamps{autoStop} == 0 && $conf{autoStop} ne 'off');
  }else{
    checkAutoStop();
  }
}

sub cbAhPlayerChat {
  my (undef,$playerNb,$dest,$msg)=@_;
  my $player=$autohost->{players}->{$playerNb}->{name};
  $dest="(to $dest) " if($dest ne "");
  logMsg("game","$dest<$player> $msg") if($conf{logGameChat});
  if($dest eq "") {
    if((! $conf{noSpecChat}) || (exists $p_runningBattle->{users}->{$player} && defined $p_runningBattle->{users}->{$player}->{battleStatus}
                                 && $p_runningBattle->{users}->{$player}->{battleStatus}->{mode})) {
      my $p_messages=splitMsg($msg,$conf{maxChatMessageLength}-13-length($player));
      foreach my $mes (@{$p_messages}) {
        queueLobbyCommand(["SAYBATTLE","<$player> $mes"]);
      }
    }
    if("$msg" =~ /^!(\w.*)$/) {
      handleRequest("game",$player,$1);
    }
  }
}

sub cbAhServerStarted {
  slog("Spring server started",4);
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
    my $command=lc($currentVote{command}->[0]);
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
  if(! exists $runningBattleReversedMapping{teams}->{$teamNb}) {
    slog("Received a GAME_TEAMSTAT message for an invalid team ID ($teamNb)",2);
    return;
  }
  my $lobbyTeam=$runningBattleReversedMapping{teams}->{$teamNb};
  my $lobbyAllyTeam;
  my @names;
  foreach my $player (keys %{$p_runningBattle->{users}}) {
    if(defined $p_runningBattle->{users}->{$player}->{battleStatus} && $p_runningBattle->{users}->{$player}->{battleStatus}->{mode}
       && $p_runningBattle->{users}->{$player}->{battleStatus}->{id} == $lobbyTeam) {
      $lobbyAllyTeam=$p_runningBattle->{users}->{$player}->{battleStatus}->{team};
      push(@names,$player);
    }
  }
  foreach my $bot (keys %{$p_runningBattle->{bots}}) {
    if($p_runningBattle->{bots}->{$bot}->{battleStatus}->{id} == $lobbyTeam) {
      $lobbyAllyTeam=$p_runningBattle->{bots}->{$bot}->{battleStatus}->{team};
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
  if(! exists $autohost->{players}->{$playerNb}) {
    slog("Ignoring Game Over message from unknown player number $playerNb",2);
    return;
  }
  $p_gameOverResults->{$autohost->{players}->{$playerNb}->{name}}=\@winningAllyTeams;
  slog("Game over ($autohost->{players}->{$playerNb}->{name})",4);
  return if(($springServerType eq 'dedicated' && $autohost->{state} < 3)
            || ($springServerType eq 'headless' && $autohost->{players}->{$playerNb}->{name} ne $conf{lobbyLogin}));
  $timestamps{autoStop}=time if($timestamps{autoStop} == 0 && $conf{autoStop} ne 'off');
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
    if(! exists $runningBattleReversedMapping{allyTeams}->{$winningAllyTeam}) {
      slog("Unknown internal ally team found ($winningAllyTeam) when computing game over result",1);
      next;
    }
    $winningTeams{$runningBattleReversedMapping{allyTeams}->{$winningAllyTeam}}=[];
  }

  foreach my $player (keys %{$p_runningBattle->{users}}) {
    if(defined $p_runningBattle->{users}->{$player}->{battleStatus}
       && $p_runningBattle->{users}->{$player}->{battleStatus}->{mode}
       && exists $winningTeams{$p_runningBattle->{users}->{$player}->{battleStatus}->{team}}) {
        push(@{$winningTeams{$p_runningBattle->{users}->{$player}->{battleStatus}->{team}}},$player);
    }
  }
  my @bots=keys %{$p_runningBattle->{bots}};
  foreach my $bot (@bots) {
    if(exists $winningTeams{$p_runningBattle->{bots}->{$bot}->{battleStatus}->{team}}) {
      push(@{$winningTeams{$p_runningBattle->{bots}->{$bot}->{battleStatus}->{team}}},$bot.' (bot)');
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
  if($nbTeamStats > 2 && $conf{endGameAwards}) {
    my %awardStats;
    foreach my $name (@teamStatsNames) {
      $awardStats{$name}={damage => $teamStats{$name}->{damageDealt},
                          eco => 50 * $teamStats{$name}->{metalProduced} + $teamStats{$name}->{energyProduced},
                          micro => $teamStats{$name}->{damageDealt}/($teamStats{$name}->{damageReceived} ? $teamStats{$name}->{damageReceived} : 1)};
    }
    my @sortedDamages=sort {$awardStats{$b}->{damage} <=> $awardStats{$a}->{damage}} (keys %awardStats);
    my @sortedEcos=sort {$awardStats{$b}->{eco} <=> $awardStats{$a}->{eco}} (keys %awardStats);
    my @bestDamages;
    for my $i (0..(int($nbTeamStats/2-0.5))) {
      push(@bestDamages,$sortedDamages[$i]);
    }
    my @sortedMicros=sort {$awardStats{$b}->{micro} <=> $awardStats{$a}->{micro}} (@bestDamages);

    my ($damageWinner,$ecoWinner,$microWinner)=($sortedDamages[0],$sortedEcos[0],$sortedMicros[0]);
    my $maxLength=length($damageWinner);
    $maxLength=length($ecoWinner) if(length($ecoWinner) > $maxLength);
    $maxLength=length($microWinner) if(length($microWinner) > $maxLength);
    $damageWinner=rightPadString($damageWinner,$maxLength);
    $ecoWinner=rightPadString($ecoWinner,$maxLength);
    $microWinner=rightPadString($microWinner,$maxLength);

    my $formattedDamage=formatInteger(int($awardStats{$sortedDamages[0]}->{damage}));
    my $formattedResources=formatInteger(int($awardStats{$sortedEcos[0]}->{eco}));

    my $damageAwardMsg="  Damage award:  $damageWinner  (total damage: $formattedDamage)";
    my $ecoAwardMsg="  Eco award:     $ecoWinner  (resources produced: $formattedResources)";
    my $microAwardMsg="  Micro award:   $microWinner  (damage efficiency: ".int($awardStats{$sortedMicros[0]}->{micro}*100).'%)';
    
    $maxLength=length($damageAwardMsg);
    $maxLength=length($ecoAwardMsg) if(length($ecoAwardMsg) > $maxLength);
    $maxLength=length($microAwardMsg) if(length($microAwardMsg) > $maxLength);
    $damageAwardMsg=rightPadString($damageAwardMsg,$maxLength);
    $ecoAwardMsg=rightPadString($ecoAwardMsg,$maxLength);
    $microAwardMsg=rightPadString($microAwardMsg,$maxLength);
    $damageAwardMsg.='  [ OWNAGE! ]' if($awardStats{$sortedDamages[0]}->{damage} >= 2*$awardStats{$sortedDamages[1]}->{damage});
    $ecoAwardMsg.='  [ OWNAGE! ]' if($awardStats{$sortedEcos[0]}->{eco} >= 2*$awardStats{$sortedEcos[1]}->{eco});
    $microAwardMsg.='  [ OWNAGE! ]' if($awardStats{$sortedMicros[0]}->{micro} >= $awardStats{$sortedMicros[1]}->{micro}+0.5);
    sayBattle($damageAwardMsg);
    sayBattle($ecoAwardMsg);
    sayBattle($microAwardMsg);
  }

  my %teamCounts;
  foreach my $player (keys %{$p_runningBattle->{users}}) {
    if(defined $p_runningBattle->{users}->{$player}->{battleStatus} && $p_runningBattle->{users}->{$player}->{battleStatus}->{mode}) {
      my $playerTeam=$p_runningBattle->{users}->{$player}->{battleStatus}->{team};
      $teamCounts{$playerTeam}=0 unless(exists $teamCounts{$playerTeam});
      $teamCounts{$playerTeam}++;
    }
  }
  foreach my $bot (@bots) {
    my $botTeam=$p_runningBattle->{bots}->{$bot}->{battleStatus}->{team};
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
    my %gdrPlayer=(accountId => $p_runningBattle->{users}->{$player}->{accountId},
                   name => $player,
                   ip => '',
                   team => '',
                   allyTeam => '',
                   win => 0,
                   loseTime => '');
    $gdrPlayer{loseTime}=$defeatTimes{$player}-$timestamps{lastGameStart} if(exists $defeatTimes{$player});
    $gdrPlayer{ip}=$gdrIPs{$player} if(exists $gdrIPs{$player});
    if(defined $p_runningBattle->{users}->{$player}->{battleStatus}
       && $p_runningBattle->{users}->{$player}->{battleStatus}->{mode}) {
      $gdrPlayer{team}=$p_runningBattle->{users}->{$player}->{battleStatus}->{id};
      $gdrPlayer{allyTeam}=$p_runningBattle->{users}->{$player}->{battleStatus}->{team};
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
    my %gdrBot=(accountId => $p_runningBattle->{users}->{$p_runningBattle->{bots}->{$bot}->{owner}}->{accountId},
                name => $bot,
                ai => $p_runningBattle->{bots}->{$bot}->{aiDll},
                team => $p_runningBattle->{bots}->{$bot}->{battleStatus}->{id},
                allyTeam => $p_runningBattle->{bots}->{$bot}->{battleStatus}->{team},
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
    if(! exists $autohost->{players}->{$playerNb}) {
      slog("Received a connection established message for an unknown user, cancelling checks on in-game IP",2);
      return;
    }
    my $name=$autohost->{players}->{$playerNb}->{name};
    my $gameIp=$autohost->{players}->{$playerNb}->{address};
    if(! $gameIp) {
      slog("Unable to retrieve in-game IP for user $name, cancelling checks on in-game IP",2);
      return;
    }
    $gameIp=$1 if($gameIp =~ /^\[(?:::ffff:)?(\d+(?:\.\d+){3})\]:\d+$/);
    $gdrIPs{$name}=$gameIp;

    my $p_battleUserData;
    $p_battleUserData=$lobby->{battle}->{users}->{$name} if(%{$lobby->{battle}} && exists $lobby->{battle}->{users}->{$name});
    if((defined $p_battleUserData && defined $p_battleUserData->{scriptPass})
       || (exists $p_runningBattle->{users}->{$name} && defined $p_runningBattle->{users}->{$name}->{scriptPass})) {
      if($gameIp =~ /^\d+(?:\.\d+){3}$/) {
        seenUserIp($name,$gameIp);
      }else{
        slog("Invalid in-game IP format ($gameIp) for player \"$name\"",2);
      }
    }

    my $p_lobbyUserData;
    $p_lobbyUserData=$lobby->{users}->{$name} if(exists $lobby->{users}->{$name});
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

    $p_lobbyUserData=$p_runningBattle->{users}->{$name} if(! defined $p_lobbyUserData && exists $p_runningBattle->{users}->{$name});
    if(defined $p_lobbyUserData) {
      my $p_ban=$spads->getUserBan($name,$p_lobbyUserData,isUserAuthenticated($name),$gameIp,getPlayerSkillForBanCheck($name));
      if($p_ban->{banType} < 2) {
        sayBattleAndGame("Kicking $name from game (banned)");
        $autohost->sendChatMessage("/kickbynum $playerNb");
        logMsg("game","> /kickbynum $playerNb") if($conf{logGameChat});
      }elsif($p_ban->{banType} == 2 && exists $p_runningBattle->{users}->{$name}
             && defined($p_runningBattle->{users}->{$name}->{battleStatus})
             && $p_runningBattle->{users}->{$name}->{battleStatus}->{mode}) {
        sayBattleAndGame("Kicking $name from game (force-spec ban)");
        $autohost->sendChatMessage("/kickbynum $playerNb");
        logMsg("game","> /kickbynum $playerNb") if($conf{logGameChat});
      }
    }else{
      slog("Unable to perform in-game IP ban check for user $name, unknown user",2);
    }
  }
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
  my $p_unloadedPlugins=unloadPlugin($pluginName);
  my (@reloadedPlugins,$failedPlugin,@notReloadedPlugins);
  while(@{$p_unloadedPlugins}) {
    my $pluginToLoad=pop(@{$p_unloadedPlugins});
    if(loadPlugin($pluginToLoad)) {
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
  my $pluginName=shift;
  if(! exists $plugins{$pluginName}) {
    slog("Ignoring unloadPlugin call for plugin $pluginName (plugin is not loaded!)",2);
    return [];
  }

  my @unloadedPlugins;
  if(exists $pluginsReverseDeps{$pluginName}) {
    my @dependentPlugins=keys %{$pluginsReverseDeps{$pluginName}};
    foreach my $dependentPlugin (@dependentPlugins) {
      if(! exists $pluginsReverseDeps{$pluginName}->{$dependentPlugin}) {
        slog("Ignoring already unloaded dependent plugin ($dependentPlugin) during $pluginName plugin unload operation",5);
        next;
      }
      my $p_unloadedPlugins=unloadPlugin($dependentPlugin);
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
    if(! exists $pluginsReverseDeps{$dependencyPlugin}->{$pluginName}) {
      slog("Inconsistent plugin dependency state: $pluginName was not marked as being a dependent plugin of $dependencyPlugin",2);
      next;
    }
    delete $pluginsReverseDeps{$dependencyPlugin}->{$pluginName};
  }

  $plugins{$pluginName}->onUnload() if($plugins{$pluginName}->can('onUnload'));
  delete $spads->{pluginsConf}->{$pluginName};
  removePluginFromList($pluginName);
  delete($plugins{$pluginName});
  delete $INC{"$pluginName.pm"};

  push(@unloadedPlugins,$pluginName);
  return \@unloadedPlugins;
}

sub loadPlugin {
  my $pluginName=shift;
  if($spads->loadPluginConf($pluginName)) {
    $spads->applyPluginPreset($pluginName,$conf{defaultPreset});
    $spads->applyPluginPreset($pluginName,$conf{preset}) if($conf{preset} ne $conf{defaultPreset});
    return 1 if(loadPluginModule($pluginName));
  }
  delete $spads->{pluginsConf}->{$pluginName};
  delete $INC{"$pluginName.pm"};
  return 0;
}

sub loadPluginModule {
  my $pluginName=shift;

  my $hasDependencies;
  eval "\$hasDependencies=$pluginName->can('getDependencies')";

  my @pluginDeps;
  if($hasDependencies) {
    eval "\@pluginDeps=$pluginName->getDependencies()";
    my @missingDeps;
    foreach my $pluginDep (@pluginDeps) {
      push(@missingDeps,$pluginDep) unless(exists $plugins{$pluginDep});
    }
    if(@missingDeps) {
      slog("Unable to load plugin \"$pluginName\", dependenc".($#missingDeps > 0 ? 'ies' : 'y').' missing: '.join(',',@missingDeps),1);
      return 0;
    }
  }

  my $plugin;
  eval "\$plugin=$pluginName->new()";
  if($@) {
    slog("Unable to instanciate plugin module \"$pluginName\": $@",1);
    return 0;
  }
  if(! defined $plugin) {
    slog("Unable to initialize plugin module \"$pluginName\"",1);
    return 0;
  }
  my @mandatoryPluginFunctions=qw'getVersion getRequiredSpadsVersion';
  foreach my $mandatoryPluginFunction (@mandatoryPluginFunctions) {
    if(! $plugin->can($mandatoryPluginFunction)) {
      slog("Unable to load plugin \"$pluginName\", mandatory plugin function missing: $mandatoryPluginFunction",1);
      return 0;
    }
  }
  my $requiredSpadsVersion=$plugin->getRequiredSpadsVersion();
  if(compareVersions($spadsVer,$requiredSpadsVersion) < 0) {
    slog("Unable to load plugin \"$pluginName\", this plugin requires a SPADS version >= $requiredSpadsVersion, current is $spadsVer",1);
    return 0;
  }

  foreach my $pluginDep (@pluginDeps) {
    if(! exists $pluginsReverseDeps{$pluginDep}) {
      $pluginsReverseDeps{$pluginDep}={$pluginName => 1};
    }else{
      $pluginsReverseDeps{$pluginDep}->{$pluginName}=1;
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
                                                                $lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod},
                                                                $currentGameType);
      if($pluginResult) {
        if($pluginResult == 2) {
          slog("Using degraded mode for skill retrieving by plugin $pluginName ($accountId, $lobby->{battles}->{$lobby->{battle}->{battleId}}->{mod}, $currentGameType)",2);
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

slog("Initializing SPADS $spadsVer",3);

# Auto-update ##########################

if($conf{autoUpdateRelease} ne "") {
  $timestamps{autoUpdate}=time;
  if($updater->isUpdateInProgress()) {
    slog('Skipping auto-update at start, another updater instance is already running',2);
  }else{
    my $updateRc=$updater->update();
    if($updateRc < 0) {
      slog("Unable to check or apply SPADS update",2);
      if($updateRc > -7) {
        addAlert("UPD-001");
      }elsif($updateRc == -7) {
        addAlert("UPD-002");
      }else{
        addAlert("UPD-003");
      }
    }elsif($updateRc > 0) {
      sleep(2); # Avoid CPU eating loop in case auto-update is broken (fork bomb protection)
      restartAfterGame("auto-update");
      $running=0;
    }
  }
}

# Documentation ########################

if($genDoc) {
  slog("Generating SPADS documentation",3);

  my $p_comHelp=$spads->getFullCommandsHelp();
  my $p_setHelp=$spads->{helpSettings};
  my %allHelp=();
  foreach my $com (keys %{$p_comHelp}) {
    $allHelp{$com}={} unless(exists $allHelp{$com});
    my @comHelp=@{$p_comHelp->{$com}};
    my $comDesc=shift(@comHelp);
    $allHelp{$com}->{command}={desc => $comDesc, examples => \@comHelp};
  }
  foreach my $settingType (keys %{$p_setHelp}) {
    foreach my $setting (keys %{$p_setHelp->{$settingType}}) {
      my $settingName=$p_setHelp->{$settingType}->{$setting}->{name};
      $allHelp{$settingName}={} unless(exists $allHelp{$settingName});
      $allHelp{$settingName}->{$settingType}=$p_setHelp->{$settingType}->{$setting};
    }
  }

  my $genTime=gmtime();
  open(CSS,">$conf{varDir}/spadsDoc.css");
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
EOF
  close(CSS);

  open(HTML,">$conf{varDir}/spadsDoc.html");
  print HTML <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Frameset//EN" "http://www.w3.org/TR/html4/frameset.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$spadsVer on $genTime GMT-->
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

  open(HTML,">$conf{varDir}/spadsDoc_index.html");
  print HTML <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$spadsVer on $genTime GMT-->
<TITLE>SPADS doc index</TITLE>
<LINK REL="stylesheet" TYPE="text/css" HREF="spadsDoc.css" TITLE="Style">
</HEAD>

<BODY BGCOLOR="white">

<TABLE BORDER="0" WIDTH="100%" SUMMARY="">
<TR>
<TH ALIGN="left" NOWRAP><FONT size="+1" CLASS="FrameTitleFont">
<B>SPADS v$spadsVer</B></FONT></TH>
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

  my $escapedString;
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
    open(HTML,">$conf{varDir}/spadsDoc_list$listType.html");
    print HTML <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$spadsVer on $genTime GMT-->
<TITLE>$listContents{$listType}->[0]</TITLE>
<LINK REL="stylesheet" TYPE="text/css" HREF="spadsDoc.css" TITLE="Style">
</HEAD>

<BODY BGCOLOR="white">

<FONT size="+1" CLASS="FrameHeadingFont">
<B>$listContents{$listType}->[0]</B></FONT>
<BR>

<TABLE BORDER="0" WIDTH="100%" SUMMARY="">
<TR>
<TD NOWRAP>
EOF

    open(HTML2,">$conf{varDir}/spadsDoc_$listType.html");
    print HTML2 <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<!--NewPage-->
<HTML>
<HEAD>
<!-- Generated by SPADS v$spadsVer on $genTime GMT-->
<TITLE>$listContents{$listType}->[0] help</TITLE>
<LINK REL="stylesheet" TYPE="text/css" HREF="spadsDoc.css" TITLE="Style">
</HEAD>

<BODY BGCOLOR="white">
EOF

    foreach my $item (sort keys %allHelp) {
      next if($item eq "");
      foreach my $itemType (sort keys %{$allHelp{$item}}) {
        next unless($itemType =~ /^$listContents{$listType}->[1]$/);
        print HTML "<FONT CLASS=\"$items{$itemType}->[1]\"><A HREF=\"spadsDoc_$listType.html\#$itemType:$item\" target=\"mainFrame\">$item</A></FONT><BR>\n";
        print HTML2 <<EOF;
<A NAME="$itemType:$item"></a>
<TABLE BORDER="1" WIDTH="100%" CELLPADDING="3" CELLSPACING="0" SUMMARY="">
<TR BGCOLOR="#$items{$itemType}->[2]" ><TD COLSPAN=2><FONT SIZE="+2"><B>$item ($items{$itemType}->[0])</B></FONT></TD></TR>
EOF
        if($itemType eq "command") {
          my $comSyntax=$allHelp{$item}->{$itemType}->{desc};
          $comSyntax=encodeHtmlEntities($comSyntax);
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Syntax</B></TD><TD>$comSyntax</TD></TR>\n";
          if(@{$allHelp{$item}->{$itemType}->{examples}}) {
            print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Example(s)</B></TD><TD>";
            foreach my $example (@{$allHelp{$item}->{$itemType}->{examples}}) {
              my $exampleString=encodeHtmlEntities($example);
              print HTML2 "$exampleString<BR>";
            }
            print HTML2 "</TD></TR>\n";
          }
        }else{
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Explicit name</B></TD><TD>";
          foreach my $helpLine (@{$allHelp{$item}->{$itemType}->{explicitName}}) {
            my $lineHtml=encodeHtmlHelp($helpLine);
            print HTML2 "$lineHtml<BR>";
          }
          print HTML2 "</TD></TR>\n";
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Description</B></TD><TD>";
          foreach my $helpLine (@{$allHelp{$item}->{$itemType}->{description}}) {
            my $lineHtml=encodeHtmlHelp($helpLine);
            print HTML2 "$lineHtml<BR>";
          }
          print HTML2 "</TD></TR>\n";
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Format / Allowed values</B></TD><TD>";
          foreach my $helpLine (@{$allHelp{$item}->{$itemType}->{format}}) {
            my $lineHtml=encodeHtmlHelp($helpLine);
            print HTML2 "$lineHtml<BR>";
          }
          print HTML2 "</TD></TR>\n";
          print HTML2 "<TR BGCOLOR=\"white\" CLASS=\"TableRowColor\"><TD WIDTH=\"15%\"><B>Default value</B></TD><TD>";
          foreach my $helpLine (@{$allHelp{$item}->{$itemType}->{default}}) {
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

  exit 0;
}

sub encodeHtmlEntities {
  my $htmlLine=shift;
  if($htmlEntitiesUnavailable) {
    $htmlLine =~ s/</\&lt\;/g;
    $htmlLine =~ s/>/\&gt\;/g;
  }else{
    $htmlLine=encode_entities($htmlLine);
  }
  return $htmlLine;
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
  $line=~s/\[global:(\w+)\]/<FONT CLASS=\"FrameGlobalSettingFont\"><A HREF=\"spadsDoc_GlobalSettings.html\#global:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[set:(\w+)\]/<FONT CLASS=\"FrameSettingFont\"><A HREF=\"spadsDoc_PresetSettings.html\#set:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[hSet:(\w+)\]/<FONT CLASS=\"FrameHostingSettingFont\"><A HREF=\"spadsDoc_HostingSettings.html\#hset:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[bSet:(\w+)\]/<FONT CLASS=\"FrameBattleSettingFont\"><A HREF=\"spadsDoc_BattleSettings.html\#bset:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  $line=~s/\[pSet:(\w+)\]/<FONT CLASS=\"FramePreferenceFont\"><A HREF=\"spadsDoc_Preferences.html\#pset:$1\" target=\"mainFrame\">$1<\/A><\/FONT>/g;
  return $line;
}

# Init #################################

if($running) {

  my $lockFile="$conf{varDir}/spads.lock";
  if(open($lockFh,'>',$lockFile)) {
    $pidFile="$conf{varDir}/spads.pid";
    if(autoRetry(sub {flock($lockFh, LOCK_EX|LOCK_NB)})) {
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
      slog("Another SPADS instance (PID $spadsPid) is already running using same varDir ($conf{varDir}), please use a different varDir for every SPADS instance",0);
      exit 1;
    }
  }else{
    slog("Unable to write SPADS lock file \"$lockFile\" ($!)",0);
    exit 1;
  }

  slog("Using $springServerType Spring server binary",3);

  chdir($conf{springDataDir}) if($win);
  eval "use PerlUnitSync";
  if ($@) {
    slog("Unable to load PerlUnitSync module ($@)",0);
    unlink($pidFile);
    exit 1;
  }
  chdir($cwd) if($win);
  $syncedSpringVersion=PerlUnitSync::GetSpringVersion();
  push(@packages,@packagesWinServer) if($conf{autoUpdateBinaries} eq 'yes' || $conf{autoUpdateBinaries} eq 'server');
  $updater = SpadsUpdater->new(sLog => $updaterSimpleLog,
                               localDir => $conf{binDir},
                               repository => "http://planetspads.free.fr/spads/repository",
                               release => $conf{autoUpdateRelease},
                               packages => \@packages,
                               syncedSpringVersion => $syncedSpringVersion);
  if(! loadArchives()) {
    slog("Unable to load Spring archives at startup",0);
    unlink($pidFile);
    exit 1;
  }
  @predefinedColors=(generateColorPanel(1,1),
                     {red => 100, green => 100, blue => 100},
                     generateColorPanel(0.45,1),
                     {red => 150, green => 150, blue => 150},
                     generateColorPanel(1,0.6),
                     {red => 50, green => 50, blue => 50},
                     generateColorPanel(0.25,1),
                     {red => 200, green => 200, blue => 200},
                     generateColorPanel(1,0.25));

  if($conf{autoUpdateBinaries} eq 'yes' || $conf{autoUpdateBinaries} eq 'server') {
    if($updater->isUpdateInProgress()) {
      slog('Skipping Spring server binaries auto-update at start, another updater instance is already running',2);
    }else{
      my $updateRc=$updater->update();
      if($updateRc < 0) {
        slog("Unable to check or apply Spring server binaries update",2);
      }elsif($updateRc > 0) {
        sleep(2); # Avoid CPU eating loop in case auto-update is broken (fork bomb protection)
        restartAfterGame("auto-update");
        $running=0;
      }
    }
  }
}
if($running) {
  if($conf{autoLoadPlugins} ne '') {
    my @pluginNames=split(/;/,$conf{autoLoadPlugins});
    foreach my $pluginName (@pluginNames) {
      loadPluginModule($pluginName);
    }
  }

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
                           GAME_TEAMSTAT => \&cbAhGameTeamStat});

  $ahSock = $autohost->open();
  if(! $ahSock) {
    slog("Unable to create socket for Spring AutoHost interface",0);
    unlink($pidFile);
    exit 1;
  }
  $sockets{$ahSock} = sub { $autohost->receiveCommand() };
}

if(! $win) {
  $SIG{CHLD} = \&sigChldHandler;
  slog('SPADS process is currently running as root!',2) unless($>);
}

# Main loop ############################

while($running) {

  if(! $lobbyState && ! $quitAfterGame) {
    if($timestamps{connectAttempt} != 0 && $conf{lobbyReconnectDelay} == 0) {
      quitAfterGame('disconnected from lobby server, no reconnection delay configured');
    }else{
      if(time-$timestamps{connectAttempt} > $conf{lobbyReconnectDelay}) {
        $timestamps{connectAttempt}=time;
        $lobbyState=1;
        delete $sockets{$lSock} if(defined $lSock);
        $lobby->addCallbacks({REDIRECT => \&cbRedirect});
        $lSock = $lobby->connect(\&cbLobbyDisconnect,{TASSERVER => \&cbLobbyConnect},\&cbConnectTimeout);
        if($lSock) {
          $sockets{$lSock} = sub { $lobby->receiveCommand() };
        }else{
          $lobby->removeCallbacks(['REDIRECT']);
          $lobbyState=0;
          slog("Connection to lobby server failed",1);
        }
      }
    }
  }

  checkQueuedLobbyCommands();

  checkTimedEvents();

  my @pendingSockets=IO::Select->new(keys %sockets)->can_read(1);
  foreach my $pendingSock (@pendingSockets) {
    &{$sockets{$pendingSock}}($pendingSock);
  }

  if( $lobbyState > 0 && ( (time - $timestamps{connectAttempt} > 30 && time - $lobby->{lastRcvTs} > 60) || $lobbyBrokenConnection ) ) {
    if($lobbyBrokenConnection) {
      $lobbyBrokenConnection=0;
      slog("Disconnecting from lobby server (broken connection detected)",2);
    }else{
      slog("Disconnected from lobby server (timeout)",2);
    }
    logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > 5 && $conf{logBattleJoinLeave});
    $lobbyState=0;
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
    logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > 5 && $conf{logBattleJoinLeave});
    $lobbyState=0;
    foreach my $joinedChan (keys %{$lobby->{channels}}) {
      logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
    }
    $lobby->disconnect();
    $conf{lobbyHost}=$ip;
    $conf{lobbyPort}=$port;
    $lobby = SpringLobbyInterface->new(serverHost => $conf{lobbyHost},
                                       serverPort => $conf{lobbyPort},
                                       simpleLog => $lobbySimpleLog,
                                       warnForUnhandledMessages => 0);
    $timestamps{connectAttempt}=0;
  }

  openBattle() if($lobbyState == 4 && ! $closeBattleAfterGame);

  closeBattle() if($lobbyState >= 6 && $closeBattleAfterGame && $autohost->getState() == 0);

  if($lobbyState > 5) {
    my @players=keys %{$lobby->{battle}->{users}};
    if($conf{restoreDefaultPresetDelay} && $timestamps{autoRestore} && (! $springPid)) {
      if($#players == 0 && time-$timestamps{autoRestore} > $conf{restoreDefaultPresetDelay}) {
        my $restoreDefaultPresetDelayTime=secToTime($conf{restoreDefaultPresetDelay});
        broadcastMsg("Battle empty for $restoreDefaultPresetDelayTime, restoring default settings");
        applyPreset($conf{defaultPreset});
        $timestamps{autoRestore}=0;
        rehostAfterGame("restoring default hosting settings") if(needRehost());
      }
    }
    my $isEmpty=1;
    if($#players > 0) {
      foreach my $player (@players) {
        next if($player eq $conf{lobbyLogin});
        if(! $lobby->{users}->{$player}->{status}->{bot}) {
          $isEmpty=0;
          last;
        }
      }
    }
    if($isEmpty && ! $springPid) {
      if($conf{rotationEmpty} ne "off" && time - $timestamps{rotationEmpty} > $conf{rotationDelay}) {
        $timestamps{rotationEmpty}=time;
        if($conf{rotationType} eq "preset") {
          rotatePreset($conf{rotationEmpty},0);
        }else{
          rotateMap($conf{rotationEmpty},0);
        }
      }
      if(needRehost()) {
        rehostAfterGame("applying pending hosting settings while battle is empty",1);
        $timestamps{autoRestore}=time if($timestamps{autoRestore});
      }
    }
    autoManageBattle();
  }

  if($autohost->getState() == 0) {
    if($quitAfterGame == 1 || $quitAfterGame == 2) {
      slog("Game is not running, exiting",3);
      $running=0;
    }elsif($quitAfterGame) {
      if($lobbyState > 5) {
        my @players=keys %{$lobby->{battle}->{users}};
        if($#players == 0) {
          slog("Game is not running and battle is empty, exiting",3);
          $running=0;
        }elsif($quitAfterGame > 4) {
          my $containsPlayer=0;
          foreach my $p (@players) {
            if(defined $lobby->{battle}->{users}->{$p}->{battleStatus} && $lobby->{battle}->{users}->{$p}->{battleStatus}->{mode}) {
              $containsPlayer=1;
              last;
            }
          }
          if(! $containsPlayer) {
            slog("Game is not running and battle only contains spectators, exiting",3);
            $running=0;
          }
        }
      }else{
        slog("Game is not running and battle is closed, exiting",3);
        $running=0;
      }
    }
  }

}

# Exit handling ########################

while(@pluginsOrder) {
  my $pluginName=pop(@pluginsOrder);
  unloadPlugin($pluginName);
}
if($lobbyState) {
  foreach my $joinedChan (keys %{$lobby->{channels}}) {
    logMsg("channel_$joinedChan","=== $conf{lobbyLogin} left ===") if($conf{logChanJoinLeave});
  }
  logMsg("battle","=== $conf{lobbyLogin} left ===") if($lobbyState > 5 && $conf{logBattleJoinLeave});
  $lobbyState=0;
  if($quitAfterGame == 2 || $quitAfterGame == 4 || $quitAfterGame == 6) {
    sendLobbyCommand([['EXIT','AutoHost restarting']]);
  }else{
    sendLobbyCommand([['EXIT','AutoHost shutting down']]);
  }
  $lobby->disconnect();
}
$autohost->close() if(defined $autohost->{autoHostSock} && $autohost->{autoHostSock});
$spads->dumpDynamicData();
unlink($pidFile) if(defined $pidFile);
close($lockFh) if(defined $lockFh);
if($quitAfterGame == 2 || $quitAfterGame == 4 || $quitAfterGame == 6) {
  $SIG{CHLD}="" unless($win);
  chdir($cwd);
  my @paramsRestart=map {"$_=$confMacros{$_}"} (keys %confMacros);
  if($win) {
    map {s/\\+\"/\"/g} @paramsRestart;
    map {s/\"/\\\"/g} @paramsRestart;
    map {s/^(.*)$/\"$1\"/} @paramsRestart;
    exec($^X,"\"$0\"","\"$confFile\"",@paramsRestart) || forkedError("Unable to restart SPADS",0);
  }else{
    exec($^X,$0,$confFile,@paramsRestart) || forkedError("Unable to restart SPADS",0);
  }
}

exit 0;
