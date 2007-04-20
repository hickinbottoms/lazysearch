# Makefile for LazySearch2 plugin for SlimServer 7.0 (and later)
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

VERSION=3.0b2
PERLSOURCE=Plugin.pm Settings.pm
HTMLSOURCE=HTML/EN/plugins/LazySearch2/settings/basic.html HTML/EN/plugins/LazySearch2/settings/logo.jpg
SOURCE=$(PERLSOURCE) $(HTMLSOURCE) INSTALL strings.txt install.xml LICENSE
RELEASEDIR=releases
STAGEDIR=stage
SLIMDIR=/usr/local/slimserver7/server
PLUGINSDIR=$(SLIMDIR)/Plugins
PLUGINDIR=LazySearch2
REVISION=`svn info . | grep "^Revision:" | cut -d' ' -f2`
DISTFILE=LazySearch2-7_0-$(VERSION).zip
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
	-chmod -R +w $(STAGEDIR)/* >/dev/null 2>&1
	-rm -rf $(STAGEDIR)/* >/dev/null 2>&1
	for FILE in $(SOURCE); do \
		mkdir -p "$(STAGEDIR)/$(PLUGINDIR)/`dirname $$FILE`"; \
		sed "s/@@VERSION@@/$(VERSION)/" <"$$FILE" >"$(STAGEDIR)/$(PLUGINDIR)/$$FILE"; \
	done
	chmod -R -w $(STAGEDIR)/*

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
	sudo cp -r "$(STAGEDIR)/$(PLUGINDIR)" "$(PLUGINSDIR)"
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
release: make-stage
	echo Building distfile: $(DISTFILE)
	echo Remember to have committed and updated first.
	-rm "$(DISTFILEDIR)" >/dev/null 2>&1
	(cd "$(STAGEDIR)" && zip -r "../$(DISTFILEDIR)" "$(PLUGINDIR)")
	-rm "$(LATESTLINK)" >/dev/null 2>&1
	ln -s "$(DISTFILE)" "$(LATESTLINK)"
	cp $(DISTFILEDIR) $(SVNDISTFILE)

# Utility target to clear lazification from the database without the bother
# of having to do a full rescan.
unlazify:
	echo Unlazifying the database...
	sh -c "mysql --user=`grep -i dbuser $(PREFS) | cut -d' ' -f2` --password=`grep -i dbpassword $(PREFS) | cut -d' ' -f2` `grep -i dbsource $(PREFS) | cut -d' ' -f2 | cut -d= -f2 | cut -d';' -f1` < unlazify.sql"
