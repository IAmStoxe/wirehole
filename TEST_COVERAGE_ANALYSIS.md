# WireHole Test Coverage Analysis

## Executive Summary

**Current Test Coverage: 0%**

This codebase currently has **no automated tests**. As an Infrastructure-as-Code (IaC) project using Docker Compose, the testing strategy should focus on configuration validation, integration testing, and security verification.

---

## Current State

### Files Analyzed
| File | Lines | Purpose | Testable |
|------|-------|---------|----------|
| `docker-compose.yml` | 76 | Service orchestration | Yes |
| `unbound/unbound.conf` | 316 | DNS resolver config | Yes |
| `.env.example` | 47 | Environment template | Yes |

### CI/CD Status
- **Current**: Only stale issue management (`.github/workflows/stale.yml`)
- **Missing**: Build validation, test execution, security scanning

---

## Recommended Test Implementation Areas

### 1. Configuration Validation Tests (Priority: HIGH)

#### 1.1 Docker Compose Validation
**What to test:**
- YAML syntax correctness
- Service dependency graph validity
- Network configuration correctness
- Volume mount paths exist
- Port mappings don't conflict

**Recommended tools:**
- `docker-compose config` - validates and normalizes compose file
- `yamllint` - YAML syntax validation
- Custom shell scripts for semantic validation

**Example test script:**
```bash
#!/bin/bash
# tests/validate-compose.sh

set -e

echo "Validating docker-compose.yml syntax..."
docker-compose -f docker-compose.yml config > /dev/null

echo "Checking for required services..."
for service in unbound wireguard wireguard-ui pihole; do
  if ! docker-compose config --services | grep -q "^${service}$"; then
    echo "ERROR: Missing required service: ${service}"
    exit 1
  fi
done

echo "All validations passed!"
```

#### 1.2 Unbound Configuration Validation
**What to test:**
- Configuration syntax validity
- Security settings are properly configured
- Access control lists are correct
- Cache settings are within reasonable bounds

**Recommended tools:**
- `unbound-checkconf` - native Unbound syntax checker
- Custom validation scripts

**Example test:**
```bash
#!/bin/bash
# tests/validate-unbound.sh

# Run inside Unbound container or with unbound installed
unbound-checkconf /opt/unbound/etc/unbound/unbound.conf
```

#### 1.3 Environment Variable Validation
**What to test:**
- All required variables are documented in `.env.example`
- IP addresses are valid format
- Ports are within valid range (1-65535)
- No sensitive defaults (passwords, secrets)

**Example test:**
```bash
#!/bin/bash
# tests/validate-env.sh

source .env.example

# Validate IP format
validate_ip() {
  if [[ ! $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Invalid IP: $1"
    return 1
  fi
}

validate_ip "$UNBOUND_IPV4_ADDRESS"
validate_ip "$PIHOLE_IPV4_ADDRESS"
validate_ip "$WIREGUARD_PEER_DNS"
validate_ip "$PIHOLE_DNS"

# Check for insecure defaults
if [ "$WGUI_PASSWORD" = "admin" ]; then
  echo "WARNING: Default password detected"
fi
```

---

### 2. Container Startup Tests (Priority: HIGH)

#### 2.1 Service Health Checks
**What to test:**
- All containers start successfully
- Containers reach healthy state
- Services are listening on expected ports
- Inter-container communication works

**Recommended approach:**
```bash
#!/bin/bash
# tests/container-health.sh

set -e

# Start services
docker-compose up -d

# Wait for containers to be healthy
echo "Waiting for containers to start..."
sleep 30

# Check container status
for container in unbound pihole wireguard wireguard-ui; do
  status=$(docker inspect --format='{{.State.Status}}' $container 2>/dev/null || echo "not_found")
  if [ "$status" != "running" ]; then
    echo "FAIL: Container $container is not running (status: $status)"
    docker-compose logs $container
    exit 1
  fi
  echo "PASS: $container is running"
done

# Check port availability
echo "Checking exposed ports..."
nc -z localhost 5000 && echo "PASS: WireGuard-UI port 5000 is open" || echo "FAIL: Port 5000"
nc -z -u localhost 51820 && echo "PASS: WireGuard UDP port 51820 is open" || echo "FAIL: Port 51820"
```

---

### 3. DNS Resolution Tests (Priority: HIGH)

#### 3.1 Unbound DNS Tests
**What to test:**
- DNS queries resolve correctly
- DNSSEC validation works
- Cache behavior is correct
- Access controls are enforced

