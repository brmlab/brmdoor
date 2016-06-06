This is quick and dirty version of brmdoor that does not require Arduino, and runs only on Raspberry Pi.

This version of brmdoor requires:
- create user brmdoor, ~brmdoor/.screenrc
- create /etc/systemd/system/brmdoor.service in case systemd is used to autostart brmdoor service
- irssi configured according to ./irssi/config with loaded scripts from ./irssi/scripts
- libnfc-compatible smartcard reader
- libnfc installed
- create /etc/nfc/libnfc.conf using content from libnfc.conf supplied (otherwise nfc-list wouldnt find your NFC device)
- nfc-getcard.c compiled against libnfc (with -lnfc) and saved as "./nfc-getcard"
- to be running on RaspberryPi (or simillar with GPIO pins exported through /proc)
- variables in brmdoor-rpi.sh modified according to reality
- list of allowed cards in allowed.list in the correct format
