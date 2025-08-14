# WLST online: deploy two applications with explicit deployment order
# Args: --admin_url --admin_user --admin_password --targets --app1_path --app1_order --app2_path --app2_order

import sys
import os

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

admin_url = params.get('admin_url')
admin_user = params.get('admin_user', 'weblogic')
admin_password = params.get('admin_password')

app1_path = params.get('app1_path')
app1_order = int(params.get('app1_order', '100'))
app2_path = params.get('app2_path')
app2_order = int(params.get('app2_order', '200'))

targets = params.get('targets', 'ManagedServer1')

if not admin_url or not admin_password:
    print('[ERROR] Missing admin connection params')
    exit(1)

if not app1_path or not os.path.exists(app1_path):
    print('[ERROR] app1_path missing or not found')
    exit(1)

if not app2_path or not os.path.exists(app2_path):
    print('[ERROR] app2_path missing or not found')
    exit(1)

app1_name = os.path.splitext(os.path.basename(app1_path))[0]
app2_name = os.path.splitext(os.path.basename(app2_path))[0]

connect(admin_user, admin_password, admin_url)

# Deploy app1
edit()
startEdit()
try:
    try:
        print('Checking existing deployment: ' + app1_name)
        cd('/AppDeployments/' + app1_name)
        print('Already exists; updating order to ' + str(app1_order))
    except:
        print('Deploying ' + app1_name + ' to ' + targets)
        deploy(app1_name, app1_path, targets=targets, upload='true')
        cd('/AppDeployments/' + app1_name)
    set('DeploymentOrder', app1_order)
    save()
    activate(block='true')
except:
    cancelEdit('y')
    raise

# Deploy app2
edit()
startEdit()
try:
    try:
        print('Checking existing deployment: ' + app2_name)
        cd('/AppDeployments/' + app2_name)
        print('Already exists; updating order to ' + str(app2_order))
    except:
        print('Deploying ' + app2_name + ' to ' + targets)
        deploy(app2_name, app2_path, targets=targets, upload='true')
        cd('/AppDeployments/' + app2_name)
    set('DeploymentOrder', app2_order)
    save()
    activate(block='true')
except:
    cancelEdit('y')
    raise

print('Deployments ensured with order: ' + app1_name + '=' + str(app1_order) + ', ' + app2_name + '=' + str(app2_order))