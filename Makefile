#
# Copyright (C) 2026 Mehedi Hasan <hello@mehedims.com>
# SPDX-License-Identifier: GPL-2.0-only
#
# BD Controls - lightweight per-user bandwidth monitoring & control for LuCI
# https://github.com/asma019/BD-Controls-OpenWRT-Luci
#
# Builds two packages from the bundled (no upstream download) file tree in this dir:
#   * bd-controls          - the daemon, firewall backends (nftables/iptables auto),
#                            tc/HTB shaping, schedule engine, volatile usage stats
#   * luci-app-bd-controls - modern JS (client-side) LuCI frontend
#
# Get the source and build (the clone keeps the repo name as the folder;
# OpenWrt targets packages by directory path, not by name):
#   cd $TOPDIR/package
#   git clone https://github.com/asma019/BD-Controls-OpenWRT-Luci.git
#   cd $TOPDIR
#   make defconfig
#   make package/BD-Controls-OpenWRT-Luci/{clean,compile}
#   find bin -name '*.apk'
#

include $(TOPDIR)/rules.mk

PKG_NAME:=bd-controls
PKG_VERSION:=1.1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Mehedi Hasan <hello@mehedims.com>

PKG_BUILD_PARALLEL:=1

# Internal: everything lives in the package dir, nothing to download.
# PKG_SOURCE / PKG_SOURCE_URL intentionally unset.

include $(INCLUDE_DIR)/package.mk

# ------------------------------------------------------------------
# Package metadata
# ------------------------------------------------------------------
define Package/bd-controls
	SECTION:=net
	CATEGORY:=Network
	SUBMENU:=Bandwidth
	TITLE:=Per-user bandwidth monitoring and control daemon
	URL:=https://github.com/asma019/BD-Controls-OpenWRT-Luci
	DEPENDS:=+tc +nftables
endef

define Package/bd-controls/description
	Extremely lightweight daemon for low-end OpenWrt routers (128-256MB
	RAM, 65-128MB flash). Tracks per-user connectivity, data usage and
	provides block/unblock, time-based schedules and per-user speed
	limits via tc/HTB. Backend for the LuCI app luci-app-bd-controls.
	Uses nftables when present, iptables otherwise.
endef

define Package/luci-app-bd-controls
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=Bandwidth
	TITLE:=BD Controls - usage monitor, limits and schedules
	URL:=https://github.com/asma019/BD-Controls-OpenWRT-Luci
	DEPENDS:=+bd-controls +luci-base
endef

define Package/luci-app-bd-controls/description
 Frontend for the bd-controls daemon: live CPU/RAM/network, connected
 users with session length, per-user data totals, block/unblock,
 per-user speed limits and time schedules, usage graphs - all without
 reflashing this low-end router.
endef

# ------------------------------------------------------------------
# Install
# ------------------------------------------------------------------
define Package/bd-controls/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/bd-controls
	$(INSTALL_BIN) ./files/usr/bin/bd-controls $(1)/usr/bin/
	$(CP) ./files/usr/share/bd-controls/* $(1)/usr/share/bd-controls/
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_CONF) ./files/etc/config/bd-controls $(1)/etc/config/bd-controls
	$(INSTALL_BIN) ./files/etc/init.d/bd-controls $(1)/etc/init.d/bd-controls
endef

define Package/luci-app-bd-controls/install
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-bd-controls.json \
		$(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-bd-controls.json \
		$(1)/usr/share/luci/menu.d/
	# JS view
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/bd-controls
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/bd-controls/*.js \
		$(1)/www/luci-static/resources/view/bd-controls/
endef

$(eval $(call BuildPackage,bd-controls))
$(eval $(call BuildPackage,luci-app-bd-controls))