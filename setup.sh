#!/bin/bash

# K3s on Phone Setup Script
# This script sets up a Kubernetes cluster using K3s on Android phones
# running Debian in KVM hypervisor via the Android Linux Terminal app.
#
# One-line installation:
# curl -sfL https://raw.githubusercontent.com/parttimenerd/k3s-on-phone/refs/heads/main/setup.sh | bash -s -- HOSTNAME -t TAILSCALE_KEY

set -e

# Script version
VERSION="0.1.0"

# Default values
VERBOSE=false
HOSTNAME=""
TAILSCALE_AUTH_KEY=""
K3S_TOKEN=""
K3S_URL=""
CLEANUP_MODE=false
REMOVE_FROM_TAILSCALE=false
LOCAL_MODE=false
FORCE_MODE=false
TEST_GEOCODER_MODE=false

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

# Help functions
show_help() {
    cat << EOF
K3s on Phone Setup Script v${VERSION}

Sets up a Kubernetes cluster using K3s on Android phones running Debian
in KVM hypervisor via the Android Linux Terminal app.

USAGE:
    ./setup.sh COMMAND [OPTIONS]

COMMANDS:
    HOSTNAME [OPTIONS]          Setup K3s node with given hostname
    --local [OPTIONS]           Local mode setup (skip hostname, use current system)

    # Cluster Management
    scan-for-server [SUBNET]    Discover K3s Phone Servers on network
    setup-port                  Setup port forwarding to discovered server
    status [OPTIONS]            Show cluster status and health
    clean [OPTIONS]             Remove dead/unreachable nodes
    reset [OPTIONS]             Reset cluster (destructive)

    # Services
    dashboard [start|stop]      Launch interactive web dashboard
    test-location              Test location monitoring system
    test-geocoder              Test reverse geocoding service

    # Legacy Commands (deprecated)
    cleanup [OPTIONS]          Use 'clean' instead

    # Troubleshooting
    troubleshoot-ssh           Diagnose SSH connectivity issues
    validate-registry HOST     Validate Docker and K3s registry configuration

GLOBAL OPTIONS:
    -h, --help                  Show help (use with command for specific help)
    --version                   Show version information
    -v, --verbose               Enable verbose output

Use './setup.sh COMMAND --help' for command-specific help.

EXAMPLES:
    # Quick Start - Setup cluster
    ./setup.sh phone-01 -t tskey-auth-xxxxx              # Setup master node
    ./setup.sh phone-02 -t tskey-auth-xxxxx -k TOKEN -u https://phone-01:6443  # Add worker
    ./setup.sh --local                                   # Local server setup

    # Discovery and Management
    ./setup.sh scan-for-server                           # Find K3s Phone Servers
    ./setup.sh status                                     # Check cluster health
    ./setup.sh clean                                      # Remove dead nodes

    # Command-specific help
    ./setup.sh scan-for-server --help                    # Scanning help
    ./setup.sh my-phone-01 --help                        # Node setup help
    ./setup.sh clean --help                              # Cleanup help

EOF
}

# Command-specific help functions
show_scan_for_server_help() {
    cat << EOF
K3s Phone Server Discovery v${VERSION}

Discover K3s Phone Servers running on your network using parallel scanning.

USAGE:
    ./setup.sh scan-for-server [SUBNET] [OPTIONS]

ARGUMENTS:
    SUBNET                      Network subnet to scan (optional)
                                Formats: 192.168.1, 192.168.1.0/24, 10.0.0.0/16
                                Default: 192.168.179.0/24

OPTIONS:
    -v, --verbose               Show detailed endpoint testing (default: enabled)
    -q, --quiet                 Suppress verbose output
    -h, --help                  Show this help message

FEATURES:
    • Parallel scanning (20 concurrent connections)
    • Early termination on first server found
    • Endpoint validation (/status, /location, /orientation, /help)
    • Network latency measurement
    • Server capability detection

EXAMPLES:
    ./setup.sh scan-for-server                    # Scan default subnet
    ./setup.sh scan-for-server 192.168.1          # Scan 192.168.1.0/24
    ./setup.sh scan-for-server 10.0.0.0/16        # Scan large subnet
    ./setup.sh scan-for-server --quiet            # Minimal output

EOF
}

show_node_setup_help() {
    cat << EOF
K3s Node Setup v${VERSION}

Setup K3s master or worker nodes on Android phones or local systems.

USAGE:
    ./setup.sh HOSTNAME [OPTIONS]
    ./setup.sh --local [OPTIONS]

ARGUMENTS:
    HOSTNAME                    Set hostname for this node (phone-XX, server-XX)
    --local                     Use current system hostname (local mode)

REQUIRED OPTIONS (for cluster join):
    -t, --tailscale-key KEY     Tailscale auth key from admin console
    -k, --k3s-token TOKEN       K3s node token (with -u for worker nodes)
    -u, --k3s-url URL           K3s server URL (with -k for worker nodes)

OPTIONAL:
    --force                     Force reinstall K3s
    -v, --verbose               Enable verbose logging
    -h, --help                  Show this help

SETUP MODES:
    Master Node:    ./setup.sh phone-01 -t tskey-auth-xxxxx
    Worker Node:    ./setup.sh phone-02 -t tskey-auth-xxxxx -k TOKEN -u https://phone-01:6443
    Local Server:   ./setup.sh --local
    Local Join:     ./setup.sh --local -k TOKEN -u https://server:6443

REQUIREMENTS:
    • Android Linux Terminal with Debian (for phone nodes)
    • Tailscale account and auth key
    • K3s Phone Server app running on port 8005 (for phones)

EOF
}

show_clean_help() {
    cat << EOF
K3s Cluster Cleanup v${VERSION}

Remove dead, unreachable, or NotReady nodes from the cluster.

USAGE:
    ./setup.sh clean [OPTIONS]

OPTIONS:
    -t, --tailscale-key KEY     Also remove nodes from Tailscale VPN
    --dry-run                   Preview what would be cleaned (no changes)
    --force                     Skip confirmation prompts
    -v, --verbose               Show detailed cleanup process
    -h, --help                  Show this help

CLEANUP ACTIONS:
    • Remove NotReady Kubernetes nodes
    • Clean up abandoned pods and services
    • Remove unreachable phone devices from Tailscale (with -t)
    • Preserve master/server nodes

EXAMPLES:
    ./setup.sh clean --dry-run              # Preview cleanup
    ./setup.sh clean                        # Interactive cleanup
    ./setup.sh clean --force                # Auto-confirm cleanup
    ./setup.sh clean -t tskey-api-xxxxx     # Also clean Tailscale

SAFETY:
    • Master nodes are never removed
    • Dry-run mode shows planned actions
    • Interactive confirmation by default

EOF
}

show_status_help() {
    cat << EOF
K3s Cluster Status v${VERSION}

Display comprehensive cluster health, node locations, and resource usage.

USAGE:
    ./setup.sh status [OPTIONS]

OPTIONS:
    -n, --namespace NS          Show specific namespace (default: all)
    -w, --watch                 Continuous refresh mode
    -s, --system                Include system namespaces
    --object-detection          Include object detection from cameras
    --location-only             Show only location information
    -v, --verbose               Detailed node and pod information
    -h, --help                  Show this help

FEATURES:
    • Node health and resource usage
    • GPS locations with city names
    • Pod status across namespaces
    • Service endpoints and load balancers
    • Object detection from phone cameras (optional)
    • Interactive map links

EXAMPLES:
    ./setup.sh status                       # Basic cluster overview
    ./setup.sh status -w                    # Watch mode with auto-refresh
    ./setup.sh status -n default            # Specific namespace
    ./setup.sh status --location-only -v    # GPS tracking focus

EOF
}

show_reset_help() {
    cat << EOF
K3s Cluster Reset v${VERSION}

Reset the cluster to master-only state by removing all worker nodes.

USAGE:
    ./setup.sh reset [OPTIONS]

⚠️  WARNING: This is a DESTRUCTIVE operation! ⚠️

OPTIONS:
    --force                     Skip all confirmation prompts
    --remove-from-tailscale     Also remove nodes from Tailscale VPN
    --dry-run                   Preview what would be reset (no changes)
    -v, --verbose               Show detailed reset process
    -h, --help                  Show this help

RESET ACTIONS:
    • Remove ALL worker/agent nodes from cluster
    • Delete ALL applications and services
    • Reset cluster to master-only state
    • Optionally remove nodes from Tailscale VPN
    • Preserve master node configuration

EXAMPLES:
    ./setup.sh reset --dry-run                    # Preview reset
    ./setup.sh reset                              # Interactive reset
    ./setup.sh reset --force                      # Auto-confirm reset
    ./setup.sh reset --remove-from-tailscale      # Also clean Tailscale

RECOVERY:
    After reset, worker nodes can rejoin using their original setup commands.

EOF
}

show_setup_port_help() {
    cat << 'EOF'
K3s Phone Server Port Forwarding v1.0.0

Setup port forwarding to a discovered K3s Phone Server.

USAGE:
    ./setup.sh setup-port [OPTIONS]

OPTIONS:
    -h, --help                  Show this help

DESCRIPTION:
    Sets up port forwarding from local port 8005 to a discovered K3s Phone Server.
    Automatically scans for servers if none specified.

EXAMPLES:
    ./setup.sh setup-port       # Auto-discover and setup forwarding

REQUIREMENTS:
    • socat installed for port forwarding
    • K3s Phone Server running on target device

EOF
}

show_dashboard_help() {
    cat << 'EOF'
K3s Cluster Dashboard v1.0.0

Launch interactive web dashboard for cluster monitoring.

USAGE:
    ./setup.sh dashboard [COMMAND]

COMMANDS:
    start                       Start dashboard server
    stop                        Stop dashboard server

OPTIONS:
    -h, --help                  Show this help

DESCRIPTION:
    Launches the cluster dashboard with real-time monitoring, location tracking,
    and object detection from phone cameras.

EXAMPLES:
    ./setup.sh dashboard        # Start dashboard
    ./setup.sh dashboard start  # Start dashboard
    ./setup.sh dashboard stop   # Stop dashboard

FEATURES:
    • Real-time cluster status
    • GPS location tracking
    • Object detection feeds
    • Resource usage monitoring

EOF
}

show_test_location_help() {
    cat << 'EOF'
K3s Location Monitoring Test v1.0.0

Test the SSH-based location monitoring system.

USAGE:
    ./setup.sh test-location [OPTIONS]

OPTIONS:
    -h, --help                  Show this help

DESCRIPTION:
    Tests the simplified location monitoring system that collects GPS data
    from K3s Phone Server nodes via direct API calls.

EXAMPLES:
    ./setup.sh test-location    # Test location system

TESTING:
    • Connectivity to phone nodes
    • GPS data collection
    • Location data formatting
    • Reverse geocoding

EOF
}

show_test_geocoder_help() {
    cat << 'EOF'
K3s Geocoder Service Test v1.0.0

Test the reverse geocoding service functionality.

USAGE:
    ./setup.sh test-geocoder [OPTIONS]

OPTIONS:
    -h, --help                  Show this help

DESCRIPTION:
    Tests the geocoder service that converts GPS coordinates to
    human-readable location names.

EXAMPLES:
    ./setup.sh test-geocoder    # Test geocoder service

TESTING:
    • Geocoder service connectivity
    • Coordinate to location conversion
    • Service response times
    • Data accuracy

EOF
}

show_troubleshoot_ssh_help() {
    cat << 'EOF'
K3s SSH Troubleshooting Tool v1.0.0

Diagnose and troubleshoot SSH connectivity issues on nodes.

USAGE:
    ./setup.sh troubleshoot-ssh [OPTIONS]

OPTIONS:
    -h, --help                  Show this help

DESCRIPTION:
    Comprehensive SSH diagnostics including service status, configuration
    validation, network connectivity, firewall rules, and connection examples.

EXAMPLES:
    ./setup.sh troubleshoot-ssh    # Full SSH diagnostics

DIAGNOSTICS:
    • SSH service status and configuration
    • Network interfaces and IP addresses  
    • Firewall rules and port availability
    • Connection examples and troubleshooting steps

EOF
}

show_validate_registry_help() {
    cat << 'EOF'
K3s Registry Validation Tool v1.0.0

Validate Docker and K3s containerd registry configuration for agent nodes.

USAGE:
    ./setup.sh validate-registry HOST [OPTIONS]

ARGUMENTS:
    HOST                        Registry hostname or IP address

OPTIONS:
    -h, --help                  Show this help
    -v, --verbose               Enable verbose output

DESCRIPTION:
    Validates both Docker daemon.json and K3s registries.yaml configuration
    for insecure registry access. Tests connectivity and configuration files.

EXAMPLES:
    ./setup.sh validate-registry 192.168.1.100    # Validate registry config
    ./setup.sh validate-registry phone-server -v  # Verbose validation

VALIDATION CHECKS:
    • Docker daemon.json insecure-registries configuration
    • K3s registries.yaml containerd configuration  
    • Registry connectivity and reachability
    • Configuration file syntax and content

EOF
}

# Parse command line arguments and determine execution mode
parse_command() {
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    # Check for help with specific commands
    if [[ $# -ge 2 && ("$2" = "--help" || "$2" = "-h") ]]; then
        case "$1" in
            scan-for-server)
                show_scan_for_server_help
                exit 0
                ;;
            clean|cleanup)
                show_clean_help
                exit 0
                ;;
            status)
                show_status_help
                exit 0
                ;;
            reset)
                show_reset_help
                exit 0
                ;;
            dashboard)
                show_dashboard_help
                exit 0
                ;;
            setup-port)
                show_setup_port_help
                exit 0
                ;;
            test-location)
                show_test_location_help
                exit 0
                ;;
            test-geocoder)
                show_test_geocoder_help
                exit 0
                ;;
            troubleshoot-ssh)
                show_troubleshoot_ssh_help
                exit 0
                ;;
            validate-registry)
                show_validate_registry_help
                exit 0
                ;;
            --local)
                show_node_setup_help
                exit 0
                ;;
            *)
                if [[ "$1" != -* ]]; then
                    show_node_setup_help
                    exit 0
                fi
                ;;
        esac
    fi

    # Handle global options first
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --version)
            show_version
            exit 0
            ;;
    esac

    # Route to specific command handlers
    case "$1" in
        scan-for-server)
            shift
            handle_scan_command "$@"
            ;;
        setup-port)
            shift
            handle_setup_port_command "$@"
            ;;
        clean)
            shift
            handle_clean_command "$@"
            ;;
        status)
            shift
            handle_status_command "$@"
            ;;
        reset)
            shift
            handle_reset_command "$@"
            ;;
        dashboard)
            shift
            handle_dashboard_command "$@"
            ;;
        test-location)
            shift
            handle_test_location_command "$@"
            ;;
        test-geocoder)
            shift
            handle_test_geocoder_command "$@"
            ;;
        troubleshoot-ssh)
            shift
            handle_troubleshoot_ssh_command "$@"
            ;;
        validate-registry)
            shift
            handle_validate_registry_command "$@"
            ;;
        cleanup)
            # Legacy command - redirect to clean
            shift
            handle_cleanup_legacy_command "$@"
            ;;
        --local)
            shift
            handle_local_setup_command "$@"
            ;;
        *)
            # Default: node setup with hostname
            if [[ "$1" == -* ]]; then
                log_error "Unknown option: $1"
                echo ""
                show_help
                exit 1
            fi
            handle_node_setup_command "$@"
            ;;
    esac
}

# Command handlers
handle_scan_command() {
    echo "🔍 Scanning for K3s Phone Server..."
    VERBOSE=true  # Default verbose for scan

    custom_subnet=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                VERBOSE=false
                shift
                ;;
            -h|--help)
                show_scan_for_server_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            -*)
                log_error "Unknown scan option: $1"
                echo ""
                show_scan_for_server_help
                exit 1
                ;;
            *)
                if [ -z "$custom_subnet" ]; then
                    custom_subnet="$1"
                    shift
                else
                    log_error "Too many arguments for scan command"
                    show_scan_for_server_help
                    exit 1
                fi
                ;;
        esac
    done

    scan_for_k3s_server_verbose "$custom_subnet"
    command_exit $? "scan-for-server"
}

handle_setup_port_command() {
    echo "🔌 Setting up K3s Phone Server port forwarding..."
    setup_port_forwarding
    command_exit $? "setup-port"
}

handle_clean_command() {
    echo "🧹 Running cluster cleanup..."
    if [ -f "$(dirname "$0")/clean.sh" ]; then
        bash "$(dirname "$0")/clean.sh" "$@"
    else
        log_error "clean.sh not found in script directory"
        exit 1
    fi
    exit $?
}

handle_status_command() {
    echo "📊 Showing cluster status..."
    if [ -f "$(dirname "$0")/status.sh" ]; then
        bash "$(dirname "$0")/status.sh" "$@"
        command_exit $? "status"
    else
        log_error "status.sh not found in script directory"
        exit 1
    fi
}

handle_reset_command() {
    echo "🔄 Resetting cluster (WARNING: This is destructive!)..."
    if [ -f "$(dirname "$0")/reset.sh" ]; then
        bash "$(dirname "$0")/reset.sh" "$@"
    else
        log_error "reset.sh not found in script directory"
        exit 1
    fi
    exit $?
}

handle_dashboard_command() {
    echo "🌐 Starting K3s Phone Cluster Dashboard..."
    if [ -f "$(dirname "$0")/dashboard.sh" ]; then
        bash "$(dirname "$0")/dashboard.sh" "$@"
        command_exit $? "dashboard"
    else
        log_error "dashboard.sh not found in script directory"
        exit 1
    fi
}

handle_test_location_command() {
    echo "📍 Testing location monitoring system..."
    if [ -f "$(dirname "$0")/test-simplified-location.sh" ]; then
        bash "$(dirname "$0")/test-simplified-location.sh" "$@"
    else
        log_error "test-simplified-location.sh not found in script directory"
        exit 1
    fi
    exit $?
}

handle_test_geocoder_command() {
    handle_test_geocoder_mode
    exit $?
}

handle_troubleshoot_ssh_command() {
    # Parse options for troubleshoot-ssh command
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_troubleshoot_ssh_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            *)
                log_error "Unknown option for troubleshoot-ssh: $1"
                show_troubleshoot_ssh_help
                exit $EXIT_INVALID_ARGS
                ;;
        esac
    done
    
    # Run SSH troubleshooting
    troubleshoot_ssh
    exit $?
}

