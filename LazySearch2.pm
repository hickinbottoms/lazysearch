# LazySearch2 plugin for SlimServer by Stuart Hickinbottom 2006
#
# $Id$
#
# This code is derived from code with the following copyright message:
#
# SlimServer Copyright (c) 2001-2005 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# This is a plugin to implement lazy searching using the SqueezeBox remote
# control.
#
# For further details see:
# http://hickinbottom.demon.co.uk/SlimServer/lazy_searching2.htm

use strict;
use warnings;

package Plugins::LazySearch2;

use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Text;
use Slim::Utils::Timers;
use Time::HiRes;

# Name of this plugin - used for various global things to prevent clashes with
# other plugins.
use constant PLUGIN_NAME => 'PLUGIN_LAZYSEARCH2';

# Name of the menu item that is expected to be added to the home menu.
use constant LAZYSEARCH_HOME_MENUITEM => 'LazySearch2';

# Mode for main lazy search mode and lazy search menu.
use constant LAZYSEARCH_TOP_MODE           => 'PLUGIN_LAZYSEARCH2.topmode';
use constant LAZYSEARCH_CATEGORY_MENU_MODE => 'PLUGIN_LAZYSEARCH2.categorymenu';
use constant LAZYBROWSE_MODE               => 'PLUGIN_LAZYSEARCH2.browsemode';

# Preference ranges and defaults.
use constant LAZYSEARCH_MINLENGTH_MIN            => 2;
use constant LAZYSEARCH_MINLENGTH_MAX            => 9;
use constant LAZYSEARCH_MINLENGTH_ARTIST_DEFAULT => 3;
use constant LAZYSEARCH_MINLENGTH_ALBUM_DEFAULT  => 3;
use constant LAZYSEARCH_MINLENGTH_GENRE_DEFAULT  => 3;
use constant LAZYSEARCH_MINLENGTH_TRACK_DEFAULT  => 4;
use constant LAZYSEARCH_LEFTDELETES_DEFAULT      => 1;
use constant LAZYSEARCH_HOOKSEARCHBUTTON_DEFAULT => 1;
use constant LAZYSEARCH_ALLENTRIES_DEFAULT       => 1;

# Constants that control the background lazy search database encoding.
use constant LAZYSEARCH_ENCODE_MAX_QUANTA    => 0.4;
use constant LAZYSEARCH_INITIAL_LAZIFY_DELAY => 5;

# Special item IDs that are used to recognise non-result items in the
# search results list.
use constant RESULT_ENTRY_ID_ALL => -1;

# Export the version to the server (as a subversion keyword).
use vars qw($VERSION);
$VERSION = 'trunk-6.5-r@@REVISION@@';

# This hash-of-hashes contains state information on the current lazy search for
# each player. The first hash index is the player (eg $clientMode{$client}),
# and the second a 'parameter' for that player.
# The elements of the second hash are as follows:
#	search_type:	This is the item type being searched for, and can be one
#					of Track, Contributor, Album or Genre.
#	text_col:		The column of the search_type row that holds the text that
#					will be shown on the player as the result of the search.
#	search_text:	The current search text (ie the number keys on the remote
#					control).
#	search_performed:	A Boolean flag indicating whether a search has yet
#						been performed (and hence whether search_items has
#						the search results).
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
#	search_items:		Function reference to a method that will return all
#						the tracks corresponding to the found item (the item
#						is passed as a parameter to this method). This is used
#						to find the tracks that will be added/replaced in the
#						playlist when ADD/INSERT/PLAY is pressed.
my %clientMode = ();

# Hash of outstanding database objects that are to be lazy-encoded. This is
# present to allow a background task to work on them in chunks, preventing
# performance problems caused by the server going busy for a long time.
# The structure of the hash is as follows:
# 	type => { lazify_sub => XX, ids => (YY) }
# Where:
# 	type is 'album', 'artist', 'genre' or 'track'.
# 	XX is a subroutine that will update the appropriate 'search' attribute of
# 		the object
# 	YY is a list (array) of IDs to process.
my %encodeQueues = ();

# Flag to protect against multiple initialisation or shutdown
my $initialised = 0;

