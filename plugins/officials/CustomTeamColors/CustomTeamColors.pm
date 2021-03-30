package CustomTeamColors;

use strict;

use File::Spec::Functions qw/catfile/;
use List::Util qw'all max';

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.12.34';

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }

my @cutomTeamColorsRulesFields=(['nbTeams','teamSize','aiBotTeamSize'],['teamsColors']);

sub new {
  my $class=shift;
  my $self = { customColors => {},
               colorRules => [] };
  bless($self,$class);
  return undef unless($self->onReloadConf());
  slog("Plugin loaded (version $pluginVersion)",3);
  return $self;
}

sub parseLcColorDef {
  my $colorDef=shift;
  $colorDef='#'."$1$1$2$2$3$3" if($colorDef=~ /^#([0-9a-f])([0-9a-f])([0-9a-f])$/);
  my %color;
  if($colorDef =~ /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/) {
    my ($red,$green,$blue)=map {hex($_)} ($1,$2,$3);
    %color=(red => $red, green => $green, blue => $blue);
  }elsif($colorDef =~ /^rgb\(\s*(\d{1,3}\%?)\s*,\s*(\d{1,3}\%?)\s*,\s*(\d{1,3}\%?)\s*\)$/) {
    my ($red,$green,$blue)=($1,$2,$3);
    ($red,$green,$blue) = map {/^(\d+)\%$/ ? int($1*2.55+0.5) : $_+0} ($red,$green,$blue);
    return undef unless(all {$_ < 256} ($red,$green,$blue));
    %color=(red => $red, green => $green, blue => $blue);
  }elsif($colorDef =~ /^hsl\(\s*(\d{1,3})\s*,\s*(\d{1,3}(?:\.\d{1,3})?\%?)\s*,\s*(\d{1,3}(?:\.\d{1,3})?\%?)\s*\)$/) {
    my ($hue,$saturation,$lightness)=($1,$2,$3);
    return undef unless($hue < 360);
    ($saturation,$lightness) = map {/^(.+)\%$/ ? $1/100 : $_} ($saturation,$lightness);
    return undef unless(all {$_ <= 1} ($saturation,$lightness));
    my ($red,$green,$blue)=::hslToRgb($hue,$saturation,$lightness);
    %color=(red => $red, green => $green, blue => $blue);
  }elsif($colorDef =~ /^hsv\(\s*(\d{1,3})\s*,\s*(\d{1,3}(?:\.\d{1,3})?\%?)\s*,\s*(\d{1,3}(?:\.\d{1,3})?\%?)\s*\)$/) {
    my ($hue,$saturation,$value)=($1,$2,$3);
    return undef unless($hue < 360);
    ($saturation,$value) = map {/^(.+)\%$/ ? $1/100 : $_} ($saturation,$value);
    return undef unless(all {$_ <= 1} ($saturation,$value));
    my ($red,$green,$blue)=::hsvToRgb($hue,$saturation,$value);
    %color=(red => $red, green => $green, blue => $blue);
  }else{
    return undef;
  }
  return \%color;
}

sub onReloadConf {
  my $self=shift;
  
  my $etcDir=getSpadsConf()->{etcDir};
  
  my $customColorsFile=catfile($etcDir,'CustomTeamColors.colors.conf');
  if(! -f $customColorsFile) {
    slog("Custom colors definition file not found: $customColorsFile",1);
    return 0;
  }
  my $openRes=open(my $customColorsFh,'<',$customColorsFile);
  if(! $openRes || ! $customColorsFh) {
    slog("Unable to read configuration file ($customColorsFile: $!)",1);
    return 0;
  }
  my %customColors;
  while(local $_ = <$customColorsFh>) {
    next if(/^\s*(?:\#.*)?$/);
    if(/^\s*([^\s:]*[^\s:])\s*:\s*((?:.*[^\s])?)\s*$/) {
      my ($colorName,$colorDef)=map {lc($_)} ($1,$2);
      if(exists $customColors{$colorName}) {
        slog("Duplicate definition for color \"$colorName\" found in file \"$customColorsFile\"",1);
        return 0;
      }
      $customColors{$colorName}=parseLcColorDef($colorDef);
      if(! defined $customColors{$colorName}) {
        slog("Invalid color definition \"$colorDef\" found for color \"$colorName\" in file \"$customColorsFile\"",1);
        return 0;
      }
    }else{
      chomp($_);
      slog("Invalid configuration line \"$_\" in file \"$customColorsFile\"",2);
      return 0;
    }
  }
  close($customColorsFh);

  my $colorRulesFile=catfile($etcDir,'CustomTeamColors.rules.conf');
  my $spads=getSpadsConfFull();
  my $r_rules=SpadsConf::loadTableFile($spads->{log},$colorRulesFile,\@cutomTeamColorsRulesFields,$spads->{macros});
  return 0 unless(%{$r_rules});
  foreach my $r_colorRule (@{$r_rules->{''}}) {
    return 0 unless($#{$r_colorRule} == 1 && %{$r_colorRule->[1]} && exists $r_colorRule->[1]{teamsColors});
    my @teamColorsDefs=split(/\s+/,$r_colorRule->[1]{teamsColors});
    foreach my $teamColorsDef (@teamColorsDefs) {
      my @colorDefs=split(/;/,$teamColorsDef);
      foreach my $colorDef (@colorDefs) {
        $colorDef=lc($colorDef);
        if(exists $customColors{$colorDef}) {
          $colorDef=$customColors{$colorDef};
        }elsif(my $r_color = parseLcColorDef($colorDef)) {
          $colorDef=$r_color;
        }else{
          slog("Invalid color \"$colorDef\" referenced in \"$colorRulesFile\"",1);
          return 0;
        }
      }
      $teamColorsDef=\@colorDefs;
    }
    $r_colorRule->[1]{teamsColors}=\@teamColorsDefs;
  }
  $self->{customColors}=\%customColors;
  $self->{colorRules}=$r_rules->{''};
  return 1;
  
}

sub onUnload {
  slog('Plugin unloaded',3);
}

sub fixColors {
  my ($self,$r_battleStructure)=@_[0,3];
  
  my @orderedTeamNbs = sort {$a <=> $b} keys %{$r_battleStructure};
  
  my $nbTeams=scalar @orderedTeamNbs;
  my $teamSize=max(map {scalar keys %{$r_battleStructure->{$_}}} @orderedTeamNbs);
  my $aiBotTeamSize=0;
  
  my ($playerTeam,$aiBotTeam);
  if($nbTeams == 2) {
    foreach my $teamNb (@orderedTeamNbs) {
      my $r_idsInTeam=$r_battleStructure->{$teamNb};
      if(all {@{$r_idsInTeam->{$_}{players}} && ! @{$r_idsInTeam->{$_}{bots}} } (keys %{$r_idsInTeam})) {
        $playerTeam=$teamNb;
      }elsif(all {@{$r_idsInTeam->{$_}{bots}} && ! @{$r_idsInTeam->{$_}{players}} } (keys %{$r_idsInTeam})) {
        $aiBotTeam=$teamNb;
      }
    }
    if(defined $playerTeam && defined $aiBotTeam) {
      $teamSize=scalar keys %{$r_battleStructure->{$playerTeam}};
      $aiBotTeamSize=scalar keys %{$r_battleStructure->{$aiBotTeam}};
    }
  }
  
  my %context=(nbTeams => $nbTeams, teamSize => $teamSize, aiBotTeamSize => $aiBotTeamSize);

  my %idColors;
  my $r_teamsColorsList=SpadsConf::findMatchingData(\%context,$self->{colorRules});
  if(@{$r_teamsColorsList}) {
    my $r_teamsColors=$r_teamsColorsList->[0]{teamsColors};
    if($aiBotTeamSize && $playerTeam > $aiBotTeam) {
      $r_teamsColors=[$r_teamsColors->[1],$r_teamsColors->[0]];
    }
    for my $teamIdx (0..$#orderedTeamNbs) {
      my $team=$orderedTeamNbs[$teamIdx];
      my $r_teamColors=$r_teamsColors->[$teamIdx];
      last unless(defined $r_teamColors);
      my @orderedIdNbs=sort {$a <=> $b} keys %{$r_battleStructure->{$team}};
      for my $idIdx (0..$#orderedIdNbs) {
        my $r_color=$r_teamColors->[$idIdx];
        last unless(defined $r_color);
        $idColors{$orderedIdNbs[$idIdx]}=$r_color;
      }
    }
  }else{
    return undef;
  }

  return \%idColors;
}

1;
