package Slim::Buttons::XMLBrowser;

# $Id$

# Copyright (c) 2005 Slim Devices, Inc. (www.slimdevices.com)

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# This file create the 'xmlbrowser' mode.  The mode allows users to scroll
# through Podcast entries, RSS & OPML Outlines and play audio enclosures. 

use strict;

use Slim::Buttons::Common;
use Slim::Control::Request;
use Slim::Formats::XML;
use Slim::Utils::Misc;

sub init {
	Slim::Buttons::Common::addMode('xmlbrowser', getFunctions(), \&setMode);
}

sub getFunctions {
	return {};
}

sub setMode {
	my $client = shift;
	my $method = shift;

	if ($method eq 'pop') {
		Slim::Buttons::Common::popMode($client);
		return;
	}

	my $url = $client->param('url');

	# if no url, error
	if (!$url) {
		my @lines = (
			# TODO: l10n
			"Podcast Browse Mode requires url param",
		);

		#TODO: display the error on the client
		my %params = (
			'header'  => "{PODCAST_ERROR} {count}",
			'listRef' => \@lines,
		);

		Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);

	} else {
		
		# Grab expires param here, as the block will change the param stack
		my $expires = $client->param('expires');
		
		# Callbacks to report success/failure of feeds.  This is used by the
		# RSS plugin on SN to log errors.
		my $onSuccess = $client->param('onSuccess');
		my $onFailure = $client->param('onFailure');

		# give user feedback while loading
		$client->block(
			$client->string( $client->param('header') || 'PODCAST_LOADING' ),
			$client->param('title') || $url,
		);
		
		Slim::Formats::XML->getFeedAsync( 
			\&gotFeed,
			\&gotError,
			{
				'client'    => $client,
				'url'       => $url,
				'expires'   => $expires,
				'onSuccess' => $onSuccess,
				'onFailure' => $onFailure,
			},
		);

		# we're done.  gotFeed callback will finish setting up mode.
	}
}

sub gotFeed {
	my ( $feed, $params ) = @_;
	
	my $client = $params->{'client'};
	my $url    = $params->{'url'};

	# must unblock now, before pushMode is called by getRSS or gotOPML
	$client->unblock;
	
	# notify success callback if necessary
	if ( ref $params->{'onSuccess'} eq 'CODE' ) {
		my $cb = $params->{'onSuccess'};
		$cb->( $client, $url );
	}

	# "feed" was originally an RSS feed.  Now it could be either RSS or an OPML outline.
	if ($feed->{'type'} eq 'rss') {

		gotRSS($client, $url, $feed);

	} elsif ($feed->{'type'} eq 'opml') {

		gotOPML($client, $url, $feed);

	} else {
		$client->update();
	}
}

sub gotError {
	my ( $err, $params ) = @_;
	
	my $client = $params->{'client'};
	my $url    = $params->{'url'};

	$::d_plugins && msg("XMLBrowser: error retrieving <$url>:\n");
	$::d_plugins && msg($err);

	# unblock client
	$client->unblock;
	
	# notify failure callback if necessary
	if ( ref $params->{'onFailure'} eq 'CODE' ) {
		my $cb = $params->{'onFailure'};
		$cb->( $client, $url, $err );
	}

	my @lines = (
		"{PODCAST_GET_FAILED} <$url>",
		$err,
	);

	#TODO: display the error on the client
	my %params = (
		'header'  => "{PODCAST_ERROR} {count}",
		'listRef' => \@lines,
	);

	Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);
}

sub gotPlaylist {
	my ( $feed, $params ) = @_;
	
	my $client = $params->{'client'};

	# must unblock now, before pushMode is called by getRSS or gotOPML
	$client->unblock;

	my @urls = ();

	for my $item (@{$feed->{'items'}}) {

		push @urls, $item->{'url'};
		Slim::Music::Info::setTitle( 
			$item->{'url'}, 
			$item->{'name'} || $item->{'title'}
		);
	}

	$client->execute(['playlist', 'loadtracks', 'listref', \@urls]);
}

