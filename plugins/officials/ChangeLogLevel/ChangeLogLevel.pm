package ChangeLogLevel;

use warnings;
use strict;

use List::Util 'first';

use SpadsPluginApi;

my $pluginVersion='0.1';
my $requiredSpadsVersion='0.13.35';

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
my %presetPluginParams;

sub getVersion { return $pluginVersion; }
sub getRequiredSpadsVersion { return $requiredSpadsVersion; }
sub getParams { return [\%globalPluginParams,\%presetPluginParams]; }

my %LOG_CATEGORIES = map {lc($_) => $_} (qw'lobbyInterface autoHostInterface SPADS');
my @LOG_LEVEL_NAMES=(qw'CRITICAL ERROR WARNING NOTICE INFO DEBUG');
my %LOG_LEVELS = map {lc($LOG_LEVEL_NAMES[$_]) => $_} (0..$#LOG_LEVEL_NAMES);

sub new {
  my ($class,$context)=@_;
  my $self = { restoreLogLevelTimers => {} };
  bless($self,$class);
  addSpadsCommandHandler({setLogLevel => \&hSetLogLevel});
  slog("Plugin loaded (version $pluginVersion) [$context]",3);
  return $self;
}

sub onUnload {
  my ($self,$context)=@_;
  removeSpadsCommandHandler(['setLogLevel']);
  foreach my $timer (keys %{$self->{restoreLogLevelTimers}}) {
    removeTimer($timer);
    delete $self->{restoreLogLevelTimers}{$timer};
  }
  slog("Plugin unloaded [$context]",3);
}

sub hSetLogLevel {
  my ($source,$user,$r_params,$checkOnly)=@_;

  if($#{$r_params} > 2) {
    invalidSyntax($user,'setLogLevel');
    return 0;
  }

  my ($category,$level,$duration)=@{$r_params};

  if(defined $category && $category ne '*') {
    my $categoryParamLength=length($category);
    my $lcCategoryParam=lc($category);
    my $lcCategory = first {$lcCategoryParam eq substr($_,0,$categoryParamLength)} (keys %LOG_CATEGORIES);
    if(! defined $lcCategory) {
      invalidSyntax($user,'setLogLevel',"invalid log category \"$category\"");
      return 0;
    }
    $category=$LOG_CATEGORIES{$lcCategory};
  }else{
    $category='*';
  }

  if(defined $level) {
    if($level =~ /^\d+$/) {
      if($level > 5) {
        invalidSyntax($user,'setLogLevel',"invalid log level \"$level\"");
        return 0;
      }
      $level+=0;
    }else{
      my $levelParamLength=length($level);
      my $lcLevelParam=lc($level);
      my $lcLevel = first {$lcLevelParam eq substr($_,0,$levelParamLength)} (keys %LOG_LEVELS);
      if(! defined $lcLevel) {
        invalidSyntax($user,'setLogLevel',"invalid log level \"$level\"");
        return 0;
      }
      $level=$LOG_LEVELS{$lcLevel};
    }
  }

  if(defined $duration) {
    my %units=(
      y => 31536000,
      M => 2592000,
      w => 604800,
      d => 86400,
      h => 3600,
      m => 60,
      s => 1,
        );
    if($duration =~ /^(\d+)([smhdwMy])$/) {
      $duration = $1 * $units{$2};
    }elsif($duration =~ /^\d+$/) {
      $duration+=0;
    }else{
      invalidSyntax($user,'setLogLevel',"invalid duration \"$duration\"");
      return 0;
    }
  }
  
  return 1 if($checkOnly);

  my $r_spadsConf=getSpadsConf();
  my @categories = $category eq '*' ? (values %LOG_CATEGORIES) : ($category);
  foreach my $logCat (@categories) {
    my ($r_sl,$defaultLvl,$additionnalLvl);
    if($logCat eq 'lobbyInterface') {
      $r_sl=getLobbyInterface()->{conf}{simpleLog};
      $defaultLvl=$r_spadsConf->{lobbyInterfaceLogLevel};
    }elsif($logCat eq 'autoHostInterface') {
      $r_sl=getSpringInterface()->{conf}{simpleLog};
      $defaultLvl=$r_spadsConf->{autoHostInterfaceLogLevel};
    }elsif($logCat eq 'SPADS') {
      $r_sl=getSpadsConfFull()->{log};
      $defaultLvl=$r_spadsConf->{spadsLogLevel};
      $additionnalLvl=3;
    }else{
      my $internalError="Internal logic error: unrecognized log category \"$logCat\"";
      slog($internalError,0);
      answer($internalError);
      next;
    }
    my $newLvl=$level//$defaultLvl;
    my $newLvlName=$LOG_LEVEL_NAMES[$newLvl];
    my $previousLvl=$r_sl->{logs}[0]{level};
    my $previousLvlName=$LOG_LEVEL_NAMES[$previousLvl];
    if($previousLvl == $newLvl) {
      answer("Log level for $logCat category is already set to ".(defined $level ? $newLvlName : "default value ($newLvlName)"));
      next;
    }
    my $self=getPlugin();
    if($self->{restoreLogLevelTimers}{$logCat}) {
      removeTimer($logCat);
      delete $self->{restoreLogLevelTimers}{$logCat};
    }
    my $msg="Changing log level for $logCat category from $previousLvlName to $newLvlName";
    $msg.=' during '.secToTime($duration) if($duration);
    slog("$msg (by $user)",3);
    answer($msg);
    $r_sl->setLevels([$newLvl,$additionnalLvl//()]);
    if($duration) {
      $self->{restoreLogLevelTimers}{$logCat}=1;
      addTimer($logCat,$duration,0,sub {
        delete $self->{restoreLogLevelTimers}{$logCat};
        my $defaultLvlName=$LOG_LEVEL_NAMES[$defaultLvl];
        my $msg="Restoring log level for $logCat category to default value ($defaultLvlName)";
        slog($msg,3);
        sayPrivate($user,$msg)
            unless(getLobbyState() < LOBBY_STATE_SYNCHRONIZED || ! exists getLobbyInterface()->{users}{$user});
        $r_sl->setLevels([$defaultLvl,$additionnalLvl//()]);
               });
    }
  }
  
  return 1;
}

1;
