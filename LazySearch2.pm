# LazySearch2 plugin for SlimServer by Stuart Hickinbottom 2006
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

# This is a plugin to implement lazy searching using the Squeezebox/Transporter
# remote control.
#
# For further details see:
# http://hickinbottom.demon.co.uk/lazysearch

use strict;
use warnings;

package Plugins::LazySearch2;

use utf8;
use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Text;
use Slim::Utils::Timers;
use Time::HiRes;
use Text::Unidecode;

# Name of this plugin - used for various global things to prevent clashes with
# other plugins.
use constant PLUGIN_NAME => 'PLUGIN_LAZYSEARCH2';

# Name of the menu item that is expected to be added to the home menu.
use constant LAZYSEARCH_HOME_MENUITEM => 'LazySearch2';

# A special search_type value that indicates that it's actually for a keyword
# search rather than a normal database entity search.
use constant SEARCH_TYPE_KEYWORD => 'Keyword';

# Mode for main lazy search mode and lazy search menu.
use constant LAZYSEARCH_TOP_MODE           => 'PLUGIN_LAZYSEARCH2.topmode';
use constant LAZYSEARCH_CATEGORY_MENU_MODE => 'PLUGIN_LAZYSEARCH2.categorymenu';
use constant LAZYBROWSE_MODE               => 'PLUGIN_LAZYSEARCH2.browsemode';
use constant LAZYBROWSE_KEYWORD_MODE => 'PLUGIN_LAZYSEARCH2.keywordbrowse';

# Preference ranges and defaults.
use constant LAZYSEARCH_MINLENGTH_MIN             => 2;
use constant LAZYSEARCH_MINLENGTH_MAX             => 9;
use constant LAZYSEARCH_MINLENGTH_ARTIST_DEFAULT  => 3;
use constant LAZYSEARCH_MINLENGTH_ALBUM_DEFAULT   => 3;
use constant LAZYSEARCH_MINLENGTH_GENRE_DEFAULT   => 3;
use constant LAZYSEARCH_MINLENGTH_TRACK_DEFAULT   => 4;
use constant LAZYSEARCH_MINLENGTH_KEYWORD_DEFAULT => 4;
use constant LAZYSEARCH_LEFTDELETES_DEFAULT       => 1;
use constant LAZYSEARCH_HOOKSEARCHBUTTON_DEFAULT  => 1;
use constant LAZYSEARCH_ALLENTRIES_DEFAULT        => 1;
use constant LAZYSEARCH_KEYWORD_ARTISTS_DEFAULT   => 1;
use constant LAZYSEARCH_KEYWORD_ALBUMS_DEFAULT    => 1;
use constant LAZYSEARCH_KEYWORD_TRACKS_DEFAULT    => 1;

# Constants that control the background lazy search database encoding.
use constant LAZYSEARCH_ENCODE_MAX_QUANTA    => 0.4;
use constant LAZYSEARCH_INITIAL_LAZIFY_DELAY => 5;

# Special item IDs that are used to recognise non-result items in the
# search results list.
use constant RESULT_ENTRY_ID_ALL => -1;

# The character used to separate individual words of a keyword search
# string.
use constant KEYWORD_SEPARATOR_CHARACTER => ',';

# Export the version to the server (as a subversion keyword).
use vars qw($VERSION);
$VERSION = 'trunk-6.5-r@@REVISION@@';

# This hash-of-hashes contains state information on the current lazy search for
# each player. The first hash index is the player (eg $clientMode{$client}),
# and the second a 'parameter' for that player.
# The elements of the second hash are as follows:
#	search_type:	This is the item type being searched for, and can be one
#					of Track, Contributor, Album, Genre or Keyword.
#	text_col:		The column of the search_type row that holds the text that
#					will be shown on the player as the result of the search.
#	search_text:	The current search text (ie the number keys on the remote
#					control).
#	side:				Allows the search to be constrained to one side of
#						the pipe in the customsearch column or the other.
#						side=1 searches left, side=2 searches right, anything
#						else isn't specific.
#	search_performed:	Indicates whether a search has yet been performed
#						(and hence whether search_items has the search
#						results). It contains the search text at the time the
#						search was performed.
#	search_forced:		Whether the results are for a forced search (where
#						the user pressed SEARCH before a minimum-length
#						string was entered).
#	search_pending:		A Boolean flag indicating whether there is a search
#						scheduled to happen in a short time following the
#						change of the search_text.
#	all_entry:			This is the string to be used for the 'all' entry at
#						the end of the list. If this isn't defined then there
#						won't be an 'all' entry added.
#	select_col:			This is the 'field' that the find returns.
#	player_title:		Start of line1 player text when there are search
#						results.
#	player_title_empty:	The line1 text when no search has yet been performed.
#	enter_more_prompt:	The line2 prompt shown when there is insufficient
#						search text entered to perform the search.
#	min_search_length:	The minimum number of characters that must be entered
#						before the lazy search is performed.
#	onright:			Function reference to a method that enters a browse
#						mode on the item being displayed.
#	search_tracks:		Function reference to a method that will return all
#						the tracks corresponding to the found item (the item
#						is passed as a parameter to this method). This is used
#						to find the tracks that will be added/replaced in the
#						playlist when ADD/INSERT/PLAY is pressed.
my %clientMode = ();

# Hash of outstanding database objects that are to be lazy-encoded. This is
# present to allow a background task to work on them in chunks, preventing
# performance problems caused by the server going busy for a long time.
# The structure of the hash is as follows:
# 	type => { rs, source_attr, keyword_artist, keyword_album, keyword_track,
# 	          ids }
# Where:
# 	type is 'album', 'artist', 'genre' or 'track'.
#	rs is the DBIx ResultSet containing the items of that type that need to
#	  be lazified.
#	source_attr is the column name in the ResultSet that has the source
#	  attribute that will be lazified into the custom search.
#	keyword_artist, keyword_album, keyword_track are flags (0/1) that indicate
#	  whether those items are lazified into the customsearch field to support
#	  custom searches.
# 	ids is a list (array) of IDs to process.
my %encodeQueues = ();

# Flag to protect against multiple initialisation or shutdown
my $initialised = 0;

# Flag to indicate whether we're currently applying 'lazification' to the
# database. Used to detect and warn the user of this when entering
# lazy search mode while this is in progress.
my $lazifyingDatabase = 0;

# Map which is used to quickly translate the button pushes captured by our
# mode back into the numbers on those keys.
my %numberScrollMap = (
	'numberScroll_0' => '0',
	'numberScroll_1' => '1',
	'numberScroll_2' => '2',
	'numberScroll_3' => '3',
	'numberScroll_4' => '4',
	'numberScroll_5' => '5',
	'numberScroll_6' => '6',
	'numberScroll_7' => '7',
	'numberScroll_8' => '8',
	'numberScroll_9' => '9',
);

# Below are functions that are part of the standard SlimServer plugin
# interface.

# Main mode of this plugin; offers the artist/album/genre/song browse options
sub setMode {
	my $client = shift;
	my $method = shift || '';

	# Handle request to exit our mode.
	if ( $method eq 'pop' ) {
		leaveMode($client);

		# Pop the current mode off the mode stack and restore the previous one
		Slim::Buttons::Common::popMode($client);
		return;
	}

	# The menu items shown depend on whether keyword search is enabled or
	# not.
	my @topMenuItems = (qw({ARTISTS} {ALBUMS} {GENRES} {SONGS}));
	if ( keywordSearchEnabled() ) {
		push @topMenuItems, '{KEYWORD_MENU_ITEM}';
	}

	# Use INPUT.Choice to display the top-level search menu choices.
	my %params = (

		# The header (first line) to display whilst in this mode.
		header => '{LINE1_BROWSE} {count}',

		# A reference to the list of items to display.
		listRef => \@topMenuItems,

		# A unique name for this mode that won't actually get displayed
		# anywhere.
		modeName => LAZYSEARCH_CATEGORY_MENU_MODE,

		# An anonymous function that is called every time the user presses the
		# RIGHT button.
		onRight => sub {
			my ( $client, $item ) = @_;

			# Search term initially empty.
			$clientMode{$client}{search_text}      = '';
			$clientMode{$client}{search_items}     = ();
			$clientMode{$client}{search_performed} = '';
			$clientMode{$client}{search_pending}   = 0;

			if ( $item eq '{ARTISTS}' ) {
				$clientMode{$client}{search_type}  = 'Contributor';
				$clientMode{$client}{side}         = 0;
				$clientMode{$client}{text_col}     = 'name';
				$clientMode{$client}{all_entry}    = '{ALL_ARTISTS}';
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_ARTISTS}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_ARTISTS_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_ARTISTS';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get(
					'plugin-lazysearch2-minlength-artist');
				$clientMode{$client}{onright}       = \&rightIntoArtist;
				$clientMode{$client}{search_tracks} = \&searchTracksForArtist;
				setSearchBrowseMode( $client, $item, 0 );
			} elsif ( $item eq '{ALBUMS}' ) {
				$clientMode{$client}{search_type}  = 'Album';
				$clientMode{$client}{side}         = 0;
				$clientMode{$client}{text_col}     = 'title';
				$clientMode{$client}{all_entry}    = '{ALL_ALBUMS}';
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_ALBUMS}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_ALBUMS_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_ALBUMS';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-album');
				$clientMode{$client}{onright}       = \&rightIntoAlbum;
				$clientMode{$client}{search_tracks} = \&searchTracksForAlbum;
				setSearchBrowseMode( $client, $item, 0 );
			} elsif ( $item eq '{GENRES}' ) {
				$clientMode{$client}{search_type}  = 'Genre';
				$clientMode{$client}{side}         = 0;
				$clientMode{$client}{text_col}     = 'name';
				$clientMode{$client}{all_entry}    = undef;
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_GENRES}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_GENRES_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_GENRES';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-genre');
				$clientMode{$client}{onright}       = \&rightIntoGenre;
				$clientMode{$client}{search_tracks} = \&searchTracksForGenre;
				setSearchBrowseMode( $client, $item, 0 );
			} elsif ( $item eq '{SONGS}' ) {
				$clientMode{$client}{search_type}  = 'Track';
				$clientMode{$client}{side}         = 1;
				$clientMode{$client}{text_col}     = 'title';
				$clientMode{$client}{all_entry}    = '{ALL_SONGS}';
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_TRACKS}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_TRACKS_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_TRACKS';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-track');
				$clientMode{$client}{onright}       = \&rightIntoTrack;
				$clientMode{$client}{search_tracks} = \&searchTracksForTrack;
				setSearchBrowseMode( $client, $item, 0 );
			} elsif ( $item eq '{KEYWORD_MENU_ITEM}' ) {
				$clientMode{$client}{search_type}  = SEARCH_TYPE_KEYWORD;
				$clientMode{$client}{side}         = 2;
				$clientMode{$client}{text_col}     = undef;
				$clientMode{$client}{all_entry}    = undef;
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_ARTISTS}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_KEYWORDS_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_KEYWORDS';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get(
					'plugin-lazysearch2-minlength-keyword');
				$clientMode{$client}{onright}       = \&keywordOnRightHandler;
				$clientMode{$client}{search_tracks} = undef;
				setSearchBrowseMode( $client, $item, 0 );
			}

			# If rescan is in progress then warn the user.
			if ( $lazifyingDatabase || Slim::Music::Import->stillScanning() ) {
				$::d_plugins
				  && Slim::Utils::Misc::msg(
					"LazySearch2: Entering search while scan in progress\n");
				if ( $client->linesPerScreen == 1 ) {
					$client->showBriefly(
						{
							'line1' => $client->doubleString('SCAN_IN_PROGRESS')
						}
					);
				} else {
					$client->showBriefly(
						{ 'line1' => string('SCAN_IN_PROGRESS') } );
				}
			}
		},

		# These are all menu items and so have a right-arrow overlay
		overlayRef => sub {
			return [ undef, Slim::Display::Display::symbol('rightarrow') ];
		},
	);

	# Use our INPUT.Choice-derived mode to show the menu and let it do all the
	# hard work of displaying the list, moving it up and down, etc, etc.
	if ( $method eq 'push' ) {
		Slim::Buttons::Common::pushModeLeft( $client,
			LAZYSEARCH_CATEGORY_MENU_MODE, \%params );
	} else {
		Slim::Buttons::Common::pushMode( $client, LAZYSEARCH_CATEGORY_MENU_MODE,
			\%params );
		$client->update();
	}
}

# Return a result set that contains all tracks for a given artist, for when
# PLAY/INSERT/ADD is pressed on one of those items.
sub searchTracksForArtist($) {
	my $id = shift;
	return Slim::Schema->search( 'ContributorTrack',
		{ 'me.contributor' => $id } )->search_related(
		'track', undef,
		{
			'order_by' =>
			  'track.album, track.disc, track.tracknum, track.titlesort'
		}
		)->all;
}

# Return a result set that contains all tracks for a given album, for when
# PLAY/INSERT/ADD is pressed on one of those items.
sub searchTracksForAlbum($) {
	my $id = shift;
	return Slim::Schema->search(
		'track',
		{ 'album'    => $id },
		{ 'order_by' => 'me.disc, me.tracknum, me.titlesort' }
	)->all;
}

