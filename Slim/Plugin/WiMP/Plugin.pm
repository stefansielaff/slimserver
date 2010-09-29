package Slim::Plugin::WiMP::Plugin;

# $Id:  $

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Plugin::WiMP::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.wimp',
	defaultLevel => 'DEBUG',
	description  => 'PLUGIN_WIMP_MODULE_NAME',
} );

sub initPlugin {
	my $class = shift;
	
	Slim::Player::ProtocolHandlers->registerHandler(
		wimp => 'Slim::Plugin::WiMP::ProtocolHandler'
	);
	
	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr/squeezenetwork\.com.*\/wimp\//, 
		sub { return $class->_pluginDataFor('icon'); }
	);

	$class->SUPER::initPlugin(
		feed   => Slim::Networking::SqueezeNetwork->url( '/api/wimp/v1/opml' ),
		tag    => 'wimp',
		menu   => 'music_services',
		weight => 35,
		is_app => 1,
	);
	
	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( wimp => (
		after => 'middle',
		func  => \&trackInfoMenu,
	) );
	
	if ( main::WEBUI ) {
		# Add a function to view trackinfo in the web
		Slim::Web::Pages->addPageFunction( 
			'plugins/wimp/trackinfo.html',
			sub {
				my $client = $_[0];
				
				my $url = Slim::Player::Playlist::url($client);
				
				Slim::Web::XMLBrowser->handleWebIndex( {
					client  => $client,
					feed    => Slim::Plugin::WiMP::ProtocolHandler->trackInfoURL( $client, $url ),
					path    => 'plugins/wimp/trackinfo.html',
					title   => 'WiMP Track Info',
					timeout => 35,
					args    => \@_
				} );
			},
		);
	}
}

sub getDisplayName {
	return 'PLUGIN_WIMP_MODULE_NAME';
}

# Don't add this item to any menu
sub playerMenu { }

1;