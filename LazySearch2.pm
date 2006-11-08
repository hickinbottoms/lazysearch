# LazySearch2 Plugin for SlimServer
# Copyright © Stuart Hickinbottom 2004-2006
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
use Scalar::Util qw(blessed);

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

# Search button behaviour options.
use constant LAZYSEARCH_SEARCHBUTTON_STANDARD => 0;
use constant LAZYSEARCH_SEARCHBUTTON_MENU     => 1;
use constant LAZYSEARCH_SEARCHBUTTON_ARTIST   => 2;
use constant LAZYSEARCH_SEARCHBUTTON_ALBUM    => 3;
use constant LAZYSEARCH_SEARCHBUTTON_GENRE    => 4;
use constant LAZYSEARCH_SEARCHBUTTON_TRACK    => 5;
use constant LAZYSEARCH_SEARCHBUTTON_KEYWORD  => 6;

# Preference ranges and defaults.
use constant LAZYSEARCH_MINLENGTH_MIN             => 2;
use constant LAZYSEARCH_MINLENGTH_MAX             => 9;
use constant LAZYSEARCH_MINLENGTH_ARTIST_DEFAULT  => 3;
use constant LAZYSEARCH_MINLENGTH_ALBUM_DEFAULT   => 3;
use constant LAZYSEARCH_MINLENGTH_GENRE_DEFAULT   => 3;
use constant LAZYSEARCH_MINLENGTH_TRACK_DEFAULT   => 4;
use constant LAZYSEARCH_MINLENGTH_KEYWORD_DEFAULT => 4;
use constant LAZYSEARCH_LEFTDELETES_DEFAULT       => 1;
use constant LAZYSEARCH_HOOKSEARCHBUTTON_DEFAULT  =>
  LAZYSEARCH_SEARCHBUTTON_MENU;
use constant LAZYSEARCH_ALLENTRIES_DEFAULT           => 1;
use constant LAZYSEARCH_KEYWORD_ARTISTS_DEFAULT      => 1;
use constant LAZYSEARCH_KEYWORD_ALBUMS_DEFAULT       => 1;
use constant LAZYSEARCH_KEYWORD_TRACKS_DEFAULT       => 1;
use constant LAZYSEARCH_KEYWORD_ALBUMARTISTS_DEFAULT => 0;

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
$VERSION = 'trunk-6.5 $Id$';

# This hash-of-hashes contains state information on the current lazy search for
# each player. The first hash index is the player (eg $clientMode{$client}),
# and the second a 'parameter' for that player.
# The elements of the second hash are as follows:
#	search_type:	This is the item type being searched for, and can be one
#					of Track, Contributor, Album, Genre or Keyword.
#	search_text:	The current search text (ie the number keys on the remote
#					control).
#	side:				Allows the search to be constrained to one side of
#						the pipe in the customsearch column or the other.
#						side=1 searches left, side=2 searches right, anything
#						else isn't specific.
#	perform_search:		Function reference to a function that will perform
#						the actual search. The search text is passed to this
#						function.
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
#	hierarchy:			Hierarchy definition that is passed to the mixer
#						function when invoking a fix (this is a hack to
#						allow reuse of BrowseDB's mix invocation function).
#	level:				Indication of the depth into the current 'hierarchy'
#						(this is also part of the hack to reuse BrowseDB's
#						mix function).
#	all_entry:			This is the string to be used for the 'all' entry at
#						the end of the list. If this isn't defined then there
#						won't be an 'all' entry added.
#	select_col:			This is the 'field' that the find returns.
#	player_title:		Start of line1 player text when there are search
#						results.
#	player_title_empty:	The line1 text when no search has yet been performed.
#	enter_more_prompt:	The line2 prompt shown when there is insufficient
#						search text entered to perform the search.
#	further_help_prompt: Extra help available to the user by pressing DOWN
#						 when viewing the prompt to enter characters for that
#						 search mode.
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

			# Push into a sub-mode for the selected category.
			enterCategoryItem( $client, $item );

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

# Enter the correct search category item.
sub enterCategoryItem($$) {
	my $client = shift;
	my $item   = shift;

	# Search term initially empty.
	$clientMode{$client}{search_text}      = '';
	$clientMode{$client}{search_items}     = ();
	$clientMode{$client}{search_performed} = '';
	$clientMode{$client}{search_pending}   = 0;

	# Dispatch to the correct method.
	if ( $item eq '{ARTISTS}' ) {
		enterArtistSearch( $client, $item );
	} elsif ( $item eq '{ALBUMS}' ) {
		enterAlbumSearch( $client, $item );
	} elsif ( $item eq '{GENRES}' ) {
		enterGenreSearch( $client, $item );
	} elsif ( $item eq '{SONGS}' ) {
		enterTrackSearch( $client, $item );
	} elsif ( $item eq '{KEYWORD_MENU_ITEM}' ) {
		enterKeywordSearch( $client, $item );
	}
}

# Used when the user starts an artist search from the main category menu.
sub enterArtistSearch($$) {
	my $client = shift;
	my $item   = shift;

	$clientMode{$client}{search_type}         = 'Contributor';
	$clientMode{$client}{side}                = 0;
	$clientMode{$client}{hierarchy}           = 'contributor,album,track';
	$clientMode{$client}{level}               = 0;
	$clientMode{$client}{all_entry}           = '{ALL_ARTISTS}';
	$clientMode{$client}{player_title}        = '{LINE1_BROWSE_ARTISTS}';
	$clientMode{$client}{player_title_empty}  = '{LINE1_BROWSE_ARTISTS_EMPTY}';
	$clientMode{$client}{enter_more_prompt}   = 'LINE2_ENTER_MORE_ARTISTS';
	$clientMode{$client}{further_help_prompt} = 'LINE2_BRIEF_HELP';
	$clientMode{$client}{min_search_length}   =
	  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-artist');
	$clientMode{$client}{perform_search} = \&performArtistSearch;
	$clientMode{$client}{onright}        = \&rightIntoArtist;
	$clientMode{$client}{search_tracks}  = \&searchTracksForArtist;
	setSearchBrowseMode( $client, $item, 0 );
}

# Used when the user starts an album search from the main category menu.
sub enterAlbumSearch($$) {
	my $client = shift;
	my $item   = shift;

	$clientMode{$client}{search_type}         = 'Album';
	$clientMode{$client}{side}                = 0;
	$clientMode{$client}{hierarchy}           = 'album,track';
	$clientMode{$client}{level}               = 0;
	$clientMode{$client}{all_entry}           = '{ALL_ALBUMS}';
	$clientMode{$client}{player_title}        = '{LINE1_BROWSE_ALBUMS}';
	$clientMode{$client}{player_title_empty}  = '{LINE1_BROWSE_ALBUMS_EMPTY}';
	$clientMode{$client}{enter_more_prompt}   = 'LINE2_ENTER_MORE_ALBUMS';
	$clientMode{$client}{further_help_prompt} = 'LINE2_BRIEF_HELP';
	$clientMode{$client}{min_search_length}   =
	  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-album');
	$clientMode{$client}{perform_search} = \&performAlbumSearch;
	$clientMode{$client}{onright}        = \&rightIntoAlbum;
	$clientMode{$client}{search_tracks}  = \&searchTracksForAlbum;
	setSearchBrowseMode( $client, $item, 0 );
}

# Used when the user starts a genre search from the main category menu.
sub enterGenreSearch($$) {
	my $client = shift;
	my $item   = shift;

	$clientMode{$client}{search_type}         = 'Genre';
	$clientMode{$client}{side}                = 0;
	$clientMode{$client}{hierarchy}           = 'genre,track';
	$clientMode{$client}{level}               = 0;
	$clientMode{$client}{all_entry}           = undef;
	$clientMode{$client}{player_title}        = '{LINE1_BROWSE_GENRES}';
	$clientMode{$client}{player_title_empty}  = '{LINE1_BROWSE_GENRES_EMPTY}';
	$clientMode{$client}{enter_more_prompt}   = 'LINE2_ENTER_MORE_GENRES';
	$clientMode{$client}{further_help_prompt} = 'LINE2_BRIEF_HELP';
	$clientMode{$client}{min_search_length}   =
	  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-genre');
	$clientMode{$client}{perform_search} = \&performGenreSearch;
	$clientMode{$client}{onright}        = \&rightIntoGenre;
	$clientMode{$client}{search_tracks}  = \&searchTracksForGenre;
	setSearchBrowseMode( $client, $item, 0 );
}

# Used when the user starts a track search from the main category menu.
sub enterTrackSearch($$) {
	my $client = shift;
	my $item   = shift;

	$clientMode{$client}{search_type}         = 'Track';
	$clientMode{$client}{side}                = 1;
	$clientMode{$client}{hierarchy}           = 'track';
	$clientMode{$client}{level}               = 0;
	$clientMode{$client}{all_entry}           = '{ALL_SONGS}';
	$clientMode{$client}{player_title}        = '{LINE1_BROWSE_TRACKS}';
	$clientMode{$client}{player_title_empty}  = '{LINE1_BROWSE_TRACKS_EMPTY}';
	$clientMode{$client}{enter_more_prompt}   = 'LINE2_ENTER_MORE_TRACKS';
	$clientMode{$client}{further_help_prompt} = 'LINE2_BRIEF_HELP';
	$clientMode{$client}{min_search_length}   =
	  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-track');
	$clientMode{$client}{perform_search} = \&performTrackSearch;
	$clientMode{$client}{onright}        = \&rightIntoTrack;
	$clientMode{$client}{search_tracks}  = \&searchTracksForTrack;
	setSearchBrowseMode( $client, $item, 0 );
}