# Return a result set that contains all tracks for a given genre, for when
# PLAY/INSERT/ADD is pressed on one of those items.
sub searchTracksForGenre($) {
	my $id = shift;
	return Slim::Schema->search( 'GenreTrack', { 'me.genre' => $id } )
	  ->search_related(
		'track', undef,
		{
			'order_by' =>
			  'track.album, track.disc, track.tracknum, track.titlesort'
		}
	  )->all;
}

# Return a result set that contain the given track, for when PLAY/INSERT/ADD is
# pressed on one of those items.
sub searchTracksForTrack($) {
	my $id = shift;
	return Slim::Schema->find( 'Track', $id );
}

# Browse into a particular artist.
sub rightIntoArtist($$) {
	my $client = shift;
	my $item   = shift;

	# Browse albums by this artist.
	Slim::Buttons::Common::pushModeLeft(
		$client,
		'browsedb',
		{
			'hierarchy'    => 'contributor,album,track',
			'level'        => 1,
			'findCriteria' => { 'contributor.id' => $item->{'value'} },
		}
	);
}

# Browse into a particular album.
sub rightIntoAlbum($$) {
	my $client = shift;
	my $item   = shift;

	# Browse tracks for this album.
	Slim::Buttons::Common::pushModeLeft(
		$client,
		'browsedb',
		{
			'hierarchy'    => 'album,track',
			'level'        => 1,
			'findCriteria' => { 'album.id' => $item->{'value'} },
		}
	);

}

# Browse into a particular genre.
sub rightIntoGenre($$) {
	my $client = shift;
	my $item   = shift;

	# Browse artists by this genre.
	Slim::Buttons::Common::pushModeLeft(
		$client,
		'browsedb',
		{
			'hierarchy'    => 'genre,contributor,album,track',
			'level'        => 1,
			'findCriteria' => { 'genre.id' => $item->{'value'} },
		}
	);
}

# Browse into a particular track.
sub rightIntoTrack($$) {
	my $client = shift;
	my $item   = shift;

	# Push into the trackinfo mode for this one track.
	my $track = Slim::Schema->rs('Track')->find( $item->{'value'} );
	Slim::Buttons::Common::pushModeLeft( $client, 'trackinfo',
		{ 'track' => $track->url } );
}

# Function called when leaving our top-level lazy search menu mode. We use this
# to track whether or not the user is within the lazy search mode for a
# particular player.
sub leaveMode {
	my $client = shift;

	# Clear the search results to save a little memory.
	$clientMode{$client}{search_items} = ();
}

# There are no functions in this mode as the main mode (the top-level menu) is
# all handled by the INPUT.Choice mode.
sub getFunctions {
	return {};
}

# Return the name of this plugin; this goes on the server setting plugin
# page, for example.
sub getDisplayName {
	return PLUGIN_NAME;
}

# Set up this plugin when it's inserted or the server started. Adds our hooks
# for database encoding and makes our customised mode that lets us grab and
# process extra buttons.
sub initPlugin() {
	return if $initialised;    # don't need to do it twice

	$::d_plugins
	  && Slim::Utils::Misc::msg("LazySearch2: Initialising $VERSION\n");

	# Remember we're now initialised. This prevents multiple-initialisation,
	# which may otherwise cause trouble with duplicate hooks or modes.
	$initialised = 1;

	# Make sure the preferences are set to something sensible before we call
	# on them later.
	checkDefaults();

	# Subscribe so that we are notified when the database has been rescanned;
	# we use this so that we can apply lazification.
	Slim::Control::Request::subscribe( \&Plugins::LazySearch2::scanDoneCallback,
		[ ['rescan'], ['done'] ] );

	# Top-level menu mode. We register a custom INPUT.Choice mode so that
	# we can detect when we're in it (for SEARCH button toggle).
	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: Making custom INPUT.Choice-derived modes\n");
	Slim::Buttons::Common::addMode( LAZYSEARCH_TOP_MODE, undef, \&setMode );
	Slim::Buttons::Common::addMode(
		LAZYSEARCH_CATEGORY_MENU_MODE,
		Slim::Buttons::Input::Choice::getFunctions(),
		\&Slim::Buttons::Input::Choice::setMode
	);

	# Out input map for the new categories menu mode, based on thd default map
	# contents for INPUT.Choice.
	my %categoryInputMap = (
		'arrow_left'  => 'exit_left',
		'arrow_right' => 'exit_right',
		'play'        => 'play',
		'add'         => 'add',
		'stop'        => 'passback',
		'pause'       => 'passback',
	);
	for my $buttonPressMode (qw{repeat hold hold_release single double}) {
		$categoryInputMap{ 'play.' . $buttonPressMode }   = 'dead';
		$categoryInputMap{ 'add.' . $buttonPressMode }    = 'dead';
		$categoryInputMap{ 'search.' . $buttonPressMode } = 'dead';
		$categoryInputMap{ 'stop.' . $buttonPressMode }   = 'passback';
		$categoryInputMap{ 'pause.' . $buttonPressMode }  = 'passback';
	}
	Slim::Hardware::IR::addModeDefaultMapping( LAZYSEARCH_CATEGORY_MENU_MODE,
		\%categoryInputMap );

	# Make a customised version of the INPUT.Choice mode so that we can grab
	# the numbers (INPUT.Choice will normally use these to scroll through
	# 'numberScroll').
	my %chFunctions = %{ Slim::Buttons::Input::Choice::getFunctions() };
	$chFunctions{'numberScroll'} = \&lazyKeyHandler;
	$chFunctions{'play'}         = \&onPlayHandler;
	$chFunctions{'addSingle'}    = \&onAddHandler;
	$chFunctions{'addHold'}      = \&onInsertHandler;
	$chFunctions{'leftSingle'}   = \&onDelCharHandler;
	$chFunctions{'leftHold'}     = \&onDelAllHandler;
	$chFunctions{'forceSearch'}  = \&lazyForceSearch;
	$chFunctions{'zeroButton'}   = \&zeroButtonHandler;
	$chFunctions{'keywordSep'}   = \&keywordSepHandler;
	Slim::Buttons::Common::addMode( LAZYBROWSE_MODE, \%chFunctions,
		\&Slim::Buttons::Input::Choice::setMode );

	# Our input map for the new lazy browse mode, based on the default map
	# contents for INPUT.Choice.
	my %lazyInputMap = (
		'arrow_left'      => 'leftSingle',
		'arrow_left.hold' => 'leftHold',
		'arrow_right'     => 'exit_right',
		'play'            => 'play',
		'pause.single'    => 'pause',
		'pause.hold'      => 'stop',
		'add.single'      => 'addSingle',
		'add.hold'        => 'addHold',
		'search'          => 'forceSearch',
		'0.single'        => 'zeroButton',
		'0.hold'          => 'keywordSep',
		'0'               => 'dead',
		'0.repeat'        => 'dead',
		'0.hold_release'  => 'dead',
		'0.double'        => 'dead',
	);
	for my $buttonPressMode (qw{repeat hold hold_release single double}) {
		$lazyInputMap{ 'play.' . $buttonPressMode }   = 'dead';
		$lazyInputMap{ 'search.' . $buttonPressMode } = 'dead';
	}
	Slim::Hardware::IR::addModeDefaultMapping( LAZYBROWSE_MODE,
		\%lazyInputMap );

	# The mode that is used to show keyword results once the user has entered
	# one of the returned categories.
	my %chFunctions2 = %{ Slim::Buttons::Input::Choice::getFunctions() };
	$chFunctions2{'play'}        = \&onPlayHandler;
	$chFunctions2{'addSingle'}   = \&onAddHandler;
	$chFunctions2{'addHold'}     = \&onInsertHandler;
	$chFunctions2{'forceSearch'} = \&lazyForceSearch;
	Slim::Buttons::Common::addMode( LAZYBROWSE_KEYWORD_MODE, \%chFunctions2,
		\&Slim::Buttons::Input::Choice::setMode );

	# Our input map for the new keyword browse mode, based on the default map
	# contents for INPUT.Choice.
	my %keywordInputMap = (
		'arrow_left'   => 'exit_left',
		'arrow_right'  => 'exit_right',
		'play'         => 'play',
		'pause.single' => 'pause',
		'pause.hold'   => 'stop',
		'add.single'   => 'addSingle',
		'add.hold'     => 'addHold',
		'search'       => 'forceSearch',
	);
	for my $buttonPressMode (qw{repeat hold hold_release single double}) {
		$keywordInputMap{ 'play.' . $buttonPressMode }   = 'dead';
		$keywordInputMap{ 'search.' . $buttonPressMode } = 'dead';
	}
	Slim::Hardware::IR::addModeDefaultMapping( LAZYBROWSE_KEYWORD_MODE,
		\%keywordInputMap );

	# Intercept the 'search' button to take us to our top-level menu.
	Slim::Buttons::Common::setFunction( 'search', \&lazyOnSearch );

	# Schedule a lazification to ensure that the database is lazified. This
	# is useful because the user might shut down the server during the scan
	# and we would otherwise have a part filled database that couldn't be
	# lazy searched.
	Slim::Utils::Timers::setTimer( undef,
		Time::HiRes::time() + LAZYSEARCH_INITIAL_LAZIFY_DELAY,
		\&scanDoneCallback );

	$::d_plugins
	  && Slim::Utils::Misc::msg("LazySearch2: Initialisation completed\n");
}

sub shutdownPlugin() {
	return if !$initialised;    # don't need to do it twice

	$::d_plugins && Slim::Utils::Misc::msg("LazySearch2: Shutting down\n");

	# Remove the subscription we'd previously registered
	Slim::Control::Request::unsubscribe(
		\&Plugins::LazySearch2::scanDoneCallback );

	# @@TODO@@
	# Do we need to remove our top-level mode?

	# We're no longer initialised.
	$initialised = 0;
}

# Return information on this plugin's settings. The web interface will then
# present those on the 'server settings->plugins' page.
sub setupGroup {
	my %setupGroup = (
		PrefOrder => [
			'plugin-lazysearch2-minlength-artist',
			'plugin-lazysearch2-minlength-album',
			'plugin-lazysearch2-minlength-genre',
			'plugin-lazysearch2-minlength-track',
			'plugin-lazysearch2-minlength-keyword',
			'plugin-lazysearch2-leftdeletes',
			'plugin-lazysearch2-hooksearchbutton',
			'plugin-lazysearch2-keyword-artists-enabled',
			'plugin-lazysearch2-keyword-albums-enabled',
			'plugin-lazysearch2-keyword-tracks-enabled',
			'plugin-lazysearch2-lazifynow'
		],
		GroupHead         => string('SETUP_GROUP_PLUGIN_LAZYSEARCH2'),
		GroupDesc         => string('SETUP_GROUP_PLUGIN_LAZYSEARCH2_DESC'),
		GroupLine         => 1,
		GroupSub          => 1,
		Suppress_PrefSub  => 1,
		Suppress_PrefLine => 1,
	);

	my %setupPrefs = (
		'plugin-lazysearch2-minlength-artist' => {
			'validate'     => \&Slim::Utils::Validate::isInt,
			'validateArgs' =>
			  [ LAZYSEARCH_MINLENGTH_MIN, LAZYSEARCH_MINLENGTH_MAX ],
			'PrefHead' => string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST'),
			'PrefDesc' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_DESC'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHANGE'),
		},
		'plugin-lazysearch2-minlength-album' => {
			'validate'     => \&Slim::Utils::Validate::isInt,
			'validateArgs' =>
			  [ LAZYSEARCH_MINLENGTH_MIN, LAZYSEARCH_MINLENGTH_MAX ],
			'PrefHead'   => string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHANGE'),
		},
		'plugin-lazysearch2-minlength-genre' => {
			'validate'     => \&Slim::Utils::Validate::isInt,
			'validateArgs' =>
			  [ LAZYSEARCH_MINLENGTH_MIN, LAZYSEARCH_MINLENGTH_MAX ],
			'PrefHead'   => string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHANGE'),
		},
		'plugin-lazysearch2-minlength-track' => {
			'validate'     => \&Slim::Utils::Validate::isInt,
			'validateArgs' =>
			  [ LAZYSEARCH_MINLENGTH_MIN, LAZYSEARCH_MINLENGTH_MAX ],
			'PrefHead'   => string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHANGE'),
		},
		'plugin-lazysearch2-minlength-keyword' => {
			'validate'     => \&Slim::Utils::Validate::isInt,
			'validateArgs' =>
			  [ LAZYSEARCH_MINLENGTH_MIN, LAZYSEARCH_MINLENGTH_MAX ],
			'PrefHead' => string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_KEYWORD'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_KEYWORD_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_KEYWORD_CHANGE'),
		},
		'plugin-lazysearch2-leftdeletes' => {
			'validate'   => \&Slim::Utils::Validate::trueFalse,
			'PrefHead'   => string('SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES'),
			'PrefDesc'   => string('SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_DESC'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHANGE'),
			'options' => {
				'1' => string('SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_1'),
				'0' => string('SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_0')
			},
		},
		'plugin-lazysearch2-hooksearchbutton' => {
			'validate' => \&Slim::Utils::Validate::trueFalse,
			'PrefHead' => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON'),
			'PrefDesc' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_DESC'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHANGE'),
			'options' => {
				'1' => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_1'),
				'0' => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_0')
			},
		},
		'plugin-lazysearch2-keyword-artists-enabled' => {
			'validate' => \&Slim::Utils::Validate::trueFalse,
			'PrefHead' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ARTISTS_HEAD'),
			'PrefDesc' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_OPTIONS_DESC'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ARTISTS_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ARTISTS_CHANGE'),
			'options' => {
				'1' => string('ENABLED'),
				'0' => string('DISABLED')
			},
		},
		'plugin-lazysearch2-keyword-albums-enabled' => {
			'validate' => \&Slim::Utils::Validate::trueFalse,
			'PrefHead' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ALBUMS_HEAD'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ALBUMS_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ALBUMS_CHANGE'),
			'options' => {
				'1' => string('ENABLED'),
				'0' => string('DISABLED')
			},
		},
		'plugin-lazysearch2-keyword-tracks-enabled' => {
			'validate' => \&Slim::Utils::Validate::trueFalse,
			'PrefHead' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_TRACKS_HEAD'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_TRACKS_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_TRACKS_CHANGE'),
			'options' => {
				'1' => string('ENABLED'),
				'0' => string('DISABLED')
			},
		},
		'plugin-lazysearch2-lazifynow' => {
			'validate'    => \&Slim::Utils::Validate::acceptAll,
			'PrefHead'    => string('SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW'),
			'PrefDesc'    => string('SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_DESC'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_CHANGE'),
			'inputTemplate' => 'setup_input_submit.html',
			'ChangeButton'  =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_BUTTON'),
			'onChange' => sub {
				if ( !$lazifyingDatabase ) {
					$::d_plugins
					  && Slim::Utils::Misc::msg(
						"LazySearch2: Manual lazification requested\n");
					lazifyDatabase();
				}
			},
			'dontSet'   => 1,
			'changeMsg' => '',
		},
	);

	return ( \%setupGroup, \%setupPrefs );
}