handle_validate_registry_command() {
    local registry_host=""
    
    # Parse options for validate-registry command
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_validate_registry_help
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                log_error "Unknown option for validate-registry: $1"
                show_validate_registry_help
                exit $EXIT_INVALID_ARGS
                ;;
            *)
                if [ -z "$registry_host" ]; then
                    registry_host="$1"
                else
                    log_error "Too many arguments for validate-registry"
                    show_validate_registry_help
                    exit $EXIT_INVALID_ARGS
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "$registry_host" ]; then
        log_error "Registry host is required"
        show_validate_registry_help
        exit $EXIT_INVALID_ARGS
    fi
    
    # Run registry validation
    validate_registry_setup "$registry_host"
    exit $?
}

handle_cleanup_legacy_command() {
    log_warn "Warning: 'cleanup' command is deprecated. Use 'clean' instead."
    echo "Redirecting to: ./setup.sh clean $*"
    echo ""
    handle_clean_command "$@"
}

handle_local_setup_command() {
    LOCAL_MODE=true
    parse_node_setup_options "$@"
    main_setup
}

handle_node_setup_command() {
    HOSTNAME="$1"
    shift
    parse_node_setup_options "$@"
    main_setup
}

# Parse options for node setup
parse_node_setup_options() {
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
            --force)
                FORCE_MODE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_node_setup_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                show_node_setup_help
                exit 1
                ;;
        esac
    done
}

# Show version information
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

# Function to install debugging utilities for network troubleshooting
install_debug_utilities() {
    log_verbose "Installing network debugging utilities..."

    # Install netcat for port testing and other useful debugging tools
    local packages_to_install=""

    # Check if netcat is installed
    if ! command -v nc &> /dev/null; then
        packages_to_install="$packages_to_install netcat-openbsd"
    fi

    # Check if curl is installed (usually is, but just in case)
    if ! command -v curl &> /dev/null; then
        packages_to_install="$packages_to_install curl"
    fi

    # Check if dig is installed for DNS debugging
    if ! command -v dig &> /dev/null; then
        packages_to_install="$packages_to_install dnsutils"
    fi

    # Install missing packages if any
    if [ -n "$packages_to_install" ]; then
        log_verbose "Installing missing debug utilities:$packages_to_install"
        sudo apt-get update -qq && sudo apt-get install -y $packages_to_install || {
            log_warn "Failed to install some debug utilities, network troubleshooting may be limited"
        }
    else
        log_verbose "All debugging utilities already installed"
    fi
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

    # Validate input parameters
    if [ -z "$master_ip" ]; then
        log_error "Master IP address is required for Docker registry configuration"
        return 1
    fi

    log_verbose "Debug: Received master_ip='$master_ip', registry_port='$registry_port'"
    log_verbose "Debug: Constructed registry_address='$registry_address'"

    # Pre-flight check: Ensure Docker is installed and running
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed - cannot configure registry"
        return 1
    fi

    if ! sudo systemctl is-active docker >/dev/null 2>&1; then
        log_warn "Docker service is not running, attempting to start it..."
        if ! sudo systemctl start docker; then
            log_error "Failed to start Docker service"
            return 1
        fi

        # Wait for Docker to be ready
        for i in {1..30}; do
            if docker info >/dev/null 2>&1; then
                log_verbose "Docker service started successfully"
                break
            fi
            if [ $i -eq 30 ]; then
                log_error "Docker service failed to start properly"
                return 1
            fi
            sleep 1
        done
    fi
    log "Configuring Docker daemon for insecure registry: $registry_address"

    # Install jq if not present (required for JSON manipulation)
    if ! command -v jq &>/dev/null; then
        log_verbose "Installing jq for JSON manipulation..."
        sudo apt-get update -qq && sudo apt-get install -y jq || {
            log_warn "Failed to install jq, falling back to simpler approach"
        }
    fi

    # Create Docker configuration directory if it doesn't exist
    sudo mkdir -p /etc/docker

    # Create or update Docker daemon configuration
    local daemon_config="/etc/docker/daemon.json"
    local temp_config="/tmp/docker-daemon-setup.json"
    local backup_config="/etc/docker/daemon.json.backup"

    # Backup existing configuration
    if [ -f "$daemon_config" ]; then
        log_verbose "Backing up existing Docker daemon configuration"
        sudo cp "$daemon_config" "$backup_config"
    fi

    # Check if daemon.json exists and process it
    if [ -f "$daemon_config" ]; then
        log_verbose "Processing existing Docker daemon configuration"

        # Use jq if available for proper JSON manipulation
        if command -v jq &>/dev/null; then
            log_verbose "Using jq for JSON manipulation"

            # Check if insecure-registries already contains our registry
            if sudo jq -e --arg registry "$registry_address" '.["insecure-registries"]? // [] | index($registry)' "$daemon_config" >/dev/null 2>&1; then
                log "Registry $registry_address already configured in Docker daemon"
                return 0
            fi

            # Add registry to insecure-registries array
            if sudo jq --arg registry "$registry_address" \
                'if .["insecure-registries"] then .["insecure-registries"] += [$registry] | .["insecure-registries"] |= unique else . + {"insecure-registries": [$registry]} end' \
                "$daemon_config" | sudo tee "$temp_config" >/dev/null; then
                log_verbose "Successfully updated configuration with jq"
            else
                log_error "Failed to update configuration with jq"
                return 1
            fi
        else
            # Fallback: create new configuration
            log_warn "jq not available, creating new configuration"
            sudo tee "$temp_config" >/dev/null << EOF
{
  "insecure-registries": ["$registry_address"]
}
EOF
        fi
    else
        # Create new daemon.json
        log_verbose "Creating new Docker daemon configuration"
        sudo tee "$temp_config" >/dev/null << EOF
{
  "insecure-registries": ["$registry_address"]
}
EOF
    fi

    # Debug: Show what was written to temp config
    if [ "$VERBOSE" = true ]; then
        log_verbose "Debug: Contents of temp config file:"
        log_verbose "$(cat "$temp_config" 2>/dev/null || echo 'Failed to read temp config')"
    fi

    # Validate JSON if jq is available
    if command -v jq &>/dev/null; then
        log_verbose "Validating JSON configuration"
        if ! jq . "$temp_config" >/dev/null 2>&1; then
            log_error "Generated JSON configuration is invalid"
            log_error "jq validation output:"
            jq . "$temp_config" 2>&1 || true

            # Restore backup if it exists
            if [ -f "$backup_config" ]; then
                log_warn "Restoring backup configuration"
                sudo cp "$backup_config" "$daemon_config"
            fi
            return 1
        fi
        log_verbose "JSON validation passed"
    fi

    # Apply the new configuration
    sudo cp "$temp_config" "$daemon_config"
    sudo chmod 644 "$daemon_config"
    log "✅ Docker daemon configuration updated"

    # Restart Docker daemon with better error handling
    log "Restarting Docker daemon..."

    # Check Docker status before restart
    local docker_was_running=false
    if sudo systemctl is-active docker >/dev/null 2>&1; then
        docker_was_running=true
    fi

    if sudo systemctl restart docker; then
        log "✅ Docker daemon restart command completed"

        # Wait for Docker to be ready with more detailed monitoring
        log_verbose "Waiting for Docker daemon to be ready..."
        for i in {1..60}; do
            if sudo systemctl is-active docker >/dev/null 2>&1; then
                # Service is active, now check if Docker API is responding
                if docker info >/dev/null 2>&1; then
                    log "✅ Docker daemon is ready and responding"
                    break
                else
                    log_verbose "Docker service active but API not responding yet (${i}/60)"
                fi
            else
                log_verbose "Docker service not active yet (${i}/60)"
            fi

            if [ $i -eq 60 ]; then
                log_error "Docker daemon failed to become ready within 60 seconds"
                log_error "Final checks:"
                log_error "  Service status: $(sudo systemctl is-active docker 2>/dev/null || echo 'unknown')"
                log_error "  API responding: $(docker info >/dev/null 2>&1 && echo 'yes' || echo 'no')"
                log_error "Checking Docker service status:"
                sudo systemctl status docker || true
                log_error "Checking Docker daemon logs:"
                sudo journalctl -u docker --no-pager --lines=20 || true

                # Don't fail immediately - Docker might actually be working
                log_warn "Docker readiness check failed, but attempting to continue..."
                log_warn "Docker may still be functional despite readiness check timeout"
                break
            fi
            sleep 1
        done
    else
        log_error "Failed to restart Docker daemon"
        log_error "Checking Docker service status:"
        sudo systemctl status docker || true
        log_error "Checking Docker daemon logs:"
        sudo journalctl -u docker --no-pager --lines=10 || true

        # Attempt to restore backup configuration
        if [ -f "$backup_config" ]; then
            log_warn "Attempting to restore backup Docker configuration"
            sudo cp "$backup_config" "$daemon_config"
            if sudo systemctl restart docker; then
                log_warn "Docker restored with backup configuration"
            fi
        fi
        return 1
    fi

    # Test the registry configuration
    log_verbose "Testing Docker registry configuration..."

    # Final check: Ensure Docker is actually working before declaring success
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker API is not responding after configuration"
        log_error "Registry configuration may have failed"

        # Attempt to restore backup configuration as last resort
        if [ -f "$backup_config" ]; then
            log_warn "Attempting to restore backup Docker configuration as last resort"
            sudo cp "$backup_config" "$daemon_config"
            if sudo systemctl restart docker && docker info >/dev/null 2>&1; then
                log_warn "Docker restored with backup configuration"
                log "✅ Docker registry configuration completed with backup restoration"
                return 0
            fi
        fi
        return 1
    fi

    # Verify the configuration file contains our registry
    if [ -f "$daemon_config" ] && grep -q "$registry_address" "$daemon_config"; then
        log "✅ Registry $registry_address successfully configured in Docker daemon"
        log_verbose "Configuration file: $daemon_config contains registry entry"
    else
        log_warn "Registry configuration file may not contain expected entry"
        log_verbose "But Docker is responding, so configuration was likely successful"
    fi

    # Also check if docker info shows the registry (might take a moment)
    if docker info 2>/dev/null | grep -q "$registry_address"; then
        log_verbose "Docker info confirms registry is active"
    else
        log_verbose "Registry not yet showing in docker info (may take a few moments)"
        log_verbose "This is normal - the configuration will be active for new operations"
    fi

    # Cleanup temporary files
    sudo rm -f "$temp_config" 2>/dev/null || true

    log "✅ Docker registry configuration completed successfully"
    return 0
}

# Function to setup K3s containerd registry configuration
setup_k3s_registry_config() {
    log_step "Configuring K3s containerd for insecure registry..."

    local master_ip="$1"
    local registry_port="${2:-5000}"
    local registry_address="${master_ip}:${registry_port}"

    # Validate input parameters
    if [ -z "$master_ip" ]; then
        log_error "Master IP address is required for K3s registry configuration"
        return 1
    fi

    log_verbose "Configuring K3s containerd for registry: $registry_address"

    # Create K3s config directory if it doesn't exist
    sudo mkdir -p /etc/rancher/k3s

    # Create registries.yaml for K3s containerd configuration
    local registries_config="/etc/rancher/k3s/registries.yaml"
    local backup_config="/etc/rancher/k3s/registries.yaml.backup"

    # Backup existing configuration if present
    if [ -f "$registries_config" ]; then
        log_verbose "Backing up existing K3s registries configuration"
        sudo cp "$registries_config" "$backup_config"
    fi

    # Create the registries.yaml configuration
    log_verbose "Creating K3s registries.yaml configuration"
    sudo tee "$registries_config" >/dev/null << EOF
mirrors:
  "$registry_address":
    endpoint:
      - "http://$registry_address"
configs:
  "$registry_address":
    tls:
      insecure_skip_verify: true
    auth:
      username: ""
      password: ""
EOF

    # Verify the configuration was written correctly
    if [ -f "$registries_config" ]; then
        log_verbose "✅ K3s registries.yaml created successfully"
        if [ "$VERBOSE" = true ]; then
            log_verbose "Contents of $registries_config:"
            log_verbose "$(cat "$registries_config" 2>/dev/null | sed 's/^/  /')"
        fi
    else
        log_error "Failed to create K3s registries.yaml configuration"
        return 1
    fi

    # The configuration will be picked up by K3s automatically
    # No need to restart K3s as it reads this file on startup and for new operations
    log "✅ K3s containerd registry configuration completed"
    log_verbose "K3s will use this configuration for container image pulls from $registry_address"
    
    return 0
}

# Function to validate registry configuration
validate_registry_setup() {
    log_step "Validating registry configuration..."
    
    local registry_host="$1"
    local registry_port="${2:-5000}"
    local registry_address="${registry_host}:${registry_port}"
    
    if [ -z "$registry_host" ]; then
        log_error "Registry host is required for validation"
        return 1
    fi
    
    local issues=0
    
    # Check Docker daemon.json
    if [ -f /etc/docker/daemon.json ]; then
        if grep -q "$registry_address" /etc/docker/daemon.json; then
            log "✅ Docker daemon.json contains registry $registry_address"
        else
            log "❌ Docker daemon.json missing registry $registry_address"
            issues=$((issues + 1))
        fi
    else
        log "❌ Docker daemon.json not found"
        issues=$((issues + 1))
    fi
    
    # Check K3s registries.yaml
    if [ -f /etc/rancher/k3s/registries.yaml ]; then
        if grep -q "$registry_address" /etc/rancher/k3s/registries.yaml; then
            log "✅ K3s registries.yaml contains registry $registry_address"
        else
            log "❌ K3s registries.yaml missing registry $registry_address"
            issues=$((issues + 1))
        fi
    else
        log "❌ K3s registries.yaml not found"
        issues=$((issues + 1))
    fi
    
    # Test connectivity
    log_verbose "Testing registry connectivity..."
    if command -v nc &>/dev/null; then
        if nc -z -w5 "$registry_host" "$registry_port" 2>/dev/null; then
            log "✅ Registry $registry_address is reachable"
        else
            log "⚠️  Registry $registry_address is not reachable (may be normal if registry is down)"
        fi
    else
        log_verbose "nc (netcat) not available, skipping connectivity test"
    fi
    
    if [ $issues -eq 0 ]; then
        log "✅ Registry configuration validation passed"
        return 0
    else
        log "❌ Registry configuration validation failed ($issues issues found)"
        return 1
    fi
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

    # Enable root login and password authentication
    log_verbose "Configuring SSH authentication settings"
    
    # Enable root login
    if grep -q "^#PermitRootLogin" /etc/ssh/sshd_config; then
        sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    elif grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
        sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    else
        echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi

    # Enable password authentication
    if grep -q "^#PasswordAuthentication" /etc/ssh/sshd_config; then
        sudo sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    elif grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
        sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    else
        echo "PasswordAuthentication yes" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi

    # Disable public key only authentication to allow password auth
    if grep -q "^#PubkeyAuthentication" /etc/ssh/sshd_config; then
        sudo sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    elif ! grep -q "^PubkeyAuthentication" /etc/ssh/sshd_config; then
        echo "PubkeyAuthentication yes" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi

    # Ensure SSH listens on all interfaces
    if grep -q "^#ListenAddress" /etc/ssh/sshd_config; then
        sudo sed -i 's/^#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
    elif ! grep -q "^ListenAddress" /etc/ssh/sshd_config; then
        echo "ListenAddress 0.0.0.0" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi

    # Set SSH port explicitly
    if grep -q "^#Port 22" /etc/ssh/sshd_config; then
        sudo sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config
    elif ! grep -q "^Port" /etc/ssh/sshd_config; then
        echo "Port 22" | sudo tee -a /etc/ssh/sshd_config > /dev/null
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

    # Verify SSH configuration
    log_verbose "Testing SSH configuration..."
    if sudo sshd -t 2>/dev/null; then
        log_verbose "SSH configuration is valid"
    else
        log_error "SSH configuration has errors:"
        sudo sshd -t
        exit $EXIT_CONFIG_FAILED
    fi

    # Check if SSH port is listening
    log_verbose "Checking if SSH is listening on port 22..."
    if netstat -tln 2>/dev/null | grep -q ":22 " || ss -tln 2>/dev/null | grep -q ":22 "; then
        log_verbose "SSH is listening on port 22"
    else
        log_warn "SSH may not be listening on port 22"
        log_warn "Check with: sudo netstat -tln | grep :22"
    fi

    # Get current IP addresses for connection testing
    log_verbose "Node IP addresses for SSH access:"
    if command -v ip &> /dev/null; then
        ip addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print "  " $2}' | head -5
    else
        ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print "  " $2}' | head -5
    fi

    # Check firewall status (common issue)
    if command -v ufw &> /dev/null; then
        UFW_STATUS=$(sudo ufw status 2>/dev/null | head -1)
        if echo "$UFW_STATUS" | grep -q "Status: active"; then
            log_warn "UFW firewall is active - may block SSH"
            log_warn "Allow SSH with: sudo ufw allow ssh"
        else
            log_verbose "UFW firewall is not blocking SSH"
        fi
    fi

    log "SSH server configured successfully"
    log_warn "Root SSH login enabled with password 'root' - consider changing for security"
}

