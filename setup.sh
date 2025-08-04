#!/bin/bash

# K3s on Phone Setup Script
# This script sets up a Kubernetes cluster using K3s on Android phones
# running Debian in KVM hypervisor via the Android Linux Terminal app.
#
# One-line installation:
# curl -sfL https://raw.githubusercontent.com/parttimenerd/k3s-on-phone/refs/heads/main/setup.sh | bash -s -- HOSTNAME -t TAILSCALE_KEY

set -e

# Script version
VERSION="1.0.0"

# Default values
VERBOSE=false
HOSTNAME=""
TAILSCALE_AUTH_KEY=""
K3S_TOKEN=""
K3S_URL=""
CLEANUP_MODE=false
REMOVE_FROM_TAILSCALE=false
LOCAL_MODE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Exit codes
EXIT_SUCCESS=0
EXIT_INVALID_ARGS=1
EXIT_MISSING_DEPS=2
EXIT_INSTALL_FAILED=3
EXIT_CONFIG_FAILED=4

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}[VERBOSE]${NC} $1"
    fi
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
K3s on Phone Setup Script v${VERSION}

Sets up a Kubernetes cluster using K3s on Android phones running Debian
in KVM hypervisor via the Android Linux Terminal app.

USAGE:
    ./setup.sh HOSTNAME [OPTIONS]
    ./setup.sh --local [OPTIONS]
    ./setup.sh cleanup [OPTIONS]

ARGUMENTS:
    HOSTNAME                    Set the hostname for this node (not allowed with --local)
    cleanup                     Remove not-ready nodes from cluster

OPTIONS:
    -t, --tailscale-key KEY     Tailscale authentication key (validated before use)
                                Get one at: https://login.tailscale.com/admin/settings/keys
                                Ensure key is set to 'Reusable' for multiple uses
    -k, --k3s-token TOKEN       K3s node token (must be used with -u)
    -u, --k3s-url URL           K3s server URL (must be used with -k)
    --local                     Local mode: skip hostname, password, Tailscale, Docker setup (but checks Tailscale is running)
    -v, --verbose               Enable verbose output
    -h, --help                  Show this help message
    --version                   Show version information
    --remove-from-tailscale     Also remove nodes from Tailscale VPN (cleanup only)

EXAMPLES:
    # Setup as K3s server (master node)
    ./setup.sh my-phone-01 -t tskey-auth-xxxxx

    # Setup as K3s agent (worker node)
    ./setup.sh my-phone-02 -t tskey-auth-xxxxx -k mynodetoken -u https://my-phone-01:6443

    # Setup agent with auto-generated hostname
    ./setup.sh phone-%d -t tskey-auth-xxxxx -k mynodetoken -u https://my-phone-01:6443

    # Local server setup: computer/server as K3s master
    ./setup.sh --local

    # Local mode: join existing cluster
    ./setup.sh --local -k mynodetoken -u https://existing-server:6443

    # Clean up not-ready nodes
    ./setup.sh cleanup -v

    # Clean up not-ready nodes and remove from Tailscale
    ./setup.sh cleanup --remove-from-tailscale -v

DESCRIPTION:
    This script will:
    1. Set the hostname for the device
    2. Install Docker following official Debian installation guide
    3. Configure SSH server with root access
    4. Install and configure Tailscale for secure networking
    5. Install K3s either as server (master) or agent (worker)

    Cleanup mode will:
    1. Identify nodes in NotReady state
    2. Remove them from the K3s cluster
    3. Optionally remove them from Tailscale VPN

    Local mode will:
    1. Skip hostname, password, Tailscale, and Docker setup
    2. Only install and configure K3s
    3. Suitable for existing systems with prerequisites already installed
    4. If -t flag is provided, it will be included in generated agent commands

NOTES:
    - This script requires sudo privileges
    - Root SSH password will be set to 'root' for simplicity
    - The Android Linux Terminal app is experimental and may be unstable
    - Ensure you have developer mode enabled on your Android device
    - If network connectivity issues occur, restarting and reinstalling 
      Debian on your phone may be needed (known issue with Android Linux Terminal)
    - Cleanup mode must be run from the K3s server (master) node
    - For dead node cleanup, use ./clean.sh
    - For complete cluster reset, use ./reset.sh

TROUBLESHOOTING:
    Common issues and solutions:
    - Network connectivity: Check internet and DNS resolution
    - Permissions: Ensure user has sudo access but don't run as root
    - SSH service: Script handles both 'ssh' and 'sshd' service names automatically
    - Tailscale auth: Keys are validated automatically before use
      • Ensure key format starts with 'tskey-auth-'
      • Check that key hasn't expired or been revoked
      • Set keys to 'Reusable' for multiple node setups
      • Get new keys at: https://login.tailscale.com/admin/settings/keys
    - Firewall: May block Tailscale or K3s traffic
    - Manual Tailscale setup: curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --auth-key=YOUR_KEY

EOF
}

show_version() {
    echo "K3s on Phone Setup Script v${VERSION}"
}

check_sudo() {
    if ! command -v sudo &> /dev/null; then
        log_error "sudo is required but not installed"
        exit $EXIT_MISSING_DEPS
    fi
    
    # Test sudo access
    if ! sudo -n true 2>/dev/null; then
        log "Testing sudo access..."
        if ! sudo true; then
            log_error "sudo access required but not available"
            exit $EXIT_MISSING_DEPS
        fi
    fi
}

check_internet() {
    log_verbose "Checking internet connectivity..."
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log_error "Internet connection required but not available"
        log_error "If connectivity issues persist, try restarting and reinstalling Debian on your phone"
        log_error "This is a known issue with the Android Linux Terminal app"
        exit $EXIT_MISSING_DEPS
    fi
    
    log_verbose "Checking GitHub connectivity..."
    if ! ping -c 1 github.com &> /dev/null; then
        log_error "Cannot reach github.com - this may prevent package downloads"
        log_error "If connectivity issues persist, try restarting and reinstalling Debian on your phone"
        log_error "This is a known issue with the Android Linux Terminal app"
        exit $EXIT_MISSING_DEPS
    fi
}

# Installation functions
detect_ssh_service_name() {
    local ssh_service=""
    
    # Check for available SSH service names
    if systemctl list-unit-files 2>/dev/null | grep -q "^ssh\.service"; then
        ssh_service="ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
        ssh_service="sshd"
    else
        # Try to detect by checking if service files exist
        if [ -f "/lib/systemd/system/ssh.service" ] || [ -f "/etc/systemd/system/ssh.service" ]; then
            ssh_service="ssh"
        elif [ -f "/lib/systemd/system/sshd.service" ] || [ -f "/etc/systemd/system/sshd.service" ]; then
            ssh_service="sshd"
        fi
    fi
    
    echo "$ssh_service"
}

install_docker() {
    log_step "Installing Docker..."
    
    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        log "Docker is already installed, skipping installation"
        return 0
    fi
    
    log_verbose "Updating package list"
    sudo apt-get update -qq || {
        log_error "Failed to update package list"
        exit $EXIT_INSTALL_FAILED
    }
    
    log_verbose "Installing prerequisites"
    sudo apt-get install -y ca-certificates curl || {
        log_error "Failed to install prerequisites"
        exit $EXIT_INSTALL_FAILED
    }
    
    log_verbose "Setting up Docker GPG key"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || {
        log_error "Failed to download Docker GPG key"
        exit $EXIT_INSTALL_FAILED
    }
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    
    log_verbose "Adding Docker repository"
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || {
        log_error "Failed to add Docker repository"
        exit $EXIT_INSTALL_FAILED
    }
    
    log_verbose "Installing Docker packages"
    sudo apt-get update -qq || {
        log_error "Failed to update package list after adding Docker repository"
        exit $EXIT_INSTALL_FAILED
    }
    
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
        log_error "Failed to install Docker packages"
        exit $EXIT_INSTALL_FAILED
    }
    
    log_verbose "Testing Docker installation"
    if sudo docker run --rm hello-world > /dev/null 2>&1; then
        log "Docker installed and tested successfully"
    else
        log_error "Docker test failed"
        exit $EXIT_INSTALL_FAILED
    fi
    
    # Add current user to docker group
    log_verbose "Adding user to docker group"
    sudo usermod -aG docker "$USER" || log_warn "Failed to add user to docker group"
}

