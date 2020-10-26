/usr/libexec/platform-python -c "
import json
import libvirt
from xml.dom import minidom
NODE_PREFIX = 'controller'
VBMC_HOST = '172.16.0.1'
VBMC_USER = 'admin'
VBMC_PASSWORD = 'password'
VBMC_PORT_MAP = {'controller-0': 6240}
instackenv = {'nodes': []}
nodes = instackenv['nodes']
data_format = ('\"pm_type\": \"ipmi\", ' 
               '\"mac\": [\"{mac}\"], ' 
               '\"pm_user\": \"' + VBMC_USER + '\", ' 
               '\"pm_password\": \"' + VBMC_PASSWORD + '\", ' 
               '\"pm_addr\": \"' + VBMC_HOST + '\", ' 
               '\"pm_port\": \"{vbmc_port}\", ' 
               '\"name\": \"{domain_name}\"')
conn = libvirt.openReadOnly(None)
domains = conn.listAllDomains(0)
for domain in domains:
    if domain.name().startswith(NODE_PREFIX):
        raw_xml = domain.XMLDesc()
        xml = minidom.parseString(raw_xml)
        mac = xml.getElementsByTagName(
	  'interface')[0].getElementsByTagName(
	  'mac')[0].attributes['address'].value
        data = data_format.format(mac=mac,
                                  vbmc_port=VBMC_PORT_MAP[domain.name()],
                                  domain_name=domain.name())
        nodes.append(json.loads('{' + data + '}'))
print(json.dumps(instackenv, indent=4,  sort_keys=True))
" > instackenv.json

