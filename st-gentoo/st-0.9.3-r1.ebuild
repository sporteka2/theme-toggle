# Copyright 1999-2025 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2
#
# Local revision of x11-terms/st, identical to the Gentoo ebuild but with the
# "xresources with signal reloading" patch (re-merged to also apply on top
# of the "anygeometry" patch: -G pixel-based window geometry) applied, so the
# palette can be
# reloaded live (xrdb -merge + kill -s USR1) instead of only at startup.

EAPI=8

inherit desktop savedconfig toolchain-funcs

DESCRIPTION="Simple terminal implementation for X"
HOMEPAGE="https://st.suckless.org/"

SRC_URI="https://dl.suckless.org/${PN}/${P/_}.tar.gz"

LICENSE="MIT"
KEYWORDS="amd64"
SLOT="0"

RDEPEND="
	>=sys-libs/ncurses-6.0:0=
	media-libs/fontconfig
	x11-libs/libX11
	x11-libs/libXft
	~x11-terms/st-terminfo-${PV}
"
DEPEND="
	${RDEPEND}
	x11-base/xorg-proto
"
BDEPEND="virtual/pkgconfig"

src_prepare() {
	default

	sed -i \
		-e "/^X11LIB/{s:/usr/X11R6/lib:/usr/$(get_libdir)/X11:}" \
		-e '/^STLDFLAGS/s|= .*|= $(LDFLAGS) $(LIBS)|g' \
		-e '/^X11INC/{s:/usr/X11R6/include:/usr/include/X11:}' \
		config.mk || die
	sed -i \
		-e '/tic/d' \
		Makefile || die

	eapply "${FILESDIR}/st-geometry-reload.diff"

	restore_config config.h
}

src_configure() {
	sed -i \
		-e "s|pkg-config|$(tc-getPKG_CONFIG)|g" \
		config.mk || die

	tc-export CC
}

src_install() {
	emake DESTDIR="${D}" PREFIX="${EPREFIX}"/usr install

	dodoc TODO

	make_desktop_entry ${PN} simpleterm utilities-terminal 'System;TerminalEmulator;' ''

	save_config config.h
}

pkg_postinst() {
	if [[ -z "${REPLACING_VERSIONS}" ]]; then
		elog "Please ensure a usable font is installed, like"
		elog "    media-fonts/corefonts"
		elog "    media-fonts/dejavu"
		elog "    media-fonts/urw-fonts"
	fi
	elog "Built with the xresources-with-signal-reloading patch:"
	elog "palette can be reloaded live with 'xrdb -merge <file>' and"
	elog "'kill -s USR1' on every running st process."
}
