package CustomAliases;

use strict;

use SpadsPluginApi;

no warnings 'redefine';

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.11.2';

my %globalPluginParams = ( aliases => [] );

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,{}]; }

sub new {
  my $class=shift;
  my %aliases;
  my @aliasDefs=split(/;/,getPluginConf()->{aliases});
  foreach my $aliasDef (@aliasDefs) {
    if($aliasDef=~/^([^\(]+)\(([^\)]+)\)$/) {
      my ($aliasName,$aliasCmd)=($1,$2);
      my @aliasCmdTokens=split(/ /,$aliasCmd);
      $aliases{$aliasName}=\@aliasCmdTokens;
    }else{
      slog("Ignoring invalid alias definition \"$aliasDef\"",2);
    }
  }
  my $self = {aliases => \%aliases};
  bless($self,$class);
  my $nbAliases=keys %aliases;
  slog("Plugin loaded (version $pluginVersion): $nbAliases alias".($nbAliases > 1 ? 'es' : '').' configured',3);
  return $self;
}

sub updateCmdAliases {
  my ($self,$p_spadsAliases)=@_;
  foreach my $alias (keys %{$self->{aliases}}) {
    $p_spadsAliases->{$alias}=$self->{aliases}->{$alias};
  }
}

1;
