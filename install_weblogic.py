#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from textwrap import dedent
import grp


class CommandError(Exception):
    pass


def run_cmd(command, env=None, check=True, cwd=None):
    print(f"[exec] {' '.join(command)}")
    process = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=cwd,
        text=True,
    )
    if check and process.returncode != 0:
        print(process.stdout)
        raise CommandError(f"Command failed with exit code {process.returncode}: {' '.join(command)}")
    return process.stdout


def is_root() -> bool:
    try:
        return os.geteuid() == 0
    except AttributeError:
        return False


def detect_pkg_mgr() -> str:
    if shutil.which("apt-get"):
        return "apt"
    if shutil.which("dnf"):
        return "dnf"
    if shutil.which("yum"):
        return "yum"
    return "unknown"


def install_openjdk(version: int) -> None:
    pkg_mgr = detect_pkg_mgr()
    print(f"Detected package manager: {pkg_mgr}")
    if pkg_mgr == "unknown":
        print("No supported package manager detected. Please install JDK manually or provide JAVA_HOME.")
        return

    if not is_root():
        print("Warning: Not running as root. Attempting to use sudo for package installation.")
        sudo = shutil.which("sudo")
        if not sudo:
            print("sudo is not available. Skipping package installation. Please install JDK manually.")
            return
        sudo_prefix = [sudo, "-n"]
    else:
        sudo_prefix = []

    if pkg_mgr == "apt":
        if version == 8:
            pkg = "openjdk-8-jdk"
        elif version == 11:
            pkg = "openjdk-11-jdk"
        elif version == 17:
            pkg = "openjdk-17-jdk"
        else:
            pkg = f"openjdk-{version}-jdk"
        run_cmd(sudo_prefix + ["apt-get", "update", "-y"])
        run_cmd(sudo_prefix + ["apt-get", "install", "-y", pkg])
    elif pkg_mgr in ("dnf", "yum"):
        if version == 8:
            pkg = "java-1.8.0-openjdk-devel"
        elif version == 11:
            pkg = "java-11-openjdk-devel"
        elif version == 17:
            pkg = "java-17-openjdk-devel"
        else:
            pkg = f"java-{version}-openjdk-devel"
        run_cmd(sudo_prefix + [pkg_mgr, "install", "-y", pkg])


def find_java_home() -> str:
    java_path = shutil.which("java")
    if not java_path:
        return ""
    try:
        real = run_cmd(["readlink", "-f", java_path], check=False).strip()
    except Exception:
        real = java_path
    # Typical path: /usr/lib/jvm/java-11-openjdk-amd64/bin/java -> JAVA_HOME is parent of bin
    bin_dir = Path(real).parent if real else Path(java_path).parent
    java_home = str(bin_dir.parent)
    return java_home


def ensure_java(jdk_version: int, prefer_system: bool, preferred_java_home: str | None) -> str:
    # If caller provided a fixed JAVA_HOME, honor it first
    if preferred_java_home:
        candidate = Path(preferred_java_home)
        if Path(candidate, "bin", "java").exists():
            os.environ["JAVA_HOME"] = str(candidate)
            print(f"Using provided JAVA_HOME={candidate}")
            return str(candidate)
        else:
            raise RuntimeError(
                f"Provided --java-home path does not contain bin/java: {candidate}. Install JDK there or omit --java-home."
            )

    existing_java_home = os.environ.get("JAVA_HOME", "").strip()
    if existing_java_home and Path(existing_java_home, "bin", "java").exists():
        print(f"Using existing JAVA_HOME={existing_java_home}")
        return existing_java_home

    java_home = find_java_home()
    if java_home and Path(java_home, "bin", "java").exists():
        print(f"Detected java at {java_home}. Setting JAVA_HOME.")
        os.environ["JAVA_HOME"] = java_home
        return java_home

    if prefer_system:
        print("No JAVA_HOME detected. Attempting to install OpenJDK via system package manager.")
        install_openjdk(jdk_version)
        java_home = find_java_home()
        if java_home and Path(java_home, "bin", "java").exists():
            print(f"Installed JDK detected at {java_home}")
            os.environ["JAVA_HOME"] = java_home
            return java_home

    raise RuntimeError(
        "JDK not found. Install JDK manually or re-run with --install-jdk-from-system to allow package installation."
    )


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def resolve_writable_default(path_root: Path, fallback_root: Path) -> Path:
    try:
        ensure_dir(path_root)
        test_file = path_root / ".write_test"
        test_file.write_text("ok")
        test_file.unlink()
        return path_root
    except Exception:
        print(f"No write permission for {path_root}. Falling back to {fallback_root}")
        ensure_dir(fallback_root)
        return fallback_root


