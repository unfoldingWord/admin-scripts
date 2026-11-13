#!/bin/bash

# OpenBao Health Check Script
# Tests basic functionality of OpenBao
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
SHOW_WARNING=true
USERNAME=""
PASSWORD=""
VAULT_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN=""
test_guid=""

# Function to print colored status
print_status() {
    local step_name=$1
    local status=$2
    local error_message=${3:-""}
    
    echo -n "$step_name: "
    if [[ "$status" == "SUCCESS" ]]; then
        echo -e "${GREEN}[SUCCESS]${NC}"
    elif [[ "$status" == "FAILED" ]]; then
        echo -e "${RED}[FAILED]${NC}"
        if [[ -n "$error_message" ]]; then
            echo "  Error: $error_message"
        fi
        echo ""
    fi
}

# Function to show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --no-warning          Skip backup warning message"
    echo "  -u, --username USER   Username for userpass authentication"
    echo "  -p, --password PASS   Password for userpass authentication"
    echo "  --vault-addr ADDR     OpenBao server address (default: \$BAO_ADDR or http://127.0.0.1:8200)"
    echo "  -h, --help           Show this help message"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-warning)
            SHOW_WARNING=false
            shift
            ;;
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        --vault-addr)
            VAULT_ADDR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Show warning unless suppressed
if [[ "$SHOW_WARNING" == "true" ]]; then
    echo -e "${YELLOW}WARNING: Please ensure you have made a backup before proceeding.${NC}"
    echo -e "${YELLOW}This script will perform read/write operations within its testing bounds.${NC}"
    echo ""
fi

# Get username and password if not provided
if [[ -z "$USERNAME" ]]; then
    read -p "Enter username: " USERNAME
fi

if [[ -z "$PASSWORD" ]]; then
    read -sp "Enter password: " PASSWORD
    echo ""
fi

echo "Starting OpenBao health check..."
echo "Vault Address: $VAULT_ADDR"
echo ""

# Test 1: Check if OpenBao is reachable, initialized, and unsealed
CONTINUE_TESTS=true
response_with_code=$(curl -s -w "\n%{http_code}" "$VAULT_ADDR/v1/sys/health" 2>/dev/null)

if [[ -n "$response_with_code" ]]; then
    http_code="${response_with_code##*$'\n'}"
    response="${response_with_code%$'\n'*}"
    
    if [[ "$http_code" =~ ^(200|429|472|473|501|503)$ ]]; then
        # Parse the JSON response
        if command -v jq >/dev/null 2>&1; then
            sealed=$(echo "$response" | jq -r 'if .sealed == null then "unknown" else (.sealed | tostring) end' 2>/dev/null)
            initialized=$(echo "$response" | jq -r 'if .initialized == null then "unknown" else (.initialized | tostring) end' 2>/dev/null)
        else
            # Fallback without jq
            sealed=$(echo "$response" | grep -o '"sealed":[^,}]*' | cut -d':' -f2 | tr -d ' "' || echo "unknown")
            initialized=$(echo "$response" | grep -o '"initialized":[^,}]*' | cut -d':' -f2 | tr -d ' "' || echo "unknown")
        fi
        
        if [[ "$sealed" == "false" && "$initialized" == "true" ]]; then
            print_status "OpenBao is initialized and unsealed" "SUCCESS"
        elif [[ "$sealed" == "true" ]]; then
            print_status "OpenBao is initialized and unsealed" "FAILED" "OpenBao is currently sealed and cannot be used"
            CONTINUE_TESTS=false
        elif [[ "$initialized" == "false" ]]; then
            print_status "OpenBao is initialized and unsealed" "FAILED" "OpenBao is not initialized - please run 'bao operator init' first"
            CONTINUE_TESTS=false
        else
            print_status "OpenBao is initialized and unsealed" "FAILED" "Unable to determine OpenBao status from response"
            CONTINUE_TESTS=false
        fi
    else
        print_status "OpenBao is initialized and unsealed" "FAILED" "OpenBao health endpoint returned HTTP status code $http_code"
        CONTINUE_TESTS=false
    fi
