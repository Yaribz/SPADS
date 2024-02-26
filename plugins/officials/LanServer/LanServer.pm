# LanServer (Perl module)
#
# SPADS plugin implementing a lobby server in LAN mode for SpringRTS engine
# based games (no account registration required).
#
# Copyright (C) 2024  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

package LanServer;

use warnings;
use strict;

use Net::SSLeay;

use Scalar::Util 'weaken';

use SpringLobbyProtocol 'marshallClientStatus';
use SpringLobbyServer;

use SpadsPluginApi;

my $pluginVersion='0.10';
my $requiredSpadsVersion='0.13.16';

my %globalPluginParams = (
  listenAddress => ['ipAddr','null'],
  listenPort => ['port'],
  wanAddress => ['ipAddr','star','null'],
  countryCode => [],
    );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my $class=shift;
  
  my $self={
    newUsers => {},
  };
  
  my $r_pluginConf=getPluginConf();
  map {$self->{$_}=$r_pluginConf->{$_}} (qw'listenAddress listenPort');
  
  my %springLobbyServerConf=(
    serverMode => SpringLobbyServer::SRV_MODE_LAN,
    logger => \&slog,
    onNewClientConnection => \&springLobbyServerOnNewClientConnection,
    authenticationSvc => \&springLobbyServerAuthenticationSvc,
      );
  $springLobbyServerConf{listenAddress}=$r_pluginConf->{listenAddress}
    unless($r_pluginConf->{listenAddress} eq '');
  if($r_pluginConf->{wanAddress} eq '*') {
    $springLobbyServerConf{wanAddress}='';
  }elsif($r_pluginConf->{wanAddress} ne '') {
    $springLobbyServerConf{wanAddress}=$r_pluginConf->{wanAddress};
  }
  $springLobbyServerConf{listenPort}=$r_pluginConf->{listenPort};
  if($r_pluginConf->{countryCode} ne '') {
    if($r_pluginConf->{countryCode} =~ /^[a-zA-Z]{2}$/) {
      $springLobbyServerConf{defaultCountryCode}=uc($r_pluginConf->{countryCode});
    }else{
      slog("Invalid country code parameter value \"$r_pluginConf->{countryCode}\" in plugin configuration file: must be a two letter country code",1);
      return undef;
    }
  }
  
  $self->{lobbySrv} = SpringLobbyServer->new(%springLobbyServerConf);
  bless($self,$class);

  onReloadConf($self);
  
  my $bioPemCertificate=Net::SSLeay::BIO_new_file($self->{lobbySrv}{pemCertFile},'r');
  if($bioPemCertificate) {
    my $certificate=Net::SSLeay::PEM_read_bio_X509($bioPemCertificate);
    if($certificate) {
      Net::SSLeay::BIO_free($bioPemCertificate);
      my $certHash=unpack('H*',Net::SSLeay::X509_digest($certificate,Net::SSLeay::EVP_get_digestbyname('sha256')));
      Net::SSLeay::X509_free($certificate);
      my $lobbyHost=getSpadsConf()->{lobbyHost};
      my $spads=getSpadsConfFull();
      if(! $spads->isTrustedCertificateHash($lobbyHost,$certHash)) {
        slog("Adding LAN server certificate to the trusted certificates list (host: $lobbyHost, hash: $certHash)",3);
        $spads->addTrustedCertificateHash({lobbyHost => $lobbyHost, certHash => $certHash});
      }
    }else{
      slog("Failed to parse local server PEM certificate file \"$self->{lobbySrv}{pemCertFile}\": ".Net::SSLeay::ERR_error_string(Net::SSLeay::ERR_get_error()),2);
      Net::SSLeay::BIO_free($bioPemCertificate);
    }
  }else{
    slog("Failed to open local server PEM certificate file \"$self->{lobbySrv}{pemCertFile}\" for reading: $!",2);
  }
  
  
  SimpleEvent::addForkedProcessCallback('CloseLanServerSockets',sub {map {close($_->{hdl}{fh})} (values %{$self->{lobbySrv}{connections}})});
  if(getLobbyState() > 3) {
    addLobbyCommandHandler({
      ADDUSER => \&hLobbyAddUser,
      REMOVEUSER => \&hLobbyRemoveUser,
      CLIENTSTATUS => \&hLobbyClientStatus,
                           });
  }elsif(getLobbyState() == 3) {
    addLobbyCommandHandler({LOGININFOEND => \&hLoginInfoEnd});
  }
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onReloadConf {
  my $self=shift;
  my $lobbyHost = $self->{listenAddress} eq '' ? '127.0.0.1' : $self->{listenAddress};
  my $lobbyPort = $self->{listenPort};
  my $r_conf=getSpadsConf();
  $r_conf->{lobbyHost}=$lobbyHost;
  $r_conf->{lobbyPort}=$lobbyPort;
  my $spads=getSpadsConfFull();
  $spads->{conf}{lobbyHost}=$lobbyHost;
  $spads->{conf}{lobbyPort}=$lobbyPort;
  my $lobby=getLobbyInterface();
  $lobby->{conf}{serverHost}=$lobbyHost;
  $lobby->{conf}{serverPort}=$lobbyPort;
}

sub onLobbyLogin {
  my $self=shift;
  addLobbyCommandHandler({LOGININFOEND => \&hLoginInfoEnd});
}
sub onLobbyConnected {
  my $self=shift;
  addLobbyCommandHandler({
    ADDUSER => \&hLobbyAddUser,
    REMOVEUSER => \&hLobbyRemoveUser,
    CLIENTSTATUS => \&hLobbyClientStatus,
                         });
}