# Used when the user starts a keyword search from the main category menu.
sub enterKeywordSearch($$) {
	my $client = shift;
	my $item   = shift;

	$clientMode{$client}{search_type}         = SEARCH_TYPE_KEYWORD;
	$clientMode{$client}{side}                = 2;
	$clientMode{$client}{all_entry}           = undef;
	$clientMode{$client}{hierarchy}           = 'contributor,album,track';
	$clientMode{$client}{level}               = 0;
	$clientMode{$client}{player_title}        = '{LINE1_BROWSE_ARTISTS}';
	$clientMode{$client}{player_title_empty}  = '{LINE1_BROWSE_KEYWORDS_EMPTY}';
	$clientMode{$client}{enter_more_prompt}   = 'LINE2_ENTER_MORE_KEYWORDS';
	$clientMode{$client}{further_help_prompt} = 'LINE2_BRIEF_HELP';
	$clientMode{$client}{min_search_length}   =
	  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-keyword');
	$clientMode{$client}{onright}       = \&keywordOnRightHandler;
	$clientMode{$client}{search_tracks} = undef;
	setSearchBrowseMode( $client, $item, 0 );
}

# Return a result set that contains all tracks for a given artist, for when
# PLAY/INSERT/ADD is pressed on one of those items.
sub searchTracksForArtist($) {
	my $id        = shift;
	my $condition = undef;

	# We restrict the search to include artists related in the roles the
	# user wants (set through SlimServer preferences).
	my $roles = Slim::Schema->artistOnlyRoles('TRACKARTIST');
	if ($roles) {
		$condition->{'role'} = { 'in' => $roles };
	}

	return Slim::Schema->search( 'ContributorTrack',
		{ 'me.contributor' => $id } )->search_related(
		'track',
		$condition,
		{
			'order_by' =>
			  'track.album, track.disc, track.tracknum, track.titlesort'
		}
		)->distinct->all;
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
			'findCriteria' => { 'contributor.id' => $item->id },
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
			'findCriteria' => { 'album.id' => $item->id },
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
			'findCriteria' => { 'genre.id' => $item->id },
		}
	);
}

# Browse into a particular track.
sub rightIntoTrack($$) {
	my $client = shift;
	my $item   = shift;

	# Push into the trackinfo mode for this one track.
	my $track = Slim::Schema->rs('Track')->find( $item->id );
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

	# Out input map for the new categories menu mode, based on the default map
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
	$chFunctions{'playSingle'}   = \&onPlayHandler;
	$chFunctions{'playHold'}     = \&onCreateMixHandler;
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
		'arrow_left'        => 'leftSingle',
		'arrow_left.hold'   => 'leftHold',
		'arrow_right'       => 'exit_right',
		'play.single'       => 'playSingle',
		'play.hold'         => 'playHold',
		'play'              => 'dead',
		'play.repeat'       => 'dead',
		'play.hold_release' => 'dead',
		'play.double'       => 'dead',
		'pause.single'      => 'pause',
		'pause.hold'        => 'stop',
		'add.single'        => 'addSingle',
		'add.hold'          => 'addHold',
		'search'            => 'forceSearch',
		'0.single'          => 'zeroButton',
		'0.hold'            => 'keywordSep',
		'0'                 => 'dead',
		'0.repeat'          => 'dead',
		'0.hold_release'    => 'dead',
		'0.double'          => 'dead',
	);
	for my $buttonPressMode (qw{repeat hold hold_release single double}) {
		$lazyInputMap{ 'search.' . $buttonPressMode } = 'dead';
	}
	Slim::Hardware::IR::addModeDefaultMapping( LAZYBROWSE_MODE,
		\%lazyInputMap );

	# The mode that is used to show keyword results once the user has entered
	# one of the returned categories.
	my %chFunctions2 = %{ Slim::Buttons::Input::Choice::getFunctions() };
	$chFunctions2{'playSingle'}  = \&onPlayHandler;
	$chFunctions2{'playHold'}    = \&onCreateMixHandler;
	$chFunctions2{'addSingle'}   = \&onAddHandler;
	$chFunctions2{'addHold'}     = \&onInsertHandler;
	$chFunctions2{'forceSearch'} = \&lazyForceSearch;
	Slim::Buttons::Common::addMode( LAZYBROWSE_KEYWORD_MODE, \%chFunctions2,
		\&Slim::Buttons::Input::Choice::setMode );

	# Our input map for the new keyword browse mode, based on the default map
	# contents for INPUT.Choice.
	my %keywordInputMap = (
		'arrow_left'        => 'exit_left',
		'arrow_right'       => 'exit_right',
		'play.single'       => 'playSingle',
		'play.hold'         => 'playHold',
		'play'              => 'dead',
		'play.repeat'       => 'dead',
		'play.hold_release' => 'dead',
		'play.double'       => 'dead',
		'pause.single'      => 'pause',
		'pause.hold'        => 'stop',
		'add.single'        => 'addSingle',
		'add.hold'          => 'addHold',
		'search'            => 'forceSearch',
	);
	for my $buttonPressMode (qw{repeat hold hold_release single double}) {
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
			'plugin-lazysearch2-keyword-return-albumartists',
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
			'validate'     => \&Slim::Utils::Validate::inList,
			'validateArgs' => [ 0 .. 6 ],
			'PrefHead' => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON'),
			'PrefDesc' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_DESC'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHANGE'),
			'options' => {
				0 => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_0'),
				1 => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_1'),
				2 => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_2'),
				3 => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_3'),
				4 => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_4'),
				5 => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_5'),
				6 => string('SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_6')
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
			'onChange' => \&scheduleForcedRelazify,
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
			'onChange' => \&scheduleForcedRelazify,
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
			'onChange' => \&scheduleForcedRelazify,
		},
		'plugin-lazysearch2-keyword-return-albumartists' => {
			'validate' => \&Slim::Utils::Validate::trueFalse,
			'PrefHead' => string('SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD'),
			'PrefDesc' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD_DESC'),
			'PrefChoose' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD_CHOOSE'),
			'changeIntro' =>
			  string('SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD_CHANGE'),
			'options' => {
				'1' => string('YES'),
				'0' => string('NO')
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

					# Forcibly re-lazify the whole database.
					lazifyDatabase(1);
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

		if ( defined( $clientMode{$client}{further_help_prompt} ) ) {
			push @$itemsRef,
			  $client->string( $clientMode{$client}{further_help_prompt} );
		}
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

			# Start playing the item selected (in the correct mode - play, add
			# or insert).
			lazyOnPlay( $client, $item, $addMode );
		},

		# What overlays are shown on lines 1 and 2.
		overlayRef => \&lazyOverlay,

		# To keep BrowseDB's create_mix handler happy.
		hierarchy => $clientMode{$client}{hierarchy},
		level     => $clientMode{$client}{level},
		descend   => 1,
	);

	# Make sure we pop back to the first result - most useful because of the
	# second-row help that is included because it might confuse the user to
	# see that when the re-enter the search mode (SlimServer will try to resume
	# the mode on the same row that it was last on).
	if ( length( $clientMode{$client}{search_performed} ) == 0 ) {
		$params{initialValue} = $itemsRef->[0];
	}

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

# Function to return the overlay information for browse results - this is used
# for both normal lazy search results as well as for keyword search results.
sub lazyOverlay {
	my ( $client, $item ) = @_;
	my $listRef = $client->modeParam('listRef');
	my $l1      = undef;
	my $l2      = undef;

	# If we've a pending search then we have an overlay on line 1.
	if ( $clientMode{$client}{search_pending} ) {
		$l1 = '*';
	} elsif ( ( length( $clientMode{$client}{search_performed} ) > 0 )
		&& ( scalar(@$listRef) != 0 ) )
	{

		# MusicMagic/MoodLogic overlay - pinched from BrowseDB.
		my $Imports = Slim::Music::Import->importers;

		for my $import ( keys %{$Imports} ) {
			if ( $import->can('mixable') && $import->mixable($item) ) {
				$l1 = Slim::Display::Display::symbol('mixable');
			}
		}
	}

	# See if there might be an overlay on line 2.
	if (   ( length( $clientMode{$client}{search_performed} ) > 0 )
		&& ( scalar(@$listRef) != 0 ) )
	{

		# 'All' items don't have an arrow; the others do. Since the
		# 'all' entry is the only one that isn't an object that
		# makes it a simple test.
		if ( blessed($item)
			&& ( $clientMode{$client}{search_type} eq 'Track' ) )
		{
			$l2 = Slim::Display::Display::symbol('notesymbol');
		} elsif ( blessed($item) ) {
			$l2 = Slim::Display::Display::symbol('rightarrow');
		}
	}

	return [ $l1, $l2 ];
}

