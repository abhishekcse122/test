# WLST offline: configure XML Registry entries
# Args: --domain_home --entries "publicId|systemId|entityURI publicId2|systemId2|entityURI2"

import sys

args = sys.argv
params = {}
for i in range(len(args)):
    if args[i].startswith('--') and i + 1 < len(args):
        params[args[i][2:]] = args[i + 1]

domain_home = params.get('domain_home')
entries = params.get('entries', '').strip()

if not domain_home:
    print('[ERROR] domain_home required')
    exit(1)

if not entries:
    print('No XML Registry entries provided; nothing to do.')
    exit(0)

readDomain(domain_home)

cd('/')
# Create domain-level XML Registry if needed
try:
    cd('/XMLRegistries/XMLRegistry')
except:
    create('XMLRegistry', 'XMLRegistry')
    cd('/XMLRegistries/XMLRegistry')

# Parse and create entity resolvers
for token in entries.split():
    parts = token.split('|')
    if len(parts) != 3:
        print('Skipping invalid entry: ' + token)
        continue
    public_id, system_id, entity_uri = parts
    try:
        cd('/XMLRegistries/XMLRegistry/EntityMappings/' + public_id)
    except:
        cd('/XMLRegistries/XMLRegistry')
        create(public_id, 'EntityMapping')
        cd('/XMLRegistries/XMLRegistry/EntityMappings/' + public_id)
    set('PublicId', public_id)
    set('SystemId', system_id)
    set('EntityURI', entity_uri)

updateDomain()
closeDomain()

print('XML Registry entries configured.')