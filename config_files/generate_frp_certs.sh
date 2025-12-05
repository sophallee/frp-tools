#!/bin/bash
script_file=$(basename "$0")
script_path=$(realpath "$0")
script_dir=$(dirname "$script_path")
script_name=$(echo $script_file | cut -d. -f 1)
cd $script_dir

# Configuration
properties_file="$script_dir/cert.properties"
ssl_dir="$script_dir/certs"
clients_list_file="$script_dir/clients.list"

# Function to load properties
load_properties() {
    if [ -f "$properties_file" ]; then
        source "$properties_file"
    else
        echo "Error: Properties file $properties_file not found!"
        exit 1
    fi
}

# Load properties
load_properties

# Default values (can be overridden in frp.properties)
ca_cn="${ssl_ca_cn:-ca.fsr.technexus-academy.com}"
server_cn="${ssl_server_cn:-technexus-academy.com}"
country="${ssl_country:-AU}"
state="${ssl_state:-Victoria}"
locality="${ssl_locality:-Melbourne}"
organization="${ssl_organization:-Technexus Academy}"
server_sans="${ssl_server_sans:-DNS:localhost,IP:127.0.0.1,DNS:ovh-vps1.technexus-academy.com}"

# Function to generate OpenSSL config file
generate_openssl_config() {
    local config_file="$1"
    local common_name="$2"
    local san_section="$3"
    
    cat > "$config_file" << EOF
[ req ]
default_bits        = 4096
default_keyfile     = server-key.pem
distinguished_name  = subject
req_extensions      = req_ext
x509_extensions     = x509_ext
string_mask         = utf8only

[ subject ]
countryName         = Country Name (2 letter code)
countryName_default     = $country
stateOrProvinceName     = State or Province Name (full name)
stateOrProvinceName_default = $state
localityName            = Locality Name (eg, city)
localityName_default        = $locality
organizationName          = Organization Name (eg, company)
organizationName_default  = $organization
commonName          = Common Name (e.g. server FQDN or YOUR name)
commonName_default      = $common_name

[ x509_ext ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints       = CA:FALSE
keyUsage               = digitalSignature, keyEncipherment
subjectAltName         = $san_section
nsComment              = "OpenSSL Generated Certificate"

[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints     = CA:FALSE
keyUsage             = digitalSignature, keyEncipherment
subjectAltName       = $san_section
nsComment            = "OpenSSL Generated Certificate"
EOF
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --generate ca-cert          Generate CA certificate only"
    echo "  --generate server-cert      Generate server certificate only"
    echo "  --generate client-cert CN   Generate client certificate for specific CN"
    echo "  --generate all-clients      Generate certificates for all clients in clients.list"
    echo "  --generate all              Generate all certificates (CA, server, all clients)"
    echo "  --clean                     Remove all generated SSL files"
    echo "  --verify                    Verify generated certificates"
    echo "  --list-clients              List configured clients and tarballs"
    echo "  --help                      Show this help message"
    echo ""
    echo "Configuration:"
    echo "  - Properties file: $properties_file"
    echo "  - Clients list:    $clients_list_file (one client per line)"
    echo "  - SSL directory:   $ssl_dir"
    echo "  - Client output:   Tarballs in $ssl_dir/clients/"
    echo ""
    echo "Certificate details:"
    echo "  CA CN:          $ca_cn"
    echo "  Server CN:      $server_cn"
    echo "  Country:        $country"
    echo "  State:          $state"
    echo "  Locality:       $locality"
    echo "  Organization:   $organization"
    echo "  Server SANs:    $server_sans"
    echo ""
    echo "Add these to frp.properties to customize:"
    echo "  ssl_ca_cn, ssl_server_cn"
    echo "  ssl_country, ssl_state, ssl_locality, ssl_organization"
    echo "  ssl_server_sans"
}

# Function to get list of clients
get_clients_list() {
    local clients=()
    
    # Check if clients.list exists
    if [ -f "$clients_list_file" ]; then
        # Read clients from file, skip comments and empty lines
        while IFS= read -r line || [ -n "$line" ]; do
            # Trim whitespace
            line=$(echo "$line" | xargs)
            # Skip empty lines and comments
            if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
                clients+=("$line")
            fi
        done < "$clients_list_file"
    fi
    
    # If no clients in file, show error
    if [ ${#clients[@]} -eq 0 ]; then
        echo "Error: No clients found in $clients_list_file"
        echo "Create $clients_list_file with one client CN per line"
        exit 1
    fi
    
    echo "${clients[@]}"
}

# Function to list clients and tarballs
list_clients() {
    echo "Configured clients:"
    echo "-------------------"
    
    if [ -f "$clients_list_file" ]; then
        echo "From $clients_list_file:"
        cat "$clients_list_file" | grep -v '^#' | grep -v '^$' | nl -w2 -s'. '
    else
        echo "No clients.list file found."
    fi
    
    echo ""
    echo "Generated client tarballs in $ssl_dir/clients/:"
    echo "-----------------------------------------------"
    if [ -d "$ssl_dir/clients" ]; then
        cd "$ssl_dir/clients"
        ls -la *.tar.gz 2>/dev/null | nl -w2 -s'. ' || echo "  No tarballs found"
    else
        echo "  No clients directory found"
    fi
}

# Function to generate CA certificate
generate_ca_cert() {
    echo "Generating Certificate Authority (CA)..."
    
    mkdir -p "$ssl_dir"
    cd "$ssl_dir"
    
    openssl genrsa -out ca.key 2048
    openssl req -x509 -new -nodes -key ca.key \
        -subj "/CN=$ca_cn" \
        -days 5000 -out ca.crt
    
    echo "✓ CA certificate generated:"
    echo "  - ca.key (private key)"
    echo "  - ca.crt (certificate)"
}

# Function to generate server certificate
generate_server_cert() {
    echo "Generating server certificate..."
    
    if [ ! -f "$ssl_dir/ca.crt" ] || [ ! -f "$ssl_dir/ca.key" ]; then
        echo "Error: CA certificate (ca.crt) or key (ca.key) not found."
        echo "Generate CA certificate first with: $0 --generate ca-cert"
        exit 1
    fi
    
    mkdir -p "$ssl_dir"
    cd "$ssl_dir"
    
    # Generate OpenSSL config for server
    generate_openssl_config "server-openssl.cnf" "$server_cn" "$server_sans"
    
    openssl genrsa -out server.key 2048
    openssl req -new -sha256 -key server.key \
        -subj "/C=$country/ST=$state/L=$locality/O=$organization/CN=$server_cn" \
        -reqexts SAN \
        -config <(cat server-openssl.cnf <(printf "\n[SAN]\nsubjectAltName=$server_sans")) \
        -out server.csr
    
    openssl x509 -req -days 3650 -sha256 \
        -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -extfile <(printf "subjectAltName=$server_sans") \
        -out server.crt
    
    # Create combined and PKCS12 files
    cat server.crt server.key > server-combined.pem
    openssl pkcs12 -export -out server.p12 -inkey server.key -in server.crt -certfile ca.crt -password pass:
    
    # Clean up temp files
    rm -f server-openssl.cnf server.csr ca.srl
    
    echo "✓ Server certificate generated:"
    echo "  - server.key (private key)"
    echo "  - server.crt (certificate)"
    echo "  - server-combined.pem (certificate + key)"
    echo "  - server.p12 (PKCS12 format)"
}

# Function to generate a single client certificate and create tarball
generate_single_client_cert() {
    local client_cn="$1"
    
    echo "Generating certificate for client: $client_cn"
    
    # Sanitize filename
    local client_filename=$(echo "$client_cn" | sed 's/[^a-zA-Z0-9.-]/_/g')
    local temp_dir="$ssl_dir/temp_${client_filename}"
    local clients_dir="$ssl_dir/clients"
    
    # Create temporary directory for this client
    mkdir -p "$temp_dir"
    
    # Client SANs
    local client_sans="DNS:$client_cn"
    
    # Generate OpenSSL config for client
    generate_openssl_config "$temp_dir/client-openssl.cnf" "$client_cn" "$client_sans"
    
    # Generate key and CSR
    openssl genrsa -out "$temp_dir/${client_filename}.key" 2048
    openssl req -new -sha256 -key "$temp_dir/${client_filename}.key" \
        -subj "/C=$country/ST=$state/L=$locality/O=$organization/CN=$client_cn" \
        -reqexts SAN \
        -config <(cat "$temp_dir/client-openssl.cnf" <(printf "\n[SAN]\nsubjectAltName=$client_sans")) \
        -out "$temp_dir/${client_filename}.csr"
    
    # Sign certificate with CA
    openssl x509 -req -days 365 -sha256 \
        -in "$temp_dir/${client_filename}.csr" -CA "$ssl_dir/ca.crt" -CAkey "$ssl_dir/ca.key" -CAcreateserial \
        -extfile <(printf "subjectAltName=$client_sans") \
        -out "$temp_dir/${client_filename}.crt"
    
    # Create combined and PKCS12 files
    cat "$temp_dir/${client_filename}.crt" "$temp_dir/${client_filename}.key" > "$temp_dir/${client_filename}-combined.pem"
    openssl pkcs12 -export -out "$temp_dir/${client_filename}.p12" \
        -inkey "$temp_dir/${client_filename}.key" \
        -in "$temp_dir/${client_filename}.crt" \
        -certfile "$ssl_dir/ca.crt" \
        -password pass:
    
    # Copy CA certificate
    cp "$ssl_dir/ca.crt" "$temp_dir/"
    
    # Create README file
    cat > "$temp_dir/README.txt" << EOF
FRP Client SSL Certificate Package
==================================

Client: $client_cn
Generated: $(date)
CA: $ca_cn

Files included:
1. ${client_filename}.key     - Private key (keep this secure!)
2. ${client_filename}.crt     - Client certificate
3. ${client_filename}-combined.pem - Combined certificate + key
4. ${client_filename}.p12     - PKCS12 format (for browsers/Java)
5. ca.crt                    - Certificate Authority certificate

Installation instructions for FRP client:

1. Copy the files to your FRP client system:
   - ca.crt -> /etc/frp/ca.crt
   - ${client_filename}.crt -> /etc/frp/client.crt
   - ${client_filename}.key -> /etc/frp/client.key

2. Update your FRP client configuration (frpc.toml):
   [common]
   serverAddr = "your-server-address"
   serverPort = 7000
   
   tls.enable = true
   tls.certFile = "/etc/frp/client.crt"
   tls.keyFile = "/etc/frp/client.key"
   tls.trustedCaFile = "/etc/frp/ca.crt"

3. Set proper permissions:
   sudo chmod 600 /etc/frp/client.key
   sudo chmod 644 /etc/frp/client.crt /etc/frp/ca.crt

Security notes:
- Keep the .key file secure (readable only by root)
- The password for .p12 files is empty (press Enter when prompted)
- These certificates are valid for 365 days
EOF
    
    # Create tarball
    mkdir -p "$clients_dir"
    cd "$temp_dir"
    tar -czf "$clients_dir/${client_filename}.tar.gz" .
    
    # Clean up temporary directory
    cd "$ssl_dir"
    rm -rf "$temp_dir"
    
    echo "✓ Certificate tarball created for $client_cn"
    echo "  File: clients/${client_filename}.tar.gz"
    echo "  Contents: .key, .crt, .p12, .pem, ca.crt, README.txt"
}

# Function to generate certificate for specific client
generate_client_cert() {
    local client_cn="$2"
    
    if [ -z "$client_cn" ]; then
        echo "Error: Client CN required."
        echo "Usage: $0 --generate client-cert CLIENT_CN"
        exit 1
    fi
    
    if [ ! -f "$ssl_dir/ca.crt" ] || [ ! -f "$ssl_dir/ca.key" ]; then
        echo "Error: CA certificate (ca.crt) or key (ca.key) not found."
        echo "Generate CA certificate first with: $0 --generate ca-cert"
        exit 1
    fi
    
    mkdir -p "$ssl_dir"
    cd "$ssl_dir"
    
    generate_single_client_cert "$client_cn"
}

# Function to generate certificates for all clients
generate_all_client_certs() {
    if [ ! -f "$ssl_dir/ca.crt" ] || [ ! -f "$ssl_dir/ca.key" ]; then
        echo "Error: CA certificate (ca.crt) or key (ca.key) not found."
        echo "Generate CA certificate first with: $0 --generate ca-cert"
        exit 1
    fi
    
    mkdir -p "$ssl_dir"
    cd "$ssl_dir"
    
    local clients=($(get_clients_list))
    local total=${#clients[@]}
    
    echo "Generating certificate tarballs for $total client(s)..."
    
    for ((i=0; i<total; i++)); do
        local client_cn="${clients[$i]}"
        echo ""
        echo "[$((i+1))/$total]"
        generate_single_client_cert "$client_cn"
    done
    
    echo ""
    echo "✓ All client certificate tarballs generated"
    echo "  Location: $ssl_dir/clients/"
    echo ""
    echo "To distribute to a client (example):"
    echo "  scp $ssl_dir/clients/prod-web1.technexus-academy.com.tar.gz user@prod-web1:/tmp/"
    echo "  ssh user@prod-web1 'cd /etc/frp && sudo tar -xzf /tmp/prod-web1.technexus-academy.com.tar.gz'"
}

# Function to generate all certificates
generate_all_certs() {
    echo "Generating all SSL certificates..."
    echo "SSL directory: $ssl_dir"
    
    mkdir -p "$ssl_dir"
    cd "$ssl_dir"
    
    generate_ca_cert
    echo ""
    generate_server_cert
    echo ""
    generate_all_client_certs
}

# Function to verify certificates
verify_ssl() {
    if [ ! -d "$ssl_dir" ]; then
        echo "Error: SSL directory $ssl_dir not found."
        echo "Run $0 --generate first."
        exit 1
    fi
    
    cd "$ssl_dir"
    
    echo "Verifying SSL certificates..."
    echo "=============================="
    
    # Check CA certificate
    echo "1. CA Certificate:"
    if [ -f "ca.crt" ]; then
        openssl x509 -in ca.crt -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After"
        echo ""
    else
        echo "  ERROR: ca.crt not found"
    fi
    
    # Check server certificate
    echo "2. Server Certificate:"
    if [ -f "server.crt" ]; then
        openssl x509 -in server.crt -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After|DNS:|IP Address:"
        
        # Verify server cert against CA
        echo ""
        echo "  Verifying against CA:"
        if openssl verify -CAfile ca.crt server.crt > /dev/null 2>&1; then
            echo "  ✓ Server certificate is valid and signed by CA"
        else
            echo "  ✗ Server certificate verification failed"
        fi
    else
        echo "  ERROR: server.crt not found"
    fi
    
    # Check client tarballs
    echo ""
    echo "3. Client Certificate Tarballs:"
    
    local clients_dir="$ssl_dir/clients"
    if [ -d "$clients_dir" ]; then
        local tarball_count=$(ls "$clients_dir"/*.tar.gz 2>/dev/null | wc -l)
        if [ $tarball_count -eq 0 ]; then
            echo "  No client tarballs found in $clients_dir/"
        else
            echo "  Found $tarball_count client tarball(s):"
            
            # Create temporary directory for verification
            local temp_verify_dir=$(mktemp -d)
            
            for tarball in "$clients_dir"/*.tar.gz; do
                local tarball_name=$(basename "$tarball")
                local client_name="${tarball_name%.tar.gz}"
                
                echo "  - $client_name"
                
                # Extract and verify
                tar -xzf "$tarball" -C "$temp_verify_dir" 2>/dev/null
                
                # Check for .crt file
                local cert_file=$(find "$temp_verify_dir" -name "*.crt" -not -name "ca.crt" | head -1)
                if [ -f "$cert_file" ]; then
                    if openssl verify -CAfile ca.crt "$cert_file" > /dev/null 2>&1; then
                        echo "      ✓ Valid and signed by CA"
                    else
                        echo "      ✗ Verification failed"
                    fi
                fi
                
                # Clean temp directory for next tarball
                rm -rf "$temp_verify_dir"/*
            done
            
            # Clean up
            rm -rf "$temp_verify_dir"
        fi
    else
        echo "  No clients directory found"
    fi
}

# Function to clean up SSL files
clean_ssl() {
    echo "Cleaning SSL files from $ssl_dir..."
    
    if [ -d "$ssl_dir" ]; then
        # List files to be removed
        echo "Files to be removed:"
        ls -la "$ssl_dir/" 2>/dev/null || echo "  (directory is empty)"
        
        # Ask for confirmation
        read -p "Are you sure you want to delete all SSL files? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$ssl_dir"
            echo "✓ SSL files removed."
        else
            echo "Operation cancelled."
        fi
    else
        echo "SSL directory $ssl_dir does not exist."
    fi
}

# Main script logic
case "${1:-}" in
    --generate)
        mkdir -p "$ssl_dir"
        case "${2:-}" in
            ca-cert)
                generate_ca_cert
                ;;
            server-cert)
                generate_server_cert
                ;;
            client-cert)
                generate_client_cert "$@"
                ;;
            all-clients)
                generate_all_client_certs
                ;;
            all|"")
                generate_all_certs
                ;;
            *)
                echo "Error: Unknown certificate type '$2'"
                echo "Valid types: ca-cert, server-cert, client-cert CN, all-clients, all"
                exit 1
                ;;
        esac
        ;;
    --clean|-c)
        clean_ssl
        ;;
    --verify|-v)
        verify_ssl
        ;;
    --list-clients|-l)
        list_clients
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