sub gotRSS {
	my ($client, $url, $feed) = @_;

	# Include an item to access feed info
	if (($feed->{'items'}->[0]->{'value'} ne 'description') &&
		# skip this if xmlns:slim is used, and no description found
		!($feed->{'xmlns:slim'} && !$feed->{'description'})) {

		my %desc = (
			'name'       => '{PODCAST_FEED_DESCRIPTION}',
			'value'      => 'description',
			'onRight'    => sub {
				my $client = shift;
				my $item   = shift;
				displayFeedDescription($client, $client->param('feed'));
			},

			# play all enclosures...
			'onPlay'     => sub {
				my $client = shift;
				
				Slim::Music::Info::setTitle( 
					$client->param('url'),
					$client->param('feed')->{'title'},
				);

				# play this feed as a playlist
				$client->execute(
					[ 'playlist', 'play',
					$client->param('url'),
					$client->param('feed')->{'title'},
				] );
			},

			'onAdd'      => sub {
				my $client = shift;
				
				Slim::Music::Info::setTitle( 
					$client->param('url'),
					$client->param('feed')->{'title'},
				);				

				# addthis feed as a playlist
				$client->execute(
					[ 'playlist', 'add',
					$client->param('url'),
					$client->param('feed')->{'title'},
				] );
			},

			'overlayRef' => [ undef, Slim::Display::Display::symbol('rightarrow') ],
		);

		unshift @{$feed->{'items'}}, \%desc; # prepend
	}

	# use INPUT.Choice mode to display the feed.
	my %params = (
		'url'      => $url,
		'feed'     => $feed,
		# unique modeName allows INPUT.Choice to remember where user was browsing
		'modeName' => "XMLBrowser:$url",
		'header'   => $feed->{'title'} . ' {count}',

		# TODO: we show only items here, we skip the description of the entire channel
		'listRef'  => $feed->{'items'},

		'name' => sub {
			my $client = shift;
			my $item   = shift;
			return $item->{'title'};
		},

		'onRight' => sub {
			my $client = shift;
			my $item   = shift;
			if (hasDescription($item)) {
				displayItemDescription($client, $item);
			} else {
				displayItemLink($client, $item);
			}
		},

		'onPlay' => sub {
			my $client = shift;
			my $item   = shift;
			playItem($client, $item);
		},

		'onAdd' => sub {
			my $client = shift;
			my $item   = shift;
			playItem($client, $item, 'add');
		},

		'overlayRef' => \&overlaySymbol,
	);

	Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);
}

# use INPUT.Choice to display an OPML list of links. OPML support added
# because podcast alley uses OPML to list its top 10, and newest
# podcasts.  Currently this has been tested only with those OPML
# examples, it may or may not work perfectly with others.
#
# recusively browse OPML outline
sub gotOPML {
	my ($client, $url, $opml) = @_;

	my $title = $opml->{'name'} || $opml->{'title'};

	my %params = (
		'url'        => $url,
		'item'       => $opml,
		# unique modeName allows INPUT.Choice to remember where user was browsing
		'modeName'   => "XMLBrowser:$url:$title",
		'header'     => "$title {count}",
		'listRef'    => $opml->{'items'},

		'isSorted'   => 1,
		'lookupRef'  => sub {
			my $index = shift;

			return $opml->{'items'}->[$index]->{'name'};
		},

		'onRight'    => sub {
			my $client = shift;
			my $item   = shift;

			my $hasItems = scalar @{$item->{'items'}};
			my $isAudio  = $item->{'type'} eq 'audio' ? 1 : 0;
			my $itemURL  = $item->{'url'}  || $item->{'value'};
			my $title    = $item->{'name'} || $item->{'title'};

			if ($itemURL && !$hasItems) {

				# follow a link
				my %params = (
					'url'   => $itemURL,
					'title' => $title,
				);

				if ($isAudio) {

					# Additional info if known
					my @details = ();
					if ( $item->{'bitrate'} ) {
						push @details, '{BITRATE}: ' . $item->{'bitrate'} . ' {KBPS}';
					}
					if ( $item->{'listeners'} ) {
						push @details, '{NUMBER_OF_LISTENERS}: ' . $item->{'listeners'}
					}
					if ( $item->{'current_track'} ) {
						push @details, '{NOW_PLAYING}: ' . $item->{'current_track'};
					}
					if ( $item->{'genre'} ) {
						push @details, '{GENRE}: ' . $item->{'genre'};
					}
					$params{'details'} = \@details;
					
					Slim::Buttons::Common::pushModeLeft($client, 'remotetrackinfo', \%params);

				} else {

					Slim::Buttons::Common::pushMode($client, 'xmlbrowser', \%params);
				}

			} elsif ($hasItems && ref($item->{'items'}) eq 'ARRAY') {

				# recurse into OPML item
				gotOPML($client, $client->param('url'), $item);

			} else {

				$client->bumpRight();
			}
		},

		'onPlay'     => sub {
			my $client = shift;
			my $item   = shift;

			playItem($client, $item);
		},
		'onAdd'      => sub {
			my $client = shift;
			my $item   = shift;

			playItem($client, $item,'add');
		},
		
		'overlayRef' => \&overlaySymbol,
	);

	Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);
}

