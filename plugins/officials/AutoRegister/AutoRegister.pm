package AutoRegister;

use strict;

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.12.18';

my %globalPluginParams = ( enabled => ['bool'],
                           agreementAutoAcceptDelay => ['integer'],
                           registrationEmail => []);

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my $class=shift;
  my $self = {enabled => getPluginConf()->{enabled}};
  bless($self,$class);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  slog('Plugin unloaded',3);
}

sub enable {
  my $self=shift;
  $self->{enabled}=1;
  slog('Autoregistration enabled',3);
}

sub disable {
  my $self=shift;
  $self->{enabled}=0;
  slog('Autoregistration disabled',3);
}

sub onLobbyLogin {
  my $self=shift;
  return unless($self->{enabled});
  my $lobby=getLobbyInterface();
  $lobby->{pendingRequests}{LOGIN}[0]{DENIED}=\&hLobbyDenied;
  $lobby->{pendingRequests}{LOGIN}[0]{AGREEMENTEND}=\&hLobbyAgreementEnd;
}

sub hLobbyDenied {
  my (undef,$loginDeniedReason)=@_;
  
  if($loginDeniedReason ne 'Invalid username or password') {
    ::cbLoginDenied(undef,$loginDeniedReason);
    return;
  }
  slog('Login denied, trying to auto-register',3);
  
  my $lobby=getLobbyInterface();
  my $r_conf=getSpadsConf();
  my $lobbyLogin=$r_conf->{lobbyLogin};
  my $lobbyLoginInEmail=$lobbyLogin;
  $lobbyLoginInEmail=~s/[\[\]]/_/g;
  
  my @registerCommand=('REGISTER',$lobbyLogin,$lobby->marshallPasswd($r_conf->{lobbyPassword}));
  
  my $registrationEmail=getPluginConf()->{registrationEmail};
  $registrationEmail =~ s/\%LOBBY_LOGIN\%/$lobbyLoginInEmail/g;
  push(@registerCommand,$registrationEmail) unless($registrationEmail eq '');
  
  queueLobbyCommand(\@registerCommand,
                    { REGISTRATIONDENIED => sub { ::cbLoginDenied(undef,$loginDeniedReason." | failed to auto-register: $_[1]") },
                      REGISTRATIONACCEPTED => sub {
                        slog('Registration accepted',3);
                        my $localLanIp=$r_conf->{localLanIp};
                        $localLanIp=::getLocalLanIp() unless($localLanIp);
                        my $legacyFlags = ($lobby->{serverParams}{protocolVersion} =~ /^(\d+\.\d+)/ && $1 > 0.36) ? '' : ' l t cl';
                        queueLobbyCommand(['LOGIN',$lobbyLogin,$lobby->marshallPasswd($r_conf->{lobbyPassword}),0,$localLanIp,"SPADS v$::spadsVer",0,'b sp'.$legacyFlags],
                                          {ACCEPTED => \&::cbLoginAccepted,
                                           DENIED => \&::cbLoginDenied,
                                           AGREEMENTEND => \&hLobbyAgreementEnd},
                                          \&::cbLoginTimeout);
                      } },
                    \&::cbLoginTimeout);
}

sub hLobbyAgreementEnd {
  my $delayForAgreement=getPluginConf()->{agreementAutoAcceptDelay};
  if($delayForAgreement) {
    slog("Waiting $delayForAgreement second".($delayForAgreement>1?'s':'').' before confirming agreement',3);
    sleep($delayForAgreement);
  }
  queueLobbyCommand(['CONFIRMAGREEMENT'],
                    {ACCEPTED => \&::cbLoginAccepted,
                     DENIED => \&::cbLoginDenied},
                    \&::cbLoginTimeout);
}

1;