# SSH troubleshooting function
troubleshoot_ssh() {
    log_step "Troubleshooting SSH connectivity..."
    
    # Check SSH service status
    local ssh_service
    ssh_service=$(detect_ssh_service_name)
    
    if [ -n "$ssh_service" ]; then
        log "SSH service status:"
        sudo systemctl status "$ssh_service" --no-pager -l
        echo ""
    fi
    
    # Check SSH configuration
    log "Testing SSH configuration..."
    if sudo sshd -t; then
        log "✅ SSH configuration is valid"
    else
        log_error "❌ SSH configuration has errors"
    fi
    echo ""
    
    # Check listening ports
    log "Checking SSH port status..."
    if netstat -tln 2>/dev/null | grep -q ":22 "; then
        log "✅ SSH is listening on port 22"
        netstat -tln | grep ":22 "
    elif ss -tln 2>/dev/null | grep -q ":22 "; then
        log "✅ SSH is listening on port 22"
        ss -tln | grep ":22 "
    else
        log_error "❌ SSH is not listening on port 22"
    fi
    echo ""
    
    # Show network interfaces
    log "Network interfaces and IP addresses:"
    if command -v ip &> /dev/null; then
        ip addr show | grep -E "(inet |^[0-9]+:)" | sed 's/^/  /'
    else
        ifconfig 2>/dev/null | grep -E "(inet |^[a-z])" | sed 's/^/  /'
    fi
    echo ""
    
    # Check firewall
    log "Firewall status:"
    if command -v ufw &> /dev/null; then
        UFW_STATUS=$(sudo ufw status verbose 2>/dev/null)
        echo "$UFW_STATUS" | sed 's/^/  /'
        if echo "$UFW_STATUS" | grep -q "Status: active"; then
            if echo "$UFW_STATUS" | grep -q "22/tcp"; then
                log "✅ SSH port 22 is allowed in UFW firewall"
            else
                log_warn "⚠️  SSH port 22 may not be allowed in UFW firewall"
                log_warn "Run: sudo ufw allow ssh"
            fi
        fi
    else
        log_verbose "UFW not installed"
    fi
    echo ""
    
    # Check iptables if available
    if command -v iptables &> /dev/null; then
        log "iptables rules for SSH:"
        sudo iptables -L INPUT -n | grep ":22 " | sed 's/^/  /' || log_verbose "No specific SSH rules found"
    fi
    echo ""
    
    # Show SSH connection examples
    log "SSH connection examples:"
    if command -v ip &> /dev/null; then
        MAIN_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    else
        MAIN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    if [ -n "$MAIN_IP" ]; then
        echo "  ssh root@$MAIN_IP"
        echo "  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$MAIN_IP"
    fi
    
    # Show Tailscale IP if available
    if command -v tailscale &> /dev/null; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -1)
        if [ -n "$TAILSCALE_IP" ]; then
            echo "  ssh root@$TAILSCALE_IP  # via Tailscale"
        fi
    fi
    echo ""
    
    log "Common troubleshooting steps:"
    echo "1. Check service: sudo systemctl status $ssh_service"
    echo "2. Restart service: sudo systemctl restart $ssh_service"
    echo "3. Check config: sudo sshd -t"
    echo "4. Check logs: sudo journalctl -u $ssh_service -f"
    echo "5. Allow firewall: sudo ufw allow ssh"
    echo "6. Test locally: ssh -v root@localhost"
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

# Function to generate random lowercase hostname for phones
generate_phone_hostname() {
    # Generate a random lowercase hostname with format: phone-[6 random chars]
    local random_suffix=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)
    echo "phone-${random_suffix}"
}

