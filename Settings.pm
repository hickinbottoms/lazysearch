# LazySearch2 Plugin for SlimServer
# Copyright © Stuart Hickinbottom 2004-2007
#
# $Id$
#
# This code is derived from code with the following copyright message:
#
# SlimServer Copyright (c) 2001-2006 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# Web settings page handler.

use strict;
use warnings;

package Plugins::LazySearch2::Settings;

use base qw(Slim::Web::Settings);
use Slim::Utils::Log;

# A logger we will use to write plugin-specific messages.
#@@TODO@@ - change default level to INFO
my $log = Slim::Utils::Log->addLogCategory({
		'category' => 'plugin.lazysearch2',
		'defaultLevel' => 'DEBUG',
		'description' => 'PLUGIN_LAZYSEARCH2'
	});

sub name {
	return 'PLUGIN_LAZYSEARCH2';
}

sub page {
	return 'plugins/LazySearch2/settings/basic.html';
}

#@@TODO@@ make sure we validate to ensure integers etc.

sub handler {
	my ($class, $client, $params) = @_;

	my @prefs = qw(
		showhelp
		minlength_artist
		minlength_album
		minlength_genre
		minlength_track
		minlength_keyword
		leftdeletes
		hooksearchbutton
		keyword_artists_enabled
		keyword_albums_enabled
		keyword_tracks_enabled
		keyword_return_albumartists
	);

	if ($params->{'saveSettings'}) {
		$log->debug('Saving plugin preferences');

		for my $pref (@prefs) {
			Slim::Utils::Prefs::set("plugin-LazySearch2-".$pref, $params->{$pref});
		}

	}

	if ($params->{'lazifynow'}) {
		$log->debug('Lazify Now button pushed');
		Plugins::LazySearch2::Plugin::lazifyNow();
	}

	for my $pref (@prefs) {
		$params->{'prefs'}->{$pref} = Slim::Utils::Prefs::get("plugin-LazySearch2-".$pref);
	}

	return $class->SUPER::handler($client, $params);
}

1;

__END__
