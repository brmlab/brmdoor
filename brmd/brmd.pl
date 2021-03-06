#!/usr/bin/perl
# 2011 (c)  Petr Baudis <pasky@suse.cz>, brmlab
# 2011 (c)  Pavol Rusnak <stick@gk2.sk>, brmlab
# You can distribute this under the same terms as Perl itself.

use strict;
use warnings;
use POE;
use WWW::WolframAlpha;
use Image::Magick;

our @channels = ("#brmlab", "#brmstatus");
our $streamurl = "http://brmlab.cz/stream";
our $devdoor = $ARGV[0]; $devdoor ||= "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A70078Q1-if00-port0";
our $devasign = $ARGV[1]; $devasign ||= "/dev/serial/by-id/usb-1a86_USB2.0-Serial-if00-port0";
our ($status, $streaming, $dooropen, $topic) = (0, 0, 0, 'BRMLAB OPEN');
our ($laststchange, $lastunlock) = (time, 0);
our $stmanual = 0;

my $irc = brmd::IRC->new();
my $web = brmd::WWW->new();
my $door = brmd::Door->new();
my $stream = brmd::Stream->new();
my $log = brmd::Log->new();
my $alphasign = brmd::Alphasign->new();


POE::Session->create(
	package_states => [
		main => [ qw(_default _start
				status_update streaming_update dooropen_update
				notify_door_unlocked notify_door_unauth) ],
	],
	heap => { irc => $irc, web => $web, door => $door, stream => $stream, log => $log, alphasign => $alphasign },
);

$poe_kernel->run();


sub _start {
	$poe_kernel->post($_[HEAP]->{web}, 'register');
	$poe_kernel->post($_[HEAP]->{door}, 'register');
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "main $event: " );

	for my $arg (@$args) {
		if ( ref $arg eq 'ARRAY' ) {
			push( @output, '[' . join(', ', @$arg ) . ']' );
		}
		else {
			push( @output, "'$arg'" );
		}
	}
	print join ' ', @output, "\n";
}

sub status_str {
	$status ? 'OPEN' : 'CLOSED';
}

sub dooropen_str {
	$dooropen ? 'AJAR' : 'SHUT';
}

sub streaming_str {
	$streaming ? 'ON AIR' : 'OFF AIR';
}

sub status_update {
	my ($self, $newstatus, $manual, $nick) = @_[OBJECT, ARG0 .. ARG2];
	$status = $newstatus;
	my $st = status_str();
	$stmanual = $manual;

	if ($manual) {
		$poe_kernel->post($door, 'status_override', $status);
	}

	$poe_kernel->post( $irc, 'notify_update', 'brmstatus', $st, undef, $manual, $nick );

	$laststchange = time;
}

sub streaming_update {
	my ($self, $newstreaming) = @_[OBJECT, ARG0];
	$streaming = $newstreaming;
	if ($streaming) {
		$poe_kernel->post( $_, 'stream_start' ) for ($stream, $alphasign);
	} else {
		$poe_kernel->post( $_, 'stream_stop' ) for ($stream, $alphasign);
	}

	my $st = streaming_str();
	$poe_kernel->post( $irc, 'notify_update', 'brmvideo', $st, $streaming ? $streamurl : undef );
}

sub dooropen_update {
	my ($self, $newdooropen) = @_[OBJECT, ARG0];
	$dooropen = $newdooropen;
	my $st = dooropen_str();

	my $closed_timeout = 60;
	my $unlock_timeout = 30;
	my $alert = ($dooropen == 1 and ($status == 0 or $stmanual) and time - $laststchange >= $closed_timeout and time - $lastunlock >= $unlock_timeout);
	if ($alert) {
		$poe_kernel->post($door, 'play_alarm');
	}

	$poe_kernel->post( $irc, 'notify_door_open', $st, $alert );
}

sub notify_door_unlocked {
	my ($self, $nick) = @_[OBJECT, ARG0];

	$poe_kernel->post($irc, 'notify_door_unlocked');
	$poe_kernel->post($log, 'notify_door_unlocked', $nick);

	$lastunlock = time;
}

