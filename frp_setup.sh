#!/bin/bash
script_file=$(basename "$0")
script_path=$(realpath "$0")
script_dir=$(dirname "$script_path")
script_name=$(echo $script_file | cut -d. -f 1)
cd $script_dir

software_dir="$script_dir/software"
properties_file="$script_dir/frp.properties"
config_dir="$script_dir/config_files"

# Function to generate random string (excluding double quotes)
generate_random_string() {
    local length=${1:-16}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.?' < /dev/urandom | head -c $length
}

# Function to escape special characters for sed
escape_sed() {
    echo "$1" | sed -e 's/[\/&]/\\&/g'
}

# Function to load properties
load_properties() {
    if [ -f "$properties_file" ]; then
        source "$properties_file"
    else
        echo "Error: Properties file $properties_file not found!"
        exit 1
    fi
}

# Function to detect OS version
detect_os_version() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "$VERSION_ID" == 10* ]]; then
            echo "el10"
        elif [[ "$VERSION_ID" == 9* ]]; then
            echo "el9"
        elif [[ "$VERSION_ID" == 8* ]]; then
            echo "el8"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# Function to setup FRP server configuration
setup_frp_server_config() {
    echo "Setting up FRP server configuration..."
    
    # Create FRP configuration directory
    sudo mkdir -p /etc/frp
    
    # Check for TOML config file (new format)
    local source_toml="$config_dir/frps.toml"
    local target_toml="/etc/frp/frps.toml"
    
    if [ -f "$source_toml" ]; then
        echo "Using TOML configuration format (frps.toml)..."
        
        # Copy the TOML configuration file
        sudo cp "$source_toml" "$target_toml"
        
        # Generate random credentials and escape them for sed
        local web_server_pwd=$(generate_random_string 16)
        local auth_token=$(generate_random_string 24)
        
        # Escape special characters for sed
        local escaped_web_server_pwd=$(escape_sed "$web_server_pwd")
        local escaped_auth_token=$(escape_sed "$auth_token")
        
        # Replace the webServer password and auth token in the TOML config file
        sudo sed -i "s/^webServer.password = \".*\"/webServer.password = \"${escaped_web_server_pwd}\"/" "$target_toml"
        sudo sed -i "s/^auth.token = \".*\"/auth.token = \"${escaped_auth_token}\"/" "$target_toml"
        
        # Verify the replacements were made correctly
        if sudo grep -q "^webServer.password = \"${web_server_pwd}\"$" "$target_toml" && \
           sudo grep -q "^auth.token = \"${auth_token}\"$" "$target_toml"; then
            echo "✓ Random credentials successfully applied to TOML configuration"
        else
            echo "Warning: There may have been an issue applying credentials to the TOML configuration file"
            echo "Please verify the contents of $target_toml"
        fi
        
        # Set appropriate permissions
        sudo chmod 644 "$target_toml"
        sudo chown root:root "$target_toml"
        
        echo "FRP server TOML configuration setup completed."
        echo "Configuration file: $target_toml"
        
    else
        # Fall back to INI format if TOML doesn't exist
        local source_ini="$config_dir/frps.ini"
        local target_ini="/etc/frp/frps.ini"
        
        if [ ! -f "$source_ini" ]; then
            echo "Error: No configuration file found. Please ensure config_files directory contains frps.toml or frps.ini"
            exit 1
        fi
        
        echo "Using INI configuration format (frps.ini)..."
        
        # Copy the INI configuration file
        sudo cp "$source_ini" "$target_ini"
        
        # Generate random credentials and escape them for sed
        local dashboard_pwd=$(generate_random_string 16)
        local token=$(generate_random_string 24)
        
        # Escape special characters for sed
        local escaped_dashboard_pwd=$(escape_sed "$dashboard_pwd")
        local escaped_token=$(escape_sed "$token")
        
        # Replace the password and token in the INI config file
        sudo sed -i "s/^dashboard_pwd = .*/dashboard_pwd = ${escaped_dashboard_pwd}/" "$target_ini"
        sudo sed -i "s/^token = .*/token = ${escaped_token}/" "$target_ini"
        
        # Verify the replacements were made correctly
        if sudo grep -q "^dashboard_pwd = ${dashboard_pwd}$" "$target_ini" && \
           sudo grep -q "^token = ${token}$" "$target_ini"; then
            echo "✓ Random credentials successfully applied to INI configuration"
        else
            echo "Warning: There may have been an issue applying credentials to the INI configuration file"
            echo "Please verify the contents of $target_ini"
        fi
        
        # Set appropriate permissions
        sudo chmod 644 "$target_ini"
        sudo chown root:root "$target_ini"
        
        echo "FRP server INI configuration setup completed."
        echo "Configuration file: $target_ini"
    fi
    
    # Copy service file if it exists
    local source_service="$config_dir/frps.service"
    local target_service="/usr/lib/systemd/system/frps.service"
    
    if [ -f "$source_service" ]; then
        echo "Copying FRP server service file..."
        sudo cp "$source_service" "$target_service"
        sudo chmod 644 "$target_service"
        sudo chown root:root "$target_service"
        
        # Reload systemd to recognize the new service
        sudo systemctl daemon-reload
        echo "FRP server service file installed: $target_service"
    else
        echo "Warning: FRP service file $source_service not found."
        echo "The RPM package should provide the service file, but customizations are missing."
    fi
}