**Example tests:**
```bash
#!/bin/bash
# tests/dns-resolution.sh

UNBOUND_IP="10.2.0.200"

# Test basic resolution
echo "Testing basic DNS resolution..."
dig @$UNBOUND_IP google.com +short || { echo "FAIL: Basic DNS resolution"; exit 1; }

# Test DNSSEC
echo "Testing DNSSEC validation..."
dig @$UNBOUND_IP dnssec-failed.org +dnssec 2>&1 | grep -q "SERVFAIL" && \
  echo "PASS: DNSSEC validation working" || \
  echo "WARN: DNSSEC might not be validating properly"

# Test Pi-hole integration
PIHOLE_IP="10.2.0.100"
echo "Testing Pi-hole DNS..."
dig @$PIHOLE_IP example.com +short || { echo "FAIL: Pi-hole DNS resolution"; exit 1; }
```

#### 3.2 Ad-Blocking Tests
**What to test:**
- Known ad domains are blocked
- Legitimate domains are not blocked
- Blocklist updates work

```bash
#!/bin/bash
# tests/ad-blocking.sh

PIHOLE_IP="10.2.0.100"

# Test ad domain is blocked (should return 0.0.0.0 or NXDOMAIN)
echo "Testing ad blocking..."
result=$(dig @$PIHOLE_IP ads.google.com +short)
if [ -z "$result" ] || [ "$result" = "0.0.0.0" ]; then
  echo "PASS: Ad domain blocked"
else
  echo "INFO: Ad domain returned: $result (may not be in blocklist)"
fi

# Test legitimate domain is NOT blocked
result=$(dig @$PIHOLE_IP github.com +short)
if [ -n "$result" ] && [ "$result" != "0.0.0.0" ]; then
  echo "PASS: Legitimate domain not blocked"
else
  echo "FAIL: Legitimate domain appears blocked"
  exit 1
fi
```

---

### 4. Network Connectivity Tests (Priority: MEDIUM)

#### 4.1 Internal Network Tests
**What to test:**
- Containers can communicate on private network
- IP assignments are correct
- Service discovery works

```bash
#!/bin/bash
# tests/network-connectivity.sh

# Test Pihole can reach Unbound
docker exec pihole ping -c 3 10.2.0.200 || { echo "FAIL: Pi-hole cannot reach Unbound"; exit 1; }

# Test WireGuard can reach Pi-hole
docker exec wireguard ping -c 3 10.2.0.100 || { echo "FAIL: WireGuard cannot reach Pi-hole"; exit 1; }

# Verify static IP assignments
unbound_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' unbound)
pihole_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pihole)

[ "$unbound_ip" = "10.2.0.200" ] && echo "PASS: Unbound IP correct" || echo "FAIL: Unbound IP mismatch"
[ "$pihole_ip" = "10.2.0.100" ] && echo "PASS: Pi-hole IP correct" || echo "FAIL: Pi-hole IP mismatch"
```

---

### 5. Security Tests (Priority: HIGH)

#### 5.1 Container Security Scanning
**What to test:**
- No known vulnerabilities in base images
- No secrets in images
- Proper user permissions

**Recommended tools:**
- `trivy` - container vulnerability scanner
- `docker scan` - Docker's built-in scanner
- `hadolint` - Dockerfile linting (if custom Dockerfiles are added)

```bash
#!/bin/bash
# tests/security-scan.sh

images=(
  "mvance/unbound:latest"
  "linuxserver/wireguard"
  "ngoduykhanh/wireguard-ui:latest"
  "pihole/pihole:latest"
)

for image in "${images[@]}"; do
  echo "Scanning $image..."
  trivy image --severity HIGH,CRITICAL "$image"
done
```

#### 5.2 Configuration Security Audit
**What to test:**
- No hardcoded credentials
- Proper access controls in Unbound
- DNSSEC is enabled
- TLS certificates are used where applicable

```bash
#!/bin/bash
# tests/security-audit.sh

echo "Checking for security configurations..."

# Check Unbound security settings
grep -q "harden-dnssec-stripped: yes" unbound/unbound.conf && \
  echo "PASS: DNSSEC stripping protection enabled" || \
  echo "FAIL: DNSSEC stripping protection not found"

grep -q "hide-identity: yes" unbound/unbound.conf && \
  echo "PASS: Server identity hidden" || \
  echo "FAIL: Server identity exposed"

grep -q "hide-version: yes" unbound/unbound.conf && \
  echo "PASS: Server version hidden" || \
  echo "FAIL: Server version exposed"

# Check for default credentials in env
if grep -q 'WGUI_PASSWORD=admin' .env.example; then
  echo "WARN: Default admin password in .env.example"
fi

if grep -q 'WGUI_SESSION_SECRET=$' .env.example; then
  echo "WARN: Empty session secret in .env.example"
fi
```

