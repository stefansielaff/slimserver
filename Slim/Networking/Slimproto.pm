package Slim::Networking::Slimproto;

# $Id: Slimproto.pm,v 1.2 2003/07/30 23:01:57 sadams Exp $

# Slim Server Copyright (c) 2001, 2002, 2003 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use FindBin qw($Bin);
use IO::Socket;
use IO::Select;
use FileHandle;
use Net::hostent;              # for OO version of gethostbyaddr
use Sys::Hostname;
use File::Spec::Functions qw(:ALL);
use POSIX qw(:fcntl_h strftime);
use Fcntl qw(F_GETFL F_SETFL);
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

use Errno qw(EWOULDBLOCK EINPROGRESS);

my $SLIMPROTO_ADDR = 0;
my $SLIMPROTO_PORT = 3483;

my $slimproto_socket;
my $slimSelRead  = IO::Select->new();
my $slimSelWrite = IO::Select->new();

my %peeraddr;     	# peer address for each socket
my %inputbuffer;  	# inefficiently append data here until we have a full slimproto frame
my %parser_state; 	# 'LENGTH', 'OP', or 'DATA'
my %parser_framelength; # total number of bytes for data frame
my %parser_frametype;   # frame type eg "HELO", "IR  ", etc.

sub init {
	my ($listenerport, $listeneraddr) = ($SLIMPROTO_PORT, $SLIMPROTO_ADDR);

	$slimproto_socket = IO::Socket::INET ->new(
		Proto => 'tcp',
		LocalAddr => $listeneraddr,
		LocalPort => $listenerport,
		Listen    => SOMAXCONN,
		ReuseAddr     => 1,
		Reuse     => 1,
		Timeout   => 0.001
	) || die "Can't listen on port $listenerport for Slim protocol: $!";

        defined($slimproto_socket->blocking(0))  || die "Cannot set port nonblocking";

	$slimSelRead->add($slimproto_socket);
	$main::selRead->add($slimproto_socket);

	$::d_protocol && msg "Squeezebox protocol listening on port $listenerport\n";	
}

sub idle {

	my $selReadable;
	my $selWriteable;

	($selReadable, $selWriteable) = IO::Select->select($slimSelRead, $slimSelWrite, undef, 0);

	my $sock;
	foreach $sock (@$selReadable) {

		if ($sock eq $slimproto_socket) {
			slimproto_accept();
		} else {
			client_readable($sock);
		}
	}

	foreach $sock (@$selWriteable) {
		next if ($sock == $slimproto_socket);  # never happens, right?
		client_writeable($sock);
	}
}


sub slimproto_accept {
	my $clientsock = $slimproto_socket->accept();

	return unless $clientsock;

        defined($clientsock->blocking(0))  || die "Cannot set port nonblocking";

	my $peer = $clientsock->peeraddr;

	if (!($clientsock->connected && $peer)) {
		$::d_protocol && msg ("Slimproto accept failed; couldn't get peer addr.\n");
		return;
	}

	my $tmpaddr = inet_ntoa($peer);

	if ((Slim::Utils::Prefs::get('filterHosts')) &&
		!(Slim::Utils::Misc::isAllowedHost($tmpaddr))) {
		$::d_protocol && msg ("Slimproto unauthorized host, accept denied: $tmpaddr\n");
		$clientsock->close();
		return;
	}
	
	$peeraddr{$clientsock} = $tmpaddr;
	$parser_state{$clientsock} = 'OP';
	$parser_framelength{$clientsock} = 0;
	$inputbuffer{$clientsock}='';

	$slimSelRead->add($clientsock);
#	$slimSelWrite->add($clientsock);      # for now assume it's always writeable.
	$::main::selRead->add($clientsock);
#	$::main::selWrite->add($clientsock);

	$::d_protocol && msg ("Slimproto accepted connection from: $tmpaddr\n");
}

sub slimproto_close {
	my $clientsock = shift;

	# stop selecting	
	$slimSelRead->remove($clientsock);
	$main::selRead->remove($clientsock);
	$slimSelWrite->remove($clientsock);
	$main::selWrite->remove($clientsock);

	# close socket
	$clientsock->close();

	# forget state
	delete($peeraddr{$clientsock});
	delete($parser_state{$clientsock});
	delete($parser_framelength{$clientsock});
}		

