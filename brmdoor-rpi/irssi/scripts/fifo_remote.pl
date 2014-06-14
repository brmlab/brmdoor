# fifo_remote.pl -- send commands to Irssi through named pipe/fifo
#
# DESCRIPTION
#
# fifo_remote.pl creates a named pipe (a.k.a. fifo). Everything written to the
# fifo will be passed on to Irssi and run as a command. (You need not precede
# you commands with `/', or whatever you've set you `cmdchars' to -- this also
# means that if you want to send a message, you must use the explicit `say'
# command.)
#
# SETTINGS
#
# fifo_remote_file (default is `remote-control')
#
#       This is the file name of the named pipe. Any leading `~[USER]' part is
#       expanded before use. If the name does not begin with `/' it is taken to
#       be relative to Irssi's current configuration dir (usually `~/.irssi').
#
#       The default value thus normally means `~/.irssi/remote-control'.
#
# NOTES
#
# This script may have limited use to you, since it cannot bring back *any*
# return values from Irssi. It can only run Irssi commands from the outside. --
# I use it to trigger my online/away messages from any shell, and that's about
# it.
#
# CAVEATS
#
# Due to the way named pipes (or fifos) works one must take extra care when
# writing to one of these beasts -- if not, the writing program may well hang
# forever. This is because the writing process will not terminate until the
# fifo has been read from the other end (see also fifo(4)).
#
# To avoid this problem, I usually use something akin to the below shell
# function to write to the Irssi fifo remote. It simply kills off the writing
# process if it's still around after a certain timeout (e.g. the fifo could be
# present but Irssi not running -- and thus the pipe would never be read). The
# entire process is done in the background, so the caller of the function does
# not have to wait.
#
#     FILE="$HOME/.irssi/remote-control"
#     irssi_command() {
#          if [ -p "$FILE" ]; then
#              (   echo "$*" > "$FILE" &
#                  sleep 5
#                  kill $! 2>/dev/null   )&
#          fi
#      }
#
# TODO
#
# o Clean up fifo file when Irssi quits -- right now this is not done, so extra
#   precautions are required inside your shell scripts to make sure they do not
#   hang indefinately when trying to write to the remote control fifo. (See
#   above example.)
#
# HISTORY
#
# [2004-08-12, 22.16-00.58] v0.1a - began implementing it
#
# [2004-08-13, 09.52-10-19] v0.2a - began implementing fifo_read
#
# [2004-08-14, 01.12-04.27] v0.3a
#
# [2004-08-14, 14.09-18.13] v0.4a - seems to be fully functional, except for
# the fact that commands aren't run in the proper window/server environment
#
# [2004-08-15, 18.17-19.26] v0.5a - command comming through pipe is now run in
# the active window; removed bug which crashed Irssi, bug was caused by several
# input_add()s being called without having been removed in between
#
# [2004-08-26, 21.46-22.30] v0.5 - wrote above docs
#

our $VERSION = '0.5';
our %IRSSI = (
    authors     => 'Zrajm C Akfohg',
    contact     => 'zrajm\@klingonska.org',
    name        => 'fifo_remote',
    description => 'Irssi remote control (for shell scripting etc.) -- ' .
                   'run all commands written to named pipe.',
    license     => 'GPLv2',
    url         => 'http://www.irssi.org/scripts/',
);                                             #
use strict;                                    #
use Irssi;                                     #
use Fcntl;          # provides `O_NONBLOCK' and `O_RDONLY' constants
our ( $FIFO,        # fifo absolute filename (expanded from Irssi config)
      $FIFO_HANDLE, # fifo filehandle for `open' et al.
      $FIFO_TAG );  # fifo signal tag for `input_add'

# simple subs
sub TRUE()   { 1  }                            # some constants [perlsyn(1)
sub FALSE()  { "" }                            # "Constant Functions"]
sub DEBUG(@) { print "%B", join(":", @_),"%n" }# DEBUG thingy


# Irssi settings
Irssi::settings_add_str($IRSSI{name},          # default fifo_remote_file
    'fifo_remote_file', 'remote-control');     #


# create named fifo and open it for input
# (called on script load and fifo name changes)
sub create_fifo($) {                           # [2004-08-14]
    my ($new_fifo) = @_;                       #   get args
    if (not -p $new_fifo) {                    #   create fifo if non-existant
        if (system "mkfifo '$new_fifo' &>/dev/null" and
            system "mknod  '$new_fifo' &>/dev/null"){
            print CLIENTERROR "`mkfifo' failed -- could not create named pipe";
                # TODO: capture `mkfifo's stderr and show that here
            return "";                         #
        }                                      #
    }                                          #
    $FIFO = $new_fifo;                         #   remember fifo name
    open_fifo($new_fifo);                      #   open fifo for reading
}                                              #


