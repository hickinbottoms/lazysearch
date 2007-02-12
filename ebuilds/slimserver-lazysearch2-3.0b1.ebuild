# LazySearch2 Plugin for SlimServer
# Copyright © Stuart Hickinbottom 2004-2007
#
# $Id$

inherit eutils

SLIMSERVER_VERSION="7.0"
MY_P="LazySearch2-${PV}"
DESCRIPTION="A plugin for SlimServer to perform searches more quickly and easily using your player's remote control."
HOMEPAGE="http://hickinbottom.demon.co.uk/lazysearch"
SRC_URI="http://hickinbottom.demon.co.uk/lazysearch/${MY_P}.tar.gz"
LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~x86"
IUSE=""
DEPEND=""
RDEPEND="
	>=media-sound/slimserver-${SLIMSERVER_VERSION}"
S="${WORKDIR}"

src_install() {
	cp -r * ${D}/opt/slimserver/Plugins
}
