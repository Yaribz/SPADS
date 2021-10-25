package ClientStatusEvents;

use strict;

use List::Util 'any';

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.12.45';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);
  onLobbyConnected() if(getLobbyState() > 3);
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onLobbyConnected {
  addLobbyCommandHandler({CLIENTSTATUS => \&hLobbyPreClientStatus,
                          CLIENTBATTLESTATUS => \&hLobbyPreClientBattleStatus,
                          UPDATEBOT => \&hLobbyPreUpdateBot},undef,1);
  addLobbyCommandHandler({ADDBOT => \&hLobbyAddBot});
}

sub onUnload {
  removeLobbyCommandHandler(['CLIENTSTATUS','CLIENTBATTLESTATUS','UPDATEBOT'],undef,1);
  removeLobbyCommandHandler(['ADDBOT']);
}

sub hLobbyPreClientStatus {
  my (undef,$user,$status)=@_;
  my $lobby=getLobbyInterface();
  if(! exists $lobby->{users}{$user}) {
    slog("Ignoring invalid CLIENTSTATUS command (unknown client $user)",1);
    return;
  }
  my $p_newClientStatus=$lobby->unmarshallClientStatus($status);
  my %changes;
  foreach my $field (keys %{$p_newClientStatus}) {
    my $previousVal=$lobby->{users}{$user}{status}{$field};
    my $newVal=$p_newClientStatus->{$field};
    $changes{$field}={old => $previousVal, new => $newVal} if($newVal != $previousVal);
  }
  return unless(%changes);
  my $r_pluginsOrder=getPluginList();
  foreach my $pluginName (@{$r_pluginsOrder}) {
    my $plugin=getPlugin($pluginName);
    $plugin->onClientStatusChange($user,\%changes) if($plugin->can('onClientStatusChange'));
    if(exists $changes{inGame}) {
      if($changes{inGame}{new}) {
        $plugin->onClientInGame($user) if($plugin->can('onClientInGame'));
      }else{
        $plugin->onClientOutOfGame($user) if($plugin->can('onClientOutOfGame'));
      }
    }
    if(exists $changes{rank}) {
      $plugin->onClientRankChange($user,$changes{rank}{old},$changes{rank}{new}) if($plugin->can('onClientRankChange'));
    }
    if(exists $changes{away}) {
      if($changes{away}{new}) {
        $plugin->onClientAway($user) if($plugin->can('onClientAway'));
      }else{
        $plugin->onClientBack($user) if($plugin->can('onClientBack'));
      }
    }
  }
}

sub hLobbyPreClientBattleStatus {
  my (undef,$user,$status,$color)=@_;
  
  my $lobby=getLobbyInterface();
  if(! %{$lobby->{battle}}) {
    slog("Ignoring invalid CLIENTBATTLESTATUS command (battle is closed)",1);
    return;
  }
  if(! exists $lobby->{battle}{users}{$user}) {
    slog("Ignoring invalid CLIENTBATTLESTATUS command (client not in battle: $user)",1);
    return;
  }
  
  my $p_newClientStatus=$lobby->unmarshallBattleStatus($status);
  my $p_newClientColor=$lobby->unmarshallColor($color);
  if(! defined $lobby->{battle}{users}{$user}{battleStatus}) {
    my $r_pluginsOrder=getPluginList();
    foreach my $pluginName (@{$r_pluginsOrder}) {
      my $plugin=getPlugin($pluginName);
      $plugin->onNewBattleClient($user,$p_newClientStatus,$p_newClientColor) if($plugin->can('onNewBattleClient'));
    }
    return;
  }
  
  my %changes;
  foreach my $field (keys %{$p_newClientStatus}) {
    next if(substr($field,0,10) eq 'workaround');
    my $previousVal=$lobby->{battle}{users}{$user}{battleStatus}{$field};
    my $newVal=$p_newClientStatus->{$field};
    $changes{$field}={old => $previousVal, new => $newVal} if($newVal != $previousVal);
  }

  my $p_previousClientColor=$lobby->{battle}{users}{$user}{color};
  my $colorChanged = any {$p_previousClientColor->{$_} != $p_newClientColor->{$_}} (keys %{$p_newClientColor});
  
  return unless(%changes || $colorChanged);
  
  my $r_pluginsOrder=getPluginList();
  foreach my $pluginName (@{$r_pluginsOrder}) {
    my $plugin=getPlugin($pluginName);
    if(%changes) {
      $plugin->onClientBattleStatusChange($user,\%changes) if($plugin->can('onClientBattleStatusChange'));
      if(exists $changes{side}) {
        $plugin->onClientSideChange($user,$changes{side}{old},$changes{side}{new}) if($plugin->can('onClientSideChange'));
      }
      if(exists $changes{sync}) {
        $plugin->onClientSyncChange($user,$changes{sync}{old},$changes{sync}{new}) if($plugin->can('onClientSyncChange'));
      }
      if(exists $changes{bonus}) {
        $plugin->onClientBonusChange($user,$changes{bonus}{old},$changes{bonus}{new}) if($plugin->can('onClientBonusChange'));
      }
      if(exists $changes{mode}) {
        if($changes{mode}{new}) {
          $plugin->onClientUnspec($user) if($plugin->can('onClientUnspec'));
        }else{
          $plugin->onClientSpec($user) if($plugin->can('onClientSpec'));
        }
      }
      if(exists $changes{team}) {
        $plugin->onClientTeamChange($user,$changes{team}{old},$changes{team}{new}) if($plugin->can('onClientTeamChange'));
      }
      if(exists $changes{id}) {
        $plugin->onClientIdChange($user,$changes{id}{old},$changes{id}{new}) if($plugin->can('onClientIdChange'));
      }
      if(exists $changes{ready}) {
        if($changes{ready}{new}) {
          $plugin->onClientReady($user) if($plugin->can('onClientReady'));
        }else{
          $plugin->onClientUnready($user) if($plugin->can('onClientUnready'));
        }
      }
    }
    if($colorChanged) {
      $plugin->onClientColorChange($user,$p_previousClientColor,$p_newClientColor) if($plugin->can('onClientColorChange'));
    }
  }
}

