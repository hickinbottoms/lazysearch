# Makefile for LazySearch2 plugin for SlimServer 7.0 (and later)
# 
# $Id$
#
# Stuart Hickinbottom 2006-2007

VERSION=3.0b1
PERLSOURCE=Plugin.pm.in
PERLTARGETS=Plugin.pm
SOURCE=$(PERLSOURCE) strings.txt install.xml.in
TARGETS=$(PERLTARGETS) strings.txt install.xml
RELEASEDIR=releases
DEST=LazySearch2.pm
DESTSTAGE=$(RELEASEDIR)/$(DEST)
DISTFILES=$(DESTSTAGE) INSTALL
SLIMDIR=/usr/local/slimserver7/server
PLUGINSDIR=$(SLIMDIR)/Plugins
PLUGINDIR=LazySearch2
REVISION=`svn info . | grep "^Revision:" | cut -d' ' -f2`
DISTFILE=LazySearch2-7_0-r$(REVISION).zip
DISTFILEDIR=$(RELEASEDIR)/$(DISTFILE)
SVNDISTFILE=LazySearch2.zip
LATESTLINK=$(RELEASEDIR)/LazySearch2-7_0-latest.zip

#.SILENT:

all:
	echo Try 'make install', 'make release' or 'make pretty'
	echo Or, 'make install restart logtail'

FORCE:

Plugin.pm: Plugin.pm.in
	sed "s/@@VERSION@@/$(VERSION)/" <"$^" >"$@"

install.xml: install.xml.in
	sed "s/@@VERSION@@/$(VERSION)/" <"$^" >"$@"

# Regenerate tags.
tags: $(SOURCE)
	exuberant-ctags $^

# Run the plugin through the Perl beautifier.
pretty:
	perltidy -b -ce -et=4 $(SOURCE) && rm $(SOURCE).bak
	echo "You're Beautiful..."

# Install the plugin in SlimServer.
install: $(TARGETS)
	echo Installing plugin...
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && chmod -R +w "$(PLUGINSDIR)/$(PLUGINDIR)"
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && rm -r "$(PLUGINSDIR)/$(PLUGINDIR)"
	mkdir "$(PLUGINSDIR)/$(PLUGINDIR)"
	cp $(SOURCE) "$(PLUGINSDIR)/$(PLUGINDIR)"
	chmod -R -w "$(PLUGINSDIR)/$(PLUGINDIR)"

# Restart SlimServer, quite forcefully. This is obviously quite
# Gentoo-specific.
restart:
	echo "Forcefully restarting SlimServer..."
	/etc/init.d/slimserver7 stop
	sleep 5
	>/var/log/slimserver7/messages
	/etc/init.d/slimserver7 zap
	/etc/init.d/slimserver7 restart

logtail:
	echo "Following the end of the SlimServer log..."
	tail -F /var/log/slimserver/messages

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
