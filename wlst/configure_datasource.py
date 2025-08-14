# WLST offline script: configure a JDBC datasource offline in the domain
# Usage: wlst.sh configure_datasource.py --domain_home ... --ds_name ... --ds_jndi ... --jdbc_url ... --jdbc_driver ... --db_user ... --db_password ...

import sys

# Parse args
args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
ds_name = params.get('ds_name', 'F1DataSource')
ds_jndi = params.get('ds_jndi', 'jdbc/F1DataSource')
jdbc_url = params.get('jdbc_url')
jdbc_driver = params.get('jdbc_driver', 'oracle.jdbc.OracleDriver')
db_user = params.get('db_user')
db_password = params.get('db_password')

if not domain_home or not jdbc_url or not db_user or not db_password:
    print('[ERROR] Missing required arguments')
    exit(1)

# Read existing domain
readDomain(domain_home)

# Create DS if missing
already = False
try:
    cd('/JDBCSystemResources/' + ds_name)
    already = True
except:
    already = False

if not already:
    cd('/')
    create(ds_name, 'JDBCSystemResource')

cd('/JDBCSystemResources/' + ds_name + '/JDBCResource/' + ds_name)
set('Name', ds_name)

cd('JDBCDriverParams/' + ds_name)
set('DriverName', jdbc_driver)
set('URL', jdbc_url)
set('PasswordEncrypted', db_password)

# Set properties
cd('Properties/' + ds_name)
try:
    cd('Property/user')
except:
    create('user', 'Property')
    cd('Property/user')
set('Value', db_user)

# JNDI
cd('/JDBCSystemResources/' + ds_name + '/JDBCResource/' + ds_name + '/JDBCDataSourceParams/' + ds_name)
set('JNDINames', [ds_jndi])

# Targets left to default (AdminServer) — can be adjusted online later

updateDomain()
closeDomain()

print('Configured JDBC datasource: ' + ds_name)