sub hLobbyAddBot {
  my (undef,undef,$name,$owner,$status,$color,$aiDll)=@_;
  
  my $lobby=getLobbyInterface();
  if(! %{$lobby->{battle}}) {
    slog("Ignoring invalid ADDBOT command (battle is closed)",1);
    return;
  }

  my $r_aiBotBattleStatus=$lobby->unmarshallBattleStatus($status);
  my $r_aiBotColor=$lobby->unmarshallColor($color);
  
  my $r_pluginsOrder=getPluginList();
  foreach my $pluginName (@{$r_pluginsOrder}) {
    my $plugin=getPlugin($pluginName);
    $plugin->onNewBattleAiBot($name,$r_aiBotBattleStatus,$r_aiBotColor,$owner,$aiDll) if($plugin->can('onNewBattleAiBot'));
  }
}

sub hLobbyPreUpdateBot {
  my (undef,undef,$name,$status,$color)=@_;
  
  my $lobby=getLobbyInterface();
  if(! %{$lobby->{battle}}) {
    slog("Ignoring invalid UPDATEBOT command (battle is closed)",1);
    return;
  }
  if(! exists $lobby->{battle}{bots}{$name}) {
    slog("Ignoring invalid UPDATEBOT command (AI bot not in battle: $name)",1);
    return;
  }
  
  my $p_newAiBotStatus=$lobby->unmarshallBattleStatus($status);
  my $p_newAiBotColor=$lobby->unmarshallColor($color);
  
  my %changes;
  foreach my $field (keys %{$p_newAiBotStatus}) {
    next if(substr($field,0,10) eq 'workaround');
    my $previousVal=$lobby->{battle}{bots}{$name}{battleStatus}{$field};
    my $newVal=$p_newAiBotStatus->{$field};
    $changes{$field}={old => $previousVal, new => $newVal} if($newVal != $previousVal);
  }
  
  my $p_previousAiBotColor=$lobby->{battle}{bots}{$name}{color};
  my $colorChanged = any {$p_previousAiBotColor->{$_} != $p_newAiBotColor->{$_}} (keys %{$p_newAiBotColor});
  
  return unless(%changes || $colorChanged);
  
  my $r_pluginsOrder=getPluginList();
  foreach my $pluginName (@{$r_pluginsOrder}) {
    my $plugin=getPlugin($pluginName);
    if(%changes) {
      $plugin->onAiBotBattleStatusChange($name,\%changes) if($plugin->can('onAiBotBattleStatusChange'));
      if(exists $changes{side}) {
        $plugin->onAiBotSideChange($name,$changes{side}{old},$changes{side}{new}) if($plugin->can('onAiBotSideChange'));
      }
      if(exists $changes{bonus}) {
        $plugin->onAiBotBonusChange($name,$changes{bonus}{old},$changes{bonus}{new}) if($plugin->can('onAiBotBonusChange'));
      }
      if(exists $changes{team}) {
        $plugin->onAiBotTeamChange($name,$changes{team}{old},$changes{team}{new}) if($plugin->can('onAiBotTeamChange'));
      }
      if(exists $changes{id}) {
        $plugin->onAiBotIdChange($name,$changes{id}{old},$changes{id}{new}) if($plugin->can('onAiBotIdChange'));
      }
    }
    if($colorChanged) {
      $plugin->onAiBotColorChange($name,$p_previousAiBotColor,$p_newAiBotColor) if($plugin->can('onAiBotColorChange'));
    }
  }
}

1;
