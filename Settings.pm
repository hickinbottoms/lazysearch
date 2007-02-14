# Web settings page handler for LazySearch2 plugin for SlimServer.
# Copyright © Stuart Hickinbottom 2004-2007

# This file is part of LazySearch2.
#
# LazySearch2 is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# LazySearch2 is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Foobar; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

# $Id$

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