---

### 6. VPN Connectivity Tests (Priority: MEDIUM)

#### 6.1 WireGuard Functionality Tests
**What to test:**
- WireGuard interface is created
- Peer configuration is generated
- VPN tunnel can be established

```bash
#!/bin/bash
# tests/wireguard-tests.sh

# Check WireGuard interface exists
docker exec wireguard wg show || { echo "FAIL: WireGuard interface not found"; exit 1; }

# Check peer configs are generated
if [ -d "./config/peer1" ]; then
  echo "PASS: Peer configuration generated"
else
  echo "FAIL: No peer configuration found"
fi

# Verify WireGuard is listening
docker exec wireguard ss -uln | grep -q ":51820" && \
  echo "PASS: WireGuard listening on UDP 51820" || \
  echo "FAIL: WireGuard not listening"
```

---

### 7. Web Interface Tests (Priority: LOW)

#### 7.1 UI Availability Tests
**What to test:**
- WireGuard-UI is accessible
- Pi-hole admin interface is accessible
- Authentication works

```bash
#!/bin/bash
# tests/web-interface.sh

# Test WireGuard-UI
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5000)
[ "$status" = "200" ] || [ "$status" = "302" ] && \
  echo "PASS: WireGuard-UI accessible (HTTP $status)" || \
  echo "FAIL: WireGuard-UI not accessible (HTTP $status)"

# Note: Pi-hole admin is internal only (10.2.0.100/admin)
# Would need to test from within the network
```

---

## Recommended CI/CD Pipeline

Create `.github/workflows/test.yml`:

```yaml
name: Test WireHole

on:
  push:
    branches: [master, main]
  pull_request:
    branches: [master, main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate YAML syntax
        run: |
          pip install yamllint
          yamllint docker-compose.yml

      - name: Validate Docker Compose
        run: docker-compose config

      - name: Check for security issues
        run: |
          # Check for hardcoded secrets
          if grep -rE "(password|secret|key)\s*=\s*['\"]?[a-zA-Z0-9]+" --include="*.yml" --include="*.yaml" .; then
            echo "WARNING: Potential hardcoded secrets found"
          fi

  container-test:
    runs-on: ubuntu-latest
    needs: validate
    steps:
      - uses: actions/checkout@v4

      - name: Copy env file
        run: cp .env.example .env

      - name: Start services
        run: docker-compose up -d

      - name: Wait for services
        run: sleep 60

      - name: Check container health
        run: |
          for container in unbound pihole wireguard wireguard-ui; do
            status=$(docker inspect --format='{{.State.Status}}' $container)
            echo "$container: $status"
            [ "$status" = "running" ] || exit 1
          done

      - name: Test DNS resolution
        run: |
          docker exec pihole dig @10.2.0.200 google.com +short

      - name: Cleanup
        if: always()
        run: docker-compose down -v

  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run Trivy vulnerability scanner
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'config'
          scan-ref: '.'
          severity: 'CRITICAL,HIGH'
```

---

## Implementation Priority

| Priority | Test Category | Effort | Impact |
|----------|--------------|--------|--------|
| 1 | Configuration Validation | Low | High |
| 2 | Container Startup Tests | Medium | High |
| 3 | DNS Resolution Tests | Medium | High |
| 4 | Security Tests | Medium | Critical |
| 5 | Network Connectivity | Medium | Medium |
| 6 | VPN Functionality | High | Medium |
| 7 | Web Interface | Low | Low |

---

## Quick Start

To begin implementing tests:

1. **Create test directory structure:**
   ```bash
   mkdir -p tests/
   ```

2. **Start with configuration validation:**
   ```bash
   # Create tests/validate-compose.sh from examples above
   chmod +x tests/validate-compose.sh
   ```

3. **Add CI/CD pipeline:**
   ```bash
   # Create .github/workflows/test.yml from example above
   ```

4. **Run tests locally:**
   ```bash
   ./tests/validate-compose.sh
   docker-compose up -d
   ./tests/container-health.sh
   ./tests/dns-resolution.sh
   docker-compose down
   ```

---

## Conclusion

The WireHole project would significantly benefit from implementing automated tests in the following areas:

1. **Configuration validation** - Catch syntax errors and misconfigurations before deployment
2. **Container health checks** - Ensure services start and remain healthy
3. **DNS functionality tests** - Verify core DNS resolution and ad-blocking work
4. **Security scanning** - Identify vulnerabilities in container images
5. **Network connectivity tests** - Verify inter-service communication

Starting with configuration validation and basic container health tests would provide immediate value with minimal effort. The security scanning should be prioritized given the sensitive nature of VPN and DNS infrastructure.