# Function to install FRP
install_frp() {
    local role=$1
    local os_version=$(detect_os_version)
    
    # Load properties to get version info
    load_properties
    
    if [ "$os_version" = "unknown" ]; then
        echo "Error: Unsupported OS version. Only EL8, EL9, and EL10 are supported."
        exit 1
    fi
    
    local package_file=""
    
    if [ "$role" = "server" ]; then
        package_file="frps-${frp_version}-${frp_release}.${os_version}.x86_64.rpm"
    elif [ "$role" = "client" ]; then
        package_file="frpc-${frp_version}-${frp_release}.${os_version}.x86_64.rpm"
    else
        echo "Error: Invalid role. Use 'server' or 'client'"
        exit 1
    fi
    
    local package_path="$software_dir/$package_file"
    
    if [ ! -f "$package_path" ]; then
        echo "Error: Package file $package_file not found in $software_dir"
        echo "Available packages:"
        ls -1 "$software_dir/"*.rpm 2>/dev/null || echo "No RPM packages found"
        
        # Provide helpful message
        echo ""
        echo "Note: Expected package name: $package_file"
        echo "Current version: $frp_version, Release: $frp_release"
        exit 1
    fi
    
    echo "Installing FRP $role v${frp_version}-${frp_release} for $os_version..."
    
    # Check if already installed
    if [ "$role" = "server" ]; then
        if rpm -q frps &>/dev/null; then
            echo "FRP server is already installed. Updating..."
            sudo rpm -Uvh "$package_path"
        else
            sudo rpm -ivh "$package_path"
        fi
    else
        if rpm -q frpc &>/dev/null; then
            echo "FRP client is already installed. Updating..."
            sudo rpm -Uvh "$package_path"
        else
            sudo rpm -ivh "$package_path"
        fi
    fi
    
    if [ $? -eq 0 ]; then
        echo "FRP $role v${frp_version}-${frp_release} installed successfully!"
        
        # Setup server configuration if installing server
        if [ "$role" = "server" ]; then
            setup_frp_server_config
            
            # Enable and start the service
            if systemctl list-unit-files | grep -q frps.service; then
                echo "Enabling and starting FRP server service..."
                sudo systemctl enable frps
                sudo systemctl start frps
            else
                echo "Warning: FRP server service not found. Manual service setup may be required."
            fi
        else
            # For client, just enable the service if it exists
            if systemctl list-unit-files | grep -q frpc.service; then
                echo "Enabling FRP client service..."
                sudo systemctl enable frpc
            fi
        fi
        
        # Show service status if available
        if [ "$role" = "server" ]; then
            if systemctl is-active --quiet frps 2>/dev/null; then
                echo "FRP server service is running"
                # Check which config format was used
                if [ -f "/etc/frp/frps.toml" ]; then
                    echo "Web server password and auth token have been randomly generated in /etc/frp/frps.toml"
                else
                    echo "Dashboard password and token have been randomly generated in /etc/frp/frps.ini"
                fi
            elif systemctl is-enabled --quiet frps 2>/dev/null; then
                echo "FRP server service is installed but not running"
            fi
        else
            if systemctl is-active --quiet frpc 2>/dev/null; then
                echo "FRP client service is running"
            elif systemctl is-enabled --quiet frpc 2>/dev/null; then
                echo "FRP client service is installed but not running"
            fi
        fi
    else
        echo "Error: Failed to install FRP $role"
        exit 1
    fi
}

# Function to show current version info
show_version_info() {
    if [ -f "$properties_file" ]; then
        source "$properties_file"
        echo "FRP Version: $frp_version"
        echo "FRP Release: $frp_release"
    else
        echo "Properties file not found: $properties_file"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [--install-server | --install-client | --version | --help]"
    echo ""
    echo "Options:"
    echo "  --install-server    Install FRP server (includes configuration setup)"
    echo "  --install-client    Install FRP client"
    echo "  --version          Show version information"
    echo "  --help             Show this help message"
    echo ""
    local current_os=$(detect_os_version)
    echo "Detected OS version: $current_os"
    echo "Supported OS versions: EL8, EL9, EL10"
    echo ""
    
    # Show version info
    if [ -f "$properties_file" ]; then
        source "$properties_file"
        echo "Current FRP Version: $frp_version-$frp_release"
        echo ""
        echo "Expected package names for $current_os:"
        echo "  Server: frps-${frp_version}-${frp_release}.${current_os}.x86_64.rpm"
        echo "  Client: frpc-${frp_version}-${frp_release}.${current_os}.x86_64.rpm"
        echo ""
    fi
    
    echo "Available packages in software directory:"
    ls -1 "$software_dir/"*.rpm 2>/dev/null || echo "No RPM packages found"
    
    # Show config info
    echo ""
    echo "Configuration notes:"
    echo "  - Server installation looks for these files in config_files/:"
    echo "    * frps.toml (preferred, new TOML format)"
    echo "    * frps.ini (fallback, legacy INI format)" 
    echo "    * frps.service (systemd service file)"
    echo "  - Random web server passwords and auth tokens are generated for security"
    echo "  - Double quotes are excluded from generated passwords"
    echo "  - Configuration directory: /etc/frp/"
}

# Main script logic
case "${1:-}" in
    --install-server)
        install_frp "server"
        ;;
    --install-client)
        install_frp "client"
        ;;
    --version|-v)
        show_version_info
        ;;
    --help|-h|"")
        show_usage
        ;;
    *)
        echo "Error: Unknown option '$1'"
        show_usage
        exit 1
        ;;
esac