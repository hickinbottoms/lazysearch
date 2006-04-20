# Makefile for LazySearch2 plugin for SlimServer 6.2 (and later)
# 
# $Id$
#
# Stuart Hickinbottom 2005

SOURCE=LazySearch2.pm.in
DEST=LazySearch2.pm
DISTFILES=$(DEST) INSTALL
SLIMDIR=~slim
PLUGINDIR=$(SLIMDIR)/Plugins
RELEASEDIR=releases
REVISION=`svn info . | grep "^Revision:" | cut -d' ' -f2`
DISTFILE=LazySearch2-6_5-r$(REVISION).zip
DISTFILEDIR=$(RELEASEDIR)/$(DISTFILE)
LATESTLINK=$(RELEASEDIR)/LazySearch2-6_5-latest.zip

.SILENT:

all:
	echo Try 'make install', 'make release' or 'make pretty'

FORCE:

# Run the plugin through the Perl beautifier.
pretty:
	perltidy -b -ce -et=4 $(SOURCE) && rm $(SOURCE).bak
	echo "You're Beautiful..."

# Install the plugin in SlimServer.
install: $(PLUGINDIR)/$(DEST)

$(PLUGINDIR)/$(DEST): $(DEST)
	echo Installing plugin...
	chmod +w "$@"
	cp "$^" "$@"
	chmod -w "$@"
	rm "$^"

# Build a distrubution package for this Plugin.
release: $(DISTFILES)
	echo Building distfile: $(DISTFILE)
	echo Remember to have committed and updated first.
	rm "$(DISTFILEDIR)" >/dev/null 2>&1 || true
	zip "$(DISTFILEDIR)" $(DISTFILES)
	rm "$(LATESTLINK)" >/dev/null 2>&1 || true
	ln -s "$(DISTFILE)" "$(LATESTLINK)"
	rm $(DEST)

# Build a version of the plugin with the revision information substituted
$(DEST): $(SOURCE)
	echo "Inserting plugin revision ($(REVISION))..."
	sed "s/@@REVISION@@/$(REVISION)/" <"$^" >"$@"