# Function to setup insecure registry for Docker daemon
setup_docker_insecure_registry() {
    log_step "Configuring Docker for insecure registry..."
    
    local master_ip="$1"
    local registry_port="${2:-5000}"
    local registry_address="${master_ip}:${registry_port}"
    
    log "Configuring Docker daemon for insecure registry: $registry_address"
    
    # Create or update Docker daemon configuration
    local daemon_config="/etc/docker/daemon.json"
    local temp_config="/tmp/docker-daemon-setup.json"
    
    # Check if daemon.json exists
    if [ -f "$daemon_config" ]; then
        # Parse existing configuration and add insecure registry
        if command -v jq &>/dev/null; then
            # Use jq if available for proper JSON manipulation
            sudo jq --arg registry "$registry_address" \
                '.["insecure-registries"] += [$registry] | .["insecure-registries"] |= unique' \
                "$daemon_config" | sudo tee "$temp_config" >/dev/null
        else
            # Fallback: simple text manipulation (less robust)
            if grep -q "insecure-registries" "$daemon_config"; then
                # Add to existing insecure-registries array
                sudo sed "s/\"insecure-registries\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\]/\"insecure-registries\": [\1, \"$registry_address\"]/g" \
                    "$daemon_config" | sudo tee "$temp_config" >/dev/null
            else
                # Add insecure-registries to existing config
                sudo sed 's/{/{\n  "insecure-registries": ["'"$registry_address"'"],/' \
                    "$daemon_config" | sudo tee "$temp_config" >/dev/null
            fi
        fi
    else
        # Create new daemon.json
        sudo tee "$temp_config" >/dev/null << EOF
{
  "insecure-registries": ["$registry_address"]
}
EOF
    fi
    
    # Validate JSON and apply
    if command -v jq &>/dev/null && jq . "$temp_config" >/dev/null 2>&1; then
        sudo cp "$temp_config" "$daemon_config"
        sudo chmod 644 "$daemon_config"
        log "✅ Docker daemon configuration updated"
        
        # Restart Docker daemon
        log "Restarting Docker daemon..."
        if sudo systemctl restart docker; then
            log "✅ Docker daemon restarted successfully"
            
            # Wait for Docker to be ready
            for i in {1..30}; do
                if docker info >/dev/null 2>&1; then
                    log "✅ Docker daemon is ready"
                    break
                fi
                if [ $i -eq 30 ]; then
                    log_error "Docker daemon failed to restart properly"
                    return 1
                fi
                sleep 1
            done
        else
            log_error "Failed to restart Docker daemon"
            return 1
        fi
    else
        log_error "Failed to create valid Docker daemon configuration"
        return 1
    fi
    
    # Cleanup
    sudo rm -f "$temp_config" 2>/dev/null || true
}

# Function to setup local Docker registry
setup_local_registry() {
    log_step "Setting up local Docker registry..."
    
    # Check if registry.sh exists
    if [ ! -f "./registry.sh" ]; then
        log_error "Registry management script not found: ./registry.sh"
        log_error "Please ensure registry.sh is in the same directory as setup.sh"
        return 1
    fi
    
    # Make sure it's executable
    chmod +x ./registry.sh
    
    # Setup the registry
    log "Running registry setup..."
    if ./registry.sh setup; then
        log "✅ Local Docker registry setup completed"
        
        # Get registry address for reference
        local registry_address
        registry_address=$(./registry.sh address 2>/dev/null || echo "localhost:5000")
        log "Registry available at: $registry_address"
        
        return 0
    else
        log_error "Failed to setup local Docker registry"
        return 1
    fi
}

setup_ssh() {
    log_step "Setting up SSH server..."
    
    log_verbose "Installing OpenSSH server"
    sudo apt-get install -y openssh-server || {
        log_error "Failed to install OpenSSH server"
        exit $EXIT_INSTALL_FAILED
    }
    
    log_verbose "Configuring SSH"
    # Backup original config if it exists and we haven't backed it up yet
    if [ -f /etc/ssh/sshd_config ] && [ ! -f /etc/ssh/sshd_config.backup ]; then
        sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    fi
    
    # Enable root login (configure as needed for security)
    if grep -q "^#PermitRootLogin" /etc/ssh/sshd_config; then
        sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    elif grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
        sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    else
        echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    
    log_verbose "Setting root password to 'root'"
    echo "root:root" | sudo chpasswd || {
        log_error "Failed to set root password"
        exit $EXIT_CONFIG_FAILED
    }
    
    log_verbose "Starting and enabling SSH service"
    
    # Detect the correct SSH service name
    local ssh_service
    ssh_service=$(detect_ssh_service_name)
    
    if [ -z "$ssh_service" ]; then
        log_warn "Could not determine SSH service name, trying common names"
        
        # Try to restart using common service names
        local restart_success=false
        for service in ssh sshd; do
            log_verbose "Trying to restart $service service..."
            if sudo systemctl restart "$service" 2>/dev/null; then
                ssh_service="$service"
                restart_success=true
                log_verbose "Successfully restarted $service service"
                break
            fi
        done
        
        if [ "$restart_success" = false ]; then
            log_error "Failed to restart SSH service (tried ssh and sshd)"
            exit $EXIT_CONFIG_FAILED
        fi
    else
        log_verbose "Using SSH service name: $ssh_service"
        if ! sudo systemctl restart "$ssh_service"; then
            log_error "Failed to restart $ssh_service service"
            exit $EXIT_CONFIG_FAILED
        fi
    fi
    
    # Enable the SSH service
    log_verbose "Enabling SSH service: $ssh_service"
    if ! sudo systemctl enable "$ssh_service" 2>/dev/null; then
        log_warn "Failed to enable $ssh_service service - SSH may not start on boot"
    fi
    
    # Verify SSH service is running
    if sudo systemctl is-active "$ssh_service" &>/dev/null; then
        log_verbose "SSH service '$ssh_service' is running"
    else
        log_warn "SSH service may not be running properly"
        log_warn "Check with: sudo systemctl status $ssh_service"
    fi
    
    log "SSH server configured successfully"
    log_warn "Root SSH login enabled with password 'root' - consider changing for security"
}