sub notify_door_unauth {
	my ($self, $cardid) = @_[OBJECT, ARG0];

	$poe_kernel->post($irc, 'notify_door_unauth');
	$poe_kernel->post($log, 'notify_door_unauth', $cardid);
}


## Door serial

package brmd::Door;

use POE qw(Wheel::ReadWrite Filter::Line);
use Symbol qw(gensym);
use Device::SerialPort;

sub new {
	my $class = shift;
	my $self = bless { }, $class;

	POE::Session->create(
		object_states => [
			$self => [ qw(_start _default register
					serial_input serial_error
					status_override play_alarm) ],
		],
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");

	$_[HEAP]->{serial} = POE::Wheel::ReadWrite->new(
		Handle => serial_open($devdoor),
		Filter => POE::Filter::Line->new(
			InputLiteral  => "\x0A",    # Received line endings.
			OutputLiteral => "",    # Sent line endings.
			),
		InputEvent => "serial_input",
		ErrorEvent => "serial_error",
	) or die "Door fail: $!";
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "Door $event: " );

	for my $arg (@$args) {
		if ( ref $arg eq 'ARRAY' ) {
			push( @output, '[' . join(', ', @$arg ) . ']' );
		}
		else {
			push( @output, "'$arg'" );
		}
	}
	print join ' ', @output, "\n";
}

sub register {
	my ($self, $sender) = @_[OBJECT, SENDER];
	my $sid = $sender->ID;
	$poe_kernel->refcount_increment($sid, 'observer_door'); # XXX: No decrement
	push (@{$self->{'observers'}}, $sid);
}

sub serial_open {
	my ($device) = @_;
	# Open a serial port, and tie it to a file handle for POE.
	my $handle = gensym();
	my $port = tie(*$handle, "Device::SerialPort", $device);
	die "can't open port: $!" unless $port;
	$port->datatype('raw');
	$port->baudrate(9600);
	$port->databits(8);
	$port->parity("none");
	$port->stopbits(2);
	$port->handshake("none");
	$port->write_settings();
	return $handle;
}

sub serial_input {
	my ($self, $input) = @_[OBJECT, ARG0];
	print ((scalar localtime)." $input\n");
	$input =~ /^(\d) (\d) (\d) (.*)$/ or return;
	my ($cur_status, $cur_streaming, $cur_dooropen, $brm) = ($1, $2, $3, $4);
	if ($cur_status != $status) {
		foreach (@{$self->{observers}}) {
			$poe_kernel->post($_, 'status_update', $cur_status);
		}
	}
	if ($cur_streaming != $streaming) {
		foreach (@{$self->{observers}}) {
			$poe_kernel->post($_, 'streaming_update', $cur_streaming);
		}
	}
	if ($brm =~ s/^CARD //) {
		print "from door: $input\n";
		if ($brm =~ s/^UNKNOWN //) {
			foreach (@{$self->{observers}}) {
				$poe_kernel->post($_, 'notify_door_unauth', $brm);
			}
		} else {
			foreach (@{$self->{observers}}) {
				$poe_kernel->post($_, 'notify_door_unlocked', $brm);
			}
		}
	}
	if ($cur_dooropen != $dooropen) {
		foreach (@{$self->{observers}}) {
			$poe_kernel->post($_, 'dooropen_update', $cur_dooropen);
		}
	}
}

sub serial_error {
	my ($heap) = ($_[HEAP]);
	print "$_[ARG0] error $_[ARG1]: $_[ARG2]\n";
	print "bye!\n";
}

sub status_override {
	my ($heap, $status) = @_[HEAP, ARG0];
	my $serial = $heap->{serial};
	$serial->put('s'.$status);
	$serial->flush();
}

sub play_alarm {
	my ($heap) = $_[HEAP];
	my $serial = $heap->{serial};
	$serial->put('a0');
	$serial->flush();
}



## Web interface

package brmd::WWW;

use POE qw(Component::Server::HTTP);
use HTTP::Status qw/RC_OK/;
use CGI;

