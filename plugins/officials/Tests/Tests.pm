package Tests;

use strict;

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.5';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

my $currentTestIdx=0;

# Test functions order
my @TESTS = (
  \&checkLobbyLoggedIn,
  \&checkLobbyBattleOpened,
    );

sub testFailed {
  my $reason=shift;
  slog('Test #'.($currentTestIdx+1).' failed'.(defined $reason ? " ($reason)" : ''),2);
  quit(1,'Tests failed',::EXIT_FAILURE);
}

sub testSucceeded {
  slog('Test #'.($currentTestIdx+1).' succeeded',3);
  if($currentTestIdx < $#TESTS) {
    $TESTS[++$currentTestIdx]();
  }else{
    quit(1,'Tests succeeded',::EXIT_SUCCESS);
  }
}

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  slog("Plugin loaded (version $pluginVersion)",3);
  $TESTS[$currentTestIdx]();
  addTimer('Tests',10,0,\&doTests);
  return $self;
}


# Test functions declarations

sub checkLobbyLoggedIn {
  if(getLobbyState() >= LOBBY_STATE_LOGGED_IN) {
    testSucceeded();
  }else{
    addTimer('TestTimeout',5,0,sub {
      removeLobbyCommandHandler(['ACCEPTED','DENIED']);
      testFailed('TIMEOUT');
             });
    addLobbyCommandHandler({
      ACCEPTED => sub {
        removeTimer('TestTimeout');
        removeLobbyCommandHandler(['ACCEPTED','DENIED']);
        testSucceeded();
      },
      DENIED => sub {
        removeTimer('TestTimeout');
        removeLobbyCommandHandler(['ACCEPTED','DENIED']);
        testFailed('LOGIN DENIED');
      },
                           });
  }
}
    
sub checkLobbyBattleOpened {
  if(getLobbyState() >= LOBBY_STATE_BATTLE_OPENED) {
    testSucceeded();
  }else{
    addTimer('TestTimeout',5,0,sub {
      removeLobbyCommandHandler(['OPENBATTLE','OPENBATTLEFAILED']);
      testFailed('TIMEOUT');
             });
    addLobbyCommandHandler({
      OPENBATTLE => sub {
        removeTimer('TestTimeout');
        removeLobbyCommandHandler(['OPENBATTLE','OPENBATTLEFAILED']);
        testSucceeded();
      },
      OPENBATTLEFAILED => sub {
        removeTimer('TestTimeout');
        removeLobbyCommandHandler(['OPENBATTLE','OPENBATTLEFAILED']);
        testFailed('OPENBATTLEFAILED');
      },
                           });
  }
}

1;