# Below are functions that are specific to this plugin.

# Sub-mode, allowing entry search and browsing within a search category. This
# uses our custom mode to combine standard INPUT.Choice functionality with
# our handlers that catch the number keys (which would normally scroll the
# choices), and the play/add/insert buttons that we need so that we can
# manipulate the playlist as appropriate. This mode is driven through the
# clientMode hash (see its description at the head of this file).
sub setSearchBrowseMode {
	my $client = shift;
	my $method = shift;
	my $silent = shift;

	# Handle request to exit our mode.
	if ( $method && ( $method eq 'pop' ) ) {

		# Pop the current mode off the mode stack and restore the previous one
		Slim::Buttons::Common::popMode($client);
		return;
	}

	# The items for the list are those returned by the search (if there was
	# one), or the defined 'enter more' prompt if not.
	my $itemsRef;
	my $headerString;
	my $searchText = $clientMode{$client}{search_text};
	my $searchType = $clientMode{$client}{search_type};
	if ( ( length $searchText ) > 0 ) {
		$headerString = $clientMode{$client}{player_title} . ' ';
		if ( $searchType eq SEARCH_TYPE_KEYWORD ) {
			$headerString .= '\'' . keywordMatchText( $client, 0 ) . '\'';
		} else {
			$headerString .= '\'' . $searchText . '\'';
		}
	} else {
		$headerString = $clientMode{$client}{player_title_empty};
	}

	# If we've actually performed a search then the title also includes
	# the item number/total items as per normal browse modes.
	if ( length( $clientMode{$client}{search_performed} ) > 0 ) {
		$itemsRef = $clientMode{$client}{search_items};
		$headerString .= ' {count}';
	} else {
		@$itemsRef =
		  ( $client->string( $clientMode{$client}{enter_more_prompt} ) );
	}

	# Parameters for our INPUT.Choice-derived mode.
	my %params = (

		# Text title on list1.
		header => $headerString,

		# A reference to the list of items to display.
		listRef => $itemsRef,

		# The function to extract the title of each item.
		name => \&lazyGetText,

		# Name for this mode.
		modeName => "LAZYBROWSE_MODE:$searchType:$searchText",

		# Catch and handle the RIGHT button.
		onRight => \&lazyOnRight,

		# A handler that manages play/add/insert (differentiated by the
		# last parameter).
		onPlay => sub {
			my ( $client, $item, $addMode ) = @_;

			$::d_plugins
			  && Slim::Utils::Misc::msg(
"LazySearch2: lazyOnPlay called for normal category search result\n"
			  );

			# Start playing the item selected (in the correct mode - play, add
			# or insert).
			lazyOnPlay( $client, $item, $addMode );
		},

		# These are all browsable items and so have a right-arrow overlay,
		# but if the list is empty then there is never an overlay.
		overlayRef => sub {
			my ( $client, $item ) = @_;
			my $listRef = $client->param('listRef');
			my $l1      = undef;
			my $l2      = undef;

			# If we've a pending search then we have an overlay on line 1.
			if ( $clientMode{$client}{search_pending} ) {
				$l1 = '*';
			}

			# See if there might be an overlay on line 2.
			if (   ( length( $clientMode{$client}{search_performed} ) > 0 )
				&& ( scalar(@$listRef) != 0 ) )
			{

				# 'All' items don't have an arrow; the others do.
				if ( defined( $item->{result_set} )
					|| ( $item->{value} != RESULT_ENTRY_ID_ALL ) )
				{
					$l2 = Slim::Display::Display::symbol('rightarrow');
				}
			}

			return [ $l1, $l2 ];
		},
	);

	$::d_plugins
	  && Slim::Utils::Misc::msg(
"LazySearch2: setSearchBrowseMode called with mode \'LAZYBROWSE_MODE:$searchType:$searchText\'\n"
	  );

	# Use the new mode defined by INPUT.Choice and let it do all the hard work
	# of displaying the list, moving it up and down, etc, etc. We have a silent
	# version that doesn't scroll the mode in, which is used for subsequent
	# narrowing of the search (which will be replacing an already-displayed
	# version of this mode).
	if ($silent) {
		Slim::Buttons::Common::pushMode( $client, LAZYBROWSE_MODE, \%params );
	} else {
		Slim::Buttons::Common::pushModeLeft( $client, LAZYBROWSE_MODE,
			\%params );
	}
}

# Subroutine to extract the text to show for the browse/search. Most of this
# is stock here, we just need to defer to a specific function stored in the
# clientMode hash to get the actual text, as that differs for each item class.
sub lazyGetText {
	my ( $client, $item ) = @_;

	if ( length( $clientMode{$client}{search_performed} ) == 0 ) {
		return $client->string( $clientMode{$client}{enter_more_prompt} );
	} else {
		my $listRef = $client->param('listRef');
		if ( scalar(@$listRef) == 0 ) {
			return $client->string('EMPTY');
		} else {
			return $item->get_column( $clientMode{$client}{text_col} );
		}
	}
}

# Make the SEARCH button force a search in the lazy search entry, consistent
# with the behaviour of the standard SEARCH button.
sub lazyForceSearch {
	my $client = shift;

	# If keyword searching a force search is allowed if there are any 'short'
	# keywords present (and at least one character).
	# If not keyword searching, a force search is allowed if a search string
	# has been entered of at least one character and a search has not yet been
	# performed.
	my $searchText = $clientMode{$client}{search_text};
	$::d_plugins
	  && Slim::Utils::Misc::msg(
"LazySearch2: lazyForceSearch - search_text=\'$searchText\' search_performed=\'"
		  . $clientMode{$client}{search_performed}
		  . "\'\n" );
	if (
		(
			( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD )
			&& ( minKeywordLength($searchText) <
				$clientMode{$client}{min_search_length} )
			&& ( minKeywordLength($searchText) > 1 )
			&& ( keywordMatchText( $client, 0, $searchText ) ne
				$clientMode{$client}{search_performed} )
		)
		|| (   ( $clientMode{$client}{search_type} ne SEARCH_TYPE_KEYWORD )
			&& ( length( $clientMode{$client}{search_performed} ) == 0 )
			&& ( length($searchText) > 1 ) )
	  )
	{
		$::d_plugins
		  && Slim::Utils::Misc::msg("LazySearch2: Forcing short text search\n");
		cancelPendingSearch($client);
		onFindTimer( 'dummy', $client, 1 );
	} else {

		# Cancel any pending timer.
		cancelPendingSearch($client);

		# Re-enter the category lazy search menu
		enterCategoryMenu($client);
	}
}

# Called when the user presses SEARCH. This allows toggling between the
# lazy search menu and the standard player search menu. A preference allows
# the SEARCH button to decide whether it's going to enter the standard or
# lazy search modes when it's currently in neither.
sub lazyOnSearch {
	my $client       = shift;
	my $mode         = Slim::Buttons::Common::mode($client);
	my $inLazySearch = ( $mode eq LAZYSEARCH_TOP_MODE )
	  || ( $mode eq LAZYSEARCH_CATEGORY_MENU_MODE )
	  || ( $mode eq LAZYBROWSE_MODE )
	  || 0;
	my $inSearch = 0;    #@@TODO@@@
	my $gotoLazy;

	if ( !$initialised ) {

		# We never intercept SEARCH if the plugin isn't initialised.
		$gotoLazy = 0;
	} elsif ( Slim::Utils::Prefs::get('plugin-lazysearch2-hooksearchbutton') ) {

		# Normal operation - enter lazy search as long as we're not already
		# in it, in which case we go to original search (allows double-search
		# to get back to the old mode).
		$gotoLazy = !$inLazySearch || 0;
	} elsif ($inSearch) {

		# If in original search mode we always enter lazy search.
		$gotoLazy = 1;
	} else {

		# Go into the standard search.
		$gotoLazy = 0;
	}

	if ($gotoLazy) {
		enterCategoryMenu($client);
	} else {

		# Into the normal search menu.
		Slim::Buttons::Home::jumpToMenu( $client, "SEARCH" );
	}
}

# Enter the top-level category menu for lazy search
sub enterCategoryMenu {
	my $client = shift;

	# @@TODO@@
	# This doesn't seem to work properly - it doesn't seem to set the top
	# menu to the lazy item prior to jumping in. It seems to work,
	# but when existing the mode it doesn't exit to the lazy top
	# level item
	Slim::Buttons::Common::setMode( $client, 'home' );
	Slim::Buttons::Home::jump( $client, LAZYSEARCH_HOME_MENUITEM );
	Slim::Buttons::Common::pushMode( $client, LAZYSEARCH_TOP_MODE );
}

# Subroutine to perform the 'browse into' RIGHT button handler for lazy search
# results. The browse mode just differs by the method used to start browsing
# for each type, and that's stored in the clientMode hash.
sub lazyOnRight {
	my ( $client, $item ) = @_;

	# If the list is empty then don't push into browse mode
	my $listRef = $client->param('listRef');
	if ( scalar(@$listRef) == 0 ) {
		$client->bumpRight();
	} else {

		# Only allow right if we've performed a search.
		if (   ( length( $clientMode{$client}{search_performed} ) > 0 )
			&& ( $item->{value} != RESULT_ENTRY_ID_ALL ) )
		{

			# Cancel any pending timer.
			cancelPendingSearch($client);

			# Push into the item details, using database browse.
			# The method executed is stored in the hash.
			my $onRightFunction = $clientMode{$client}{onright};
			return &$onRightFunction( $client, $item );
		} else {
			$client->bumpRight();
		}
	}
}

