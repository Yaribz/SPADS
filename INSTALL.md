Prerequisites
=============

  For Linux systems
  -----------------
  1) Ensure Perl is installed, including all standard Perl core modules (on some systems such as RedHat/Fedora/CentOS, this requires installing a metapackage usually named "perl-core" in addition to main Perl package)
  2) For SPADS 0.12 only (current "stable" and "testing" SPADS releases): ensure swig and g++ are installed and available in your PATH
  3) For SPADS 0.13 only (current "unstable" SPADS release): install the "FFI::Platypus" Perl module. Usually this module can be installed using the standard system package manager of your Linux distribution. For example, on Debian-based distributions, you can use the following command to install the "FFI::Platypus" Perl module: `apt-get install libffi-platypus-perl`. On RedHat-based distributions, you can use `dnf install perl-FFI-Platypus`. If your distribution doesn't provide a package for the "FFI::Platypus" Perl module, you can install the module using the "CPAN" tool included with Perl instead, with following command: `cpan FFI::Platypus`
  4) If you plan to use SPADS on official Spring lobby server which requires TLS connection, install the "IO::Socket::SSL" Perl module. Usually this module can be installed using the standard system package manager of your Linux distribution. For example, on Debian-based distributions, you can use the following command to install the "IO::Socket::SSL" Perl module: `apt-get install libio-socket-ssl-perl`. On RedHat-based distributions, you can use `dnf install perl-IO-Socket-SSL`. If your distribution doesn't provide a package for the "IO::Socket::SSL" Perl module, you can install the module using the "CPAN" tool included with Perl instead, with following command: `cpan IO::Socket::SSL`
  5) If you plan to run multiple instances of SPADS in parallel from same installation directory (multi-instance mode), it is recommended to install the "DBD::SQLite" Perl module. Usually this module can be installed using the standard system package manager of your Linux distribution. For example, on Debian-based distributions, you can use the following command to install the "DBD::SQLite" Perl module: `apt-get install libdbd-sqlite3-perl`. On RedHat-based distributions, you can use `dnf install perl-DBD-SQLite`. If your distribution doesn't provide a package for the "DBD::SQLite" Perl module, you can install the module using the "CPAN" tool included with Perl instead, with following command: `cpan DBD::SQLite`

  For Windows systems
  -------------------
  1) Install Strawberry Perl (available here: http://strawberryperl.com)
  2) Ensure your Perl bin directory is in your PATH environement variable

  For macOS systems
  -----------------
  1) Ensure Perl is installed.
  2) For SPADS 0.12 only (current "stable" and "testing" SPADS releases): ensure swig and g++ are installed and available in your PATH
  3) For SPADS 0.13 only (current "unstable" SPADS release): install the "FFI::Platypus" Perl module.
  4) If you plan to use SPADS on official Spring lobby server which requires TLS connection, install the "IO::Socket::SSL" Perl module.
  5) If you plan to run multiple instances of SPADS in parallel from same installation directory (multi-instance mode), it is recommended to install the "DBD::SQLite" Perl module.
  6) Install Spring server (check the locations of the unitsyc library, "spring-dedicated" and "Spring data directory", they will be asked during SPADS installation)
  7) Install at least one mod in Spring data directory.

Installation instructions
=========================

  1) Create the directory where SPADS should be installed
  2) Download SPADS installation archive from http://planetspads.free.fr/spads/installer/spadsInstaller.tar and extract it in SPADS installation directory
  3) From SPADS installation directory, launch the installer using following command: `perl spadsInstaller.pl`
  4) After installation, check and customize your configuration files if needed (in particular "spads.conf", "hostingPresets.conf" and "battlePresets.conf")
  5) Launch SPADS using following command: `perl spads.pl etc/spads.conf`

Support
=======

  * SpringRTS/SPADS subforum: https://springrts.com/phpbb/viewforum.php?f=88
  * Github/SPADS discussions: https://github.com/Yaribz/SPADS/discussions
