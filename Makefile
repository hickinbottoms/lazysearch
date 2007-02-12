# Makefile for LazySearch2 plugin for SlimServer 7.0 (and later)
# 
# $Id$
#
# Stuart Hickinbottom 2006-2007

VERSION=3.0b1
PERLSOURCE=Plugin.pm Settings.pm
SOURCE=$(PERLSOURCE) INSTALL strings.txt install.xml
DIRSOURCE=HTML
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
PREFS=/etc/slimserver7.pref

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
	cp -R $(DIRSOURCE) $(STAGEDIR)
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
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && sudo chmod -R +w "$(PLUGINSDIR)/$(PLUGINDIR)"
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && sudo rm -r "$(PLUGINSDIR)/$(PLUGINDIR)"
	sudo mkdir "$(PLUGINSDIR)/$(PLUGINDIR)"
	sudo cp -r $(STAGEDIR)/* "$(PLUGINSDIR)/$(PLUGINDIR)"
	sudo chmod -R -w "$(PLUGINSDIR)/$(PLUGINDIR)"

# Restart SlimServer, quite forcefully. This is obviously quite
# Gentoo-specific.
restart:
	echo "Forcefully restarting SlimServer..."
	sudo /etc/init.d/slimserver7 stop
	sudo /etc/init.d/slimserver7 zap
	sleep 2
	sudo sh -c ">/var/log/slimserver7/server.log"
	sudo sh -c ">/var/log/slimserver7/scanner.log"
	sudo sh -c ">/var/log/slimserver7/perfmon.log"
	sudo /etc/init.d/slimserver7 restart

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

# Utility target to clear lazification from the database without the bother
# of having to do a full rescan.
unlazify:
	echo Unlazifying the database...
	sh -c "mysql --user=`grep -i dbuser $(PREFS) | cut -d' ' -f2` --password=`grep -i dbpassword $(PREFS) | cut -d' ' -f2` `grep -i dbsource $(PREFS) | cut -d' ' -f2 | cut -d= -f2 | cut -d';' -f1` < unlazify.sql"
