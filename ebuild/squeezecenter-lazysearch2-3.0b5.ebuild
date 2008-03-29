# Copyright 1999-2008 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header:$

inherit eutils

MY_P="LazySearch2-7_0-${PV}"

DESCRIPTION="A plugin for SqueezeCentre to perform searches more quickly and easily using your player's remote control."
HOMEPAGE="http://www.hickinbottom.com/lazysearch"
SRC_URI="http://www.hickinbottom.com/lazysearch/browser/downloads/${MY_P}.zip?format=raw"
LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~x86"

RDEPEND="
	media-sound/squeezecentre
	"

S="${WORKDIR}/${MY_P}"

# The root of the SqueezeCenter installation, as defined by the SqueezeCenter
# ebuild
INSTROOT=/opt/squeezecenter

src_install() {
	dodir ${D}${INSTROOT}
	cp -r * ${D}${INSTROOT}/Plugins
}
