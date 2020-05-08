package ReverseLookup;

use strict;

use SpadsPluginApi;

use List::Util 'first';
use POSIX ':sys_wait_h';
use Socket qw':DEFAULT :addrinfo';
use Storable qw/store retrieve/;

no warnings 'redefine';

sub any (&@) {
  my $code = shift;
  return defined first {&{$code}} @_;
}

my $pluginVersion='0.3';
my $requiredSpadsVersion='0.11.31';

my %globalPluginParams = ( dnsCacheTime => ['integer'],
                           maxLookupProcess => ['integer'],
                           maxQueueLength => ['integer'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub getInstanceDir {
  return getSpadsConf()->{instanceDir} // getSpadsConf()->{varDir};
}

sub new {
  my $class=shift;
  my $self = {dnsCache => {},
              dnsCacheFlushTs => time,
              nbLookupProcesses => 0,
              lookupQueue => [] };
  bless($self,$class);
  my $dnsCacheFile=getInstanceDir().'/ReverseLookup.dat';
  if(-f $dnsCacheFile) {
    my $p_dnsCache=retrieve($dnsCacheFile);
    if(! defined $p_dnsCache) {
      slog("Unable to read DNS cache data file ($dnsCacheFile)",1);
    }else{
      $self->{dnsCache}=$p_dnsCache;
      $self->removePendingDnsEntries();
      $self->removeExpiredDnsEntries();
    }
  }
  if(getLobbyState() > 5) {
    my $lobby=getLobbyInterface();
    if(%{$lobby->{battle}}) {
      foreach my $user (keys %{$lobby->{battle}->{users}}) {
        $self->seenIp($lobby->{users}->{$user}->{ip}) if(defined $lobby->{users}->{$user}->{ip});
      }
    }
  }
  addSpringCommandHandler({SERVER_MESSAGE => \&hSpringServerMessage});
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub removePendingDnsEntries {
  my $self=shift;
  foreach my $ip (keys %{$self->{dnsCache}}) {
    delete $self->{dnsCache}->{$ip} if(any {$self->{dnsCache}->{$ip}->{hostname} eq $_} qw'_QUEUED_ _RESOLVING_');
  }
}

sub removeExpiredDnsEntries {
  my $self=shift;
  my $p_conf=getPluginConf();
  foreach my $ip (keys %{$self->{dnsCache}}) {
    delete $self->{dnsCache}->{$ip} unless(time - $self->{dnsCache}->{$ip}->{timestamp} < $p_conf->{dnsCacheTime} * 24 * 60 * 60);
  }
}

sub onUnload {
  my $self=shift;
  $self->storeDnsCacheIfNeeded(1);
  removeSpringCommandHandler(['SERVER_MESSAGE']);
  slog("Plugin unloaded",3);
}

sub eventLoop {
  my $self=shift;
  $self->storeDnsCacheIfNeeded();
  my $p_conf=getPluginConf();
  while(@{$self->{lookupQueue}} && $p_conf->{maxLookupProcess} > $self->{nbLookupProcesses}) {
    $self->lookupIp(shift(@{$self->{lookupQueue}}));
  }
}

sub storeDnsCacheIfNeeded {
  my ($self,$force)=@_;
  $force=0 unless(defined $force);
  my $p_spadsConf=getSpadsConf();
  return unless($force || ($p_spadsConf->{dataDumpDelay} && time-$self->{dnsCacheFlushTs} > 60 * $p_spadsConf->{dataDumpDelay}));
  $self->removeExpiredDnsEntries();
  $self->{dnsCacheFlushTs}=time;
  my $dnsCacheFile=getInstanceDir().'/ReverseLookup.dat';
  slog("Unable to store DNS cache data in file $dnsCacheFile",1) unless(store($self->{dnsCache},$dnsCacheFile));
}

sub lookupIp {
  my ($self,$ip)=@_;
  my ($inSocket,$outSocket);
  if(! socketpair($inSocket,$outSocket,AF_UNIX,SOCK_STREAM,PF_UNSPEC)) {
    slog("Unable to create socketpair, cancelling lookup of IP \"$ip\"! ($!)",1);
    return;
  }
  shutdown($inSocket, 0);
  shutdown($outSocket, 1);
  $self->{dnsCache}->{$ip}={hostname => '_RESOLVING_',
                            timestamp => time};
  $self->{nbLookupProcesses}++;
  if(! forkProcess( sub { close($outSocket); $self->forkedLookup($ip,$inSocket); }, sub { close($inSocket); $self->lookupComplete($ip,$outSocket,@_); } )) {
    slog("Unable to fork, cancelling lookup of IP \"$ip\"! ($!)",1);
    close($inSocket);
    close($outSocket);
    delete $self->{dnsCache}->{$ip};
    $self->{nbLookupProcesses}--;
  }
}

sub forkedLookup {
  my ($self,$ip,$socket)=@_;
  my ($exitCode,$resultString)=$self->forwardConfirmedReverseDns($ip);
  print $socket $resultString;
  close($socket);
  exit $exitCode;
}

sub forwardConfirmedReverseDns {
  my ($self,$ip)=@_;
  my ($err,$addrData,$hostName,@multiAddrData,$ip2);
  ($err,$addrData)=getaddrinfo($ip,undef,{flags => AI_NUMERICHOST, socktype => SOCK_RAW});
  return (1,'_INVALID_IP_') if($err);
  ($err,$hostName)=Socket::getnameinfo($addrData->{addr},NI_NAMEREQD,NIx_NOSERV);
  return (2,'_UNRESOLVABLE_IP_') if($err);
  ($err,@multiAddrData)=getaddrinfo($hostName,undef,{socktype => SOCK_RAW});
  return (3,'_UNRESOLVABLE_HOST_') if($err);
  my $spoofed=0;
  foreach my $addr (@multiAddrData) {
    ($err,$ip2)=Socket::getnameinfo($addr->{addr},NI_NUMERICHOST,NIx_NOSERV);
    next if($err);
    if($ip eq $ip2) {
      return (0,$hostName);
    }else{
      $spoofed=1;
    }
  }
  if($spoofed) {
    return (4,'_SPOOFED_');
  }else{
    return (5,'_INVALID_HOST_');
  }
}

sub lookupComplete {
  my ($self,$ip,$socket,$rc)=@_;
  my $data;
  my $readLength=$socket->sysread($data,4096);
  if(defined $readLength) {
    $self->{dnsCache}->{$ip}={hostname => $data,
                              timestamp => time};
  }else{
    slog("Error while reading data from socket, cancelling lookup of IP \"$ip\"! ($!)",1);
    delete $self->{dnsCache}->{$ip};
  }
  close($socket);
  $self->{nbLookupProcesses}--;
}

sub seenIp {
  my ($self,$ip)=@_;
  return if(exists $self->{dnsCache}->{$ip});
  my $p_conf=getPluginConf();
  if($p_conf->{maxLookupProcess} > $self->{nbLookupProcesses}) {
    $self->lookupIp($ip);
  }elsif($p_conf->{maxQueueLength} > @{$self->{lookupQueue}}) {
    $self->queueIp($ip);
  }else{
    slog("IP lookup queue is full, ignoring lookup of IP \"$ip\"!",2);
  }
}

sub queueIp {
  my ($self,$ip)=@_;
  push(@{$self->{lookupQueue}},$ip);
  $self->{dnsCache}->{$ip}={hostname => '_QUEUED_',
                            timestamp => time};
}

sub onJoinBattleRequest {
  my ($self,undef,$ip)=@_;
  $self->seenIp($ip);
  return 0;
}

sub hSpringServerMessage {
  if($_[1] =~ /^ -> Connection established \(given id (\d+)\)$/) {
    my $playerNb=$1;
    my $autohost=getSpringInterface();
    if(exists $autohost->{players}->{$playerNb} && $autohost->{players}->{$playerNb}->{address}) {
      my $ip=$autohost->{players}->{$playerNb}->{address};
      $ip=$1 if($ip =~ /^\[(?:::ffff:)?(\d+(?:\.\d+){3})\]:\d+$/);
      getPlugin()->seenIp($ip);
    }
  }
}

sub updateStatusInfo {
  my ($self,$p_playerStatus)=@_;
  return [] unless(exists $p_playerStatus->{IP} && defined $p_playerStatus->{IP});
  if(exists $self->{dnsCache}->{$p_playerStatus->{IP}}) {
    my $hostname=$self->{dnsCache}->{$p_playerStatus->{IP}}->{hostname};
    if($hostname eq '_QUEUED_') {
      $hostname='queued...';
    }elsif($hostname eq '_RESOLVING_') {
      $hostname='resolving...';
    }
    $p_playerStatus->{IP}.=" ($hostname)" if(index($hostname,'_') != 0);
    return ['IP'];
  }
  $p_playerStatus->{IP}.=' (?)';
  return ['IP'];
}

sub updateGameStatusInfo {
  my ($self,$p_playerStatus)=@_;
  return $self->updateStatusInfo($p_playerStatus);
}

1;
