SPADS major update documentation
================================

Description
-----------

Some SPADS updates, called "major updates", require some modifications to be performed manually on the system (usually in SPADS configuration files). When this happens, SPADS does NOT auto-update because it wouldn't be able to restart without these modifications. Instead, it logs an alert, points to this document and continues running normally.

This document describes the manual actions which must be performed during the major update. If you need additional information regarding new SPADS settings, you can check the SPADS settings documentation here: http://planetspads.free.fr/spads/doc/spadsDoc.html

You can also check that your modifications are correct by comparing them with the up-to-date configuration templates available here (replace `<release>` by your actual SPADS release: "stable", "testing" or "unstable"): `http://planetspads.free.fr/spads/conf/templates/<release>/`

When all the required manual actions listed in next section have been performed, you must force an update of all SPADS packages by entering the following command *twice* from main SPADS installation directory (replace `<release>` by your actual SPADS release: "stable", "testing" or "unstable"):

    perl update.pl <release> -f -a

You need to run the command twice because the script might need to update itself first.

Finally, you can take a look at what changed with this update by checking the changelog available here:
  http://planetspads.free.fr/spads/repository/CHANGELOG

Instructions for SPADS upgrade from version 0.12 to version 0.13
----------------------------------------------------------------

/!\ _Steps 1 to 3 must be skipped on Windows systems_ /!\

### 1. Installation of the `FFI::Platypus` Perl module
(_this step must be skipped on Windows systems_)

On Linux, SPADS 0.13 requires the `FFI::Platypus` Perl module. Usually this module can be installed using the standard system package manager of your Linux distribution. For example, on Debian-based distributions, you can use the following command to install the `FFI::Platypus` Perl module: `apt-get install libffi-platypus-perl`. On RedHat-based distributions, you can use `dnf install perl-FFI-Platypus`.

If your distribution doesn't provide a package for the `FFI::Platypus` Perl module, you can use the `CPAN` tool included with Perl instead to install the module, using following command: `cpan FFI::Platypus`

### 2. Removal of the obsolete Perl Unitsync wrapper files
(_this step must be skipped on Windows systems_)

On Linux, SPADS versions prior to 0.13 were using a generated wrapper to call the Unitsync library. This method of calling the Unitsync library has been replaced by `FFI::Platypus` in SPADS 0.13. Consequently, following files must be removed from SPADS installation directory to allow `FFI::Platypus` to work properly: `PerlUnitSync.pm` and `PerlUnitSync.so` (a new `PerlUnitSync.pm` file will be automatically downloaded when launching the update at the end of the procedure)

### 3. Installation of the `DBD::SQLite` Perl module
(_this step must be skipped on Windows systems_)

(_this step is optional on Linux systems, but recommended if SPADS is used in multi-instance mode_)

In order to be able to share user preferences data between several instances, SPADS uses a SQLite database which requires the Perl `DBD::SQLite` module. Usually this module can be installed using the standard system package manager of your Linux distribution. For example, on Debian-based distributions, you can use the following command to install the `DBD::SQLite` Perl module: `apt-get install libdbd-sqlite3-perl`. On RedHat-based distributions, you can use `dnf install perl-DBD-SQLite`.

If your distribution doesn't provide a package for the `DBD::SQLite` Perl module, you can use the `CPAN` tool included with Perl instead to install the module, using following command: `cpan DBD::SQLite`

### 4. Removal of the obsolete `cpu` field from the users configuration file (`users.conf`)

The `cpu` field has been removed from SpringRTS lobby protocol so the corresponding field must be removed from the `users.conf` configuration file (usually located in the `etc` subdirectory of main SPADS installation directory). To do so, following actions must be performed in this file:
* the template declaration line (usually the first line of the file) must be replaced:  
Old line: `#?accountId:name:country:cpu:rank:access:bot:auth|level`  
New line: `#?accountId:name:country:rank:access:bot:auth|level` (the `cpu` field has been removed)
* the data lines (i.e. all the lines that contain values and which don't start with `#`) must be modified to remove the 4th field. For example, a data line like `:::::1::|110` must be replaced by `::::1::|110` (the 3rd `:` character has been removed).

### 5. Declaration of the new `resign` command in the commands configuration file (`commands.conf` by default)

SPADS 0.13 provides a new command called `resign` which was provided by the `Resign` plugin in previous SPADS versions.

a) If the `Resign` plugin is installed and the `resign` command configuration has been customized

The customized content contained in the `ResignCmd.conf` plugin configuration file must be copied directly in main SPADS commands configuration file (`commands.conf` by default)

b) If the `Resign` plugin is NOT installed or the `resign` command configuration has NOT been customized

Following lines must be added in SPADS commands configuration file (`commands.conf` by default):
```
[resign]
:playing:running|100:10
::running|100:
```

### 6. Uninstallation of the `Resign` plugin if needed

If the `Resign` plugin is installed, it must be uninstalled as follows:
* remove the `Resign` plugin from the `autoLoadPlugins` setting if needed in your main SPADS configuration file (`spads.conf` by default)
* remove the `Resign.pm` and `ResignHelp.dat` files from your SPADS plugin directory
* remove the `Resign.conf` and `ResignCmd.conf` files from your SPADS configuration directory

### 7. Update of main SPADS configuration file (`spads.conf` by default)

The `colorSensitivity` setting has been changed from a global unmodifiable setting to a global preset setting. This means the setting declaration must be moved from the top part of the configuration file to the preset declarations part, between the `autoBlockColors` and the `balanceMode` settings declarations for example.

The `springieEmulation` setting value _should_ be updated from `warn` to `off`.

Following new global settings must be declared (in the top part of the configuration file, before the preset declarations):
```
lobbyTls:auto
bansData:shared
mapInfoCacheData:shared
savedBoxesData:shared
trustedLobbyCertificatesData:shared
preferencesData:shared
sharedDataRefreshDelay:5
sequentialUnitsync:0
majorityVoteMargin:0
awayVoteDelay:20
```
Note 1: if you are using Linux and chose to not install the `DBD::SQLite` module in step 3., you must use `private` instead of `shared` for the `preferencesData` value

Note 2: if you were previously using command line arguments to pass values of `lobbyTls`, `sharedDataRefreshDelay`, `sequentialUnitsync`, `majorityVoteMargin`, `awayVoteDelay` and `sharedData`, you must now use the corresponding standard settings listed above instead, as these command line arguments will be ignored by SPADS 0.13.
