# WLST online script: deploy an application EAR/WAR
# Usage: wlst.sh deploy_app.py --admin_url t3://host:port --admin_user weblogic --admin_password ... --app_path /path/app.ear --targets AdminServer

import sys

# Parse args
args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

admin_url = params.get('admin_url')
admin_user = params.get('admin_user', 'weblogic')
admin_password = params.get('admin_password')
app_path = params.get('app_path')
app_name = params.get('app_name')
targets = params.get('targets', 'AdminServer')

if not admin_url or not admin_password or not app_path:
    print('[ERROR] Missing required arguments')
    exit(1)

if not app_name:
    import os
    app_name = os.path.splitext(os.path.basename(app_path))[0]

connect(admin_user, admin_password, admin_url)
edit()
startEdit()

try:
    print('Deploying ' + app_path + ' as ' + app_name + ' to ' + targets)
    deploy(app_name, app_path, targets=targets, upload='true')
    activate()
except Exception as e:
    print('Deployment error: ' + str(e))
    cancelEdit('y')
    raise

print('Deployment submitted for: ' + app_name)