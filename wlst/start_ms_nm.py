# WLST: start managed server via Node Manager
# Args: --admin_url --admin_user --admin_password --nm_listen_address --nm_listen_port --nm_type --domain_home --server_name

import sys

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

admin_url = params.get('admin_url')
admin_user = params.get('admin_user', 'weblogic')
admin_password = params.get('admin_password')
nm_host = params.get('nm_listen_address', '127.0.0.1')
nm_port = int(params.get('nm_listen_port', '5556'))
nm_type = params.get('nm_type', 'Plain')
domain_home = params.get('domain_home')
server_name = params.get('server_name', 'ManagedServer1')

def ensure_connected():
    try:
        state(server_name, 'Server')
        return True
    except:
        try:
            connect(admin_user, admin_password, admin_url)
            return True
        except:
            return False

# Connect to Node Manager
nmConnect(username=admin_user, password=admin_password, host=nm_host, port=nm_port, domainName=None, domainDir=domain_home, nmType=nm_type)

# Start server
nmStart(server_name)

# Verify
if ensure_connected():
    print('Start requested for ' + server_name)
else:
    print('Start requested via Node Manager; unable to verify admin connection.')