sub onLobbyDisconnected {
  my $self=shift;
  $self->{newUsers}={};
}

sub onUnload {
  my $self=shift;
  removeLobbyCommandHandler([qw'LOGININFOEND ADDUSER REMOVEUSER CLIENTSTATUS']);
  SimpleEvent::removeForkedProcessCallback('CloseLanServerSockets');
  slog("Plugin unloaded",3);
}

sub hLoginInfoEnd {
  my $self=getPlugin();
  my $lobby=getLobbyInterface();
  map {updateUserRankAndAccessLevelIfNeeded($self,$_)} (keys %{$lobby->{users}});
}

sub hLobbyAddUser {
  my (undef,$user)=@_;
  updateUserRankAndAccessLevelIfNeeded(getPlugin(),$user);
  getPlugin()->{newUsers}{$user}=1;
}

sub hLobbyRemoveUser {
  my (undef,$user)=@_;
  delete getPlugin()->{newUsers}{$user};
}

sub hLobbyClientStatus {
  my (undef,$user)=@_;
  updateUserRankAndAccessLevelIfNeeded(getPlugin(),$user)
      if(delete getPlugin()->{newUsers}{$user});
}

sub postSpadsCommand {
  my ($self,$command,undef,$user,$r_params,$commandResult)=@_;
  return if(defined $commandResult && $commandResult eq '0');
  if($command eq 'auth') {
    updateUserRankAndAccessLevelIfNeeded($self,$user);
  }elsif($command eq 'chrank') {
    updateUserRankAndAccessLevelIfNeeded($self,$r_params->[0]);
  }
}

sub springLobbyServerOnNewClientConnection {
  my ($r_connInfo,$hdl)=@_;
  my $r_ban=getSpadsConfFull()->getUserBan('*',
                                           {
                                             accountId => '*',
                                             country => '*',
                                             lobbyClient => '*',
                                             status => {rank => '*', access => '*', bot => '*'},
                                             rank => '*',
                                           },
                                           0,
                                           $r_connInfo->{host});
  if($r_ban->{banType}) {
    SimpleEvent::win32HdlDisableInheritance($hdl) if($^O eq 'MSWin32');
    return undef;
  }else{
    return 'user is banned';
  }
  
}

sub springLobbyServerAuthenticationSvc {
  my ($r_connInfo,$userName,$password,$r_userInfo)=@_;
  my $r_spadsConf=getSpadsConf();
  if($userName eq $r_spadsConf->{lobbyLogin}) {
    return 'invalid password' unless($password eq getLobbyInterface()->marshallPasswd($r_spadsConf->{lobbyPassword}));
    $r_userInfo->{status}{bot}=1;
    $r_userInfo->{accessLevel}=200;
  }else{
    return 'reserved name' if(lc($userName) eq lc($r_spadsConf->{lobbyLogin}));
    my $rankPref=getSpadsConfFull()->getUserPrefs('',$userName)->{rankMode};
    $rankPref=$r_spadsConf->{rankMode} unless(defined $rankPref && $rankPref ne '');
    $r_userInfo->{status}{rank}=$rankPref if($rankPref =~ /^[0-7]$/);
    $r_userInfo->{status}{bot}=1 if(substr($r_userInfo->{lobbyClient},0,6) eq 'SPADS ');
  }
  return;
}

sub updateUserRankAndAccessLevelIfNeeded {
  my ($self,$userName)=@_;
  return unless(getLobbyState() >= 3);
  my ($lobbySrv,$lobbyCli)=($self->{lobbySrv},getLobbyInterface());
  my ($r_userInfoSrv,$r_userInfoCli) = map {$_->{users}{$userName}} ($lobbySrv,$lobbyCli);
  return unless(defined $r_userInfoSrv && defined $r_userInfoCli);
  my $rankPref=getSpadsConfFull()->getUserPrefs('',$userName)->{rankMode};
  my $r_spadsConf=getSpadsConf();
  $rankPref=$r_spadsConf->{rankMode} unless(defined $rankPref && $rankPref ne '');
  my $needUpdate;
  if($rankPref =~ /^[0-7]$/ && $r_userInfoSrv->{status}{rank} != $rankPref) {
    $needUpdate=1;
    map {$_->{status}{rank}=$rankPref} ($r_userInfoSrv,$r_userInfoCli);
  }
  my $accessLevel = $userName eq $r_spadsConf->{lobbyLogin} ? 200 : ::getUserAccessLevel($userName);
  $accessLevel=1 if($accessLevel < 1);
  if($r_userInfoSrv->{accessLevel} != $accessLevel) {
    $r_userInfoSrv->{accessLevel}=$accessLevel;
    if($lobbySrv->{accessFlagLevel}) {
      my $userAccessFlag = $accessLevel >= $lobbySrv->{accessFlagLevel} ? 1 : 0;
      if($userAccessFlag != $r_userInfoSrv->{status}{access}) {
        $needUpdate=1;
        $r_userInfoSrv->{status}{access}=$userAccessFlag;
      }
    }
  }
  if($needUpdate) {
    $r_userInfoSrv->{marshalledStatus}=marshallClientStatus($r_userInfoSrv->{status});
    $lobbySrv->broadcast('CLIENTSTATUS',$userName,$r_userInfoSrv->{marshalledStatus});
  }
}

1;