def write_file(path: Path, content: str, mode: int = 0o644) -> None:
    ensure_dir(path.parent)
    path.write_text(content)
    os.chmod(path, mode)


def install_weblogic_silent(
    installer_jar: Path,
    oracle_home: Path,
    inventory_dir: Path,
    install_type: str,
    java_home: Path,
    logs_dir: Path,
) -> None:
    if (oracle_home / "wlserver").exists():
        print(f"WebLogic already appears installed in {oracle_home}")
        return

    ensure_dir(logs_dir)

    response_file = logs_dir / "wls_install.rsp"
    pointer_file = logs_dir / "oraInst.loc"

    # Build response (sufficient for generic installer)
    response_content = dedent(
        f"""
        [ENGINE]
        Response File Version=1.0.0.0.0
        [GENERIC]
        ORACLE_HOME={oracle_home}
        INSTALL_TYPE={install_type}
        """
    ).strip() + "\n"

    # Determine appropriate group name for oraInst.loc
    try:
        gid = os.getgid() if hasattr(os, "getgid") else 0
        group_name = grp.getgrgid(gid).gr_name
    except Exception:
        group_name = "oinstall" if is_root() else "users"

    pointer_content = dedent(
        f"""
        inventory_loc={inventory_dir}
        inst_group={group_name}
        """
    ).strip() + "\n"

    write_file(response_file, response_content)
    write_file(pointer_file, pointer_content)

    ensure_dir(inventory_dir)

    java_bin = str(Path(java_home) / "bin" / "java")
    log_file = logs_dir / "wls_install.out"

    cmd = [
        java_bin,
        "-jar",
        str(installer_jar),
        "-silent",
        "-responseFile",
        str(response_file),
        "-invPtrLoc",
        str(pointer_file),
        "-ignoreSysPrereqs",
        "-noConsole",
    ]

    print(f"Starting WebLogic silent install into {oracle_home}")
    output = run_cmd(cmd, env={**os.environ, "JAVA_HOME": str(java_home)})
    write_file(log_file, output)

    if not (oracle_home / "wlserver").exists():
        raise RuntimeError("WebLogic installation did not complete successfully; wlserver not found.")

    print("WebLogic installation completed.")


