# Oracle Cloud Free Tier ARM Instance Hunter

Automatically checks Oracle Cloud for VM.Standard.A1.Flex (4 CPU, 24GB RAM) availability and creates an instance when capacity is found.

> **Note:** This script is pre-configured for **US-ASHBURN-1** region. You'll need to modify the availability domains in `config.env` for other regions.

## Features

- ✅ Checks all availability domains in your region
- ✅ Auto-creates instance when capacity is available
- ✅ Prevents duplicate instance creation
- ✅ Handles Oracle API quirks (auth errors when capacity exists)
- ✅ Detailed logging
- ✅ Configuration via separate file

## Prerequisites

1. **Oracle Cloud Account** with Always Free tier
2. **OCI CLI** installed and configured
3. **VCN and Subnet** created in your compartment
4. **SSH key pair** for instance access

## Quick Start

### 1. Install OCI CLI

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

### 2. Configure OCI CLI

```bash
~/bin/oci setup config
```

You'll need:
- Tenancy OCID (Profile → Tenancy)
- User OCID (Profile → User Settings)
- Region (e.g., us-ashburn-1)
- API key (can be auto-generated)

Upload the generated public key to Oracle Cloud Console: Profile → User Settings → API Keys → Add API Key

### 3. Create Network Infrastructure

```bash
# Create VCN
oci network vcn create \
  --compartment-id <YOUR_COMPARTMENT_OCID> \
  --display-name vcn-hub01 \
  --cidr-blocks '["10.0.0.0/16"]' \
  --dns-label vcnhub01

# Create Internet Gateway
oci network internet-gateway create \
  --compartment-id <YOUR_COMPARTMENT_OCID> \
  --vcn-id <VCN_OCID_FROM_ABOVE> \
  --display-name igw-hub01 \
  --is-enabled true

# Update route table
oci network route-table update \
  --rt-id <DEFAULT_ROUTE_TABLE_OCID_FROM_VCN> \
  --route-rules '[{"destination": "0.0.0.0/0", "destinationType": "CIDR_BLOCK", "networkEntityId": "<IGW_OCID_FROM_ABOVE>"}]' \
  --force

# Update security list (replace YOUR_IP with your public IP)
oci network security-list update \
  --security-list-id <DEFAULT_SECURITY_LIST_OCID_FROM_VCN> \
  --ingress-security-rules '[{"protocol": "6", "source": "YOUR_IP/32", "isStateless": false, "tcpOptions": {"destinationPortRange": {"min": 22, "max": 22}}}]' \
  --egress-security-rules '[{"protocol": "all", "destination": "0.0.0.0/0", "isStateless": false}]' \
  --force

# Create subnet
oci network subnet create \
  --compartment-id <YOUR_COMPARTMENT_OCID> \
  --vcn-id <VCN_OCID> \
  --display-name sn-hub01 \
  --cidr-block 10.0.0.0/24 \
  --dns-label snhub01
```

### 4. Clone and Configure

```bash
git clone https://github.com/NotReached/Oracle-Cloud-ARM-Capacity-Cron.git
cd Oracle-Cloud-ARM-Capacity-Cron

# Copy config template
cp config.env.example config.env

# Edit configuration
nano config.env
```

Fill in your OCIDs and settings in `config.env`.

### 5. Get Required Information

**Get your availability domains (IMPORTANT - varies by region!):**
```bash
oci iam availability-domain list --compartment-id <YOUR_TENANCY_OCID>
```

**Example output for US-ASHBURN-1:**
```json
{
  "data": [
    {
      "name": "PddS:US-ASHBURN-AD-1"
    },
    {
      "name": "PddS:US-ASHBURN-AD-2"
    },
    {
      "name": "PddS:US-ASHBURN-AD-3"
    }
  ]
}
```

**Other regions will have different AD names!** For example:
- US-PHOENIX-1: `PddS:PHX-AD-1`, etc.
- EU-FRANKFURT-1: `PddS:EU-FRANKFURT-1-AD-1`, etc.

Update the `AVAILABILITY_DOMAINS` array in your `config.env` with your region's AD names.

