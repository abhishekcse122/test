# WLST offline: set ServerStart arguments for a server
# Args: --domain_home --server_name --args "-Xms2g -Xmx4g ..."

import sys

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
server_name = params.get('server_name', 'ManagedServer1')
args_str = params.get('args', '')

if not domain_home or not args_str:
    print('[ERROR] domain_home and args required')
    exit(1)

readDomain(domain_home)

# Ensure ServerStart
try:
    cd('/Servers/' + server_name + '/ServerStart/' + server_name)
except:
    cd('/Servers/' + server_name)
    create(server_name, 'ServerStart')
    cd('/Servers/' + server_name + '/ServerStart/' + server_name)

set('Arguments', args_str)

updateDomain()
closeDomain()

print('ServerStart arguments set for ' + server_name)