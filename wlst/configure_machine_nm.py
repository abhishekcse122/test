# WLST offline: create Machine and Node Manager settings and map a server to the machine
# Args: --domain_home --machine_name --nm_listen_address --nm_listen_port --nm_type Plain|SSL --server_name

import sys

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
machine_name = params.get('machine_name', 'Machine1')
nm_listen_address = params.get('nm_listen_address', '')
nm_listen_port = int(params.get('nm_listen_port', '5556'))
nm_type = params.get('nm_type', 'Plain')
server_name = params.get('server_name', 'ManagedServer1')

if not domain_home:
    print('[ERROR] domain_home required')
    exit(1)

readDomain(domain_home)

# Create or get machine
try:
    cd('/Machines/' + machine_name)
except:
    cd('/')
    create(machine_name, 'Machine')
    cd('/Machines/' + machine_name)

# Configure Node Manager under the machine
try:
    cd('/Machines/' + machine_name + '/NodeManager/' + machine_name)
except:
    cd('/Machines/' + machine_name)
    create(machine_name, 'NodeManager')
    cd('/Machines/' + machine_name + '/NodeManager/' + machine_name)

if nm_listen_address:
    set('ListenAddress', nm_listen_address)
set('ListenPort', nm_listen_port)
set('NMType', nm_type)

# Map server to machine
try:
    cd('/Servers/' + server_name)
    set('Machine', getMBean('/Machines/' + machine_name))
except:
    print('Warning: Server ' + server_name + ' not found to map to machine ' + machine_name)

updateDomain()
closeDomain()

print('Machine/NodeManager configured: ' + machine_name)