#!/usr/bin/perl

use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::Plugin::Connector Component::Server::HTTP
		Wheel::ReadWrite Filter::Line);
use Symbol qw(gensym);
use Device::SerialPort;
use HTTP::Status qw/RC_OK/;

our $channel = "#brmlab";
our $device = "/dev/ttyUSB0";
our ($status, $record, $topic) = (0, 0, 'BRMLAB OPEN');

my $irc = POE::Component::IRC->spawn(
	nick => 'brmbot',
	ircname => 'The Brmlab Automaton',
	server => 'irc.freenode.org',
) or die "Oh noooo! $!";

my $web = POE::Component::Server::HTTP->new(
	Port           => 8088,
	ContentHandler => {
		"/brmstatus.html" => \&web_brmstatus_html,
		"/brmstatus.js" => \&web_brmstatus_js,
		"/brmstatus.png" => \&web_brmstatus_png,
		"/brmstatus.txt" => \&web_brmstatus_txt,
		"/" => \&web_index
	},
	Headers => {Server => 'brmd/xxx'},
) or die "Oh neee! $!";


POE::Session->create(
	package_states => [
		main => [ qw(_default _start irc_001 irc_public irc_332 irc_topic) ],
	],
	inline_states => {
		serial_input => \&serial_input,
		serial_error => \&serial_error,
	},
	heap => { irc => $irc },
);

$poe_kernel->run();


sub _start {
	my $heap = $_[HEAP];

	$heap->{serial} = POE::Wheel::ReadWrite->new(
		Handle => serial_open($device),
		Filter => POE::Filter::Line->new(
			InputLiteral  => "\x0A",    # Received line endings.
			OutputLiteral => "\x0A",    # Sent line endings.
			),
		InputEvent => "serial_input",
		ErrorEvent => "serial_error",
	) or die "Oh ooops! $!";

	# retrieve our component's object from the heap where we stashed it
	my $irc = $heap->{irc};

	$irc->yield( register => 'all' );
	$heap->{connector} = POE::Component::IRC::Plugin::Connector->new();
	$irc->plugin_add( 'Connector' => $heap->{connector} );
	$irc->yield( connect => { } );
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( (scalar localtime), "$event: " );

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

sub topic_update {
	my $newtopic = $topic;
	if ($status) {
		$newtopic =~ s/BRMLAB CLOSED/BRMLAB OPEN/g;
	} else {
		$newtopic =~ s/BRMLAB OPEN/BRMLAB CLOSED/g;
	}
	if ($newtopic ne $topic) {
		$topic = $newtopic;
		$irc->yield (topic => $channel => $topic );
	}
}

sub status_update {
	my ($newstatus) = @_;
	$status = $newstatus;
	my $st = status_str();
	$irc->yield (privmsg => $channel => "[brmstatus] update: \002$st" );
	topic_update();
}

sub record_update {
	my ($newrecord) = @_;
	$record = $newrecord;
	my $st = record_str();
	$irc->yield (privmsg => $channel => "[brmvideo] update (TODO): \002$st" );
}


## Brmdoor serial

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
	my ($input) = ($_[ARG0]);
	print ((scalar localtime)." $input\n");
	$input =~ /^(\d) (\d) (.*)$/ or return;
	my ($cur_status, $cur_record, $brm) = ($1, $2, $3);
	if ($cur_status != $status) {
		status_update($cur_status);
	}
	if ($cur_record != $record) {
		record_update($cur_record);
	}
	if ($brm =~ s/^CARD //) {
		print "from brmdoor: $input\n";
		if ($brm =~ /^UNKNOWN/) {
			$irc->yield (privmsg => $channel => "[brmdoor] unauthorized access denied!" );
		} else {
			$irc->yield (privmsg => $channel => "[brmdoor] unlocked by: \002$brm" );
		}
	}
}

sub serial_error {
	my ($heap) = ($_[HEAP]);
	print "$_[ARG0] error $_[ARG1]: $_[ARG2]\n";
	print "bye!\n";
}


## Web interface

sub disable_caching {
	my ($response) = @_;
	$response->push_header("Cache-Control", "no-cache, must-revalidate");
	$response->push_header("Expires", "Sat, 26 Jul 1997 05:00:00 GMT");
}

sub web_index {
	my ($request, $response) = @_;

	my $sts = status_str();
	my $str = record_str();

	$response->protocol("HTTP/1.1");
	$response->code(RC_OK);
	$response->push_header("Content-Type", "text/html");
	disable_caching($response);

	$response->content(<<EOT
<html>
<head><title>brmd</title></head>
<body>
<img src="http://brmlab.cz/lib/tpl/brmlab/images/brmlab_logo.png" alt="brmlab" align="right" />
<h1>brmd web interface</h1>
<p>Enjoy the view!</p>
<ul>
<li><strong>brmstatus</strong> ($sts) <a href="brmstatus.html">status page</a> | <a href="brmstatus.js">javascript code</a> | <a href="brmstatus.txt">plaintext file</a> | <a href="brmstatus.png">picture</a></li>
<li><strong>brmvideo</strong> ($str) live feed coming soon!</li>
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

	my $st = status_str();

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


## IRC

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
	topic_update();
}

sub irc_topic {
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $channel = $where;
	$topic = $what;
	print "new topic: $topic\n";
	topic_update();
}
