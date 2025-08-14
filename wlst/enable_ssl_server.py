# WLST offline: enable SSL and configure keystores for a server
# Args: --domain_home --server_name --ssl_listen_port --keystores_mode --id_ks_path --id_ks_type --id_ks_pass --trust_ks_path --trust_ks_type --trust_ks_pass --hostname_verification true|false --use_jsse true|false

import sys

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
server_name = params.get('server_name', 'ManagedServer1')
ssl_listen_port = int(params.get('ssl_listen_port', '8002'))
keystores_mode = params.get('keystores_mode', 'CustomIdentityAndCustomTrust')
id_ks_path = params.get('id_ks_path', '')
id_ks_type = params.get('id_ks_type', 'JKS')
id_ks_pass = params.get('id_ks_pass', '')
trust_ks_path = params.get('trust_ks_path', '')
trust_ks_type = params.get('trust_ks_type', 'JKS')
trust_ks_pass = params.get('trust_ks_pass', '')
hostname_verification = params.get('hostname_verification', 'false').lower() == 'true'
use_jsse = params.get('use_jsse', 'true').lower() == 'true'

if not domain_home:
    print('[ERROR] domain_home required')
    exit(1)

readDomain(domain_home)

# Set keystores mode
cd('/Servers/' + server_name)
set('KeyStores', keystores_mode)
if keystores_mode != 'DemoIdentityAndDemoTrust':
    set('CustomIdentityKeyStoreFileName', id_ks_path)
    set('CustomIdentityKeyStoreType', id_ks_type)
    set('CustomIdentityKeyStorePassPhraseEncrypted', id_ks_pass)
    set('CustomTrustKeyStoreFileName', trust_ks_path)
    set('CustomTrustKeyStoreType', trust_ks_type)
    set('CustomTrustKeyStorePassPhraseEncrypted', trust_ks_pass)

# SSL MBean
cd('/Servers/' + server_name + '/SSL/' + server_name)
set('Enabled', 'true')
set('ListenPort', ssl_listen_port)
set('HostnameVerificationIgnored', 'true' if not hostname_verification else 'false')
set('TwoWaySSLEnabled', 'false')
set('JSSEEnabled', 'true' if use_jsse else 'false')

updateDomain()
closeDomain()

print('SSL configured for server: ' + server_name)