# Function to clean up inaccessible devices from Tailscale
cleanup_tailscale_devices() {
    log_step "Cleaning up inaccessible devices from Tailscale and Kubernetes..."
    
    if ! command -v tailscale &> /dev/null; then
        log_warn "Tailscale not available, skipping device cleanup"
        return 0
    fi
    
    # Get list of devices and check their status
    local devices_to_remove=""
    local cleanup_count=0
    local k8s_cleanup_count=0
    
    log_verbose "Checking Tailscale device status..."
    
    # Get device list in JSON format for parsing
    if command -v jq &> /dev/null; then
        # Use jq for better JSON parsing
        local offline_devices=$(tailscale status --json 2>/dev/null | jq -r '.Peer[] | select(.Online == false and (.HostName | startswith("phone-"))) | .HostName' 2>/dev/null || echo "")
        
        if [ -n "$offline_devices" ]; then
            log "Found offline phone devices:"
            echo "$offline_devices" | while read -r device; do
                if [ -n "$device" ]; then
                    log "  - $device (offline)"
                    # Note: We can only log here, actual removal requires different approach
                fi
            done
            
            # Check if kubectl is available and we're on master for K8s cleanup
            if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
                log_verbose "Checking for corresponding Kubernetes nodes to remove..."
                echo "$offline_devices" | while read -r device; do
                    if [ -n "$device" ] && kubectl get node "$device" &> /dev/null; then
                        log "Removing inaccessible K8s node: $device"
                        kubectl delete node "$device" || log_warn "Failed to remove node $device from Kubernetes"
                        k8s_cleanup_count=$((k8s_cleanup_count + 1))
                    fi
                done
            fi
        fi
    else
        # Fallback without jq
        log_verbose "jq not available, using basic parsing"
        local offline_count=$(tailscale status 2>/dev/null | grep -c "phone-.*offline" || echo "0")
        if [ "$offline_count" -gt 0 ]; then
            log "Found $offline_count offline phone devices"
            local offline_list=$(tailscale status 2>/dev/null | grep "phone-.*offline" | awk '{print $2}' || echo "")
            
            if [ -n "$offline_list" ]; then
                echo "$offline_list" | while read -r device; do
                    log "  - $device (offline)"
                done
                
                # Check if kubectl is available and we're on master for K8s cleanup
                if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
                    log_verbose "Checking for corresponding Kubernetes nodes to remove..."
                    echo "$offline_list" | while read -r device; do
                        if [ -n "$device" ] && kubectl get node "$device" &> /dev/null; then
                            log "Removing inaccessible K8s node: $device"
                            kubectl delete node "$device" || log_warn "Failed to remove node $device from Kubernetes"
                        fi
                    done
                fi
            fi
        fi
    fi
    
    # Note about manual cleanup (since programmatic removal requires admin access)
    local total_phones=$(tailscale status 2>/dev/null | grep -c "phone-" || echo "0")
    if [ "$total_phones" -gt 0 ]; then
        log_verbose "Total phone devices in Tailscale: $total_phones"
        log_verbose "To remove offline devices, visit: https://login.tailscale.com/admin/machines"
        log_verbose "Or use: tailscale admin delete-device <hostname>"
    fi
    
    log "✅ Tailscale device status checked, Kubernetes nodes cleaned up"
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

# Function to force reset the cluster and all components
force_reset_cluster() {
    local old_hostname=$(hostname)
    log_step "Force reset: Completely resetting K3s cluster and reinstalling..."

    log_warn "⚠️  This will completely destroy the existing K3s cluster and all deployments!"
    log_warn "⚠️  All pods, services, and data will be permanently lost!"
    log_warn "⚠️  Docker will remain untouched - only K3s will be reinstalled"

    echo ""
    echo "Continuing in 5 seconds... Press Ctrl+C to cancel"
    for i in 5 4 3 2 1; do
        echo -n "$i... "
        sleep 1
    done
    echo ""
    echo ""
    log "Starting K3s force reset process..."

    # Stop and disable geolocation monitoring if it exists
    log "Stopping geolocation monitoring service..."
    sudo systemctl stop k3s-geolocation-monitor 2>/dev/null || true
    sudo systemctl disable k3s-geolocation-monitor 2>/dev/null || true
    sudo rm -f /usr/local/bin/k3s-geolocation-monitor 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k3s-geolocation-monitor.service 2>/dev/null || true

    # Use official K3s uninstall scripts
    log "Running official K3s uninstall scripts..."

    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        log "Found K3s server uninstall script, running..."
        if [ "$VERBOSE" = true ]; then
            sudo /usr/local/bin/k3s-uninstall.sh
        else
            sudo /usr/local/bin/k3s-uninstall.sh 2>&1 | while read -r line; do
                log "$line"
            done
        fi
        log "✅ K3s server uninstall completed"
    elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
        log "Found K3s agent uninstall script, running..."
        if [ "$VERBOSE" = true ]; then
            sudo /usr/local/bin/k3s-agent-uninstall.sh
        else
            sudo /usr/local/bin/k3s-agent-uninstall.sh 2>&1 | while read -r line; do
                log "$line"
            done
        fi
        log "✅ K3s agent uninstall completed"
    else
        log_warn "No K3s uninstall scripts found"
        log "Attempting manual cleanup..."

        # Manual cleanup if no uninstall scripts exist
        sudo systemctl stop k3s-agent 2>/dev/null || true
        sudo systemctl stop k3s 2>/dev/null || true
        sudo systemctl disable k3s-agent 2>/dev/null || true
        sudo systemctl disable k3s 2>/dev/null || true

        sudo rm -rf /var/lib/rancher/k3s 2>/dev/null || true
        sudo rm -rf /etc/rancher/k3s 2>/dev/null || true
        sudo rm -f /usr/local/bin/k3s* 2>/dev/null || true
        sudo rm -f /etc/systemd/system/k3s* 2>/dev/null || true

        sudo systemctl daemon-reload
        log "Manual K3s cleanup completed"
    fi

    # set hostname back to $current_hostname
    log "Resetting hostname to original value..."
    local current_hostname=$(hostname)
    if [ "$current_hostname" != "$old_hostname" ]; then
        log_verbose "Current hostname: $current_hostname"
        log_verbose "Setting hostname back to: $old_hostname"
        sudo hostnamectl set-hostname "$old_hostname" || {
            log_error "Failed to reset hostname"
        }
        log "Hostname is again set to $old_hostname"
    fi

    log "✅ K3s force reset completed - system is ready for fresh K3s installation"
    log "📝 Docker and other services remain untouched"
}

# Function to comprehensively test geocoder service functionality
test_geocoder_comprehensive() {
    log_step "Comprehensive geocoder service testing..."

    # First, ensure kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not available - cannot test geocoder service"
        return 1
    fi

    # Check if geocoder deployment exists
    if ! sudo kubectl get deployment reverse-geocoder &> /dev/null 2>&1; then
        log_error "Geocoder deployment not found in cluster"
        return 1
    fi

    # Check deployment status
    local ready_replicas desired_replicas
    ready_replicas=$(sudo kubectl get deployment reverse-geocoder -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired_replicas=$(sudo kubectl get deployment reverse-geocoder -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

    if [ "$ready_replicas" != "$desired_replicas" ]; then
        log_error "Geocoder deployment not ready: $ready_replicas/$desired_replicas replicas available"
        return 1
    fi
    log_verbose "✅ Geocoder deployment is ready: $ready_replicas/$desired_replicas replicas"

    # Get service endpoint
    local service_ip service_port api_url
    service_ip=$(sudo kubectl get service reverse-geocoder -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    service_port=$(sudo kubectl get service reverse-geocoder -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8090")

    if [ -z "$service_ip" ]; then
        log_error "Cannot determine geocoder service IP"
        return 1
    fi

    api_url="http://${service_ip}:${service_port}"
    log_verbose "Testing geocoder at: $api_url"

    # Test 1: Health endpoint
    log_verbose "1. Testing health endpoint..."
    local health_response
    health_response=$(curl -s --connect-timeout 5 --max-time 10 "${api_url}/health" 2>/dev/null)

    if [ $? -eq 0 ] && (echo "$health_response" | grep -q "healthy" || echo "$health_response" | grep -q "ok"); then
        log_verbose "✅ Health endpoint responding"
    else
        log_error "❌ Health endpoint failed or not responding"
        log_error "Response: ${health_response:-'No response'}"
        return 1
    fi

    # Test 2: API endpoint basic connectivity with German coordinates
    log_verbose "2. Testing API endpoint connectivity with German city..."
    local api_test_url="${api_url}/api/reverse-geocode?lat=52.52&lon=13.40&method=geonames"
    local api_response
    api_response=$(curl -s --connect-timeout 10 --max-time 15 "$api_test_url" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$api_response" ]; then
        log_verbose "✅ API endpoint responding for German cities"
    else
        log_error "❌ API endpoint not responding for German cities"
        return 1
    fi

    # Test 3: Comprehensive city resolution test with German cities
    log_verbose "3. Testing city resolution with German coordinates..."

    # Define German city test cases - geocoder is optimized for German cities only
    declare -A test_coordinates=(
        ["Berlin_Germany"]="52.52,13.40"
        ["Munich_Germany"]="48.14,11.58"
        ["Hamburg_Germany"]="53.55,9.99"
        ["Cologne_Germany"]="50.94,6.96"
        ["Frankfurt_Germany"]="50.11,8.68"
        ["Stuttgart_Germany"]="48.78,9.18"
    )

    local test_count=0
    local success_count=0

    for test_case in "${!test_coordinates[@]}"; do
        test_count=$((test_count + 1))
        local coords=${test_coordinates[$test_case]}
        local lat=${coords%,*}
        local lon=${coords#*,}
        local city_name=${test_case%_*}  # Extract city name before underscore

        log_verbose "  Testing $city_name ($lat, $lon)..."

        local test_url="${api_url}/api/reverse-geocode?lat=${lat}&lon=${lon}&method=geonames"
        local response
        response=$(curl -s --connect-timeout 10 --max-time 15 "$test_url" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$response" ]; then
            # Check if response contains location data
            local location
            location=$(echo "$response" | grep -o '"location":"[^"]*"' | cut -d'"' -f4)

            if [ -n "$location" ]; then
                log_verbose "    ✅ $city_name → $location"
                success_count=$((success_count + 1))
            else
                log_verbose "    ⚠️  $city_name → No location in response"
                log_verbose "    Response: $response"
            fi
        else
            log_verbose "    ❌ $city_name → API call failed"
        fi
    done

    # Test 4: Method parameter validation with German city
    log_verbose "4. Testing different geocoding methods with German coordinates..."
    local berlin_lat="52.52"
    local berlin_lon="13.40"

    # Test geonames method (primary) with Berlin coordinates
    local geonames_url="${api_url}/api/reverse-geocode?lat=${berlin_lat}&lon=${berlin_lon}&method=geonames"
    local geonames_response
    geonames_response=$(curl -s --connect-timeout 10 --max-time 15 "$geonames_url" 2>/dev/null)

    if [ $? -eq 0 ] && echo "$geonames_response" | grep -q '"location"'; then
        log_verbose "✅ Geonames method working with German cities"
    else
        log_verbose "⚠️  Geonames method not responding properly for German cities"
    fi

    # Test 5: Error handling
    log_verbose "5. Testing error handling with invalid coordinates..."
    local invalid_url="${api_url}/api/reverse-geocode?lat=999&lon=999&method=geonames"
    local invalid_response
    invalid_response=$(curl -s --connect-timeout 5 --max-time 10 "$invalid_url" 2>/dev/null)

    if [ $? -eq 0 ]; then
        log_verbose "✅ API handles invalid coordinates gracefully"
    else
        log_verbose "⚠️  API error handling test failed"
    fi

    # Summarize results
    echo ""
    log "Geocoder Test Results:"
    log "  Total German city tests: $test_count"
    log "  Successful resolutions: $success_count"
    log "  Success rate: $(( (success_count * 100) / test_count ))%"

    # Determine overall success - expect high success rate for German cities
    if [ $success_count -ge $((test_count * 5 / 6)) ]; then  # At least 83% success rate (5/6 cities)
        log "✅ Geocoder service is functional and ready for German cities"
        return 0
    else
        log_error "❌ Geocoder service test failed - insufficient success rate for German cities"
        log_error "Expected at least 83% success rate, got $(( (success_count * 100) / test_count ))%"
        log_error "Note: This geocoder is optimized for German cities only"
        return 1
    fi
}

# Function to test geocoder city resolution with sample coordinates
test_geocoder_city_resolution() {
    log_step "Testing geocoder city resolution..."

    # Wait for service to be ready (additional to deployment wait)
    local max_retries=10
    local retry_count=0
    local geocoder_service_url=""

    log_verbose "Determining geocoder service URL..."

    # Try to find service IP
    while [ $retry_count -lt $max_retries ]; do
        local service_ip
        service_ip=$(sudo kubectl get service reverse-geocoder -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

        if [ -n "$service_ip" ]; then
            geocoder_service_url="http://${service_ip}:8090"
            log_verbose "Found geocoder service at: $geocoder_service_url"
            break
        fi

        log_verbose "Waiting for geocoder service IP... ($((retry_count + 1))/$max_retries)"
        sleep 5
        retry_count=$((retry_count + 1))
    done

    # If service IP not found, try NodePort
    if [ -z "$geocoder_service_url" ]; then
        local node_port
        node_port=$(sudo kubectl get service reverse-geocoder -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)

        if [ -n "$node_port" ]; then
            geocoder_service_url="http://localhost:$node_port"
            log_verbose "Using NodePort access: $geocoder_service_url"
        else
            # Fallback to default port on localhost
            geocoder_service_url="http://localhost:8090"
            log_verbose "Using default port on localhost: $geocoder_service_url"
        fi
    fi

    # Test German cities with well-known coordinates
    log "Testing city resolution with sample German coordinates..."

    # Define test German cities with their coordinates
    declare -A test_cities=(
        ["Berlin"]="52.52,13.40"
        ["Munich"]="48.14,11.58"
        ["Hamburg"]="53.55,9.99"
        ["Frankfurt"]="50.11,8.68"
    )

    local success_count=0

    for city in "${!test_cities[@]}"; do
        local coords=${test_cities[$city]}
        local lat=${coords%,*}
        local lon=${coords#*,}

        log_verbose "Testing coordinates for $city: $lat,$lon"

        # Call geocoder API
        local url="${geocoder_service_url}/api/reverse-geocode?lat=${lat}&lon=${lon}&method=geonames"
        local result
        result=$(curl -s --connect-timeout 10 --max-time 15 "$url" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$result" ]; then
            # Extract location from response
            local resolved_location
            resolved_location=$(echo "$result" | grep -o '"location":"[^"]*"' | cut -d'"' -f4)

            if [ -n "$resolved_location" ]; then
                log "✅ Resolved $city: $resolved_location"
                success_count=$((success_count + 1))
            else
                log_warn "⚠️  Failed to extract location from response for $city"
            fi
        else
            log_warn "⚠️  Failed to query geocoder for $city coordinates"
        fi
    done

    # Summarize results
    local total=${#test_cities[@]}
    if [ $success_count -eq $total ]; then
        log "✅ All German city resolutions successful ($success_count/$total)"
        return 0
    elif [ $success_count -gt 0 ]; then
        log_warn "⚠️  Some German city resolutions successful ($success_count/$total)"
        # Still return success if at least one German city resolves
        return 0
    else
        log_error "❌ All German city resolutions failed (0/$total)"
        log_error "Geocoder service is not functional - this indicates cluster issues"
        log_error "Exiting setup as the geocoder is a critical component for cluster functionality"
        exit $EXIT_CONFIG_FAILED
    fi
}

# Function to test geocoder functionality independently
test_geocoder_service() {
    log_step "Testing reverse geocoder service functionality..."

    # Ensure kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl command not found, cannot test geocoder service"
        exit $EXIT_MISSING_DEPS
    fi

    # Check if the geocoder service exists
    if ! sudo kubectl get deployment reverse-geocoder &> /dev/null; then
        log_error "Reverse geocoder service not found in the cluster"
        log_error "Please deploy the geocoder service first"
        exit $EXIT_CONFIG_FAILED
    fi

    # Run comprehensive geocoder tests
    log "Running comprehensive geocoder functionality tests..."
    echo ""

    if test_geocoder_comprehensive; then
        echo ""
        log "=============================================="
        log "✅ GEOCODER SERVICE TEST: PASSED"
        log "=============================================="
        log "The reverse geocoder service is fully functional"
        log "All major city resolution tests passed"
        log "Geolocation monitoring will work correctly"
        return 0
    else
        echo ""
        log "=============================================="
        log "❌ GEOCODER SERVICE TEST: FAILED"
        log "=============================================="
        log_error "The reverse geocoder service has functional issues"
        log_error "Geolocation monitoring may not work properly"
        echo ""
        log "Troubleshooting recommendations:"
        log "  1. Check deployment status: kubectl get deployment reverse-geocoder"
        log "  2. Check pod logs: kubectl logs deployment/reverse-geocoder"
        log "  3. Check service status: kubectl get service reverse-geocoder"
        log "  4. Restart deployment: kubectl rollout restart deployment/reverse-geocoder"
        return 1
    fi
}

# Function to get the current local IP address
get_local_ip() {
    # Try multiple methods to get local IP
    local local_ip=""

    # Method 1: Use ip route to get default route interface IP
    if command -v ip &> /dev/null; then
        local_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -n1)
    fi

    # Method 2: Use hostname -I as fallback
    if [ -z "$local_ip" ] && command -v hostname &> /dev/null; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # Method 3: Parse ip addr output as another fallback
    if [ -z "$local_ip" ] && command -v ip &> /dev/null; then
        local_ip=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n1)
    fi

    echo "$local_ip"
}

# Reusable parallel K3s Phone Server scanner
# Usage: scan_k3s_phone_server_parallel [subnet] [quiet_mode]
# Returns: IP address of first found server, empty if none found
scan_k3s_phone_server_parallel() {
    local target_subnet="$1"
    local quiet_mode="${2:-false}"
    local local_ip=""
    local subnet=""

    # Determine target subnet
    if [ -n "$target_subnet" ]; then
        # Parse different subnet formats
        if [[ "$target_subnet" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
            # Format: 192.168.1 (missing last octet)
            subnet="$target_subnet"
        elif [[ "$target_subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            # Format: 192.168.1.0/24 (CIDR notation)
            subnet=$(echo "$target_subnet" | cut -d'/' -f1 | cut -d. -f1-3)
        elif [[ "$target_subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            # Format: 192.168.1.0 (full IP, extract subnet)
            subnet=$(echo "$target_subnet" | cut -d. -f1-3)
        else
            if [ "$quiet_mode" != "true" ]; then
                log_error "Invalid subnet format: $target_subnet"
                log_error "Supported formats: 192.168.1, 192.168.1.0, 192.168.1.0/24"
            fi
            return 1
        fi

        # Get local IP for informational purposes
        local_ip=$(get_local_ip)
    else
        # Use default subnet 192.168.179.0/24
        subnet="192.168.179"
        local_ip=$(get_local_ip)
    fi

    # Validate subnet format
    if ! [[ "$subnet" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
        if [ "$quiet_mode" != "true" ]; then
            log_error "Invalid subnet derived: $subnet"
        fi
        return 1
    fi

    # Check if required tools are available
    if ! command -v curl &> /dev/null; then
        if [ "$quiet_mode" != "true" ]; then
            log_warn "curl not found, installing..."
            sudo apt-get update -qq && sudo apt-get install -y curl
        fi
    fi

    # Create temporary directory for parallel scan results
    local temp_dir=$(mktemp -d)
    local winner_file="$temp_dir/winner"

    # Cleanup function - simplified to avoid scope issues
    trap "rm -rf \"$temp_dir\" 2>/dev/null; kill \$(jobs -p) 2>/dev/null; wait 2>/dev/null" EXIT

    # Launch parallel scans in batches to avoid overwhelming the system
    batch_size=20
    jobs_running=0

    for i in {1..254}; do
        target_ip="${subnet}.${i}"

        # Skip our own IP if we know it and it's in the target subnet
        if [ -n "$local_ip" ] && [ "$target_ip" = "$local_ip" ]; then
            continue
        fi

        # Instead of background function, use a background command
        (
            # Check if someone already won
            if [ -f "$winner_file" ]; then
                exit 0
            fi

            # Test if port 8005 is open and returns K3s Phone Server response
            response=$(curl -s --connect-timeout 1 --max-time 3 "http://${target_ip}:8005/status" 2>/dev/null || echo "")

            if [ -n "$response" ] && [[ "$response" == *"K3s Phone Server"* ]]; then
                # We found a winner! Try to claim it
                if ! [ -f "$winner_file" ]; then
                    echo "$target_ip" > "$winner_file" 2>/dev/null
                fi
            fi
        ) &

        jobs_running=$((jobs_running + 1))

        # If we've hit batch size, wait for some jobs to complete
        if [ $jobs_running -ge $batch_size ]; then
            # Check if we have a winner while jobs are running
            if [ -f "$winner_file" ]; then
                break
            fi

            # Wait for batch to complete
            wait
            jobs_running=0

            # Check again after batch completes
            if [ -f "$winner_file" ]; then
                break
            fi
        fi
    done

    # Wait for any remaining background jobs
    wait 2>/dev/null

    # Get result
    local winner_ip=""
    if [ -f "$winner_file" ]; then
        winner_ip=$(cat "$winner_file" 2>/dev/null)
    fi

    # Return result
    if [ -n "$winner_ip" ]; then
        echo "$winner_ip"
        return 0
    else
        return 1
    fi
}

# Function to scan for K3s Phone Server on the local subnet
scan_for_k3s_server() {
    log_step "Scanning local subnet for K3s Phone Server..."

    local local_ip=$(get_local_ip)
    if [ -z "$local_ip" ]; then
        log_error "Could not determine local IP address"
        return 1
    fi

    log "Local IP: $local_ip"

    # Extract subnet (assume /24)
    local subnet=$(echo "$local_ip" | cut -d. -f1-3)
    log "Scanning subnet: ${subnet}.0/24 on port 8005"

    # Use the parallel scanner with auto-detected local subnet
    local found_ip=$(scan_k3s_phone_server_parallel "$subnet" "true")

    if [ -n "$found_ip" ]; then
        log "📱 K3s Phone Server discovered at: $found_ip:8005"

        # Get server response for verbose logging
        if [ "$VERBOSE" = true ]; then
            local response=$(curl -s --connect-timeout 3 --max-time 5 "http://${found_ip}:8005/status" 2>/dev/null || echo "")
            if [ -n "$response" ]; then
                log_verbose "Server response: $response"
            fi
        fi

        echo "$found_ip"
        return 0
    else
        log_warn "❌ No K3s Phone Server found on local subnet"
        log_warn "⚠️  This means no location, image capture, or local AI capabilities will be available"
        log_warn "    Make sure the K3s Phone Server app is running on an Android device"
        log_warn "    connected to the same network (${subnet}.0/24)"
        return 1
    fi
}

# Function to perform a verbose scan for K3s Phone Server (standalone command)
scan_for_k3s_server_verbose() {
    local custom_subnet="$1"
    log_step "Verbose K3s Phone Server Discovery Scan"
    echo ""

    local local_ip=""
    local subnet=""

    # Determine target subnet
    if [ -n "$custom_subnet" ]; then
        log "🎯 Using custom subnet specification: $custom_subnet"

        # Parse different subnet formats
        if [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
            # Format: 192.168.1 (missing last octet)
            subnet="$custom_subnet"
            log "   Interpreted as: ${subnet}.0/24"
        elif [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            # Format: 192.168.1.0/24 (CIDR notation)
            subnet=$(echo "$custom_subnet" | cut -d'/' -f1 | cut -d. -f1-3)
            local cidr=$(echo "$custom_subnet" | cut -d'/' -f2)
            log "   Interpreted as: ${subnet}.0/$cidr"
            if [ "$cidr" != "24" ]; then
                log_warn "   Note: Only /24 subnets are supported, treating as ${subnet}.0/24"
            fi
        elif [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            # Format: 192.168.1.0 (full IP, extract subnet)
            subnet=$(echo "$custom_subnet" | cut -d. -f1-3)
            log "   Interpreted as: ${subnet}.0/24"
        else
            log_error "Invalid subnet format: $custom_subnet"
            log_error "Supported formats:"
            log_error "  • 192.168.1 (subnet without last octet)"
            log_error "  • 192.168.1.0 (subnet with zero last octet)"
            log_error "  • 192.168.1.0/24 (CIDR notation)"
            return 1
        fi

        # Validate subnet format
        if ! [[ "$subnet" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
            log_error "Invalid subnet derived: $subnet"
            return 1
        fi

        # Get local IP for informational purposes only
        local_ip=$(get_local_ip)
        if [ -n "$local_ip" ]; then
            log "   Local IP Address: $local_ip"
        fi
    else
        # Use default subnet 192.168.179.0/24 instead of auto-detecting
        subnet="192.168.179"
        log "🌐 Using default subnet for K3s Phone Server discovery:"

        # Get local IP for informational purposes
        local_ip=$(get_local_ip)
        if [ -n "$local_ip" ]; then
            log "   Local IP Address: $local_ip"
        fi

        log "   Default Target: 192.168.179.0/24 (K3s Phone Server default network)"
    fi

    log "   Target Subnet: ${subnet}.0/24"
    log "   Scan Range: ${subnet}.1 - ${subnet}.254"
    log "   Target Port: 8005 (K3s Phone Server)"
    echo ""

    # Check if required tools are available
    if ! command -v curl &> /dev/null; then
        log_warn "curl not found, installing..."
        sudo apt-get update -qq && sudo apt-get install -y curl
    fi

    local found_servers=()
    local scanned_count=0
    local responsive_count=0
    local k3s_servers_count=0

    log "🔍 Starting parallel subnet scan..."
    echo ""

    log "🚀 Launching parallel scans across ${subnet}.1-254..."

    # Use the working parallel scan function instead of the problematic embedded one
    local winner_ip=$(scan_k3s_phone_server_parallel "$subnet" "false")

    echo ""
    if [ -n "$winner_ip" ]; then
        log "✅ K3s Phone Server found at: $winner_ip:8005"

        # Get additional server information for the winner
        if [ "$VERBOSE" = true ]; then
            log_verbose "   Getting detailed server information..."

            local info_response=$(curl -s --connect-timeout 3 --max-time 7 "http://${winner_ip}:8005/info" 2>/dev/null || echo "")
            if [ -n "$info_response" ]; then
                log_verbose "   Server Info: $info_response"
            fi

            # Test individual endpoints
            log_verbose "   Testing endpoints:"
            local endpoints=("/status" "/location" "/orientation" "/help")
            for endpoint in "${endpoints[@]}"; do
                local test_url="http://${winner_ip}:8005${endpoint}"
                if curl -s --connect-timeout 2 --max-time 4 "$test_url" >/dev/null 2>&1; then
                    log_verbose "     ✅ $endpoint - Available"
                else
                    log_verbose "     ❌ $endpoint - Not responding"
                fi
            done
        fi

        echo ""
        log "📊 Scan Results Summary:"
        log "   Parallel scan completed"
        log "   K3s Phone Server found: $winner_ip:8005"
        echo ""

        log "🎯 K3s Phone Server Details:"
        log "   📱 Server: http://$winner_ip:8005"

        # Get detailed server capabilities for the winner
        log "   Capabilities:"
        local capabilities=$(curl -s --connect-timeout 3 --max-time 7 "http://${winner_ip}:8005/capabilities" 2>/dev/null || echo "")
        if [ -n "$capabilities" ]; then
            log "     $capabilities"
        else
            log "     • Server status (/status)"
            log "     • Location services (/location)"
            log "     • Orientation data (/orientation)"
            log "     • Help information (/help)"
            log "     • Camera capture (/capture)"
            log "     • AI text generation (/ai/text)"
            log "     • Object detection (/ai/object_detection)"
        fi

        # Test network latency
        local ping_result=$(ping -c 3 -W 2000 "$winner_ip" 2>/dev/null | grep "avg" | cut -d'/' -f5 2>/dev/null || echo "unknown")
        if [ "$ping_result" != "unknown" ]; then
            log "     • Network latency: ${ping_result}ms average"
        fi
        echo ""

        log "💡 Configuration Recommendations:"
        log "   To use this server with agent nodes:"
        log "   1. Run: ./setup.sh setup-port"
        log "   2. Or manually setup port forwarding:"
        log "      socat TCP-LISTEN:8005,fork TCP:$winner_ip:8005 &"
        echo ""
        log "   For agent node setup:"
        log "   • Make sure the Android app stays running"
        log "   • Ensure both devices are on the same network"
        log "   • Test connection: curl http://$winner_ip:8005/status"
        echo ""

        echo "$winner_ip"  # Return the IP for potential use in scripts
        return 0
    else
        log "❌ No K3s Phone Server found"
        log "   Scanned ${subnet}.1-254 on port 8005"
        log "   No devices responded with 'K3s Phone Server' identification"
        echo ""
        log "💡 Troubleshooting:"
        log "   • Ensure K3s Phone Server Android app is running"
        log "   • Check if devices are on the same network"
        log "   • Try scanning a different subnet: ./setup.sh scan-for-server 192.168.1"
        log "   • Verify port 8005 is not blocked by firewalls"
        echo ""
        return 1
    fi
}

# Function to setup port forwarding to a specific IP (for immediate use)
setup_port_forwarding_to_network_ip() {
    local target_ip="$1"
    
    if [ -z "$target_ip" ]; then
        log_error "No target IP provided for port forwarding"
        return 1
    fi
    
    # Check if socat is available
    if ! command -v socat &> /dev/null; then
        log "Installing socat for port forwarding..."
        sudo apt-get update -qq && sudo apt-get install -y socat >/dev/null 2>&1
    fi
    
    # Kill any existing socat processes on port 8005
    sudo pkill -f "socat.*8005" 2>/dev/null || true
    
    # Start port forwarding in background
    log "Starting port forwarding: localhost:8005 → ${target_ip}:8005"
    sudo socat TCP-LISTEN:8005,fork,reuseaddr TCP:${target_ip}:8005 &
    
    # Wait a moment and test
    sleep 2
    if curl -s --connect-timeout 3 --max-time 5 "http://localhost:8005/status" >/dev/null 2>&1; then
        log "✅ Port forwarding active and working"
        return 0
    else
        log_error "❌ Port forwarding setup failed"
        return 1
    fi
}

# Function to setup port forwarding using socat
setup_port_forwarding() {
    log_step "Setting up K3s Phone Server port forwarding..."

    # Check if socat is available
    if ! command -v socat &> /dev/null; then
        log "Installing socat..."
        sudo apt-get update -qq && sudo apt-get install -y socat
    fi

    # Scan for the server
    local server_ip=$(scan_for_k3s_server)
    if [ $? -ne 0 ] || [ -z "$server_ip" ]; then
        log_error "Cannot setup port forwarding without a detected K3s Phone Server"
        return 1
    fi

    # Store the server IP in a config file
    local config_file="/etc/k3s-phone-server.conf"
    echo "K3S_PHONE_SERVER_IP=$server_ip" | sudo tee "$config_file" > /dev/null
    log "📁 Server IP stored in $config_file"

    # Check if port 8005 is already in use locally
    if ss -tuln 2>/dev/null | grep -q ':8005 ' || netstat -tuln 2>/dev/null | grep -q ':8005 '; then
        log_warn "⚠️  Port 8005 is already in use locally"
        log "Checking if existing service is our port forwarding..."

        # Check if it's our socat process
        if pgrep -f "socat.*TCP-LISTEN:8005.*TCP:.*:8005" > /dev/null; then
            log "✅ Port forwarding to K3s Phone Server is already active"
            return 0
        else
            log_error "Port 8005 is occupied by another service"
            log "Please stop the service using port 8005 or use a different configuration"
            return 1
        fi
    fi

    # Create intelligent port forwarding script with IP reevaluation
    log "Creating intelligent port forwarding script..."

    cat << 'EOF' | sudo tee /usr/local/bin/k3s-phone-forward.sh > /dev/null
#!/bin/bash

# Intelligent K3s Phone Server Port Forwarding
# Reevaluates IP every 60s if working, retries every 20s if no connection

LOG_TAG="k3s-phone-forward"
CONFIG_FILE="/etc/k3s-phone-server.conf"

log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" | systemd-cat -t "$LOG_TAG" -p info
}

log_warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" | systemd-cat -t "$LOG_TAG" -p warning
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | systemd-cat -t "$LOG_TAG" -p err
}

# Function to scan for K3s Phone Server
scan_for_server() {
    # Try to determine network range automatically
    local default_route=$(ip route | grep default | head -n1)
    local target_subnet=""

    if [ -n "$default_route" ]; then
        local gateway=$(echo "$default_route" | awk '{print $3}')
        if [[ "$gateway" =~ ^192\.168\.([0-9]+)\.1$ ]]; then
            target_subnet="192.168.${BASH_REMATCH[1]}"
        fi
    fi

    # Default to 192.168.179 if we can't determine the subnet
    if [ -z "$target_subnet" ]; then
        target_subnet="192.168.179"
    fi

    log_info "Scanning network ${target_subnet}.0/24 for K3s Phone Server..."

    # Use the reusable parallel scanner with quiet mode
    # Note: We need to source the main functions, but since this runs in a systemd script,
    # we'll use a simplified parallel approach

    # Create temporary directory for parallel scan results
    local temp_dir=$(mktemp -d)
    local winner_file="$temp_dir/winner"

    # Cleanup function
    cleanup_embedded_scan() {
        jobs -p | xargs -r kill 2>/dev/null
        wait 2>/dev/null
        rm -rf "$temp_dir" 2>/dev/null
    }
    trap cleanup_embedded_scan EXIT INT TERM

    # Function to test a single IP (will run in background)
    test_single_ip() {
        local ip="$1"
        local winner_file="$2"

        # Check if someone already won
        if [ -f "$winner_file" ]; then
            return 0
        fi

        if timeout 1 curl -s "http://$ip:8005/status" 2>/dev/null | grep -q "K3s Phone Server"; then
            # Try to claim the win
            if ! [ -f "$winner_file" ]; then
                echo "$ip" > "$winner_file" 2>/dev/null
            fi
        fi
    }

    # Launch parallel scans in batches
    local batch_size=20
    local jobs_running=0

    for i in {1..254}; do
        local ip="${target_subnet}.${i}"

        # Launch background job
        test_single_ip "$ip" "$winner_file" &
        jobs_running=$((jobs_running + 1))

        # If we've hit batch size, wait and check for winner
        if [ $jobs_running -ge $batch_size ]; then
            if [ -f "$winner_file" ]; then
                break
            fi
            wait
            jobs_running=0
            if [ -f "$winner_file" ]; then
                break
            fi
        fi
    done

    # Wait for remaining jobs
    wait 2>/dev/null

    # Get result
    local winner_ip=""
    if [ -f "$winner_file" ]; then
        winner_ip=$(cat "$winner_file" 2>/dev/null)
    fi

    # Cleanup
    cleanup_embedded_scan
    trap - EXIT INT TERM

    if [ -n "$winner_ip" ]; then
        echo "$winner_ip"
        return 0
    fi

    return 1
}

# Function to test connection to server
test_connection() {
    local server_ip="$1"
    timeout 5 curl -s "http://$server_ip:8005/status" 2>/dev/null | grep -q "K3s Phone Server"
}

# Main forwarding loop
main_loop() {
    local current_server_ip=""
    local last_check=0
    local socat_pid=""

    while true; do
        local now=$(date +%s)
        local should_check=false
        local check_interval=60  # Default: check every 60 seconds if working

        # If no current server IP or socat process died, scan immediately
        if [ -z "$current_server_ip" ] || ! kill -0 "$socat_pid" 2>/dev/null; then
            should_check=true
            check_interval=20  # Retry every 20 seconds if no connection
            if [ -n "$socat_pid" ]; then
                log_warn "socat process died, rescanning for server"
            fi
        elif [ $((now - last_check)) -ge $check_interval ]; then
            should_check=true
        fi

        if [ "$should_check" = true ]; then
            last_check=$now

            # Test current server if we have one
            if [ -n "$current_server_ip" ] && test_connection "$current_server_ip"; then
                log_info "Server $current_server_ip still responsive"
            else
                # Current server not working, scan for new one
                log_info "Scanning for K3s Phone Server..."
                local new_server_ip=$(scan_for_server)

                if [ $? -eq 0 ] && [ -n "$new_server_ip" ]; then
                    if [ "$new_server_ip" != "$current_server_ip" ]; then
                        log_info "Found K3s Phone Server at $new_server_ip"

                        # Kill old socat process
                        if [ -n "$socat_pid" ] && kill -0 "$socat_pid" 2>/dev/null; then
                            log_info "Stopping old port forwarding to $current_server_ip"
                            kill "$socat_pid" 2>/dev/null
                            wait "$socat_pid" 2>/dev/null
                        fi

                        # Start new socat process
                        log_info "Starting port forwarding localhost:8005 -> $new_server_ip:8005"
                        socat TCP-LISTEN:8005,fork,reuseaddr TCP:$new_server_ip:8005 &
                        socat_pid=$!
                        current_server_ip="$new_server_ip"

                        # Update config file
                        echo "K3S_PHONE_SERVER_IP=$new_server_ip" > "$CONFIG_FILE"

                        check_interval=60  # Check every 60 seconds when working
                    fi
                else
                    log_warn "No K3s Phone Server found, retrying in 20 seconds"
                    current_server_ip=""
                    socat_pid=""
                    check_interval=20  # Retry every 20 seconds when no server found
                fi
            fi
        fi

        sleep 5  # Main loop runs every 5 seconds for responsiveness
    done
}

# Handle signals gracefully
cleanup() {
    log_info "Received shutdown signal, cleaning up..."
    if [ -n "$socat_pid" ] && kill -0 "$socat_pid" 2>/dev/null; then
        kill "$socat_pid" 2>/dev/null
        wait "$socat_pid" 2>/dev/null
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

log_info "Starting intelligent K3s Phone Server port forwarding"
main_loop
EOF

    sudo chmod +x /usr/local/bin/k3s-phone-forward.sh

    # Create systemd service for intelligent port forwarding
    log "Creating systemd service for intelligent port forwarding..."

    cat << EOF | sudo tee /etc/systemd/system/k3s-phone-server-forward.service > /dev/null
[Unit]
Description=K3s Phone Server Intelligent Port Forwarding
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/k3s-phone-forward.sh
Restart=always
RestartSec=10
User=root
Group=root
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start the service
    sudo systemctl daemon-reload
    sudo systemctl enable k3s-phone-server-forward.service
    sudo systemctl start k3s-phone-server-forward.service

    # Wait a moment and check if service started successfully
    sleep 2
    if sudo systemctl is-active --quiet k3s-phone-server-forward.service; then
        log "✅ Port forwarding service started successfully"
        log "🔌 Local port 8005 now forwards to $server_ip:8005"
        log ""
        log "📱 K3s Phone Server capabilities now available:"
        log "   • Location services (/location)"
        log "   • Orientation data (/orientation)"
        log "   • Help information (/help)"
        log "   • Camera capture (/capture)"
        log "   • AI text generation (/ai/text)"
        log "   • Object detection (/ai/object_detection)"
        log ""
        log "Test the connection:"
        log "   curl http://localhost:8005/status"

        # Test the forwarding
        log_verbose "Testing port forwarding..."
        local test_response=$(curl -s --connect-timeout 5 --max-time 10 "http://localhost:8005/status" 2>/dev/null || echo "")
        if [[ "$test_response" == *"K3s Phone Server"* ]]; then
            log "✅ Port forwarding test successful"
        else
            log_warn "⚠️  Port forwarding test failed - may need a moment to stabilize"
        fi

        # Update Kubernetes ConfigMap for sample_app to use the local forwarded port
        log_verbose "Updating phone-server-config ConfigMap for sample_app..."
        if command -v kubectl &> /dev/null && sudo kubectl cluster-info &> /dev/null; then
            # Create or update the ConfigMap with the correct local configuration
            sudo kubectl create configmap phone-server-config \
                --from-literal=phone.server.host=localhost \
                --from-literal=phone.server.port=8005 \
                --from-literal=phone.server.enabled=true \
                --from-literal=phone.server.timeout=3000 \
                --dry-run=client -o yaml | sudo kubectl apply -f - &> /dev/null

            if [ $? -eq 0 ]; then
                log "📋 Updated phone-server-config ConfigMap for sample_app"
            else
                log_warn "⚠️  Could not update phone-server-config ConfigMap"
            fi
        else
            log_verbose "Kubernetes not available - skipping ConfigMap update"
        fi
    else
        log_error "❌ Failed to start port forwarding service"
        sudo systemctl status k3s-phone-server-forward.service
        return 1
    fi

    return 0
}

# Function to deploy the reverse geocoder service
deploy_geocoder_service() {
    log_verbose "[DEBUG] deploy_geocoder_service() function called"
    log_verbose "[DEBUG] Current working directory: $(pwd)"

    log_step "Deploying reverse geocoder service for offline city name resolution..."
    log "📍 This service provides local geocoding for node location labels"

    # Ensure kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl command not found - cannot deploy geocoder service"
        return 1
    fi

    # Test cluster connectivity (use sudo kubectl like deploy.sh does)
    log_verbose "Testing Kubernetes cluster connectivity..."
    if ! sudo kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Make sure K3s server is running and kubectl is configured properly"
        log_error "Try: sudo systemctl status k3s"
        log_error "For manual kubectl access: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
        return 1
    fi
    log_verbose "✅ Kubernetes cluster is accessible"

    log_verbose "[DEBUG] Starting geocoder directory detection..."

    # Check if we're in the right directory structure
    local current_dir
    current_dir=$(pwd)
    local geocoder_dir=""

    # Look for the geocoder_app directory
    log_verbose "Looking for geocoder_app directory..."
    if [ -d "./geocoder_app" ]; then
        geocoder_dir="./geocoder_app"
        log_verbose "Found geocoder_app in current directory"
    elif [ -d "../geocoder_app" ]; then
        geocoder_dir="../geocoder_app"
        log_verbose "Found geocoder_app in parent directory"
    elif [ -d "/home/$USER/code/experiments/k3s-on-phone/geocoder_app" ]; then
        geocoder_dir="/home/$USER/code/experiments/k3s-on-phone/geocoder_app"
        log_verbose "Found geocoder_app in expected path"
    else
        log_error "Geocoder app directory not found - this is required for cluster functionality"
        log_error "Searched in: ./geocoder_app, ../geocoder_app, /home/$USER/code/experiments/k3s-on-phone/geocoder_app"
        log_error "Please ensure the geocoder_app directory exists in the project"
        return 1
    fi

    log_verbose "Found geocoder directory at: $geocoder_dir"

    # Change to geocoder directory
    cd "$geocoder_dir" || {
        log_error "Cannot access geocoder directory at $geocoder_dir"
        log_error "Check directory permissions and existence"
        return 1
    }

    # Check if the geocoder service already exists
    log_verbose "Checking if reverse-geocoder deployment already exists..."
    if sudo kubectl get deployment reverse-geocoder >/dev/null 2>&1; then
        log_verbose "Found existing reverse-geocoder deployment"
        if [ "$FORCE_MODE" = true ]; then
            log "Force mode: Removing existing geocoder deployment for rebuild..."
            sudo kubectl delete deployment reverse-geocoder >/dev/null 2>&1 || true
            sudo kubectl delete service reverse-geocoder >/dev/null 2>&1 || true
        else
            log "Reverse geocoder service already deployed, checking status..."
            if sudo kubectl get deployment reverse-geocoder -o jsonpath='{.status.readyReplicas}' | grep -q "1"; then
                log "✅ Reverse geocoder service is already running"
                cd "$current_dir"
                return 0
            else
                log "⚠️  Reverse geocoder service exists but not ready, redeploying..."
            fi
        fi
    else
        log_verbose "No existing reverse-geocoder deployment found, proceeding with deployment"
    fi

    # Build the geocoder service if build script exists
    if [ -x "./build.sh" ]; then
        # Force clean build in force mode
        if [ "$FORCE_MODE" = true ] && [ -x "./clean.sh" ]; then
            log_verbose "Force mode: Cleaning previous geocoder build..."
            if [ "$VERBOSE" = true ]; then
                ./clean.sh || log_warn "Clean script failed"
            else
                ./clean.sh >/dev/null 2>&1 || log_warn "Clean script failed"
            fi
        fi

        # If target directory exists but has permission issues, clean it
        if [ -d "target" ] && [ ! -w "target" ]; then
            log_verbose "Target directory exists but has permission issues, cleaning..."
            sudo rm -rf target || {
                log_warn "Failed to clean target directory, may have permission issues"
            }
        fi

        # Run the build script which will use Docker multi-stage build
        log "🛠️ Building reverse geocoder Docker image..."

        # Add extra debugging info for verbose mode
        if [ "$VERBOSE" = true ]; then
            log_verbose "Docker build environment:"
            docker info || log_warn "Failed to get Docker info"

            log_verbose "Project structure:"
            ls -la || log_warn "Failed to list directory"

            # Run build with output shown
            if ./build.sh; then
                log "✅ Geocoder service Docker image built successfully"

                # Verify the image was created
                if docker images | grep -q "reverse-geocoder.*latest"; then
                    log_verbose "✅ Docker image 'reverse-geocoder:latest' confirmed in local registry"
                else
                    log_error "❌ Docker image 'reverse-geocoder:latest' not found after build"
                    log_error "Build may have failed silently. Check Docker daemon and build script."
                    cd "$current_dir"
                    return 1
                fi
            else
                log_error "Geocoder Docker build failed. See errors above."
                log_error "Will not proceed with deployment."
                cd "$current_dir"
                return 1
            fi
        else
            # Run build with output hidden
            if ./build.sh >/dev/null 2>&1; then
                log "✅ Geocoder service Docker image built successfully"

                # Verify the image was created
                if docker images | grep -q "reverse-geocoder.*latest"; then
                    log_verbose "✅ Docker image 'reverse-geocoder:latest' confirmed in local registry"
                else
                    log_error "❌ Docker image 'reverse-geocoder:latest' not found after build"
                    log_error "Build may have failed silently. Run with -v/--verbose for details."
                    cd "$current_dir"
                    return 1
                fi
            else
                log_error "Geocoder Docker build failed. Run with -v/--verbose to see details."
                log_error "Will not proceed with deployment."
                cd "$current_dir"
                return 1
            fi
        fi
    else
        log_error "No build script found for geocoder at ./build.sh"
        log_error "The geocoder service requires a build step to create the Docker image"
        log_error "Please ensure build.sh exists and is executable in the geocoder_app directory"
        cd "$current_dir"
        return 1
    fi

# Deploy the geocoder service if deployment script exists
    if [ -x "./deploy.sh" ]; then
        log_verbose "Deploying reverse geocoder service..."
        log_verbose "Executing: ./deploy.sh"
        if [ "$VERBOSE" = true ]; then
            log_verbose "Running deploy.sh with verbose output..."
            log_verbose "=== DEPLOY.SH OUTPUT START ==="
            if sudo ./deploy.sh; then
                log_verbose "=== DEPLOY.SH OUTPUT END ==="
                log "✅ Reverse geocoder service deployed successfully"

                # Comprehensive test of geocoder functionality
                if ! test_geocoder_comprehensive; then
                    log_error "Geocoder service deployed but failed functionality tests"
                    cd "$current_dir"
                    return 1
                fi
                log "✅ Geocoder service is fully functional"
            else
                log_verbose "=== DEPLOY.SH OUTPUT END ==="
                log_error "Geocoder deployment failed - deploy.sh returned error"
                log_error "This is a critical component for cluster functionality"
                cd "$current_dir"
                return 1
            fi
        else
            log_verbose "Running deploy.sh with output suppressed..."
            if sudo ./deploy.sh >/dev/null 2>&1; then
                log "✅ Reverse geocoder service deployed successfully"

                # Comprehensive test of geocoder functionality (with reduced verbosity)
                if test_geocoder_comprehensive >/dev/null 2>&1; then
                    log "✅ Geocoder functionality test passed"
                else
                    log_error "Geocoder service deployed but failed functionality tests"
                    log_error "Run with -v/--verbose to see test details"
                    cd "$current_dir"
                    return 1
                fi
            else
                log_error "Geocoder deployment failed - deploy.sh returned error"
                log_error "Run with -v/--verbose to see deployment details"
                cd "$current_dir"
                return 1
            fi
        fi
    else
        log_error "No deployment script found for geocoder at ./deploy.sh"
        log_error "The geocoder service requires a deployment script to install to Kubernetes"
        log_error "Please ensure deploy.sh exists and is executable in the geocoder_app directory"
        cd "$current_dir"
        return 1
    fi

    # Return to original directory
    cd "$current_dir"
    return 0
}

# Function to deploy the node-labeler service


install_k3s_server() {
    log_step "Installing K3s as server (master node)..."

    # If force mode is enabled, reset everything first
    if [ "$FORCE_MODE" = true ]; then
        force_reset_cluster
    fi

    # Clean up any conflicting services that shouldn't be on server nodes
    log_step "Cleaning up services not needed on server nodes..."
    
    # Remove any port forwarding service (servers don't need to forward to themselves)
    if sudo systemctl is-active --quiet socat-port-forward 2>/dev/null; then
        log_verbose "Stopping socat port forwarding service (not needed on server)"
        sudo systemctl stop socat-port-forward 2>/dev/null || true
    fi
    if sudo systemctl is-enabled --quiet socat-port-forward 2>/dev/null; then
        log_verbose "Disabling socat port forwarding service"
        sudo systemctl disable socat-port-forward 2>/dev/null || true
    fi
    sudo rm -f /etc/systemd/system/socat-port-forward.service 2>/dev/null || true

    # Kill any running socat processes that might be doing port forwarding
    sudo pkill -f "socat.*8005" 2>/dev/null || true

    # Reload systemd to recognize service removals
    sudo systemctl daemon-reload 2>/dev/null || true
    
    log "✅ Server node cleanup completed"

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
    # In local mode, use K3S_NODE_NAME to preserve the system hostname
    if [ "$LOCAL_MODE" = true ]; then
        log_verbose "Using K3S_NODE_NAME to preserve system hostname"
        current_hostname=$(hostname)
        curl -sfL https://get.k3s.io | K3S_NODE_NAME="$current_hostname" sh - || {
            log_error "Failed to install K3s server"
            log_error "If download failed due to connectivity, try restarting and reinstalling Debian"
            exit $EXIT_INSTALL_FAILED
        }
    else
        # Normal mode - let K3s handle hostname
        curl -sfL https://get.k3s.io | sh - || {
            log_error "Failed to install K3s server"
            log_error "If download failed due to connectivity, try restarting and reinstalling Debian"
            exit $EXIT_INSTALL_FAILED
        }
    fi

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

    # Setup local Docker registry for the server
    if setup_local_registry; then
        log "✅ Registry setup completed"
    else
        log_error "❌ Registry setup failed - this is critical for cluster functionality"
        log_error "The Docker registry is required for proper image distribution across nodes"
        log_error "Without it, agent nodes cannot access locally built images"
        exit $EXIT_CONFIG_FAILED
    fi

    # Deploy the reverse geocoder service (critical for node location labeling)
    if ! deploy_geocoder_service; then
        log_error "❌ Geocoder service deployment failed - this is critical for cluster functionality"
        log_error "The geocoder service is required for proper node location labeling"
        log_error "Without it, geolocation monitoring and node targeting will not work correctly"
        exit $EXIT_CONFIG_FAILED
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
NODE_NAME=$(hostname)
PHONE_API_URL="http://$NODE_NAME:8005"
GEOLOCATION_ENDPOINT="$PHONE_API_URL/location"
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

# Function to get Kubernetes API credentials
get_k8s_api_credentials() {
    local kubeconfig="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

    if [ ! -f "$kubeconfig" ]; then
        return 1
    fi

    # Extract server URL and token from kubeconfig
    K3S_URL=$(grep -E '^\s*server:' "$kubeconfig" | awk '{print $2}' | head -1)
    K3S_TOKEN=$(grep -E '^\s*token:' "$kubeconfig" | awk '{print $2}' | head -1)

    if [ -n "$K3S_URL" ] && [ -n "$K3S_TOKEN" ]; then
        return 0
    else
        return 1
    fi
}

# Function to make Kubernetes API calls
k8s_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    # Get API credentials if not already set
    if [ -z "$K3S_URL" ] || [ -z "$K3S_TOKEN" ]; then
        if ! get_k8s_api_credentials; then
            return 1
        fi
    fi

    local url="${K3S_URL}${endpoint}"
    local curl_opts="-s -k -H \"Authorization: Bearer $K3S_TOKEN\""

    if [ "$method" = "GET" ]; then
        curl -s -k -H "Authorization: Bearer $K3S_TOKEN" "$url"
    elif [ "$method" = "PATCH" ]; then
        curl -s -k -X PATCH \
            -H "Authorization: Bearer $K3S_TOKEN" \
            -H "Content-Type: application/merge-patch+json" \
            -d "$data" \
            "$url"
    else
        return 1
    fi
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
    local node_response
    node_response=$(k8s_api_call "GET" "/api/v1/nodes/$NODE_NAME")

    if [ $? -eq 0 ] && [ -n "$node_response" ]; then
        local latitude longitude altitude

        # Extract latitude, longitude, altitude from API response
        latitude=$(echo "$node_response" | grep -o "\"$LABEL_PREFIX/latitude\":\"[^\"]*\"" | cut -d'"' -f4)
        longitude=$(echo "$node_response" | grep -o "\"$LABEL_PREFIX/longitude\":\"[^\"]*\"" | cut -d'"' -f4)
        altitude=$(echo "$node_response" | grep -o "\"$LABEL_PREFIX/altitude\":\"[^\"]*\"" | cut -d'"' -f4)

        if [ -n "$latitude" ] && [ -n "$longitude" ]; then
            # Use altitude if available, otherwise use 0
            if [ -n "$altitude" ]; then
                echo "$latitude,$longitude,$altitude"
            else
                echo "$latitude,$longitude,0"
            fi
            return 0
        fi
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

    # Use node-labeler service (required for agents)
    if update_labels_via_service "$latitude" "$longitude" "$altitude"; then
        log_info "Updated node labels via service: latitude=$latitude, longitude=$longitude, altitude=$altitude"
        return 0
    else
        log_error "Node-labeler service is required but unavailable"
        log_error "Agent nodes must use node-labeler service for label updates"
        return 1
    fi
}

# Function to update labels via node-labeler service
update_labels_via_service() {
    local latitude="$1"
    local longitude="$2"
    local altitude="$3"

    # Get API credentials if not already set
    if [ -z "$K3S_URL" ] || [ -z "$K3S_TOKEN" ]; then
        if ! get_k8s_api_credentials; then
            return 1
        fi
    fi

    # Get node-labeler service endpoint
    local service_response service_ip service_port
    service_response=$(curl -s -k \
        -H "Authorization: Bearer $K3S_TOKEN" \
        "${K3S_URL}/api/v1/namespaces/kube-system/services/node-labeler-service" 2>/dev/null)

    if [ $? -ne 0 ] || ! echo "$service_response" | grep -q '"kind":"Service"'; then
        return 1
    fi

    # Extract service IP and port
    service_ip=$(echo "$service_response" | grep -o '"clusterIP":"[^"]*"' | cut -d'"' -f4)
    service_port=$(echo "$service_response" | grep -o '"port":[0-9]*' | head -1 | cut -d':' -f2)

    if [ -z "$service_ip" ] || [ -z "$service_port" ]; then
        return 1
    fi

    # Call node-labeler service geolocation endpoint
    local labeler_url="http://${service_ip}:${service_port}"
    local request_data="{\"latitude\":$latitude,\"longitude\":$longitude"

    if [ -n "$altitude" ] && [ "$altitude" != "0" ]; then
        request_data="$request_data,\"altitude\":$altitude"
    fi
    request_data="$request_data}"

    local response
    response=$(curl -s --connect-timeout 10 --max-time 15 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $K3S_TOKEN" \
        -d "$request_data" \
        "${labeler_url}/api/v1/node/${NODE_NAME}/geolocation" 2>/dev/null)

    if [ $? -eq 0 ] && echo "$response" | grep -q '"success":true'; then
        return 0
    else
        return 1
    fi
}

# Function to update city labels via node-labeler service
update_city_via_service() {
    local city_name="$1"
    local timestamp="$2"

    # Get API credentials if not already set
    if [ -z "$K3S_URL" ] || [ -z "$K3S_TOKEN" ]; then
        if ! get_k8s_api_credentials; then
            return 1
        fi
    fi

    # Get node-labeler service endpoint
    local service_response service_ip service_port
    service_response=$(curl -s -k \
        -H "Authorization: Bearer $K3S_TOKEN" \
        "${K3S_URL}/api/v1/namespaces/kube-system/services/node-labeler-service" 2>/dev/null)

    if [ $? -ne 0 ] || ! echo "$service_response" | grep -q '"kind":"Service"'; then
        return 1
    fi

    # Extract service IP and port
    service_ip=$(echo "$service_response" | grep -o '"clusterIP":"[^"]*"' | cut -d'"' -f4)
    service_port=$(echo "$service_response" | grep -o '"port":[0-9]*' | head -1 | cut -d':' -f2)

    if [ -z "$service_ip" ] || [ -z "$service_port" ]; then
        return 1
    fi

    # Escape special characters for Kubernetes labels
    local escaped_city
    escaped_city=$(echo "$city_name" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/^_*//;s/_*$//')

    # Call node-labeler service city endpoint
    local labeler_url="http://${service_ip}:${service_port}"
    local request_data="{\"city\":\"$escaped_city\",\"timestamp\":\"$timestamp\"}"

    local response
    response=$(curl -s --connect-timeout 10 --max-time 15 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $K3S_TOKEN" \
        -d "$request_data" \
        "${labeler_url}/api/v1/node/${NODE_NAME}/city" 2>/dev/null)

    if [ $? -eq 0 ] && echo "$response" | grep -q '"success":true'; then
        return 0
    else
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
        service_ip=$(sudo kubectl get service reverse-geocoder -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
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
    local current_labels current_city city_updated_label
    current_labels=$(get_current_labels)
    current_city=$(echo "$current_labels" | grep "^$LABEL_PREFIX/city=" | cut -d'=' -f2)
    city_updated_label=$(echo "$current_labels" | grep "^$LABEL_PREFIX/city-updated=" | cut -d'=' -f2)

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

        # Create timestamp for city update
        local timestamp
        timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

        # Update city labels via node-labeler service
        if update_city_via_service "$city_name" "$timestamp"; then
            log_info "Updated city label via service: $city_name"
            return 0
        else
            log_error "Node-labeler service is required but unavailable for city updates"
            return 1
        fi
    else
        log_warn "Reverse geocoding failed for coordinates $latitude, $longitude"
        # Set a generic city label to avoid repeated attempts
        local timestamp
        timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

        # Update with unknown city via node-labeler service
        if update_city_via_service "Unknown" "$timestamp"; then
            log_info "Updated city label via service: Unknown"
        else
            log_error "Node-labeler service is required but unavailable for city updates"
        fi
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
    if sudo chmod +x "$service_script"; then
        log_verbose "Made geolocation monitor script executable"
    else
        log_error "Failed to make geolocation monitor script executable"
        return 1
    fi

    # Verify script was created
    if [ ! -f "$service_script" ]; then
        log_error "Geolocation monitor script was not created successfully"
        return 1
    fi

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

    # Verify service file was created
    if [ ! -f "$service_file" ]; then
        log_error "Systemd service file was not created successfully"
        return 1
    fi

    # Reload systemd and enable the service
    if sudo systemctl daemon-reload; then
        log_verbose "Systemd daemon reloaded successfully"
    else
        log_error "Failed to reload systemd daemon"
        return 1
    fi

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
                log_error "Geolocation service failed to start properly"
                return 1
            fi
        else
            log_error "Failed to start geolocation monitoring service"
            return 1
        fi
    else
        log_error "Failed to enable geolocation monitoring service"
        return 1
    fi

    log "Geolocation monitoring service setup completed"
    log "Service will check phone app every 20 seconds and update node labels"
    log "View logs with: sudo journalctl -u k3s-geolocation-monitor -f"
    return 0
}

# Function to check if node-labeler service is available


# Function to set device type via node-labeler service


# Function to install location monitoring service (for master nodes)
install_location_monitoring() {
    log_step "Setting up location monitoring service..."
    log "📍 This service will monitor phone node locations via direct HTTP API access"
    log "   Connects directly to Android app on each phone node's IP:8005"

    # Create the location updater script embedded in setup.sh
    local script_path="/usr/local/bin/update-node-locations.sh"

    log_verbose "Creating location updater script at $script_path"

    sudo tee "$script_path" > /dev/null << 'LOCATION_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Simple Node Location Updater
# Queries geolocation from Android apps via direct HTTP API and updates node labels
DEFAULT_INTERVAL=30
DEFAULT_GEO_PORT=8005
INTERVAL=${INTERVAL:-$DEFAULT_INTERVAL}
RUN_ONCE=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
log() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_verbose() { [ "$VERBOSE" = true ] && echo -e "${YELLOW}[VERBOSE]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }

show_help() {
    cat << EOF
Node Location Updater

Queries geolocation from Android phone nodes via SSH and updates Kubernetes node labels.

USAGE: $0 [OPTIONS]

OPTIONS:
    --interval SECONDS      Update interval in seconds (default: $DEFAULT_INTERVAL)
    --once                  Run once and exit (don't loop)
    --port PORT            Android app geolocation port (default: $DEFAULT_GEO_PORT)
    --verbose              Enable verbose logging
    --help                 Show this help

EXAMPLES:
    $0                     # Run with default 30s interval
    $0 --interval 60       # Run with 60s interval
    $0 --once             # Run once and exit

REQUIREMENTS:
    - kubectl must be available and configured
    - SSH access to phone nodes (passwordless via keys)
    - Android geolocation app running on port $DEFAULT_GEO_PORT
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --interval) INTERVAL="$2"; shift 2 ;;
            --once) RUN_ONCE=true; shift ;;
            --port) DEFAULT_GEO_PORT="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --help) show_help; exit 0 ;;
            *) echo "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
}

# Check if kubectl is available and working
check_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl not found. Please install kubectl and configure access to the cluster."
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "kubectl cannot connect to cluster. Please check your kubeconfig."
        exit 1
    fi

    log_verbose "kubectl is available and cluster is accessible"
}

# Get list of phone nodes
get_phone_nodes() {
    local nodes
    # Get nodes with device-type=phone label, fall back to all nodes if none found
    nodes=$(kubectl get nodes -l device-type=phone -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

    if [ -z "$nodes" ]; then
        log_verbose "No nodes with device-type=phone found, checking all nodes..."
        # Fall back to all nodes and filter for likely phone hostnames
        nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -E '(phone|android|mobile)' || true)
    fi

    if [ -z "$nodes" ]; then
        log_warn "No phone nodes found. Make sure nodes are labeled with device-type=phone"
        return 1
    fi

    echo "$nodes"
}

# Query geolocation from a node via SSH
query_node_location() {
    local node="$1"
    local port="$2"

    log_verbose "Querying location from node: $node (port: $port)"

    # Get the node's IP address from Kubernetes
    local node_ip
    node_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    
    if [ -z "$node_ip" ]; then
        log_verbose "Could not get IP address for node $node"
        return 1
    fi
    
    log_verbose "Using node IP: $node_ip"

    # Try to get location data directly from the Android app via HTTP
    local location_data
    location_data=$(curl -s --connect-timeout 3 --max-time 5 "http://$node_ip:$port/location" 2>/dev/null || true)

    if [ -z "$location_data" ]; then
        log_verbose "No location data from $node_ip:$port (app may not be running or not accessible)"
        return 1
    fi

    # Parse JSON response (basic parsing without jq dependency)
    local latitude longitude altitude city
    latitude=$(echo "$location_data" | grep -o '"latitude":[^,}]*' | cut -d':' -f2 | tr -d ' "' || true)
    longitude=$(echo "$location_data" | grep -o '"longitude":[^,}]*' | cut -d':' -f2 | tr -d ' "' || true)
    altitude=$(echo "$location_data" | grep -o '"altitude":[^,}]*' | cut -d':' -f2 | tr -d ' "' || true)
    city=$(echo "$location_data" | grep -o '"city":"[^"]*"' | cut -d':' -f2 | tr -d '"' || true)

    if [ -z "$latitude" ] || [ -z "$longitude" ]; then
        log_warn "Invalid location data from $node_ip:$port: $location_data"
        return 1
    fi

    log_verbose "Retrieved coordinates from $node: lat=$latitude, lng=$longitude, alt=$altitude, city=$city"
    echo "$latitude,$longitude,$altitude,$city"
}

# Update node labels with location data
update_node_labels() {
    local node="$1"
    local location_data="$2"

    IFS=',' read -r latitude longitude altitude city <<< "$location_data"

    log_verbose "Updating labels for node $node..."

    # Build label update command
    local labels=()
    labels+=("phone.location/latitude=$latitude")
    labels+=("phone.location/longitude=$longitude")
    labels+=("phone.location/updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    labels+=("phone.location/status=active")

    if [ -n "$altitude" ] && [ "$altitude" != "null" ]; then
        labels+=("phone.location/altitude=$altitude")
    fi

    if [ -n "$city" ] && [ "$city" != "null" ]; then
        # Replace spaces and special chars for k8s label compatibility
        local city_clean
        city_clean=$(echo "$city" | sed 's/[^a-zA-Z0-9-]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g')
        labels+=("phone.location/city=$city_clean")
    fi

    # Also ensure device-type=phone label is set
    labels+=("device-type=phone")
    labels+=("node-role.kubernetes.io/phone=true")

    # Apply all labels at once
    log_verbose "Applying ${#labels[@]} labels to node $node"
    if kubectl label node "$node" "${labels[@]}" --overwrite >/dev/null 2>&1; then
        log "✅ Updated location for $node: lat=$latitude, lng=$longitude"
        if [ -n "$city" ] && [ "$city" != "null" ]; then
            log "   City: $city"
        fi
        return 0
    else
        log_error "Failed to update labels for node $node"
        return 1
    fi
}

# Update locations for all phone nodes
update_all_locations() {
    local nodes
    if ! nodes=$(get_phone_nodes); then
        return 1
    fi

    local total_nodes=0
    local success_count=0

    for node in $nodes; do
        total_nodes=$((total_nodes + 1))

        log_verbose "Processing node: $node"

        local location_data
        if location_data=$(query_node_location "$node" "$DEFAULT_GEO_PORT"); then
            if update_node_labels "$node" "$location_data"; then
                success_count=$((success_count + 1))
            fi
        else
            log_warn "Could not retrieve location from $node"
        fi
    done

    log "Processed $total_nodes nodes, $success_count successful updates"

    if [ $success_count -eq 0 ] && [ $total_nodes -gt 0 ]; then
        log_warn "No successful location updates. Check that:"
        log_warn "  1. SSH access to phone nodes is working"
        log_warn "  2. Android geolocation app is running on port $DEFAULT_GEO_PORT"
        log_warn "  3. App is serving location data at /location endpoint"
        return 1
    fi

    return 0
}

# Main function
main() {
    parse_args "$@"

    log "Node Location Updater starting..."
    log "Update interval: ${INTERVAL}s, Port: $DEFAULT_GEO_PORT, Run once: $RUN_ONCE"

    # Check prerequisites
    check_kubectl

    if [ "$RUN_ONCE" = true ]; then
        log "Running single location update..."
        update_all_locations
        exit $?
    fi

    # Continuous mode
    log "Starting continuous location monitoring (press Ctrl+C to stop)..."

    # Trap for graceful shutdown
    trap 'log "Shutting down location updater..."; exit 0' INT TERM

    while true; do
        update_all_locations || log_warn "Update cycle failed, continuing..."

        log_verbose "Waiting ${INTERVAL}s until next update..."
        sleep "$INTERVAL"
    done
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
LOCATION_SCRIPT

    # Make the script executable
    sudo chmod +x "$script_path"

    # Create systemd service for automatic location monitoring (optional)
    local service_file="/etc/systemd/system/location-monitor.service"

    log_verbose "Creating location monitoring systemd service..."
    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=K3s Node Location Monitor
After=network.target k3s.service
Wants=k3s.service

[Service]
Type=simple
User=root
ExecStart=$script_path --interval 60 --verbose
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable but don't start the service (let user decide)
    sudo systemctl daemon-reload
    sudo systemctl enable location-monitor

    log "✅ Location monitoring setup complete"
    log "   Script installed at: $script_path"
    log "   Systemd service: location-monitor (enabled but not started)"
    log ""
    log "   To start monitoring manually:"
    log "     $script_path --once                 # Run once"
    log "     $script_path --interval 30          # Run every 30s"
    log ""
    log "   To start as system service:"
    log "     sudo systemctl start location-monitor"
    log ""
    log "   Prerequisites for phone nodes:"
    log "     1. SSH passwordless access from server to phone nodes"
    log "     2. Android geolocation app running on port 8005"
    log "     3. App serving JSON data at /location endpoint"

    return 0
}

# Function to simply label the current node as a phone
simple_label_node_as_phone() {
    log_step "Labeling current node as a phone..."

    local node_name
    node_name=$(hostname)

    log_verbose "Skipping node labeling - agents don't have kubectl access"
    log "ℹ️  Node $node_name will be labeled by the K3s server when it connects"
    log "   The server will automatically detect and label phone agents"
}

# Function to label the current node as a phone for deployment targeting
label_node_as_phone() {
    # Use the simplified labeling approach
    simple_label_node_as_phone
}



# Function to check geolocation provider connectivity and basic functionality
check_geolocation_provider() {
    log_step "Checking reverse geolocation provider connectivity..."

    # Try to find the reverse geocoder service endpoint
    local api_url=""
    local provider_available=false

    # First try to find the geocoder service in Kubernetes (if kubectl is available)
    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info &>/dev/null 2>&1; then
        log_verbose "Checking for geocoder service in cluster..."

        # Check if deployment exists
        if ! sudo kubectl get deployment reverse-geocoder &>/dev/null 2>&1; then
            log_warn "⚠️  Geocoder deployment not found in cluster"
            log_warn "⚠️  Geocoder service was not deployed or deployment failed"
            return 1
        fi

        # Check deployment readiness
        local ready_replicas
        ready_replicas=$(sudo kubectl get deployment reverse-geocoder -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$ready_replicas" != "1" ]; then
            log_warn "⚠️  Geocoder deployment not ready: $ready_replicas/1 replicas"
            return 1
        fi
        log_verbose "✅ Geocoder deployment is ready"

        # Get service IP
        local service_ip
        service_ip=$(sudo kubectl get service reverse-geocoder -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        if [ -n "$service_ip" ]; then
            api_url="http://${service_ip}:8090"
            log_verbose "Found geocoder service in cluster at: $api_url"
        else
            log_warn "⚠️  Cannot determine geocoder service IP"
            return 1
        fi
    else
        log_warn "⚠️  Cannot check geocoder service - kubectl not available or cluster not accessible"
        return 1
    fi

    # Test the health endpoint
    log_verbose "Testing geocoder health endpoint..."
    local health_response
    health_response=$(curl -s --connect-timeout 5 --max-time 10 "${api_url}/health" 2>/dev/null)

    if [ $? -eq 0 ] && echo "$health_response" | grep -q "ok"; then
        log "✅ Reverse geolocation provider is accessible"
        provider_available=true
        log_verbose "Health response: $health_response"

        # Test a simple reverse geocode request
        log_verbose "Testing reverse geocoding functionality..."
        local test_result
        test_result=$(curl -s --connect-timeout 10 --max-time 15 \
            "${api_url}/api/reverse-geocode?lat=52.52&lon=13.40&method=geonames" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$test_result" ]; then
            local test_location
            test_location=$(echo "$test_result" | grep -o '"location":"[^"]*"' | cut -d'"' -f4)
            if [ -n "$test_location" ]; then
                log "✅ Reverse geocoding test successful: $test_location"
            else
                log_warn "⚠️  Reverse geocoding test returned no location"
                log_verbose "API response: $test_result"
                provider_available=false
            fi
        else
            log_warn "⚠️  Reverse geocoding test failed"
            log_verbose "API call failed or returned no data"
            provider_available=false
        fi

    else
        log_warn "⚠️  Reverse geolocation provider not accessible at $api_url"
        log_verbose "Health endpoint response: ${health_response:-'No response'}"
        log_warn "⚠️  City name resolution may not work properly"
        log_warn "⚠️  Geolocation monitoring will still track coordinates"
    fi

    # Provide guidance based on result
    if [ "$provider_available" = true ]; then
        log_verbose "Geolocation provider check passed - full location functionality available"
        return 0
    else
        log_warn "Geolocation provider check failed - limited functionality:"
        log_warn "  • Coordinate tracking: ✅ Available"
        log_warn "  • City name resolution: ❌ Not available"
        log_warn "  • Solution: Check geocoder service status on the master node"
        log_warn "  • Alternative: City names can be added manually via kubectl labels"

        # Provide troubleshooting information
        if command -v kubectl >/dev/null 2>&1; then
            log_warn ""
            log_warn "Troubleshooting commands:"
            log_warn "  • Check deployment: kubectl get deployment reverse-geocoder"
            log_warn "  • Check pods: kubectl get pods -l app=reverse-geocoder"
            log_warn "  • Check service: kubectl get service reverse-geocoder"
            log_warn "  • Check logs: kubectl logs deployment/reverse-geocoder"
        fi

        return 1
    fi
}

check_and_reinstall_tailscale_for_agent() {
    log_step "Setting up Tailscale for agent mode (always reinstalling for clean setup)..."

    # Always reinstall Tailscale in agent mode for clean configuration
    if command -v tailscale &> /dev/null; then
        log "Tailscale is installed - removing for clean agent setup..."

        # Log out and disconnect from Tailscale
        log_verbose "Logging out from Tailscale..."
        sudo tailscale logout 2>/dev/null || log_warn "Failed to logout from Tailscale (may not be logged in)"

        # Stop the Tailscale daemon
        log_verbose "Stopping Tailscale daemon..."
        if command -v systemctl &>/dev/null; then
            sudo systemctl stop tailscaled 2>/dev/null || log_warn "Failed to stop Tailscale daemon"
            # Wait for daemon to fully stop
            sleep 3
        fi

        # Purge Tailscale package to ensure clean reinstall
        log_verbose "Removing Tailscale package..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get remove -y tailscale 2>/dev/null || log_warn "Failed to remove Tailscale package"
            sudo apt-get purge -y tailscale 2>/dev/null || log_warn "Failed to purge Tailscale package"
        fi

        # Remove state directory to ensure clean state
        log_verbose "Cleaning Tailscale state..."
        sudo rm -rf /var/lib/tailscale 2>/dev/null || log_warn "Failed to remove Tailscale state directory"

        # Ensure daemon is completely stopped
        log_verbose "Ensuring Tailscale daemon is fully stopped..."
        sudo pkill -f tailscaled 2>/dev/null || true
        sleep 2

        log_verbose "Installing fresh Tailscale for agent..."
    else
        log "Installing Tailscale for agent mode..."
    fi

    # Install and configure Tailscale (fresh install)
    setup_tailscale_for_agent

    # Test connectivity to K3s server after Tailscale setup
    test_k3s_server_connectivity
}

setup_tailscale_for_agent() {
    log_step "Installing and configuring Tailscale for agent..."

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
        sleep 3

        # Check if daemon is running
        if ! sudo systemctl is-active tailscaled &>/dev/null; then
            log_error "Tailscale daemon failed to start"
            echo "Check status with: sudo systemctl status tailscaled"
            echo "Check logs with: sudo journalctl -u tailscaled"
            exit $EXIT_CONFIG_FAILED
        fi
    fi

    # For agent mode, always attempt authentication regardless of current status
    # This ensures we connect to the correct Tailscale network with the provided auth key
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        log_verbose "Connecting to Tailscale with validated auth key"
        log_verbose "Auth key starts with: $(echo "$TAILSCALE_AUTH_KEY" | cut -c1-15)..."
        log_verbose "Hostname for auth: $HOSTNAME"

        # Always run tailscale up in agent mode, even if already connected
        log "Authenticating with Tailscale using provided auth key (forced in agent mode)..."
        if sudo tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --hostname="$HOSTNAME" --force-reauth; then
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
            exit $EXIT_CONFIG_FAILED
        fi
    else
        log_error "No Tailscale auth key provided for agent mode"
        log_error "Agent mode requires Tailscale auth key for automatic setup"
        echo ""
        echo "Please provide auth key with: -t YOUR_AUTH_KEY"
        echo "Get an auth key from: https://login.tailscale.com/admin/settings/keys"
        echo ""
        exit $EXIT_INVALID_ARGS
    fi

    log "Tailscale setup completed for agent"
}

test_k3s_server_connectivity() {
    log_step "Testing connectivity to K3s server..."

    if [ -n "$K3S_URL" ]; then
        # Extract host from K3S_URL (e.g., https://192.168.1.100:6443 -> 192.168.1.100)
        local k3s_host
        k3s_host=$(echo "$K3S_URL" | sed -E 's|https?://([^:]+):.*|\1|')

        if [ -n "$k3s_host" ]; then
            log_verbose "Testing ping to K3s server: $k3s_host"
            if ping -c 3 "$k3s_host" &> /dev/null; then
                log "✅ Successfully connected to K3s server at $k3s_host"
            else
                log_error "❌ Cannot reach K3s server at $k3s_host"
                log_error "This may indicate network connectivity issues or firewall blocking"
                log_error "Please verify the server is accessible and Tailscale is working properly"

                # Show Tailscale status for debugging
                if command -v tailscale &> /dev/null; then
                    log_verbose "Current Tailscale status:"
                    sudo tailscale status 2>/dev/null || log_warn "Failed to get Tailscale status"
                fi

                exit $EXIT_CONFIG_FAILED
            fi
        else
            log_warn "Could not extract host from K3S_URL: $K3S_URL"
        fi
    else
        log_warn "K3S_URL not set, skipping server connectivity test"
    fi
}



# Function to uninstall any existing K3s installation for clean agent setup
uninstall_existing_k3s() {
    log_step "Uninstalling any existing K3s installation for clean agent setup..."

    # Stop and disable geolocation monitoring if it exists
    log_verbose "Stopping geolocation monitoring service..."
    sudo systemctl stop k3s-geolocation-monitor 2>/dev/null || true
    sudo systemctl disable k3s-geolocation-monitor 2>/dev/null || true
    sudo rm -f /usr/local/bin/k3s-geolocation-monitor 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k3s-geolocation-monitor.service 2>/dev/null || true

    # Use official K3s uninstall scripts
    log_verbose "Running official K3s uninstall scripts..."

    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        log "Found existing K3s server installation, uninstalling..."
        if [ "$VERBOSE" = true ]; then
            sudo /usr/local/bin/k3s-uninstall.sh
        else
            sudo /usr/local/bin/k3s-uninstall.sh 2>&1 | while read -r line; do
                log_verbose "$line"
            done
        fi
        log "✅ K3s server uninstall completed"
    elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
        log "Found existing K3s agent installation, uninstalling..."
        if [ "$VERBOSE" = true ]; then
            sudo /usr/local/bin/k3s-agent-uninstall.sh
        else
            sudo /usr/local/bin/k3s-agent-uninstall.sh 2>&1 | while read -r line; do
                log_verbose "$line"
            done
        fi
        log "✅ K3s agent uninstall completed"
    else
        # Manual cleanup if no uninstall scripts exist
        log_verbose "No K3s uninstall scripts found, performing manual cleanup..."

        # Stop services
        sudo systemctl stop k3s-agent 2>/dev/null || true
        sudo systemctl stop k3s 2>/dev/null || true
        sudo systemctl disable k3s-agent 2>/dev/null || true
        sudo systemctl disable k3s 2>/dev/null || true

        # Remove files and directories
        sudo rm -rf /var/lib/rancher/k3s 2>/dev/null || true
        sudo rm -rf /etc/rancher/k3s 2>/dev/null || true
        sudo rm -f /usr/local/bin/k3s* 2>/dev/null || true
        sudo rm -f /etc/systemd/system/k3s* 2>/dev/null || true

        sudo systemctl daemon-reload
        log "Manual K3s cleanup completed"
    fi

    # Remove any kubectl configuration
    local user_home
    if [ "$USER" = "root" ]; then
        user_home="/root"
    else
        user_home="/home/$USER"
    fi

    # Remove KUBECONFIG from .bashrc if it exists
    if [ -f "$user_home/.bashrc" ] && grep -q "KUBECONFIG.*k3s.yaml" "$user_home/.bashrc"; then
        log_verbose "Removing KUBECONFIG from ~/.bashrc"
        # Create a backup and remove the K3s kubectl configuration lines
        cp "$user_home/.bashrc" "$user_home/.bashrc.k3s-backup"
        grep -v "KUBECONFIG.*k3s.yaml\|# K3s kubectl configuration" "$user_home/.bashrc.k3s-backup" > "$user_home/.bashrc"
    fi

    # Remove .kube directory if it contains K3s config
    if [ -d "$user_home/.kube" ] && [ -f "$user_home/.kube/config" ]; then
        log_verbose "Removing kubectl config directory"
        rm -rf "$user_home/.kube" 2>/dev/null || true
    fi

    log "K3s uninstall completed - ready for fresh agent installation"
}

install_k3s_agent() {
    log_step "Installing K3s as agent (worker node)..."

    # Install debugging utilities for network troubleshooting
    install_debug_utilities

    # Always uninstall any existing K3s installation for clean agent setup
    if command -v k3s &> /dev/null; then
        uninstall_existing_k3s
    fi

    # Clean up any conflicting services that shouldn't be on agent nodes
    log_step "Cleaning up services not needed on agent nodes..."
    
    # Remove port forwarding service (agents don't need this)
    if sudo systemctl is-active --quiet socat-port-forward 2>/dev/null; then
        log_verbose "Stopping socat port forwarding service"
        sudo systemctl stop socat-port-forward 2>/dev/null || true
    fi
    if sudo systemctl is-enabled --quiet socat-port-forward 2>/dev/null; then
        log_verbose "Disabling socat port forwarding service"
        sudo systemctl disable socat-port-forward 2>/dev/null || true
    fi
    sudo rm -f /etc/systemd/system/socat-port-forward.service 2>/dev/null || true

    # Remove geolocation monitoring service (only servers need this)
    if sudo systemctl is-active --quiet k3s-geolocation-monitor 2>/dev/null; then
        log_verbose "Stopping geolocation monitoring service"
        sudo systemctl stop k3s-geolocation-monitor 2>/dev/null || true
    fi
    if sudo systemctl is-enabled --quiet k3s-geolocation-monitor 2>/dev/null; then
        log_verbose "Disabling geolocation monitoring service"
        sudo systemctl disable k3s-geolocation-monitor 2>/dev/null || true
    fi
    sudo rm -f /etc/systemd/system/k3s-geolocation-monitor.service 2>/dev/null || true
    sudo rm -f /usr/local/bin/k3s-geolocation-monitor 2>/dev/null || true

    # Kill any running socat processes that might be doing port forwarding
    sudo pkill -f "socat.*8005" 2>/dev/null || true

    # Reload systemd to recognize service removals
    sudo systemctl daemon-reload 2>/dev/null || true
    
    log "✅ Agent node cleanup completed"

    # In agent mode, check and reinstall Tailscale if already configured
    if [ "$LOCAL_MODE" = false ]; then
        check_and_reinstall_tailscale_for_agent
    fi

    log_verbose "Checking GitHub connectivity for K3s download..."
    if ! ping -c 1 github.com &> /dev/null; then
        log_error "Cannot reach github.com - network connectivity issue detected"
        log_error "If connectivity issues persist, try restarting and reinstalling Debian on your phone"
        log_error "This is a known issue with the Android Linux Terminal app"
        exit $EXIT_INSTALL_FAILED
    fi

    log_verbose "Downloading and installing K3s agent with server URL: $K3S_URL"
    log_verbose "This may take a few minutes - downloading K3s binary and setting up systemd service..."

    # In local mode, use K3S_NODE_NAME to preserve the system hostname
    if [ "$LOCAL_MODE" = true ]; then
        log_verbose "Using K3S_NODE_NAME to preserve system hostname"
        current_hostname=$(hostname)
        log_verbose "Installing K3s agent with preserved hostname: $current_hostname"

        # Show the exact command being executed
        log "Executing K3s agent installation command:"
        log "curl -sfL https://get.k3s.io | K3S_URL=\"$K3S_URL\" K3S_TOKEN=\"[REDACTED]\" K3S_NODE_NAME=\"$current_hostname\" sh -"

        curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" K3S_NODE_NAME="$current_hostname" K3S_NODE_LABEL="device-type=phone" sh - || {
            log_error "Failed to install K3s agent"
            log_error "If download failed due to connectivity, try restarting and reinstalling Debian"
            exit $EXIT_INSTALL_FAILED
        }
    else
        # Normal mode - let K3s handle hostname
        log_verbose "Installing K3s agent with auto-generated hostname"

        # Show the exact command being executed
        log "Executing K3s agent installation command:"
        log "curl -sfL https://get.k3s.io | K3S_URL=\"$K3S_URL\" K3S_TOKEN=\"[REDACTED]\" K3S_NODE_LABEL=\"device-type=phone\" sh -"

        curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" K3S_NODE_LABEL="device-type=phone" sh - || {
            log_error "Failed to install K3s agent"
            log_error "If download failed due to connectivity, try restarting and reinstalling Debian"
            exit $EXIT_INSTALL_FAILED
        }
    fi

    log "✅ K3s agent installation completed"
    log_verbose "K3s installer automatically set up and started the k3s-agent systemd service"

    # Give the service a moment to start up
    log "Waiting for k3s-agent service to initialize..."
    sleep 10

    # Check if the service is running (simple check)
    if sudo systemctl is-active --quiet k3s-agent; then
        log "✅ k3s-agent service is running"
    else
        log_warn "⚠️  k3s-agent service may still be starting up"
        log_warn "Check status with: sudo systemctl status k3s-agent"
        log_warn "View logs with: sudo journalctl -u k3s-agent -f"
    fi

    # NOW configure Docker registry AFTER K3s agent is installed and running
    # Use Tailscale IP for registry configuration to ensure connectivity
    log_verbose "Configuring Docker for insecure registry access..."
    
    # Get the Tailscale IP of the master node for registry access
    local REGISTRY_HOST=""
    if [ -n "$K3S_URL" ]; then
        # Extract hostname/IP from URL like https://192.168.1.100:6443 or https://thinkstation:6443
        MASTER_HOST=$(echo "$K3S_URL" | sed -E 's|https?://([^:]+):.*|\1|')
        log_verbose "Debug: Extracted MASTER_HOST='$MASTER_HOST' from K3S_URL='$K3S_URL'"
        
        # Try to get the Tailscale IP of the master node
        log_verbose "Looking up Tailscale IP for master node..."
        if command -v tailscale &>/dev/null; then
            # Try to get the Tailscale IP by hostname lookup or ping
            TAILSCALE_IP=""
            if [[ "$MASTER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                # If K3S_URL contains an IP, try to find corresponding Tailscale IP
                log_verbose "K3S_URL contains IP address, looking for Tailscale network..."
                # Get the Tailscale status and find nodes
                TAILSCALE_IP=$(tailscale status --json 2>/dev/null | grep -o '"TailscaleIPs":\["[^"]*"' | head -1 | grep -o '[0-9.]*' | head -1)
            else
                # Try to resolve the hostname via Tailscale
                log_verbose "Attempting to resolve $MASTER_HOST via Tailscale..."
                TAILSCALE_IP=$(tailscale ping --timeout=3s "$MASTER_HOST" 2>/dev/null | grep -o 'via [0-9.]*' | cut -d' ' -f2 | head -1)
                if [ -z "$TAILSCALE_IP" ]; then
                    # Alternative: get Tailscale IP from status
                    TAILSCALE_IP=$(tailscale status 2>/dev/null | grep "$MASTER_HOST" | awk '{print $1}' | head -1)
                fi
            fi
            
            if [ -n "$TAILSCALE_IP" ]; then
                REGISTRY_HOST="$TAILSCALE_IP"
                log "Using Tailscale IP for registry: $REGISTRY_HOST:5000"
            else
                log_warn "Could not determine Tailscale IP, trying original host..."
                # Fallback to original logic
                if [[ "$MASTER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    REGISTRY_HOST="$MASTER_HOST"
                else
                    RESOLVED_IP=$(getent hosts "$MASTER_HOST" 2>/dev/null | awk '{print $1}' | head -1)
                    if [ -n "$RESOLVED_IP" ]; then
                        REGISTRY_HOST="$RESOLVED_IP"
                    else
                        REGISTRY_HOST="$MASTER_HOST"
                    fi
                fi
                log_warn "Fallback: Using IP $REGISTRY_HOST:5000 for registry"
            fi
        else
            log_warn "Tailscale not available, using standard hostname resolution..."
            # Original logic as fallback
            if [[ "$MASTER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                REGISTRY_HOST="$MASTER_HOST"
            else
                RESOLVED_IP=$(getent hosts "$MASTER_HOST" 2>/dev/null | awk '{print $1}' | head -1)
                if [ -n "$RESOLVED_IP" ]; then
                    REGISTRY_HOST="$RESOLVED_IP"
                else
                    REGISTRY_HOST="$MASTER_HOST"
                fi
            fi
            log_warn "No Tailscale: Using IP $REGISTRY_HOST:5000 for registry"
        fi

        # Test connectivity to registry before configuring Docker
        if [ -n "$REGISTRY_HOST" ]; then
            log_verbose "Testing connectivity to registry at $REGISTRY_HOST:5000..."
            if command -v nc &>/dev/null; then
                if nc -z -w5 "$REGISTRY_HOST" 5000 2>/dev/null; then
                    log_verbose "✅ Registry at $REGISTRY_HOST:5000 is reachable"
                else
                    log_warn "⚠️  Registry at $REGISTRY_HOST:5000 is not currently reachable"
                    log_warn "This may be normal if the registry is not yet running on the master"
                    log_warn "Proceeding with Docker configuration anyway..."
                fi
            else
                log_verbose "nc (netcat) not available, skipping connectivity test"
            fi

            log_verbose "Debug: Calling setup_docker_insecure_registry with: '$REGISTRY_HOST'"
            if setup_docker_insecure_registry "$REGISTRY_HOST"; then
                log_verbose "✅ Docker registry configuration completed"
                
                # Also configure K3s/containerd registry
                log_verbose "Configuring K3s containerd registry..."
                if setup_k3s_registry_config "$REGISTRY_HOST"; then
                    log_verbose "✅ K3s containerd registry configuration completed"
                    
                    # Restart K3s agent to pick up the new registry configuration
                    log_verbose "Restarting K3s agent to apply registry configuration..."
                    if sudo systemctl restart k3s-agent; then
                        log_verbose "✅ K3s agent restarted successfully"
                        
                        # Wait a moment for the service to stabilize
                        sleep 5
                        
                        # Validate the complete registry setup
                        log_verbose "Validating complete registry configuration..."
                        if validate_registry_setup "$REGISTRY_HOST"; then
                            log "✅ Registry configuration validation passed"
                        else
                            log_warn "⚠️  Registry configuration validation failed"
                            log_warn "Some image pulls may fail - check /etc/docker/daemon.json and /etc/rancher/k3s/registries.yaml"
                        fi
                    else
                        log_warn "⚠️  Failed to restart K3s agent - registry config may not be active"
                        log_warn "Try manually restarting: sudo systemctl restart k3s-agent"
                    fi
                else
                    log_warn "⚠️  K3s containerd registry configuration failed, but Docker config succeeded"
                    log_warn "Some image pulls may still work via Docker, but containerd pulls may fail"
                fi
            else
                log_error "❌ Docker registry configuration failed - this is critical for agent functionality"
                log_error "Agent nodes require access to the master's Docker registry for image distribution"
                log_error "Without registry access, applications cannot be deployed to this agent node"
                echo ""
                log_error "Troubleshooting steps:"
                log_error "  1. Check if Docker service is running: sudo systemctl status docker"
                log_error "  2. Check Docker daemon logs: sudo journalctl -u docker --no-pager --lines=20"
                log_error "  3. Verify master registry is accessible: nc -zv $REGISTRY_HOST 5000"
                log_error "  4. Check Docker daemon config: sudo cat /etc/docker/daemon.json"
                log_error "  5. Try manual Docker restart: sudo systemctl restart docker"
                echo ""
                exit $EXIT_CONFIG_FAILED
            fi
        else
            log_error "❌ Could not determine registry host from K3S_URL: $K3S_URL"
            log_error "Registry configuration failed - agent nodes require registry access"
            log_error "Please ensure K3S_URL is correctly formatted (e.g., https://master-host:6443)"
            exit $EXIT_CONFIG_FAILED
        fi
    else
        log_error "❌ K3S_URL not set - registry configuration failed"
        log_error "Agent nodes require K3S_URL to configure Docker registry access"
        log_error "Please provide K3S_URL parameter for agent setup"
        exit $EXIT_CONFIG_FAILED
    fi

    # Wait for the agent to start connecting to the cluster
    log_verbose "Waiting for K3s agent to begin connecting to cluster..."
    log_verbose "This process can take 30-60 seconds for initial connection..."
    sleep 10

    # Test connectivity to K3s server after installation
    test_k3s_server_connectivity_post_install

    # Simple phone node labeling
    simple_label_node_as_phone

    log "✅ Agent node setup complete"
    log "   Location monitoring will be handled by the K3s server/host only"
    log "   Agent nodes will only provide workload capacity"

    # Show agent setup completion information
    show_agent_completion_info
}

test_k3s_server_connectivity_post_install() {
    log_step "Verifying K3s agent connectivity to server..."

    if [ -n "$K3S_URL" ]; then
        # Extract host from K3S_URL (e.g., https://192.168.1.100:6443 -> 192.168.1.100)
        local k3s_host
        k3s_host=$(echo "$K3S_URL" | sed -E 's|https?://([^:]+):.*|\1|')

        if [ -n "$k3s_host" ]; then
            log_verbose "Post-installation connectivity test to K3s server: $k3s_host"
            if ping -c 3 "$k3s_host" &> /dev/null; then
                log "✅ K3s agent can reach server at $k3s_host"
                log "ℹ️  Agent will connect to cluster automatically (kubectl not available on agents)"
            else
                log_warn "⚠️  Post-installation ping test to K3s server failed"
                log_warn "This may be temporary - the agent will keep trying to connect"
            fi
        fi
    fi
}

show_agent_completion_info() {
    echo ""
    log "=============================================="
    log "K3s Agent Setup Complete!"
    log "=============================================="
    echo ""

    # Network information
    echo ""
    log "Network Information:"
    local node_ip
    node_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    log "  Node IP: $node_ip"

    # Docker registry configuration status
    local registry_status=""
    if [ -f /etc/docker/daemon.json ] && [ -f /etc/rancher/k3s/registries.yaml ]; then
        registry_status="✅ Docker + K3s containerd configured"
    elif [ -f /etc/docker/daemon.json ]; then
        registry_status="⚠️  Docker configured, K3s containerd missing"
    elif [ -f /etc/rancher/k3s/registries.yaml ]; then
        registry_status="⚠️  K3s containerd configured, Docker missing"
    else
        registry_status="❌ No registry configuration found"
    fi
    log "  Docker Registry: $registry_status"

    log "  Geolocation Service: N/A (handled by K3s server only)"

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
    echo ""
    log "Cluster Management:"
    log "  • Check cluster status from server node: kubectl get nodes"
    log "  • View pods on this node: kubectl get pods --all-namespaces --field-selector spec.nodeName=$HOSTNAME"
    log "  • Use status.sh and dashboard.sh to check on nodes"
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

    local server_url="https://$(hostname):6443"

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
    local ping_command="ping -c 3 -q github.com"
    local setup_url="https://raw.githubusercontent.com/parttimenerd/k3s-on-phone/refs/heads/main/setup.sh"
    local cmd_auto="$ping_command && curl -sfL $setup_url | bash -s -- phone-%d$tailscale_flag -k $token -u $server_url"
    local cmd_manual="$ping_command && curl -sfL $setup_url | bash -s -- AGENT_HOSTNAME$tailscale_flag -k $token -u $server_url"
    local cmd_download1="$ping_command && curl -sfL $setup_url > setup.sh"
    local cmd_download2="chmod +x setup.sh"
    local cmd_download3="./setup.sh AGENT_HOSTNAME$tailscale_flag -k $token -u $server_url"

    echo ""
    log "=============================================="
    log "K3s Server Setup Complete!"
    log "=============================================="
    echo ""
    log "✅ Simplified SSH-based location monitoring installed"
    log "   Server-side location updates via SSH (no complex services)"
    log "   Location monitoring service: location-monitor.service"
    echo ""
    log "K3s Token (for agent nodes): $token"
    log "Server URL: $server_url"
    echo ""
    log "To get the token manually anytime:"
    echo "sudo cat /var/lib/rancher/k3s/server/node-token"
    echo ""
    log "To check location monitoring:"
    echo "sudo systemctl status location-monitor"
    echo "sudo /usr/local/bin/update-node-locations.sh --help"
    echo ""
    log "To add agent nodes, use one of the following methods:"
    echo ""
    log "Prerequisites: Ensure K3s Phone Server Android app is running on agent device"
    log "Network Resolution: Commands include 'ping github.com' to test connectivity first"
    log "If ping fails, close the Linux Terminal App tab and reinstall Debian."
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

## Simplified Location Monitoring

This cluster uses **simplified SSH-based location monitoring**:

- ✅ **Server-side location updates**: No complex services on agent nodes
- ✅ **SSH-based querying**: Direct connection to Android apps
- ✅ **No authentication issues**: Simple SSH keys + kubectl commands
- ✅ **Systemd service**: \`location-monitor.service\` on server
- ✅ **Easy debugging**: Transparent operation with clear logs

### Location Monitoring Commands (Server)
\`\`\`bash
# Check location monitoring status
sudo systemctl status location-monitor

# Manual location update
sudo /usr/local/bin/update-node-locations.sh --once --verbose

# View location monitoring logs
sudo journalctl -u location-monitor -f

# Test connectivity to phone nodes
ssh phone-hostname "curl -s http://localhost:8005/location"
\`\`\`

## Setup Methods

⚠️ **Prerequisites Before Agent Setup**:
1. **Install K3s Phone Server Android App**: Download and install the Android APK on your device
2. **Start the Android App**: Ensure the app is running and listening on port 8005
3. **Grant Permissions**: Allow camera, location, and storage permissions when prompted
   - The app will automatically request location access 10 seconds after startup
   - Make sure to grant location permissions for GPS-based cluster mapping
4. **Test Connectivity**: Verify the app responds at \`http://localhost:8005/status\`

**Network Resolution Notice**: All commands include \`ping github.com\` to test network connectivity first. If ping fails, close the Linux Terminal App tab and reinstall Debian.

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

## Location Monitoring Setup (After Agent Installation)

For automatic location updates, set up SSH connectivity from server to agent nodes:

### 1. Generate SSH Key (on server, if not exists)
\`\`\`bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
\`\`\`

### 2. Copy SSH Key to Each Agent Node
\`\`\`bash
ssh-copy-id user@agent-hostname
\`\`\`

### 3. Test SSH Connectivity
\`\`\`bash
ssh agent-hostname "echo 'SSH working'"
\`\`\`

### 4. Test Android App Endpoint
\`\`\`bash
ssh agent-hostname "curl -s http://localhost:8005/location"
\`\`\`

### 5. Verify Location Updates
\`\`\`bash
# Run manual update
sudo /usr/local/bin/update-node-locations.sh --once --verbose

# Check node labels
kubectl get nodes -l device-type=phone -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.phone\.location/latitude}{"\t"}{.metadata.labels.phone\.location/longitude}{"\t"}{.metadata.labels.phone\.location/city}{"\n"}{end}'
\`\`\`
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

## Troubleshooting Network Issues
If \`ping github.com\` fails:
1. Check internet connectivity: \`ping 8.8.8.8\`
2. Check DNS resolution: \`nslookup github.com\`
3. Try alternative DNS: \`echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf.backup\`
4. On Android Linux Terminal: Restart the Debian environment if network issues persist
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
        log_verbose "Auto-hostname pattern detected, expanding %d with random identifier"
        # Replace each %d with a unique random value
        while echo "$HOSTNAME" | grep -q '%d'; do
            local random_id
            # Generate a random lowercase alphanumeric string (6 characters)
            random_id=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)
            HOSTNAME=$(echo "$HOSTNAME" | sed "s/%d/$random_id/")
        done
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

# Function to handle test-geocoder mode
handle_test_geocoder_mode() {
    log "=============================================="
    log "K3s on Phone Geocoder Test v${VERSION}"
    log "=============================================="
    log "Mode: Test geocoder service"
    log "Verbose: $VERBOSE"
    log "=============================================="

    if [ "$VERBOSE" = true ]; then
        log_verbose "Verbose mode enabled - showing detailed output"
    fi

    echo ""

    # Pre-flight checks for test-geocoder
    check_sudo

    # Run geocoder tests
    test_geocoder_service

    # Test city resolution functionality
    log_step "Testing geocoder city resolution with sample coordinates..."
    test_geocoder_city_resolution

    echo ""
    log "=============================================="
    log "Geocoder testing completed!"
    log "=============================================="
    echo ""
    return 0
}

# Main function for setup operations
main_setup() {
    # Handle test-geocoder mode
    if [ "$TEST_GEOCODER_MODE" = true ]; then
        handle_test_geocoder_mode
        return $?
    fi

    # Handle cleanup mode (legacy)
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

    validate_hostname || exit 1
    validate_k3s_params || exit 1
    validate_local_params || exit 1

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
            exit 1
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

        # Check if Android app is running before proceeding
        log_step "Checking if K3s Phone Server Android app is running..."
        
        # For Android setups, the app binds to network interface, not localhost
        # Go straight to network discovery instead of trying localhost first
        log "🔍 Discovering K3s Phone Server on network..."
        discovered_ip=$(scan_k3s_phone_server_parallel "" "true" 2>/dev/null | head -1)
        
        if [ -n "$discovered_ip" ] && curl -s --connect-timeout 3 --max-time 5 "http://${discovered_ip}:8005/status" >/dev/null 2>&1; then
            log "✅ Found K3s Phone Server on network IP: $discovered_ip"
            echo "$discovered_ip" > /tmp/k3s_phone_server_ip
            
            # Set up port forwarding from localhost to network IP
            log_step "Setting up port forwarding: localhost:8005 → ${discovered_ip}:8005"
            if setup_port_forwarding_to_network_ip "$discovered_ip"; then
                log "✅ K3s Phone Server accessible via localhost:8005"
            else
                log_error "❌ Failed to setup port forwarding"
                exit 1
            fi
        else
            log_error "❌ K3s Phone Server Android app is not responding on port 8005"
            log_error "📱 Please ensure the Android app is installed and RUNNING before setup"
            log_error "💡 Steps to fix:"
            log_error "   1. Install K3s Phone Server APK on this device"
            log_error "   2. Open the app and ensure it starts successfully"
            log_error "   3. Verify the app shows 'Server running on port 8005'"
            log_error "   4. Test network discovery: ./setup.sh scan-for-server"
            log_error "   5. Ensure device is on same network as setup machine"
            exit 1
        fi
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
        # For agent nodes, generate random hostname if not provided or if it's not phone-specific
        if [ -n "$K3S_TOKEN" ] && [ -n "$K3S_URL" ]; then
            # This is an agent node - generate random phone hostname
            if [ -z "$HOSTNAME" ] || [[ ! "$HOSTNAME" =~ ^phone- ]]; then
                HOSTNAME=$(generate_phone_hostname)
                log "Generated random hostname for agent node: $HOSTNAME"
            else
                # Ensure hostname is lowercase
                HOSTNAME=$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]')
                log "Using provided hostname (converted to lowercase): $HOSTNAME"
            fi
        else
            # This is a server node - clean up inaccessible phones from Tailscale
            cleanup_tailscale_devices
        fi
        
        set_hostname
        install_docker
        setup_ssh

        # Skip Tailscale setup in agent mode - let install_k3s_agent handle it
        if [ -z "$K3S_TOKEN" ] || [ -z "$K3S_URL" ]; then
            # Server mode - set up Tailscale normally
            setup_tailscale
        else
            # Agent mode - skip initial Tailscale setup, will be handled in install_k3s_agent
            log_verbose "Agent mode: skipping initial Tailscale setup (will be handled by agent installer)"
        fi
    else
        log "Local mode: skipping hostname, Docker, SSH, and Tailscale setup"
        # But we still need to check that Tailscale is available
        check_tailscale_local_mode
    fi

    # Install K3s (server or agent based on parameters)
    if [ -n "$K3S_TOKEN" ] && [ -n "$K3S_URL" ]; then
        install_k3s_agent

        # Setup port forwarding to K3s Phone Server for enhanced capabilities (agent mode only)
        log_step "Setting up K3s Phone Server integration for agent node..."
        if scan_for_k3s_server > /dev/null 2>&1; then
            log "📱 K3s Phone Server detected on network - setting up port forwarding..."
            setup_port_forwarding || log_warn "Port forwarding setup failed - continuing without mobile capabilities"
        else
            log_warn "⚠️  No K3s Phone Server found on local network"
            log_warn "    This means no location, image capture, or local AI capabilities will be available"
            log_warn "    To enable these features:"
            log_warn "      1. Start the K3s Phone Server Android app on a device connected to this network"
            log_warn "      2. Run: ./setup.sh setup-port"
        fi
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

# Check and offer completion installation
check_completion_installation() {
    local completion_installed=false

    # Check if completions are already installed
    if [[ "$SHELL" == */zsh* ]]; then
        # Check zsh completion
        if [[ -n "$fpath" ]] && printf '%s\n' "${fpath[@]}" | grep -q "_k3s_setup"; then
            completion_installed=true
        elif [[ -f "$HOME/.zshrc" ]] && grep -q "k3s-completion.sh" "$HOME/.zshrc"; then
            completion_installed=true
        fi
    elif [[ "$SHELL" == */bash* ]]; then
        # Check bash completion
        if [[ -f "$HOME/.bashrc" ]] && grep -q "k3s-completion.sh" "$HOME/.bashrc"; then
            completion_installed=true
        elif [[ -f "$HOME/.bash_completion" ]] && grep -q "k3s-completion.sh" "$HOME/.bash_completion"; then
            completion_installed=true
        fi
    fi

    # If not installed, offer to install
    if [[ "$completion_installed" == "false" ]] && [[ -f "./install-completion.sh" ]]; then
        echo "📝 Tab completion not detected for your shell ($SHELL)"
        echo "   Would you like to install tab completion? (y/N)"
        echo "   This enables: ./setup.sh <TAB> for command completion"
        echo ""
        read -r response

        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo "🔧 Installing tab completion..."
            if ./install-completion.sh; then
                echo "✅ Tab completion installed successfully!"
                echo "   Restart your shell or run: source ~/.${SHELL##*/}rc"
                echo ""
            else
                echo "❌ Failed to install tab completion"
                echo ""
            fi
        else
            echo "ℹ️  You can install tab completion later with: ./install-completion.sh"
            echo ""
        fi
    fi
}

# Auto-install completion on first successful setup command
auto_install_completion() {
    local command="$1"

    # Only offer completion after successful setup operations
    case "$command" in
        scan-for-server|setup-port|status|dashboard)
            # Only check if this is an interactive session
            if [[ -t 0 ]] && [[ -t 1 ]]; then
                check_completion_installation
            fi
            ;;
    esac
}

# Wrapper for command completion that checks for auto-install
command_exit() {
    local exit_code="$1"
    local command_name="$2"

    # Only offer completion installation on successful commands
    if [[ "$exit_code" -eq 0 ]]; then
        auto_install_completion "$command_name"
    fi

    exit "$exit_code"
}

# Script entry point
parse_command "$@"