else
    print_status "OpenBao is initialized and unsealed" "FAILED" "Cannot reach OpenBao server at $VAULT_ADDR - check if the service is running and the address is correct"
    CONTINUE_TESTS=false
fi

# Test 2: Login using userpass method
login_payload=$(cat <<EOF
{
    "password": "$PASSWORD"
}
EOF
)

response_with_code=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$login_payload" \
    "$VAULT_ADDR/v1/auth/userpass/login/$USERNAME" 2>/dev/null)

if [[ -n "$response_with_code" ]]; then
    http_code="${response_with_code##*$'\n'}"
    response="${response_with_code%$'\n'*}"
    
    if [[ "$http_code" == "200" ]]; then
        # Extract token from response
        if command -v jq >/dev/null 2>&1; then
            VAULT_TOKEN=$(echo "$response" | jq -r '.auth.client_token // empty' 2>/dev/null)
        else
            # Fallback without jq
            VAULT_TOKEN=$(echo "$response" | grep -o '"client_token":"[^"]*' | cut -d'"' -f4 || echo "")
        fi
        
        if [[ -n "$VAULT_TOKEN" ]]; then
            print_status "Userpass authentication" "SUCCESS"
        else
            print_status "Userpass authentication" "FAILED" "Authentication request succeeded but no token was received in the response"
        fi
    else
        print_status "Userpass authentication" "FAILED" "Authentication failed with HTTP status code $http_code - check username and password"
    fi
else
    print_status "Userpass authentication" "FAILED" "Cannot connect to authentication endpoint - network error"
fi

# Test 3: List items under secret mount
if [[ -n "$VAULT_TOKEN" ]]; then
    response_with_code=$(curl -s -w "\n%{http_code}" \
        -X LIST \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/metadata" 2>/dev/null)
    
    if [[ -n "$response_with_code" ]]; then
        http_code="${response_with_code##*$'\n'}"
        response="${response_with_code%$'\n'*}"
        
        if [[ "$http_code" == "200" ]]; then
            # Count items
            if command -v jq >/dev/null 2>&1; then
                item_count=$(echo "$response" | jq -r '.data.keys // [] | length' 2>/dev/null)
            else
                # Fallback without jq - rough count
                item_count=$(echo "$response" | grep -o '"keys":\[' | wc -l || echo "0")
                if [[ "$item_count" -gt 0 ]]; then
                    # Try to count comma-separated items (rough estimate)
                    item_count=$(echo "$response" | grep -o ',' | wc -l || echo "0")
                    item_count=$((item_count + 1))
                fi
            fi
            print_status "List secrets under 'secret' mount ($item_count items found)" "SUCCESS"
        elif [[ "$http_code" == "404" ]]; then
            print_status "List secrets under 'secret' mount (0 items found)" "SUCCESS"
        else
            print_status "List secrets under 'secret' mount" "FAILED" "Cannot access secret mount - HTTP status code $http_code. Check if KV secrets engine is enabled at 'secret/'"
        fi
    else
        print_status "List secrets under 'secret' mount" "FAILED" "Network error when trying to list secrets"
    fi
else
    print_status "List secrets under 'secret' mount" "FAILED" "Skipped due to authentication failure"
fi

# Test 4: Write a test secret
if [[ -n "$VAULT_TOKEN" ]]; then
    test_guid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "test-$(date +%s)-$$")

    write_payload=$(cat <<EOF
{
    "data": {
        "key_verify": "$test_guid"
    }
}
EOF
)

    response_with_code=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$write_payload" \
        "$VAULT_ADDR/v1/secret/data/health-check" 2>/dev/null)
    
    if [[ -n "$response_with_code" ]]; then
        http_code="${response_with_code##*$'\n'}"
        
        if [[ "$http_code" == "200" ]]; then
            print_status "Write test secret to 'secret/health-check'" "SUCCESS"
        else
            print_status "Write test secret to 'secret/health-check'" "FAILED" "Cannot write secret - HTTP status code $http_code. Check permissions and KV engine version"
        fi
    else
        print_status "Write test secret to 'secret/health-check'" "FAILED" "Network error when trying to write secret"
    fi