# Flag to indicate whether we're currently applying 'lazification' to the
# database. Used to detect and warn the user of this when entering
# lazy search mode while this is in progress.
my $lazifying_database = 0;

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

	# Use INPUT.Choice to display the top-level search menu choices.
	my %params = (

		# The header (first line) to display whilst in this mode.
		header => '{LINE1_BROWSE} {count}',

		# A reference to the list of items to display.
		listRef => [qw({ARTISTS} {ALBUMS} {GENRES} {SONGS})],

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
			$clientMode{$client}{search_performed} = 0;
			$clientMode{$client}{search_pending}   = 0;

			if ( $item eq '{ARTISTS}' ) {
				$clientMode{$client}{search_type}  = 'Contributor';
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
				$clientMode{$client}{onright} = sub {
					my ( $client, $item ) = @_;

					# Browse albums by this artist.
					Slim::Buttons::Common::pushModeLeft(
						$client,
						'browsedb',
						{
							'hierarchy'    => 'contributor,album,track',
							'level'        => 1,
							'findCriteria' =>
							  { 'contributor.id' => $item->{'id'} },
						}
					);
				};
				$clientMode{$client}{search_tracks} = sub {
					my $id = shift;
					return Slim::Schema->search( 'ContributorTrack',
						{ 'me.contributor' => $id } )->search_related(
						'track', undef,
						{
							'order_by' =>
'track.album, track.disc, track.tracknum, track.titlesort'
						}
						)->all;
				};
				setSearchBrowseMode( $client, $item, 0 );
			} elsif ( $item eq '{ALBUMS}' ) {
				$clientMode{$client}{search_type}  = 'Album';
				$clientMode{$client}{text_col}     = 'title';
				$clientMode{$client}{all_entry}    = '{ALL_ALBUMS}';
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_ALBUMS}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_ALBUMS_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_ALBUMS';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-album');
				$clientMode{$client}{onright} = sub {
					my ( $client, $item ) = @_;

					# Browse tracks for this album.
					Slim::Buttons::Common::pushModeLeft(
						$client,
						'browsedb',
						{
							'hierarchy'    => 'album,track',
							'level'        => 1,
							'findCriteria' => { 'album.id' => $item->{'id'} },
						}
					);
				};
				$clientMode{$client}{search_tracks} = sub {
					my $id = shift;
					return Slim::Schema->search(
						'track',
						{ 'album'    => $id },
						{ 'order_by' => 'me.disc, me.tracknum, me.titlesort' }
					)->all;
				};
				setSearchBrowseMode( $client, $item, 0 );
			} elsif ( $item eq '{GENRES}' ) {
				$clientMode{$client}{search_type}  = 'Genre';
				$clientMode{$client}{text_col}     = 'name';
				$clientMode{$client}{all_entry}    = undef;
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_GENRES}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_GENRES_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_GENRES';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-genre');
				$clientMode{$client}{onright} = sub {
					my ( $client, $item ) = @_;

					# Browse artists by this genre.
					Slim::Buttons::Common::pushModeLeft(
						$client,
						'browsedb',
						{
							'hierarchy'    => 'genre,contributor,album,track',
							'level'        => 1,
							'findCriteria' => { 'genre.id' => $item->{'id'} },
						}
					);
				};
				$clientMode{$client}{search_tracks} = sub {
					my $id = shift;
					return Slim::Schema->search( 'GenreTrack',
						{ 'me.genre' => $id } )->search_related(
						'track', undef,
						{
							'order_by' =>
'track.album, track.disc, track.tracknum, track.titlesort'
						}
						)->all;
				};
				setSearchBrowseMode( $client, $item, 0 );
			} elsif ( $item eq '{SONGS}' ) {
				$clientMode{$client}{search_type}  = 'Track';
				$clientMode{$client}{text_col}     = 'title';
				$clientMode{$client}{all_entry}    = '{ALL_SONGS}';
				$clientMode{$client}{player_title} = '{LINE1_BROWSE_TRACKS}';
				$clientMode{$client}{player_title_empty} =
				  '{LINE1_BROWSE_TRACKS_EMPTY}';
				$clientMode{$client}{enter_more_prompt} =
				  'LINE2_ENTER_MORE_TRACKS';
				$clientMode{$client}{min_search_length} =
				  Slim::Utils::Prefs::get('plugin-lazysearch2-minlength-track');
				$clientMode{$client}{onright} = sub {
					my ( $client, $item ) = @_;

					# Push into the trackinfo mode for this one track.
					my $track =
					  Slim::Schema->rs('Track')->find( $item->{'id'} );
					Slim::Buttons::Common::pushModeLeft( $client, 'trackinfo',
						{ 'track' => $track->url } );
				};
				$clientMode{$client}{search_tracks} = sub {
					my $id = shift;
					return Slim::Schema->find( 'Track', $id );
				};
				setSearchBrowseMode( $client, $item, 0 );
			}

			# If rescan is in progress then warn the user.
			if ( $lazifying_database || Slim::Music::Import->stillScanning() ) {
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
	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: Making custom INPUT.Choice-derived modes\n");
	my %chFunctions = %{ Slim::Buttons::Input::Choice::getFunctions() };
	$chFunctions{'numberScroll'} = \&lazyKeyHandler;
	$chFunctions{'play'}         = \&onPlayHandler;
	$chFunctions{'addSingle'}    = \&onAddHandler;
	$chFunctions{'addHold'}      = \&onInsertHandler;
	$chFunctions{'leftSingle'}   = \&onDelCharHandler;
	$chFunctions{'leftHold'}     = \&onDelAllHandler;
	$chFunctions{'forceSearch'}  = \&lazyForceSearch;
	Slim::Buttons::Common::addMode( LAZYBROWSE_MODE, \%chFunctions,
		\&Slim::Buttons::Input::Choice::setMode );

	# Out input map for the new lazy browse mode, based on thd default map
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
	);
	for my $buttonPressMode (qw{repeat hold hold_release single double}) {
		$lazyInputMap{ 'play.' . $buttonPressMode }   = 'dead';
		$lazyInputMap{ 'search.' . $buttonPressMode } = 'dead';
	}
	Slim::Hardware::IR::addModeDefaultMapping( LAZYBROWSE_MODE,
		\%lazyInputMap );

	# Intercept the 'search' button to take us to our top-level menu.
	Slim::Buttons::Common::setFunction( 'search', \&lazyOnSearch );

	# Schedule a lazification to ensure that the database is lazified. This
	# is useful because the user might shut down the server during the scan
	# and we would otherwise have a part filled database that couldn't be
	# lazy searched.
	Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() +
		LAZYSEARCH_INITIAL_LAZIFY_DELAY,
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
			'plugin-lazysearch2-leftdeletes',
			'plugin-lazysearch2-hooksearchbutton',
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
				if ( !$lazifying_database ) {
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
	if ( ( length $clientMode{$client}{search_text} ) > 0 ) {
		$headerString =
		    $clientMode{$client}{player_title} . ' \''
		  . $clientMode{$client}{search_text} . '\'';
	} else {
		$headerString = $clientMode{$client}{player_title_empty};
	}

	# If we've actually performed a search then the title also includes
	# the item number/total items as per normal browse modes.
	if ( $clientMode{$client}{search_performed} ) {
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
		modeName => LAZYBROWSE_MODE,

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
			if ( $clientMode{$client}{search_performed}
				&& ( scalar(@$listRef) != 0 ) )
			{

				# 'All' items don't have an arrow; the others do.
				if ( $item->{id} != RESULT_ENTRY_ID_ALL ) {
					$l2 = Slim::Display::Display::symbol('rightarrow');
				}
			}

			return [ $l1, $l2 ];
		},
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

	if ( !$clientMode{$client}{search_performed} ) {
		return $client->string( $clientMode{$client}{enter_more_prompt} );
	} else {
		my $listRef = $client->param('listRef');
		if ( scalar(@$listRef) == 0 ) {
			return $client->string('EMPTY');
		} else {
			my $getTextFunction = $clientMode{$client}{gettext};
			return &$getTextFunction($item);
		}
	}
}

