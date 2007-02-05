# Makefile for LazySearch2 plugin for SlimServer 7.0 (and later)
# 
# $Id$
#
# Stuart Hickinbottom 2006-2007

VERSION=3.0b1
PERLSOURCE=Plugin.pm
SOURCE=$(PERLSOURCE) INSTALL strings.txt install.xml
RELEASEDIR=releases
STAGEDIR=stage
SLIMDIR=/usr/local/slimserver7/server
PLUGINSDIR=$(SLIMDIR)/Plugins
PLUGINDIR=LazySearch2
REVISION=`svn info . | grep "^Revision:" | cut -d' ' -f2`
DISTFILE=LazySearch2-7_0-r$(REVISION).zip
DISTFILEDIR=$(RELEASEDIR)/$(DISTFILE)
SVNDISTFILE=LazySearch2.zip
LATESTLINK=$(RELEASEDIR)/LazySearch2-7_0-latest.zip

.SILENT:

all:
	echo Try 'make install', 'make release' or 'make pretty'
	echo Or, 'make install restart logtail'

FORCE:

make-stage:
	echo "Creating plugin stage files (v$(VERSION))..."
	-rm -rf $(STAGEDIR)/* >/dev/null 2>&1
	for FILE in $(SOURCE); do \
		sed "s/@@VERSION@@/$(VERSION)/" <"$$FILE" >"$(STAGEDIR)/$$FILE"; \
	done
	chmod -w $(STAGEDIR)/*

# Regenerate tags.
tags: $(PERLSOURCE)
	echo Tagging...
	exuberant-ctags $^

# Run the plugin through the Perl beautifier.
pretty:
	for FILE in $(PERLSOURCE); do \
		perltidy -b -ce -et=4 $$FILE && rm $$FILE.bak; \
	done
	echo "You're Beautiful..."

# Install the plugin in SlimServer.
install: make-stage
	echo Installing plugin...
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && chmod -R +w "$(PLUGINSDIR)/$(PLUGINDIR)"
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && rm -r "$(PLUGINSDIR)/$(PLUGINDIR)"
	mkdir "$(PLUGINSDIR)/$(PLUGINDIR)"
	cp -r $(STAGEDIR)/* "$(PLUGINSDIR)/$(PLUGINDIR)"
	chmod -R -w "$(PLUGINSDIR)/$(PLUGINDIR)"

# Restart SlimServer, quite forcefully. This is obviously quite
# Gentoo-specific.
restart:
	echo "Forcefully restarting SlimServer..."
	/etc/init.d/slimserver7 stop
	/etc/init.d/slimserver7 zap
	sleep 5
	>/var/log/slimserver7/server.log
	>/var/log/slimserver7/scanner.log
	>/var/log/slimserver7/perfmon.log
	/etc/init.d/slimserver7 restart

logtail:
	echo "Following the end of the SlimServer log..."
	tail -F /var/log/slimserver7/server.log

# TODO - fix this for new package layout
# Build a distribution package for this Plugin.
release: $(DISTFILES)
	echo Building distfile: $(DISTFILE)
	echo Remember to have committed and updated first.
	rm "$(DISTFILEDIR)" >/dev/null 2>&1 || true
	zip -j "$(DISTFILEDIR)" $(DISTFILES)
	rm "$(LATESTLINK)" >/dev/null 2>&1 || true
	ln -s "$(DISTFILE)" "$(LATESTLINK)"
	rm $(DESTSTAGE)
	cp $(DISTFILEDIR) $(SVNDISTFILE)
