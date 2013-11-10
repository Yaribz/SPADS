package FirstWelcomeMsg;

use strict;

use Storable qw/store retrieve/;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.2';
my $requiredSpadsVersion='0.11.2';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my $class=shift;
  my $self = {welcomeMsg => [],
              welcomeMsgTs => 0,
              alreadySent => {},
              alreadySentTs => 0};
  bless($self,$class);
  $self->updateWelcomeMsgIfNeeded();
  my $alreadySentFile=getSpadsConf()->{varDir}.'/FirstWelcomeMsg.dat';
  if(-f $alreadySentFile) {
    my $p_alreadySent=retrieve($alreadySentFile);
    if(! defined $p_alreadySent) {
      slog("Unable to read welcome message persistent data file ($alreadySentFile)",1);
    }else{
      $self->{alreadySent}=$p_alreadySent;
    }
  }
  $self->{alreadySentTs}=time;
  addSpadsCommandHandler({firstWelcomeMsg => \&hSpadsFirstWelcomeMsg,
                          resendFirstWelcomeMsg => \&hSpadsResendFirstWelcomeMsg});
  addLobbyCommandHandler({JOINEDBATTLE => \&hLobbyJoinedBattle});
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onLobbyConnected {
  addLobbyCommandHandler({JOINEDBATTLE => \&hLobbyJoinedBattle});
}

sub updateWelcomeMsgIfNeeded {
  my $self=shift;
  my $welcomeMsgFile=getSpadsConf()->{etcDir}.'/FirstWelcomeMsg.txt';
  my $msgModifTs=0;
  $msgModifTs=(stat($welcomeMsgFile))[9] if(-f $welcomeMsgFile);
  if($self->{welcomeMsgTs} != $msgModifTs) {
    $self->{welcomeMsgTs}=$msgModifTs;
    if($msgModifTs) {
      if(open(WMSG,"<$welcomeMsgFile")) {
        my @newWelcomeMsg;
        while(<WMSG>) {
          chomp($_);
          push(@newWelcomeMsg,$_) if($_ ne '');
        }
        close(WMSG);
        $self->{welcomeMsg}=\@newWelcomeMsg;
      }else{
        slog("Unable to open welcome message file ($welcomeMsgFile)",2);
        $self->{welcomeMsg}=[];
      }
    }else{
      $self->{welcomeMsg}=[];
    }
  }
}

sub storeAlreadySentDataIfNeeded {
  my ($self,$force)=@_;
  $force=0 unless(defined $force);
  my $p_spadsConf=getSpadsConf();
  return unless($force || ($p_spadsConf->{dataDumpDelay} && time-$self->{alreadySentTs} > 60 * $p_spadsConf->{dataDumpDelay}));
  $self->{alreadySentTs}=time;
  my $alreadySentFile=$p_spadsConf->{varDir}.'/FirstWelcomeMsg.dat';
  slog("Unable to store welcome message persistent data in file $alreadySentFile",1) unless(store($self->{alreadySent},$alreadySentFile));
}

sub onUnload {
  my $self=shift;
  removeSpadsCommandHandler(['firstWelcomeMsg','resendFirstWelcomeMsg']);
  removeLobbyCommandHandler(['JOINEDBATTLE']);
  $self->storeAlreadySentDataIfNeeded(1);
  slog("Plugin unloaded",3);
}

sub eventLoop {
  my $self=shift;
  $self->storeAlreadySentDataIfNeeded();
}

sub hSpadsFirstWelcomeMsg {
  my (undef,$user,undef,$checkOnly)=@_;
  return 1 if($checkOnly);
  my $self=getPlugin();
  $self->updateWelcomeMsgIfNeeded();
  if(@{$self->{welcomeMsg}}) {
    sayPrivate($user,'First welcome message:');
    foreach my $line (@{$self->{welcomeMsg}}) {
      sayPrivate($user,$line);
    }
  }else{
    sayPrivate($user,'No first welcome message configured!');
  }
}

sub hSpadsResendFirstWelcomeMsg {
  my (undef,$user,undef,$checkOnly)=@_;
  return 1 if($checkOnly);
  my $self=getPlugin();
  $self->{alreadySent}={};
  unlink(getSpadsConf()->{varDir}.'/FirstWelcomeMsg.dat');
  $self->{alreadySentTs}=time;
  answer("Plugin persistent data reset (all players will receive the \"first welcome message\" another time)");
}

sub hLobbyJoinedBattle {
  my (undef,$battleId,$user)=@_;
  my $lobby=getLobbyInterface();
  if(%{$lobby->{battle}} && $battleId == $lobby->{battle}->{battleId}) {
    my $id=$lobby->{users}->{$user}->{accountId};
    my $self=getPlugin();
    if(! exists $self->{alreadySent}->{$id}) {
      $self->updateWelcomeMsgIfNeeded();
      if(@{$self->{welcomeMsg}}) {
        foreach my $line (@{$self->{welcomeMsg}}) {
          sayPrivate($user,$line);
        }
        $self->{alreadySent}->{$id}=time;
      }
    }
  }
}

1;