sub new {
	my $class = shift;
	my $self = bless { }, $class;

	my $web = POE::Component::Server::HTTP->new(
		Port           => 8088,
		ContentHandler => {
			"/brmstatus.html" => \&web_brmstatus_html,
			"/brmstatus.js" => \&web_brmstatus_js,
			"/brmstatus.png" => \&web_brmstatus_png,
			"/brmstatus.txt" => \&web_brmstatus_txt,
			"/brmstatus-switch" => sub { $self->web_brmstatus_switch(@_) },
			"/brmstatus.json" => \&web_brmstatus_json,
			"/alphasign" => \&web_alphasign_text,
			"/alphasign-set" => \&web_alphasign_set,
			"/" => \&web_index
		},
		Headers => {Server => 'brmd/xxx'},
	) or die "WWW fail: $!";

	POE::Session->create(
		object_states => [
			$self => [ qw(_start _default register) ],
		],
		heap => { web => $web },
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "WWW $event: " );

	for my $arg (@$args) {
		if ( ref $arg eq 'ARRAY' ) {
			push( @output, '[' . join(', ', @$arg ) . ']' );
		}
		else {
			push( @output, "'$arg'" );
		}
	}
	print join ' ', @output, "\n";
}

sub register {
	my ($self, $sender) = @_[OBJECT, SENDER];
	my $sid = $sender->ID;
	$poe_kernel->refcount_increment($sid, 'observer_WWW'); # XXX: No decrement
	push (@{$self->{'observers'}}, $sid);
}

sub disable_caching {
	my ($response) = @_;
	$response->push_header("Cache-Control", "no-cache, must-revalidate");
	$response->push_header("Expires", "Sat, 26 Jul 1997 05:00:00 GMT");
}

sub web_index {
	my ($request, $response) = @_;

	my $sts = main::status_str();
	my $str = main::streaming_str();

	$response->protocol("HTTP/1.0");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/html");
	disable_caching($response);

	my $r_link = '';
	$streaming and $r_link .= '<a href="'.$streamurl.'">watch now!</a>';

	my $astext = $alphasign->last_text_escaped();
	my $a_link = '';
	$streaming or $a_link .= '<a href="alphasign">change</a>';

	$response->content(<<EOT
<html>
<head><title>brmd</title></head>
<body>
<img src="http://brmlab.cz/lib/tpl/brmlab/images/brmlab_logo.png" alt="brmlab" align="right" />
<h1>brmd web interface</h1>
<p>Enjoy the view!</p>
<ul>
<li><strong>brmstatus</strong> ($sts) <a href="brmstatus.html">status page</a> | <a href="brmstatus.js">javascript code</a> | <a href="brmstatus.json">SpaceAPI JSON</a> | <a href="brmstatus.txt">plaintext file</a> | <a href="brmstatus.png">picture</a></li>
<li><strong>brmvideo</strong> ($str) $r_link</li>
<li><strong>alphasign</strong> ($astext) $a_link</li>
</ul>
<p align="right"><a href="http://github.com/brmlab/brmdoor">(view source)</a></p>
</body></html>
EOT
	);

	return RC_OK;
}

sub web_brmstatus_html {
	my ($request, $response) = @_;

	my $bg = $status ? 'lightgreen' : '#DEE7EC';
	my $st = $status ? 'OPEN' : 'CLOSED';

	$response->protocol("HTTP/1.0");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/html");
	disable_caching($response);

	$response->content(<<EOT
<html>
<head><title>brmstatus</title></head>
<body bgcolor="$bg">
<h1 align="center">brmlab is $st</h1>
<table style="border: 1pt solid" align="center"><tr><td>
<h2 align="center">Manual Override</h2>
<p>
<form method="post" action="brmstatus-switch">
<strong>Perpetrator:</strong>
<input type="text" name="nick" />
<input type="submit" name="s" value="Switch status" />
</form>
</p>
</td></tr></table>
</body></html>
EOT
	);

	return RC_OK;
}

