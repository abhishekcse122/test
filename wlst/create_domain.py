# WLST offline script: create WebLogic domain for C2M/OUAF
# Usage: wlst.sh create_domain.py --domain_home ... --wl_home ... --java_home ... --admin_port ... --admin_password ... --production_mode true|false --listen_address ''

import sys
import os

# Simple argv parser: expects --key value pairs
args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
wl_home = params.get('wl_home')
java_home = params.get('java_home')
admin_port = int(params.get('admin_port', '7001'))
admin_password = params.get('admin_password')
prod_mode = params.get('production_mode', 'true').lower() == 'true'
listen_address = params.get('listen_address', '')

if not domain_home or not wl_home or not java_home or not admin_password:
    print('[ERROR] Missing required arguments')
    exit(1)

# Load base template
readTemplate(wl_home + '/common/templates/wls/wls.jar')

# Options
setOption('OverwriteDomain', 'true')
setOption('JavaHome', java_home)
setOption('ServerStartMode', 'prod' if prod_mode else 'dev')

# Set AdminServer settings
cd('/Servers/AdminServer')
set('ListenPort', admin_port)
if listen_address:
    set('ListenAddress', listen_address)

# Set admin password (user is fixed to 'weblogic' offline)
cd('/Security/base_domain/User/weblogic')
cmo.setPassword(admin_password)

# Write domain
writeDomain(domain_home)
closeTemplate()

# Create boot.properties for non-interactive start
import java.io as javaio
import java.lang as javalang
from java.io import File

security_dir = domain_home + '/servers/AdminServer/security'
if not os.path.isdir(security_dir):
    os.makedirs(security_dir)

boot_path = security_dir + '/boot.properties'
content = 'username=weblogic\npassword=' + admin_password + '\n'
with open(boot_path, 'w') as f:
    f.write(content)

print('Domain created at: ' + domain_home)