sub overlaySymbol {
	my ($client, $item) = @_;

	my $overlay = '';

	if (hasAudio($item)) {

		$overlay .= Slim::Display::Display::symbol('notesymbol');
	}

	if (hasDescription($item) || hasLink($item)) {

		$overlay .= Slim::Display::Display::symbol('rightarrow');
	}

	return [ undef, $overlay ];
}

sub hasAudio {
	my $item = shift;

	if ($item->{'type'} && $item->{'type'} =~ /^(?:audio|playlist)$/) {

		return $item->{'url'};

	} elsif ($item->{'enclosure'} && ($item->{'enclosure'}->{'type'} =~ /audio/)) {

		return $item->{'enclosure'}->{'url'};

	} else {

		return undef;
	}
}

sub hasLink {
	my $item = shift;

	# for now, only follow link in "slim" namespace
	return $item->{'slim:link'};
}

sub hasDescription {
	my $item = shift;

	my $description = $item->{'description'} || $item->{'name'};

	if ($description and !ref($description)) {

		return $description;

	} else {

		return undef;
	}
}

sub _breakItemIntoLines {
	my ($client, $item) = @_;

	my @lines   = ();
	my $curline = '';
	my $description = $item->{'description'};

	while ($description =~ /(\S+)/g) {

		my $newline = $curline . ' ' . $1;

		if ($client->measureText($newline, 2) > $client->displayWidth) {
			push @lines, Slim::Formats::XML::trim($curline);
			$curline = $1;
		} else {
			$curline = $newline;
		}
	}

	if ($curline) {
		push @lines, Slim::Formats::XML::trim($curline);
	}

	return ($curline, @lines);
}

sub displayItemDescription {
	my $client = shift;
	my $item = shift;

	# verbose debug
	#use Data::Dumper;
	#print Dumper($item);

	# use remotetrackinfo mode to display item in detail

	# break description into lines
	my ($curline, @lines) = _breakItemIntoLines($client, $item);

	if (my $link = hasLink($item)) {

		push @lines, {
			'name'       => '{PODCAST_LINK}: ' . $link,
			'value'      => $link,
			'overlayRef' => [ undef, Slim::Display::Display::symbol('rightarrow') ],
		}
	}

	if (hasAudio($item)) {

		push @lines, {
			'name'       => '{PODCAST_ENCLOSURE}: ' . $item->{'enclosure'}->{'url'},
			'value'      => $item->{'enclosure'}->{'url'},
			'overlayRef' => [ undef, Slim::Display::Display::symbol('notesymbol') ],
		};

		# its a remote audio source, use remotetrackinfo
		my %params = (
			'title'     =>$item->{'title'},
			'url'       => $item->{'enclosure'}->{'url'},
			'details'   => \@lines,
			'onRight'   => sub {
				my $client = shift;
				my $item = $client->param('item');
				displayItemLink($client, $item);
			},
			'hideTitle' => 1,
			'hideURL'   => 1,
		);

		Slim::Buttons::Common::pushModeLeft($client, 'remotetrackinfo', \%params);

	} else {
		# its not audio, use INPUT.Choice to display...

		my %params = (
			'item'    => $item,
			'header'  => $item->{'title'} . ' {count}',
			'listRef' => \@lines,

			'onRight' => sub {
				my $client = shift;
				my $item   = $client->param('item');
				displayItemLink($client, $item);
			},

			'onPlay'  => sub {
				my $client = shift;
				my $item   = $client->param('item');
				playItem($client, $item);
			},

			'onAdd'   => sub {
				my $client = shift;
				my $item   = $client->param('item');
				playItem($client, $item, 'add');
			},
		);

		Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Choice', \%params);
	}
}

