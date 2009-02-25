# Web settings page handler for LazySearch2 plugin for SqueezeCentre.
# Copyright © Stuart Hickinbottom 2004-2009

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
# along with LazySearch2; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

use strict;
use warnings;

package Plugins::LazySearch2::Settings;

use base qw(Slim::Web::Settings);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# A logger we will use to write plugin-specific messages.
my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.lazysearch2',
		'defaultLevel' => 'INFO',
		'description'  => 'PLUGIN_LAZYSEARCH2'
	}
);

# Access to preferences for this plugin.
my $myPrefs = preferences('plugin.lazysearch2');

sub new {
	my $class = shift;

	$class->SUPER::new;
}

sub name {
	return 'PLUGIN_LAZYSEARCH2';
}

sub page {
	return 'plugins/LazySearch2/settings/basic.html';
}

# Set up validation rules.
$myPrefs->setValidate(
	{ 'validator' => 'intlimit', 'low' => 2, 'high' => 9 },
	qw(pref_minlength_artist pref_minlength_album pref_minlength_genre pref_minlength_track pref_minlength_keyword)
);

sub handler {
	my ( $class, $client, $params ) = @_;

	# A list of all our plugin preferences (with the common prefix removed).
	my @prefs = qw(
	  pref_showhelp
	  pref_minlength_artist
	  pref_minlength_album
	  pref_minlength_genre
	  pref_minlength_track
	  pref_minlength_keyword
	  pref_leftdeletes
	  pref_hooksearchbutton
	  pref_keyword_artists_enabled
	  pref_keyword_albums_enabled
	  pref_keyword_tracks_enabled
	  pref_keyword_return_albumartists
	);

	# The subset of those preferences that force the database to be
	# relazified if they change.
	my @force_relazify_prefs = qw(
	  pref_keyword_artists_enabled
	  pref_keyword_albums_enabled
	  pref_keyword_tracks_enabled
	);

	if ( $params->{'saveSettings'} ) {
		$log->debug('Saving plugin preferences');

		# Determine whether a database relazification is necessary following
		# the change in preferences.
		my $force_relazify = 0;
		for my $relazify_pref (@force_relazify_prefs) {
			if ( $myPrefs->get($relazify_pref) ne $params->{$relazify_pref} ) {
				$log->debug("Preference '$relazify_pref' changed");
				$force_relazify = 1;
			}
		}

		# Now change the preferences from the ones posted through our
		# settings page.
		for my $pref (@prefs) {
			$myPrefs->set( $pref, $params->{$pref} );
		}

		# If we found earlier that any of the settings that affect our
		# database contents have been changed, then make sure we rebuild our
		# extra information in the database.
		if ($force_relazify) {
			$log->info(
				"Forcing relazification of the database due to settings changes"
			);
			Plugins::LazySearch2::Plugin::relazifyDatabase();
		}
	}

	if ( $params->{'pref_lazifynow'} ) {
		$log->debug('Lazify Now button pushed');
		Plugins::LazySearch2::Plugin::lazifyNow();
	}

	for my $pref (@prefs) {
		$params->{'prefs'}->{$pref} = $myPrefs->get($pref);
	}

	return $class->SUPER::handler( $client, $params );
}

1;

__END__
