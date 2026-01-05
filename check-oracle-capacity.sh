#!/bin/bash
# Oracle Cloud VM.Standard.A1.Flex Availability Checker and Auto-Creator
# Checks availability domains for free tier ARM capacity and creates instance when available

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found at $CONFIG_FILE"
    echo "Copy config.env.example to config.env and fill in your values"
    exit 1
fi

source "$CONFIG_FILE"

# Validate required variables
REQUIRED_VARS=(
    "TENANCY_ID"
    "COMPARTMENT_ID"
    "IMAGE_ID"
    "SUBNET_ID"
    "SSH_KEY_FILE"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "ERROR: Required variable $var is not set in $CONFIG_FILE"
        exit 1
    fi
done

# Set defaults
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/availability.log}"
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/state}"
OCI="${OCI:-$HOME/bin/oci}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-4}"
MEMORY_GB="${MEMORY_GB:-24}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-200}"

# Check if instance was already created
if [ -f "$STATE_FILE" ] && grep -q "INSTANCE_CREATED=true" "$STATE_FILE"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Instance already created. Exiting." >> "$LOG_FILE"
    exit 0
fi

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Create instance function
create_instance() {
    local AD="$1"
    local TIMESTAMP=$(date '+%Y%m%d-%H%M')
    local INSTANCE_NAME="${INSTANCE_NAME_PREFIX:-instance}-$TIMESTAMP"
    
    log "Attempting to create instance in $AD..."
    
    # Read SSH key
    if [ ! -f "$SSH_KEY_FILE" ]; then
        log "ERROR: SSH key file not found at $SSH_KEY_FILE"
        return 1
    fi
    SSH_KEY=$(cat "$SSH_KEY_FILE")
    
    CREATE_OUTPUT=$($OCI compute instance launch \
        --availability-domain "$AD" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --display-name "$INSTANCE_NAME" \
        --assign-public-ip true \
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
        --ssh-authorized-keys-file /dev/stdin \
        2>&1 <<< "$SSH_KEY")
    
    if echo "$CREATE_OUTPUT" | grep -q '"id":'; then
        INSTANCE_ID=$(echo "$CREATE_OUTPUT" | grep -o '"id": "[^"]*"' | head -1 | cut -d'"' -f4)
        PUBLIC_IP=$(echo "$CREATE_OUTPUT" | grep -o '"public-ip": "[^"]*"' | cut -d'"' -f4)
        
        log "SUCCESS! Instance created:"
        log "  Instance ID: $INSTANCE_ID"
        log "  Instance Name: $INSTANCE_NAME"
        log "  Availability Domain: $AD"
        log "  Public IP: $PUBLIC_IP"
        
        # Save state
        echo "INSTANCE_CREATED=true" > "$STATE_FILE"
        echo "INSTANCE_ID=$INSTANCE_ID" >> "$STATE_FILE"
        echo "INSTANCE_NAME=$INSTANCE_NAME" >> "$STATE_FILE"
        echo "PUBLIC_IP=$PUBLIC_IP" >> "$STATE_FILE"
        echo "AVAILABILITY_DOMAIN=$AD" >> "$STATE_FILE"
        echo "CREATED_AT=$(date)" >> "$STATE_FILE"
        
        return 0
    else
        log "ERROR creating instance: $CREATE_OUTPUT"
        return 1
    fi
}

log "=== Starting availability check ==="

FOUND_AVAILABLE=false
AVAILABLE_ADS=()

# Check each AD
for AD in "${AVAILABILITY_DOMAINS[@]}"; do
    log "Checking $AD..."
    
    RESULT=$($OCI compute compute-capacity-report create \
        --availability-domain "$AD" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape-availabilities "[{\"instanceShape\": \"$SHAPE\", \"instanceShapeConfig\": {\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}}]" \
        2>&1)
    
    if echo "$RESULT" | grep -q "ServiceError"; then
        ERROR_MSG=$(echo "$RESULT" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)
        log "  ERROR: $AD - $ERROR_MSG"
        
        # Sometimes Oracle API returns errors when there IS capacity (rate limiting)
        # Try to create anyway if it's an auth error (might be capacity)
        if echo "$ERROR_MSG" | grep -qi "authentication\|incorrect"; then
            log "  Auth error detected - this might mean capacity is available! Attempting to create..."
            if create_instance "$AD"; then
                exit 0
            fi
        fi
    else
        STATUS=$(echo "$RESULT" | grep -o '"availability-status": "[^"]*"' | head -1 | cut -d'"' -f4)
        log "  $AD: $STATUS"
        
        if [ "$STATUS" = "AVAILABLE" ]; then
            log "  🎉 CAPACITY AVAILABLE IN $AD! 🎉"
            FOUND_AVAILABLE=true
            AVAILABLE_ADS+=("$AD")
            
            # Try to create instance immediately
            if create_instance "$AD"; then
                exit 0
            fi
        fi
    fi
done

# Log if capacity was found but creation failed
if [ "$FOUND_AVAILABLE" = true ]; then
    AD_LIST=$(IFS=", "; echo "${AVAILABLE_ADS[*]}")
    log "Capacity was available in $AD_LIST but creation failed. Check logs."
fi

log "=== Check complete ==="
echo ""
