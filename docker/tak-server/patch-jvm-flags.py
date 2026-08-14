gc = (
    '-XX:G1HeapRegionSize=16m'
    ' -XX:+HeapDumpOnOutOfMemoryError'
    ' -XX:HeapDumpPath=/opt/tak/persistent-config/'
    ' -XX:+ExitOnOutOfMemoryError'
    ' -Xlog:gc*:file=/opt/tak/persistent-config/gc-%p.log:time,uptime:filecount=3,filesize=10m'
)

# Fix for Micrometer CloudWatch SSL failure (API process only).
# Netty's native BoringSSL enforces Extended Key Usage and rejects the TLS
# handshake with CloudWatch because the TAK Server certificate does not have
# clientAuth EKU. Disabling native OpenSSL for the API JVM forces Netty to use
# the JDK JSSE provider, which does not enforce EKU on outbound connections.
#
# This flag must NOT be added to the messaging process. Tried that (to also
# fix the same CloudWatch/EKU error there, since messaging stands up its own
# CloudWatchMeterRegistry too), but messaging also owns SubmissionService's
# CoT input listener (port 8089, stdssl), which builds its TLS server context
# via Netty's OpenSslServerContext and has no JSSE fallback -- disabling
# OpenSSL there makes that listener setup throw UnsatisfiedLinkError,
# crashing the whole messaging process on every startup, which then cascades
# to the api process failing too (it depends on messaging via Ignite). This
# was caught in production as repeated ECS deployment/health-check failures.
# The messaging-side CloudWatch/EKU error is accepted as-is: those metrics
# are lost, but the process stays up. Ignite's own TcpCommunicationSpi is
# unaffected either way since it uses raw NIO, not Netty.
api_ssl_fix = '-Dio.netty.handler.ssl.noOpenSsl=true'

# Patch configureInDocker.sh - add GC flags to messaging and API JVM invocations
with open('/opt/tak/configureInDocker.sh', 'r') as f:
    content = f.read()
content = content.replace(
    'java -jar -Xmx${MESSAGING_MAX_HEAP}m',
    'java -jar ' + gc + ' -Xmx${MESSAGING_MAX_HEAP}m'
)
content = content.replace(
    'java -jar -Xmx${API_MAX_HEAP}m',
    'java -jar ' + gc + ' ' + api_ssl_fix + ' -Xmx${API_MAX_HEAP}m'
)
with open('/opt/tak/configureInDocker.sh', 'w') as f:
    f.write(content)

# Patch setenv.sh - use ECS_TASK_MEMORY_MB if set, falling back to /proc/meminfo.
# /proc/meminfo inside a Fargate container reflects host RAM, not the container memory limit,
# which causes heap sizes to be calculated far too large.
with open('/opt/tak/setenv.sh', 'r') as f:
    content = f.read()
content = content.replace(
    "TOTALRAMBYTES=`awk '/MemTotal/ {print $2}' /proc/meminfo`",
    "TOTALRAMBYTES=${ECS_TASK_MEMORY_MB:+$((ECS_TASK_MEMORY_MB * 1024))}\n"
    "TOTALRAMBYTES=${TOTALRAMBYTES:-`awk '/MemTotal/ {print $2}' /proc/meminfo`}"
)
with open('/opt/tak/setenv.sh', 'w') as f:
    f.write(content)