# Handle press of play/add/insert when on an item returned from the search.
# addMode=0 : play
# addMode=1 : add
# addMode=2 : insert
sub lazyOnPlay {
	my ( $client, $item, $addMode ) = @_;

	$::d_plugins && Slim::Utils::Misc::msg("LazySearch2: lazyOnPlay called\n");

	# Function that will return all tracks for the given item - used for
	# handling both individual entries and ALL entries.
	my $searchTracksFunction = $clientMode{$client}{search_tracks};

	# Cancel any pending timer.
	cancelPendingSearch($client);

	# If no list loaded (eg search returned nothing), or
	# user has not entered enough text yet, then ignore the
	# command.
	my $listRef = $client->param('listRef');
	if ( length( $clientMode{$client}{search_performed} ) == 0 ) {
		return;
	}

	# If we're on the keyword hierarchy then the function is dependent on the
	# level of the item we're on.
	if ( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD ) {
		my $level = $item->{'level'};
		if ( $level == 1 ) {
			$::d_plugins
			  && Slim::Utils::Misc::msg(
				"LazySearch2: lazyOnPlay called for keyword artist\n");
			$searchTracksFunction = \&searchTracksForArtist;
		} elsif ( $level == 2 ) {
			$::d_plugins
			  && Slim::Utils::Misc::msg(
				"LazySearch2: lazyOnPlay called for keyword album\n");
			$searchTracksFunction = \&searchTracksForAlbum;
		} else {
			$::d_plugins
			  && Slim::Utils::Misc::msg(
				"LazySearch2: lazyOnPlay called for keyword track\n");
			$searchTracksFunction = \&searchTracksForTrack;
		}
	}

	my $id = $item->{'value'};
	$::d_plugins
	  && Slim::Utils::Misc::msg(
"LazySearch2: PLAY pressed on '$clientMode{$client}{search_type}' search results (id $id), addMode=$addMode\n"
	  );
	my ( $line1, $line2, $msg, $cmd );

	if ( $addMode == 1 ) {
		$msg = "ADDING_TO_PLAYLIST";
		$cmd = "addtracks";
	} elsif ( $addMode == 2 ) {
		$msg = "INSERT_TO_PLAYLIST";
		$cmd = "inserttracks";
	} else {
		$msg =
		  Slim::Player::Playlist::shuffle($client)
		  ? "PLAYING_RANDOMLY_FROM"
		  : "NOW_PLAYING_FROM";
		$cmd = "loadtracks";
	}

	if ( $client->linesPerScreen == 1 ) {
		$line1 = $client->doubleString($msg);
	} else {
		$line1 = $client->string($msg);
		if ( $id != RESULT_ENTRY_ID_ALL ) {
			$line2 = $item->{'name'};
		} else {
			my $strToken = $item->{'name'};
			$strToken =~ s/(\{|\})//g;
			$line2 = $client->string($strToken);
		}
	}
	$client->showBriefly(
		{
			'line1' => $line1,
			'line2' => $line2
		}
	);

	# The playlist of tracks that we'll then action with the appropriate
	# command. This is built up for both an individual item or for ALL items.
	my @playItems = ();

	# Handle 'ALL' entries specially
	if ( $id != RESULT_ENTRY_ID_ALL ) {
		@playItems = &$searchTracksFunction($id);
	} else {

		$::d_plugins
		  && Slim::Utils::Misc::msg(
			"LazySearch2: All for '$clientMode{$client}{search_type}' chosen\n"
		  );

		for $item (@$listRef) {

			# Don't try to search for the 'all items' entry.
			next if $item->{value} == -1;

			# Find the tracks by this artist.
			my @tracks = &$searchTracksFunction( $item->{value} );

			# Add these tracks to the list we're building up for the playlist.
			push @playItems, @tracks;
		}
	}

	# Now we've built the list of track items, play them.
	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: About to '$cmd' " . scalar @playItems . " items\n" );
	$client->execute( [ 'playlist', $cmd, 'listref', \@playItems ] );

	# Not sure why, but we don't need to start the play
	# here - seems something by default is grabbing and
	# processing the button. Strange...
}

# Pick up each number button press and add it to the current lazy search text,
# then re-search using that text.
sub lazyKeyHandler {
	my ( $client, $method ) = @_;

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	# Map the scroll number (the method invoked by the INPUT.Choice button
	# the lazy browse mode is based on), to a real number character.
	my $numberKey = $numberScrollMap{$method};

#@@TODO: REMOVEME@@
$::d_plugins && Slim::Utils::Misc::msg( "LazySearch2: lazyKeyHandler method='$method' numberKey='$numberKey'\n");

	# We ignore zero here since we need to differentiate between a normal
	# zero button press and a zero button press-and-hold. That is done by
	# handling the two types of zero button press in keywordSepHandler and
	# zeroButtonHandler.
	if ($numberKey ne '0') {
		addLazySearchCharacter($client, $item, $numberKey);
	}
}

# Adds a single character to the current search defined for that player.
sub addLazySearchCharacter {
	my ($client, $item, $character) = @_;

	# Add this character to our search string.
	$clientMode{$client}{search_text} .= $character;

	# Cancel any pending search and schedule another, so search happens
	# n seconds after the last button press.
	addPendingSearch($client);

	# Update the display.
	updateLazyEntry( $client, $item );
}

# Adds a keyword separator character to the search string, if the player
# is currently in a keyword search mode.
sub keywordSepHandler {
	my ( $client, $method) = @_;

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	# Whether this is a keyword search.
	my $keywordSearch =
	  ( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD );

	if ($keywordSearch) {
		# Add the separator character to the search string.
		addLazySearchCharacter($client, $item, KEYWORD_SEPARATOR_CHARACTER);
	} else {
		# We're not in a keyword search so handle it as the normal zero
		# character.
		zeroButtonHandler($client, $method);
	}

$::d_plugins && Slim::Utils::Misc::msg( "LazySearch2: in keywordSepHandler\n");
}

# Adds a zero to the search string for the player. This is separate to all
# the other number handlers because it's the only way we can tell the
# difference between a normal press and a press-n-hold.
sub zeroButtonHandler {
	my ( $client, $method, $x, $y ) = @_; #@@REMOVE $x

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

$::d_plugins && Slim::Utils::Misc::msg( "LazySearch2: in zeroButtonHandler\n");

	# Simply add a zero to the end.
	addLazySearchCharacter($client, $item, '0');
}


# Update the display during lazy search entry. This is used on change of the
# lazy search text (ie add character or delete character).
sub updateLazyEntry {
	my ( $client, $item ) = @_;

	# Pop back into the mode to get the display updated. We ask for a 'silent'
	# update, which prevents the mode scrolling back in again.
	Slim::Buttons::Common::popMode($client);
	setSearchBrowseMode( $client, $item, 1 );
	$client->update();

	# In one-line display modes show a clue to the user, as he won't see the
	# result of the search for some time and won't otherwise get any visual
	# feedback.
	if ( $client->linesPerScreen == 1 ) {
		my $line =
		    $client->string('SHOWBRIEFLY_DISPLAY') . ' \''
		  . $clientMode{$client}{search_text} . '\'';
		$client->showBriefly( { 'line1' => $line } );
	}
}

# Schedule a new search to occur for the specified client.
sub addPendingSearch($) {
	my $client = shift;

	# Schedule a timer. Any existing one is cancelled first as we only allow
	# one outstanding one for this player.
	cancelPendingSearch($client);

	Slim::Utils::Timers::setTimer( $client,
		Time::HiRes::time() + Slim::Utils::Prefs::get("displaytexttimeout"),
		\&onFindTimer, $client );

	# Flag that this client has a pending search (this causes the overlay
	# hint). We only do that if we've put in the minimum required string
	# length.
	if ( ( length $clientMode{$client}{search_text} ) >=
		$clientMode{$client}{min_search_length} )
	{
		$clientMode{$client}{search_pending} = 1;
	}
}

# Remove any outstanding lazy search timer. This is used when either leaving
# the search mode altogether, or when another key has been entered by the user
# (as a new later search will be scheduled instead).
sub cancelPendingSearch($) {
	my $client = shift;

	my $timerName = PLUGIN_NAME . Slim::Player::Client::id($client);

	# This seems tolerant of timers that don't exist, so no need to make sure
	# we actually have one scheduled.
	Slim::Utils::Timers::killOneTimer( $client, \&onFindTimer );
}

# Actually perform the lazy search and go back into the lazy search mode to
# get the results displayed.
sub onFindTimer() {
	my $timerName   = shift;
	my $client      = shift;
	my $forceSearch = shift || 0;

	# Remember whether this search was forced.
	$clientMode{$client}{search_forced} = $forceSearch;

	# Whether this is a keyword search.
	my $keywordSearch =
	  ( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD );

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	# No longer a pending search for this client.
	$clientMode{$client}{search_pending} = 0;

	# Perform lazy search, if a minimum length of search text is provided.
	my $itemsRef = $clientMode{$client}{search_items};
	if (
		(
			!$keywordSearch
			&& ( length $clientMode{$client}{search_text} ) >=
			$clientMode{$client}{min_search_length}
		)
		|| (
			$keywordSearch
			&& ( maxKeywordLength( $clientMode{$client}{search_text} ) >=
				$clientMode{$client}{min_search_length} )
		)
		|| $forceSearch
	  )
	{
		# The search text is shown with word separators for keyword searches.
		my $searchText = $clientMode{$client}{search_text};
		my $searchType = $clientMode{$client}{search_type};
		if ( $searchType eq SEARCH_TYPE_KEYWORD ) {
			$searchText = keywordMatchText( $client, 0 , $searchText);
		}

		$client->showBriefly(
			{
				'line1' => sprintf(
					$client->string('LINE1_SEARCHING'),
					$searchText
				)
			}
		);

		# The way the search is performed is different between keyword and
		# non-keyword searches.
		my $searchPerformedText = $clientMode{$client}{search_text};
		if ($keywordSearch) {
			performTimedKeywordSearch( $client, $forceSearch );
			$searchPerformedText =
			  keywordMatchText( $client, 1, $searchPerformedText );
		} else {
			performTimedItemSearch($client);
		}

		# Remember a version of the search text used. The contents isn't too
		# important, but whether any short keywords are included is used to
		# know whether a force search has already been performed (in which
		# case another force will pop out of the search mode altogether).
		$clientMode{$client}{search_performed} = $searchPerformedText;

		# Re-enter the search mode to get the display updated.
		Slim::Buttons::Common::popMode($client);
		setSearchBrowseMode( $client, $item, 1 );
		$client->update();
	} else {
		$clientMode{$client}{search_performed} = '';
	}
}

# Find the longest keyword within a multiple-keyword search term.
sub maxKeywordLength($) {
	my $keywordString = shift;
	my @keywords      = split( KEYWORD_SEPARATOR_CHARACTER, $keywordString );
	my $maxLength     = 0;
	foreach my $keyword (@keywords) {
		my $keywordLength = length($keyword);
		if ( $keywordLength > $maxLength ) {
			$maxLength = $keywordLength;
		}
	}

	return $maxLength;
}

# Find the shortest keyword within a multiple-keyword search term.
sub minKeywordLength($) {
	my $keywordString = shift;
	my @keywords      = split( KEYWORD_SEPARATOR_CHARACTER, $keywordString );
	my $minLength     = -1;
	foreach my $keyword (@keywords) {
		my $keywordLength = length($keyword);
		if ( ( $minLength == -1 ) || ( $keywordLength < $minLength ) ) {
			$minLength = $keywordLength;
		}
	}

	return $minLength;
}

# Perform the lazy search for a single item type (artist etc). This will be
# called from the search timer for non-keyword searches.
sub performTimedItemSearch($) {
	my $client = shift;

	my $searchResults =
	  Slim::Schema->resultset( $clientMode{$client}{search_type} )->search_like(
		{
			customsearch => buildFind(
				$clientMode{$client}{search_text},
				$clientMode{$client}{side}
			)
		},
		{
			columns => [ 'id', "$clientMode{$client}{text_col}" ],
			order_by => $clientMode{$client}{text_col}
		}
	  );

	# Each element of the listRef will be a hash with keys name and value.
	# This is true for artists, albums and tracks.
	my @searchItems = ();
	while ( my $searchItem = $searchResults->next ) {
		my $text = $searchItem->get_column( $clientMode{$client}{text_col} );
		my $id   = $searchItem->id;
		push @searchItems, { name => $text, value => $id };
	}

	# If there are multiple results, show the 'all X' choice.
	if ( ( scalar(@searchItems) > 1 )
		&& defined( $clientMode{$client}{all_entry} ) )
	{
		push @searchItems,
		  {
			name  => $clientMode{$client}{all_entry},
			value => RESULT_ENTRY_ID_ALL
		  };
	}

	# Make these items available to the results-listing mode.
	$clientMode{$client}{search_items} = \@searchItems;
}

# Perform the lazy search for the keywords. This performs an AND query with
# each entered query matching somewhere within the custom search text (the
# database lazification will have put all candidate text within the
# customsearch column).
sub performTimedKeywordSearch($$) {
	my $client      = shift;
	my $forceSearch = shift;

	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: About to perform timed keyword search\n");

	# Perform the search. The search will always be an unconstrained one
	# because it is at the top level (we've not yet pushed into contributor
	# or album to constrain the results).
	my $searchItems =
	  doKeywordSearch( $client, $clientMode{$client}{search_text},
		$forceSearch, 1, undef, undef );

	# Make these items available to the results-listing mode.
	$clientMode{$client}{search_items}             = $searchItems;
	$clientMode{$client}{lazysearch_keyword_level} = 1;
	delete $clientMode{$client}{lazysearch_keyword_contributor};
	delete $clientMode{$client}{lazysearch_keyword_album};
}

# Actually perform the keyword search. This supports all levels of searching
# and will filter on contributor or album as requested.
sub doKeywordSearch($$$$$$) {
	my $client                = shift;
	my $searchText            = shift;
	my $forceSearch           = shift;
	my $level                 = shift;
	my $contributorConstraint = shift;
	my $albumConstraint       = shift;
	my @items;

	$::d_plugins
	  && Slim::Utils::Misc::msg(
"LazySearch2: doing keyword search, level=$level, contributorConstraint=$contributorConstraint, albumConstraint=$albumConstraint\n"
	  );

	# Keyword searches are separate 'keywords' separated by a space (lazy
	# encoded). We split those out here.
	my @keywordParts = split( KEYWORD_SEPARATOR_CHARACTER, $searchText );

	# Build the WHERE clause for the query, containing multiple AND clauses
	# and LIKE searches.
	my @andClause = ();
	foreach my $keyword (@keywordParts) {

		# We don't include zero-length keywords.
		next if ( length($keyword) == 0 );

		# We don't include short keywords unless the search is forced.
		next
		  if ( !$forceSearch
			&& ( length($keyword) < $clientMode{$client}{min_search_length} ) );

		# Otherwise, here's the search term for this one keyword.
		push @andClause, 'me.customsearch';
		push @andClause,
		  { 'like', buildFind( $keyword, $clientMode{$client}{side} ) };
	}

	# Bail out here if we've not found any keywords we're interested
	# in searching. This can happen because the outer minimum length is
	# based on the whole string, not the maximum individual keyword.
	return if ( @andClause == 0 );

	# Perform the search, depending on the level.
	my $textColumn;
	my $results;
	if ( $level == 1 ) {
		$results =
		  Slim::Schema->resultset('Track')->search( { -and => [@andClause] },
			{ order_by => 'namesort', distinct => 1 } )
		  ->search_related('contributorTracks')->search_related('contributor');
		$textColumn = 'name';

	} elsif ( $level == 2 ) {

		$results = Slim::Schema->resultset('Track')->search(
			{
				-and => [
					@andClause,
					'contributorTracks.contributor' =>
					  { '=', $contributorConstraint }
				]
			},
			{
				order_by => 'titlesort',
				distinct => 1,
				join     => 'contributorTracks'
			}
		)->search_related('album');
		$textColumn = 'title';

	} elsif ( $level == 3 ) {
		$results = Slim::Schema->resultset('Track')->search(
			{
				-and => [
					@andClause,
					'contributorTracks.contributor' =>
					  { '=', $contributorConstraint },
					'album' => { '=', $albumConstraint }
				]
			},
			{
				join     => 'contributorTracks',
				order_by => 'disc,tracknum,titlesort'
			}
		);
		$textColumn = 'title';
	}

	# Build up the item array.
	while ( my $item = $results->next ) {
		push @items,
		  {
			name  => $item->get_column($textColumn),
			value => $item->id,
			level => $level
		  };
	}

	return \@items;
}

