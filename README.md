eve-log-alert
=============

This is a little tool to read a chat log file emitted by CCP's EVE Online
client and sound an alert when certain phrases (or rather system names)
are mentioned.

It's a slightly more elaborate `tail -f ... | grep ... | notify-send`.  I
couldn't get it to work as a shell pipeline mostly because `iconv` seemed
to buffer too much, so here you go.