def generate_wlst_script(
    oracle_home: Path,
    domain_home: Path,
    domain_name: str,
    admin_user: str,
    admin_password: str,
    listen_address: str,
    listen_port: int,
    admin_ssl_port: int,
    managed_server_name: str,
    managed_listen_address: str,
    managed_listen_port: int,
    managed_ssl_port: int,
    node_manager_name: str,
    node_manager_listen_address: str,
    node_manager_listen_port: int,
    node_manager_type: str,
    production_mode: bool,
    java_home: Path,
) -> str:
    mode = "prod" if production_mode else "dev"
    # WLST offline script
    return dedent(
        f"""
        import os
        oracle_home = r"{oracle_home}"
        domain_home = r"{domain_home}"
        domain_name = r"{domain_name}"
        admin_user = r"{admin_user}"
        admin_password = r"{admin_password}"
        listen_address = r"{listen_address}"
        listen_port = int({listen_port})
        admin_ssl_port = int({admin_ssl_port})
        
        managed_server_name = r"{managed_server_name}"
        managed_listen_address = r"{managed_listen_address}"
        managed_listen_port = int({managed_listen_port})
        managed_ssl_port = int({managed_ssl_port})
        
        node_manager_name = r"{node_manager_name}"
        node_manager_listen_address = r"{node_manager_listen_address}"
        node_manager_listen_port = int({node_manager_listen_port})
        node_manager_type = r"{node_manager_type}"
        
        java_home = r"{java_home}"
        
        template_path = os.path.join(oracle_home, 'wlserver', 'common', 'templates', 'wls', 'wls.jar')
        readTemplate(template_path)
        
        # Configure admin user
        cd('Security/base_domain/User/weblogic')
        cmo.setName(admin_user)
        cmo.setUserPassword(admin_password)
        
        # Configure AdminServer
        cd('/')
        cd('Servers/AdminServer')
        set('ListenAddress', listen_address)
        set('ListenPort', listen_port)
        try:
            create('AdminServer','SSL')
        except:
            pass
        cd('SSL/AdminServer')
        cmo.setEnabled(True)
        set('ListenPort', admin_ssl_port)
        cd('/')
        
        # Create Node Manager and Machine
        create(node_manager_name, 'Machine')
        cd(f'Machines/{{node_manager_name}}')
        create(node_manager_name, 'NodeManager')
        cd(f'NodeManager/{{node_manager_name}}')
        set('ListenAddress', node_manager_listen_address)
        set('ListenPort', node_manager_listen_port)
        set('NMType', node_manager_type)
        cd('/')
        
        # Create Managed Server
        create(managed_server_name, 'Server')
        cd(f'Servers/{{managed_server_name}}')
        set('ListenAddress', managed_listen_address)
        set('ListenPort', managed_listen_port)
        try:
            create(managed_server_name, 'SSL')
        except:
            pass
        cd(f'SSL/{{managed_server_name}}')
        cmo.setEnabled(True)
        set('ListenPort', managed_ssl_port)
        cd(f'/Servers/{{managed_server_name}}')
        try:
            mbean = getMBean(f'/Machines/{{node_manager_name}}')
            if mbean is not None:
                cmo.setMachine(mbean)
        except:
            pass
        cd('/')
        
        # Domain options and write
        setOption('DomainName', domain_name)
        setOption('OverwriteDomain', 'true')
        setOption('ServerStartMode', '{mode}')
        setOption('JavaHome', java_home)
        
        writeDomain(domain_home)
        closeTemplate()
        
        # Create boot.properties for AdminServer
        security_dir = os.path.join(domain_home, 'servers', 'AdminServer', 'security')
        if not os.path.isdir(security_dir):
            os.makedirs(security_dir)
        with open(os.path.join(security_dir, 'boot.properties'), 'w') as f:
            f.write('username=' + admin_user + '\n')
            f.write('password=' + admin_password + '\n')
        
        exit()
        """
    ).strip() + "\n"