# Construct the search terms. This takes into account the 'search substring'
# preference to build an appropriate array. Additionally, it can split separate
# keywords (separated by a space encoded as '0'), to build an AND search.
# An optional flag can be passed to constrain the search to either the left (1)
# or the right (2) hand-side of the customsearch value.
sub buildFind($) {
	my $searchText      = shift;
	my $side            = shift || 0;
	my $searchSubstring = ( Slim::Utils::Prefs::get('searchSubString') );
	my $searchReturn;

	if ($searchSubstring) {
		$searchReturn = '%' . $searchText . '%';
	} else {

		# Search for start of words only. The lazy encoded version in the
		# database has a encoded space on the front so that the first word
		# isn't a special case here.
		$searchReturn = '%' . lazyEncode(' ') . $searchText . '%';
	}

	# Constrain for one side or the other, if specified.
	$searchReturn .= '|%' if $side == 1;    # Left-hand side
	$searchReturn = ( '%|' . $searchReturn ) if $side == 2;    # Right-hand side

	return $searchReturn;
}

# Call the play/insert/add handler (passing the parameter to differentiate
# which function is actually needed).
sub onPlayHandler {
	my ( $client, $method ) = @_;
	my $onAdd = $client->param('onPlay');

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	&$onAdd( $client, $item, 0 );
}

# Call the play/insert/add handler (passing the parameter to differentiate
# which function is actually needed).
sub onAddHandler {
	my ( $client, $method ) = @_;
	my $onAdd = $client->param('onPlay');

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	&$onAdd( $client, $item, 1 );
}

# Call the play/insert/add handler (passing the parameter to differentiate
# which function is actually needed).
sub onInsertHandler {
	my ( $client, $method ) = @_;
	my $onAdd = $client->param('onPlay');

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	&$onAdd( $client, $item, 2 );
}

# Remove a single character from the search text. If this drops below the
# minimum the user is given the same prompts that he gets when he's entered
# less than the minimum search characters.
sub onDelCharHandler {
	my ( $client, $method ) = @_;

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	my $currentText = $clientMode{$client}{search_text};
	if ( ( length($currentText) > 0 )
		&& Slim::Utils::Prefs::get('plugin-lazysearch2-leftdeletes') )
	{

		# Remove the right-most character from the string.
		$clientMode{$client}{search_text} = substr( $currentText, 0, -1 );

		# 'cancel' a previous search if the length of the search text now
		# falls below the minimum.
		if ( ( length $clientMode{$client}{search_text} ) <
			$clientMode{$client}{min_search_length} )
		{
			$clientMode{$client}{search_performed} = '';
		}

		# Cancel any pending search and schedule another, so search happens
		# n seconds after the last button press.
		addPendingSearch($client);

		# Update the display.
		updateLazyEntry( $client, $item );
	} else {

		# Clear the search results to save a little memory.
		$clientMode{$client}{search_items} = ();

		# Prevent any pending search timer from performing a search once
		# we've left this mode.
		cancelPendingSearch($client);

		# Search string is empty, so pop out.
		Slim::Buttons::Common::popModeRight($client);
	}
}

# Clear the current search and reset to the state you get into when no search
# text has yet been entered.
sub onDelAllHandler {
	my ( $client, $method ) = @_;

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	my $currentText = $clientMode{$client}{search_text};
	if ( length($currentText) > 0 ) {

		# Reset the current search text.
		$clientMode{$client}{search_text} = '';

		# 'Cancel' any search that may have already been performed.
		$clientMode{$client}{search_performed} = '';

		# Update the display.
		updateLazyEntry( $client, $item );
	}
}

# Called during initialisation, this makes sure that the plugin preferences
# stored are sensible. This has the effect of adding them the first time this
# plugin is activated and removing the need to check they're defined in each
# case of reading them.
sub checkDefaults {
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-minlength-artist') )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-minlength-artist',
			LAZYSEARCH_MINLENGTH_ARTIST_DEFAULT
		);
	}
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-minlength-album') )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-minlength-album',
			LAZYSEARCH_MINLENGTH_ALBUM_DEFAULT
		);
	}
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-minlength-genre') )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-minlength-genre',
			LAZYSEARCH_MINLENGTH_GENRE_DEFAULT
		);
	}
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-minlength-track') )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-minlength-track',
			LAZYSEARCH_MINLENGTH_TRACK_DEFAULT
		);
	}
	if (
		!Slim::Utils::Prefs::isDefined('plugin-lazysearch2-minlength-keyword') )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-minlength-keyword',
			LAZYSEARCH_MINLENGTH_KEYWORD_DEFAULT
		);
	}
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-leftdeletes') ) {
		Slim::Utils::Prefs::set( 'plugin-lazysearch2-leftdeletes',
			LAZYSEARCH_LEFTDELETES_DEFAULT );
	}
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-hooksearchbutton') )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-hooksearchbutton',
			LAZYSEARCH_HOOKSEARCHBUTTON_DEFAULT
		);
	}
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-allentries') ) {
		Slim::Utils::Prefs::set( 'plugin-lazysearch2-allentries',
			LAZYSEARCH_ALLENTRIES_DEFAULT );
	}
	if (
		!Slim::Utils::Prefs::isDefined(
			'plugin-lazysearch2-keyword-artists-enabled')
	  )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-keyword-artists-enabled',
			LAZYSEARCH_KEYWORD_ARTISTS_DEFAULT
		);
	}
	if (
		!Slim::Utils::Prefs::isDefined(
			'plugin-lazysearch2-keyword-albums-enabled')
	  )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-keyword-albums-enabled',
			LAZYSEARCH_KEYWORD_ALBUMS_DEFAULT
		);
	}
	if (
		!Slim::Utils::Prefs::isDefined(
			'plugin-lazysearch2-keyword-tracks-enabled')
	  )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-keyword-tracks-enabled',
			LAZYSEARCH_KEYWORD_TRACKS_DEFAULT
		);
	}
}

# This is called by SlimServer when a scan has finished. We use this to kick
# off lazification of the database once it's been populated with all music
# information.
sub scanDoneCallback {

	$::d_plugins
	  && Slim::Utils::Misc::msg(
"LazySearch2: Received notification of end of rescan - lazifying database\n"
	  );
	lazifyDatabase();
}

# This function is called when the music database scan has finished. It
# identifies each artist, track and album that has not yet been encoded into
# lazy form and schedules a SlimServer background task to encode them.
sub lazifyDatabase {

	# Make sure the encode queue is empty.
	%encodeQueues = ();

	# Convert the albums table.
	lazifyDatabaseType( 'Album', 'title', 0, 0, 0 );

	# Convert the artists (contributors) table.
	lazifyDatabaseType( 'Contributor', 'name', 0, 0, 0 );

	# Convert the genres table.
	lazifyDatabaseType( 'Genre', 'name', 0, 0, 0 );

	# Convert the songs (tracks) table.
	lazifyDatabaseType( 'Track', 'title', 1, 1, 1 );

	# If there are any items to encode then initialise a background task that
	# will do that work in chunks.
	if ( scalar keys %encodeQueues ) {
		$::d_plugins
		  && Slim::Utils::Misc::msg(
			"LazySearch2: Scheduling backround lazification\n");
		Slim::Utils::Scheduler::add_task( \&encodeTask );
		$lazifyingDatabase = 1;
	} else {
		$::d_plugins
		  && Slim::Utils::Misc::msg(
"LazySearch2: No object types require lazification - no task scheduled\n"
		  );
	}
}

# Return a lazy-encoded search column value; the original 'search' version
# is passed in.
sub lazifyColumn {
	my $in = shift;
	my $out;

	# Lazify the search value; if it was NULL we produce an empty string so it
	# stops being found by our "IS NULL" SQL filter.
	if ( defined($in) ) {
		$out = lazyEncode( ' ' . $in );
	} else {
		$out = '';
	}

	return $out;
}

# This function examines the database for a specific 'object' type (artist,
# album or track), and looks for those which have not yet been lazy-encoded.
# Those it finds are added to a global hash that is later worked through from
# the background task.
sub lazifyDatabaseType {
	my $type                  = shift;
	my $sourceAttr            = shift;
	my $considerKeywordArtist = shift;
	my $considerKeywordAlbum  = shift;
	my $considerKeywordTrack  = shift;

	# Include keywords in the lazified version if the caller asked for it and
	# the user preference says they want it.
	my $includeKeywordArtist = $considerKeywordArtist
	  && Slim::Utils::Prefs::get('plugin-lazysearch2-keyword-artists-enabled');
	my $includeKeywordAlbum = $considerKeywordAlbum
	  && Slim::Utils::Prefs::get('plugin-lazysearch2-keyword-albums-enabled');
	my $includeKeywordTrack = $considerKeywordTrack
	  && Slim::Utils::Prefs::get('plugin-lazysearch2-keyword-tracks-enabled');

	# If adding keywords for album titles then we need to join to the album
	# table, to.
	my $extraJoins;
	$extraJoins = qw/ album / if $includeKeywordAlbum;

	# The query to find items to lazify takes into account keyword columns
	# in case that column was previously lazified before keywords were
	# introduced.
	my $whereClause;
	if (   $considerKeywordArtist
		|| $considerKeywordAlbum
		|| $considerKeywordTrack )
	{
		$whereClause = {
			-or => [
				'me.customsearch' => { 'not like', '%|%' },
				'me.customsearch' => undef
			]
		};
	} else {
		$whereClause = { 'me.customsearch' => undef };
	}

	# Find all entries that are not yet converted.
	my $rs = Slim::Schema->resultset($type)->search(
		$whereClause,
		{
			columns  => [ 'id', $sourceAttr, 'me.customsearch' ],
			join     => $extraJoins,
			prefetch => $extraJoins
		}
	);
	my $rsCount = $rs->count;

	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: Lazify type=$type, " . $rsCount . " items to lazify\n" );

	# Store the unlazified item IDs; later, we'll work on these in chunks from
	# within a task.
	if ( $rsCount > 0 ) {
		my %typeHash = (
			rs             => $rs,
			source_attr    => $sourceAttr,
			keyword_artist => $includeKeywordArtist,
			keyword_album  => $includeKeywordAlbum,
			keyword_track  => $includeKeywordTrack,
		);
		$encodeQueues{$type} = \%typeHash;
	}
}