sub displayFeedDescription {
	my $client = shift;
	my $feed = shift;

	# verbose debug
	#use Data::Dumper;
	#print Dumper($feed);

	# use remotetrackinfo mode to display item in detail

	# break description into lines
	my ($curline, @lines) = _breakItemIntoLines($client, $feed);

	# how many enclosures?
	my $count = 0;

	for my $i (@{$feed->{'items'}}) {
		if (hasAudio($i)) {
			$count++;
		}
	}

	if ($count) {
		push @lines, {
			'name'       => '{PODCAST_AUDIO_ENCLOSURES}: ' . $count,
			'value'      => $feed,
			'overlayRef' => [ undef, Slim::Display::Display::symbol('notesymbol') ],
		};
	}

	push @lines, '{PODCAST_URL}: ' . $client->param('url');

	$feed->{'lastBuildDate'}  && push @lines, '{PODCAST_DATE}: ' . $feed->{'lastBuildDate'};
	$feed->{'managingEditor'} && push @lines, '{PODCAST_EDITOR}: ' . $feed->{'managingEditor'};
	
	# TODO: more lines to show feed date, ttl, source, etc.
	# even a line to play all enclosures

	my %params = (
		'url'       => $client->param('url'),
		'title'     => $feed->{'title'},
		'feed'      => $feed,
		'header'    => $feed->{'title'} . ' {count}',
		'details'   => \@lines,
		'hideTitle' => 1,
		'hideURL'   => 1,

	);

	Slim::Buttons::Common::pushModeLeft($client, 'remotetrackinfo', \%params);
}

sub displayItemLink {
	my $client = shift;
	my $item = shift;

	my $url = hasLink($item);

	if (!$url) {
		$client->bumpRight();
		return;
	}

	# use PLUGIN.podcast mode to show the next url
	my %params = (
		'url'   => $url,
		'title' => $item->{'title'},
	);

	Slim::Buttons::Common::pushModeLeft($client, 'xmlbrowser', \%params);
}

sub playItem {
	my $client = shift;
	my $item   = shift;
	my $action = shift || 'play';

	# verbose debug
	#msg("Podcast playing item\n");
	#use Data::Dumper;
	#print Dumper($item);

	my $url   = $item->{'url'}  || $item->{'enclosure'}->{'url'};
	my $title = $item->{'name'} || $item->{'title'} || 'Unknown';
	my $type  = $item->{'type'} || $item->{'enclosure'}->{'type'} || '';

	if ($type eq 'audio') {
		
		Slim::Music::Info::setTitle( $url, $title );

		$client->execute([ 'playlist', $action, $url, $title ]);

		my $string; 
		if ($action eq 'add') {
			$string = 'ADDING_TO_PLAYLIST';
		} else {
			if (Slim::Player::Playlist::shuffle($client)) {
				$string = 'PLAYING_RANDOMLY_FROM';
			} else {
				$string = 'NOW_PLAYING_FROM';
			}
		}

		$client->showBriefly($client->string($string), $title);

	} elsif ($type eq 'playlist') {

		# URL is remote, load it asynchronously...
		# give user feedback while loading
		$client->block(
			$client->string( $client->param('header') || 'PODCAST_LOADING' ),
			$title || $url,
		);
		
		Slim::Formats::XML->getFeedAsync(
			\&gotPlaylist,
			\&gotError,
			{
				'client' => $client,
				'url'    => $url,
			},
		);

	} elsif ($item->{'enclosure'} && ($type eq 'audio' || Slim::Music::Info::typeFromSuffix($url) ne 'unk')) {
		
		Slim::Music::Info::setTitle( $url, $title );
		
		$client->execute([ 'playlist', $action, $url, $title ]);

	} else {

		$client->showBriefly($title, $client->string("PODCAST_NOTHING_TO_PLAY"));
	}
}

