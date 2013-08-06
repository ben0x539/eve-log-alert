eve-log-alert
=============

This little tool follows along as CCP's EVE Online client writes out the
combat log (for multiple characters) and our intel channel log to disk. It
will pipe up (via `notify-send`, `aplay` and a sound file you have to
supply) when supplied system names (regexes generated from the command line,
really) are mentioned in the intel channnel, or when it doesn't look like
afk ratting is going according to plan.

There's some vague heuristics like taking damage, but dealing none, dealing
damage, but taking none (ie. your drones probably have aggro), no combat
happening at all (ie. anomaly cleared) and hey look a dread gurista spawned,
remember to loot that guy.

Since this is basically a glorified linux shell script, there is about zero
chance for portability. The OS-specific plumbing that relies on `/proc` to
find a currently opened chatlog and `inotify` to follow up on new writes to
the log files is the bulk of the complexity here.
