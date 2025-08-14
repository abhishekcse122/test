#!/usr/bin/env bash
set -Eeuo pipefail

# Simple log helpers
log() { echo "[$(date +%F' '%T)] $*"; }
abort() { echo "[ERROR] $*" >&2; exit 1; }

# Trap errors
trap 'echo "[ERROR] Line $LINENO failed: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-$SCRIPT_DIR/c2m.env}"

[ -f "$ENV_FILE" ] || abort "Config file not found: $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

require_root() {
	if [ "$(id -u)" != "0" ]; then
		abort "Run as root (sudo)."
	fi
}

ensure_dir() {
	# ensure_dir path [owner] [mode]
	local dir="$1" owner="${2:-}" mode="${3:-}"
	[ -d "$dir" ] || mkdir -p "$dir"
	[ -n "$owner" ] && chown -R "$owner" "$dir" || true
	[ -n "$mode" ] && chmod "$mode" "$dir" || true
}

pkg_mgr=""
detect_pkg_mgr() {
	if command -v yum >/dev/null 2>&1; then pkg_mgr="yum"; return; fi
	if command -v dnf >/dev/null 2>&1; then pkg_mgr="dnf"; return; fi
	if command -v apt-get >/dev/null 2>&1; then pkg_mgr="apt"; return; fi
	abort "No supported package manager found (yum/dnf/apt)."
}

install_os_prereqs() {
	log "Installing OS prerequisites..."
	detect_pkg_mgr
	case "$pkg_mgr" in
		yum|dnf)
			$pkg_mgr -y install $COMMON_RPMS | cat
			;;
		apt)
			apt-get update | cat
			# shellcheck disable=SC2086
			DEBIAN_FRONTEND=noninteractive apt-get install -y $COMMON_DEBS | cat
			;;
	esac
	log "OS prerequisites installed."
}

create_os_users() {
	log "Ensuring OS users and groups..."
	getent group "$WLS_OS_GROUP" >/dev/null 2>&1 || groupadd "$WLS_OS_GROUP"
	if ! id "$WLS_OS_USER" >/dev/null 2>&1; then
		useradd -m -g "$WLS_OS_GROUP" -s /bin/bash "$WLS_OS_USER"
	fi
	getent group "$DB_OS_GROUP" >/dev/null 2>&1 || groupadd "$DB_OS_GROUP"
	if ! id "$DB_OS_USER" >/dev/null 2>&1; then
		useradd -m -g "$DB_OS_GROUP" -s /bin/bash "$DB_OS_USER"
	fi
	log "OS users/groups ensured."
}

install_jdk() {
	[ "${INSTALL_JDK,,}" = "true" ] || return 0
	[ -n "$JAVA_HOME" ] || abort "JAVA_HOME must be set in $ENV_FILE"
	if [ -x "$JAVA_HOME/bin/java" ]; then
		log "JDK already present at $JAVA_HOME"
		return 0
	fi
	[ -f "$JDK_TARBALL" ] || abort "JDK_TARBALL not found: $JDK_TARBALL"
	ensure_dir "$(dirname "$JAVA_HOME")"
	log "Extracting JDK from $JDK_TARBALL to $(dirname "$JAVA_HOME")"
	tar_top_dir=$(tar -tf "$JDK_TARBALL" | head -1 | cut -d/ -f1)
	tar -xzf "$JDK_TARBALL" -C "$(dirname "$JAVA_HOME")"
	if [ "$tar_top_dir" != "$(basename "$JAVA_HOME")" ]; then
		mv -f "$(dirname "$JAVA_HOME")/$tar_top_dir" "$JAVA_HOME"
	fi
	log "JAVA_HOME set up at $JAVA_HOME"
}

install_weblogic() {
	[ "${INSTALL_WLS,,}" = "true" ] || return 0
	[ -n "$MW_HOME" ] || abort "MW_HOME must be set"
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	if [ -x "$WL_HOME_EFFECTIVE/server/bin/startWebLogic.sh" ]; then
		log "WebLogic already installed at $WL_HOME_EFFECTIVE"
		return 0
	fi
	[ -f "$WLS_JAR" ] || abort "WLS_JAR not found: $WLS_JAR"
	[ -x "$JAVA_HOME/bin/java" ] || abort "JAVA_HOME/bin/java not executable"
	ensure_dir "$MW_HOME" "$WLS_OS_USER:$WLS_OS_GROUP"
	ensure_dir "$ORACLE_INVENTORY"

	WORK_TMP="$WORK_DIR/wls"
	ensure_dir "$WORK_TMP"

	cat > "$WORK_TMP/oraInst.loc" <<EOF
inventory_loc=$ORACLE_INVENTORY
inst_group=$WLS_OS_GROUP
EOF

	cat > "$WORK_TMP/wls.rsp" <<'EOF'
[ENGINE]
Response File Version=1.0.0.0.0
[GENERIC]
ORACLE_HOME=<ORACLE_HOME>
INSTALL_TYPE=WebLogic Server
EOF
	# Inject ORACLE_HOME dynamically
	sed -i "s|<ORACLE_HOME>|$MW_HOME|g" "$WORK_TMP/wls.rsp"

	log "Installing WebLogic into $MW_HOME (silent)..."
	su - "$WLS_OS_USER" -c "\
		'$JAVA_HOME/bin/java' -jar '$WLS_JAR' \
		-silent -responseFile '$WORK_TMP/wls.rsp' -invPtrLoc '$WORK_TMP/oraInst.loc' -ignorePrereq -force | cat"
	log "WebLogic installed at $WL_HOME_EFFECTIVE"
}