# Make the SEARCH button force a search in the lazy search entry, consistent
# with the behaviour of the standard SEARCH button.
sub lazyForceSearch {
	my $client = shift;

	if ( !$clientMode{$client}{search_performed}
		&& ( length $clientMode{$client}{search_text} > 1 ) )
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
		if ( $clientMode{$client}{search_performed}
			&& ( $item->{id} != RESULT_ENTRY_ID_ALL ) )
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
# addMode=1 : add
# addMode=2 : insert
# addMode=3 : play
sub lazyOnPlay {
	my ( $client, $item, $addMode ) = @_;

	# Cancel any pending timer.
	cancelPendingSearch($client);

	# If no list loaded (eg search returned nothing), or
	# user has not entered enough text yet, then ignore the
	# command.
	my $listRef = $client->param('listRef');
	if ( !$clientMode{$client}{search_performed} ) {
		return;
	}

	my $id = $item->{'id'};
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
		my $getTextFunction = $clientMode{$client}{gettext};
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

	# Function that will return all tracks for the given item - used for
	# handling both individual entries and ALL entries.
	my $searchTracksFunction = $clientMode{$client}{search_tracks};

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
			next if $item->{id} == -1;

			# Find the tracks by this artist.
			my @tracks = &$searchTracksFunction( $item->{id} );

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
	$clientMode{$client}{search_text} .= $numberKey;

	# Cancel any pending search and schedule another, so search happens
	# n seconds after the last button press.
	addPendingSearch($client);

	# Update the display.
	updateLazyEntry( $client, $item );
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

	my $listIndex = $client->param('listIndex');
	my $items     = $client->param('listRef');
	my $item      = $items->[$listIndex];

	# No longer a pending search for this client.
	$clientMode{$client}{search_pending} = 0;

	# Perform lazy search, if a minimum length of search text is provided.
	my $itemsRef = $clientMode{$client}{search_items};
	if ( ( length $clientMode{$client}{search_text} ) >=
		$clientMode{$client}{min_search_length} || $forceSearch )
	{
		$client->showBriefly(
			{
				'line1' => sprintf(
					$client->string('LINE1_SEARCHING'),
					$clientMode{$client}{search_text}
				)
			}
		);

		my $searchResults =
		  Slim::Schema->resultset( $clientMode{$client}{search_type} )
		  ->search_like(
			{ customsearch => buildFind( $clientMode{$client}{search_text} ) },
			{
				columns => [ 'id', "$clientMode{$client}{text_col}" ],
				order_by => $clientMode{$client}{text_col}
			}
		  );

		# Each element of the listRef will be a hash with keys name and id.
		# This is true for artists, albums and tracks.
		my @searchItems = ();
		while ( my $searchItem = $searchResults->next ) {
			my $text =
			  $searchItem->get_column( $clientMode{$client}{text_col} );
			my $id = $searchItem->id;
			push @searchItems, { name => $text, id => $id };
		}

		# If there are results, and the user wanted it, show the 'all X'
		# choice.
		if (   Slim::Utils::Prefs::get('plugin-lazysearch2-leftdeletes')
			&& ( scalar(@searchItems) > 1 )
			&& defined( $clientMode{$client}{all_entry} ) )
		{
			push @searchItems,
			  {
				name => $clientMode{$client}{all_entry},
				id   => RESULT_ENTRY_ID_ALL
			  };
		}

		$clientMode{$client}{search_items}     = \@searchItems;
		$clientMode{$client}{search_performed} = 1;

		# Re-enter the search mode to get the display updated.
		Slim::Buttons::Common::popMode($client);
		setSearchBrowseMode( $client, $item, 1 );
		$client->update();
	} else {
		$clientMode{$client}{search_performed} = 0;
	}
}

# Construct the search terms. This takes into account the 'search substring'
# preference to build an appropriate array.
sub buildFind($) {
	my $searchText      = shift;
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
			$clientMode{$client}{search_performed} = 0;
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
		$clientMode{$client}{search_performed} = 0;

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
	lazifyDatabaseType( 'Album', 'titlesearch' );

	# Convert the artists (contributors) table.
	lazifyDatabaseType( 'Contributor', 'namesearch' );

	# Convert the genres table.
	lazifyDatabaseType( 'Genre', 'namesearch' );

	# Convert the songs (tracks) table.
	lazifyDatabaseType( 'Track', 'titlesearch' );

	# If there are any items to encode then initialise a background task that
	# will do that work in chunks.
	if ( scalar keys %encodeQueues ) {
		$::d_plugins
		  && Slim::Utils::Misc::msg(
			"LazySearch2: Scheduling backround lazification\n");
		Slim::Utils::Scheduler::add_task( \&encodeTask );
		$lazifying_database = 1;
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
	my $type        = shift;
	my $source_attr = shift;
	my $lazify_sub  = shift;

	# Find all entries that are not yet converted.
	my $rs = Slim::Schema->resultset($type)->search( { customsearch => undef },
		{ columns => [ 'id', $source_attr, 'customsearch' ] } );
	my $rs_count = $rs->count;

	$::d_plugins
	  && Slim::Utils::Misc::msg(
		"LazySearch2: Lazify type=$type, " . $rs_count . " items to lazify\n" );

	# Store the unlazified item IDs; later, we'll work on these in chunks from
	# within a task.
	if ( $rs_count > 0 ) {
		my %typeHash =
		  ( lazify_sub => $lazify_sub, rs => $rs, source_attr => $source_attr );
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
	my $type        = ( keys %encodeQueues )[0];
	my $typeHashRef = $encodeQueues{$type};
	my %typeHash    = %$typeHashRef;
	my $rs          = $typeHash{rs};
	my $source_attr = $typeHash{source_attr};

	$::d_plugins
	  && Slim::Utils::Misc::msg( 'LazySearch2: EncodeTask - '
		  . $rs->count
		  . " $type"
		  . "s remaining\n" );

	# Go through and encode each of the identified IDs. To maintain performance
	# we will bail out if this takes more than a defined time slice.

	my $rows_done  = 0;
	my $start_time = Time::HiRes::time();
	my $obj;
	do {

		# Get the next row from the resultset.
		$obj = $rs->next;
		if ($obj) {

			# Update the search text for this one row and write it back to the
			# database.
			$obj->set_column( 'customsearch',
				lazifyColumn( $obj->get_column($source_attr) ) );
			$obj->update;

			$rows_done++;
		}
	  } while (
		$obj
		&& ( ( Time::HiRes::time() - $start_time ) <
			LAZYSEARCH_ENCODE_MAX_QUANTA )
	  );

	my $end_time = Time::HiRes::time();

	# Speedometer
	my $speed = 0;
	if ( $end_time != $start_time ) {
		$speed = int( $rows_done / ( $end_time - $start_time ) );
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
	my $reschedule_task;
	if ( scalar keys %encodeQueues ) {
		$reschedule_task = 1;
	} else {
		$::d_plugins
		  && Slim::Utils::Misc::msg("LazySearch2: Lazification completed\n");

		$reschedule_task = 0;

		# Make sure our work gets persisted.
		Slim::Schema->forceCommit;

		# Clear the global flag indicating the task is in progress.
		$lazifying_database = 0;
	}

	return $reschedule_task;
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

	# This translates each searchable character into the number of the key that
	# shares that letter on the remote. Thus, this tells us what keys the user
	# will enter if he doesn't bother to multi-tap to get at the later
	# characters. Note that space maps to zero.
	# We do all this on an upper case version, since upper case is all the user
	# can enter through the remote control.
	$out_string = uc $in_string;
	$out_string =~
tr/ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890 /2223334445556667777888999912345678900/;

	return $out_string;
}

# Standard plugin function to return our message catalogue. Many thanks to the
# following for the translations:
# 	DE	Dieter (dieterp@patente.de)
# 	ES	Néstor (nspedalieri@gmail.com)
sub strings {
	return '
PLUGIN_LAZYSEARCH2
	DE	Faulpelz-Suche
	EN	Lazy Search Music
	ES	Búsqueda Laxa de Música

PLUGIN_LAZYSEARCH2_TOPMENU
	DE	Faulpelz-Suche
	EN	Lazy Search Music
	ES	Búsqueda Laxa de Música

LINE1_BROWSE
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa

LINE1_SEARCHING
	DE	Suchen nach \'%s\' ...
	EN	Searching for \'%s\' ...
	ES	Buscando \'%s\' ...

SHOWBRIEFLY_DISPLAY
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa

LINE1_BROWSE_ARTISTS
	DE	Passende Interpreten
	EN	Artists Matching
	ES	Artistas Coincidentes

LINE1_BROWSE_ARTISTS_EMPTY
	DE	Faulpelz-Suche nach Interpreten
	EN	Lazy Search for Artists
	ES	Búsqueda Laxa de Artistas

LINE1_BROWSE_ALBUMS
	DE	Passende Alben
	EN	Albums Matching
	ES	Álbumes Coincidentes

LINE1_BROWSE_ALBUMS_EMPTY
	DE	Faulpelz-Suche nach Alben
	EN	Lazy Search for Albums
	ES	Búsqueda Laxa de Álbumes

LINE1_BROWSE_TRACKS
	DE	Passende Titel
	EN	Songs Matching
	ES	Canciones Coincidentes

LINE1_BROWSE_TRACKS_EMPTY
	DE	Faulpelz-Suche nach Titel
	EN	Lazy Search for Songs
	ES	Búsqueda Laxa de Canciones

LINE1_BROWSE_GENRES
	DE	Passende Stilrichtungen
	EN	Genres Matching
	ES	Géneros Coincidentes

LINE1_BROWSE_GENRES_EMPTY
	DE	Faulpelz-Suche nach Stilrichtungen
	EN	Lazy Search for Genres
	ES	Búsqueda Laxa de Géneros

LINE2_ENTER_MORE_ARTISTS
	DE	Interpret eingeben
	EN	Enter Artist Search
	ES	Ingresar Búsqueda de Artista

LINE2_ENTER_MORE_ALBUMS
	DE	Album eingeben
	EN	Enter Album Search
	ES	Ingresar Búsqueda de Álbumes

LINE2_ENTER_MORE_TRACKS
	DE	Titel eingeben
	EN	Enter Song Search
	ES	Ingresar Búsqueda de Canciones

LINE2_ENTER_MORE_GENRES
	DE	Stilrichtung eingeben
	EN	Enter Genre Search
	ES	Ingresar Búsqueda de Géneros

SETUP_GROUP_PLUGIN_LAZYSEARCH2
	DE	Faulpelz-Suche
	EN	Lazy Search
	ES	Búsqueda Laxa

SETUP_GROUP_PLUGIN_LAZYSEARCH2_DESC
	DE	Mit den unten angebenen Einstellungen kann definiert werden, wie sich die Player-Oberfläche der Faulpelz-Suche verhält. Es wird empfohlen, den Plugin-Menüpunkt <i>Faulpelz-Suche</i> zum Hauptmenü des Players hinzuzufügen, um einen einfachen Zugriff auf die Funktionen dieses Plugins zu ermöglichen (die Standard <i>SEARCH</i>-Taste auf der Fernbedienung ermöglicht ebenfalls den Zugang zu dieser Funktionalität).
	EN	The settings below control how the lazy searching player interface performs. It is suggested that the <i>Lazy Search Music</i> menu item from this plugin is added to a player\'s home menu to provide easy access to this plugin\'s functions (the standard remote <i>search</i> button will also access this functionality).
	ES	La configuración debajo controla cómo actúa la interface de búsqueda laxa del reproductor. Se sugiere que el item de menú <i>Búsqueda Laxa de Música</i> para este plugin se añada al menú inicial del reproductor para brindar un acceso fácil a las funciones del plugin (el botón <i>search</i> estándar del control remoto tendrá también acceso a esta funcionalidad).

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST
	DE	Mindestlänge für die Suche nach Interpreten
	EN	Minimum Artist Search Length
	ES	Mínima Longitud para Búsqueda de Artista

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_DESC
	DE	Die Suche nach Interpreten, Alben, Stilrichtungen oder Titel mit einer zu kleinen Zahl von Zeichen ist nicht besonders sinnvoll, da sie zu viele Ergebnisse liefert. Um zu verhindern, dass eine Suche gestartet wird, bevor eine sinnvolle Anzahl von Zeichen eingeben wurde, ist eine Mindestzahl von Zeichen vorgegeben. Es gibt unterschiedliche Einstellungen für Interpretennamen, Albumnamen und Liedertitel - sinnvolle Voreinstellungen sind 3 für Interpreten und Alben und 4 für Lieder.
	EN	Searching for artists, albums, genres or songs with a short number of characters isn\'t very useful as it will return so many results. To prevent a search being performed until a more useful number of characters have been entered a mininum number of characters is specified here. There are separate settings for artists and album names, genres and song titles - a setting of 3 for artists, albums and genres, and 4 for songs, is a useful default.
	ES	El buscar artistas, álbumes, géneros o canciones con muy pocos caracteres no es muy útil, ya que retornará demasiados resultados. Para evitar que se efectúe una búsqueda hasta que se hayan ingresado más caracteres, se especifica aquí un número mínimo de ellos. Existen configuraciones individuales para búsqueda por nombre de artistas, nombre de álbumes, y nombre de canciones - valores por defecto apropiados son 3 caracteres para artistas, álbumes y géneros, y 4 caracteres para canciones.

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHOOSE
	DE	Mindestlänge für die Suche nach Interpreten (2-9 Zeichen):
	EN	Minimum length for artist search (2-9 characters):
	ES	Mínima longitud para búsqueda de artista (2-9 caracteres):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ARTIST_CHANGE
	DE	Mindestlänge für die Suche nach Interpreten wurde geändert in:
	EN	Minimum length for artist search changed to:
	ES	Mínima longitud para búsqueda de artista cambió a:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM
	DE	Mindestlänge für die Suche nach Alben
	EN	Minimum Album Search Length
	ES	Mínima Longitud para Búsqueda de Álbum

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHOOSE
	DE	Mindestlänge für die Suche nach Alben (2-9 Zeichen):
	EN	Minimum length for album search (2-9 characters):
	ES	Mínima longitud para búsqueda de álbum (2-9 caracteres):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_ALBUM_CHANGE
	DE	Mindestlänge für die Suche nach Alben wurde geändert in:
	EN	Minimum length for album search changed to:
	ES	Mínima longitud para búsqueda de álbum cambió a:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK
	DE	Mindestlänge für die Suche nach Titel
	EN	Minimum Song Search Length
	ES	Mínima Longitud para Búsqueda de Canción

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHOOSE
	DE	Mindestlänge für die Suche nach Titel (2-9 Zeichen):
	EN	Minimum length for song search (2-9 characters):
	ES	Mínima longitud para búsqueda de canción (2-9 caracteres):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_TRACK_CHANGE
	DE	Mindestlänge für die Suche nach Titel wurde geändert in:
	EN	Minimum length for song search changed to:
	ES	Mínima longitud para búsqueda de canción cambió a:

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE
	DE	Mindestlänge für die Suche nach Stilrichtungen
	EN	Minimum Genre Search Length
	ES	Mínima Longitud para Búsqueda de Género

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHOOSE
	DE	Mindestlänge für die Suche nach Stilrichtungen (2-9 Zeichen):
	EN	Minimum length for genre search (2-9 characters):
	ES	Mínima longitud para búsqueda de género (2-9 caracteres):

SETUP_PLUGIN_LAZYSEARCH2_MINLENGTH_GENRE_CHANGE
	DE	Mindestlänge für die Suche nach Stilrichtungen wurde geändert in:
	EN	Minimum length for genre search changed to:
	ES	Mínima longitud para búsqueda de género cambió a:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES
	DE	Verhalten der LINKS-Taste
	EN	LEFT Button Behaviour
	ES	Comportamiento del Botón IZQUIERDA

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_DESC
	DE	Man kann einstellen, wie sich die LINKS-Taste auf der Fernbedienung bei der Eingabe von Suchtext verhält. Mit der LINKS-Taste kann entweder das zuletzt eingegeben Zeichen gelöscht werden (z.B. um einen Fehler zu korrigieren) oder der Suchmodus beendet werden.
	EN	You can choose how the LEFT button on the remote control behaves when entering search text. LEFT can either delete the last character entered (eg to correct a mistake), or can exit the search mode altogether.
	ES	Se puede elegir como se comportará el boton IZQUIERDA del control remoto cuando se ingresa texto. IZQUIERDA puede o bien borrar el último caracter ingresado (por ej, para corregir un error), o bien puede abandonar el modo búsqueda.

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHOOSE
	DE	Drücken der LINKS-Taste während einer Suche:
	EN	Pressing LEFT while entering a search:
	ES	Presionando IZQUIERDA mientras se ingresa una búsqueda:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_CHANGE
	DE	Drücken der LINKS-Taste wurde geändert in:
	EN	Pressing LEFT changed to:
	ES	Presionando IZQUIERDA cambió a:

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_0
	DE	Beendet den Suchmodus
	EN	Exits the search mode
	ES	Abandona el modo búsqueda

SETUP_PLUGIN_LAZYSEARCH2_LEFTDELETES_1
	DE	Löscht das zuletzt eingegebene Zeichen
	EN	Deletes the last character entered
	ES	Borra los últimos caracteres ingresados

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON
	DE	Verhalten der SEARCH-Taste
	EN	SEARCH Button Behaviour
	ES	Comportamiento del Botón SEARCH

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_DESC
	DE	Mit dieser Einstellung kann die SEARCH-Taste auf der Squeezebox-Fernbedienung mit der <i>Faulpelz-Suche</i> statt mit der <i>Originalsuche</i> belegt werden. Durch Aktivieren dieser Einstellung kann diese Taste entsprechend umbelegt werden, ohne die Dateien <i>Default.map</i> oder <i>Custom.map</i> ändern zu müssen. Hinweis: Änderungen an dieser Einstellung werden erst nach einem erneuten Start des Plugins wirksam (z.B. bei einem Neustart des SlimServers).
	EN	This setting allows the SEARCH button on the Squeezebox remote to be remapped to the <i>lazy search music</i> function instead of the original <i>search music</i> function. Enabling this setting allows this button remapping to be performed without editing the <i>Default.map</i> or <i>Custom.map</i> files. Note that changes to this setting do not take effect until the plugin is reloaded (eg by restarting SlimServer).
	ES	Esta configuración permite reasignar el boton SEARCH del control remoto de Squeezebox a la función de <i>búsqueda laxa de música</i>, en lugar de la función de <i>búsqueda de música</i> original. Habilitando esto se logra que la reasignación del botón sea realizada sin editar los archivos <i>Default.map</i> o <i>Custom.map</i>. Notar que los cambios no tendrán efecto hasta que el plugin sea recargado (por ej. al reiniciar SlimServer).

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHOOSE
	DE	Drücken der SEARCH-Taste auf der Squeezebox-Fernbedienung:
	EN	Pressing SEARCH on the Squeezebox remote:
	ES	Presionando SEARCH en el remoto de Squeezebox:

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_CHANGE
	DE	Drücken der SEARCH-Taste wurde geändert in:
	EN	Pressing SEARCH changed to:
	ES	Presionando SEARCH cambió a:

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_0
	DE	Zeigt das Menü der Standardsuche an
	EN	Accesses the standard search music menu
	ES	Accede al menú de búsqueda musical estándar

SETUP_PLUGIN_LAZYSEARCH2_HOOKSEARCHBUTTON_1
	DE	Zeigt das Menü der Faulpelz-Suche an
	EN	Accesses the lazy search music menu
	ES	Accede al menú de búsqueda musical laxa

SCAN_IN_PROGRESS
	DE	Hinweis: Die Musikdatenbank wird gerade durchsucht
	EN	Note: music library scan in progress
	ES	Nota: se está recopilando la colección musical

SCAN_IN_PROGRESS_DBL
	DE	Hinweis: Suche läuft
	EN	Note: scanning
	ES	Nota: recopilando

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW
	DE	Indexerzeugung für die Faulpelz-Suche
	EN	Force Lazy Search Index Build
	ES	Forzar Creación de Índice para Búsqueda Laxa

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_DESC
	DE	Das Plugin erzeugt den Index für die Faulpelz-Suche, wenn dies erforderlich ist. Normalerweise ist daher keine extra Pflege der Datenbank notwendig. Falls Sie sichergehen wollen, dass der Index der Faulpelz-Suche korrekt erzeugt wurde, können Sie die folgende Schaltfläche anklicken. Aber in Anbetracht dessen, dass dies nie erforderlich sein sollte, ist dies in erster Linie eine Hilfe für die Fehlersuche.
	EN	The plugin is designed to build the lazy search index whenever required and so, under normal circumstances, no extra database maintenance is required. If you wish to ensure that the lazy search index has been correctly built you can press the following button, but given that it should never be necessary this is primarily a debugging aid.
	ES	El plugin se ha diseñado para construir el índice de búsqueda laxa cuando sea que se requiera. Por lo tanto, en circunstancias normales, no se requiere mantenimiento extra de la base de datos. Si se quiere estar seguro que el índice de búsqueda laxa ha sido construido correctamente, se puede presionar el siguiente botón (aunque dado que nunca debería ser necesario reconstruirlo manualmente se lo incluye aquí simplemente como una ayuda para la depuración).

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_CHANGE
	DE	Die Erzeugung des Index für die Faulpelz-Suche hat begonnen
	EN	Lazy search index build has been started
	ES	La creación del índice para búsqueda laxa ha comenzado

SETUP_PLUGIN_LAZYSEARCH2_LAZIFYNOW_BUTTON
	DE	Jetzt den Index für die Faulpelz-Suche erzeugen
	EN	Build Lazy Search Index Now
	ES	Crear Índice de Búsqueda Laxa Ahora
';
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