setup_tailscale() {
    log_step "Installing and configuring Tailscale..."
    
    # Check network connectivity first
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        log_error "No internet connectivity - cannot install Tailscale"
        echo "Please check your network connection and try again"
        exit $EXIT_INSTALL_FAILED
    fi
    
    # Install Tailscale if not already installed
    if ! command -v tailscale &> /dev/null; then
        log_verbose "Installing Tailscale"
        
        # Try the official installer with better error handling
        if ! curl -fsSL https://tailscale.com/install.sh | sh; then
            log_error "Failed to install Tailscale via official installer"
            echo ""
            echo "Troubleshooting options:"
            echo "1. Check internet connectivity: ping tailscale.com"
            echo "2. Check firewall/proxy settings"
            echo "3. Try manual installation from https://tailscale.com/download"
            echo "4. Check the manual installation guide at: https://tailscale.com/kb/"
            echo ""
            exit $EXIT_INSTALL_FAILED
        fi
        
        # Verify installation
        if ! command -v tailscale &> /dev/null; then
            log_error "Tailscale installation completed but command not found"
            echo "Try: sudo apt-get install tailscale"
            exit $EXIT_INSTALL_FAILED
        fi
        
        log "Tailscale installed successfully"
    else
        log "Tailscale is already installed"
        log_verbose "Version: $(tailscale version --short 2>/dev/null || echo 'unknown')"
    fi
    
    # Ensure Tailscale daemon is running
    log_verbose "Starting Tailscale daemon..."
    if command -v systemctl &>/dev/null; then
        sudo systemctl enable tailscaled 2>/dev/null || log_warn "Failed to enable Tailscale service"
        sudo systemctl start tailscaled 2>/dev/null || log_warn "Failed to start Tailscale service"
        
        # Wait for daemon to initialize
        sleep 2
        
        # Check if daemon is running
        if ! sudo systemctl is-active tailscaled &>/dev/null; then
            log_error "Tailscale daemon failed to start"
            echo "Check status with: sudo systemctl status tailscaled"
            echo "Check logs with: sudo journalctl -u tailscaled"
            exit $EXIT_CONFIG_FAILED
        fi
    fi
    
    # Check if already configured and running
    if sudo tailscale status --json &> /dev/null; then
        log "Tailscale is already configured and running"
        log_verbose "Status: $(sudo tailscale status --peers=false 2>/dev/null | head -1 || echo 'Connected')"
        return 0
    fi
    
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        log_verbose "Connecting to Tailscale with validated auth key"
        log_verbose "Auth key starts with: $(echo "$TAILSCALE_AUTH_KEY" | cut -c1-15)..."
        log_verbose "Hostname for auth: $HOSTNAME"
        
        # Attempt authentication with detailed error handling
        log "Authenticating with Tailscale using provided auth key..."
        if sudo tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --hostname="$HOSTNAME"; then
            log "Successfully connected to Tailscale"
            
            # Show connection status
            sleep 2
            if sudo tailscale status &>/dev/null; then
                log_verbose "Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'unknown')"
            fi
        else
            local exit_code=$?
            log_error "Failed to connect to Tailscale (exit code: $exit_code)"
            echo ""
            echo "Debug information:"
            echo "• Auth key length: ${#TAILSCALE_AUTH_KEY}"
            echo "• Auth key prefix: $(echo "$TAILSCALE_AUTH_KEY" | cut -c1-15)..."
            echo "• Hostname: $HOSTNAME"
            echo ""
            echo "Common issues:"
            echo "• Auth key expired or invalid"
            echo "• Auth key already used (single-use keys)"
            echo "• Network connectivity problems"
            echo "• Firewall blocking Tailscale"
            echo "• Hostname already in use"
            echo ""
            echo "Troubleshooting:"
            echo "• Check auth key at: https://login.tailscale.com/admin/settings/keys"
            echo "• Try manual authentication: sudo tailscale up"
            echo "• Check Tailscale documentation: https://tailscale.com/kb/"
            echo ""
            echo "Working manual command that you reported:"
            echo "curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --auth-key=$TAILSCALE_AUTH_KEY"
            echo ""
            exit $EXIT_CONFIG_FAILED
        fi
    else
        log "Tailscale installed. Run 'sudo tailscale up --auth-key=YOUR_KEY' to connect manually"
        echo ""
        echo "Get an auth key from: https://login.tailscale.com/admin/settings/keys"
        echo "Or authenticate interactively: sudo tailscale up"
        echo ""
    fi
    
    log "Tailscale setup completed"
}

check_tailscale_local_mode() {
    log_step "Checking Tailscale status in local mode..."
    
    # Check if Tailscale is installed
    if ! command -v tailscale &> /dev/null; then
        log_error "Tailscale is not installed!"
        echo ""
        echo "Please install Tailscale first:"
        echo "  curl -fsSL https://tailscale.com/install.sh | sh"
        echo ""
        echo "Then authenticate with your Tailscale account:"
        echo "  sudo tailscale up"
        echo ""
        exit $EXIT_MISSING_DEPS
    fi
    
    # Check if Tailscale is running and authenticated
    if ! sudo tailscale status --json &> /dev/null; then
        log_error "Tailscale is installed but not running or not authenticated!"
        echo ""
        echo "Please ensure Tailscale is set up and running:"
        echo "  sudo tailscale up"
        echo ""
        echo "If you haven't authenticated yet, you'll be prompted to visit a URL to authenticate."
        echo ""
        exit $EXIT_CONFIG_FAILED
    fi
    
    # Get Tailscale status
    local tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
    local tailscale_hostname=$(tailscale status --json 2>/dev/null | grep -o '"Name":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "unknown")
    
    log "✅ Tailscale is running"
    log_verbose "Tailscale IP: $tailscale_ip"
    log_verbose "Tailscale hostname: $tailscale_hostname"
}

set_hostname() {
    log_step "Setting hostname to: $HOSTNAME"
    
    # Get current hostname
    local current_hostname=$(hostname)
    
    if [ "$current_hostname" = "$HOSTNAME" ]; then
        log "Hostname is already set correctly"
        return 0
    fi
    
    # Try to use hostnamectl if available (systemd systems)
    if command -v hostnamectl &> /dev/null; then
        log_verbose "Using hostnamectl to set hostname"
        sudo hostnamectl set-hostname "$HOSTNAME" || {
            log_error "Failed to set hostname using hostnamectl"
            exit $EXIT_CONFIG_FAILED
        }
    else
        # Fallback to manual hostname setting
        log_verbose "Using manual hostname configuration"
        
        log_verbose "Updating /etc/hostname"
        echo "$HOSTNAME" | sudo tee /etc/hostname > /dev/null || {
            log_error "Failed to update /etc/hostname"
            exit $EXIT_CONFIG_FAILED
        }
        
        log_verbose "Setting hostname for current session"
        sudo hostname "$HOSTNAME" || {
            log_error "Failed to set hostname for current session"
            exit $EXIT_CONFIG_FAILED
        }
    fi
    
    log_verbose "Updating /etc/hosts"
    # Update or add the hostname entry
    if grep -q "127.0.1.1" /etc/hosts; then
        sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
    else
        echo -e "127.0.1.1\t$HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
    fi
    
    # Verify the hostname was set correctly
    local new_hostname=$(hostname)
    if [ "$new_hostname" = "$HOSTNAME" ]; then
        log "Hostname set successfully to: $new_hostname"
    else
        log_warn "Hostname may not have been set correctly (current: $new_hostname, expected: $HOSTNAME)"
        log_warn "A reboot may be required for the hostname change to fully take effect"
    fi
}

# Function to deploy the reverse geocoder service
deploy_geocoder_service() {
    log_step "Deploying reverse geocoder service..."
    
    # Check if we're in the right directory structure
    local current_dir
    current_dir=$(pwd)
    local geocoder_dir=""
    
    # Look for the geocoder_app directory
    if [ -d "./geocoder_app" ]; then
        geocoder_dir="./geocoder_app"
    elif [ -d "../geocoder_app" ]; then
        geocoder_dir="../geocoder_app"
    elif [ -d "/home/$USER/code/experiments/k3s-on-phone/geocoder_app" ]; then
        geocoder_dir="/home/$USER/code/experiments/k3s-on-phone/geocoder_app"
    else
        log_warn "Geocoder app directory not found, skipping geocoder deployment"
        log_warn "Reverse geocoding will fallback to external Nominatim service"
        return 0
    fi
    
    log_verbose "Found geocoder directory at: $geocoder_dir"
    
    # Change to geocoder directory
    cd "$geocoder_dir" || {
        log_warn "Cannot access geocoder directory, skipping geocoder deployment"
        return 0
    }
    
    # Check if the geocoder service already exists
    if kubectl get deployment reverse-geocoder >/dev/null 2>&1; then
        log "Reverse geocoder service already deployed, checking status..."
        if kubectl get deployment reverse-geocoder -o jsonpath='{.status.readyReplicas}' | grep -q "1"; then
            log "✅ Reverse geocoder service is already running"
            cd "$current_dir"
            return 0
        else
            log "⚠️  Reverse geocoder service exists but not ready, redeploying..."
        fi
    fi
    
    # Build the geocoder service if build script exists
    if [ -x "./build.sh" ]; then
        log_verbose "Building reverse geocoder service..."
        if ./build.sh >/dev/null 2>&1; then
            log "✅ Geocoder service built successfully"
        else
            log_warn "Geocoder build failed, attempting deployment anyway..."
        fi
    else
        log_verbose "No build script found, deploying existing image..."
    fi
    
    # Deploy the geocoder service if deployment script exists
    if [ -x "./deploy.sh" ]; then
        log_verbose "Deploying reverse geocoder service..."
        if ./deploy.sh >/dev/null 2>&1; then
            log "✅ Reverse geocoder service deployed successfully"
            
            # Wait for deployment to be ready
            log_verbose "Waiting for geocoder service to be ready..."
            if kubectl wait --for=condition=available deployment/reverse-geocoder --timeout=120s >/dev/null 2>&1; then
                log "✅ Reverse geocoder service is ready"
            else
                log_warn "Geocoder service deployment timeout, may still be starting"
            fi
        else
            log_warn "Geocoder deployment failed, continuing without local reverse geocoding"
            log_warn "Node location updates will use external Nominatim service"
        fi
    else
        log_warn "No deployment script found for geocoder, skipping deployment"
    fi
    
    # Return to original directory
    cd "$current_dir"
}

install_k3s_server() {
    log_step "Installing K3s as server (master node)..."
    
    # Check if K3s is already installed
    if command -v k3s &> /dev/null; then
        log "K3s is already installed, checking configuration..."
        
        # Check if this is running as a server by looking for server process
        if sudo systemctl is-active --quiet k3s 2>/dev/null; then
            log "K3s server service is already running"
            
            # Server is running, token file should exist - read it directly
            if sudo test -f /var/lib/rancher/k3s/server/node-token; then
                show_agent_setup_info
                return 0
            else
                log_error "K3s server service is running but token file not found"
                log_error "Server may have failed to initialize properly"
                return 1
            fi
        elif sudo systemctl is-active --quiet k3s-agent 2>/dev/null; then
            log_error "K3s is already installed and running as an agent (worker node)"
            log_error "Cannot install server on a node that's already configured as an agent"
            log_error "Use cleanup mode or reinstall K3s to change the node type"
            return 1
        else
            log "K3s is installed but not running, will start as server"
        fi
    fi
    
    log_verbose "Checking GitHub connectivity for K3s download..."
    if ! ping -c 1 github.com &> /dev/null; then
        log_error "Cannot reach github.com - network connectivity issue detected"
        log_error "If connectivity issues persist, try restarting and reinstalling Debian on your phone"
        log_error "This is a known issue with the Android Linux Terminal app"
        exit $EXIT_INSTALL_FAILED
    fi
    
    log_verbose "Downloading and installing K3s server"
    curl -sfL https://get.k3s.io | sh - || {
        log_error "Failed to install K3s server"
        log_error "If download failed due to connectivity, try restarting and reinstalling Debian"
        exit $EXIT_INSTALL_FAILED
    }
    
    log_verbose "Waiting for K3s to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if sudo k3s kubectl get nodes &> /dev/null; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done
    
    if [ $retries -eq 0 ]; then
        log_error "K3s server failed to start properly"
        exit $EXIT_INSTALL_FAILED
    fi
    
    log "K3s server installed successfully!"
    
    # Deploy the reverse geocoder service (critical for node location labeling)
    deploy_geocoder_service
    
    # Setup local Docker registry for the server
    if setup_local_registry; then
        log "✅ Registry setup completed"
    else
        log_warn "Registry setup failed - continuing without registry"
    fi
    
    show_agent_setup_info
}

