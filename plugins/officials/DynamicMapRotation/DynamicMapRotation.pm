package DynamicMapRotation;

use strict;

use File::Spec::Functions qw/catfile/;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.2';
my $requiredSpadsVersion='0.11.5';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

my @dynamicMapRotationFields=(['targetNbTeams','targetTeamSize','targetMinTeamSize','nbPlayers','currentNbTeams','currentTeamSize','startPosType'],['rotationMapList']);

sub new {
  my $class=shift;
  my $self = { rules => {},
               previousContext => { targetNbTeams => 0,
                                    targetTeamSize => 0,
                                    targetMinTeamSize => 0,
                                    nbPlayers => 0,
                                    currentNbTeams => 0,
                                    currentTeamSize => 0,
                                    startPosType => 0 },
               previousRotationType => undef };
  bless($self,$class);
  return undef unless($self->onReloadConf());
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onReloadConf {
  my $self=shift;
  my $p_spadsConf=getSpadsConf();
  my $spads=getSpadsConfFull();
  my $p_rules=SpadsConf::loadTableFile($spads->{log},catfile($p_spadsConf->{etcDir},'DynamicMapRotation.conf'),\@dynamicMapRotationFields,$spads->{macros});
  return 0 unless(%{$p_rules});
  foreach my $p_mapListRule (@{$p_rules->{''}}) {
    return 0 unless($#{$p_mapListRule} == 1 && %{$p_mapListRule->[1]} && exists $p_mapListRule->[1]->{rotationMapList});
    if(! exists $spads->{mapLists}{$p_mapListRule->[1]->{rotationMapList}}) {
      slog("Invalid map list \"$p_mapListRule->[1]->{rotationMapList}\" (referenced in DynamicMapRotation.conf but not defined in mapLists.conf)",1);
      return 0;
    }
  }
  $self->{rules}=$p_rules->{''};
  return 1;
}

sub onUnload {
  slog("Plugin unloaded",3);
}

sub eventLoop {
  my $self=shift;
  my $lobby=getLobbyInterface();
  return unless(getLobbyState() > 5 && %{$lobby->{battle}});

  my $p_spadsConf=getSpadsConf();
  return unless($p_spadsConf->{rotationType} =~ /^map(;.+)?$/);

  my $spads=getSpadsConfFull();
  
  my ($nbHumanPlayers,$nbAiBots)=getCurrentNumberOfPlayers();
  my ($currentNbTeams,$currentTeamSize)=::getTargetBattleStructure($p_spadsConf->{nbTeams} == 1 ? $nbHumanPlayers : $nbHumanPlayers+$nbAiBots);
  my $p_currentContext = { targetNbTeams => $p_spadsConf->{nbTeams},
                           targetTeamSize => $p_spadsConf->{teamSize},
                           targetMinTeamSize => $p_spadsConf->{minTeamSize} ? $p_spadsConf->{minTeamSize} : $p_spadsConf->{teamSize},
                           nbPlayers => $nbHumanPlayers+$nbAiBots,
                           currentNbTeams => $currentNbTeams,
                           currentTeamSize => $currentTeamSize,
                           startPosType => $spads->{bSettings}{startpostype} };
  my $needNewCheck=0;
  foreach my $contextData (keys %{$p_currentContext}) {
    if($p_currentContext->{$contextData} != $self->{previousContext}{$contextData}) {
      $needNewCheck=1;
      last;
    }
  }
  $needNewCheck=1 unless(defined $self->{previousRotationType} && $p_spadsConf->{rotationType} eq $self->{previousRotationType});
  return unless($needNewCheck);
  $self->{previousContext}=$p_currentContext;
  my $p_mapLists=SpadsConf::findMatchingData($p_currentContext,$self->{rules});
  if(@{$p_mapLists}) {
    $p_spadsConf->{rotationType}="map;$p_mapLists->[0]->{rotationMapList}";
  }else{
    $p_spadsConf->{rotationType}='map';
  }
  $spads->{conf}{rotationType}=$p_spadsConf->{rotationType};
  $self->{previousRotationType}=$p_spadsConf->{rotationType};
}


sub getCurrentNumberOfPlayers {
  my ($nbHumanPlayers,$nbAiBots)=(0,0);
  my $lobby=getLobbyInterface();
  my $p_bUsers=$lobby->{battle}{users};
  foreach my $bUser (keys %{$p_bUsers}) {
    ++$nbHumanPlayers if(defined $p_bUsers->{$bUser}{battleStatus} && $p_bUsers->{$bUser}{battleStatus}{mode});
  }
  my @bots=keys %{$lobby->{battle}{bots}};
  $nbAiBots=$#bots+1;
  return ($nbHumanPlayers,$nbAiBots);
}

1;