sub web_brmstatus_js {
	my ($request, $response) = @_;

	$response->protocol("HTTP/1.0");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/javascript");
	disable_caching($response);

	$response->content(<<EOT
function brmstatus() { return ($status); }
EOT
	);

	return RC_OK;
}

sub web_brmstatus_json {
	my ($request, $response) = @_;

	$response->protocol("HTTP/1.0");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "application/json");
	$response->push_header("Access-Control-Allow-Origin", "*");
	disable_caching($response);

	$response->content(<<EOT
{
    "api": "0.13",
    "space": "brmlab",
    "logo": "https://status.brmlab.cz/_media/brmlab.png",
    "url": "https://brmlab.cz",
    "open": ${\($status ? 'true' : 'false')},
    "location": {
        "address": "brmlab o.s., Bubenska 1477/1, 170 00 Prague 7, Czech republic",
        "lon": 14.4369158,
        "lat": 50.0984614
    },
    "contact": {
        "phone": "+420608801582",
        "sip": "910114321\@sip.odorik.cz",
        "irc": "irc://freenode/#brmlab",
        "twitter": "\@brmlab",
        "facebook": "brmlab",
        "foursquare": "4cbdc77cc7228cfa25052cce",
        "ml": "brmlab\@brmlab.cz",
        "issue_mail": "cmFkYUBicm1sYWIuY3oK"
    },
    "issue_report_channels": [
        "issue_mail"
    ],
    "state": {
        "open": ${\($status ? 'true' : 'false')},
        "lastchange": $laststchange,
        "icon": {
            "open": "https://status.brmlab.cz/status-open-icon.png",
            "closed": "https://status.brmlab.cz/status-closed-icon.png"
        }
    },
    "icon": {
        "open": "https://status.brmlab.cz/status-open-icon.png",
        "closed": "https://status.brmlab.cz/status-closed-icon.png"
    },
    "stream": {
        "mp4": "http://brmlab.cz/stream.flv"
    },
    "projects": [
        "https://brmlab.cz/project/start",
        "https://github.com/brmlab"
    ],
    "cache": {
        "schedule": "m.02"
    }
}
EOT
	);

	return RC_OK;
}

sub web_brmstatus_txt {
	my ($request, $response) = @_;

	my $st = main::status_str();

	$response->protocol("HTTP/1.0");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/plain");
	disable_caching($response);

	$response->content($st);

	return RC_OK;
}

sub web_brmstatus_png {
	my ($request, $response) = @_;

	#open my $img, ($status ? "status-open.png" : "status-closed.png");
	#local $/;
	#my $imgdata = <$img>;
	#close $img;

	my $image = new Image::Magick;
	$image->Read($status ? "status-open.png" : "status-closed.png");

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($laststchange);

	$mon += 1;
	$year -= 100;

	my $str = sprintf("Since %02d-%02s-%02d %02s:%02d", $mday,$mon,$year,$hour,$min);
	$image->Annotate( text=>$str, font=>'arial.ttf', fill=>'blue', pointsize=>'9', gravity=>'South');

	$image->Set(magick=>'png');
	my $imgdata = $image->ImageToBlob();

	$response->protocol("HTTP/1.0");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "image/png");
	disable_caching($response);

	$response->content($imgdata);

	return RC_OK;
}

sub web_brmstatus_switch {
	my ($self, $request, $response) = @_;

	my $q = new CGI($request->content);
	my $nick = $q->param('nick');

	my $newstatus = 0 + not $status;
	foreach (@{$self->{observers}}) {
		$poe_kernel->post($_, 'status_update', $newstatus, 'web', $nick);
	}

	$response->protocol("HTTP/1.0");
	$response->code(302);
	$response->header('Location' => 'brmstatus.html');

	return RC_OK;
}