# Function to set up geolocation monitoring service
setup_geolocation_service() {
    log_step "Setting up geolocation monitoring service..."
    
    # Create the geolocation monitor script
    local service_script="/usr/local/bin/k3s-geolocation-monitor"
    log_verbose "Creating geolocation monitor script at $service_script"
    
    sudo tee "$service_script" >/dev/null << 'EOF'
#!/bin/bash

# K3s Geolocation Monitor Service
# Monitors phone app geolocation API and updates node labels

# Configuration
PHONE_API_URL="http://localhost:8005"
GEOLOCATION_ENDPOINT="$PHONE_API_URL/location"
NODE_NAME=$(hostname)
LABEL_PREFIX="phone.location"
CHECK_INTERVAL=20

# Logging
LOG_TAG="k3s-geolocation"

log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" | systemd-cat -t "$LOG_TAG" -p info
}

log_warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" | systemd-cat -t "$LOG_TAG" -p warning
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | systemd-cat -t "$LOG_TAG" -p err
}

# Function to get current coordinates from phone app
get_phone_location() {
    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 "$GEOLOCATION_ENDPOINT" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        # Try to parse JSON response
        local latitude longitude altitude
        
        # Simple JSON parsing (works without jq)
        latitude=$(echo "$response" | grep -o '"latitude"[[:space:]]*:[[:space:]]*[^,}]*' | sed 's/.*:[[:space:]]*//' | tr -d '"')
        longitude=$(echo "$response" | grep -o '"longitude"[[:space:]]*:[[:space:]]*[^,}]*' | sed 's/.*:[[:space:]]*//' | tr -d '"')
        altitude=$(echo "$response" | grep -o '"altitude"[[:space:]]*:[[:space:]]*[^,}]*' | sed 's/.*:[[:space:]]*//' | tr -d '"')
        
        # Validate coordinates (basic check)
        if [[ "$latitude" =~ ^-?[0-9]+\.?[0-9]*$ ]] && [[ "$longitude" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            # Use altitude if available, otherwise use 0
            if [[ "$altitude" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
                echo "$latitude,$longitude,$altitude"
            else
                echo "$latitude,$longitude,0"
            fi
            return 0
        fi
    fi
    
    return 1
}

# Function to get current node labels
get_current_labels() {
    local latitude longitude altitude
    
    latitude=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.labels['$LABEL_PREFIX/latitude']}" 2>/dev/null || echo "")
    longitude=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.labels['$LABEL_PREFIX/longitude']}" 2>/dev/null || echo "")
    altitude=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.labels['$LABEL_PREFIX/altitude']}" 2>/dev/null || echo "")
    
    if [ -n "$latitude" ] && [ -n "$longitude" ]; then
        # Use altitude if available, otherwise use 0
        if [ -n "$altitude" ]; then
            echo "$latitude,$longitude,$altitude"
        else
            echo "$latitude,$longitude,0"
        fi
        return 0
    fi
    
    return 1
}

# Function to update node labels with new coordinates
update_node_labels() {
    local new_coords="$1"
    local latitude longitude altitude
    
    latitude=$(echo "$new_coords" | cut -d',' -f1)
    longitude=$(echo "$new_coords" | cut -d',' -f2)
    altitude=$(echo "$new_coords" | cut -d',' -f3)
    
    # Update labels
    if kubectl label node "$NODE_NAME" "$LABEL_PREFIX/latitude=$latitude" --overwrite >/dev/null 2>&1 && \
       kubectl label node "$NODE_NAME" "$LABEL_PREFIX/longitude=$longitude" --overwrite >/dev/null 2>&1 && \
       kubectl label node "$NODE_NAME" "$LABEL_PREFIX/altitude=$altitude" --overwrite >/dev/null 2>&1; then
        
        log_info "Updated node labels: latitude=$latitude, longitude=$longitude, altitude=$altitude"
        
        # Also add a timestamp label for debugging
        local timestamp
        timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
        kubectl label node "$NODE_NAME" "$LABEL_PREFIX/updated=$timestamp" --overwrite >/dev/null 2>&1
        
        return 0
    else
        log_error "Failed to update node labels"
        return 1
    fi
}

# Function to perform reverse geocoding using local API
reverse_geocode() {
    local latitude="$1"
    local longitude="$2"
    
    # Try to find the reverse geocoder service endpoint
    local api_url=""
    
    # First try to find the geocoder service in Kubernetes
    if command -v kubectl >/dev/null 2>&1; then
        local service_ip
        service_ip=$(kubectl get service reverse-geocoder -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        if [ -n "$service_ip" ]; then
            api_url="http://${service_ip}:8090"
        fi
    fi
    
    # If Kubernetes service not found, try localhost (for development)
    if [ -z "$api_url" ]; then
        api_url="http://localhost:8090"
    fi
    
    # Call our reverse geocoding API (using geonames method only)
    local url="${api_url}/api/reverse-geocode?lat=${latitude}&lon=${longitude}&method=geonames"
    
    local response
    response=$(curl -s --connect-timeout 10 --max-time 15 \
        -H "User-Agent: K3s-on-Phone/1.0" \
        "$url" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        # Extract location from JSON response
        local location
        location=$(echo "$response" | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
        
        if [ -n "$location" ]; then
            echo "$location"
            return 0
        fi
    fi
    
    # If local API fails, return empty (no external fallback)
    log_warn "Local reverse geocoding API failed for coordinates $latitude, $longitude"
    return 1
}

# Function to update city label
update_city_label() {
    local latitude="$1"
    local longitude="$2"
    
    # Check if we need to update (only if no city label or it's old)
    local current_city city_updated_label
    current_city=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.labels['$LABEL_PREFIX/city']}" 2>/dev/null || echo "")
    city_updated_label=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.labels['$LABEL_PREFIX/city-updated']}" 2>/dev/null || echo "")
    
    # Skip if city was updated recently (within 24 hours)
    if [ -n "$current_city" ] && [ -n "$city_updated_label" ]; then
        local city_updated_epoch current_epoch age_seconds
        city_updated_epoch=$(date -d "$city_updated_label" +%s 2>/dev/null || echo "0")
        current_epoch=$(date +%s)
        age_seconds=$((current_epoch - city_updated_epoch))
        
        # Skip if updated within 24 hours (86400 seconds)
        if [ $age_seconds -lt 86400 ]; then
            log_info "City label is current: $current_city"
            return 0
        fi
    fi
    
    # Perform reverse geocoding
    local city_name
    if city_name=$(reverse_geocode "$latitude" "$longitude"); then
        log_info "Found city: $city_name"
        
        # Escape special characters for Kubernetes labels
        local escaped_city
        escaped_city=$(echo "$city_name" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/^_*//;s/_*$//')
        
        if kubectl label node "$NODE_NAME" "$LABEL_PREFIX/city=$escaped_city" --overwrite >/dev/null 2>&1; then
            # Also add a timestamp for city update
            local timestamp
            timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
            kubectl label node "$NODE_NAME" "$LABEL_PREFIX/city-updated=$timestamp" --overwrite >/dev/null 2>&1
            
            log_info "Updated city label: $city_name"
            return 0
        else
            log_error "Failed to update city label"
            return 1
        fi
    else
        log_warn "Reverse geocoding failed for coordinates $latitude, $longitude"
        # Set a generic city label to avoid repeated attempts
        local escaped_city="Unknown"
        kubectl label node "$NODE_NAME" "$LABEL_PREFIX/city=$escaped_city" --overwrite >/dev/null 2>&1
        local timestamp
        timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
        kubectl label node "$NODE_NAME" "$LABEL_PREFIX/city-updated=$timestamp" --overwrite >/dev/null 2>&1
        return 1
    fi
}

# Function to check if coordinates have changed significantly
coordinates_changed() {
    local old_coords="$1"
    local new_coords="$2"
    
    # If no old coordinates, consider it changed
    if [ -z "$old_coords" ]; then
        return 0
    fi
    
    # Parse coordinates
    local old_lat old_lon new_lat new_lon
    old_lat=$(echo "$old_coords" | cut -d',' -f1)
    old_lon=$(echo "$old_coords" | cut -d',' -f2)
    new_lat=$(echo "$new_coords" | cut -d',' -f1)
    new_lon=$(echo "$new_coords" | cut -d',' -f2)
    
    # Calculate rough distance (simplified for speed)
    # Consider changed if difference > 0.0001 degrees (~11 meters)
    local lat_diff lon_diff
    lat_diff=$(echo "$old_lat $new_lat" | awk '{print ($1 > $2) ? $1 - $2 : $2 - $1}')
    lon_diff=$(echo "$old_lon $new_lon" | awk '{print ($1 > $2) ? $1 - $2 : $2 - $1}')
    
    # Use awk for floating point comparison
    if awk "BEGIN {exit !($lat_diff > 0.0001 || $lon_diff > 0.0001)}"; then
        return 0  # Changed
    else
        return 1  # Not changed
    fi
}

# Main monitoring loop
main() {
    log_info "Starting geolocation monitoring for node: $NODE_NAME"
    log_info "Phone API endpoint: $GEOLOCATION_ENDPOINT"
    log_info "Check interval: ${CHECK_INTERVAL}s"
    
    while true; do
        # Get current location from phone
        local new_location
        if new_location=$(get_phone_location); then
            log_info "Phone app available, location: $new_location"
            
            # Get current node labels
            local current_labels
            current_labels=$(get_current_labels) || current_labels=""
            
            # Check if coordinates changed
            if coordinates_changed "$current_labels" "$new_location"; then
                log_info "Location changed from '$current_labels' to '$new_location', updating labels..."
                
                if update_node_labels "$new_location"; then
                    log_info "Successfully updated node geolocation labels"
                    
                    # Also update city information using reverse geocoding
                    log_info "Updating city information..."
                    local latitude longitude
                    latitude=$(echo "$new_location" | cut -d',' -f1)
                    longitude=$(echo "$new_location" | cut -d',' -f2)
                    
                    if update_city_label "$latitude" "$longitude"; then
                        log_info "Successfully updated city information"
                    else
                        log_warn "Failed to update city information"
                    fi
                else
                    log_error "Failed to update node labels"
                fi
            else
                log_info "Location unchanged, no update needed"
            fi
        else
            # Phone app not available, but don't spam logs
            if [ $(($(date +%s) % 300)) -eq 0 ]; then  # Log every 5 minutes
                log_warn "Phone app not available at $GEOLOCATION_ENDPOINT"
            fi
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# Signal handlers for graceful shutdown
cleanup() {
    log_info "Received shutdown signal, stopping geolocation monitoring"
    exit 0
}

trap cleanup TERM INT

# Start monitoring
main
EOF
    
    # Make the script executable
    sudo chmod +x "$service_script"
    log_verbose "Made geolocation monitor script executable"
    
    # Create systemd service file
    local service_file="/etc/systemd/system/k3s-geolocation-monitor.service"
    log_verbose "Creating systemd service file at $service_file"
    
    sudo tee "$service_file" >/dev/null << EOF
[Unit]
Description=K3s Geolocation Monitor
Documentation=https://github.com/parttimenerd/k3s-on-phone
After=k3s-agent.service
Wants=k3s-agent.service
StartLimitInterval=0

[Service]
Type=simple
ExecStart=$service_script
Restart=always
RestartSec=30
User=root
Group=root
KillMode=process
TimeoutStopSec=30

# Environment
Environment=KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=k3s-geolocation

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and enable the service
    sudo systemctl daemon-reload
    
    if sudo systemctl enable k3s-geolocation-monitor.service; then
        log_verbose "Enabled geolocation monitor service"
        
        # Start the service
        if sudo systemctl start k3s-geolocation-monitor.service; then
            log "✅ Geolocation monitoring service started successfully"
            
            # Check if it's running
            sleep 2
            if sudo systemctl is-active --quiet k3s-geolocation-monitor.service; then
                log_verbose "Geolocation service is running"
            else
                log_warn "Geolocation service may have failed to start"
            fi
        else
            log_warn "Failed to start geolocation monitoring service"
        fi
    else
        log_warn "Failed to enable geolocation monitoring service"
    fi
    
    log "Geolocation monitoring service setup completed"
    log "Service will check phone app every 20 seconds and update node labels"
    log "View logs with: sudo journalctl -u k3s-geolocation-monitor -f"
}

# Function to label the current node as a phone for deployment targeting
label_node_as_phone() {
    log_step "Labeling node as 'phone' for deployment targeting..."
    
    local node_name
    node_name=$(hostname)
    
    # Wait for the node to be registered in the cluster
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl get node "$node_name" &>/dev/null 2>&1; then
            log_verbose "Node $node_name found in cluster"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "Node $node_name not found in cluster after $max_attempts attempts"
            log_warn "Node labeling skipped - you may need to label manually:"
            log_warn "  kubectl label node $node_name device-type=phone"
            return 1
        fi
        
        log_verbose "Waiting for node $node_name to appear in cluster... (attempt $attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    # Apply the phone label
    if kubectl label node "$node_name" device-type=phone --overwrite &>/dev/null; then
        log "✅ Node $node_name labeled as device-type=phone"
        
        # Also add a role label for clarity
        if kubectl label node "$node_name" node-role.kubernetes.io/phone=true --overwrite &>/dev/null; then
            log_verbose "Node $node_name also labeled with role phone"
        fi
        
        # Verify the labels were applied
        log_verbose "Node labels:"
        kubectl get node "$node_name" --show-labels 2>/dev/null | grep -E "device-type=phone|node-role.kubernetes.io/phone" || true
        
    else
        log_warn "Failed to label node $node_name - you may need to do this manually:"
        log_warn "  kubectl label node $node_name device-type=phone"
        log_warn "  kubectl label node $node_name node-role.kubernetes.io/phone=true"
        return 1
    fi
}

install_k3s_agent() {
    log_step "Installing K3s as agent (worker node)..."
    
    # Check if K3s is already installed
    if command -v k3s &> /dev/null; then
        log "K3s is already installed, checking configuration..."
        
        # Check if this is running as an agent
        if sudo systemctl is-active --quiet k3s-agent 2>/dev/null; then
            log "K3s agent service is already running"
            show_agent_completion_info
            return 0
        elif sudo systemctl is-active --quiet k3s 2>/dev/null; then
            log_error "K3s is already installed and running as a server (master node)"
            log_error "Cannot install agent on a node that's already configured as a server"
            log_error "Use cleanup mode or reinstall K3s to change the node type"
            return 1
        else
            log "K3s is installed but not running, will start as agent"
        fi
    fi
    
    # Extract master IP from K3S_URL for registry configuration
    log_verbose "Configuring Docker for insecure registry access..."
    if [ -n "$K3S_URL" ]; then
        # Extract IP from URL like https://192.168.1.100:6443 -> 192.168.1.100
        MASTER_IP=$(echo "$K3S_URL" | sed -E 's|https?://([^:]+):.*|\1|')
        if [ -n "$MASTER_IP" ] && [[ "$MASTER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_verbose "Configuring Docker for insecure registry at $MASTER_IP:5000"
            setup_docker_insecure_registry "$MASTER_IP:5000"
        else
            log_warn "Could not extract valid IP from K3S_URL: $K3S_URL, skipping registry configuration"
        fi
    else
        log_warn "K3S_URL not set, skipping registry configuration"
    fi
    
    log_verbose "Checking GitHub connectivity for K3s download..."
    if ! ping -c 1 github.com &> /dev/null; then
        log_error "Cannot reach github.com - network connectivity issue detected"
        log_error "If connectivity issues persist, try restarting and reinstalling Debian on your phone"
        log_error "This is a known issue with the Android Linux Terminal app"
        exit $EXIT_INSTALL_FAILED
    fi
    
    log_verbose "Downloading and installing K3s agent with server URL: $K3S_URL"
    curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh - || {
        log_error "Failed to install K3s agent"
        log_error "If download failed due to connectivity, try restarting and reinstalling Debian"
        exit $EXIT_INSTALL_FAILED
    }
    
    # Wait a moment for the agent to start and connect
    log_verbose "Waiting for K3s agent to connect to cluster..."
    sleep 5
    
    # Label the node as a phone for deployment targeting
    label_node_as_phone
    
    # Set up geolocation monitoring service
    setup_geolocation_service
    
    # Show agent setup completion information
    show_agent_completion_info
}

show_agent_completion_info() {
    echo ""
    log "=============================================="
    log "K3s Agent Setup Complete!"
    log "=============================================="
    echo ""
    
    # Basic node information
    log "Node Information:"
    log "  Hostname: $HOSTNAME"
    log "  Connected to: $K3S_URL"
    echo ""
    
    # Check if we can get node status from the cluster
    if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null 2>&1; then
        log "Cluster Connection: ✅ Connected"
        
        # Try to get this node's status
        local node_status
        node_status=$(kubectl get node "$HOSTNAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$node_status" = "True" ]; then
            log "Node Status: ✅ Ready"
        else
            log "Node Status: ⏳ Joining cluster..."
        fi
        
        # Show node info if available
        if kubectl get node "$HOSTNAME" &> /dev/null; then
            echo ""
            log "Node Details:"
            kubectl get node "$HOSTNAME" -o wide 2>/dev/null || log_warn "Could not retrieve detailed node information"
            
            # Show node labels for phone targeting
            local device_label
            device_label=$(kubectl get node "$HOSTNAME" -o jsonpath='{.metadata.labels.device-type}' 2>/dev/null || echo "")
            if [ "$device_label" = "phone" ]; then
                log "Node Label: ✅ device-type=phone (ready for phone-targeted deployments)"
            else
                log "Node Label: ⚠️  device-type not set (deployments may not target this node)"
            fi
        fi
        
        # Show cluster nodes count
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "unknown")
        echo ""
        log "Cluster Summary:"
        log "  Total nodes in cluster: $node_count"
        
        # Show running pods on this node
        local pod_count
        pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$HOSTNAME" --no-headers 2>/dev/null | wc -l || echo "unknown")
        log "  Pods running on this node: $pod_count"
        
    else
        log "Cluster Connection: ⏳ Agent connecting to cluster..."
        log_warn "kubectl not available or cluster not accessible from agent node"
        log "The agent should be connecting to the cluster. Check status from the server node."
    fi
    
    # Network information
    echo ""
    log "Network Information:"
    local node_ip
    node_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    log "  Node IP: $node_ip"
    
    # Docker registry configuration status
    if [ -f /etc/docker/daemon.json ]; then
        log "  Docker Registry: ✅ Configured for local registry access"
    else
        log "  Docker Registry: ⚠️  No insecure registry configuration"
    fi
    
    # Geolocation monitoring service status
    if sudo systemctl is-active --quiet k3s-geolocation-monitor.service 2>/dev/null; then
        log "  Geolocation Service: ✅ Running (monitors phone app every 20s)"
    elif sudo systemctl is-enabled --quiet k3s-geolocation-monitor.service 2>/dev/null; then
        log "  Geolocation Service: ⏳ Enabled but not running"
    else
        log "  Geolocation Service: ❌ Not installed"
    fi
    
    # Tailscale information if available
    if command -v tailscale &> /dev/null && tailscale status &> /dev/null; then
        local tailscale_ip
        local tailscale_name
        tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
        tailscale_name=$(tailscale status --json 2>/dev/null | grep -o '"Name":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "unknown")
        log "  Tailscale IP: $tailscale_ip"
        log "  Tailscale Name: $tailscale_name"
    fi
    
    echo ""
    log "Next Steps:"
    log "  • Check cluster status from server node: kubectl get nodes"
    log "  • View pods on this node: kubectl get pods --all-namespaces --field-selector spec.nodeName=$HOSTNAME"
    log "  • Monitor node logs: sudo journalctl -u k3s-agent -f"
    echo ""
}

show_agent_setup_info() {
    if ! sudo test -f /var/lib/rancher/k3s/server/node-token; then
        log_warn "K3s node token file not found, cannot show agent setup commands"
        return 1
    fi
    
    local token
    token=$(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null)
    if [ -z "$token" ]; then
        log_warn "Failed to read K3s node token"
        return 1
    fi
    
    local server_url="https://$HOSTNAME:6443"
    
    # Handle Tailscale auth key parameter based on context
    local tailscale_flag=""
    if [ "$LOCAL_MODE" = true ]; then
        # In local mode, only include -t if it was explicitly provided
        if [ -n "$TAILSCALE_AUTH_KEY" ]; then
            tailscale_flag=" -t $TAILSCALE_AUTH_KEY"
        fi
    else
        # In non-local mode, always include -t (with placeholder if not provided)
        local tailscale_key_param="${TAILSCALE_AUTH_KEY:-YOUR_TAILSCALE_AUTH_KEY}"
        tailscale_flag=" -t $tailscale_key_param"
    fi
    
    # Create the commands for display and file
    local cmd_auto="curl -sfL https://raw.githubusercontent.com/parttimenerd/k3s-on-phone/refs/heads/main/setup.sh | bash -s -- phone-%d$tailscale_flag -k $token -u $server_url"
    local cmd_manual="curl -sfL https://raw.githubusercontent.com/parttimenerd/k3s-on-phone/refs/heads/main/setup.sh | bash -s -- AGENT_HOSTNAME$tailscale_flag -k $token -u $server_url"
    local cmd_download1="curl -sfL https://raw.githubusercontent.com/parttimenerd/k3s-on-phone/refs/heads/main/setup.sh > setup.sh"
    local cmd_download2="chmod +x setup.sh"
    local cmd_download3="./setup.sh AGENT_HOSTNAME$tailscale_flag -k $token -u $server_url"
    
    echo ""
    log "=============================================="
    log "K3s Server Setup Complete!"
    log "=============================================="
    echo ""
    log "K3s Token (for agent nodes): $token"
    log "Server URL: $server_url"
    echo ""
    log "To get the token manually anytime:"
    echo "sudo cat /var/lib/rancher/k3s/server/node-token"
    echo ""
    log "To add agent nodes, use one of the following methods:"
    echo ""
    echo "Option 1 - One-line setup with auto-generated hostname:"
    echo ""
    echo "$cmd_auto"
    echo ""
    echo "Option 2 - One-line setup with manual hostname:"
    echo ""
    echo "$cmd_manual"
    echo ""
    echo "Option 3 - Download and run manually:"
    echo ""
    echo "$cmd_download1"
    echo "$cmd_download2"
    echo "$cmd_download3"
    echo ""
    log "Option 1 auto-generates unique hostnames. For manual setup (Options 2-3), replace AGENT_HOSTNAME with the desired hostname for each agent node"
    if [ "$LOCAL_MODE" = false ] && [ -z "$TAILSCALE_AUTH_KEY" ]; then
        log "Replace YOUR_TAILSCALE_AUTH_KEY with your actual Tailscale auth key"
    fi
    echo ""
    
    # Save commands to add_nodes.md file
    local add_nodes_file="add_nodes.md"
    log "Saving setup commands to: $add_nodes_file"
    
    cat > "$add_nodes_file" << EOF
# K3s Agent Node Setup Commands

Generated on: $(date)
Server: $HOSTNAME ($server_url)

## Quick Reference

### K3s Token
\`\`\`
$token
\`\`\`

### Server URL
\`\`\`
$server_url
\`\`\`

## Setup Methods

### Option 1 - One-line setup with auto-generated hostname
\`\`\`bash
$cmd_auto
\`\`\`

### Option 2 - One-line setup with manual hostname
\`\`\`bash
$cmd_manual
\`\`\`

### Option 3 - Download and run manually
\`\`\`bash
$cmd_download1
$cmd_download2
$cmd_download3
\`\`\`

## Notes
- Option 1 auto-generates unique hostnames using timestamp-based naming
- For manual setup (Options 2-3), replace \`AGENT_HOSTNAME\` with your desired hostname
EOF

    if [ "$LOCAL_MODE" = false ] && [ -z "$TAILSCALE_AUTH_KEY" ]; then
        cat >> "$add_nodes_file" << EOF
- Replace \`YOUR_TAILSCALE_AUTH_KEY\` with your actual Tailscale auth key
- Get Tailscale auth keys at: https://login.tailscale.com/admin/machines/new-linux
EOF
    fi

    cat >> "$add_nodes_file" << EOF

## Manual Token Retrieval
If you need to get the token again later:
\`\`\`bash
sudo cat /var/lib/rancher/k3s/server/node-token
\`\`\`

## Cluster Status
Check cluster status from the server node:
\`\`\`bash
kubectl get nodes
kubectl get pods --all-namespaces
\`\`\`

EOF
    
    log "✅ Setup commands saved to $add_nodes_file"
    echo ""
}

# Cleanup functions
cleanup_not_ready_nodes() {
    log_step "Cleaning up not-ready nodes from K3s cluster..."
    
    # Check if we have kubectl access
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. This command must be run from the K3s server node."
        exit $EXIT_MISSING_DEPS
    fi
    
    # Check if we can connect to the cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to K3s cluster. Ensure you're running this on the server node."
        exit $EXIT_MISSING_DEPS
    fi
    
    # Get not-ready nodes
    log_verbose "Checking for not-ready nodes..."
    local not_ready_nodes
    not_ready_nodes=$(kubectl get nodes --no-headers | grep "NotReady" | awk '{print $1}' || echo "")
    
    if [ -z "$not_ready_nodes" ]; then
        log "No not-ready nodes found in the cluster"
        return 0
    fi
    
    log "Found not-ready nodes:"
    echo "$not_ready_nodes" | while read -r node; do
        if [ -n "$node" ]; then
            log "  - $node"
        fi
    done
    
    # Confirm deletion
    echo ""
    read -p "Do you want to remove these nodes from the cluster? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Cleanup cancelled by user"
        return 0
    fi
    
    # Remove each not-ready node
    echo "$not_ready_nodes" | while read -r node; do
        if [ -n "$node" ]; then
            log_verbose "Draining node: $node"
            kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s || {
                log_warn "Failed to drain node $node, continuing with deletion"
            }
            
            log_verbose "Deleting node: $node"
            kubectl delete node "$node" || {
                log_error "Failed to delete node $node"
                continue
            }
            
            log "Removed node: $node"
            
            # Remove from Tailscale if requested
            if [ "$REMOVE_FROM_TAILSCALE" = true ]; then
                remove_from_tailscale "$node"
            fi
        fi
    done
    
    log "Cleanup completed"
}

remove_from_tailscale() {
    local node_name="$1"
    
    if [ -z "$node_name" ]; then
        log_warn "No node name provided for Tailscale removal"
        return 1
    fi
    
    log_verbose "Attempting to remove $node_name from Tailscale..."
    
    # Check if tailscale command is available
    if ! command -v tailscale &> /dev/null; then
        log_warn "Tailscale command not found, skipping Tailscale cleanup for $node_name"
        return 1
    fi
    
    # List Tailscale devices and try to find the node
    local tailscale_status
    tailscale_status=$(sudo tailscale status --json 2>/dev/null || echo "")
    
    if [ -z "$tailscale_status" ]; then
        log_warn "Could not get Tailscale status, skipping removal of $node_name"
        return 1
    fi
    
    # Try to find the device ID for the node (this is a simplified approach)
    # In a real scenario, you might need more sophisticated matching
    log_warn "Automatic Tailscale device removal not implemented yet"
    log_warn "Please manually remove $node_name from your Tailscale admin console:"
    log_warn "https://login.tailscale.com/admin/machines"
    
    return 0
}

# Validation functions
validate_hostname() {
    # In local mode, hostname is prohibited
    if [ "$LOCAL_MODE" = true ] && [ -n "$HOSTNAME" ]; then
        log_error "Hostname argument is not allowed in --local mode"
        return 1
    fi
    
    # In local mode without hostname, this is valid
    if [ "$LOCAL_MODE" = true ] && [ -z "$HOSTNAME" ]; then
        return 0
    fi
    
    if [ -z "$HOSTNAME" ]; then
        log_error "Hostname is required"
        return 1
    fi
    
    # Check for auto-hostname pattern and expand it
    if echo "$HOSTNAME" | grep -q '%d'; then
        log_verbose "Auto-hostname pattern detected, expanding %d with timestamp"
        local timestamp_b64
        timestamp_b64=$(echo "$(date +%s)" | base64 | tr -d '=' | tr '/' '-' | cut -c1-8)
        HOSTNAME=$(echo "$HOSTNAME" | sed "s/%d/$timestamp_b64/g")
        log_verbose "Expanded hostname: $HOSTNAME"
    fi
    
    # Basic hostname validation
    if ! echo "$HOSTNAME" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
        log_error "Invalid hostname format. Use only letters, numbers, and hyphens"
        return 1
    fi
}

validate_k3s_params() {
    # K3S_TOKEN and K3S_URL must be used together
    if [ -n "$K3S_TOKEN" ] && [ -z "$K3S_URL" ]; then
        log_error "K3S_TOKEN requires K3S_URL to be set"
        return 1
    fi
    
    if [ -n "$K3S_URL" ] && [ -z "$K3S_TOKEN" ]; then
        log_error "K3S_URL requires K3S_TOKEN to be set"
        return 1
    fi
    
    # Validate URL format if provided
    if [ -n "$K3S_URL" ]; then
        if ! echo "$K3S_URL" | grep -qE '^https?://'; then
            log_error "K3S_URL must start with http:// or https://"
            return 1
        fi
    fi
}

validate_tailscale_key() {
    # Skip validation if no key provided
    if [ -z "$TAILSCALE_AUTH_KEY" ]; then
        return 0
    fi
    
    log_verbose "Validating Tailscale auth key format..."
    
    # Basic format validation
    if ! echo "$TAILSCALE_AUTH_KEY" | grep -qE '^tskey-auth-'; then
        log_error "Invalid Tailscale auth key format. Tailscale keys must start with 'tskey-auth-'"
        log_error "Get a valid key at: https://login.tailscale.com/admin/settings/keys"
        return 1
    fi
    
    # Check key length (Tailscale auth keys are typically around 48+ characters)
    local key_length=${#TAILSCALE_AUTH_KEY}
    if [ $key_length -lt 20 ]; then
        log_error "Tailscale auth key appears too short (length: $key_length)"
        log_error "Valid auth keys are typically much longer"
        return 1
    fi
    
    # Check for common invalid characters that might indicate copy/paste errors
    if echo "$TAILSCALE_AUTH_KEY" | grep -qE '[[:space:]]'; then
        log_error "Tailscale auth key contains whitespace characters"
        log_error "Please check for copy/paste errors"
        return 1
    fi
    
    log_verbose "✓ Tailscale auth key format appears valid"
    return 0
}

validate_local_params() {
    if [ "$LOCAL_MODE" = true ]; then
        # In local mode, use current hostname
        HOSTNAME=$(hostname)
        log_verbose "Local mode: using current hostname: $HOSTNAME"
        
        # Local mode without K3s parameters requires server setup or agent parameters
        if [ -z "$K3S_TOKEN" ] && [ -z "$K3S_URL" ]; then
            log_verbose "Local mode: will setup K3s server (no agent parameters provided)"
        elif [ -n "$K3S_TOKEN" ] && [ -n "$K3S_URL" ]; then
            log_verbose "Local mode: will setup K3s agent"
        else
            log_error "Local mode: either provide both -k and -u for agent mode, or neither for server mode"
            return 1
        fi
    fi
    
    return 0
}

# Argument parsing
parse_arguments() {
    if [ $# -eq 0 ]; then
        show_help
        exit $EXIT_SUCCESS
    fi
    
    # Check for help/version flags first
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_help
        exit $EXIT_SUCCESS
    fi
    
    if [ "$1" = "--version" ]; then
        show_version
        exit $EXIT_SUCCESS
    fi
    
    # Check if first argument is 'cleanup'
    if [ "$1" = "cleanup" ]; then
        CLEANUP_MODE=true
        shift
        
        # Parse cleanup-specific options
        while [[ $# -gt 0 ]]; do
            case $1 in
                --remove-from-tailscale)
                    REMOVE_FROM_TAILSCALE=true
                    shift
                    ;;
                -v|--verbose)
                    VERBOSE=true
                    shift
                    ;;
                -h|--help)
                    show_help
                    exit $EXIT_SUCCESS
                    ;;
                --version)
                    show_version
                    exit $EXIT_SUCCESS
                    ;;
                *)
                    log_error "Unknown cleanup option: $1"
                    echo ""
                    show_help
                    exit $EXIT_INVALID_ARGS
                    ;;
            esac
        done
        return 0
    fi
    
    # Check if first argument is '--local'
    if [ "$1" = "--local" ]; then
        LOCAL_MODE=true
        shift
        
        # Parse remaining options for local mode
        while [[ $# -gt 0 ]]; do
            case $1 in
                -t|--tailscale-key)
                    TAILSCALE_AUTH_KEY="$2"
                    shift 2
                    ;;
                -k|--k3s-token)
                    K3S_TOKEN="$2"
                    shift 2
                    ;;
                -u|--k3s-url)
                    K3S_URL="$2"
                    shift 2
                    ;;
                -v|--verbose)
                    VERBOSE=true
                    shift
                    ;;
                -h|--help)
                    show_help
                    exit $EXIT_SUCCESS
                    ;;
                --version)
                    show_version
                    exit $EXIT_SUCCESS
                    ;;
                *)
                    log_error "Unknown option for --local mode: $1"
                    echo ""
                    show_help
                    exit $EXIT_INVALID_ARGS
                    ;;
            esac
        done
        return 0
    fi
    
    # Regular hostname-based setup
    HOSTNAME="$1"
    shift
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--tailscale-key)
                TAILSCALE_AUTH_KEY="$2"
                shift 2
                ;;
            -k|--k3s-token)
                K3S_TOKEN="$2"
                shift 2
                ;;
            -u|--k3s-url)
                K3S_URL="$2"
                shift 2
                ;;
            --local)
                LOCAL_MODE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                exit $EXIT_SUCCESS
                ;;
            --version)
                show_version
                exit $EXIT_SUCCESS
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                show_help
                exit $EXIT_INVALID_ARGS
                ;;
        esac
    done
}

# Main function
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Handle cleanup mode
    if [ "$CLEANUP_MODE" = true ]; then
        log "=============================================="
        log "K3s on Phone Cleanup v${VERSION}"
        log "=============================================="
        log "Mode: Cleanup not-ready nodes"
        log "Remove from Tailscale: $REMOVE_FROM_TAILSCALE"
        log "Verbose: $VERBOSE"
        log "=============================================="
        
        if [ "$VERBOSE" = true ]; then
            log_verbose "Verbose mode enabled - showing detailed output"
        fi
        
        echo ""
        
        # Pre-flight checks for cleanup
        check_sudo
        
        # Run cleanup
        cleanup_not_ready_nodes
        
        echo ""
        log "=============================================="
        log "Cleanup completed!"
        log "=============================================="
        echo ""
        return 0
    fi
    
    # Regular setup mode - validate arguments
    log_verbose "Validating configuration parameters..."
    
    validate_hostname || exit $EXIT_INVALID_ARGS
    validate_k3s_params || exit $EXIT_INVALID_ARGS
    validate_local_params || exit $EXIT_INVALID_ARGS
    
    # Validate Tailscale key (requires internet connectivity, so do pre-flight checks first)
    check_sudo
    
    # Tailscale key validation requires network connectivity
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        log_step "Validating Tailscale authentication key..."
        check_internet  # Ensure we have connectivity for validation
        validate_tailscale_key || {
            log_error "Tailscale auth key validation failed"
            echo ""
            echo "Please:"
            echo "1. Verify your auth key at: https://login.tailscale.com/admin/settings/keys"
            echo "2. Generate a new key if the current one is expired or invalid"
            echo "3. Ensure the key is set to 'Reusable' if you plan to use it multiple times"
            echo "4. Run './tailscale-troubleshoot.sh' for additional help"
            echo ""
            exit $EXIT_INVALID_ARGS
        }
    else
        check_internet
    fi
    
    # Show configuration
    log "=============================================="
    log "K3s on Phone Setup v${VERSION}"
    log "=============================================="
    log "Hostname: $HOSTNAME"
    if [ "$LOCAL_MODE" = true ]; then
        log "Mode: Local (minimal setup)"
    fi
    if [ "$LOCAL_MODE" = false ]; then
        log "Tailscale Auth Key: ${TAILSCALE_AUTH_KEY:+***provided***}"
    fi
    if [ -n "$K3S_TOKEN" ] && [ -n "$K3S_URL" ]; then
        log "K3s Mode: Agent (Worker Node)"
        log "K3s Server URL: $K3S_URL"
        log "K3s Token: ***provided***"
    else
        log "K3s Mode: Server (Master Node)"
    fi
    log "Verbose: $VERBOSE"
    log "=============================================="
    
    if [ "$VERBOSE" = true ]; then
        log_verbose "Verbose mode enabled - showing detailed output"
    fi
    
    echo ""
    
    # Main installation steps
    if [ "$LOCAL_MODE" = false ]; then
        set_hostname
        install_docker
        setup_ssh
        setup_tailscale
    else
        log "Local mode: skipping hostname, Docker, SSH, and Tailscale setup"
        # But we still need to check that Tailscale is available
        check_tailscale_local_mode
    fi
    
    # Install K3s (server or agent based on parameters)
    if [ -n "$K3S_TOKEN" ] && [ -n "$K3S_URL" ]; then
        install_k3s_agent
    else
        install_k3s_server
    fi
    
    echo ""
    log "=============================================="
    log "Setup completed successfully!"
    log "=============================================="
    if [ -z "$K3S_TOKEN" ] && [ -z "$K3S_URL" ]; then
        log "📄 Agent setup commands saved to: add_nodes.md"
    fi
    log "You may need to reboot for all changes to take effect."
    log "Docker group membership requires logout/login or reboot to take effect."
    echo ""
}

# Run main function with all arguments
main "$@"
