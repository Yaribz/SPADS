package RecommendedMap;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.20c';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
my %presetPluginParams = ( useRecommendedMaps => ['bool'],
                           useRecommendedBoxes => ['bool2'] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }
sub getDependencies { return ('SpringieExtension'); }

sub new {
  my $class=shift;
  my $self = {};
  bless($self,$class);

  addSpadsCommandHandler({adaptmap => \&hSpadsAdaptMap});

  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub onUnload {
  removeSpadsCommandHandler(['adaptmap']);
  slog("Plugin unloaded",3);
}

sub hSpadsAdaptMap {
  my ($source,$user,$p_params,$checkOnly)=@_;

  if($#{$p_params} > 1) {
    invalidSyntax($user,'adaptmap');
    return 0;
  }

  if(getLobbyState() < 6) {
    answer('Unable to adapt map, battle is closed!');
    return 0;
  }

  my ($gameType,$nbPlayers)=@{$p_params};
  if(! defined $nbPlayers && defined $gameType && $gameType =~ /^\d+$/) {
    $nbPlayers=$gameType;
    $gameType=undef;
  }

  if(defined $gameType) {
    my %validGameTypes=(duel=>'Duel',team=>'Team',ffa=>'FFA',chicken=>'Chicken');
    if(! exists $validGameTypes{lc($gameType)}) {
      invalidSyntax($user,'adaptmap',"invalid game type \"$gameType\", allowed values: ".(join(',',values %validGameTypes)).'"');
      return 0;
    }
    $gameType=$validGameTypes{lc($gameType)};
  }

  if(defined $nbPlayers) {
    if($nbPlayers !~ /^\d+$/) {
      invalidSyntax($user,'adaptmap');
      return 0;
    }
    $nbPlayers=16 if($nbPlayers > 16);
  }else{
    $nbPlayers=getCurrentNumberOfPlayers();
  }

  return 1 if($checkOnly);

  my $springieExt=getPlugin('SpringieExtension');
  my $autohostName=$springieExt->getNameOfSimilarSpringieAutohost($gameType);
  my $recommendedMap=$springieExt->GetRecommendedMap($nbPlayers,$autohostName);
  if(! defined $recommendedMap) {
    slog("Unable to find a recommended map through SpringieService/GetRecommendedMap web service",2);
    answer("Unable to find a recommended map (technical error)");
    return 0;
  }
  my $p_spadsConf=getSpadsConf();
  if($recommendedMap eq $p_spadsConf->{map}) {
    slog("Ignoring map recommended by SpringieService/GetRecommendedMap web service (same as current map)",5);
    answer("Recommended map is already current map");
    return 1;
  }

  my $mapIsAllowed=0;
  my $spads=getSpadsConfFull();
  foreach my $mapNb (keys %{$spads->{maps}}) {
    if($spads->{maps}->{$mapNb} eq $recommendedMap) {
      $mapIsAllowed=1;
      last;
    }
  }
  if(! $mapIsAllowed) {
    $mapIsAllowed=1 if($p_spadsConf->{allowGhostMaps} && getSpringServerType() eq 'dedicated' && exists $spads->{ghostMaps}->{$recommendedMap});
  }
  if(! $mapIsAllowed) {
    slog("Ignoring map \"$recommendedMap\" recommended by SpringieService/GetRecommendedMap web service (not in current map list)",4);
    answer("Recommended map not available on this server: $recommendedMap");
    return 1;
  }

  return ::executeCommand($source,$user,['set','map',$recommendedMap]);
}

sub filterRotationMaps {
  my (undef,$p_rotationMaps)=@_;
  return $p_rotationMaps unless(getLobbyState() > 5 && getPluginConf()->{useRecommendedMaps});

  my $nbPlayers=getCurrentNumberOfPlayers();
  my $springieExt=getPlugin('SpringieExtension');
  my $autohostName=$springieExt->getNameOfSimilarSpringieAutohost();

  my $recommendedMap=$springieExt->GetRecommendedMap($nbPlayers,$autohostName);
  if(! defined $recommendedMap) {
    slog("Unable to find a recommended map through SpringieService/GetRecommendedMap web service",2);
    return $p_rotationMaps;
  }
  my $p_spadsConf=getSpadsConf();
  if($recommendedMap eq $p_spadsConf->{map}) {
    slog("Ignoring map recommended by SpringieService/GetRecommendedMap web service (same as current map)",5);
    return $p_rotationMaps;
  }

  my $mapIsAllowed=0;
  my $spads=getSpadsConfFull();
  foreach my $mapNb (keys %{$spads->{maps}}) {
    if($spads->{maps}->{$mapNb} eq $recommendedMap) {
      $mapIsAllowed=1;
      last;
    }
  }
  if(! $mapIsAllowed) {
    $mapIsAllowed=1 if($p_spadsConf->{allowGhostMaps} && getSpringServerType() eq 'dedicated' && exists $spads->{ghostMaps}->{$recommendedMap});
  }
  if(! $mapIsAllowed) {
    slog("Ignoring map \"$recommendedMap\" recommended by SpringieService/GetRecommendedMap web service (not in current map list)",4);
    return $p_rotationMaps;
  }

  return [$p_spadsConf->{map},$recommendedMap];
}

sub setMapStartBoxes {
  my ($self,$p_boxes,$mapName)=@_;
  my $p_conf=getPluginConf();
  return 0 unless($p_conf->{useRecommendedBoxes});
  return 0 if(@{$p_boxes} && $p_conf->{useRecommendedBoxes} == 2);
  my $mapCommandsString=getPlugin('SpringieExtension')->GetMapCommands($mapName);
  return 0 unless(defined $mapCommandsString);
  my @mapCommands=split(/\n/,$mapCommandsString);
  my $firstBox=1;
  foreach my $mapCommand (@mapCommands) {
    if($mapCommand =~ /^\!addbox (\d+) (\d+) (\d+) (\d+)/) {
      my %springieCoor=(left => $1,
                        top => $2,
                        width => $3,
                        height => $4);
      my %coor=(left => 2*$springieCoor{left},
                top => 2*$springieCoor{top});
      $coor{right}=$coor{left}+2*$springieCoor{width};
      $coor{bottom}=$coor{top}+2*$springieCoor{height};
      foreach my $c (keys %coor) {
        if($coor{$c} > 200) {
          slog("Invalid $c coordinate received from SpringieService/GetMapCommands web service for map $mapName",2);
          $coor{$c}=200;
        }
      }
      if($firstBox) {
        $firstBox=0;
        $#{$p_boxes}=-1;
      }
      push(@{$p_boxes},"$coor{left} $coor{top} $coor{right} $coor{bottom}");
    }elsif($mapCommand =~ /^\!split ([hv] \d+)$/) {
      push(@{$p_boxes},$1);
    }
  }
  return 0;
}


sub getCurrentNumberOfPlayers {
  my $nbEntities;
  my $lobby=getLobbyInterface();
  my $p_bUsers=$lobby->{battle}->{users};
  foreach my $bUser (keys %{$p_bUsers}) {
    ++$nbEntities if(defined $p_bUsers->{$bUser}->{battleStatus} && $p_bUsers->{$bUser}->{battleStatus}->{mode});
  }
  my @bots=keys %{$lobby->{battle}->{bots}};
  $nbEntities+=$#bots+1;
  return $nbEntities;
}
1;