# This task function is periodically called by SlimServer when it is 'idle'.
# It works through the IDs of the objects that require encoding. They are
# encoded in chunks taking a maximum amount of time to keep the server and
# players responsive. This function returns 0 when the task has finished, and
# 1 when there is more work to do and this function should be called again.
sub encodeTask {

	# As protection from two encodes going on simultaneously, if we detect that
	# a scan is in progress we cancel the whole encode task.
	if ( Slim::Music::Import->stillScanning() ) {
		$::d_plugins
		  && Slim::Utils::Misc::msg(
"LazySearch2: Detected a rescan while database scan in progress - cancelling lazy encoding\n"
		  );
		%encodeQueues = ();

		return 0;
	}

	# Get a single type hash from the encode queue. It doesn't matter on the
	# order they come out of the hash.
	my $type          = ( keys %encodeQueues )[0];
	my $typeHashRef   = $encodeQueues{$type};
	my %typeHash      = %$typeHashRef;
	my $rs            = $typeHash{rs};
	my $sourceAttr    = $typeHash{source_attr};
	my $keywordArtist = $typeHash{keyword_artist};
	my $keywordAlbum  = $typeHash{keyword_album};
	my $keywordTrack  = $typeHash{keyword_track};

	$::d_plugins
	  && Slim::Utils::Misc::msg( 'LazySearch2: EncodeTask - '
		  . $rs->count
		  . " $type"
		  . "s remaining\n" );

	# Go through and encode each of the identified IDs. To maintain performance
	# we will bail out if this takes more than a defined time slice.

	my $rowsDone  = 0;
	my $startTime = Time::HiRes::time();
	my $obj;
	do {

		# Get the next row from the resultset.
		$obj = $rs->next;
		if ($obj) {

			# Update the search text for this one row and write it back to the
			# database.
			my $customSearch = lazifyColumn( $obj->get_column($sourceAttr) );

			# If keyword searching is enabled then add keywords.
			if ( $keywordArtist || $keywordAlbum || $keywordTrack ) {
				my $encodedArtist = '';
				my $encodedAlbum  = '';
				my $encodedTrack  = '';

				if ($keywordTrack) {
					$encodedTrack =
					  lazifyColumn( $obj->get_column($sourceAttr) );
				}

				if ($keywordArtist) {
					my $contributors = $obj->contributors;
					while ( my $contributor = $contributors->next ) {
						$encodedArtist .= lazifyColumn( $contributor->name );
					}
				}

				if ($keywordAlbum) {
					$encodedAlbum = lazifyColumn( $obj->album->title );
				}

				# Add this to the custom search column.
				$customSearch .= "|$encodedTrack$encodedAlbum$encodedArtist";
			}

			# Get the custom search added to the database.
			$obj->set_column( 'customsearch', $customSearch );
			$obj->update;

			$rowsDone++;
		}
	  } while ( $obj
		&& ( ( Time::HiRes::time() - $startTime ) <
			LAZYSEARCH_ENCODE_MAX_QUANTA ) );

	my $endTime = Time::HiRes::time();

	# Speedometer
	my $speed = 0;
	if ( $endTime != $startTime ) {
		$speed = int( $rowsDone / ( $endTime - $startTime ) );
	}
	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: Lazifier running at $speed $type" . "s/sec\n" );

	# If we've exhausted the ids for this type then remove this type from the
	# hash. If there are any left, however, we'll leave those in for the task
	# next time.
	if ( !defined($obj) ) {
		delete $encodeQueues{$type};
		$::d_plugins
		  && Slim::Utils::Misc::msg("LazySearch2: Exhaused IDs for $type\n");
	}

	# Find if there there is more work to do, and if so request that this task
	# is rescheduled.
	my $rescheduleTask;
	if ( scalar keys %encodeQueues ) {
		$rescheduleTask = 1;
	} else {
		$::d_plugins
		  && Slim::Utils::Misc::msg("LazySearch2: Lazification completed\n");

		$rescheduleTask = 0;

		# Make sure our work gets persisted.
		Slim::Schema->forceCommit;

		# Clear the global flag indicating the task is in progress.
		$lazifyingDatabase = 0;
	}

	return $rescheduleTask;
}

# Convert a search string to a lazy-entry encoded search string. This includes
# both the original search term and a lazy-encoded version. Later, when
# searching, both are tried. The original search text is kept in upper-case
# and the lazy version is encoded as digits - the latter is because both the
# original and lazy encoded version is searched in case the user bothers to
# put the search string in properly and this minimises the chance of erroneous
# matching. This single line tr is what lazification really boils down to -
# the rest of this plugin is just the skeleton to hang it off.
#
# called:
#   string to encode
sub lazyEncode($) {
	my $in_string = shift;
	my $out_string;

	# There are a few aims to the following process - understanding them
	# will explain why it's not just a simple 'tr'...
	#  1. there are a lot of accented characters and I didn't want to have
	#     to list them all (I'd probably miss some). Hence, unidecode is used
	#     to turn them back into non-accented versions. That's fine for
	#     searching purposes since those non-accented versions are never
	#     displayed.
	#  2. To save listing every upper and lower-case character we turn the
	#     character to upper case - from that point on we only have to expect
	#     upper case characters in the string.
	#  3. We ignore punctuation (except spaces - see later), since the user
	#     cannot easily search for it with the remote control. So we want to
	#     treat "I'VE" as "IVE", "DON'T" as "DONT" and "RADIO #1" as "RADIO 1"
	#     etc. Note that this can introduce runs of spaces - eg "1 - 1" would
	#     become "1   1", so we instead encode spaces as X's before we drop
	#     the punctuation, leaving us with "1XX1".
	#  4. We want to remove runs of multiple spaces - they might have existed
	#     in the tags in the first place, but the user might not spot it and
	#     so would only enter a single space in the query. Also, they might
	#     have been introduced through the above discarding of punctuation,
	#     so in the "1 - 1" case we'd be left with "1XX1", so we turn any
	#     multiple X's into single 0's (the lazy encoding of spaces). So,
	#     we correctly end up with "101" as the lazy encoding.

	# This translates each searchable character into the number of the key that
	# shares that letter on the remote. Thus, this tells us what keys the user
	# will enter if he doesn't bother to multi-tap to get at the later
	# characters. Note that space maps to zero.
	# We do all this on an upper case version, since upper case is all the user
	# can enter through the remote control.
	$out_string = uc unidecode($in_string);
	$out_string =~
tr/ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890 /222333444555666777788899991234567890X/;

	# Now, if there's any punctuation left in we remove that to aid searching.
	# We do that by calling the SlimServer method that transforms all
	# punctuation to spaces, then remove those spaces (since the original
	# spaces are temporarily turned to X's.
	if ($out_string ne '0') {
		$out_string = Slim::Utils::Text::ignorePunct($out_string);
		$out_string =~ s/ //go;

		# Finally, turn any X's back into spaces, collapse them down to a single
		# space, then turn those spaces to their correct lazy encoding.
		$out_string =~ s/X+/0/go;
	}

	return $out_string;
}

# Determines whether keyword searching is enabled. It's enabled if at least one
# of the keyword search categories is enabled.
sub keywordSearchEnabled {
	return Slim::Utils::Prefs::get('plugin-lazysearch2-keyword-artists-enabled')
	  || Slim::Utils::Prefs::get('plugin-lazysearch2-keyword-albums-enabled')
	  || Slim::Utils::Prefs::get('plugin-lazysearch2-keyword-tracks-enabled');
}

# Handler when RIGHT is pressed on the top-level keyword search results mode.
# This pushes into a browse mode that constrains the search results.
sub keywordOnRightHandler {
	my ( $client, $item ) = @_;

	# If the list is empty then don't push into browse mode
	my $listRef = $client->param('listRef');
	if ( scalar(@$listRef) == 0 ) {
		$client->bumpRight();
	} else {

		# Only allow right if we've performed a search.
		if (   ( length( $clientMode{$client}{search_performed} ) > 0 )
			&& ( $item->{value} != RESULT_ENTRY_ID_ALL ) )
		{
			my $name                  = $item->{name};
			my $value                 = $item->{value};
			my $level                 = $item->{level};
			my $contributorConstraint =
			  $clientMode{$client}{contributor_constraint};
			my $albumConstraint = $clientMode{$client}{album_constraint};
			$::d_plugins
			  && Slim::Utils::Misc::msg(
"LazySearch2: level=$level keyword results OnRight, value=$value, name=\'$name\', contributorConstraint=$contributorConstraint, albumConstraint=$albumConstraint\n"
			  );

			# Cancel any pending timer.
			cancelPendingSearch($client);

			# Track details are a special case.
			if ( $level < 3 ) {
				my $line1BrowseText;
				if ( $level == 1 ) {

					# Current item provides contributor constraint.
					$contributorConstraint = $value;
					$line1BrowseText       = '{LINE1_BROWSE_ALBUMS}';
				} elsif ( $level == 2 ) {

					# Current item provides album constraint.
					$albumConstraint = $value;
					$line1BrowseText = '{LINE1_BROWSE_TRACKS}';
				}

				# Remember these consraints in the mode.
				$clientMode{$client}{contributor_constraint} =
				  $contributorConstraint;
				$clientMode{$client}{album_constraint} = $albumConstraint;

				# The current unique text to make the mode unique.
				my $searchText  = $clientMode{$client}{search_text};
				my $forceSearch = $clientMode{$client}{search_forced};

				# Do the next level of keyword search.
				my $items =
				  doKeywordSearch( $client, $searchText, $forceSearch,
					( $level + 1 ),
					$contributorConstraint, $albumConstraint );

	  # Use INPUT.Choice to display the results for this selected keyword search
	  # category.
				my %params = (

					# The header (first line) to display whilst in this mode.
					header => $line1BrowseText . ' \''
					  . keywordMatchText( $client, 1 )
					  . '\' {count}',

					# A reference to the list of items to display.
					listRef => $items,

				 # A unique name for this mode that won't actually get displayed
				 # anywhere.
					modeName => "LAZYBROWSE_KEYWORD_MODE:$level:$searchText",

		  # An anonymous function that is called every time the user presses the
		  # RIGHT button.
					onRight => \&keywordOnRightHandler,

				 # A handler that manages play/add/insert (differentiated by the
				 # last parameter).
					onPlay => sub {
						my ( $client, $item, $addMode ) = @_;

						$::d_plugins
						  && Slim::Utils::Misc::msg(
"LazySearch2: lazyOnPlay called for keyword search result\n"
						  );

			  # Start playing the item selected (in the correct mode - play, add
			  # or insert).
						lazyOnPlay( $client, $item, $addMode );
					},

					# These are all menu items and so have a right-arrow overlay
					overlayRef => sub {
						return [
							undef, Slim::Display::Display::symbol('rightarrow')
						];
					},
				);

				$::d_plugins
				  && Slim::Utils::Misc::msg(
"LazySearch2: setSearchBrowseMode called with mode \'LAZYBROWSE_KEYWORD_MODE:$level:$searchText\'\n"
				  );

	  # Use our INPUT.Choice-derived mode to show the menu and let it do all the
	  # hard work of displaying the list, moving it up and down, etc, etc.
				Slim::Buttons::Common::pushModeLeft( $client,
					LAZYBROWSE_KEYWORD_MODE, \%params );
			} else {

				# We're currently at the track level so push into track info
				# browse mode (which needs the track URL to be looked-up).
				my $track = Slim::Schema->rs('Track')->find($value);
				$::d_plugins
				  && Slim::Utils::Misc::msg(
"LazySearch2: going into trackinfo mode for track URL=$track\n"
				  );
				Slim::Buttons::Common::pushModeLeft( $client, 'trackinfo',
					{ 'track' => $track } );
			}
		} else {
			$client->bumpRight();
		}
	}
}

sub keywordMatchText($$$) {
	my $client       = shift;
	my $hideShorties = shift;

	# Search text is an optional parameter; if not specified it is taken
	# from the current player status.
	my $searchText = shift || $clientMode{$client}{search_text};

	# Find whether the search is being forced; if it is then we don't hide
	# short text.
	my $searchForced = $clientMode{$client}{search_forced};

	# Split and add each separate 'keyword' to our string. We optionally don't
	# output any that are too short since we've not actually searched for them.
	my $text = '';
	my @keywordParts = split( KEYWORD_SEPARATOR_CHARACTER, $searchText );
	foreach my $keyword (@keywordParts) {
		next if ( length($keyword) == 0 );
		next
		  if ( !$searchForced
			&& $hideShorties
			&& ( length($keyword) < $clientMode{$client}{min_search_length} ) );

		if ( length($text) == 0 ) {
			$text .= "$keyword";
		} else {
			$text .= ",$keyword";
		}
	}

	# If we're not hiding short keywords (ie the user is entering the search)
	# we add a trailing ',' if the last key entry was the separator.
	if ( !$hideShorties
		&& ( substr( $searchText, length($searchText) - 1 ) eq KEYWORD_SEPARATOR_CHARACTER )
	  )
	{
		$text .= ',';
	}

	return $text;
}

