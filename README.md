SPADS
=====
SPADS (Spring Perl Autohost for Dedicated Server) is a Perl autohost program
for [SpringRTS](http://springrts.com/), released under GPL v3 license. It has
been designed from start for headless servers without any graphic interface,
and is heavily customizable through various configuration levels and a plugin
system. For more details please refer to
[SPADS thread](http://springrts.com/phpbb/viewtopic.php?f=1&t=17130) on Spring
forums.

Components
----------
* [src/spads.pl](src/spads.pl): SPADS application.
* [src/SpadsConf.pm](src/SpadsConf.pm): Perl module handling SPADS
  configuration and dynamic data files.
* [src/spadsInstaller.pl](src/spadsInstaller.pl): SPADS installation script
  (also used to compile Perl Unitsync interface module).
* [src/SpadsUpdater.pm](src/SpadsUpdater.pm): Perl module handling SPADS
  automatic update.
* [src/update.pl](src/update.pl): Application to update SPADS components
  manually.
* [src/SpadsPluginApi.pm](src/SpadsPluginApi.pm): Perl module implementing the
  plugin API for SPADS.
* [src/getDefaultModOptions.pl](src/getDefaultModOptions.pl): Application to
  retrieve the list of modoptions for all installed mods, and convert them
  optionnaly in SPADS format to copy-paste in the battlePresets.conf
  configuration file.
* [src/PerlUnitSync.pm](src/PerlUnitSync.pm): Perl module for unitsync library
  interface on Windows
* [SPADS configuration templates](etc): Templates for SPADS configuration
  files.
* [var/help.dat](var/help.dat): Data file for SPADS commands help.
* [var/helpSettings.dat](var/helpSettings.dat): Data file for SPADS settings
  help.
* [SPADS reference guide](doc/spadsDoc.html): HTML documentation of all SPADS
  commands and settings (generated from help data files).
* [SPADS plugin API](doc/spadsPluginApiDoc.html): HTML documentation of the SPADS
  plugin API (generated from SPADS plugin API module)
* [Official SPADS plugins](plugins/officials): Official SPADS plugins sources.
* [SPADS plugins templates](plugins/templates): Templates for SPADS plugins
  development.
* [SPADS plugins tutorials](plugins/tutorials): Sources of the SPADS plugins
  used in the tutorials.
* [packages.txt](packages.txt): SPADS packages index file for HTTP repository
  (used for automatic updates).
* [UPDATE](UPDATE): Manual update procedure for major SPADS versions.

SPADS is based on the templates provided by following project:
* [SpringLobbyBot](https://github.com/Yaribz/SpringLobbyBot)

Dependencies
------------
The SPADS application depends on following projects:
* [SimpleLog](https://github.com/Yaribz/SimpleLog)
* [SimpleEvent](https://github.com/Yaribz/SimpleEvent)
* [SpringLobbyInterface](https://github.com/Yaribz/SpringLobbyInterface)
* [SpringAutoHostInterface](https://github.com/Yaribz/SpringAutoHostInterface)
* [Spring](https://github.com/spring/spring)

SPADS also depends on following projects (hosted remotely) for additional
functionalities:
* [SLDB](https://github.com/Yaribz/SLDB) for TrueSkill support and advanced
  multi-account detection.
* [spring replay site](https://github.com/dansan/spring-replay-site) for
  automatic replay uploading.

Installation
------------
The installation can be performed by following the instructions of the
[INSTALL.md](INSTALL.md) file.

The installation package contains following components (other components are
automatically downloaded):
* [INSTALL.md](INSTALL.md)
* [LICENSE](LICENSE)
* [SimpleLog.pm](https://github.com/Yaribz/SimpleLog/blob/master/SimpleLog.pm)
* [spadsInstaller.pl](src/spadsInstaller.pl)
* [SpadsUpdater.pm](src/SpadsUpdater.pm)

Documentation
-------------
* The SPADS reference guide for all SPADS commands and settings is available
  online [here](http://planetspads.free.fr/spads/doc/spadsDoc.html). It can be
  generated from any SPADS installation directory by using following command
  (files are generated in the directory specified by the "varDir" setting in
  spads.conf):
  
        perl spads.pl etc/spads.conf --doc
    
* The SPADS plugin API documentation is available online
  [here](http://planetspads.free.fr/spads/doc/spadsPluginApiDoc.html). It can
  be generated from any SPADS installation directory by using following
  command (the pod2html.css file can be found [here](doc/pod2html.css)):
  
        pod2html -css=pod2html.css --infile=SpadsPluginApi.pm --outfile=spadsPluginApiDoc.html --title="SPADS Plugin API Doc"
    
* Additional documentation can be found on [SPADS wiki](http://springrts.com/wiki/SPADS).

Licensing
---------
Please see the file called [LICENSE](LICENSE).

Author
------
Yann Riou <yaribzh@gmail.com>