**Get Ubuntu ARM image OCID:**
```bash
oci compute image list \
  --compartment-id <YOUR_COMPARTMENT_OCID> \
  --operating-system "Canonical Ubuntu" \
  --shape VM.Standard.A1.Flex \
  --limit 1 \
  --query 'data[0].id'
```

### 6. Run

```bash
chmod +x check-oracle-capacity.sh
./check-oracle-capacity.sh
```

### 7. Set Up Cron (Optional)

Run every minute for best chances:

```bash
# Add to crontab
(crontab -l 2>/dev/null; echo "* * * * * $PWD/check-oracle-capacity.sh >> $PWD/cron.log 2>&1") | crontab -
```

## Configuration

All configuration is in `config.env`:

| Variable | Required | Description |
|----------|----------|-------------|
| `TENANCY_ID` | Yes | Your Oracle Cloud tenancy OCID |
| `COMPARTMENT_ID` | Yes | Compartment OCID (or use tenancy for root) |
| `IMAGE_ID` | Yes | Ubuntu ARM image OCID |
| `SUBNET_ID` | Yes | Subnet OCID where instance will be created |
| `SSH_KEY_FILE` | Yes | Path to SSH public key file |
| `AVAILABILITY_DOMAINS` | Yes | **Array of ADs for YOUR region** (see step 5 above) |
| `SHAPE` | No | Instance shape (default: VM.Standard.A1.Flex) |
| `OCPUS` | No | Number of CPUs (default: 4) |
| `MEMORY_GB` | No | Memory in GB (default: 24) |
| `BOOT_VOLUME_GB` | No | Boot volume size (default: 200) |
| `INSTANCE_NAME_PREFIX` | No | Instance name prefix (default: instance) |

### Region-Specific Configuration

The `config.env.example` file includes Ashburn (US-ASHBURN-1) availability domains by default:

```bash
AVAILABILITY_DOMAINS=(
    "PddS:US-ASHBURN-AD-1"
    "PddS:US-ASHBURN-AD-2"
    "PddS:US-ASHBURN-AD-3"
)
```

**If you're using a different region, you MUST update this array** with the correct AD names from step 5 above!

## Instance Specifications

- **Shape**: VM.Standard.A1.Flex
- **CPUs**: 4 OCPU
- **Memory**: 24 GB
- **Boot Volume**: 200 GB
- **OS**: Ubuntu 24.04 ARM64
- **Cost**: FREE (Always Free tier)

## Usage

### Manual Check
```bash
./check-oracle-capacity.sh
```

### View Logs
```bash
tail -f availability.log
```

### Check Instance State
```bash
cat state
```

### Reset (Allow New Instance Creation)
```bash
rm state
```

## Files

- `check-oracle-capacity.sh` - Main script
- `config.env` - Your configuration (create from `config.env.example`)
- `config.env.example` - Configuration template
- `availability.log` - Script logs
- `state` - Instance creation state (auto-generated)

## Troubleshooting

### Configuration File Not Found
Make sure you've copied `config.env.example` to `config.env` and filled in your values.

### Authentication Errors
Sometimes Oracle's API returns authentication errors when capacity IS available (rate limiting). The script handles this by attempting to create an instance anyway.

### No Capacity
ARM instances are in very high demand. Run the script every minute via cron to maximize your chances.

### Instance Creation Failed
Check `availability.log` for detailed error messages.

### Wrong Availability Domain Names
If you see errors about invalid availability domains, run:
```bash
oci iam availability-domain list --compartment-id <YOUR_TENANCY_OCID>
```
And update the `AVAILABILITY_DOMAINS` array in `config.env` with the correct names for your region.

## How It Works

1. Checks capacity in all configured availability domains
2. When capacity is found (`AVAILABLE` status):
   - Immediately attempts to create instance
   - Saves state to prevent duplicates
   - Logs all details including public IP
3. Exits after successful creation
4. On auth errors (potential capacity), attempts creation anyway

## License

MIT

## Disclaimer

This script is provided as-is. Oracle Cloud's availability changes constantly. No guarantee of instance creation success.
