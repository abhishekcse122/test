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

install_ccb() {
	[ "${INSTALL_CCB,,}" = "true" ] || return 0
	[ -n "$CCB_INSTALLER" ] && [ -f "$CCB_INSTALLER" ] || abort "CCB_INSTALLER missing"
	[ -n "$CCB_RESPONSE_FILE" ] && [ -f "$CCB_RESPONSE_FILE" ] || abort "CCB_RESPONSE_FILE missing"
	log "Running CCB silent installer..."
	if [[ "$CCB_INSTALLER" == *.jar ]]; then
		su - "$WLS_OS_USER" -c "\
			'$JAVA_HOME/bin/java' -jar '$CCB_INSTALLER' -silent -responseFile '$CCB_RESPONSE_FILE' | cat"
	else
		chmod +x "$CCB_INSTALLER"
		su - "$WLS_OS_USER" -c "'$CCB_INSTALLER' -silent -responseFile '$CCB_RESPONSE_FILE' | cat"
	fi
	log "CCB installer completed."
}

install_mdm() {
	[ "${INSTALL_MDM,,}" = "true" ] || return 0
	[ -n "$MDM_INSTALLER" ] && [ -f "$MDM_INSTALLER" ] || abort "MDM_INSTALLER missing"
	[ -n "$MDM_RESPONSE_FILE" ] && [ -f "$MDM_RESPONSE_FILE" ] || abort "MDM_RESPONSE_FILE missing"
	log "Running MDM silent installer..."
	if [[ "$MDM_INSTALLER" == *.jar ]]; then
		su - "$WLS_OS_USER" -c "\
			'$JAVA_HOME/bin/java' -jar '$MDM_INSTALLER' -silent -responseFile '$MDM_RESPONSE_FILE' | cat"
	else
		chmod +x "$MDM_INSTALLER"
		su - "$WLS_OS_USER" -c "'$MDM_INSTALLER' -silent -responseFile '$MDM_RESPONSE_FILE' | cat"
	fi
	log "MDM installer completed."
}

