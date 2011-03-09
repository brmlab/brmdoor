#!/usr/bin/perl

use strict;
use warnings;
use POE qw(Component::IRC Component::Client::TCP Component::Server::HTTP);
use HTTP::Status qw/RC_OK/;

our $channel = "#brmlab";
our ($status, $record, $topic) = (0, 0, 'BRMLAB OPEN');

my $irc = POE::Component::IRC->spawn(
	nick => 'brmbot',
	ircname => 'The Brmlab Automaton',
	server => 'irc.freenode.org',
) or die "Oh noooo! $!";

my $door = POE::Component::Client::TCP->new(
	RemoteAddress => "192.168.1.3",
	RemotePort    => 23,
	ServerInput   => \&brmdoor_input,
) or die "Oh naaaay! $!";

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
	heap => { irc => $irc },
);

$poe_kernel->run();


sub _start {
	my $heap = $_[HEAP];

	# retrieve our component's object from the heap where we stashed it
	my $irc = $heap->{irc};

	$irc->yield( register => 'all' );
	$irc->yield( connect => { } );
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( "$event: " );

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


## Brmdoor

sub brmdoor_input {
	my $input = $_[ARG0];
	$input =~ /^(\d) (\d) (.*)$/ or return;
	my ($cur_status, $cur_record, $brm) = ($1, $2, $3);
	if ($cur_status != $status) {
		$status = $cur_status;
		my $st = status_str();
		$irc->yield (privmsg => $channel => "[brmstatus] update: \002$st" );
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
	if ($cur_record != $record) {
		$record = $cur_record;
		my $st = record_str();
		$irc->yield (privmsg => $channel => "[brmvideo] update (TODO): \002$st" );
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
<li><strong>brmstatus</strong> ($sts) <a href="brmstatus.html">status page</a> | <a href="brmstatus.js">javascript code</a> | <a href="brmstatus.png">picture</a></li>
<li><strong>brmvideo</strong> ($str) live feed coming soon!</li>
</ul>
</body></html>
EOT
	);

	return RC_OK;
}

sub web_brmstatus_html {
	my ($request, $response) = @_;

	my $bg = $status ? 'lightgreen' : '#DEE7EC';
	my $st = $status ? 'OPEN' : 'CLOSED';

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
	print "new topic: $topic\n"
}

sub irc_topic {
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $channel = $where;
	$topic = $what;
	print "new topic: $topic\n"
}
