# eve-log-alert

This little tool follows along as CCP's EVE Online client writes out the combat
log (for multiple characters) and our intel channel log to disk. It will pipe
up (via `notify-send`, `aplay` and a sound file you have to supply) when
supplied system names (regexes generated from the command line, really, or
optionally systems within n jumps from one given on the commandline if sqlite3
is available and a EVE universe data dump is supplied) are mentioned in the
intel channel, or when it doesn't look like afk ratting is going according to
plan.

There's some vague heuristics like taking high damage, taking damage but
dealing none, dealing damage but taking none (ie. your drones probably have
aggro), no combat happening at all (ie. anomaly cleared) and hey look a dread
gurista spawned, remember to loot that guy.

In addition, a separate (if provided) file will be played on loop if attacks or tackle attempts from players are seen in the combat log.

Since this is basically a glorified linux shell script, there is about zero
chance for portability. The OS-specific plumbing that relies on `/proc` to find
a currently opened chatlog and `inotify` to follow up on new writes to the log
files is the bulk of the complexity here. See https://github.com/psde/eve-alert
for a possibly superior alternative.

## Usage

Place a `wav` file (or symlink to one) named `alertsound` in the directory with
`alert.rb`. Optionally, also provide another `wav` named `frogsiren` for the
separate player attack alert sound. Edit the `INTEL_LOG_PREFIX` constant to
reflect the channel name of your intel channel.

Invoke as

    ruby alert.rb <,-separated character names> <system name>...

where `<system name>` is either a prefix to a system name that is interpreted
as a regular expression anchored to the beginning of a word from lines in the
intel channel log, *or*, if the ruby can `require 'sqlite3'` and the sqlite
database `universeDataDx.db` exists in the directory with the script,  a full,
correctly capitalized system name immediately followed by a `+` and a number,
in which case all systems up to that many jumps away from the named systems are
mangled into regexps loosely matching the first few letters of those systems.

### Examples

    ruby alert.rb "Jarna Civire,Oleena Natiras" s-d ju- mxx 2[o0]9g

    ruby alert.rb "Tobu Musume" S-DN5M+2
