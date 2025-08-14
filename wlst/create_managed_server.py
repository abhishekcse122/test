# WLST offline: create or ensure a Managed Server
# Args: --domain_home --server_name --listen_address --listen_port

import sys

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
server_name = params.get('server_name', 'ManagedServer1')
listen_address = params.get('listen_address', '')
listen_port = int(params.get('listen_port', '8001'))

if not domain_home:
    print('[ERROR] domain_home required')
    exit(1)

readDomain(domain_home)

# Create server if missing
try:
    cd('/Servers/' + server_name)
except:
    cd('/')
    create(server_name, 'Server')
    cd('/Servers/' + server_name)

set('ListenPort', listen_port)
if listen_address:
    set('ListenAddress', listen_address)

updateDomain()
closeDomain()

print('Managed server ensured: ' + server_name)