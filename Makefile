# Makefile for LazySearch2 plugin for SlimServer 6.2 (and later)
# 
# $Id$
#
# Stuart Hickinbottom 2006

SOURCE=LazySearch2.pm
RELEASEDIR=releases
DEST=LazySearch2.pm
DESTSTAGE=$(RELEASEDIR)/$(DEST)
DISTFILES=$(DESTSTAGE) INSTALL
SLIMDIR=~slim
PLUGINDIR=$(SLIMDIR)/Plugins
REVISION=`svn info . | grep "^Revision:" | cut -d' ' -f2`
DISTFILE=LazySearch2-6_5-r$(REVISION).zip
DISTFILEDIR=$(RELEASEDIR)/$(DISTFILE)
SVNDISTFILE=LazySearch2.zip
LATESTLINK=$(RELEASEDIR)/LazySearch2-6_5-latest.zip

.SILENT:

all:
	echo Try 'make install', 'make release' or 'make pretty'
	echo Or, 'make install restart logtail'

FORCE:

# Run the plugin through the Perl beautifier.
pretty:
	perltidy -b -ce -et=4 $(SOURCE) && rm $(SOURCE).bak
	echo "You're Beautiful..."

# Install the plugin in SlimServer.
install: $(PLUGINDIR)/$(DEST)

# Restart SlimServer, quite forcefully. This is obviously quite
# Gentoo-specific.
restart:
	echo "Forcefully restarting SlimServer..."
	>/var/log/slimserver/messages
	/etc/init.d/slimserver stop
	/etc/init.d/slimserver zap
	/etc/init.d/slimserver restart

logtail:
	echo "Following the end of the SlimServer log..."
	tail -F /var/log/slimserver/messages

$(PLUGINDIR)/$(DEST): $(DESTSTAGE)
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
	zip -j "$(DISTFILEDIR)" $(DISTFILES)
	rm "$(LATESTLINK)" >/dev/null 2>&1 || true
	ln -s "$(DISTFILE)" "$(LATESTLINK)"
	rm $(DESTSTAGE)
	cp $(DISTFILEDIR) $(SVNDISTFILE)

# Build a version of the plugin with the revision information substituted
$(DESTSTAGE): $(SOURCE)
	echo "Inserting plugin revision ($(REVISION))..."
	sed "s/@@REVISION@@/$(REVISION)/" <"$^" >"$@"
