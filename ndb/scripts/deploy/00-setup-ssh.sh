#!/bin/bash
# Setup SSH key-based auth between all 6 nodes on 200.0.0.x network
# Run this from Node 1 (S0101 / 200.0.0.101)
set -e

NODES=(200.0.0.101 200.0.0.102 200.0.0.103 200.0.0.104 200.0.0.106 200.0.0.107)

echo "=== Setting up SSH key-based authentication ==="

# Generate key if needed
if [[ ! -f ~/.ssh/id_rsa ]]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    echo "Generated SSH key"
fi

# Copy public key to all nodes (including self)
for ip in "${NODES[@]}"; do
    echo -n "Setting up $ip... "
    # Copy key pair and authorize
    sshpass -p 'Passw0rd' ssh -o StrictHostKeyChecking=no root@$ip "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null
    # Use SSH pipe instead of scp (scp breaks when remote .bashrc produces output)
    PUBKEY=$(cat ~/.ssh/id_rsa.pub)
    PRIVKEY=$(cat ~/.ssh/id_rsa)
    sshpass -p 'Passw0rd' ssh -o StrictHostKeyChecking=no root@$ip "echo '$PUBKEY' > ~/.ssh/id_rsa.pub && cat > ~/.ssh/id_rsa << 'KEYEOF'
$PRIVKEY
KEYEOF
chmod 600 ~/.ssh/id_rsa" 2>/dev/null
    sshpass -p 'Passw0rd' ssh -o StrictHostKeyChecking=no root@$ip "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null
    echo "done"
done

echo ""
echo "=== Verifying connectivity ==="
for ip in "${NODES[@]}"; do
    echo -n "$ip: "
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$ip "hostname" 2>/dev/null || echo "FAILED"
done

echo ""
echo "=== SSH setup complete ==="
