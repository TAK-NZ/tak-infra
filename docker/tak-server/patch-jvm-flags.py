gc = (
    '-XX:G1HeapRegionSize=16m'
    ' -XX:+HeapDumpOnOutOfMemoryError'
    ' -XX:HeapDumpPath=/opt/tak/persistent-config/'
    ' -Xlog:gc*:file=/opt/tak/persistent-config/gc-%p.log:time,uptime:filecount=3,filesize=10m'
)
with open('/opt/tak/configureInDocker.sh', 'r') as f:
    content = f.read()
content = content.replace(
    'java -jar -Xmx${MESSAGING_MAX_HEAP}m',
    'java -jar ' + gc + ' -Xmx${MESSAGING_MAX_HEAP}m'
)
content = content.replace(
    'java -jar -Xmx${API_MAX_HEAP}m',
    'java -jar ' + gc + ' -Xmx${API_MAX_HEAP}m'
)
with open('/opt/tak/configureInDocker.sh', 'w') as f:
    f.write(content)