# set up signal to trigger on fifo input
# (called when creating named fifo)
sub open_fifo($) {                             # [2004-08-14]
    my ($fifo) = @_;                           #   get args
    if (not sysopen $FIFO_HANDLE, $fifo,       #   open fifo for non-blocking
        O_NONBLOCK | O_RDONLY) {               #     reading
        print CLIENTERROR "could not open named pipe for reading";
        return "";                             #
    }                                          #
    Irssi::input_remove($FIFO_TAG)             #   disable fifo reading signal
       if defined $FIFO_TAG;                   #     if there is one
    $FIFO_TAG = Irssi::input_add               #   set up signal called when
        fileno($FIFO_HANDLE), INPUT_READ,      #     there's input in the pipe
        \&read_fifo, '';                       #
    return 1;                                  #
}                                              #


# read from fifo
# (called by fifo input signal)
sub read_fifo() {                              # [2004-08-14]
    foreach (<$FIFO_HANDLE>) {                 #   for each input line
        chomp;                                 #     strip trailing newline
        Irssi::print(                          #
            "%B>>%n $IRSSI{name} received command: \"$_\"",
            MSGLEVEL_CLIENTCRAP);              #
#        Irssi::active_win->print(              #   show incoming commands
#            "\u$IRSSI{name} received command: \"$_\"", #
#            MSGLEVEL_CLIENTNOTICE);            #
        Irssi::active_win->command($_);     #   run incoming commands
    }                                          #
    open_fifo($FIFO);                          #   re-open fifo
        # TODO: Is the above re-opening of fifo really necessary? -- If not
        # invoked here `read_fifo' is called repeatedly, even though no input
        # is to be found on the fifo. (This seems a waste of resources to me.)
}                                              #


# disable fifo and erase fifo file
sub destroy_fifo($) {                          # [2004-08-14]
    my ($fifo) = @_;                           #   get args
    if (defined $FIFO_TAG) {                   #   if fifo signal is active
        Irssi::input_remove($FIFO_TAG);        #     disable fifo signal
        undef $FIFO_TAG;                       #     and forget its tag
    }                                          #
    if (defined $FIFO_HANDLE) {                #   if fifo is open
        close $FIFO_HANDLE;                    #     close it
        undef $FIFO_HANDLE;                    #     and forget handle
    }                                          #
    if (-p $fifo) {                            #   if named fifo exists
        unlink $fifo;                          #     erase fifo file
        undef $FIFO;                           #     and forget filename
    }                                          #
    return 1;                                  #   return
}                                              #


# add path to filename (expands `~user', and make
# non-absolute filename relative to Irssi's config dir)
sub absolute_path($) {                         # [2004-08-14] -- [2004-08-15]
    my ($file) = @_;                           #
    return '' if $file eq '';                  #   don't modify empty value
    $file =~ s¶^(~[^/]*)¶                      #   expand any leading tilde
        my $x;                                 #     WORKAROUND: glob()
        until($x = glob($1)) { };              #       sometimes return empty
        $x;                                    #       string -- avoid that
    ¶ex;                                       #
    $file = Irssi::get_irssi_dir() . "/$file"  #     if full path is not given
        unless $file =~ m¶^/¶;                 #       prepend irssi config path
        # FIXME: clean up multiple slashes, and occuring `/./' and `/../'.
        # this sub used in: fifo_remote.pl, xcuses.pl
    return $file;                              #
}                                              #


# clean up fifo on unload
# (called on /script unload)
Irssi::signal_add_first                        #
    'command script unload', sub {             # [2004-08-13]
        my ($script) = @_;                     #   get args
        return unless $script =~               #   only do cleanup when
            /(?:^|\s) $IRSSI{name}             #     unloading *this* script
             (?:\.[^. ]*)? (?:\s|$) /x;        #
        destroy_fifo($FIFO) if -p $FIFO;       #   destroy old fifo
        Irssi::print("%B>>%n $IRSSI{name} $VERSION unloaded", MSGLEVEL_CLIENTCRAP);
    };                                         #


# create new fifo (erase any old) and get command prefix
# (called on script loading and on user /set)
sub setup() {                                  # [2004-08-13]
    my $new_fifo = absolute_path               #   get fifo_remote_file
        Irssi::settings_get_str                #     setting from Irssi
        'fifo_remote_file';                    #     (and add path to it)
    return if $new_fifo eq $FIFO and -p $FIFO; #   do nada if already exists
    destroy_fifo($FIFO) if -p $FIFO;           #   destroy old fifo
    create_fifo($new_fifo)                     #   create new fifo
        and $FIFO = $new_fifo;                 #     and remember that fifo
}                                              #

setup();                                       # initialize setup values
Irssi::signal_add('setup changed', \&setup);   # re-read setup when it changes
print CLIENTCRAP "%B>>%n $IRSSI{name} $VERSION (by $IRSSI{authors}) loaded";
#print CLIENTCRAP "   (Fifo name: $FIFO)";