sub web_alphasign_text {
	my ($request, $response) = @_;

	$response->protocol("HTTP/1.0");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/html");
	disable_caching($response);
	my $text = $alphasign->last_text_escaped();
	my $lm = $alphasign->last_mode();
	my $help = $alphasign->markup_help();
	$help =~ s/&/&amp;/g; $help =~ s/</&lt;/g; $help =~ s/>/&gt;/g;
	$help =~ s/\n/<br \/>/g;
	my $modes = join("\n", map { "<option".($lm eq $_?" selected":"").">$_</option>" } $alphasign->mode_list());

	$response->content(<<EOT
<html>
<head><title>brm alphasign</title></head>
<body>
<h1 align="center">brm alphasign</h1>
<p align="center">Current text: $text</p>
<hr />
<p>$help</p>
<p>
<form method="post" action="alphasign-set">
<strong>New text:</strong>
<select name="mode">$modes</select>
<input type="text" name="text" value="$text" />
<input type="checkbox" name="beep" value="1" /> beep
<input type="submit" name="s" value="Update" />
</form>
</p>
</td></tr></table>
</body></html>
EOT
	);

	return RC_OK;
}

sub web_alphasign_set {
	my ($request, $response) = @_;

	my $q = new CGI($request->content);
	my $mode = $q->param('mode');
	my $text = $q->param('text');
	my $beep = $q->param('beep');

	if (not $streaming) {
		$poe_kernel->post($alphasign, 'text', $mode, $text);
		$beep and $poe_kernel->post($alphasign, 'beep');
	}

	$response->protocol("HTTP/1.0");
	$response->code(302);
	$response->header('Location' => 'alphasign');

	return RC_OK;
}


## IRC

package brmd::IRC;

use POE qw(Component::IRC Component::IRC::Plugin::Connector);
use URI;

sub new {
	my $class = shift;
	my $self = bless { }, $class;

	my $irc = POE::Component::IRC->spawn(
		nick => 'brmbot',
		ircname => 'The Brmitron',
		server => 'irc.freenode.org',
	) or die "IRC fail: $!";
	my $connector = POE::Component::IRC::Plugin::Connector->new();

	POE::Session->create(
		object_states => [
			$self => [ qw(_start _default
					irc_001 irc_public irc_332 irc_topic
					notify_update
					notify_door_unauth notify_door_unlocked notify_door_open) ],
		],
		heap => { irc => $irc, connector => $connector },
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");
	my $irc = $_[HEAP]->{irc};
	$irc->yield( register => 'all' );
	$irc->plugin_add( 'Connector' => $_[HEAP]->{connector} );
	$irc->yield( connect => { } );
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "IRC $event: " );

	for my $arg (@$args) {
		if ( ref $arg eq 'ARRAY' ) {
			push( @output, '[' . join(', ', @$arg ) . ']' );
		}
		else {
			push( @output, "'$arg'" );
		}
	}
	print join ' ', @output, "\n";
}

sub irc_001 {
	my $sender = $_[SENDER];

	# Since this is an irc_* event, we can get the component's object by
	# accessing the heap of the sender. Then we register and connect to the
	# specified server.
	my $irc = $sender->get_heap();

	print "Connected to ", $irc->server_name(), "\n";

	$irc->yield( join => $_ ) for @channels;
}

sub irc_public {
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $irc = $sender->get_heap();
	my $nick = ( split /!/, $who )[0];
	my $channel = $where->[0];

	if ( my ($rot13) = $what =~ /^!rot13 (.+)/ ) {
		$rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
		$irc->yield( privmsg => $channel => "$nick: $rot13" );
	}

	if ( my ($alpha) = $what =~ /^!alpha (.+)/ ) {
		my $wa = WWW::WolframAlpha->new ( appid => 'P6XPHG-URK5HXVWXL', );
		my $query = $wa->query( input => $alpha, );
		if ($query->success) {
			my $first = 1;
			my $npods = 3;
			foreach my $pod (@{$query->pods}[0..$npods-1]) {
				$pod or next;
				if (!$pod->error) {
					my @answers;
					push @answers, $pod->title if $pod->title;
					foreach my $subpod (@{$pod->subpods}) {
						if ($subpod->plaintext) {
							my $sanswer = '';
							$sanswer .= ($subpod->title . ': ') if $subpod->title;
							$sanswer .= $subpod->plaintext;
							push @answers, split (/\n+/, $sanswer);
						}
					}
					if ($first) {
						my $sanswer = URI->new("http://www.wolframalpha.com/input/?i=$alpha")->as_string;
						$sanswer .= " (trimmed)" if (@{$query->pods} > $npods);
						push @answers, $sanswer;
						$first = 0;
					}
					my $answer = join(" \3"."14::\3 ", @answers);
					$irc->yield( privmsg => $channel => "$nick: $answer" );
				} else {
					$irc->yield( privmsg => $channel => "$nick: Error " . $pod->error->code . ": " . $pod->error->msg );
				}
			}
		} else {
			$irc->yield( privmsg => $channel => "$nick: No results." );
		}
	}
}

