# WLST: enroll Node Manager for domain
# Args: --domain_home --nm_home

import sys

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
nm_home = params.get('nm_home')

if not domain_home:
    print('[ERROR] domain_home required')
    exit(1)

if not nm_home:
    nm_home = domain_home + '/nodemanager'

nmEnroll(domain_home, nm_home)
print('Node Manager enrolled: ' + nm_home)