# Standard plugin function to return our message catalogue. Many thanks to the
# following for the translations:
#	DA	Jacob Bang (jacob@phonden.dk)
# 	DE	Dieter (dieterp@patente.de)
# 	ES	Néstor (nspedalieri@gmail.com)
#	FI	Kim B. Heino (b@bbbs.net)
sub strings {
	return '
PLUGIN_LAZYSEARCH2
	DA	Lazy Search Music
	DE	Faulpelz-Suche
	EN	Lazy Search Music
	ES	Búsqueda Laxa de Música
	FI	Laiska musiikin haku

PLUGIN_LAZYSEARCH2_TOPMENU
	DA	Lazy Search Music
	DE	Faulpelz-Suche
	EN	Lazy Search Music
	ES	Búsqueda Laxa de Música
	FI	Laiska musiikin haku

LINE1_BROWSE
	DA	Lazy Search
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa
	FI	Laiska haku

LINE1_SEARCHING
	DA	Søger efter \'%s\' ...
	DE	Suchen nach \'%s\' ...
	EN	Searching for \'%s\' ...
	ES	Buscando \'%s\' ...
	FI	Haen \'%s\'...

SHOWBRIEFLY_DISPLAY
	DA	Lazy Search
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa
	FI	Laiska haku

LINE1_BROWSE_ARTISTS
	DA	Kunstner søgning
	DE	Passende Interpreten
	EN	Artists Matching
	ES	Artistas Coincidentes
	FI	Esittäjän haku

LINE1_BROWSE_ARTISTS_EMPTY
	DA	Lazy Search efter kunstner
	DE	Faulpelz-Suche nach Interpreten
	EN	Lazy Search for Artists
	ES	Búsqueda Laxa de Artistas
	FI	Laiska hae esittäjää

LINE1_BROWSE_ALBUMS
	DA	Matchende albums
	DE	Passende Alben
	EN	Albums Matching
	ES	Álbumes Coincidentes
	FI	Levyn nimen haku

LINE1_BROWSE_ALBUMS_EMPTY
	DA	Lazy Search efter Album
	DE	Faulpelz-Suche nach Alben
	EN	Lazy Search for Albums
	ES	Búsqueda Laxa de Álbumes
	FI	Laiska hae levyä

LINE1_BROWSE_TRACKS
	DA	Matchende sange
	DE	Passende Titel
	EN	Songs Matching
	ES	Canciones Coincidentes
	FI	Kappaleen haku

LINE1_BROWSE_TRACKS_EMPTY
	DA	Lazy Search efter sange
	DE	Faulpelz-Suche nach Titel
	EN	Lazy Search for Songs
	ES	Búsqueda Laxa de Canciones
	FI	Laiska hae kappaletta

LINE1_BROWSE_GENRES
	DA	Matchende genre
	DE	Passende Stilrichtungen
	EN	Genres Matching
	ES	Géneros Coincidentes
	FI	Lajin haku

LINE1_BROWSE_GENRES_EMPTY
	DA	Lazy Search efter genre
	DE	Faulpelz-Suche nach Stilrichtungen
	EN	Lazy Search for Genres
	ES	Búsqueda Laxa de Géneros
	FI	Laiska hae lajia

LINE2_ENTER_MORE_ARTISTS
	DA	Indtast kunstner
	DE	Interpret eingeben
	EN	Enter Artist Search
	ES	Ingresar Búsqueda de Artista
	FI	Kirjoita esittäjän nimi

LINE2_ENTER_MORE_ALBUMS
	DA	Indtast album
	DE	Album eingeben
	EN	Enter Album Search
	ES	Ingresar Búsqueda de Álbumes
	FI	Kirjoita levyn nimi

LINE2_ENTER_MORE_TRACKS
	DA	Indtast sang
	DE	Titel eingeben
	EN	Enter Song Search
	ES	Ingresar Búsqueda de Canciones
	FI	Kirjoita kappaleen nimi

LINE2_ENTER_MORE_GENRES
	DA	Indtast genre
	DE	Stilrichtung eingeben
	EN	Enter Genre Search
	ES	Ingresar Búsqueda de Géneros
	FI	Kirjoita lajin nimi

SETUP_GROUP_PLUGIN_LAZYSEARCH2
	DA	Lazy Search
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa
	FI	Laiska haku

SETUP_GROUP_PLUGIN_LAZYSEARCH2_DESC
	DA	Indstillingen nedenfor styrer ydelsen af lazy search afspillerens interface. Det er anbefalet at <i>Lazy Search Music</i> menuen fra dette plugin bliver tilføjet til en afspiller\'s home menu for at give nem adgang til dette plugin\'s funktioner. (Standard søgefunktionen vil også give adgang til denne funktionalitet).
	DE	Mit den unten angebenen Einstellungen kann definiert werden, wie sich die Player-Oberfläche der Faulpelz-Suche verhält. Es wird empfohlen, den Plugin-Menüpunkt <i>Faulpelz-Suche</i> zum Hauptmenü des Players hinzuzufügen, um einen einfachen Zugriff auf die Funktionen dieses Plugins zu ermöglichen (die Standard <i>SEARCH</i>-Taste auf der Fernbedienung ermöglicht ebenfalls den Zugang zu dieser Funktionalität).
	EN	The settings below control how the lazy searching player interface performs. It is suggested that the <i>Lazy Search Music</i> menu item from this plugin is added to a player\'s home menu to provide easy access to this plugin\'s functions (the standard remote <i>search</i> button will also access this functionality).
	ES	La configuración debajo controla cómo actúa la interface de búsqueda laxa del reproductor. Se sugiere que el item de menú <i>Búsqueda Laxa de Música</i> para este plugin se añada al menú inicial del reproductor para brindar un acceso fácil a las funciones del plugin (el botón <i>search</i> estándar del control remoto tendrá también acceso a esta funcionalidad).
	FI	Alla olevat asetukset vaikuttavat laiskan haun toimintaan. Kätevin tapa käyttää <i>laiskaa musiikin hakua</i> on lisätä se soittimen päävalikkoon soittimen asetuksista. Laiskaan hakuun pääsee myös painamalla kaukosäätimen <i>hae</i>-nappia.

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST
	DA	Minimum kunstnersøge længde
	DE	Mindestlänge für die Suche nach Interpreten
	EN	Minimum Artist Search Length
	ES	Mínima Longitud para Búsqueda de Artista
	FI	Esittäjä-haun lyhin pituus

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_DESC
	DA	Søgning efter kunstner, album, genre eller sang med et kort antal tegn er ikke brugbart i praksis, da det vil resultere i et stort antal resultater. For at undgå at søgningen starter før et mere brugbart antal tegn bliver tastet, kan et minimum antal tegn specificeres her. Der er separate indstillinger for kunstner og album navn, genre og sangtitel. - Det anbefales at bruge 3 for kunstner, album og genre, og 4 for sangtitel.
	DE	Die Suche nach Interpreten, Alben, Stilrichtungen oder Titel mit einer zu kleinen Zahl von Zeichen ist nicht besonders sinnvoll, da sie zu viele Ergebnisse liefert. Um zu verhindern, dass eine Suche gestartet wird, bevor eine sinnvolle Anzahl von Zeichen eingeben wurde, ist eine Mindestzahl von Zeichen vorgegeben. Es gibt unterschiedliche Einstellungen für Interpretennamen, Albumnamen und Liedertitel - sinnvolle Voreinstellungen sind 3 für Interpreten und Alben und 4 für Lieder.
	EN	Searching for artists, albums, genres or songs with a short number of characters isn\'t very useful as it will return so many results. To prevent a search being performed until a more useful number of characters have been entered a mininum number of characters is specified here. There are separate settings for artists and album names, genres and song titles - a setting of 3 for artists, albums and genres, and 4 for songs, is a useful default.
	ES	El buscar artistas, álbumes, géneros o canciones con muy pocos caracteres no es muy útil, ya que retornará demasiados resultados. Para evitar que se efectúe una búsqueda hasta que se hayan ingresado más caracteres, se especifica aquí un número mínimo de ellos. Existen configuraciones individuales para búsqueda por nombre de artistas, nombre de álbumes, y nombre de canciones - valores por defecto apropiados son 3 caracteres para artistas, álbumes y géneros, y 4 caracteres para canciones.
	FI	Jos haet esittäjää, levyä, lajia tai kappaletta liian lyhyellä sanalla, niin saat usein liian monta vastausta. Alla voit määritellä montako kirjainta pitää kirjoittaa, että laiska haku aloittaa haun. Voit määritellä eri arvon eri hakutavoille. Oletusarvoisesti lyhin kirjainmäärä on esittäjälle, levylle ja lajille kolme, sekä kappaleen nimelle neljä.

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHOOSE
	DA	Minimum længde for kunstner søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Interpreten (2-9 Zeichen):
	EN	Minimum length for artist search (2-9 characters):
	ES	Mínima longitud para búsqueda de artista (2-9 caracteres):
	FI	Esittäjä-haun lyhin kirjainmäärä (2-9 kirjainta):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHANGE
	DA	Minimum længde for kunstner søgning ændret til:
	DE	Mindestlänge für die Suche nach Interpreten wurde geändert in:
	EN	Minimum length for artist search changed to:
	ES	Mínima longitud para búsqueda de artista cambió a:
	FI	Esittäjä-haun lyhin kirjainmäärä vaihdettiin arvoon:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM
	DA	Minimum længde for album søgning
	DE	Mindestlänge für die Suche nach Alben
	EN	Minimum Album Search Length
	ES	Mínima Longitud para Búsqueda de Álbum
	FI	Levy-haun lyhin pituus

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHOOSE
	DA	Minimum længde for album søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Alben (2-9 Zeichen):
	EN	Minimum length for album search (2-9 characters):
	ES	Mínima longitud para búsqueda de álbum (2-9 caracteres):
	FI	Levy-haun lyhin kirjainmäärä (2-9 kirjainta):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHANGE
	DA	Minimum længde for album søgning rettet til:
	DE	Mindestlänge für die Suche nach Alben wurde geändert in:
	EN	Minimum length for album search changed to:
	ES	Mínima longitud para búsqueda de álbum cambió a:
	FI	Lyvy-haun lyhin kirjainmäärä vaihdettiin arvoon:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK
	DA	Minimum længde for sang søgning
	DE	Mindestlänge für die Suche nach Titel
	EN	Minimum Song Search Length
	ES	Mínima Longitud para Búsqueda de Canción
	FI	Kappale-haun lyhin pituus

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHOOSE
	DA	Minimum længde for sang søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Titel (2-9 Zeichen):
	EN	Minimum length for song search (2-9 characters):
	ES	Mínima longitud para búsqueda de canción (2-9 caracteres):
	FI	Kappale-haun lyhin kirjainmäärä (2-9 kirjainta):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHANGE
	DA	Minimum længde for sang søgning rettet til:
	DE	Mindestlänge für die Suche nach Titel wurde geändert in:
	EN	Minimum length for song search changed to:
	ES	Mínima longitud para búsqueda de canción cambió a:
	FI	Kappale-haun lyhin kirjainmäärä vaihdettiin arvoon:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE
	DA	Minimum længde for sang søgning
	DE	Mindestlänge für die Suche nach Stilrichtungen
	EN	Minimum Genre Search Length
	ES	Mínima Longitud para Búsqueda de Género
	FI	Laji-haun lyhin pituus

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHOOSE
	DA	Minimum længde for genre søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Stilrichtungen (2-9 Zeichen):
	EN	Minimum length for genre search (2-9 characters):
	ES	Mínima longitud para búsqueda de género (2-9 caracteres):
	FI	Laji-haun lyhin kirjainmäärä (2-9 kirjainta):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHANGE
	DA	Minimum længde for genre søgning rettet til:
	DE	Mindestlänge für die Suche nach Stilrichtungen wurde geändert in:
	EN	Minimum length for genre search changed to:
	ES	Mínima longitud para búsqueda de género cambió a:
	FI	Laji-haun lyhin kirjainmäärä vaihdettiin arvoon:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES
	DA	VENSTRE-knap opførsel
	DE	Verhalten der LINKS-Taste
	EN	LEFT Button Behaviour
	ES	Comportamiento del Botón IZQUIERDA
	FI	VASEN-napin toiminta

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_DESC
	DA	Du kan vælge hvordan VESTRE-knappen på fjernbetjæningen opfører sig når man trykker en søgetekst. VESTRE kan enten slette det sidst tastet tegn (for at rette en fejl), eller forlade søgeningen.
	DE	Man kann einstellen, wie sich die LINKS-Taste auf der Fernbedienung bei der Eingabe von Suchtext verhält. Mit der LINKS-Taste kann entweder das zuletzt eingegeben Zeichen gelöscht werden (z.B. um einen Fehler zu korrigieren) oder der Suchmodus beendet werden.
	EN	You can choose how the LEFT button on the remote control behaves when entering search text. LEFT can either delete the last character entered (eg to correct a mistake), or can exit the search mode altogether.
	ES	Se puede elegir como se comportará el boton IZQUIERDA del control remoto cuando se ingresa texto. IZQUIERDA puede o bien borrar el último caracter ingresado (por ej, para corregir un error), o bien puede abandonar el modo búsqueda.
	FI	Voit valita miten kaukosäätimen VASEN-nappi toimii kun kirjoitat hakua. VASEN voi olla joko viimeisen kirjaimen pyyhintä (esim. virheen korjaus), tai se voi poistua kokonaan hausta.

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHOOSE
	DA	Ved tryk på VENSTRE under søgning:
	DE	Drücken der LINKS-Taste während einer Suche:
	EN	Pressing LEFT while entering a search:
	ES	Presionando IZQUIERDA mientras se ingresa una búsqueda:
	FI	VASEN-napin toiminta hakua kirjoitettaessa:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHANGE
	DA	Tyk VENSTRE for at:
	DE	Drücken der LINKS-Taste wurde geändert in:
	EN	Pressing LEFT changed to:
	ES	Presionando IZQUIERDA cambió a:
	FI	VASEN-napin toiminta muutettu arvoon:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_0
	DA	Forlade søgning
	DE	Beendet den Suchmodus
	EN	Exits the search mode
	ES	Abandona el modo búsqueda
	FI	Poistu hausta

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_1
	DA	Slette det sidst tastede tegn
	DE	Löscht das zuletzt eingegebene Zeichen
	EN	Deletes the last character entered
	ES	Borra los últimos caracteres ingresados
	FI	Poista viimeinen kirjain

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON
	DA	SEARCH-knap opførsel
	DE	Verhalten der SEARCH-Taste
	EN	SEARCH Button Behaviour
	ES	Comportamiento del Botón SEARCH
	FI	HAKU-napin toiminta

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_DESC
	DA	Denne indstilling giver mulighed for at SEARCH knappen på Squeezebox/Transporter fjernbetjæningen benyttes til at aktivere <i>Lazy Search Music</i> funktionen i stedet for den orginale <i>søg</i> funktion. Det er ikke nødvendigt at rette i <i>Default.map</i> eller <i>Custom.map filerne. Bemærk, denne indstilling slår ikke igennem før plugin\'et er genindløst (f.eks. ved at genstarte SlimServer).
	DE	Mit dieser Einstellung kann die SEARCH-Taste auf der Squeezebox/Transporter-Fernbedienung mit der <i>Faulpelz-Suche</i> statt mit der <i>Originalsuche</i> belegt werden. Durch Aktivieren dieser Einstellung kann diese Taste entsprechend umbelegt werden, ohne die Dateien <i>Default.map</i> oder <i>Custom.map</i> ändern zu müssen. Hinweis: Änderungen an dieser Einstellung werden erst nach einem erneuten Start des Plugins wirksam (z.B. bei einem Neustart des SlimServers).
	EN	This setting allows the SEARCH button on the Squeezebox/Transporter remote control to be remapped to the <i>lazy search music</i> function instead of the original <i>search music</i> function. Enabling this setting allows this button remapping to be performed without editing the <i>Default.map</i> or <i>Custom.map</i> files. Note that changes to this setting do not take effect until the plugin is reloaded (eg by restarting SlimServer).
	ES	Esta configuración permite reasignar el boton SEARCH del control remoto de Squeezebox/Transporter a la función de <i>búsqueda laxa de música</i>, en lugar de la función de <i>búsqueda de música</i> original. Habilitando esto se logra que la reasignación del botón sea realizada sin editar los archivos <i>Default.map</i> o <i>Custom.map</i>. Notar que los cambios no tendrán efecto hasta que el plugin sea recargado (por ej. al reiniciar SlimServer).
	FI	Tällä asetuksella voit muuttaa miten Squeezeboxin / Transporterin kaukosäätimen HAKU-nappi toimii. Painamalla sitä voit joko päästä <i>laiska musiikin haku</i>-valikkoon, tai normaalin <i>haku</i>-valikkoon. Tällä asetuksella voit muuttaa napin toimintaa muuttamatta <i>Default.map</i> tai <i>Custom.map</i> tiedostoja. Huomaa, että asetuksen uusi arvo tulee voimaan, kun laajennus käynnistetään uudelleen (esim. käynnistämällä SlimServer uudelleen).

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHOOSE
	DA	Tryk på SEARCH knappen på Squeezebox/Transporter fjernbetjæningen:
	DE	Drücken der SEARCH-Taste auf der Squeezebox/Transporter-Fernbedienung:
	EN	Pressing SEARCH on the Squeezebox/Transporter remote control:
	ES	Presionando SEARCH en el remoto de Squeezebox/Transporter:
	FI	Squeezeboxin / Transporterin kaukosäätimen HAKU-nappin toiminta:

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHANGE
	DA	Tryk på SEARCH går til:
	DE	Drücken der SEARCH-Taste wurde geändert in:
	EN	Pressing SEARCH changed to:
	ES	Presionando SEARCH cambió a:
	FI	HAKU-napin toiminta muutettu arvoon:

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_0
	DA	Standard søgning
	DE	Zeigt das Menü der Standardsuche an
	EN	Accesses the standard search music menu
	ES	Accede al menú de búsqueda musical estándar
	FI	Normaali haku

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_1
	DA	Lazy Search menuen.
	DE	Zeigt das Menü der Faulpelz-Suche an
	EN	Accesses the lazy search music menu
	ES	Accede al menú de búsqueda musical laxa
	FI	Laiska musiikin haku

SCAN_IN_PROGRESS
	DA	Note: dit musik biblioteket bliver lige nu scannet.
	DE	Hinweis: Die Musikdatenbank wird gerade durchsucht
	EN	Note: music library scan in progress
	ES	Nota: se está recopilando la colección musical
	FI	Huomautus: Musiikkikirjaston luominen on käynnissä.

SCAN_IN_PROGRESS_DBL
	DA	Note: scanner
	DE	Hinweis: Suche läuft
	EN	Note: scanning
	ES	Nota: recopilando
	FI	Huomautus: etsin

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW
	DA	Gennemtving opbygningen af Lazy Seach indexet
	DE	Indexerzeugung für die Faulpelz-Suche
	EN	Force Lazy Search Index Build
	ES	Forzar Creación de Índice para Búsqueda Laxa
	FI	Käynnistä laiskan haun indeksointi

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_DESC
	DA	Dette plugin er lavet til at vedligeholde Lazy Search indexet når det er nødvendigt. Derfor er det ikke, under normale omstændigheder, nødvendigt at tivnge re-index igennem. Du kan dog, hvis du vil være sikker på at indexet er opbygget korrekt, trykke denne knap. Dette er primært en debug funktion.
	DE	Das Plugin erzeugt den Index für die Faulpelz-Suche, wenn dies erforderlich ist. Normalerweise ist daher keine extra Pflege der Datenbank notwendig. Falls Sie sichergehen wollen, dass der Index der Faulpelz-Suche korrekt erzeugt wurde, können Sie die folgende Schaltfläche anklicken. Aber in Anbetracht dessen, dass dies nie erforderlich sein sollte, ist dies in erster Linie eine Hilfe für die Fehlersuche.
	EN	The plugin is designed to build the lazy search index whenever required and so, under normal circumstances, no extra database maintenance is required. If you wish to ensure that the lazy search index has been correctly built you can press the following button, but given that it should never be necessary this is primarily a debugging aid.
	ES	El plugin se ha diseñado para construir el índice de búsqueda laxa cuando sea que se requiera. Por lo tanto, en circunstancias normales, no se requiere mantenimiento extra de la base de datos. Si se quiere estar seguro que el índice de búsqueda laxa ha sido construido correctamente, se puede presionar el siguiente botón (aunque dado que nunca debería ser necesario reconstruirlo manualmente se lo incluye aquí simplemente como una ayuda para la depuración).
	FI	Normaalisti laiska haku huomaa itse milloin sen pitää luoda hakuindeksi uudelleen. Jos haluat varmistaa, että laiskan haun hakuindeksi on varmasti ajan tasalla, niin voit tehdä sen painamalla alla olevaa nappia. Sitä ei normaalisti tarvitse tehdä koskaan, joten tämä on lähinnä tarkoitettu vian etsintään.

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_CHANGE
	DA	Lazy Search indexet bliver du genopbygget
	DE	Die Erzeugung des Index für die Faulpelz-Suche hat begonnen
	EN	Lazy search index build has been started
	ES	La creación del índice para búsqueda laxa ha comenzado
	FI	Laiskan haun indeksointi on käynnistetty.

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_BUTTON
	DA	Start opbygning af Lazy Search indexet
	DE	Jetzt den Index für die Faulpelz-Suche erzeugen
	EN	Build Lazy Search Index Now
	ES	Crear Índice de Búsqueda Laxa Ahora
	FI	Luo laiskan haun indeksi nyt

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ARTISTS_HEAD
	DA	Keyword søgning
	DE	Stichwort-Suche
	EN	Keyword Search
	FI	Sana-haku

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_OPTIONS_DESC
	DA	Keyword søgning giver mulighed for at søge mellem flere kategorier, og på den måde finde albums, kunstnere og sangtitler som matcher et eller flere <i>keywords</i> i deres titel. Dette kan være brugbart, f.eks. med klassisk musik samlinger som både kan have kunster, forfatter og udøver inkluderet i sangtitlen og albumkunstneren eller sangkunstneren idet funktionen giver mulighed for at søge ligegyldigt hvordan sangens tags er opbygget. Følgende indstillinger giver dig mulighed for at specificere hvilke kategorier der bliver inkluderet i keyword søgningen. Hvis alle kattegorier er slået fra, vil keyword søgnings muligheden ikke optræde i afspillerens Lazy Search menu.<br/><br/><b>Bemærk</b> at denne indstilling vil først slå igennem efter en komplet genscanning af databasen er foretaget.
	DE	Die Stichwort-Suche ermöglicht die Suche über mehrere Kategorien gleichzeitig, d.h. man kann Alben, Interpreten und Lieder finden, die ein oder mehrere <i>Stichworte</i> enthalten. Dies ist z.B. bei klassischen Musiksammlungen hilfreich, bei denen Interpreten, Komponisten und Dirigenten in den Liedertiteln, im Album-Interpret oder im Lied-Interpret enthalten sind, weil du deine Musik suchen und finden kannst unabhängig davon, wie die Lieder mit "Tags" versehen sind. Mit den folgenden Optionen kannst du einstellen, welche Kategorien in die Stichwort-Suche einbezogen werden. Wenn keine Kategorien ausgewählt ist, erscheint die Anzeige der Stichwort-Suche nicht im Faulpelz-Menü am Player.<br/><br/><b>Hinweis</b>: Änderungen werden erst wirksam, wenn die Datenbank einmal komplett gelöscht und neu aufgebaut wurde.
	EN	Keyword search allows searching across multiple categories, finding albums, artists and songs that match one or more <i>keywords</i> within their titles. This may be useful, for example, with classical music collections which can have artists, composers and performers included in the song titles as well as in the album artist and song artist because it lets you search and find your music no matter how the tracks were tagged. The following settings allow you to specify which categories will be included in keyword searches. If all categories are disabled then the keyword search option won\'t appear in the player\'s Lazy Search menu at all.<br/><br/><b>Note</b> that this change will only take effect once a complete database clear and rescan has been performed.
	FI	Sana-haulla voit etsiä samalla kertaa monesta eri kategoriasta. Voit yhdellä haulla etsiä <i>sanoja</i> levyn, esittäjän tai kappaleen nimestä. Tämä on käytännöllistä esimerkiksi klassisessa musiikissa: esittäjä tai säveltäjä voi olla merkitty joko kappaleen, levyn tai esittäjän kohdalle. Sana-haulla voit etsiä niistä kaikista. Seuraavilla asetuksilla voit määritellä mistä asioista haku tehdään. Jos kaikki ovat pois päältä, niin sana-hakua ei näytetä ollenkaan laiskan haun valikossa.<br/><br/><b>Huomaa,</b> että tämä asetus tulee voimaan vasta, kun musiikkikirjasto on ensin tyhjennetty ja luettu musiikkihakemistosta uudelleen.

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ARTISTS_CHOOSE
	DA	Keyword søgning efter kunstner:
	DE	Stichwort-Suche nach Interpreten:
	EN	Keyword search for artists:
	FI	Sana-hae esittäjää:

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ARTISTS_CHANGE
	DA	Keyword søgning for kunstner rettet til:
	DE	Stichwort-Suche nach Interpreten wurde geändert in:
	EN	Keyword search for artists changed to:
	FI	Sana-hae esittäjää muutettu arvoon:

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ALBUMS_HEAD
	DA	Keyword søgning efter Album
	DE	Stichwort-Suche nach Alben
	EN	Keyword Search for Albums
	FI	Sana-hae levyn nimeä

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ALBUMS_CHOOSE
	DA	Keyword søgning efter album:
	DE	Stichwort-Suche nach Alben:
	EN	Keyword search for albums:
	FI	Sana-hae levyn nimeä:

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ALBUMS_CHANGE
	DA	Keyword søgning for album rettet til:
	DE	Stichwort-Suche nach Alben wurde geändert in:
	EN	Keyword search for albums changed to:
	FI	Sana-hae levyn nimeä vaihdettu arvoon:

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_TRACKS_HEAD
	DA	Keyword søgning efter sangtitel
	DE	Stichwort-Suche nach Liedern
	EN	Keyword Search for Songs
	FI	Sana-hae kappaleen nimeä

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_TRACKS_CHOOSE
	DA	Keyword søgning efter sangtitel:
	DE	Stichwort-Suche nach Liedern:
	EN	Keyword search for songs:
	FI	Sana-hae kappaleen nimeä:

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_TRACKS_CHANGE
	DA	Keyword søgning for sangtitel rettet til:
	DE	Stichwort-Suche nach Liedern wurde geändert in:
	EN	Keyword search for songs changed to:
	FI	Sana-hae kappaleen nimeä muutettu arvoon:

KEYWORD_MENU_ITEM
	DA	Keywords
	DE	Stichwörter
	EN	Keywords
	FI	Sanat

LINE1_BROWSE_KEYWORDS_EMPTY
	DA	Lazy Search efter Keywords
	DE	Faulpelz-Suche nach Stichwörtern
	EN	Lazy Search by Keywords
	FI	Laiska hae sanaa

LINE2_ENTER_MORE_KEYWORDS
	DA	Indtast Keyword Søgning
	DE	Stichwörter eingeben
	EN	Enter Keyword Search
	FI	Kirjoita hakusana

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_KEYWORD
	DA	Minimum længde for keyword søgning
	DE	Mindestlänge für die Stichwort-Suche
	EN	Minimum Keyword Search Length
	FI	Sana-haun lyhin pituus

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_KEYWORD_CHOOSE
	DA	Minimum længde for keyword søgning (2-9 tegn):
	DE	Mindestlänge für die Stichwort-Suche (2-9 Zeichen):
	EN	Minimum length for keyword search (2-9 characters):
	FI	Sana-haun lyhin kirjainmäärä (2-9 kirjainta):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_KEYWORD_CHANGE
	DA	Minimum længde for keyword søgning rettet til:
	DE	Mindestlänge für die Stichwort-Suche wurde geändert in:
	EN	Minimum length for keyword search changed to:
	FI	Sana-haun lyhin kirjainmäärä vaihdettu arvoon:
';
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