create_wls_domain() {
	[ "${CREATE_WLS_DOMAIN,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	if [ -f "$DOMAIN_HOME/bin/startWebLogic.sh" ]; then
		log "Domain already exists at $DOMAIN_HOME"
		return 0
	fi
	ensure_dir "$DOMAIN_HOME" "$WLS_OS_USER:$WLS_OS_GROUP"
	log "Creating WebLogic domain at $DOMAIN_HOME (offline)..."
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/create_domain.py' \
		--domain_home '$DOMAIN_HOME' \
		--wl_home '$WL_HOME_EFFECTIVE' \
		--java_home '$JAVA_HOME' \
		--admin_port '$WL_ADMIN_PORT' \
		--admin_password '$WL_ADMIN_PASSWORD' \
		--production_mode '${WL_PRODUCTION_MODE,,}' \
		--listen_address '${WL_LISTEN_ADDRESS:-}' | cat"
	log "Domain created."
}

configure_wls_jdbc() {
	[ "${CONFIGURE_WLS_JDBC,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	[ -f "$DOMAIN_HOME/config/config.xml" ] || abort "Domain not found at $DOMAIN_HOME"
	local jdbc_url="jdbc:oracle:thin:@//${DB_HOST}:${DB_PORT}/${DB_SERVICE}"
	log "Configuring offline JDBC DataSource ${JDBC_DS_NAME} -> ${jdbc_url}"
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/configure_datasource.py' \
		--domain_home '$DOMAIN_HOME' \
		--ds_name '$JDBC_DS_NAME' \
		--ds_jndi '$JDBC_DS_JNDI' \
		--jdbc_url '$jdbc_url' \
		--jdbc_driver '$JDBC_DRIVER' \
		--db_user '$DB_APP_USER' \
		--db_password '$DB_APP_PASSWORD' | cat"
	log "JDBC DataSource configured."
}

install_ouaf() {
	[ "${INSTALL_OUAF,,}" = "true" ] || return 0
	[ -n "$OUAF_INSTALLER" ] && [ -f "$OUAF_INSTALLER" ] || abort "OUAF_INSTALLER missing"
	[ -n "$OUAF_RESPONSE_FILE" ] && [ -f "$OUAF_RESPONSE_FILE" ] || abort "OUAF_RESPONSE_FILE missing"
	log "Running OUAF silent installer..."
	if [[ "$OUAF_INSTALLER" == *.jar ]]; then
		su - "$WLS_OS_USER" -c "\
			'$JAVA_HOME/bin/java' -jar '$OUAF_INSTALLER' -silent -responseFile '$OUAF_RESPONSE_FILE' | cat"
	else
		chmod +x "$OUAF_INSTALLER"
		su - "$WLS_OS_USER" -c "'$OUAF_INSTALLER' -silent -responseFile '$OUAF_RESPONSE_FILE' | cat"
	fi
	log "OUAF installer completed."
}

install_c2m() {
	[ "${INSTALL_C2M,,}" = "true" ] || return 0
	[ -n "$C2M_INSTALLER" ] && [ -f "$C2M_INSTALLER" ] || abort "C2M_INSTALLER missing"
	[ -n "$C2M_RESPONSE_FILE" ] && [ -f "$C2M_RESPONSE_FILE" ] || abort "C2M_RESPONSE_FILE missing"
	log "Running C2M silent installer..."
	if [[ "$C2M_INSTALLER" == *.jar ]]; then
		su - "$WLS_OS_USER" -c "\
			'$JAVA_HOME/bin/java' -jar '$C2M_INSTALLER' -silent -responseFile '$C2M_RESPONSE_FILE' | cat"
	else
		chmod +x "$C2M_INSTALLER"
		su - "$WLS_OS_USER" -c "'$C2M_INSTALLER' -silent -responseFile '$C2M_RESPONSE_FILE' | cat"
	fi
	log "C2M installer completed."
}

load_db() {
	[ "${LOAD_DB,,}" = "true" ] || return 0
	if [ -n "$DB_INSTALLER" ] && [ -f "$DB_INSTALLER" ]; then
		log "Running vendor DB installer..."
		chmod +x "$DB_INSTALLER" || true
		"$DB_INSTALLER" ${DB_INSTALLER_RESPONSE:+-responseFile "$DB_INSTALLER_RESPONSE"} | cat
		log "Vendor DB installer finished."
	else
		log "No vendor DB installer supplied. Skipping."
	fi
}

deploy_app() {
	[ "${DEPLOY_APP,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	[ -f "$PRODUCT_EAR" ] || abort "PRODUCT_EAR not found: $PRODUCT_EAR"
	local admin_url="t3://${WL_LISTEN_ADDRESS:-127.0.0.1}:$WL_ADMIN_PORT"
	log "Deploying application EAR via WLST to $admin_url"
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/deploy_app.py' \
		--admin_url '$admin_url' \
		--admin_user '$WL_ADMIN_USER' \
		--admin_password '$WL_ADMIN_PASSWORD' \
		--app_path '$PRODUCT_EAR' \
		--targets 'AdminServer' | cat"
	log "Deployment requested. Ensure AdminServer is running."
}

main() {
	require_root
	ensure_dir "$STAGING_DIR"
	ensure_dir "$WORK_DIR"
	[ "${INSTALL_OS_PREREQS,,}" = "true" ] && install_os_prereqs
	[ "${CREATE_OS_USERS,,}" = "true" ] && create_os_users
	install_jdk
	install_weblogic
	create_wls_domain
	configure_wls_jdbc
	install_ouaf
	install_c2m
	load_db
	deploy_app
	log "All requested steps completed."
}

main "$@"