sub irc_332 {
	my ($sender, $server, $str, $data) = @_[SENDER, ARG0 .. ARG2];
	$topic = $data->[1];
	print "new topic: $topic\n";
	topic_update($_[HEAP]->{irc});
}

sub irc_topic {
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $channel = $where;
	$topic = $what;
	print "new topic: $topic\n";
	topic_update($_[HEAP]->{irc});
}

sub topic_update {
	my ($irc) = @_;
	my $newtopic = $topic;
	if ($status) {
		$newtopic =~ s/BRMLAB CLOSED/BRMLAB OPEN/g;
	} else {
		$newtopic =~ s/BRMLAB OPEN/BRMLAB CLOSED/g;
	}
	if ($streaming) {
		$newtopic =~ s#OFF AIR#ON AIR ($streamurl)#g;
	} else {
		$newtopic =~ s#ON AIR.*? \|#OFF AIR |#g;
	}
	if ($newtopic ne $topic) {
		$topic = $newtopic;
		$irc->yield (topic => $_ => $topic ) for @channels;
	}
}

sub notify_update {
	my ($sender, $comp, $status, $extra, $manual, $nick) = @_[SENDER, ARG0 .. ARG4];
	my $irc = $_[HEAP]->{irc};
	my $msg = "[$comp] update: \002$status\002";
	$extra and $msg .= " $extra";
	$manual and $msg .= " ($manual manual override by $nick)";
	$irc->yield (privmsg => $_ => $msg ) for @channels;
	topic_update($irc);
}

sub notify_door_unauth {
	my ($sender) = $_[SENDER];
	my $irc = $_[HEAP]->{irc};
	my $msg = "[door] \002unauthorized access\002 denied!";
	$irc->yield (privmsg => $_ => $msg ) for @channels;
}

sub notify_door_unlocked {
	my ($sender) = @_[SENDER, ARG0];
	my $irc = $_[HEAP]->{irc};
	my $msg = "[door] unlocked";
	$irc->yield (privmsg => $_ => $msg ) for @channels;
}

sub notify_door_open {
	my ($sender, $newstate, $alert) = @_[SENDER, ARG0, ARG1];
	$alert or return;

	my $irc = $_[HEAP]->{irc};
	my $msg = "[door] $newstate \002(alert: closed brmlab, door opened, not unlocked)";
	$irc->yield (privmsg => $_ => $msg ) for @channels;
}

1;


## Live Stream

package brmd::Stream;

use POE;

sub new {
	my $class = shift;
	my $self = bless { }, $class;

	POE::Session->create(
		object_states => [
			$self => [ qw(_start _default
					stream_start stream_stop) ],
		],
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "Stream $event: " );

	for my $arg (@$args) {
		if ( ref $arg eq 'ARRAY' ) {
			push( @output, '[' . join(', ', @$arg ) . ']' );
		}
		else {
			push( @output, "'$arg'" );
		}
	}
	print join ' ', @output, "\n";
}

sub stream_switch {
	my ($s) = @_;
	system('ssh brmlab@brmvid "echo '.($s?'START':'STOP').' >/tmp/brmstream"');
}

sub stream_start {
	stream_switch(1);
}

sub stream_stop {
	stream_switch(0);
}