def create_domain_via_wlst(
    oracle_home: Path,
    java_home: Path,
    domain_home: Path,
    domain_name: str,
    admin_user: str,
    admin_password: str,
    listen_address: str,
    listen_port: int,
    admin_ssl_port: int,
    managed_server_name: str,
    managed_listen_address: str,
    managed_listen_port: int,
    managed_ssl_port: int,
    node_manager_name: str,
    node_manager_listen_address: str,
    node_manager_listen_port: int,
    node_manager_type: str,
    production_mode: bool,
    logs_dir: Path,
    wl_home: Path,
) -> None:
    if (domain_home / "config" / "config.xml").exists():
        print(f"Domain already exists at {domain_home}")
        return

    wlst_script_content = generate_wlst_script(
        oracle_home=oracle_home,
        domain_home=domain_home,
        domain_name=domain_name,
        admin_user=admin_user,
        admin_password=admin_password,
        listen_address=listen_address,
        listen_port=listen_port,
        admin_ssl_port=admin_ssl_port,
        managed_server_name=managed_server_name,
        managed_listen_address=managed_listen_address,
        managed_listen_port=managed_listen_port,
        managed_ssl_port=managed_ssl_port,
        node_manager_name=node_manager_name,
        node_manager_listen_address=node_manager_listen_address,
        node_manager_listen_port=node_manager_listen_port,
        node_manager_type=node_manager_type,
        production_mode=production_mode,
        java_home=java_home,
    )

    ensure_dir(logs_dir)
    wlst_script_path = logs_dir / "create_domain.py"
    write_file(wlst_script_path, wlst_script_content)

    wlst_sh = oracle_home / "oracle_common" / "common" / "bin" / "wlst.sh"
    if not wlst_sh.exists():
        raise RuntimeError(f"wlst.sh not found at {wlst_sh}. Is WebLogic installed correctly?")

    env = {
        **os.environ,
        "JAVA_HOME": str(java_home),
        "ORACLE_HOME": str(oracle_home),
        "WL_HOME": str(wl_home),
        "DOMAIN_HOME": str(domain_home),
    }
    cmd = [str(wlst_sh), str(wlst_script_path)]
    print(f"Running WLST to create domain {domain_name} at {domain_home}")
    output = run_cmd(cmd, env=env)
    write_file(logs_dir / "wlst_create_domain.out", output)

    if not (domain_home / "config" / "config.xml").exists():
        raise RuntimeError("Domain creation failed: config.xml not found")

    print("Domain creation completed.")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Install JDK (optional), install WebLogic silently from installer JAR, and create a domain via WLST."
    )
    parser.add_argument("--wls-installer", required=True, help="Path to WebLogic generic installer JAR (e.g., fmw_12.2.1.4.0_wls.jar)")
    parser.add_argument("--oracle-home", default="/app/oracle/middleware/ORACLE_HOME", help="Target ORACLE_HOME for WebLogic installation")
    parser.add_argument("--inventory", default="/opt/oraInventory", help="Oracle inventory directory location")
    parser.add_argument("--install-type", default="WebLogic Server", help="INSTALL_TYPE for response file (e.g., 'WebLogic Server')")

    parser.add_argument("--java-home", default="/app/oracle/java", help="Use an explicit JAVA_HOME (expects bin/java under this path)")
    parser.add_argument("--jdk-version", type=int, default=11, help="JDK major version to install/detect (8, 11, 17)")
    parser.add_argument("--install-jdk-from-system", action="store_true", help="Install OpenJDK from system package manager if JAVA_HOME is not set")

    parser.add_argument("--domain-name", default="c2m_domain", help="Domain name")
    parser.add_argument("--domain-home", default="/app/oracle/middleware/ORACLE_HOME/user_projects/domains/c2m_domain", help="Domain home directory")
    parser.add_argument("--wl-home", default="/app/oracle/middleware/ORACLE_HOME/wlserver", help="WL_HOME directory (auto-derived from ORACLE_HOME if not set)")

    parser.add_argument("--admin-user", default="weblogic", help="Admin username")
    parser.add_argument("--admin-password", default="Welcome123", help="Admin password")
    parser.add_argument("--admin-address", default="", help="Admin server listen address (default: empty for all interfaces)")
    parser.add_argument("--admin-port", type=int, default=7001, help="Admin server listen port")
    parser.add_argument("--admin-ssl-port", type=int, default=7002, help="Admin server SSL listen port")
    parser.add_argument("--production-mode", action="store_true", help="Create domain in production mode (default: development)")

    parser.add_argument("--managed-server-name", default="C2M_MS1", help="Managed server name")
    parser.add_argument("--managed-address", default="", help="Managed server listen address")
    parser.add_argument("--managed-port", type=int, default=7500, help="Managed server listen port")
    parser.add_argument("--managed-ssl-port", type=int, default=7501, help="Managed server SSL listen port")

    parser.add_argument("--nodemanager-name", default="C2M_N1", help="Node Manager name (creates a Machine and NM)")
    parser.add_argument("--nodemanager-address", default="", help="Node Manager listen address")
    parser.add_argument("--nodemanager-port", type=int, default=5556, help="Node Manager listen port")
    parser.add_argument("--nodemanager-type", default="Plain", choices=["Plain", "SSL"], help="Node Manager type")

    parser.add_argument("--logs-dir", default="/var/log/weblogic-installer", help="Directory to store installer and WLST logs")

    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    installer_jar = Path(args.wls_installer).expanduser().resolve()
    if not installer_jar.exists():
        print(f"Installer JAR not found: {installer_jar}")
        return 1

    java_home = ensure_java(
        jdk_version=args.jdk_version,
        prefer_system=args.install_jdk_from_system,
        preferred_java_home=args.java_home,
    )

    desired_oracle_home = Path(args.oracle_home).expanduser()
    fallback_oracle_home = Path.home() / "Oracle" / "middleware"
    oracle_home = resolve_writable_default(desired_oracle_home, fallback_oracle_home)

    desired_inventory = Path(args.inventory).expanduser()
    fallback_inventory = Path.home() / "oraInventory"
    inventory_dir = resolve_writable_default(desired_inventory, fallback_inventory)

    logs_dir = Path(args.logs_dir).expanduser()
    ensure_dir(logs_dir)

    try:
        install_weblogic_silent(
            installer_jar=installer_jar,
            oracle_home=oracle_home,
            inventory_dir=inventory_dir,
            install_type=args.install_type,
            java_home=Path(java_home),
            logs_dir=logs_dir,
        )

        # WL_HOME derives from argument or installed path
        wl_home = Path(args.wl_home).expanduser() if args.wl_home else (oracle_home / "wlserver")

        domain_home = Path(args.domain_home).expanduser()
        # If domain_home under default /opt or /app, may not be writable; choose fallback
        desired_domain_home = domain_home
        fallback_domain_home = Path.home() / "Oracle" / "user_projects" / "domains" / args.domain_name
        domain_home = resolve_writable_default(desired_domain_home, fallback_domain_home)

        create_domain_via_wlst(
            oracle_home=oracle_home,
            java_home=Path(java_home),
            domain_home=domain_home,
            domain_name=args.domain_name,
            admin_user=args.admin_user,
            admin_password=args.admin_password,
            listen_address=args.admin_address,
            listen_port=args.admin_port,
            admin_ssl_port=args.admin_ssl_port,
            managed_server_name=args.managed_server_name,
            managed_listen_address=args.managed_address,
            managed_listen_port=args.managed_port,
            managed_ssl_port=args.managed_ssl_port,
            node_manager_name=args.nodemanager_name,
            node_manager_listen_address=args.nodemanager_address,
            node_manager_listen_port=args.nodemanager_port,
            node_manager_type=args.nodemanager_type,
            production_mode=args.production_mode,
            logs_dir=logs_dir,
            wl_home=wl_home,
        )

        print("")
        print("Installation summary:")
        print(f"  JAVA_HOME      : {java_home}")
        print(f"  ORACLE_HOME    : {oracle_home}")
        print(f"  WL_HOME        : {wl_home}")
        print(f"  Inventory      : {inventory_dir}")
        print(f"  Domain name    : {args.domain_name}")
        print(f"  Domain home    : {domain_home}")
        print(f"  Admin user     : {args.admin_user}")
        print(f"  Admin port     : {args.admin_port} (SSL {args.admin_ssl_port})")
        print(f"  Managed server : {args.managed_server_name} port {args.managed_port} (SSL {args.managed_ssl_port})")
        print(f"  Node Manager   : {args.nodemanager_name}:{args.nodemanager_port} ({args.nodemanager_type})")
        print(f"  Logs dir       : {logs_dir}")
        print("")
        print("Next steps:")
        start_script = domain_home / "startWebLogic.sh"
        if start_script.exists():
            print(f"  To start AdminServer: {start_script}")
        else:
            print(f"  To start AdminServer: {domain_home}/startWebLogic.sh")

        return 0
    except CommandError as ce:
        print(str(ce))
        return 2
    except Exception as e:
        print(f"ERROR: {e}")
        return 3


if __name__ == "__main__":
    sys.exit(main())