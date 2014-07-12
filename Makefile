# Makefile for LazySearch2 plugin for Squeezebox Server 7.0 (and later)
# Copyright © Stuart Hickinbottom 2004-2014

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

VERSION=3.6.4
PERLSOURCE=Plugin.pm Settings.pm
HTMLSOURCE=HTML/EN/plugins/LazySearch2/settings/basic.html HTML/EN/plugins/LazySearch2/settings/logo.jpg
SOURCE=$(PERLSOURCE) $(HTMLSOURCE) INSTALL strings.txt install.xml LICENSE
RELEASEDIR=releases
STAGEDIR=stage
SLIMVER=7.8
SLIMDIR=/usr/local/slimserver
PLUGINSDIR=$(SLIMDIR)/Plugins
PLUGINDIR=LazySearch2
COMMIT=`git log -1 --pretty=format:%H`
DISTFILE=LazySearch2-7-$(VERSION).zip
DISTFILEDIR=$(RELEASEDIR)/$(DISTFILE)
LATESTLINK=$(RELEASEDIR)/LazySearch2-7-latest.zip

# VM stuff for testing
PIDFILE=/home/stuarth/code/audiothings/scebuild/qemu.pid
VMHOST=chandra
LOCAL_PORTAGE=/usr/local/portage
EBUILD_PREFIX=squeezeboxserver-lazysearch
EBUILD_CATEGORY=media-plugins/$(EBUILD_PREFIX)
EBUILD_DIR=$(LOCAL_PORTAGE)/$(EBUILD_CATEGORY)

.SILENT:

all:
	echo Try 'make install', 'make release' or 'make pretty'
	echo Or, 'make install restart logtail'

FORCE:

make-stage:
	echo "Creating stage files (v$(VERSION)/$(COMMIT))..."
#	-chmod -R +w $(STAGEDIR)/* >/dev/null 2>&1
	-rm -rf $(STAGEDIR)/* >/dev/null 2>&1
	for FILE in $(SOURCE); do \
		mkdir -p "$(STAGEDIR)/$(PLUGINDIR)/`dirname $$FILE`"; \
		sed "s/@@VERSION@@/$(VERSION)/;s/@@COMMIT@@/$(COMMIT)/" <"$$FILE" >"$(STAGEDIR)/$(PLUGINDIR)/$$FILE"; \
	done
#	chmod -R -w $(STAGEDIR)/*

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

# Install the plugin in Squeezebox Server.
install: make-stage
	echo Installing plugin...
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && sudo chmod -R +w "$(PLUGINSDIR)/$(PLUGINDIR)"
	-[[ -d "$(PLUGINSDIR)/$(PLUGINDIR)" ]] && sudo rm -r "$(PLUGINSDIR)/$(PLUGINDIR)"
	sudo cp -r "$(STAGEDIR)/$(PLUGINDIR)" "$(PLUGINSDIR)"
	sudo chmod -R -w "$(PLUGINSDIR)/$(PLUGINDIR)"

# Restart Squeezebox Server, quite forcefully. This is obviously quite
# Gentoo-specific.
restart:
	echo "Forcefully restarting Squeezebox Server..."
	-sudo pkill -9 squeezeslave
	sudo /etc/init.d/squeezeslave zap
	-sudo /etc/init.d/squeezeboxserver-$(SLIMVER) stop
	-sudo /etc/init.d/squeezeboxserver-$(SLIMVER) zap
	-sudo pkill slimserver
	sleep 2
	sudo sh -c ">/var/log/squeezeboxserver-$(SLIMVER)/server.log"
	sudo sh -c ">/var/log/squeezeboxserver-$(SLIMVER)/scanner.log"
	sudo sh -c ">/var/log/squeezeboxserver-$(SLIMVER)/perfmon.log"
	sudo /etc/init.d/squeezeboxserver-$(SLIMVER) restart

logtail:
	echo "Following the end of the Squeezebox Server log..."
	tail -F /var/log/squeezeboxserver-$(SLIMVER)/server.log | grep -v "par-slim"

logtail2:
	echo "Following the end of the Squeezebox Server log (LazySearch only)..."
	multitail -e LazySearch -f /var/log/squeezeboxserver-$(SLIMVER)/server.log

# Build a distribution package for this Plugin.
release: make-stage
	echo Building distfile: $(DISTFILE)
	echo Remember to have committed and updated first.
	-rm "$(DISTFILEDIR)" >/dev/null 2>&1
	(cd "$(STAGEDIR)" && zip -r "../$(DISTFILEDIR)" "$(PLUGINDIR)")
	-rm "$(LATESTLINK)" >/dev/null 2>&1
	ln -s "$(DISTFILE)" "$(LATESTLINK)"

inject:
	[ -f $(PIDFILE) ] || echo error: VM not running
	[ -f $(PIDFILE) ] && echo Injecting ebuilds...
	ssh root@$(VMHOST) "rm -r $(EBUILD_DIR)/* >/dev/null 2>&1 || true"
	ssh root@$(VMHOST) mkdir -p $(EBUILD_DIR) $(EBUILD_DIR)/files
	scp ebuild/metadata.xml $(EBUILDS) root@$(VMHOST):$(EBUILD_DIR)
	scp ebuild/*.ebuild $(EBUILDS) root@$(VMHOST):$(EBUILD_DIR)
	ssh root@$(VMHOST) 'cd $(EBUILD_DIR); for EBUILD in *.ebuild; do echo $$EBUILD; echo ebuild $(EBUILD_DIR)/$$EBUILD manifest; done'
	echo Unmasking ebuild...
	ssh root@$(VMHOST) mkdir -p /etc/portage
	ssh root@$(VMHOST) "grep -q '$(EBUILD_CATEGORY)' /etc/portage/package.keywords >/dev/null 2>&1 || echo '$(EBUILD_CATEGORY) ~x86' >> /etc/portage/package.keywords"