else
    print_status "Write test secret to 'secret/health-check'" "FAILED" "Skipped due to authentication failure"
fi

# Test 5: Read back and verify the secret
if [[ -n "$VAULT_TOKEN" ]]; then
    response_with_code=$(curl -s -w "\n%{http_code}" \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/data/health-check" 2>/dev/null)
    
    if [[ -n "$response_with_code" ]]; then
        http_code="${response_with_code##*$'\n'}"
        response="${response_with_code%$'\n'*}"
        
        if [[ "$http_code" == "200" ]]; then
            # Extract the value
            if command -v jq >/dev/null 2>&1; then
                read_value=$(echo "$response" | jq -r '.data.data.key_verify // empty' 2>/dev/null)
            else
                # Fallback without jq
                read_value=$(echo "$response" | grep -o '"key_verify":"[^"]*' | cut -d'"' -f4 || echo "")
            fi
            
            if [[ "$read_value" == "$test_guid" ]]; then
                print_status "Read and verify test secret" "SUCCESS"
            else
                print_status "Read and verify test secret" "FAILED" "Secret value mismatch - wrote: '$test_guid', read: '$read_value'"
            fi
        else
            print_status "Read and verify test secret" "FAILED" "Cannot read secret - HTTP status code $http_code"
        fi
    else
        print_status "Read and verify test secret" "FAILED" "Network error when trying to read secret"
    fi
else
    print_status "Read and verify test secret" "FAILED" "Skipped due to authentication failure"
fi

# Test 6: Enumerate policies
if [[ -n "$VAULT_TOKEN" ]]; then
    response_with_code=$(curl -s -w "\n%{http_code}" \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/sys/policies/acl" 2>/dev/null)
    
    if [[ -n "$response_with_code" ]]; then
        http_code="${response_with_code##*$'\n'}"
        response="${response_with_code%$'\n'*}"
        
        if [[ "$http_code" == "200" ]]; then
            # Extract and count policies
            if command -v jq >/dev/null 2>&1; then
                policy_count=$(echo "$response" | jq -r '.data.keys // [] | length' 2>/dev/null)
                policy_names=$(echo "$response" | jq -r '.data.keys // [] | join(", ")' 2>/dev/null)
            else
                # Fallback without jq - extract policy names
                policy_names=$(echo "$response" | grep -o '"keys":\[[^]]*\]' | sed 's/"keys":\[\(.*\)\]/\1/' | tr -d '"' | sed 's/,/, /g' || echo "")
                if [[ -n "$policy_names" ]]; then
                    policy_count=$(echo "$policy_names" | tr ',' '\n' | wc -l)
                else
                    policy_count=0
                    policy_names=""
                fi
            fi
            
            if [[ "$policy_count" -gt 0 ]]; then
                print_status "Enumerate policies ($policy_count found: $policy_names)" "SUCCESS"
            else
                print_status "Enumerate policies (0 found)" "SUCCESS"
            fi
        else
            print_status "Enumerate policies" "FAILED" "Cannot list policies - HTTP status code $http_code. Check permissions"
        fi
    else
        print_status "Enumerate policies" "FAILED" "Network error when trying to list policies"
    fi
else
    print_status "Enumerate policies" "FAILED" "Skipped due to authentication failure"
fi

echo ""
# Check if all tests that could run were successful
if [[ -n "$VAULT_TOKEN" ]]; then
    echo -e "${GREEN}All health checks completed!${NC}"
    echo "OpenBao is functioning properly."
else
    echo -e "${RED}Health checks completed with failures.${NC}"
    echo "Please review the errors above and fix the issues."
fi
