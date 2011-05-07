#!/usr/bin/perl

use strict;
use warnings;
use POE;

our $channel = "#brmlab";
our $streamurl = "http://nat.brmlab.cz:8090/brmstream.asf";
our $device = $ARGV[0]; $device ||= "/dev/ttyUSB0";
our ($status, $record, $topic) = (0, 0, 'BRMLAB OPEN');

my $irc = brmd::IRC->new();
my $web = brmd::WWW->new();
my $door = brmd::Door->new();
my $stream = brmd::Stream->new();


POE::Session->create(
	package_states => [
		main => [ qw(_default _start
				status_update record_update) ],
	],
	heap => { irc => $irc, web => $web, door => $door, stream => $stream },
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

sub record_str {
	$record ? 'ON AIR' : 'OFF AIR';
}

sub status_update {
	my ($self, $newstatus, $manual, $nick) = @_[OBJECT, ARG0 .. ARG2];
	$status = $newstatus;
	my $st = status_str();

	if ($manual) {
		$poe_kernel->post($door, 'status_override', $status);
	}

	$poe_kernel->post( $irc, 'notify_update', 'brmstatus', $st, undef, $manual, $nick );
}

sub record_update {
	my ($self, $newrecord) = @_[OBJECT, ARG0];
	$record = $newrecord;
	if ($record) {
		$poe_kernel->post( $stream, 'stream_start' );
	} else {
		$poe_kernel->post( $stream, 'stream_stop' );
	}

	my $st = record_str();
	$record and $st .= "\002 $streamurl";
	$poe_kernel->post( $irc, 'notify_update', 'brmvideo', $st, $record ? $streamurl : undef );
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
					status_override) ],
		],
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");

	$_[HEAP]->{serial} = POE::Wheel::ReadWrite->new(
		Handle => serial_open($device),
		Filter => POE::Filter::Line->new(
			InputLiteral  => "\x0A",    # Received line endings.
			OutputLiteral => "\x0A",    # Sent line endings.
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
	$poe_kernel->refcount_increment($sid, 'observer_WWW'); # XXX: No decrement
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
	$port->stopbits(1);
	$port->handshake("none");
	$port->write_settings();
	return $handle;
}

sub serial_input {
	my ($self, $input) = @_[OBJECT, ARG0];
	print ((scalar localtime)." $input\n");
	$input =~ /^(\d) (\d) (.*)$/ or return;
	my ($cur_status, $cur_record, $brm) = ($1, $2, $3);
	if ($cur_status != $status) {
		foreach (@{$self->{observers}}) {
			$poe_kernel->post($_, 'status_update', $cur_status);
		}
	}
	if ($cur_record != $record) {
		foreach (@{$self->{observers}}) {
			$poe_kernel->post($_, 'record_update', $cur_record);
		}
	}
	if ($brm =~ s/^CARD //) {
		print "from door: $input\n";
		if ($brm =~ /^UNKNOWN/) {
			$poe_kernel->post( $irc, 'notify_door_unauth' );
		} else {
			$poe_kernel->post( $irc, 'notify_door_unlocked', $brm );
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
	my $str = main::record_str();

	$response->protocol("HTTP/1.1");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/html");
	disable_caching($response);

	my $r_link = '';
	$record and $r_link .= '<a href="'.$streamurl.'">watch now!</a>';

	$response->content(<<EOT
<html>
<head><title>brmd</title></head>
<body>
<img src="http://brmlab.cz/lib/tpl/brmlab/images/brmlab_logo.png" alt="brmlab" align="right" />
<h1>brmd web interface</h1>
<p>Enjoy the view!</p>
<ul>
<li><strong>brmstatus</strong> ($sts) <a href="brmstatus.html">status page</a> | <a href="brmstatus.js">javascript code</a> | <a href="brmstatus.txt">plaintext file</a> | <a href="brmstatus.png">picture</a></li>
<li><strong>brmvideo</strong> ($str) $r_link</li>
</ul>
<p align="right"><a href="http://gitorious.org/brmlab/brmdoor">(view source)</a></p>
</body></html>
EOT
	);

	return RC_OK;
}

sub web_brmstatus_html {
	my ($request, $response) = @_;

	my $bg = $status ? 'lightgreen' : '#DEE7EC';
	my $st = $status ? 'OPEN' : 'CLOSED';

	$response->protocol("HTTP/1.1");
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

	$response->protocol("HTTP/1.1");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/javascript");
	disable_caching($response);

	$response->content(<<EOT
function brmstatus() { return ($status); }
EOT
	);

	return RC_OK;
}

sub web_brmstatus_txt {
	my ($request, $response) = @_;

	my $st = main::status_str();

	$response->protocol("HTTP/1.1");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/plain");
	disable_caching($response);

	$response->content($st);

	return RC_OK;
}

sub web_brmstatus_png {
	my ($request, $response) = @_;

	open my $img, ($status ? "status-open.png" : "status-closed.png");
	local $/;
	my $imgdata = <$img>;
	close $img;

	$response->protocol("HTTP/1.1");
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

	my $newstatus = not $status;
	foreach (@{$self->{observers}}) {
		$poe_kernel->post($_, 'status_update', $newstatus, 'web', $nick);
	}

	$response->protocol("HTTP/1.1");
	$response->code(302);
	$response->header('Location' => 'brmstatus.html');

	return RC_OK;
}


## IRC

package brmd::IRC;

use POE qw(Component::IRC Component::IRC::Plugin::Connector);

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
					notify_door_unauth notify_door_unlocked) ],
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

	$irc->yield( join => $channel );
}

sub irc_public {
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $irc = $sender->get_heap();
	my $nick = ( split /!/, $who )[0];
	my $channel = $where->[0];

	if ( my ($rot13) = $what =~ /^rot13 (.+)/ ) {
		$rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
		$irc->yield( privmsg => $channel => "$nick: $rot13" );
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
	if ($record) {
		$newtopic =~ s#OFF AIR#ON AIR ($streamurl)#g;
	} else {
		$newtopic =~ s#ON AIR.*? \|#OFF AIR |#g;
	}
	if ($newtopic ne $topic) {
		$topic = $newtopic;
		$irc->yield (topic => $channel => $topic );
	}
}

sub notify_update {
	my ($sender, $comp, $status, $extra, $manual, $nick) = @_[SENDER, ARG0 .. ARG4];
	my $irc = $_[HEAP]->{irc};
	my $msg = "[$comp] update: \002$status\002";
	$extra and $msg .= " $extra";
	$manual and $msg .= " ($manual manual override by $nick)";
	$irc->yield (privmsg => $channel => $msg );
	topic_update($irc);
}

sub notify_door_unauth {
	my ($sender) = $_[SENDER];
	my $irc = $_[HEAP]->{irc};
	my $msg = "[door] unauthorized access denied!";
	$irc->yield (privmsg => $channel => $msg );
}

sub notify_door_unlocked {
	my ($sender, $nick) = @_[SENDER, ARG0];
	my $irc = $_[HEAP]->{irc};
	my $msg = "[door] unlocked by: \002$nick";
	$irc->yield (privmsg => $channel => $msg );
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
	system('ssh brmstream@brmvid "echo '.($s?'START':'STOP').' >/tmp/brmstream"');
}

sub stream_start {
	stream_switch(1);
}

sub stream_stop {
	stream_switch(0);
}

1;