# Subroutine to extract the text to show for the browse/search. Most of this
# is stock here, we just need to identify the actual text column name from the
# clientMode hash to get the actual text, as that differs for each item class.
sub lazyGetText {
	my ( $client, $item ) = @_;

	if ( length( $clientMode{$client}{search_performed} ) == 0 ) {
		return $item;
	} else {
		my $listRef = $client->modeParam('listRef');
		if ( scalar(@$listRef) == 0 ) {
			return $client->string('EMPTY');
		} else {
			if ( ref($item) eq 'Slim::Schema::Track' ) {
				return Slim::Music::Info::standardTitle( $client, $item->url );
			} else {
				return $item->name;
			}
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
	if (
		(
			   ( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD )
			&& ( maxKeywordLength($searchText) > LAZYSEARCH_MINLENGTH_MIN )
			&& ( keywordMatchText( $client, 0, $searchText ) ne
				$clientMode{$client}{search_performed} )
		)
		|| (   ( $clientMode{$client}{search_type} ne SEARCH_TYPE_KEYWORD )
			&& ( length( $clientMode{$client}{search_performed} ) == 0 )
			&& ( length($searchText) >= LAZYSEARCH_MINLENGTH_MIN ) )
	  )
	{
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
	my $inSearch     = 0;       #@@TODO@@
	my $gotoLazy     = 0;
	my $gotoCategory = undef;

	my $searchBehaviour =
	  Slim::Utils::Prefs::get('plugin-lazysearch2-hooksearchbutton');

	if ( !$initialised ) {

		# We never intercept SEARCH if the plugin isn't initialised.
		$gotoLazy = 0;
	} elsif (
		( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_MENU )
		|| ( ( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_KEYWORD )
			&& !keywordSearchEnabled() )
	  )
	{

		# Normal operation - enter lazy search as long as we're not already
		# in it, in which case we go to original search (allows double-search
		# to get back to the old mode).
		$gotoLazy = !$inLazySearch || 0;
	} elsif ( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_STANDARD ) {
		if ($inSearch) {

			# If in original search mode we always enter lazy search.
			$gotoLazy = 1;
		} else {

			# Go into the standard search.
			$gotoLazy = 0;
		}
	} elsif ( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_ARTIST ) {
		$gotoCategory = '{ARTISTS}';
	} elsif ( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_ALBUM ) {
		$gotoCategory = '{ALBUMS}';
	} elsif ( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_GENRE ) {
		$gotoCategory = '{GENRES}';
	} elsif ( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_TRACK ) {
		$gotoCategory = '{SONGS}';
	} elsif ( $searchBehaviour == LAZYSEARCH_SEARCHBUTTON_KEYWORD ) {
		$gotoCategory = '{KEYWORD_MENU_ITEM}';
	}

	if ( defined $gotoCategory ) {

		# This works by first entering the category menu, then immediately
		# entering the appropriate search category. This is done so when the
		# user presses LEFT he gets back to the category menu.
		enterCategoryMenu($client);
		enterCategoryItem( $client, $gotoCategory );

	} else {
		if ($gotoLazy) {
			enterCategoryMenu($client);
		} else {

			# Into the normal search menu.
			Slim::Buttons::Home::jumpToMenu( $client, "SEARCH" );
		}
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
	my $listRef = $client->modeParam('listRef');
	if ( scalar(@$listRef) == 0 ) {
		$client->bumpRight();
	} else {

		# Only allow right if we've performed a search.
		if (   ( length( $clientMode{$client}{search_performed} ) > 0 )
			&& ( blessed($item) ) )
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

	# Function that will return all tracks for the given item - used for
	# handling both individual entries and ALL entries.
	my $searchTracksFunction = $clientMode{$client}{search_tracks};

	# Cancel any pending timer.
	cancelPendingSearch($client);

	# If no list loaded (eg search returned nothing), or
	# user has not entered enough text yet, then ignore the
	# command.
	my $listRef = $client->modeParam('listRef');
	if ( length( $clientMode{$client}{search_performed} ) == 0 ) {
		return;
	}

	# If we're on the keyword hierarchy then the function is dependent on the
	# level of the item we're on.
	if ( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD ) {
		my $mode = $client->param("modeName");
		$_ = $mode;
		my ($level) = /^.*:(.*):.*$/;
		if ( !( $level =~ /^-?\d/ ) ) {
			$level = 1;
		}
		if ( $level == 1 ) {
			$searchTracksFunction = \&searchTracksForArtist;
		} elsif ( $level == 2 ) {
			$searchTracksFunction = \&searchTracksForAlbum;
		} else {
			$searchTracksFunction = \&searchTracksForTrack;
		}
	}

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
		if ( blessed($item) ) {
			$line2 = $item->name;
		} else {
			my $strToken = $clientMode{$client}{all_entry};
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
	if ( blessed($item) ) {
		my $id = $item->id;

		$::d_plugins
		  && Slim::Utils::Misc::msg(
"LazySearch2: PLAY/ADD/INSERT pressed on '$clientMode{$client}{search_type}' search results (id $id), addMode=$addMode\n"
		  );

		@playItems = &$searchTracksFunction($id);
	} else {

		$::d_plugins
		  && Slim::Utils::Misc::msg(
			"LazySearch2: All for '$clientMode{$client}{search_type}' chosen\n"
		  );

		for $item (@$listRef) {

			# Don't try to search for the 'all items' entry.
			next if !blessed($item);

			# Find the tracks by this artist.
			my @tracks = &$searchTracksFunction( $item->id );

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

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
	my $item      = $items->[$listIndex];

	# Map the scroll number (the method invoked by the INPUT.Choice button
	# the lazy browse mode is based on), to a real number character.
	my $numberKey = $numberScrollMap{$method};

	# We ignore zero here since we need to differentiate between a normal
	# zero button press and a zero button press-and-hold. That is done by
	# handling the two types of zero button press in keywordSepHandler and
	# zeroButtonHandler.
	if ( $numberKey ne '0' ) {
		addLazySearchCharacter( $client, $item, $numberKey );
	}
}

# Adds a single character to the current search defined for that player.
sub addLazySearchCharacter {
	my ( $client, $item, $character ) = @_;

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
	my ( $client, $method ) = @_;

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
	my $item      = $items->[$listIndex];

	# Whether this is a keyword search.
	my $keywordSearch =
	  ( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD );

	if ($keywordSearch) {

		# Add the separator character to the search string.
		addLazySearchCharacter( $client, $item, KEYWORD_SEPARATOR_CHARACTER );
	} else {

		# We're not in a keyword search so handle it as the normal zero
		# character.
		zeroButtonHandler( $client, $method );
	}
}

# Adds a zero to the search string for the player. This is separate to all
# the other number handlers because it's the only way we can tell the
# difference between a normal press and a press-n-hold.
sub zeroButtonHandler {
	my ( $client, $method ) = @_;

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
	my $item      = $items->[$listIndex];

	# Simply add a zero to the end.
	addLazySearchCharacter( $client, $item, '0' );
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
	my $client          = shift;
	my $searchText      = $clientMode{$client}{search_text};
	my $minSearchLength = $clientMode{$client}{min_search_length};

	# Schedule a timer. Any existing one is cancelled first as we only allow
	# one outstanding one for this player.
	cancelPendingSearch($client);

	# Whether this is a keyword search.
	my $keywordSearch =
	  ( $clientMode{$client}{search_type} eq SEARCH_TYPE_KEYWORD );
	my $scheduleSearch = 0;

	if ($keywordSearch) {
		my $maxKeywordLength = maxKeywordLength($searchText);
		$scheduleSearch = $maxKeywordLength >= $minSearchLength;
	} else {
		$scheduleSearch = ( ( length $searchText ) >= $minSearchLength );
	}

	# If we have a search scheduled then set the timer.
	if ($scheduleSearch) {
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time() + Slim::Utils::Prefs::get("displaytexttimeout"),
			\&onFindTimer,
			$client
		);

		# Flag the client has a pending search (this causes the display
		# overlay hint).
		$clientMode{$client}{search_pending} = 1;
	} else {
		$clientMode{$client}{search_pending} = 0;
	}
}

# Remove any outstanding lazy search timer. This is used when either leaving
# the search mode altogether, or when another key has been entered by the user
# (as a new later search will be scheduled instead).
sub cancelPendingSearch($) {
	my $client = shift;

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

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
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
			$searchText = keywordMatchText( $client, 0, $searchText );
		}

		$client->showBriefly(
			{
				'line1' =>
				  sprintf( $client->string('LINE1_SEARCHING'), $searchText )
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

# Perform the artist search.
sub performArtistSearch($$) {
	my $client     = shift;
	my $searchText = shift;
	my $condition  = undef;

	# We restrict the search to include artists related in the roles the
	# user wants (set through SlimServer preferences).
	my $roles = Slim::Schema->artistOnlyRoles('TRACKARTIST');
	if ($roles) {
		$condition->{'role'} = { 'in' => $roles };
	}
	$condition->{'customsearch'} = { 'like', buildFind( $searchText, 0 ) };

	my $searchResults =
	  Slim::Schema->resultset('ContributorAlbum')->search_related(
		'contributor',
		$condition,
		{
			columns =>
			  [ 'id', 'name', 'moodlogic_mixable', 'musicmagic_mixable' ],
			order_by => 'name'
		}
	  )->distinct;

	return $searchResults;
}

# Perform the album search.
sub performAlbumSearch($$) {
	my $client     = shift;
	my $searchText = shift;

	my $condition = undef;
	$condition->{'customsearch'} = { 'like', buildFind( $searchText, 0 ) };

	my $searchResults = Slim::Schema->resultset('Album')->search(
		$condition,
		{
			columns  => [ 'id', 'title', 'musicmagic_mixable' ],
			order_by => 'title'
		}
	);

	return $searchResults;
}

# Perform the genre search.
sub performGenreSearch($$) {
	my $client     = shift;
	my $searchText = shift;

	my $condition = undef;
	$condition->{'customsearch'} = { 'like', buildFind( $searchText, 0 ) };

	my $searchResults = Slim::Schema->resultset('Genre')->search(
		$condition,
		{
			columns =>
			  [ 'id', 'name', 'moodlogic_mixable', 'musicmagic_mixable' ],
			order_by => 'name'
		}
	);

	return $searchResults;
}

# Perform the track search.
sub performTrackSearch($$) {
	my $client     = shift;
	my $searchText = shift;

	my $condition = undef;
	$condition->{'customsearch'} = { 'like', buildFind( $searchText, 1 ) };

	my $searchResults = Slim::Schema->resultset('Track')->search(
		$condition,
		{
			columns => [
				'id',  'title',
				'url', 'moodlogic_mixable',
				'musicmagic_mixable'
			],
			order_by => 'title'
		}
	);

	return $searchResults;
}

# Perform the lazy search for a single item type (artist etc). This will be
# called from the search timer for non-keyword searches.
sub performTimedItemSearch($) {
	my $client = shift;

	# Actually perform the search. The method that does the searching is
	# as defined for the current search mode.
	my $searchText            = $clientMode{$client}{search_text};
	my $performSearchFunction = $clientMode{$client}{perform_search};
	my $searchResults         = &$performSearchFunction( $client, $searchText );

	# Each element of the listRef will be a hash with keys name and value.
	# This is true for artists, albums and tracks.
	my @searchItems = ();
	while ( my $searchItem = $searchResults->next ) {
		push @searchItems, $searchItem;
	}

	# If there are multiple results, show the 'all X' choice.
	if ( ( scalar(@searchItems) > 1 )
		&& defined( $clientMode{$client}{all_entry} ) )
	{
		push @searchItems,
		  {
			name  => $clientMode{$client}{all_entry},
			value => RESULT_ENTRY_ID_ALL,
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

	# Perform the search. The search will always be an unconstrained one
	# because it is at the top level (we've not yet pushed into contributor
	# or album to constrain the results).
	my $searchItems =
	  doKeywordSearch( $client, $clientMode{$client}{search_text},
		$forceSearch, 1, undef, undef );

	# Make these items available to the results-listing mode.
	$clientMode{$client}{search_items} = $searchItems;
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

	# Find the minimum length of keyword in the search text.
	my $maxKeywordLength = maxKeywordLength($searchText);

	# Keyword searches are separate 'keywords' separated by a space (lazy
	# encoded). We split those out here.
	my @keywordParts = split( KEYWORD_SEPARATOR_CHARACTER, $searchText );

	# Build the WHERE clause for the query, containing multiple AND clauses
	# and LIKE searches.
	my @andClause = ();
	foreach my $keyword (@keywordParts) {

		# We don't include very short keywords.
		next if ( length($keyword) < LAZYSEARCH_MINLENGTH_MIN );

		# We don't include short keywords unless the search is forced or
		# there is at least one that's beyond the minimum.
		next
		  if ( !$forceSearch
			&& ( length($keyword) < $clientMode{$client}{min_search_length} )
			&& ( $maxKeywordLength < $clientMode{$client}{min_search_length} )
		  );

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
	my $results;
	if ( $level == 1 ) {

		# We restrict the search to include artists related in the roles the
		# user wants (set through SlimServer preferences).
		my $artistOnlyRoles = Slim::Schema->artistOnlyRoles('TRACKARTIST');
		if ( !defined($artistOnlyRoles) ) {
			my @emptyArtists;
			$artistOnlyRoles = \@emptyArtists;
		}
		my @roles = @{$artistOnlyRoles};

		# If the user wants, remove the ALBUMARTIST role (ticket:42)
		if (
			!Slim::Utils::Prefs::get(
				'plugin-lazysearch2-keyword-return-albumartists')
		  )
		{
			my $albumArtistRole =
			  Slim::Schema::Contributor->typeToRole('ALBUMARTIST');
			@roles = grep { !/^$albumArtistRole$/ } @roles;
		}

		my $condition = undef;
		if ( scalar(@roles) > 0 ) {
			$condition->{'role'} = { 'in' => \@roles };
		}
		$results =
		  Slim::Schema->resultset('Track')->search( { -and => [@andClause] },
			{ order_by => 'namesort', distinct => 1 } )
		  ->search_related( 'contributorTracks', $condition )
		  ->search_related('contributor')->distinct;

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
		)->search_related('album')->distinct;

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
		)->distinct;
	}

	# Build up the item array.
	while ( my $item = $results->next ) {

		# Choice input mode expects each item to have a value.
		if ( !exists( $item->{'value'} ) ) {
			$item->{'value'} = $item->id;
		}

		push @items, $item;
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
	my $onPlay = $client->modeParam('onPlay');

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
	my $item      = $items->[$listIndex];

	&$onPlay( $client, $item, 0 );
}

# Create a mix (MusicMagic or MoodLogic) for the current item.
sub onCreateMixHandler {
	my ( $client, $method ) = @_;

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
	my $item      = $items->[$listIndex];

	$::d_plugins
	  && Slim::Utils::Misc::msg(
		'LazySearch2: Creating mix for item ' . $item->id . "\n" );

	# Punt on to the implementation in BrowseDB... This is not very elegant
	# as there shouldn't be any coupling between this and the BrowseDB mode.
	# However, there isn't another interface easily available so this is
	# the most straightforward way of avoiding having to duplicate all
	# the mixing code in the BrowseDB mode. I've raise bug #4451 to try
	# to address this in a future SlimServer version.
	my $createMix = Slim::Buttons::BrowseDB::getFunctions()->{'create_mix'};
	&$createMix($client);
}

# Call the play/insert/add handler (passing the parameter to differentiate
# which function is actually needed).
sub onAddHandler {
	my ( $client, $method ) = @_;
	my $onAdd = $client->modeParam('onPlay');

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
	my $item      = $items->[$listIndex];

	&$onAdd( $client, $item, 1 );
}

# Call the play/insert/add handler (passing the parameter to differentiate
# which function is actually needed).
sub onInsertHandler {
	my ( $client, $method ) = @_;
	my $onAdd = $client->modeParam('onPlay');

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
	my $item      = $items->[$listIndex];

	&$onAdd( $client, $item, 2 );
}

# Remove a single character from the search text. If this drops below the
# minimum the user is given the same prompts that he gets when he's entered
# less than the minimum search characters.
sub onDelCharHandler {
	my ( $client, $method ) = @_;

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
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

	my $listIndex = $client->modeParam('listIndex');
	my $items     = $client->modeParam('listRef');
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
	if (
		!Slim::Utils::Prefs::isDefined(
			'plugin-lazysearch2-keyword-return-albumartists')
	  )
	{
		Slim::Utils::Prefs::set(
			'plugin-lazysearch2-keyword-return-albumartists',
			LAZYSEARCH_KEYWORD_ALBUMARTISTS_DEFAULT
		);
	}

	# If the revision isn't yet in the preferences we set it to something
	# that's guaranteed to be different to the revision to force full
	# lazification.
	if ( !Slim::Utils::Prefs::isDefined('plugin-lazysearch2-revision') ) {
		Slim::Utils::Prefs::set( 'plugin-lazysearch2-revision', '-undefined-' );
	}
}

# This is called by SlimServer when a scan has finished. We use this to kick
# off lazification of the database once it's been populated with all music
# information.
sub scanDoneCallback($) {
	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: Received notification of end of rescan\n");

	# Check the plugin version that was present when we last lazified - if it
	# has changed then we're going to rebuild the database lazification in
	# case this different plugin revision has changed the format.
	my $force          = 0;
	my $prefRevision   = Slim::Utils::Prefs::get('plugin-lazysearch2-revision');
	my $pluginRevision = '$Revision$';

	if ( $prefRevision ne $pluginRevision ) {
		$::d_plugins
		  && Slim::Utils::Misc::msg(
"LazySearch2: Re-lazifying (plugin version changed from '$prefRevision' to '$pluginRevision'\n"
		  );
		$force = 1;
		Slim::Utils::Prefs::set( 'plugin-lazysearch2-revision',
			$pluginRevision );
	} else {
		$::d_plugins
		  && Slim::Utils::Misc::msg(
			"LazySearch2: Lazifying entries not already done\n");
	}

	lazifyDatabase($force);
}

# This function is called when the music database scan has finished. It
# identifies each artist, track and album that has not yet been encoded into
# lazy form and schedules a SlimServer background task to encode them.
sub lazifyDatabase($) {
	my $force = shift;

	# Make sure the encode queue is empty, and cancel any lazification
	# currently underway.
	%encodeQueues = ();
	Slim::Utils::Scheduler::remove_task( \&encodeTask );

	# Convert the albums table.
	lazifyDatabaseType( 'Album', 'title', $force, 0, 0, 0 );

	# Convert the artists (contributors) table.
	lazifyDatabaseType( 'Contributor', 'name', $force, 0, 0, 0 );

	# Convert the genres table.
	lazifyDatabaseType( 'Genre', 'name', $force, 0, 0, 0 );

	# Convert the songs (tracks) table.
	lazifyDatabaseType( 'Track', 'title', $force, 1, 1, 1 );

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
	my $force                 = shift;
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
	# table, too.
	my $extraJoins;
	$extraJoins = qw/ album / if $includeKeywordAlbum;

	# The query to find items to lazify takes into account keyword columns
	# in case that column was previously lazified before keywords were
	# introduced.
	my $whereClause;
	if ( !$force ) {
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
			rs              => $rs,
			source_attr     => $sourceAttr,
			remaining_items => $rsCount,
			keyword_artist  => $includeKeywordArtist,
			keyword_album   => $includeKeywordAlbum,
			keyword_track   => $includeKeywordTrack,
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

	# Bail out if the encode queue is empty. That can happen if another
	# lazification has been kicked off before this one has finished.
	if ( ( scalar keys %encodeQueues ) == 0 ) {
		return 0;
	}

	# Get a single type hash from the encode queue. It doesn't matter on the
	# order they come out of the hash.
	my $type           = ( keys %encodeQueues )[0];
	my $typeHashRef    = $encodeQueues{$type};
	my %typeHash       = %$typeHashRef;
	my $rs             = $typeHash{rs};
	my $sourceAttr     = $typeHash{source_attr};
	my $remainingItems = $typeHash{remaining_items};
	my $keywordArtist  = $typeHash{keyword_artist};
	my $keywordAlbum   = $typeHash{keyword_album};
	my $keywordTrack   = $typeHash{keyword_track};

	$::d_plugins
	  && Slim::Utils::Misc::msg( 'LazySearch2: EncodeTask - '
		  . $remainingItems
		  . " $type"
		  . "s remaining\n" );

	# Go through and encode each of the identified IDs. To maintain performance
	# we will bail out if this takes more than a defined time slice.

	# Find what contributor roles we consider as 'artists'. This takes account
	# of the user's preferences.
	my @roles = @{ Slim::Schema::artistOnlyRoles('TRACKARTIST') };

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
					my $contributors = $obj->contributorsOfType(@roles);
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

	$typeHashRef->{remaining_items} -= $rowsDone;

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
	if ( $out_string ne '0' ) {
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
	my $listRef = $client->modeParam('listRef');
	if ( scalar(@$listRef) == 0 ) {
		$client->bumpRight();
	} else {

		# Only allow right if we've performed a search.
		if (   ( length( $clientMode{$client}{search_performed} ) > 0 )
			&& ( blessed($item) ) )
		{
			my $name                  = $item->name;
			my $id                    = $item->id;
			my $contributorConstraint =
			  $clientMode{$client}{contributor_constraint};
			my $albumConstraint = $clientMode{$client}{album_constraint};
			my $hierarchy;

			# The current keyword level is part of the mode name.
			my $mode = $client->param("modeName");
			$_ = $mode;
			my ($level) = /^.*:(.*):.*$/;
			if ( !( $level =~ /^-?\d/ ) ) {
				$level = 1;
			}

			# Cancel any pending timer.
			cancelPendingSearch($client);

			# Track details are a special case.
			if ( $level < 3 ) {
				my $line1BrowseText;
				if ( $level == 1 ) {

					# Current item provides contributor constraint.
					$contributorConstraint = $id;
					$line1BrowseText       = '{LINE1_BROWSE_ALBUMS}';
					$hierarchy             = 'album,track';

					#					$client->modeParam('search_type') = 'Album';
				} elsif ( $level == 2 ) {

					# Current item provides album constraint.
					$albumConstraint = $id;
					$line1BrowseText = '{LINE1_BROWSE_TRACKS}';
					$hierarchy       = 'track';

					#					$client->modeParam('search_type') = 'Track';
				}

				# Remember these consraints in the mode.
				$clientMode{$client}{contributor_constraint} =
				  $contributorConstraint;
				$clientMode{$client}{album_constraint} = $albumConstraint;

				# The current unique text to make the mode unique.
				my $searchText  = $clientMode{$client}{search_text};
				my $forceSearch = $clientMode{$client}{search_forced};

				# Do the next level of keyword search.
				$level++;
				my $items =
				  doKeywordSearch( $client, $searchText, $forceSearch, $level,
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

					# The function to extract the title of each item.
					name => \&lazyGetText,

				 # A unique name for this mode that won't actually get displayed
				 # anywhere.
					modeName => "LAZYBROWSE_KEYWORD_MODE:$level:$searchText",

		  # An anonymous function that is called every time the user presses the
		  # RIGHT button.
					onRight => \&keywordOnRightHandler,

					onLeft => sub {
						$::d_plugins
						  && Slim::Utils::Misc::msg("LazySearch2: LEFT\n");
					},

				 # A handler that manages play/add/insert (differentiated by the
				 # last parameter).
					onPlay => sub {
						my ( $client, $item, $addMode ) = @_;

			  # Start playing the item selected (in the correct mode - play, add
			  # or insert).
						lazyOnPlay( $client, $item, $addMode );
					},

					# What overlays are shown on lines 1 and 2.
					overlayRef => \&lazyOverlay,

					# To keep BrowseDB's create_mix handler happy.
					hierarchy => $hierarchy,
					level     => 0,
					descend   => 1,
				);

	  # Use our INPUT.Choice-derived mode to show the menu and let it do all the
	  # hard work of displaying the list, moving it up and down, etc, etc.
				Slim::Buttons::Common::pushModeLeft( $client,
					LAZYBROWSE_KEYWORD_MODE, \%params );
			} else {

				# We're currently at the track level so push into track info
				# browse mode (which needs the track URL to be looked-up).
				$::d_plugins
				  && Slim::Utils::Misc::msg(
"LazySearch2: going into trackinfo mode for track ID=$id url="
					  . $item->url
					  . "\n" );
				Slim::Buttons::Common::pushModeLeft( $client, 'trackinfo',
					{ 'track' => $item } );
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
	if (
		!$hideShorties
		&& (
			substr( $searchText, length($searchText) - 1 ) eq
			KEYWORD_SEPARATOR_CHARACTER )
	  )
	{
		$text .= ',';
	}

	return $text;
}

# Called when one of the plugin preferences that affects the contents of the
# database has changed - this schedules a forced relazify of the database.
sub scheduleForcedRelazify {
	$::d_plugins
	  && Slim::Utils::Misc::msg(
"LazySearch2: Scheduling database relazification because of preference changes.\n"
	  );

	# Remove any existing scheduled callback.
	Slim::Utils::Timers::killOneTimer( 1, \&lazifyDatabase );

	# Schedule a relazification to take place in a short time. We do this
	# rather than kick it off immediately since this can be called several
	# times in quick succession if a number of database-affecting preferences
	# are changed. With this approach that causes a timer to be set and
	# cleared a few times with the final 'set' actually causing the
	# relazification to take place.
	Slim::Utils::Timers::setTimer( 1,
		Time::HiRes::time() + LAZYSEARCH_INITIAL_LAZIFY_DELAY,
		\&lazifyDatabase );
}

# Standard plugin function to return our message catalogue. Many thanks to the
# following for the translations:
#	DA	Jacob Bang (jacob@phonden.dk)
# 	DE	Dieter (dieterp@patente.de)
# 	ES	Néstor (nspedalieri@gmail.com)
#	FI	Kim B. Heino (b@bbbs.net)
#	NL	JPdS (jpdesmidt@gmail.com)
sub strings {
	return '
PLUGIN_LAZYSEARCH2
	DA	Lazy Search Music
	DE	Faulpelz-Suche
	EN	Lazy Search Music
	ES	Búsqueda Laxa de Música
	FI	Laiska musiikin haku
	NL	Lazy Search Music

PLUGIN_LAZYSEARCH2_TOPMENU
	DA	Lazy Search Music
	DE	Faulpelz-Suche
	EN	Lazy Search Music
	ES	Búsqueda Laxa de Música
	FI	Laiska musiikin haku
	NL	Lazy Search Music

LINE1_BROWSE
	DA	Lazy Search
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa
	FI	Laiska haku
	NL	Lazy Search

LINE1_SEARCHING
	DA	Søger efter \'%s\' ...
	DE	Suchen nach \'%s\' ...
	EN	Searching for \'%s\' ...
	ES	Buscando \'%s\' ...
	FI	Haen \'%s\'...
	NL	Zoekend naar \'%s\' ...

SHOWBRIEFLY_DISPLAY
	DA	Lazy Search
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa
	FI	Laiska haku
	NL	Lazy Search

LINE1_BROWSE_ARTISTS
	DA	Kunstner søgning
	DE	Passende Interpreten
	EN	Artists Matching
	ES	Artistas Coincidentes
	FI	Esittäjän haku
	NL	Gevonden Artiesten

LINE1_BROWSE_ARTISTS_EMPTY
	DA	Lazy Search efter kunstner
	DE	Faulpelz-Suche nach Interpreten
	EN	Lazy Search for Artists (press DOWN for help)
	ES	Búsqueda Laxa de Artistas
	FI	Laiska hae esittäjää
	NL	Lazy Search naar Artiesten

LINE1_BROWSE_ALBUMS
	DA	Matchende albums
	DE	Passende Alben
	EN	Albums Matching
	ES	Álbumes Coincidentes
	FI	Levyn nimen haku
	NL	Gevonden Albums

LINE1_BROWSE_ALBUMS_EMPTY
	DA	Lazy Search efter Album
	DE	Faulpelz-Suche nach Alben
	EN	Lazy Search for Albums (press DOWN for help)
	ES	Búsqueda Laxa de Álbumes
	FI	Laiska hae levyä
	NL	Lazy Search naar Albums

LINE1_BROWSE_TRACKS
	DA	Matchende sange
	DE	Passende Titel
	EN	Songs Matching
	ES	Canciones Coincidentes
	FI	Kappaleen haku
	NL	Gevonden Liedjes

LINE1_BROWSE_TRACKS_EMPTY
	DA	Lazy Search efter sange
	DE	Faulpelz-Suche nach Titel
	EN	Lazy Search for Songs (press DOWN for help)
	ES	Búsqueda Laxa de Canciones
	FI	Laiska hae kappaletta
	NL	Lazy Search naar Liedjes

LINE1_BROWSE_GENRES
	DA	Matchende genre
	DE	Passende Stilrichtungen
	EN	Genres Matching
	ES	Géneros Coincidentes
	FI	Lajin haku
	NL	Gevonden Genres

LINE1_BROWSE_GENRES_EMPTY
	DA	Lazy Search efter genre
	DE	Faulpelz-Suche nach Stilrichtungen
	EN	Lazy Search for Genres (press DOWN for help)
	ES	Búsqueda Laxa de Géneros
	FI	Laiska hae lajia
	NL	Lazy Search naar Genres

LINE2_ENTER_MORE_ARTISTS
	DA	Indtast kunstner
	DE	Interpret eingeben
	EN	Enter Artist Search
	ES	Ingresar Búsqueda de Artista
	FI	Kirjoita esittäjän nimi
	NL	Artiest zoekopdracht

LINE2_ENTER_MORE_ALBUMS
	DA	Indtast album
	DE	Album eingeben
	EN	Enter Album Search
	ES	Ingresar Búsqueda de Álbumes
	FI	Kirjoita levyn nimi
	NL	Album zoekopdracht

LINE2_ENTER_MORE_TRACKS
	DA	Indtast sang
	DE	Titel eingeben
	EN	Enter Song Search
	ES	Ingresar Búsqueda de Canciones
	FI	Kirjoita kappaleen nimi
	NL	Liedjes zoekopdracht
	
LINE2_ENTER_MORE_GENRES
	DA	Indtast genre
	DE	Stilrichtung eingeben
	EN	Enter Genre Search
	ES	Ingresar Búsqueda de Géneros
	FI	Kirjoita lajin nimi
	NL	Genre zoekopdracht

LINE2_BRIEF_HELP
	EN	Press the number key correponding to each letter you wish to enter - eg "786637" for "STONES". The search is performed automatically after entry.

SETUP_GROUP_PLUGIN_LAZYSEARCH2
	DA	Lazy Search
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa
	FI	Laiska haku
	NL	Lazy Search

SETUP_GROUP_PLUGIN_LAZYSEARCH2_DESC
	DA	Indstillingen nedenfor styrer ydelsen af lazy search afspillerens interface. Det er anbefalet at <i>Lazy Search Music</i> menuen fra dette plugin bliver tilføjet til en afspiller\'s home menu for at give nem adgang til dette plugin\'s funktioner. (Standard søgefunktionen vil også give adgang til denne funktionalitet).
	DE	Mit den unten angebenen Einstellungen kann definiert werden, wie sich die Player-Oberfläche der Faulpelz-Suche verhält. Es wird empfohlen, den Plugin-Menüpunkt <i>Faulpelz-Suche</i> zum Hauptmenü des Players hinzuzufügen, um einen einfachen Zugriff auf die Funktionen dieses Plugins zu ermöglichen (die Standard <i>SEARCH</i>-Taste auf der Fernbedienung ermöglicht ebenfalls den Zugang zu dieser Funktionalität).
	EN	The settings below control how the lazy searching player interface performs. It is suggested that the <i>Lazy Search Music</i> menu item from this plugin is added to a player\'s home menu to provide easy access to this plugin\'s functions (the standard remote <i>search</i> button will also access this functionality).
	ES	La configuración debajo controla cómo actúa la interface de búsqueda laxa del reproductor. Se sugiere que el item de menú <i>Búsqueda Laxa de Música</i> para este plugin se añada al menú inicial del reproductor para brindar un acceso fácil a las funciones del plugin (el botón <i>search</i> estándar del control remoto tendrá también acceso a esta funcionalidad).
	FI	Alla olevat asetukset vaikuttavat laiskan haun toimintaan. Kätevin tapa käyttää <i>laiskaa musiikin hakua</i> on lisätä se soittimen päävalikkoon soittimen asetuksista. Laiskaan hakuun pääsee myös painamalla kaukosäätimen <i>hae</i>-nappia.
	NL	Met de instellingen hieronder kan aangegeven worden hoe de Lazy SEARCH spelerinterface zich gedraagd. Het wordt aanbevolen de <i>Lazy SEARCH Muziek</i> functie aan het hoofdmenu van de speler toe te voegen, om zo een eenvoudige toegang tot de Lazy SEARCH plugin te verkrijgen (de normale <i>ZOEKknop</i> zal tevens deze functionaliteit verkrijgen).

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST
	DA	Minimum kunstnersøge længde
	DE	Mindestlänge für die Suche nach Interpreten
	EN	Minimum Artist Search Length
	ES	Mínima Longitud para Búsqueda de Artista
	FI	Esittäjä-haun lyhin pituus
	NL	Minimum Artiest zoekopdracht lengte

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_DESC
	DA	Søgning efter kunstner, album, genre eller sang med et kort antal tegn er ikke brugbart i praksis, da det vil resultere i et stort antal resultater. For at undgå at søgningen starter før et mere brugbart antal tegn bliver tastet, kan et minimum antal tegn specificeres her. Der er separate indstillinger for kunstner og album navn, genre og sangtitel. - Det anbefales at bruge 3 for kunstner, album og genre, og 4 for sangtitel.
	DE	Die Suche nach Interpreten, Alben, Stilrichtungen oder Titel mit einer zu kleinen Zahl von Zeichen ist nicht besonders sinnvoll, da sie zu viele Ergebnisse liefert. Um zu verhindern, dass eine Suche gestartet wird, bevor eine sinnvolle Anzahl von Zeichen eingeben wurde, ist eine Mindestzahl von Zeichen vorgegeben. Es gibt unterschiedliche Einstellungen für Interpretennamen, Albumnamen und Liedertitel - sinnvolle Voreinstellungen sind 3 für Interpreten und Alben und 4 für Lieder.
	EN	Searching for artists, albums, genres or songs with a short number of characters isn\'t very useful as it will return so many results. To prevent a search being performed until a more useful number of characters have been entered a mininum number of characters is specified here. There are separate settings for artists and album names, genres and song titles - a setting of 3 for artists, albums and genres, and 4 for songs, is a useful default.
	ES	El buscar artistas, álbumes, géneros o canciones con muy pocos caracteres no es muy útil, ya que retornará demasiados resultados. Para evitar que se efectúe una búsqueda hasta que se hayan ingresado más caracteres, se especifica aquí un número mínimo de ellos. Existen configuraciones individuales para búsqueda por nombre de artistas, nombre de álbumes, y nombre de canciones - valores por defecto apropiados son 3 caracteres para artistas, álbumes y géneros, y 4 caracteres para canciones.
	FI	Jos haet esittäjää, levyä, lajia tai kappaletta liian lyhyellä sanalla, niin saat usein liian monta vastausta. Alla voit määritellä montako kirjainta pitää kirjoittaa, että laiska haku aloittaa haun. Voit määritellä eri arvon eri hakutavoille. Oletusarvoisesti lyhin kirjainmäärä on esittäjälle, levylle ja lajille kolme, sekä kappaleen nimelle neljä.
	NL	Zoekend naar artiest, albums, genres of liederen met te weinig tekens is niet heel nuttig omdat het veel resultaten zal opleveren. Om te voorkomen dat een zoektocht verricht wordt voordat een nuttiger aantal tekens is ingevoerd, wordt hier een mininum aantal tekens gespecificeerd. Er zijn afzonderlijke instellingen voor artiest en album naam, genres en lied titels - een instelling van 3 voor artiest, albums en genres en 4 voor liederen, is een nuttige standaardwaarde.

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHOOSE
	DA	Minimum længde for kunstner søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Interpreten (2-9 Zeichen):
	EN	Minimum length for artist search (2-9 characters):
	ES	Mínima longitud para búsqueda de artista (2-9 caracteres):
	FI	Esittäjä-haun lyhin kirjainmäärä (2-9 kirjainta):
	NL	De minimumlengte voor Artiest zoekopdracht (2-9 tekens):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHANGE
	DA	Minimum længde for kunstner søgning ændret til:
	DE	Mindestlänge für die Suche nach Interpreten wurde geändert in:
	EN	Minimum length for artist search changed to:
	ES	Mínima longitud para búsqueda de artista cambió a:
	FI	Esittäjä-haun lyhin kirjainmäärä vaihdettiin arvoon:
	NL	De minimumlengte voor Artiest zoekopdracht is gewijzigd in:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM
	DA	Minimum længde for album søgning
	DE	Mindestlänge für die Suche nach Alben
	EN	Minimum Album Search Length
	ES	Mínima Longitud para Búsqueda de Álbum
	FI	Levy-haun lyhin pituus
	NL	Minimum Album zoekopdracht lengte
	
SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHOOSE
	DA	Minimum længde for album søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Alben (2-9 Zeichen):
	EN	Minimum length for album search (2-9 characters):
	ES	Mínima longitud para búsqueda de álbum (2-9 caracteres):
	FI	Levy-haun lyhin kirjainmäärä (2-9 kirjainta):
	NL	De minimumlengte voor Album zoekopdracht (2-9 tekens):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHANGE
	DA	Minimum længde for album søgning rettet til:
	DE	Mindestlänge für die Suche nach Alben wurde geändert in:
	EN	Minimum length for album search changed to:
	ES	Mínima longitud para búsqueda de álbum cambió a:
	FI	Lyvy-haun lyhin kirjainmäärä vaihdettiin arvoon:
	NL	De minimumlengte voor Album zoekopdracht is gewijzigd in:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK
	DA	Minimum længde for sang søgning
	DE	Mindestlänge für die Suche nach Titel
	EN	Minimum Song Search Length
	ES	Mínima Longitud para Búsqueda de Canción
	FI	Kappale-haun lyhin pituus
	NL	Minimum Liedjes zoekopdracht lengte

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHOOSE
	DA	Minimum længde for sang søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Titel (2-9 Zeichen):
	EN	Minimum length for song search (2-9 characters):
	ES	Mínima longitud para búsqueda de canción (2-9 caracteres):
	FI	Kappale-haun lyhin kirjainmäärä (2-9 kirjainta):
	NL	De minimumlengte voor Liedjes zoekopdracht (2-9 tekens):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHANGE
	DA	Minimum længde for sang søgning rettet til:
	DE	Mindestlänge für die Suche nach Titel wurde geändert in:
	EN	Minimum length for song search changed to:
	ES	Mínima longitud para búsqueda de canción cambió a:
	FI	Kappale-haun lyhin kirjainmäärä vaihdettiin arvoon:
	NL	De minimumlengte voor Liedjes zoekopdracht is gewijzigd in:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE
	DA	Minimum længde for sang søgning
	DE	Mindestlänge für die Suche nach Stilrichtungen
	EN	Minimum Genre Search Length
	ES	Mínima Longitud para Búsqueda de Género
	FI	Laji-haun lyhin pituus
	NL	Minimum Genre zoekopdracht lengte

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHOOSE
	DA	Minimum længde for genre søgning (2-9 tegn):
	DE	Mindestlänge für die Suche nach Stilrichtungen (2-9 Zeichen):
	EN	Minimum length for genre search (2-9 characters):
	ES	Mínima longitud para búsqueda de género (2-9 caracteres):
	FI	Laji-haun lyhin kirjainmäärä (2-9 kirjainta):
	NL	De minimumlengte voor Genre zoektocht (2-9 tekens):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHANGE
	DA	Minimum længde for genre søgning rettet til:
	DE	Mindestlänge für die Suche nach Stilrichtungen wurde geändert in:
	EN	Minimum length for genre search changed to:
	ES	Mínima longitud para búsqueda de género cambió a:
	FI	Laji-haun lyhin kirjainmäärä vaihdettiin arvoon:
	NL	De minimumlengte voor Genre zoektocht is gewijzigd in:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES
	DA	VENSTRE-knap opførsel
	DE	Verhalten der LINKS-Taste
	EN	LEFT Button Behaviour
	ES	Comportamiento del Botón IZQUIERDA
	FI	VASEN-napin toiminta
	NL	LINKERknop Gedrag

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_DESC
	DA	Du kan vælge hvordan VESTRE-knappen på fjernbetjæningen opfører sig når man trykker en søgetekst. VESTRE kan enten slette det sidst tastet tegn (for at rette en fejl), eller forlade søgeningen.
	DE	Man kann einstellen, wie sich die LINKS-Taste auf der Fernbedienung bei der Eingabe von Suchtext verhält. Mit der LINKS-Taste kann entweder das zuletzt eingegeben Zeichen gelöscht werden (z.B. um einen Fehler zu korrigieren) oder der Suchmodus beendet werden.
	EN	You can choose how the LEFT button on the remote control behaves when entering search text. LEFT can either delete the last character entered (eg to correct a mistake), or can exit the search mode altogether.
	ES	Se puede elegir como se comportará el boton IZQUIERDA del control remoto cuando se ingresa texto. IZQUIERDA puede o bien borrar el último caracter ingresado (por ej, para corregir un error), o bien puede abandonar el modo búsqueda.
	FI	Voit valita miten kaukosäätimen VASEN-nappi toimii kun kirjoitat hakua. VASEN voi olla joko viimeisen kirjaimen pyyhintä (esim. virheen korjaus), tai se voi poistua kokonaan hausta.
	NL	U kan kiezen hoe de LINKERknop op de afstandsbediening zich gedraagt tijdens het invoeren van een zoektekst. LINKERknop kan het laatst ingevoerde teken (om een fout te verbeteren) schrappen, of kan de zoek modus te verlaten.

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHOOSE
	DA	Ved tryk på VENSTRE under søgning:
	DE	Drücken der LINKS-Taste während einer Suche:
	EN	Pressing LEFT while entering a search:
	ES	Presionando IZQUIERDA mientras se ingresa una búsqueda:
	FI	VASEN-napin toiminta hakua kirjoitettaessa:
	NL	LINKERknop gebruikt in zoekmode:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHANGE
	DA	Tyk VENSTRE for at:
	DE	Drücken der LINKS-Taste wurde geändert in:
	EN	Pressing LEFT changed to:
	ES	Presionando IZQUIERDA cambió a:
	FI	VASEN-napin toiminta muutettu arvoon:
	NL	LINKERknop gewijzigd in:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_0
	DA	Forlade søgning
	DE	Beendet den Suchmodus
	EN	Exits the search mode
	ES	Abandona el modo búsqueda
	FI	Poistu hausta
	NL	Verlaat de zoekmode

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_1
	DA	Slette det sidst tastede tegn
	DE	Löscht das zuletzt eingegebene Zeichen
	EN	Deletes the last character entered
	ES	Borra los últimos caracteres ingresados
	FI	Poista viimeinen kirjain
	NL	Verwijder het laatst ingevoerde karakter

SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD
	DE	Stichwort-Suche und Album-Interpret
	EN	Keyword searching and artists behaviour
	FI	Sana-haku ja esittäjä

SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD_DESC
	DE	Je nachdem, wie man seine Alben mit "tags" versieht, kann es erwünscht oder unerwünscht sein, dass Album-Interpreten (der Inhalt des ALBUMARTIST tags) in der Liste der Interpreten, die zu einer Stichwort-Suche passen, angezeigt werden. Wenn man z.B. bei Samplern den Album-Interpreten auf "Various Artist" setzt, dann erwartet man diesen Wert nicht als Ergebnis einer Stichwort-Suche, da man an dem individuellen Interpreten des Liedes interessiert ist. Album-Interpreten nicht anzuzeigen ist die Voreinstellung.
	EN	Depending on how you tag your albums you may or may not want your album artists (the ALBUMARTIST tag) to be returned in the list of artists matching a keyword search. For example, if you set the album artist to "Various Artists" for your compilations then you won\'t expect that to be returned in keyword searches because it\'s the individual song artists that you\'re interested in. Not returning album artists is the default behaviour.
	FI	Riippuen siitä miten olet merkinnyt levysi, niin saatat haluta, että levyn esittäjä (ALBUMARTIST-merkintä) sisällytetään esittäjälistaan sana-haussa. Esimerkiksi, jos määrittelet kokoelmalevyn esittäjäksi "Various Artist", niin et luultavasti halua sisällyttää sitä esittäjälistaan, koska haluat löytää yksittäisen kappaleen esittäjän. Oletusarvo on pois päältä.

SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD_CHOOSE
	DE	Album-Interpreten im Ergebnis der Stichwort-Suche anzeigen:
	EN	Album artists included in keyword search results:
	FI	Levyn esittäjän sisällyttäminen sana-hakuun:

SETUP_PLUGIN_LAZYSEARCH2_IGNOREAAKEYWORD_CHANGE
	DE	Album-Interpreten im Ergebnis der Stichwort-Suche einschließen wurde geändert in:
	EN	Album artists returned in keyword searches changed to:
	FI	Levyn esittäjän sisällyttäminen sana-hakuun vaihdettu arvoon:

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON
	DA	SEARCH-knap opførsel
	DE	Verhalten der SEARCH-Taste
	EN	SEARCH Button Behaviour
	ES	Comportamiento del Botón SEARCH
	FI	HAKU-napin toiminta
	NL	ZOEKknop Gedrag

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_DESC
	DE	Mit dieser Einstellung kann man die SEARCH-Taste auf der Squeezebox/Transporter-Fernbedienung mit der Funktionalität der <i>Faulpelz-Suche</i> anstelle der Funktionalität der originalen <i>Suche</i> belegen. Mit weiteren Optionen kann man festlegen, dass mit der SEARCH-Taste unmittelbar ein gewählter Typ der Faulpelz-Suche ausgewählt wird. Dies spart Zeit, wenn man meistens diesen Typ verwenden möchte.
	EN	This setting allows the SEARCH button on the Squeezebox/Transporter remote control to be remapped to the <i>lazy search music</i> function instead of the original <i>search music</i> function. Further options allow the SEARCH button to immediately enter a chosen type of lazy search, which saves time if that\'s the type of search you prefer to use most often.
	FI	Tällä asetuksella voit muuttaa miten Squeezeboxin / Transporterin HAKU-nappi toimii. Painamalla sitä voit joko päästä <i>laiska musiikin haku</i>-valikkoon tai normaalin <i>haku</i>-valikkoon. Vaihtoehtona on myös, että HAKU-nappi aloittaa suoraan halutun laiskan haun tyylin, joka säästää aikaa, jos yleensä käytät juuri sitä hakutyyliä.
	NL	Met deze instelling kan de ZOEKknop op de Squeezebox afstandsbediening gewijzigd worden door <i>de Lazy SEARCH muziek</i> functie in plaats van het originele <i>Zoek muziek</i> functie. Door deze instelling te activeren deze ZOEKknop wijzigind doorgevoerd worden zonder wijziging van de <i>Default.map</i> of <i>Custom.map</i>. Merk op dat de veranderingen in van deze instelling niet van kracht wordt totdat de plugin wordt herladen (b.v. door SlimServer opnieuw te starten).

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHOOSE
	DA	Tryk på SEARCH knappen på Squeezebox/Transporter fjernbetjæningen:
	DE	Drücken der SEARCH-Taste auf der Squeezebox/Transporter-Fernbedienung:
	EN	Pressing SEARCH on the Squeezebox/Transporter remote control:
	ES	Presionando SEARCH en el remoto de Squeezebox/Transporter:
	FI	Squeezeboxin / Transporterin kaukosäätimen HAKU-nappin toiminta:
	NL	ZOEKknop op de Squeezebox afstandsbediening:

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHANGE
	DA	Tryk på SEARCH går til:
	DE	Drücken der SEARCH-Taste wurde geändert in:
	EN	Pressing SEARCH changed to:
	ES	Presionando SEARCH cambió a:
	FI	HAKU-napin toiminta muutettu arvoon:
	NL	ZOEKknop gewijzigd in:

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_0
	DA	Standard søgning
	DE	Zeigt das Menü der Standardsuche an
	EN	Accesses the standard search music menu
	ES	Accede al menú de búsqueda musical estándar
	FI	Normaali haku
	NL	Geeft toegang tot het normale zoek muziek menu

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_1
	DA	Lazy Search menuen.
	DE	Zeigt das Menü der Faulpelz-Suche an
	EN	Accesses the lazy search music menu
	ES	Accede al menú de búsqueda musical laxa
	FI	Laiska musiikin haku
	NL	Geeft toegang tot het Lazy Search muziek menu

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_2
	DE	Startet eine Faulpelz-Suche nach einem Interpret
	EN	Begins an artist lazy search
	FI	Aloittaa esittäjän laiskan haun

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_3
	DE	Startet eine Faulpelz-Suche nach einem Album
	EN	Begins an album lazy search
	FI	Aloittaa levyn laiskan haun

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_4
	DE	Startet eine Faulpelz-Suche nach einer Stilrichtung
	EN	Begins a genre lazy search
	FI	Aloittaa lajin laiskan haun

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_5
	DE	Startet eine Faulpelz-Suche nach einem Lied
	EN	Begins a song lazy search
	FI	Aloittaa kappaleen laiskan haun

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_6
	DE	Startet eine Faulpelz-Suche nach einem Stichwort
	EN	Begins a keyword lazy search
	FI	Aloittaa sanan laiskan haun

SCAN_IN_PROGRESS
	DA	Note: dit musik biblioteket bliver lige nu scannet
	DE	Hinweis: Die Musikdatenbank wird gerade durchsucht
	EN	Note: music library scan in progress
	ES	Nota: se está recopilando la colección musical
	FI	Huomautus: Musiikkikirjaston luominen on käynnissä
	NL	Merk op: muziek bibliotheek wordt nu ingelezen

SCAN_IN_PROGRESS_DBL
	DA	Note: scanner
	DE	Hinweis: Suche läuft
	EN	Note: scanning
	ES	Nota: recopilando
	FI	Huomautus: etsin
	NL	Merk op: Inlezen...

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW
	DA	Gennemtving opbygningen af Lazy Seach indexet
	DE	Indexerzeugung für die Faulpelz-Suche
	EN	Force Lazy Search Index Build
	ES	Forzar Creación de Índice para Búsqueda Laxa
	FI	Käynnistä laiskan haun indeksointi
	NL	Forceer de Lazy Search Indexering

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_DESC
	DA	Dette plugin er lavet til at vedligeholde Lazy Search indexet når det er nødvendigt. Derfor er det ikke, under normale omstændigheder, nødvendigt at tivnge re-index igennem. Du kan dog, hvis du vil være sikker på at indexet er opbygget korrekt, trykke denne knap. Dette er primært en debug funktion.
	DE	Das Plugin erzeugt den Index für die Faulpelz-Suche, wenn dies erforderlich ist. Normalerweise ist daher keine extra Pflege der Datenbank notwendig. Falls Sie sichergehen wollen, dass der Index der Faulpelz-Suche korrekt erzeugt wurde, können Sie die folgende Schaltfläche anklicken. Aber in Anbetracht dessen, dass dies nie erforderlich sein sollte, ist dies in erster Linie eine Hilfe für die Fehlersuche.
	EN	The plugin is designed to build the lazy search index whenever required and so, under normal circumstances, no extra database maintenance is required. If you wish to ensure that the lazy search index has been correctly built you can press the following button, but given that it should never be necessary this is primarily a debugging aid.
	ES	El plugin se ha diseñado para construir el índice de búsqueda laxa cuando sea que se requiera. Por lo tanto, en circunstancias normales, no se requiere mantenimiento extra de la base de datos. Si se quiere estar seguro que el índice de búsqueda laxa ha sido construido correctamente, se puede presionar el siguiente botón (aunque dado que nunca debería ser necesario reconstruirlo manualmente se lo incluye aquí simplemente como una ayuda para la depuración).
	FI	Normaalisti laiska haku huomaa itse milloin sen pitää luoda hakuindeksi uudelleen. Jos haluat varmistaa, että laiskan haun hakuindeksi on varmasti ajan tasalla, niin voit tehdä sen painamalla alla olevaa nappia. Sitä ei normaalisti tarvitse tehdä koskaan, joten tämä on lähinnä tarkoitettu vian etsintään.
	NL	De plugin is zo ontworpen dat de Lazy Search index, wanneer het noodzakelijk is aangemaakt wordt, onder normale omstandigheden, is er geen extra  onderhoud vereist. Indien u er zeker van wilt zijn dat de Lazy Search index correct is ingelezen, kan u de volgende knop gebruiken, maar gegeven dat, het zal nooit noodzakelijk deze knop te moeten gebruiken, het is hoofdzakelijk een debugging tool.

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_CHANGE
	DA	Lazy Search indexet bliver du genopbygget
	DE	Die Erzeugung des Index für die Faulpelz-Suche hat begonnen
	EN	Lazy search index build has been started
	ES	La creación del índice para búsqueda laxa ha comenzado
	FI	Laiskan haun indeksointi on käynnistetty
	NL	Lazy Search indexering is gestart

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_BUTTON
	DA	Start opbygning af Lazy Search indexet
	DE	Jetzt den Index für die Faulpelz-Suche erzeugen
	EN	Build Lazy Search Index Now
	ES	Crear Índice de Búsqueda Laxa Ahora
	FI	Luo laiskan haun indeksi nyt
	NL	Creëer de Lazy Search Index

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_ARTISTS_HEAD
	DA	Keyword søgning
	DE	Stichwort-Suche
	EN	Keyword Search
	FI	Sana-haku

SETUP_PLUGIN_LAZYSEARCH2_KEYWORD_OPTIONS_DESC
	DA	Keyword søgning giver mulighed for at søge mellem flere kategorier, og på den måde finde albums, kunstnere og sangtitler som matcher et eller flere <i>keywords</i> i deres titel. Dette kan være brugbart, f.eks. med klassisk musik samlinger som både kan have kunster, forfatter og udøver inkluderet i sangtitlen og albumkunstneren eller sangkunstneren idet funktionen giver mulighed for at søge ligegyldigt hvordan sangens tags er opbygget. Følgende indstillinger giver dig mulighed for at specificere hvilke kategorier der bliver inkluderet i keyword søgningen. Hvis alle kattegorier er slået fra, vil keyword søgnings muligheden ikke optræde i afspillerens Lazy Search menu.
	DE	Die Stichwort-Suche ermöglicht die Suche über mehrere Kategorien gleichzeitig, d.h. man kann Alben, Interpreten und Lieder finden, die ein oder mehrere <i>Stichworte</i> enthalten. Dies ist z.B. bei klassischen Musiksammlungen hilfreich, bei denen Interpreten, Komponisten und Dirigenten in den Liedertiteln, im Album-Interpret oder im Lied-Interpret enthalten sind, weil du deine Musik suchen und finden kannst unabhängig davon, wie die Lieder mit "Tags" versehen sind. Mit den folgenden Optionen kannst du einstellen, welche Kategorien in die Stichwort-Suche einbezogen werden. Wenn keine Kategorien ausgewählt ist, erscheint die Anzeige der Stichwort-Suche nicht im Faulpelz-Menü am Player.
	EN	Keyword search allows searching across multiple categories, finding albums, artists and songs that match one or more <i>keywords</i> within their titles. This may be useful, for example, with classical music collections which can have artists, composers and performers included in the song titles as well as in the album artist and song artist because it lets you search and find your music no matter how the songs were tagged. The following settings allow you to specify which categories will be included in keyword searches. If all categories are disabled then the keyword search option won\'t appear in the player\'s Lazy Search menu at all.
	FI	Sana-haulla voit etsiä samalla kertaa monesta eri kategoriasta. Voit yhdellä haulla etsiä <i>sanoja</i> levyn, esittäjän tai kappaleen nimestä. Tämä on käytännöllistä esimerkiksi klassisessa musiikissa: esittäjä tai säveltäjä voi olla merkitty joko kappaleen, levyn tai esittäjän kohdalle. Sana-haulla voit etsiä niistä kaikista. Seuraavilla asetuksilla voit määritellä mistä asioista haku tehdään. Jos kaikki ovat pois päältä, niin sana-hakua ei näytetä ollenkaan laiskan haun valikossa.

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
	EN	Lazy Search for Keywords (press DOWN for help)
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
