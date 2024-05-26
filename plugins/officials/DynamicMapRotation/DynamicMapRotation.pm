package DynamicMapRotation;

use strict;

use File::Spec::Functions qw/catfile/;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.3';
my $requiredSpadsVersion='0.11.10';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

my @dynamicMapRotationFields=(['targetNbTeams','targetTeamSize','targetMinTeamSize','nbPlayers','currentNbTeams','currentTeamSize','startPosType'],['rotationMapList']);

sub new {
  my ($class,$context)=@_;
  my $self = { rules => {} };
  bless($self,$class);
  return undef unless($self->onReloadConf());
  slog("Plugin loaded (version $pluginVersion) [$context]",3);
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
  my ($self,$reason)=@_;
  slog("Plugin unloaded [$reason]",3);
}

sub filterRotationMaps {
  my ($self,$r_rotationMaps)=@_;

  my $dynamicRotationMapList=$self->getCurrentDynamicRotationMapList();
  return $r_rotationMaps unless(defined $dynamicRotationMapList);
  
  my @filteredMaps;
  my $r_mapFilters=getSpadsConfFull()->{mapLists}{$dynamicRotationMapList};
  foreach my $mapName (@{$r_rotationMaps}) {
    for my $i (0..$#{$r_mapFilters}) {
      my $mapFilter=$r_mapFilters->[$i];
      if($mapFilter =~ /^!(.*)$/) {
        my $realMapFilter=$1;
        last if($mapName =~ /^$realMapFilter$/);
      }elsif($mapName =~ /^$mapFilter$/) {
        $filteredMaps[$i]//=[];
        push(@{$filteredMaps[$i]},$mapName);
        last;
      }
    }
  }

  return SpadsConf::mergeMapArrays(\@filteredMaps);
}

sub getCurrentDynamicRotationMapList {
  my $self=shift;
  my $lobby=getLobbyInterface();
  return unless(getLobbyState() > 5 && %{$lobby->{battle}});

  my $p_spadsConf=getSpadsConf();
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
  my $p_mapLists=SpadsConf::findMatchingData($p_currentContext,$self->{rules});
  return $p_mapLists->[0]->{rotationMapList} if(@{$p_mapLists});
  return;
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