1;


## Logging

package brmd::Log;

use POE;
use Logger::Syslog;

sub new {
	my $class = shift;
	my $self = bless { }, $class;

	POE::Session->create(
		object_states => [
			$self => [ qw(_start _default
					notify_door_unauth notify_door_unlocked) ],
		],
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");
	$poe_kernel->post($door, 'register');
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "Log $event: " );

	for my $arg (@$args) {
		if ( ref $arg eq 'ARRAY' ) {
			push( @output, '[' . join(', ', @$arg ) . ']' );
		}
		else {
			push( @output, "'$arg'" );
		}
	}
	print join ' ', @output, "\n";
}

sub notify_door_unauth {
	my ($sender, $cardid) = @_[SENDER, ARG0];
	error ("[door] unauthorized access denied for card " . $cardid);
}

sub notify_door_unlocked {
	my ($sender, $nick) = @_[SENDER, ARG0];
	info ("[door] unlocked by " . $nick);
}

sub notify_door_open {
	my ($sender, $newstate, $alert) = @_[SENDER, ARG0, ARG1];

	info ("[door] $newstate (alert $alert)");
}

1;


## Alphasign LED Display

package brmd::Alphasign;

use POE qw(Wheel::ReadWrite Filter::Block);
use Symbol qw(gensym);
use Device::SerialPort;
use Tie::IxHash;

sub new {
	my $class = shift;
	my $self = bless { last_text => '', last_mode => 'hold' }, $class;

	POE::Session->create(
		object_states => [
			$self => [ qw(_start _default
					serial_error rawtext
					beep text
					stream_start stream_stop) ],
		],
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");

	$_[HEAP]->{serial} = POE::Wheel::ReadWrite->new(
		Handle => \*STDERR, #serial_open($devasign),
		# We want no transformation at all, duh.
		Filter => POE::Filter::Block->new(
			LengthCodec => [ sub {}, sub {1}, ],
		),
		ErrorEvent => "serial_error",
	) or die "Alphasign fail: $!";
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "Alphasign $event: " );

	for my $arg (@$args) {
		if ( ref $arg eq 'ARRAY' ) {
			push( @output, '[' . join(', ', @$arg ) . ']' );
		}
		else {
			push( @output, "'$arg'" );
		}
	}
	print join ' ', @output, "\n";
}

sub serial_open {
	my ($device) = @_;
	# Open a serial port, and tie it to a file handle for POE.
	my $handle = gensym();
	my $port = tie(*$handle, "Device::SerialPort", $device);
	die "can't open port: $!" unless $port;
	$port->datatype('raw');
	$port->baudrate(9600);
	$port->databits(8);
	$port->parity("none");
	$port->stopbits(1);
	$port->handshake("none");
	$port->write_settings();
	$port->write("E\$" . "AAU0100FF00" . "CDU075A2000" . "BBL000F0000");
	return $handle;
}

sub serial_error {
	my ($heap) = ($_[HEAP]);
	print "$_[ARG0] error $_[ARG1]: $_[ARG2]\n";
	print "bye!\n";
}

sub encode {
	my $stuff = shift;
        $stuff = "\x00" x 5   # packet sync characters
	          . "\x01"     # start of header
	          . "Z"        # all types
	          . "00"       # broadcast address
	          . "\x02"     # start of text
	          . $stuff    # raw data
	          . "\x04";    # end of transmission
}

sub beep {
	my ($heap, $mode, $string) = (@_[HEAP, ARG0, ARG1]);
	my $s = "E"  # special function
	        . '('  # speaker tone
	        . '0';  # beep for 2 seconds
	$_[HEAP]{serial}->put(encode($s));
}

