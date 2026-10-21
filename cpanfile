# cpanfile - non-core Perl dependencies for SPADS.
#
# Core modules that ship with Perl (e.g. HTTP::Tiny, JSON::PP, Storable,
# Time::HiRes, List::Util, File::Spec) are not listed here.
#
# INSTALL.md remains the authoritative reference, including the recommended
# system-package names (e.g. libffi-platypus-perl, libio-socket-ssl-perl,
# libdbd-sqlite3-perl) which are usually preferable to installing from CPAN.
#
# Install everything declared here with:  cpanm --installdeps .

on 'runtime' => sub {
  if ($^O eq 'MSWin32') {
    # Windows: unitsync is accessed through Win32::API; these ship with
    # Strawberry Perl.
    requires 'Win32';
    requires 'Win32::API';
    requires 'Win32::TieRegistry';
  }
  else {
    # Non-Windows: the unitsync library is loaded through FFI.
    requires 'FFI::Platypus';
  }

  # Recommended: required by lobby servers using TLS (e.g. the official Spring
  # lobby server), for automatic engine installation from GitHub, and for
  # automatic download of some map sets.
  recommends 'IO::Socket::SSL';

  # Recommended for multi-instance mode (shared data stored in SQLite).
  recommends 'DBD::SQLite';
};
