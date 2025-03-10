#!/bin/bash

# put build args in a file that will be fed to the installer which only accept values from STDIN

#  Which SPADS release do you want to install (stable,testing,unstable,contrib) [testing] 
#  Please choose the directory where SPADS configuration files will be stored [etc]
# Please choose the directory where SPADS dynamic data will be stored [var] ? 
# Please choose the directory where SPADS will write the logs [log] ?
# Do you want to use official Spring binary files (auto-managed by SPADS), or a custom Spring installation already existing on the system? (official,custom) [official] ?
# Which Spring version do you want to use (104.0,104.0.1-1463-g9b63660,stable,testing,unstable,...) [104.0] 
#Please enter the absolute path of the Spring data directory containing the games and maps hosted by the autohost, or press enter to use a new directory instead [new] ? 
# Which game do you want to download to initialize the autohost "games" directory (ba,bac,evo,jauria,metalfactions,nota,phoenix,s44,swiw,tard,tc,techa,xta,zk,none) [ba] ?
#  Do you want to download a minimal set of 3 maps to initialize the autohost "maps" directory (yes,no) [yes] ?
#Which type of server do you want to use ("headless" requires much more CPU/memory and doesn't support "ghost maps", but it allows running AI bots and LUA scripts on server side)? (dedicated,headless) [dedicated] ?
#Do you want to enable new game auto-detection to always host the latest version of the game available in your "games" and "packages" folders? (yes,no) [yes] ?
# Please enter the autohost lobby login (the lobby account must already exist) ?
# Please enter the autohost lobby password ? 
# Please enter the lobby login of the autohost owner ?

SPADS_RELEASE="${SPADS_RELEASE:-testing}"
SPADS_SPRING_FLAVOUR="${SPADS_SPRING_FLAVOUR:-official}"
SPADS_SPRING_VERSION="${SPADS_SPRING_VERSION:-maintenance}"

cat << EOF > /tmp/spads-installer-args
$SPADS_RELEASE
etc
var
log
$SPADS_SPRING_FLAVOUR
stable
new
none
no
dedicated
%SPADS_LOBBY_LOGIN%
%SPADS_LOBBY_PASSWORD%
%SPADS_OWNER_LOBBY_LOGIN%
EOF

perl ./spadsInstaller.pl < /tmp/spads-installer-args

# autoManagedSpringVersion supports maintenance, but not the installer
sed -i "s/^autoManagedSpringVersion.*/autoManagedSpringVersion:$SPADS_SPRING_VERSION/"  etc/spads.conf




