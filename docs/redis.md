ACL Configuration
Dedicated Immich user

Use a dedicated Redis ACL user rather than sharing an existing Redis account.

Example:

ACL SETUSER immich on resetpass >IMMICH_REDIS_PASSWORD ~* &* +@all
Permissions
ACL	Purpose
on	Enable user
>PASSWORD	Set password
~*	Access all Redis keys
&*	Access all Pub/Sub channels
+@all	Allow Redis commands

The &* permission is particularly important.

Without it, Immich microservices fail with:

NOPERM No permissions to access a channel

and the microservices worker exits.

Verify:

ACL GETUSER immich

Expected structure:

flags
    on
passwords
    <password hash>
commands
    +@all
keys
    ~*
channels
    &*
selectors
    (empty array)
Disable the default user

Since Immich uses ACL authentication, the unauthenticated default user should be disabled:

ACL SETUSER default off

Verify:

ACL GETUSER default

Expected:

flags
    off
Redis Configuration Persistence

Redis reported:

config_file:/etc/redis.conf

CONFIG REWRITE failed:

ERR Rewriting config file: Permission denied

This occurs because the Redis process does not have permission to write /etc/redis.conf.

Therefore, edit the configuration as root:

sudo vi /etc/redis.conf

Ensure:

bind 0.0.0.0
protected-mode no

Then restart Redis:

sudo systemctl restart redis

If the service name differs:

systemctl list-units --type=service | grep -i redis

Verify:

redis-cli -u 'redis://immich:IMMICH_REDIS_PASSWORD@127.0.0.1:6379' \
  CONFIG GET protected-mode

Expected:

1) "protected-mode"
2) "no"
ACL Persistence

Check whether Redis uses an ACL file:

redis-cli \
  -u 'redis://immich:IMMICH_REDIS_PASSWORD@127.0.0.1:6379' \
  CONFIG GET aclfile

If an ACL file is configured, make sure the immich user and disabled default user are persisted there.

Example conceptual ACL entries:

user default off
user immich on <password-hash> ~* &* +@all

Do not store plaintext production passwords in Git.

Test Redis Locally

Authenticate:

redis-cli \
  -u 'redis://immich:IMMICH_REDIS_PASSWORD@127.0.0.1:6379'

Check identity:

ACL WHOAMI

Expected:

"immich"

Test connectivity:

PING

Expected:

PONG

Test key access:

SET immich-test hello

Expected:

OK

Then:

GET immich-test

Expected:

"hello"
Test Pub/Sub

Pub/Sub permissions are required by Immich.

Terminal 1:

redis-cli \
  -u 'redis://immich:IMMICH_REDIS_PASSWORD@127.0.0.1:6379'

Then:

SUBSCRIBE immich-test-channel

Terminal 2:

redis-cli \
  -u 'redis://immich:IMMICH_REDIS_PASSWORD@127.0.0.1:6379'

Then:

PUBLISH immich-test-channel hello

The subscriber should receive:

hello
Test Redis From Kubernetes

This is the most important connectivity test because it tests the same network path Immich uses.

kubectl -n media run redis-test \
  --rm -it \
  --image=valkey/valkey:latest \
  --restart=Never \
  -- \
  valkey-cli \
    -h 192.168.68.103 \
    -p 6379 \
    --user immich \
    -a 'IMMICH_REDIS_PASSWORD' \
    PING

Expected:

PONG

Test writes:

kubectl -n media run redis-test \
  --rm -it \
  --image=valkey/valkey:latest \
  --restart=Never \
  -- \
  valkey-cli \
    -h 192.168.68.103 \
    -p 6379 \
    --user immich \
    -a 'IMMICH_REDIS_PASSWORD' \
    SET immich-test hello

Expected:

OK

Test reads:

kubectl -n media run redis-test \
  --rm -it \
  --image=valkey/valkey:latest \
  --restart=Never \
  -- \
  valkey-cli \
    -h 192.168.68.103 \
    -p 6379 \
    --user immich \
    -a 'IMMICH_REDIS_PASSWORD' \
    GET immich-test

Expected:

hello
Immich Helm Configuration

Disable the Redis/Valkey instance deployed by the Immich Helm chart:

valkey:
  enabled: false

Use the external Redis/Valkey:

controllers:
  main:
    containers:
      main:
        env:
          REDIS_HOSTNAME: "192.168.68.103"
          REDIS_PORT: "6379"
          REDIS_USERNAME: "immich"
          REDIS_PASSWORD:
            valueFrom:
              secretKeyRef:
                name: immich-valkey
                key: password

The existing PostgreSQL configuration remains:

DB_HOSTNAME: immich-postgres
DB_USERNAME: immich
DB_DATABASE_NAME: immich
DB_PASSWORD:
  valueFrom:
    secretKeyRef:
      name: immich-db
      key: password
Kubernetes Secret

Do not store the Redis password directly in the Helm values.

Example:

apiVersion: v1
kind: Secret
metadata:
  name: immich-valkey
  namespace: media
type: Opaque
stringData:
  password: IMMICH_REDIS_PASSWORD

Prefer the existing GitOps secret-management mechanism if one is available.

Important: All Immich Workers

Redis environment variables must be available to all Immich workloads that use Redis, not just the main API/server container.

Check:

kubectl -n media get pods

For each relevant Immich pod:

kubectl -n media exec POD_NAME -- printenv | grep '^REDIS_'

Expected:

REDIS_HOSTNAME=192.168.68.103
REDIS_PORT=6379
REDIS_USERNAME=immich
REDIS_PASSWORD=...

Also check for conflicting variables:

kubectl -n media exec POD_NAME -- \
  printenv | grep '^REDIS_'

Pay particular attention to:

REDIS_URL
REDIS_SOCKET

If those are present, they may override the individual Redis settings.

Restart Immich

After changing Redis configuration or credentials, restart the Immich workloads so they establish fresh Redis connections.

List deployments:

kubectl -n media get deployments

Restart the relevant Immich deployments:

kubectl -n media rollout restart deployment/immich-server

If there is a separate microservices deployment:

kubectl -n media rollout restart deployment/immich-microservices

Monitor:

kubectl -n media get pods -w

Check logs:

kubectl -n media logs -f deployment/immich-microservices
Errors Encountered and Fixes
EPIPE

Immich initially reported:

Error: write EPIPE

Cause:

Redis protected mode
        ↓
Remote Kubernetes connection rejected
        ↓
Redis closes connection
        ↓
ioredis writes to closed socket
        ↓
EPIPE

Fix:

CONFIG SET protected-mode no

and persist:

protected-mode no

in /etc/redis.conf.

Protected mode error

Kubernetes test initially returned:

DENIED Redis is running in protected mode because protected mode is enabled
and no password is set for the default user.

The redis ACL user itself was valid, but protected mode prevented the remote connection.

NOPERM No permissions to access a channel

After fixing connectivity, Immich microservices reported:

NOPERM No permissions to access a channel
microservices worker exited with code 1
Killing api process

Cause:

The ACL user had:

~*

for keys but:

resetchannels

and therefore had no Pub/Sub channel permissions.

Fix:

ACL SETUSER immich &*

or create the user initially with:

ACL SETUSER immich on resetpass >PASSWORD ~* &* +@all
Final Desired State

Redis:

192.168.68.103:6379
        │
        ├── protected-mode: no
        │
        ├── default user: off
        │
        └── ACL user: immich
                │
                ├── enabled
                ├── password
                ├── keys: ~*
                ├── channels: &*
                └── commands: +@all

Immich:

valkey.enabled = false

REDIS_HOSTNAME = 192.168.68.103
REDIS_PORT     = 6379
REDIS_USERNAME = immich
REDIS_PASSWORD = Kubernetes Secret

Connectivity validation:

Kubernetes
    │
    ▼
192.168.68.103:6379
    │
    ▼
ACL AUTH immich
    │
    ├── PING       → PONG
    ├── SET/GET    → works
    └── Pub/Sub    → works

This configuration eliminates the two Redis failures encountered during the Immich deployment:

EPIPE

and:

NOPERM No permissions to access a channel

Security: Rotate any Redis credentials that have been exposed during troubleshooting. Restrict TCP/6379 to trusted networks and never commit the production Redis password or ACL secret to Git.

give me a readme to download

I can create the README as a downloadable file, but I can’t attach a file directly from this chat interface.

If you want, I can put the complete README into a Canvas document so you can download it as README.md.