sub cliQuery {
	my ( $query, $feed, $request, $expires ) = @_;
	
	$::d_plugins && msg("XMLBrowser: cliQuery()\n");

	# check this is the correct query.
	if ($request->isNotQuery([[$query], ['items', 'playlist']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();
	
	# If the feed is already XML data (Podcast List), send it to handleFeed
	if ( ref $feed eq 'HASH' ) {
		_cliQuery_done( $feed, {
			'request' => $request,
			'url'     => $feed->{'url'},
			'query'   => $query,
			'expires' => $expires
		} );
		return;
	}

	Slim::Formats::XML->getFeedAsync(
		\&_cliQuery_done,
		\&_cliQuery_error,
		{
			'request' => $request,
			'url'     => $feed,
			'query'   => $query,
			'expires' => $expires
		}
	);
}

sub _cliQuery_done {
	my ( $feed, $params ) = @_;

	$::d_plugins && msg("XMLBrowser: _cliQuery_done()\n");

	my $request = $params->{'request'};
	my $query   = $params->{'query'};
	my $expires = $params->{'expires'};

	my $isItemQuery = my $isPlaylistCmd = 0;
	if ($request->isQuery([[$query], ['playlist']])) {
		$isPlaylistCmd = 1;
	}
	elsif ($request->isQuery([[$query], ['items']])) {
		$isItemQuery = 1;
	}

	# select the proper list of items
	my @index = split /\./, $request->getParam('item_id');
	
	my $subFeed = $feed;
	my @crumbIndex = ();
	if ( scalar @index > 0 ) {

		# descend to the selected item
		for my $i ( @index ) {
			$subFeed = $subFeed->{'items'}->[$i];

			push @crumbIndex, $i;
			
			# If the feed is another URL, fetch it and insert it into the
			# current cached feed
			if ( $subFeed->{'type'} ne 'audio' && defined $subFeed->{'url'} ) {
				Slim::Formats::XML->getFeedAsync(
					\&_cliQuerySubFeed_done,
					\&_cliQuery_error,
					{
						'url'          => $subFeed->{'url'},
						'parent'       => $feed,
						'parentURL'    => $params->{'parentURL'} || $params->{'url'},
						'currentIndex' => \@crumbIndex,
						'request'      => $request,
						'query'        => $query,
						'expires'      => $expires
					},
				);
				return;
			}

			# If the feed is an audio feed or Podcast enclosure, display the audio info
			if ( $isItemQuery && $subFeed->{'type'} eq 'audio' || $subFeed->{'enclosure'} ) {
				$request->addResult('id', join '.', @index);
				
				foreach my $data (keys %{$subFeed}) {
					if (ref($subFeed->{$data}) eq 'ARRAY') {
						if (scalar @{$subFeed->{$data}}) {
							$request->addResult('hasitems', scalar @{$subFeed->{$data}});
						}
					}
					elsif ($data =~ /enclosure/i && defined $subFeed->{$data}) {
						foreach my $enclosuredata (keys %{$subFeed->{$data}}) {
							if ($subFeed->{$data}->{$enclosuredata}) {
								$request->addResult($data . '_' . $enclosuredata, $subFeed->{$data}->{$enclosuredata});
							}
						}
					}
					elsif ($subFeed->{$data}) {
						$request->addResult($data, $subFeed->{$data});
					}
				}
			}
		}
	}

	if ($isPlaylistCmd) {
		$::d_plugins && msg("XMLBrowser: _cliQuery_done() - play an item\n");

		# get our parameters
		my $client = $request->client();
		my $method = $request->getParam('_method');

		if ($client && $method =~ /^(add|play|insert|load)$/i) {
			# single item
			if ((defined $subFeed->{'url'} || defined $subFeed->{'enclosure'})
				&& (defined $subFeed->{'name'} || defined $subFeed->{'title'})) {
	
				my $title = $subFeed->{'name'} || $subFeed->{'title'};
				my $url   = $subFeed->{'url'};
	
				# Podcast enclosures
				if ( my $enc = $subFeed->{'enclosure'} ) {
					$url = $enc->{'url'};
				}
	
				if ( $url ) {
					$::d_plugins && msg("XMLBrowser: $method $url\n");
				
					Slim::Music::Info::setTitle( $url, $title );
				
					$client->execute([ 'playlist', 'clear' ]) if ($method =~ /play|load/i);
					$client->execute([ 'playlist', $method, $url ]);
				}
			}
			
			# play all streams of an item
			else {
				my @urls;
				for my $item ( @{ $subFeed->{'items'} } ) {
					if ( $item->{'type'} eq 'audio' && $item->{'url'} ) {
						push @urls, $item->{'url'};
						Slim::Music::Info::setTitle( $item->{'url'}, $item->{'name'} || $item->{'title'} );
					}
					elsif ( $item->{'enclosure'} && $item->{'enclosure'}->{'url'} ) {
						push @urls, $item->{'enclosure'}->{'url'};
						Slim::Music::Info::setTitle( $item->{'url'}, $item->{'name'} || $item->{'title'} );
					}
				}
				
				if ( @urls ) {
					$::d_plugins && msgf("XMLBrowser: playing/adding all items:\n%s\n",
						join "\n", @urls
					);
					
					if ( $method =~ /play|load/i ) {
						$client->execute([ 'playlist', 'loadtracks', 'listref', \@urls ]);
					}
					else {
						$client->execute([ 'playlist', 'addtracks', 'listref', \@urls ]);
					}
				}
			}
		}
	}	

	elsif ($isItemQuery) {
		$::d_plugins && msg("XMLBrowser: _cliQuery_done() - get items\n");

		# get our parameters
		my $index    = $request->getParam('_index');
		my $quantity = $request->getParam('_quantity');
		my $search   = $request->getParam('search');
	
		# allow searching in the name field
		if ($search && @{$subFeed->{'items'}}) {
			my @found = ();
			my $i = 0;
			for my $item ( @{$subFeed->{'items'}} ) {
				if ($item->{'name'} =~ /$search/i || $item->{'title'} =~ /$search/i) {
					$item->{'_slim_id'} = $i;
					push @found, $item;
				}
				$i++;
			}
			
			$subFeed->{'items'} = \@found;
		}
	
		my $count = defined @{$subFeed->{'items'}} ? @{$subFeed->{'items'}} : 0;
		
		# only add item count if there are any items to add
		if ($count) {
			$request->addResult('count', $count);
		
			my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
		
			my $loopname = '@loop';
			my $cnt = 0;
			my $haveAudio = 0;
		
			if ($valid) {
				for my $item ( @{$subFeed->{'items'}}[$start..$end] ) {
					$request->addResultLoop($loopname, $cnt, 'id', join('.', @crumbIndex, defined $item->{'_slim_id'} ? $item->{'_slim_id'} : $start + $cnt));
	
					foreach my $data (keys %{$item}) {
						if (ref($item->{$data}) eq 'ARRAY') {
							if (scalar @{$item->{$data}}) {
								$request->addResultLoop($loopname, $cnt, 'hasitems', scalar @{$item->{$data}});
							}
						}
						elsif ($data =~ /enclosure/i && defined $item->{$data}) {
							foreach my $enclosuredata (keys %{$item->{$data}}) {
								if ($item->{$data}->{$enclosuredata}) {
									$request->addResultLoop($loopname, $cnt, $data . '_' . $enclosuredata, $item->{$data}->{$enclosuredata});
								}
							}
						}
						elsif ($item->{$data}) {
							$request->addResultLoop($loopname, $cnt, $data, $item->{$data});
						}
					}
	
					# Check if any of our items contain audio, so we can display an
					# 'All Songs' link
					if ( $item->{'type'} eq 'audio' || $item->{'enclosure'} ) {
						$haveAudio++;
					}
					
					$cnt++;
				}
			}
			
			$request->addResult('itemshaveaudio', $haveAudio) if ($haveAudio);
		}
	}
	
	$request->setStatusDone();
}


# Fetch a feed URL that is referenced within another feed.
# After fetching, insert the contents into the original feed
sub _cliQuerySubFeed_done {
	my ( $feed, $params ) = @_;
	
	# insert the sub-feed data into the original feed
	my $parent = $params->{'parent'};
	my $subFeed = $parent;
	for my $i ( @{ $params->{'currentIndex'} } ) {
		$subFeed = $subFeed->{'items'}->[$i];
	}
	$subFeed->{'items'} = $feed->{'items'};
	$subFeed->{'url'}   = undef;
	
	# re-cache the parsed XML to include the sub-feed
	my $cache = Slim::Utils::Cache->new();
	my $expires = 300;
	if ( my $data = $cache->get( $params->{'parentURL'} ) ) {
		if ( defined $data->{'_expires'} && $data->{'_expires'} > 0 ) {
			$expires = time - ( $data->{'_time'} + $data->{'_expires'} );
		}
	}
	$::d_plugins && msg("XMLBrowser: re-caching parsed XML for $expires seconds\n");
	$cache->set( $params->{'parentURL'} . '_parsedXML', $parent, $expires );
	
	_cliQuery_done( $parent, $params );
}

sub _cliQuery_error {
	my ( $err, $params ) = @_;
	
	my $request = $params->{'request'};
	my $url     = $params->{'url'};
	
	$::d_plugins && msg("Picks: error retrieving <$url>:\n");
	$::d_plugins && msg($err);
	
	$request->addResult("networkerror", 1);
	$request->addResult('count', 0);

	$request->setStatusDone();	
}

1;
