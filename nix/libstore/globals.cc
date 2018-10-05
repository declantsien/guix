#include "config.h"

#include "globals.hh"
#include "util.hh"
#include "archive.hh"

#include <map>
#include <algorithm>


namespace nix {


/* The default location of the daemon socket, relative to nixStateDir.
   The socket is in a directory to allow you to control access to the
   Nix daemon by setting the mode/ownership of the directory
   appropriately.  (This wouldn't work on the socket itself since it
   must be deleted and recreated on startup.) */
#define DEFAULT_SOCKET_PATH "/daemon-socket/socket"


Settings settings;


Settings::Settings()
{
    keepFailed = false;
    keepGoing = false;
    tryFallback = false;
    buildVerbosity = lvlError;
    maxBuildJobs = 1;
    buildCores = 1;
    readOnlyMode = false;
    thisSystem = SYSTEM;
    maxSilentTime = 0;
    buildTimeout = 0;
    useBuildHook = true;
    printBuildTrace = false;
    reservedSize = 8 * 1024 * 1024;
    fsyncMetadata = true;
    useSQLiteWAL = true;
    syncBeforeRegistering = false;
    useSubstitutes = true;
    useChroot = false;
    impersonateLinux26 = false;
    keepLog = true;
#if HAVE_BZLIB_H
    logCompression = COMPRESSION_BZIP2;
#else
    logCompression = COMPRESSION_GZIP;
#endif
    maxLogSize = 0;
    cacheFailure = false;
    pollInterval = 5;
    checkRootReachability = false;
    gcKeepOutputs = false;
    gcKeepDerivations = true;
    autoOptimiseStore = false;
    envKeepDerivations = false;
    lockCPU = getEnv("NIX_AFFINITY_HACK", "1") == "1";
    showTrace = false;
}


void Settings::processEnvironment()
{
    nixStore = canonPath(getEnv("NIX_STORE_DIR", getEnv("NIX_STORE", NIX_STORE_DIR)));
    nixDataDir = canonPath(getEnv("NIX_DATA_DIR", NIX_DATA_DIR));
    nixLogDir = canonPath(getEnv("NIX_LOG_DIR", NIX_LOG_DIR));
    nixStateDir = canonPath(getEnv("NIX_STATE_DIR", NIX_STATE_DIR));
    nixDBPath = getEnv("NIX_DB_DIR", nixStateDir + "/db");
    nixConfDir = canonPath(getEnv("GUIX_CONFIGURATION_DIRECTORY", GUIX_CONFIGURATION_DIRECTORY));
    nixLibexecDir = canonPath(getEnv("NIX_LIBEXEC_DIR", NIX_LIBEXEC_DIR));
    nixBinDir = canonPath(getEnv("NIX_BIN_DIR", NIX_BIN_DIR));
    nixDaemonSocketFile = canonPath(nixStateDir + DEFAULT_SOCKET_PATH);
}


void Settings::set(const string & name, const string & value)
{
    settings[name] = value;
    overrides[name] = value;
}


string Settings::get(const string & name, const string & def)
{
    auto i = settings.find(name);
    if (i == settings.end()) return def;
    return i->second;
}


Strings Settings::get(const string & name, const Strings & def)
{
    auto i = settings.find(name);
    if (i == settings.end()) return def;
    return tokenizeString<Strings>(i->second);
}


bool Settings::get(const string & name, bool def)
{
    bool res = def;
    _get(res, name);
    return res;
}

int Settings::get(const string & name, int def)
{
    int res = def;
    _get(res, name);
    return res;
}


void Settings::update()
{
    _get(tryFallback, "build-fallback");
    _get(maxBuildJobs, "build-max-jobs");
    _get(buildCores, "build-cores");
    _get(thisSystem, "system");
    _get(maxSilentTime, "build-max-silent-time");
    _get(buildTimeout, "build-timeout");
    _get(reservedSize, "gc-reserved-space");
    _get(fsyncMetadata, "fsync-metadata");
    _get(useSQLiteWAL, "use-sqlite-wal");
    _get(syncBeforeRegistering, "sync-before-registering");
    _get(useSubstitutes, "build-use-substitutes");
    _get(buildUsersGroup, "build-users-group");
    _get(useChroot, "build-use-chroot");
    _get(impersonateLinux26, "build-impersonate-linux-26");
    _get(keepLog, "build-keep-log");
    // _get(logCompression, "build-log-compression");
    _get(maxLogSize, "build-max-log-size");
    _get(cacheFailure, "build-cache-failure");
    _get(pollInterval, "build-poll-interval");
    _get(checkRootReachability, "gc-check-reachability");
    _get(gcKeepOutputs, "gc-keep-outputs");
    _get(gcKeepDerivations, "gc-keep-derivations");
    _get(autoOptimiseStore, "auto-optimise-store");
    _get(envKeepDerivations, "env-keep-derivations");

    string subs = getEnv("NIX_SUBSTITUTERS", "default");
    if (subs == "default") {
        substituters.clear();
#if 0
        if (getEnv("NIX_OTHER_STORES") != "")
            substituters.push_back(nixLibexecDir + "/nix/substituters/copy-from-other-stores.pl");
#endif
        substituters.push_back(nixLibexecDir + "/nix/substituters/download-using-manifests.pl");
        substituters.push_back(nixLibexecDir + "/nix/substituters/download-from-binary-cache.pl");
    } else
        substituters = tokenizeString<Strings>(subs, ":");
}


void Settings::_get(string & res, const string & name)
{
    SettingsMap::iterator i = settings.find(name);
    if (i == settings.end()) return;
    res = i->second;
}


void Settings::_get(bool & res, const string & name)
{
    SettingsMap::iterator i = settings.find(name);
    if (i == settings.end()) return;
    if (i->second == "true") res = true;
    else if (i->second == "false") res = false;
    else throw Error(format("configuration option `%1%' should be either `true' or `false', not `%2%'")
        % name % i->second);
}


void Settings::_get(StringSet & res, const string & name)
{
    SettingsMap::iterator i = settings.find(name);
    if (i == settings.end()) return;
    res.clear();
    Strings ss = tokenizeString<Strings>(i->second);
    res.insert(ss.begin(), ss.end());
}

void Settings::_get(Strings & res, const string & name)
{
    SettingsMap::iterator i = settings.find(name);
    if (i == settings.end()) return;
    res = tokenizeString<Strings>(i->second);
}


template<class N> void Settings::_get(N & res, const string & name)
{
    SettingsMap::iterator i = settings.find(name);
    if (i == settings.end()) return;
    if (!string2Int(i->second, res))
        throw Error(format("configuration setting `%1%' should have an integer value") % name);
}


string Settings::pack()
{
    string s;
    foreach (SettingsMap::iterator, i, settings) {
        if (i->first.find('\n') != string::npos ||
            i->first.find('=') != string::npos ||
            i->second.find('\n') != string::npos)
            throw Error("illegal option name/value");
        s += i->first; s += '='; s += i->second; s += '\n';
    }
    return s;
}


Settings::SettingsMap Settings::getOverrides()
{
    return overrides;
}


const string nixVersion = PACKAGE_VERSION;


}