install_wam() {
	[ "${INSTALL_WAM,,}" = "true" ] || return 0
	[ -n "$WAM_INSTALLER" ] && [ -f "$WAM_INSTALLER" ] || abort "WAM_INSTALLER missing"
	[ -n "$WAM_RESPONSE_FILE" ] && [ -f "$WAM_RESPONSE_FILE" ] || abort "WAM_RESPONSE_FILE missing"
	log "Running WAM silent installer..."
	if [[ "$WAM_INSTALLER" == *.jar ]]; then
		su - "$WLS_OS_USER" -c "\
			'$JAVA_HOME/bin/java' -jar '$WAM_INSTALLER' -silent -responseFile '$WAM_RESPONSE_FILE' | cat"
	else
		chmod +x "$WAM_INSTALLER"
		su - "$WLS_OS_USER" -c "'$WAM_INSTALLER' -silent -responseFile '$WAM_RESPONSE_FILE' | cat"
	fi
	log "WAM installer completed."
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

run_rcu() {
	[ "${RUN_RCU,,}" = "true" ] || return 0
	[ -n "$RCU_BIN" ] && [ -x "$RCU_BIN" ] || abort "RCU_BIN not set or not executable"
	local connect="${DB_HOST}:${DB_PORT}/${DB_SERVICE}"
	local schema_pass="${RCU_SCHEMA_PASSWORD:-$DB_SYS_PASSWORD}"
	log "Running RCU to create schemas: prefix=$RCU_PREFIX components=[$RCU_COMPONENTS]"
	"$RCU_BIN" -silent -createRepository \
		-databaseType ORACLE -connectString "$connect" \
		-dbUser SYS -dbRole SYSDBA -useSamePasswordForAllSchemaUsers true \
		-schemaPrefix "$RCU_PREFIX" -componentList "$RCU_COMPONENTS" \
		-fixMissingSchemaPassword true \
		-rcuLogDir "$WORK_DIR/rcu" \
		-invPtrLoc "$WORK_DIR/wls/oraInst.loc" \
		-selectDependentsForComponents true \
		-variables STB.SCHEMAPASSWORD=$schema_pass,OPSS.SCHEMAPASSWORD=$schema_pass,IAU.SCHEMAPASSWORD=$schema_pass,IAU_APPEND.SCHEMAPASSWORD=$schema_pass,IAU_VIEWER.SCHEMAPASSWORD=$schema_pass,MDS.SCHEMAPASSWORD=$schema_pass,WLS.SCHEMAPASSWORD=$schema_pass | cat
	log "RCU creation attempted. Review logs in $WORK_DIR/rcu."
}

create_managed_server() {
	[ "${CREATE_MANAGED_SERVER,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	[ -f "$DOMAIN_HOME/config/config.xml" ] || abort "Domain not found at $DOMAIN_HOME"
	log "Creating managed server $MS_NAME ..."
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/create_managed_server.py' \
		--domain_home '$DOMAIN_HOME' \
		--server_name '$MS_NAME' \
		--listen_address '${MS_LISTEN_ADDRESS:-}' \
		--listen_port '$MS_LISTEN_PORT' | cat"
	log "Managed server ensured: $MS_NAME"
}

configure_machine_and_nm() {
	[ "${CONFIGURE_NODE_MANAGER,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	[ -f "$DOMAIN_HOME/config/config.xml" ] || abort "Domain not found at $DOMAIN_HOME"
	log "Configuring Machine $MACHINE_NAME and Node Manager mapping..."
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/configure_machine_nm.py' \
		--domain_home '$DOMAIN_HOME' \
		--machine_name '$MACHINE_NAME' \
		--nm_listen_address '${NM_LISTEN_ADDRESS:-}' \
		--nm_listen_port '$NM_LISTEN_PORT' \
		--nm_type '${NM_TYPE:-Plain}' \
		--server_name '$MS_NAME' | cat"
	if [ "${NM_ENROLL,,}" = "true" ]; then
		log "Enrolling Node Manager for domain..."
		su - "$WLS_OS_USER" -c "\
			'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/enroll_nm.py' \
			--domain_home '$DOMAIN_HOME' \
			--nm_home '${NM_HOME:-$WL_HOME_EFFECTIVE/common/nodemanager}' | cat"
	fi
	log "Machine/Node Manager configured."
}

enable_ssl_managed() {
	[ "${ENABLE_SSL_MANAGED,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	[ -f "$DOMAIN_HOME/config/config.xml" ] || abort "Domain not found at $DOMAIN_HOME"
	log "Enabling SSL for $MS_NAME on port $SSL_LISTEN_PORT ..."
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/enable_ssl_server.py' \
		--domain_home '$DOMAIN_HOME' \
		--server_name '$MS_NAME' \
		--ssl_listen_port '$SSL_LISTEN_PORT' \
		--keystores_mode '$KEYSTORES_MODE' \
		--id_ks_path '${IDENTITY_KEYSTORE_PATH:-}' \
		--id_ks_type '${IDENTITY_KEYSTORE_TYPE:-JKS}' \
		--id_ks_pass '${IDENTITY_KEYSTORE_PASSWORD:-}' \
		--trust_ks_path '${TRUST_KEYSTORE_PATH:-}' \
		--trust_ks_type '${TRUST_KEYSTORE_TYPE:-JKS}' \
		--trust_ks_pass '${TRUST_KEYSTORE_PASSWORD:-}' \
		--hostname_verification '${HOSTNAME_VERIFICATION:-false}' \
		--use_jsse '${USE_JSSE:-true}' | cat"
	log "SSL configured."
}

configure_xml_registry() {
	[ "${CONFIGURE_XML_REGISTRY,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	[ -f "$DOMAIN_HOME/config/config.xml" ] || abort "Domain not found at $DOMAIN_HOME"
	log "Configuring XML Registry entries..."
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/configure_xml_registry.py' \
		--domain_home '$DOMAIN_HOME' \
		--entries '${XML_REGISTRY_ENTRIES:-}' | cat"
	log "XML Registry configured."
}

set_ms_memory() {
	[ "${TUNE_JVM_MEMORY,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	[ -f "$DOMAIN_HOME/config/config.xml" ] || abort "Domain not found at $DOMAIN_HOME"
	local args="-Xms$MS_XMS -Xmx$MS_XMX ${EXTRA_SERVER_ARGS}"
	log "Setting server start args for $MS_NAME: $args"
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/set_server_memory.py' \
		--domain_home '$DOMAIN_HOME' \
		--server_name '$MS_NAME' \
		--args '$args' | cat"
	log "Memory tuning applied."
}

create_ms_bootprops() {
	# Ensure boot.properties for managed server to allow non-interactive start
	local sec_dir="$DOMAIN_HOME/servers/$MS_NAME/security"
	ensure_dir "$sec_dir" "$WLS_OS_USER:$WLS_OS_GROUP"
	if [ ! -f "$sec_dir/boot.properties" ]; then
		cat > "$sec_dir/boot.properties" <<EOF
username=$WL_ADMIN_USER
password=$WL_ADMIN_PASSWORD
EOF
		chown "$WLS_OS_USER:$WLS_OS_GROUP" "$sec_dir/boot.properties"
	fi
}

deploy_spl_apps() {
	[ "${DEPLOY_SPL_APPS,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
	local admin_url="t3://${WL_LISTEN_ADDRESS:-127.0.0.1}:$WL_ADMIN_PORT"
	[ -f "$SPLSERVICE_EAR" ] || abort "SPLSERVICE_EAR not found: $SPLSERVICE_EAR"
	[ -f "$SPLWEB_EAR" ] || abort "SPLWEB_EAR not found: $SPLWEB_EAR"
	log "Deploying SPLService and SPLWeb with deployment orders $SPLSERVICE_ORDER/$SPLWEB_ORDER to $DEPLOY_TARGETS"
	su - "$WLS_OS_USER" -c "\
		'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/deploy_with_order.py' \
		--admin_url '$admin_url' \
		--admin_user '$WL_ADMIN_USER' \
		--admin_password '$WL_ADMIN_PASSWORD' \
		--app1_path '$SPLSERVICE_EAR' \
		--app1_order '$SPLSERVICE_ORDER' \
		--app2_path '$SPLWEB_EAR' \
		--app2_order '$SPLWEB_ORDER' \
		--targets '$DEPLOY_TARGETS' | cat"
	log "Deployments submitted."
}

start_managed_server() {
	[ "${START_MANAGED_SERVER,,}" = "true" ] || return 0
	if [ "${USE_NODEMANAGER,,}" = "true" ]; then
		WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
		[ -x "$WL_HOME_EFFECTIVE/common/bin/wlst.sh" ] || abort "wlst.sh not found under $WL_HOME_EFFECTIVE"
		local admin_url="t3://${WL_LISTEN_ADDRESS:-127.0.0.1}:$WL_ADMIN_PORT"
		log "Starting managed server $MS_NAME via Node Manager..."
		su - "$WLS_OS_USER" -c "\
			'$WL_HOME_EFFECTIVE/common/bin/wlst.sh' '$SCRIPT_DIR/wlst/start_ms_nm.py' \
			--admin_url '$admin_url' \
			--admin_user '$WL_ADMIN_USER' \
			--admin_password '$WL_ADMIN_PASSWORD' \
			--nm_listen_address '${NM_LISTEN_ADDRESS:-127.0.0.1}' \
			--nm_listen_port '$NM_LISTEN_PORT' \
			--nm_type '${NM_TYPE:-Plain}' \
			--domain_home '$DOMAIN_HOME' \
			--server_name '$MS_NAME' | cat"
	else
		create_ms_bootprops
		log "Starting managed server $MS_NAME with startManagedWebLogic.sh ..."
		su - "$WLS_OS_USER" -c "\
			'$DOMAIN_HOME/bin/startManagedWebLogic.sh' '$MS_NAME' 't3://${WL_LISTEN_ADDRESS:-127.0.0.1}:$WL_ADMIN_PORT' | cat"
	fi
}

start_nodemanager() {
	[ "${START_NODEMANAGER,,}" = "true" ] || return 0
	WL_HOME_EFFECTIVE="${WL_HOME:-$MW_HOME/wlserver}"
	local nm_start="$WL_HOME_EFFECTIVE/common/nodemanager/startNodeManager.sh"
	[ -x "$nm_start" ] || abort "startNodeManager.sh not found at $nm_start"
	ensure_dir "${NODEMANAGER_LOG_DIR}"
	# Check if port is already listening
	if command -v ss >/dev/null 2>&1; then
		if ss -ltn | grep -q ":${NM_LISTEN_PORT} "; then
			log "Node Manager appears to be running on port ${NM_LISTEN_PORT}."
			return 0
		fi
	elif command -v netstat >/dev/null 2>&1; then
		if netstat -ltn 2>/dev/null | grep -q ":${NM_LISTEN_PORT} "; then
			log "Node Manager appears to be running on port ${NM_LISTEN_PORT}."
			return 0
		fi
	fi
	log "Starting Node Manager in background..."
	su - "$WLS_OS_USER" -c "nohup '$nm_start' > '${NODEMANAGER_LOG_DIR}/nodemanager.out' 2>&1 & echo $! > '${NODEMANAGER_LOG_DIR}/nodemanager.pid'"
	log "Node Manager start attempted; logs: ${NODEMANAGER_LOG_DIR}/nodemanager.out"
}

main() {
	require_root
	ensure_dir "$STAGING_DIR"
	ensure_dir "$WORK_DIR"
	[ "${INSTALL_OS_PREREQS,,}" = "true" ] && install_os_prereqs
	[ "${CREATE_OS_USERS,,}" = "true" ] && create_os_users
	install_jdk
	run_rcu
	install_weblogic
	create_wls_domain
	configure_wls_jdbc
	install_ouaf
	install_ccb
	install_mdm
	install_wam
	# Optional per-product installers
	install_c2m
	configure_machine_and_nm
	start_nodemanager
	create_managed_server
	enable_ssl_managed
	configure_xml_registry
	set_ms_memory
	deploy_spl_apps
	start_managed_server
	log "All requested steps completed."
}

main "$@"