#!/usr/bin/perl

use strict;
use warnings;
use POE;

our $channel = "#brmlab";
our $streamurl = "http://nat.brmlab.cz:8090/brmstream.asf";
our $device = $ARGV[0]; $device ||= "/dev/ttyUSB0";
our ($status, $record, $topic) = (0, 0, 'BRMLAB OPEN');
our $serial;

my $irc = brmd::IRC->new();
my $web = brmd::WWW->new();
my $door = brmd::Door->new();


POE::Session->create(
	package_states => [
		main => [ qw(_default _start) ],
	],
	heap => { irc => $irc, web => $web },
);

$poe_kernel->run();


sub _start {
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

sub stream_switch {
	my ($s) = @_;
	system('ssh brmstream@brmvid "echo '.($s?'START':'STOP').' >/tmp/brmstream"');
}

sub record_start { stream_switch(1); }
sub record_stop { stream_switch(0); }

sub status_update {
	my ($newstatus) = @_;
	$status = $newstatus;
	my $st = status_str();
	$poe_kernel->post( $irc, notify => "[brmstatus] update: \002$st" );
	$poe_kernel->post( $irc, 'topic_update' );
}

sub record_update {
	my ($newrecord) = @_;
	$record = $newrecord;
	if ($record) {
		record_start();
	} else {
		record_stop();
	}

	my $st = record_str();
	$record and $st .= "\002 $streamurl";
	$poe_kernel->post( $irc, notify => "[brmvideo] update: \002$st" );
	$poe_kernel->post( $irc, 'topic_update' );
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
			$self => [ qw(_start _default
					serial_input serial_error) ],
		],
	);

	return $self;
}

sub _start {
	$_[KERNEL]->alias_set("$_[OBJECT]");

	$serial = $_[HEAP]->{serial} = POE::Wheel::ReadWrite->new(
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
		print "from door: $input\n";
		if ($brm =~ /^UNKNOWN/) {
			$poe_kernel->post( $irc, 'notify' => "[door] unauthorized access denied!" );
		} else {
			$poe_kernel->post( $irc, 'notify' => "[door] unlocked by: \002$brm" );
		}
	}
}

sub serial_error {
	my ($heap) = ($_[HEAP]);
	print "$_[ARG0] error $_[ARG1]: $_[ARG2]\n";
	print "bye!\n";
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
			"/brmstatus-switch" => \&web_brmstatus_switch,
			"/" => \&web_index
		},
		Headers => {Server => 'brmd/xxx'},
	) or die "WWW fail: $!";

	POE::Session->create(
		object_states => [
			$self => [ qw(_start _default) ],
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
	my ($request, $response) = @_;

	my $q = new CGI($request->content);
	my $nick = $q->param('nick');

	my $newstatus = not $status;

	$serial->put('s'.$newstatus);
	$serial->flush();

	$poe_kernel->post($irc, 'notify' => "[brmstatus] Manual override by $nick (web)" );
	main::status_update($newstatus);

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
					topic_update notify) ],
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
	topic_update();
}

sub irc_topic {
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $channel = $where;
	$topic = $what;
	print "new topic: $topic\n";
	topic_update();
}

sub topic_update {
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
		# retrieve our component's object from the heap where we stashed it
		my $irc = $_[HEAP]->{irc};
		$irc->yield (topic => $channel => $topic );
	}
}

sub notify {
	my ($sender, $msg) = @_[SENDER, ARG0];
	my $irc = $_[HEAP]->{irc};
	$irc->yield (privmsg => $channel => $msg );
}

1;
