# LazySearch2 Plugin for SqueezeCentre
# Copyright © Stuart Hickinbottom 2004-2007
#
# $Id$

inherit eutils

SLIMSERVER_VERSION="7.0"
MY_P="LazySearch2-${PV}"
DESCRIPTION="A plugin for SqueezeCentre to perform searches more quickly and easily using your player's remote control."
HOMEPAGE="http://www.hickinbottom.com/lazysearch"
SRC_URI="http://www.hickinbottom.com/lazysearch/${MY_P}.tar.gz"
LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~x86"
IUSE=""
DEPEND=""
RDEPEND="
	>=media-sound/squeezecentre-${SLIMSERVER_VERSION}"
S="${WORKDIR}"

src_install() {
	cp -r * ${D}/opt/squeezecentre/Plugins
}