sub rawtext {
	my ($heap, $mode, $string) = (@_[HEAP, ARG0, ARG1]);
	print "out text: $mode, $string (".join('',map{sprintf'%02x',ord$_}split(//,$string)).")\n";
	my $s = "A"          # text mode
	        . "A"        # file label
	        . "\x1B"     # start of text
	        . " "        # use middle line (irrelevant on singleline display)
	        . $mode      # display mode
	        . "\x1C1"    # set default color = red
	        . $string;   # text to display
	# This crazy thing makes sure we do not write out the data in
	# more than 32-byte chunks. The syswrites happen in 32-byte
	# chunks and POE::Driver::SysRW is buggy when the write is short
	# and the rest fails with EAGAIN - it tries to write out
	# the whole original chunk again.
	my @rs = split(//, encode($s));
	while (@rs > 0) {
		$_[HEAP]{serial}->put(join('', splice(@rs, 0, 32)));
	}
}

my %modes;
BEGIN {
tie(%modes, 'Tie::IxHash',
	'hold' => 'b',
	'rotate' => 'a',
	'flash' => 'c',
	'roll_up' => 'e',
	'roll_down' => 'f',
	'roll_left' => 'g',
	'roll_right' => 'h',
	'wipe_up' => 'i',
	'wipe_down' => 'j',
	'wipe_left' => 'k',
	'wipe_right' => 'l',
	'random' => 'o',
	'roll_in' => 'p',
	'roll_out' => 'q',
	'wipe_in' => 'r',
	'wipe_out' => 's',
	'compressed' => 't',
	'twinkle' => 'n0',
	'sparkle' => 'n1',
	'snow' => 'n2',
	'interlock' => 'n3',
	'switch' => 'n4',
	'slide' => 'n5',
	'spray' => 'n6',
	'starburst' => 'n7',
	'welcome' => 'n8',
	'slotmachine' => 'n9',
	'thankyou' => 'nS',
	'nosmoking' => 'nU',
	'drink' => 'nV',
	'animal' => 'nW',
	'fireworks' => 'nX',
	'turbocar' => 'nY',
	'bomb' => 'nZ');
}
sub mode_list {
	return keys %modes;
}
my %markup;
BEGIN {
tie(%markup, 'Tie::IxHash',
	red => ["\x1C1", "\x1C1"],
	green => ["\x1C2", "\x1C1"],
	amber => ["\x1C3", "\x1C1"],
	dimred => ["\x1C4", "\x1C1"],
	dimgreen => ["\x1C5", "\x1C1"],
	brown => ["\x1C6", "\x1C1"],
	orange => ["\x1C7", "\x1C1"],
	yellow => ["\x1C8", "\x1C1"],
	rainbow1 => ["\x1C9", "\x1C1"],
	rainbow2 => ["\x1CA", "\x1C1"],
	colormix => ["\x1CB", "\x1C1"],
	autocolor => ["\x1CC", "\x1C1"],
	bold => ["\x1D01", "\x1D00"]);
}
sub markup_help {
	"The following tags are available: ".join(', ', keys %markup)."\n".
	"Example: <bold>bla<green>g</green></bold>bla";
}

sub text {
	my ($heap, $self, $mode, $string) = (@_[HEAP, OBJECT, ARG0, ARG1]);
	$self->{last_mode} = $mode;
	$mode = $modes{$mode};
	$self->{last_text} = $string;
	$string = substr($string, 0, 256);
	$string =~ s/[\000-\037]//g;
	$string =~ s/<\/(.*?)>/$markup{$1}->[1]/gei;
	$string =~ s/<(.*?)>/$markup{$1}->[0]/gei;
	$_[KERNEL]->yield('rawtext', $mode, $string);
}
sub last_mode {
	my $self = shift;
	return $self->{last_mode};
}
sub last_text {
	my $self = shift;
	return $self->{last_text};
}
sub last_text_escaped {
	my $self = shift;
	my $t = $self->last_text();
	$t =~ s/&/\&amp;/g; $t =~ s/</\&lt;/g; $t =~ s/>/\&gt;/g;
	return $t;
}

sub stream_start {
	$_[KERNEL]->yield('text', 'hold', "<green>ON AIR</green>");
	$_[KERNEL]->yield('beep');
}

sub stream_stop {
	$_[KERNEL]->yield('text', 'hold', "<bold>OFF AIR</bold>");
}

1;