sub client_writeable {
	my $clientsock = shift;

	# this prevent the "getpeername() on closed socket" error, which
	# is caused by trying to close the file handle after it's been closed during the
	# read pass but it's still in our writeable list. Don't try to close it twice - 
	# just ignore if it shouldn't exist.
	return unless (defined($peeraddr{$clientsock})); 
	
	$::d_protocol && msg("Slimproto client writeable: ".$peeraddr{$clientsock}."\n");

	if (!($clientsock->connected)) {
		$::d_protocol && msg("Slimproto connection closed by peer.\n");
		slimproto_close($clientsock);		
		return;
	}		
}

sub client_readable {
	my $s = shift;

	$::d_protocol && msg("Slimproto client readable: ".$peeraddr{$s}."\n");

GETMORE:
	if (!($s->connected)) {
		$::d_protocol && msg("Slimproto connection closed by peer.\n");
		slimproto_close($s);		
		return;
	}			

	my $bytes_remaining;

	$::d_protocol && msg(join(', ', 
		"state: ".$parser_state{$s},
		"framelen: ".$parser_framelength{$s},
		"inbuflen: ".length($inputbuffer{$s})
		)."\n");

	if ($parser_state{$s} eq 'OP') {
		$bytes_remaining = 4 - length($inputbuffer{$s});
                assert ($bytes_remaining <= 4);
	} elsif ($parser_state{$s} eq 'LENGTH') {
		$bytes_remaining = 4 - length($inputbuffer{$s});
		assert ($bytes_remaining <= 4);
	} else {
		assert ($parser_state{$s} eq 'DATA');
		$bytes_remaining = $parser_framelength{$s} - length($inputbuffer{$s});
	}
	assert ($bytes_remaining > 0);

	$::d_protocol && msg("attempting to read $bytes_remaining bytes\n");

	my $indata;
	my $bytes_read = $s->read($indata, $bytes_remaining);
	$inputbuffer{$s}.=$indata;

	if ($bytes_read == 0) {
#		$::d_protocol && msg("Slimproto half-close from client: ".$peeraddr{$s}."\n");
#		slimproto_close($s);
#		return;

		$::d_protocol && msg("no more to read.\n");
		return;

	}

	$bytes_remaining -= $bytes_read;

	$::d_protocol && msg ("Got $bytes_read bytes from client, $bytes_remaining remaining\n");

	assert ($bytes_remaining>=0);

	if ($bytes_remaining == 0) {
		if ($parser_state{$s} eq 'OP') {
			assert(length($inputbuffer{$s}) == 4);
			$parser_frametype{$s} = $inputbuffer{$s};
			$inputbuffer{$s} = '';
			$parser_state{$s} = 'LENGTH';

			$d::protocol && msg("got op: ". $parser_frametype{$s}."\n");

		} elsif ($parser_state{$s} eq 'LENGTH') {
			assert(length($inputbuffer{$s}) == 4);
			$parser_framelength{$s} = unpack('N', $inputbuffer{$s});
			$parser_state{$s} = 'DATA';
			$inputbuffer{$s} = '';

			if ($parser_framelength{$s} > 1000) {
				$::d_protocol && msg ("Client gave us insane length ".$parser_framelength{$s}." for slimproto frame. Disconnecting him.\n");
				slimproto_close($s);
				return;
			}

		} else {
			assert($parser_state{$s} eq 'DATA');
			assert(length($inputbuffer{$s}) == $parser_framelength{$s});
			&process_slimproto_frame($s, $parser_frametype{$s}, $inputbuffer{$s});
			$inputbuffer{$s} = '';
			$parser_frametype{$s} = '';
			$parser_framelength{$s} = 0;
			$parser_state{$s} = 'OP';
		}
	}

	$::d_protocol && msg("new state: ".$parser_state{$s}."\n");
	goto GETMORE;
}


sub process_slimproto_frame {
	my ($s, $op, $data) = @_;

	print "Got Slimptoto frame, op $op data $data\n";

}

1;

